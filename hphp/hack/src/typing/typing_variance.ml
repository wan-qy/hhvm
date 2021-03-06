(**
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

open Core
open Typing_defs
open Utils

module Env = Typing_env
module SN = Naming_special_names
module TLazyHeap = Typing_lazy_heap

(*****************************************************************************)
(* Module checking the (co/contra)variance annotations (+/-).
 *
 * The algorithm works in 2 passes:
 *  1) Infer the variance of every type parameter for a given class or typedef
 *  2) Check that the annotation matches the type inferred
 *
 * For every type inferred, we keep a witness (a position in the source),
 * that tells us where the covariance (or contravariance) was deduced.
 * This way, when we find an error, we can point to the place that was
 * problematic (as usual).
 *)
(*****************************************************************************)

(* Type describing the kind of position we are dealing with.
 * Pos.t gives us the position in the source, it doesn't tell us the kind
 * of position we are dealing with. This type keeps track of that.
 *)
type position_descr =
  | Rtypedef
  | Rmember                       (* Instance variable  *)
  | Rtype_parameter               (* The declaration site of a type-parameter
                                   *)
  | Rfun_parameter of [`Static | `Instance]
  | Rfun_return of [`Static | `Instance]
  | Rtype_argument of string      (* The argument of a parametric class or
                                   * typedef:
                                   * A<T1, ..>, T1 is (Rtype_argument "A")
                                   *)
  | Rconstraint_as
  | Rconstraint_eq
  | Rconstraint_super

type position_variance =
  | Pcovariant
  | Pcontravariant
  | Pinvariant

type reason = Pos.t * position_descr * position_variance

(* The variance that we have inferred for a given type-parameter. We keep
 * a stack of reasons that made us infer the variance of a position.
 * For example:
 * T appears in foo(...): (function(...): T)
 * T is inferred as covariant + a stack made of two elements:
 * -) The first one points to the position of T
 * -) The second one points to the position of (function(...): T)
 * We can, thanks to this stack, detail why we think something is covariant
 * in the error message.
 *)
type variance =
  (* The type parameter appeared in covariant position. *)
  | Vcovariant     of reason list

  (* The type parameter appeared in contravariant position. *)
  | Vcontravariant of reason list

  (* The type parameter appeared in both covariant and contravariant position.
   * We keep a stack for each side: the left hand side is proof for covariance,
   * while the right hand side is proof for contravariance.
   *)
  | Vinvariant     of reason list * reason list

  (* The type parameter is both covariant and contravariant. This can only
   * happen if the type parameter is not used. Technically, another possible
   * case would be when it is composed with a typedef that is both covariant
   * and contravariant, but since we don't have any syntax to declare such
   * a type, it cannot happen in practice.
   * We don't keep witnesses for such a type, because no error can ever
   * occur.
   *)
  | Vboth

type env = variance SMap.t

(*****************************************************************************)
(* Reason pretty-printing *)
(*****************************************************************************)

let variance_to_string = function
  | Pcovariant     -> "covariant (+)"
  | Pcontravariant -> "contravariant (-)"
  | Pinvariant     -> "invariant"

let variance_to_sign = function
  | Pcovariant     -> "(+)"
  | Pcontravariant -> "(-)"
  | Pinvariant     -> "(I)"

let reason_stack_to_string variance reason_stack =
  Printf.sprintf
    "This position is %s because it is the composition of %s\n\
    The rest of the error messages decomposes the inference of the variance.\n\
    Check out this link if you don't understand what this is about:\n\
    http://en.wikipedia.org/wiki/Covariance_and_contravariance_\
    (computer_science)\
    "
    variance
    begin List.fold_right reason_stack ~f:begin fun (_, _, pvariance) acc ->
      (variance_to_sign pvariance)^acc
    end ~init:""
    end

let reason_to_string ~sign (_, descr, variance) =
  (if sign
  then variance_to_sign variance^" "
  else ""
  )^
  match descr with
  | Rtypedef ->
      "Aliased types are covariant"
  | Rmember ->
      "A non private class member is always invariant"
  | Rtype_parameter ->
      "The type parameter was declared as "^variance_to_string variance
  | Rfun_parameter `Instance ->
      "Function parameters are contravariant"
  | Rfun_parameter `Static ->
      "Function parameters in non-final static functions are contravariant"
  | Rfun_return `Instance ->
      "Function return types are covariant"
  | Rfun_return `Static ->
      "Function return types in non-final static functions are covariant"
  | Rtype_argument name ->
      Printf.sprintf
        "This type parameter was declared as %s (cf '%s')"
        (variance_to_string variance)
        name
  | Rconstraint_super ->
      "`super` constraints on method type parameters are covariant"
  | Rconstraint_as ->
      "`as` constraints on method type parameters are contravariant"
  | Rconstraint_eq ->
      "`=` constraints on method type parameters are invariant"

let detailed_message variance pos stack =
  match stack with
  | [] -> []
  | [p, _, _ as r] ->
      [p, reason_to_string ~sign:false r]
  | _ ->
      (pos, reason_stack_to_string variance stack) ::
      List.map stack (fun (p, _, _ as r) -> p, reason_to_string ~sign:true r)

(*****************************************************************************)
(* Debug *)
(*****************************************************************************)

let to_string = function
  | Vcovariant _     -> "Vcovariant"
  | Vcontravariant _ -> "Vcontravariant"
  | Vinvariant _     -> "Vinvariant"
  | Vboth            -> "Vboth"

(*****************************************************************************)
(* Converts an annotation (+/-) to a type. *)
(*****************************************************************************)

let make_variance reason pos = function
  | Ast.Covariant ->
      Vcovariant [pos, reason, Pcovariant]
  | Ast.Contravariant ->
      Vcontravariant [pos, reason, Pcontravariant]
  | Ast.Invariant ->
      Vinvariant ([pos, reason, Pinvariant], [pos, reason, Pinvariant])

(*****************************************************************************)
(* Adds a new usage of a type to the environment.
 * This is not as simple as SMap.add, because, depending on what was already
 * there, a type can become invariant.
 * Let's say we start with T used in a covariant position: the type should
 * be Vcovariant.
 * Now if we find a place where T is used in contravariant position, it
 * must become invariant.
 *)
(*****************************************************************************)

let add_variance env name variance =
  match SMap.get name env with
  | None -> SMap.add name variance env
  | Some old_variance ->
      match old_variance, variance with
      (* Whatever the type is, if we add a usage that is both (covariant and
       * contravariant) then the variance is unchanged.
       *)
      | _, Vboth
      (* The usage is already invariant (the most restrictive type), it
       * cannot change past this point.
       *)
      | Vinvariant _, _ -> env
      (* The type is both (covariant and contravariant), Whatever the new
       * usage is, it's going to be more restrictive than what we already
       * have.
       *)
      | Vboth, _
      (* We are adding an invariant case (the most restrictive variance),
       * whatever the previous cases were, invariant is the new type
       *)
      | _, Vinvariant _ -> SMap.add name variance env
      | Vcovariant _, Vcovariant _
      | Vcontravariant _, Vcontravariant _ -> env
      | Vcovariant p1, Vcontravariant p2 ->
          SMap.add name (Vinvariant (p1, p2)) env
      | Vcontravariant p2, Vcovariant p1 ->
          SMap.add name (Vinvariant (p1, p2)) env

(*****************************************************************************)
(* Used when we want to compose with the variance coming from another class.
 * Let's assume: A<-T>
 * public function foo(A<T> $x): void;
 * A<T> is in contravariant position so we process -A<T>.
 * because A is annotated with a minus: we deduce --T (which becomes T).
 *)
(*****************************************************************************)

let compose (pos, param_descr) from to_ =
  (* We don't really care how we deduced the variance that we are composing
   * with (_stack_to). That's because the decomposition could be in a different
   * file and would be too hard to follow anyway.
   * Let's consider the following return type: A<T>.
   * Turns out A is declared as A<-T>.
   * It's not a good idea for us to point to what made us deduce that the
   * position was contravariant (the declaration side). Because the user will
   * wonder where it comes from.
   * It's better to point to the return type (more precisely, point to the T
   * in the return type) and explain that this position is contravariant.
   * Later on, the user can go and check the definition of A for herself.
   *)
  match from, to_ with
  | Vcovariant stack_from, Vcovariant _stack_to ->
      let reason = pos, param_descr, Pcovariant in
      Vcovariant (reason :: stack_from)
  | Vcontravariant stack_from, Vcontravariant _stack_to ->
      let reason = pos, param_descr, Pcontravariant in
      Vcovariant (reason :: stack_from)
  | Vcovariant stack_from, Vcontravariant _stack_to ->
      let reason = pos, param_descr, Pcontravariant in
      Vcontravariant (reason :: stack_from)
  | Vcontravariant stack_from, Vcovariant _stack_to ->
      let reason = pos, param_descr, Pcovariant in
      Vcontravariant (reason :: stack_from)
  | (Vinvariant _ as x), _ -> x
  | _, Vinvariant (_co, _contra) ->
      let reason = pos, param_descr, Pinvariant in
      Vinvariant ([reason], [reason])
  | Vboth, x | x, Vboth -> x

(*****************************************************************************)
(* Used for the arguments of function. *)
(*****************************************************************************)

let flip reason = function
  | Vcovariant stack -> Vcontravariant (reason :: stack)
  | Vcontravariant stack -> Vcovariant (reason :: stack)
  | Vinvariant _ as x -> x
  | Vboth -> Vboth

(*****************************************************************************)
(* Given a type parameter, returns the variance inferred. *)
(*****************************************************************************)

let get_tparam_variance env (_, (_, tparam_name), _) =
  match SMap.get tparam_name env with
  | None -> Vboth
  | Some x -> x

(*****************************************************************************)
(* Given a type parameter, returns the variance declared. *)
(*****************************************************************************)

let make_tparam_variance (variance, (pos, _), _) =
  make_variance Rtype_parameter pos variance

(*****************************************************************************)
(* Checks that the annotation matches the inferred type. *)
(*****************************************************************************)

let check_variance env tparam =
  let declared_variance = make_tparam_variance tparam in
  let inferred_variance = get_tparam_variance env tparam in
  match declared_variance, inferred_variance with
  | Vboth, _ -> assert false (* There is no syntax for that *)
  | _, Vboth -> ()
  | Vinvariant _, _ -> ()
  | Vcovariant _, Vcovariant _
  | Vcontravariant _, Vcontravariant _ -> ()
  | Vcovariant stack1, (Vcontravariant stack2 | Vinvariant (_, stack2)) ->
      let (pos1, _, _) = List.hd_exn stack1 in
      let (pos2, _, _) = List.hd_exn stack2 in
      let emsg = detailed_message "contravariant (-)" pos2 stack2 in
      Errors.declared_covariant pos1 pos2 emsg
  | Vcontravariant stack1, (Vcovariant stack2 | Vinvariant (stack2, _)) ->
      let (pos1, _, _) = List.hd_exn stack1 in
      let (pos2, _, _) = List.hd_exn stack2 in
      let emsg = detailed_message "covariant (+)" pos2 stack2 in
      Errors.declared_contravariant pos1 pos2 emsg

(******************************************************************************)
(* Checks that a 'this' type is correctly used at a given contravariant       *)
(* position in a final class.                                                 *)
(******************************************************************************)
let check_final_this_pos_variance env_variance rpos class_ty =
  if class_ty.tc_final then
    List.iter class_ty.tc_tparams
      begin fun (typar_variance, id, _) ->
        match env_variance, typar_variance with
        | Vcontravariant(_), (Ast.Covariant | Ast.Contravariant)  ->
           (Errors.contravariant_this
             rpos
             (Utils.strip_ns class_ty.tc_name)
             (snd id))
        | _ -> ()
      end

(*****************************************************************************)
(* Returns the list of type parameter variance for a given class.
 * Performing that operation adds a dependency on the class, because if
 * the class changes (especially the variance), we must re-check the class.
 *
 * N.B.: this function works both with classes and typedefs.
 *)
(*****************************************************************************)

let get_class_variance tcopt root (pos, class_name) =
  match class_name with
  | name when (name = SN.Classes.cAwaitable) ->
      [Vcovariant [pos, Rtype_argument (Utils.strip_ns name), Pcovariant]]
  | _ ->
      let dep = Typing_deps.Dep.Class class_name in
      Typing_deps.add_idep (fst root) dep;
      let tparams =
        if Env.is_typedef class_name
        then
          match TLazyHeap.get_typedef tcopt class_name with
          | Some {td_tparams; _} -> td_tparams
          | None -> []
        else
          match TLazyHeap.get_class tcopt class_name with
          | None -> []
          | Some { tc_tparams; _ } -> tc_tparams
      in
      List.map tparams make_tparam_variance

(*****************************************************************************)
(* The entry point (for classes). *)
(*****************************************************************************)

let rec class_ tcopt class_name class_type impl =
  let root = (Typing_deps.Dep.Class class_name, Some(class_type)) in
  let tparams = class_type.tc_tparams in
  let env = SMap.empty in
  let env = List.fold_left impl ~f:(type_ tcopt root Vboth) ~init:env in
  let env = SMap.fold (class_member tcopt root) class_type.tc_props env in
  let env =
    SMap.fold (class_method tcopt root `Instance) class_type.tc_methods env in
  (* We need to apply the same restrictions to non-final static members because
     they can be invoked through classname instances *)
  let env =
    if class_type.tc_final
    then env
    else SMap.fold (class_method tcopt root `Static) class_type.tc_smethods env in
  List.iter tparams (check_variance env)

(*****************************************************************************)
(* The entry point (for typedefs). *)
(*****************************************************************************)

and typedef tcopt type_name =
  match TLazyHeap.get_typedef tcopt type_name with
  | Some {td_tparams; td_type; td_pos = _; td_constraint = _; td_vis = _}  ->
     let root = (Typing_deps.Dep.Class type_name, None) in
      let env = SMap.empty in
      let pos = Reason.to_pos (fst td_type) in
      let reason_covariant = [pos, Rtypedef, Pcovariant] in
      let env = type_ tcopt root (Vcovariant reason_covariant) env td_type in
      List.iter td_tparams (check_variance env)
  | None -> ()

and class_member tcopt root _member_name member env =
  match member.ce_visibility with
  | Vprivate _ -> env
  | _ ->
      let lazy (reason, _ as ty) = member.ce_type in
      let pos = Reason.to_pos reason in
      let variance = make_variance Rmember pos Ast.Invariant in
      type_ tcopt root variance env ty

and class_method tcopt root static _method_name method_ env =
  match method_.ce_visibility with
  | Vprivate _ -> env
  | _ ->
    (* Final methods can't be overridden, so it's ok to use covariant
       and contravariant type parameters in any position in the type *)
    if method_.ce_final && static = `Static
    then env
    else
      match method_.ce_type with
      | lazy (_, Tfun { ft_tparams; ft_params; ft_ret; _ }) ->
          let env = List.fold_left ft_tparams
            ~f:begin fun env (_, (_, tparam_name), _) ->
              SMap.remove tparam_name env
            end ~init:env in
          let env = List.fold_left
            ~f:(fun_param tcopt root static) ~init:env ft_params in
          let env = List.fold_left
            ~f:(fun_tparam tcopt root) ~init:env ft_tparams in
          let env = fun_ret tcopt root static env ft_ret in
          env
      | _ -> assert false

and fun_param tcopt root static env (_, (reason, _ as ty)) =
  let pos = Reason.to_pos reason in
  let reason_contravariant = pos, Rfun_parameter static, Pcontravariant in
  let variance = Vcontravariant [reason_contravariant] in
  type_ tcopt root variance env ty

and fun_tparam tcopt root env (_, _, cstrl) =
  List.fold_left ~f:(constraint_ tcopt root) ~init:env cstrl

and fun_ret tcopt root static env (reason, _ as ty) =
  let pos = Reason.to_pos reason in
  let reason_covariant = pos, Rfun_return static, Pcovariant in
  let variance = Vcovariant [reason_covariant] in
  type_ tcopt root variance env ty

and type_option tcopt root variance env = function
  | None -> env
  | Some ty -> type_ tcopt root variance env ty

and type_list tcopt root variance env tyl =
  List.fold_left ~f:(type_ tcopt root variance) ~init:env tyl

and type_ tcopt root variance env (reason, ty) =
  match ty with
  | Tany -> env
  | Tmixed -> env
  | Tarray (ty1, ty2) ->
    let env = type_option tcopt root variance env ty1 in
    let env = type_option tcopt root variance env ty2 in
    env
  | Tthis ->
    (* Check that 'this' isn't being improperly referenced in a contravariant
     * position.
     *)
    Option.value_map
      (snd root)
      ~default:()
      ~f:(check_final_this_pos_variance variance (Reason.to_pos reason)) ;
    (* With the exception of the above check, `this` constraints are bivariant
     * (otherwise any class that used the `this` type would not be able to use
     * covariant type params).
     *)
    env
  | Tgeneric (name, constraints) ->
     let pos = Reason.to_pos reason in
     (* As above for 'Tthis', if 'this' appears in any constraints on the type,
      * check that it's being referenced in a proper position.
      *)
     List.iter constraints begin fun (_, (r, _ as ty))  ->
        match ty with
        | (_, Tthis) ->
           Option.value_map
             (snd root)
             ~default:()
             ~f: (check_final_this_pos_variance variance (Reason.to_pos r))
        | _ -> ()
      end ;
      (* This section makes the position more precise.
       * Say we find a return type that is a tuple (int, int, T).
       * The whole tuple is in covariant position, and so the position
       * is going to include the entire tuple.
       * That can make things pretty unreadable when the type is long.
       * Here we replace the position with the exact position of the generic
       * that was problematic.
       *)
      let variance =
        match variance with
        | Vcovariant ((pos', x, y) :: rest) when pos <> pos' ->
            Vcovariant ((pos, x, y) :: rest)
        | Vcontravariant ((pos', x, y) :: rest) when pos <> pos' ->
            Vcontravariant ((pos, x, y) :: rest)
        | x -> x
      in
      add_variance env name variance
  | Toption ty ->
      type_ tcopt root variance env ty
  | Tprim _ -> env
  | Tfun ft ->
      let env = List.fold_left ~f:begin fun env (_, (r, _ as ty)) ->
        let pos = Reason.to_pos r in
        let reason = pos, Rfun_parameter `Instance, Pcontravariant in
        let variance = flip reason variance in
        type_ tcopt root variance env ty
      end ~init:env ft.ft_params
      in
      let ret_pos = Reason.to_pos (fst ft.ft_ret) in
      let ret_variance = ret_pos, Rfun_return `Instance, Pcovariant in
      let variance =
        match variance with
        | Vcovariant stack -> Vcovariant (ret_variance :: stack)
        | Vcontravariant stack -> Vcontravariant (ret_variance :: stack)
        | variance -> variance
      in
      let env = type_ tcopt root variance env ft.ft_ret in
      env
  | Tapply (_, []) -> env
  | Tapply ((_, name as pos_name), tyl) ->
      let variancel = get_class_variance tcopt root pos_name in
      wfold_left2 begin fun env tparam_variance (r, _ as ty) ->
        let pos = Reason.to_pos r in
        let reason = Rtype_argument (Utils.strip_ns name) in
        let variance = compose (pos, reason) variance tparam_variance in
        type_ tcopt root variance env ty
      end env variancel tyl
  | Ttuple tyl ->
      type_list tcopt root variance env tyl
  (* when we add type params to type consts might need to change *)
  | Taccess _ -> env
  | Tshape (_, ty_map) ->
      Nast.ShapeMap.fold begin fun _field_name ty env ->
        type_ tcopt root variance env ty
      end ty_map env

(* `as` constraints on method type parameters must be contravariant
 * and `super` constraints on method type parameters are covariant. To
 * see why, suppose that we allow the wrong variance:
 *
 *   class Foo<+T> {
 *     public function bar<Tu as T>(Tu $x) {}
 *   }
 *
 * Let A and B be classes, with B a subtype of A. Then
 *
 *   function f(Foo<A> $x) {
 *     $x->(new A());
 *   }
 *
 * typechecks. However, covariance means that we could call `f()` with an
 * instance of B. However, B::bar would expect its argument $x to be a subtype
 * of B, but we would be passing an instance of A to it, which should be a type
 * error. In other words, `as` constraints are upper type bounds, and since
 * subtypes must have more relaxed constraints than their supertypes, `as`
 * constraints must be contravariant. (Reversing this argument shows that
 * `super` constraints must be covariant.)
 *
 * The preceding discussion might lead one to think that the constraints should
 * have the same variance as the class parameter types, i.e. that `as`
 * constraints used in the return type should be covariant. In particular,
 * suppose
 *
 *   class Foo<-T> {
 *     public function bar<Tu as T>(Tu $x): Tu { ... }
 *     public function baz<Tu as T>(): Tu { ... }
 *   }
 *
 *   class A {}
 *   class B extends A {
 *     public function qux() {}
 *   }
 *
 *   function f(Foo<B> $x) {
 *     $x->baz()->qux();
 *   }
 *
 * Now `f($x)` could be a runtime error if `$x` was an instance of Foo<A>, and
 * it seems like we should enforce covariance on Tu. However, the real problem
 * is that constraints apply to _instantiation_, not usage. As far as Hack
 * knows, $x->bar() could be of any type, since we have not provided any clues
 * about how `Tu` should be instantiated. In fact `$x->bar()->whatever()`
 * succeeds as well, because `Tu` is of type Tany -- though in an ideal world
 * we would make it Tmixed in order to ensure soundness. Also, the signature
 * of `baz()` doesn't entirely make sense -- why constrain Tu if it it's only
 * getting used in one place?
 *
 * Thus, if one wants type safety, how `$x` _should_ be used is
 *
 *   function f(Foo<B> $x) {
 *     $x->bar(new B()))->qux();
 *   }
 *
 * Thus we can see that, if `$x` is used correctly (or if we enforced correct
 * use by returning Tmixed for uninstantiated type variables), we would always
 * know the exact type of Tu, and Tu can be validly used in both co- and
 * contravariant positions.
 *
 * Remark: This is far more intuitive if you think about how Vector::concat is
 * typed with its `Tu super T` type in both the parameter and return type
 * positions. Uninstantiated `super` types are less likely to cause confusion,
 * however -- you can't imagine doing very much with a returned value that is
 * some (unspecified) supertype of a class.
 *)
and constraint_ tcopt root env (ck, (r, _ as ty)) =
  let pos = Reason.to_pos r in
  let var = match ck with
    | Ast.Constraint_as -> Vcontravariant [pos, Rconstraint_as, Pcontravariant]
    | Ast.Constraint_eq ->
      let reasons = [pos, Rconstraint_eq, Pinvariant] in
      Vinvariant (reasons, reasons)
    | Ast.Constraint_super -> Vcovariant [pos, Rconstraint_super, Pcovariant]
  in
  type_ tcopt root var env ty
