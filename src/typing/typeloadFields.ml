(*
	The Haxe Compiler
	Copyright (C) 2005-2019  Haxe Foundation

	This program is free software; you can redistribute it and/or
	modify it under the terms of the GNU General Public License
	as published by the Free Software Foundation; either version 2
	of the License, or (at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with this program; if not, write to the Free Software
	Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 *)

(* Logic for building fields. *)

open Globals
open Ast
open Type
open Typecore
open Typeload
open DisplayTypes
open DisplayMode
open CompletionItem.ClassFieldOrigin
open Common
open Error

type class_init_ctx = {
	tclass : tclass; (* I don't trust ctx.c.curclass because it's mutable. *)
	is_lib : bool;
	is_core_api : bool;
	is_class_debug : bool;
	extends_public : bool;
	abstract : tabstract option;
	mutable has_display_field : bool;
	mutable delayed_expr : (typer * tlazy ref option) list;
	mutable force_constructor : bool;
	mutable uninitialized_final : tclass_field list;
}

type field_init_ctx = {
	is_inline : bool;
	is_final : bool;
	is_static : bool;
	default : pos option;
	override : pos option;
	overload : pos option;
	is_extern : bool;
	is_abstract : bool;
	is_macro : bool;
	is_abstract_member : bool;
	is_display_field : bool;
	is_field_debug : bool;
	is_generic : bool;
	field_kind : class_field_ref_kind;
	display_modifier : placed_access option;
	mutable do_bind : bool;
	(* If true, cf_expr = None makes a difference in the logic. We insert a dummy expression in
	   display mode in order to address this. *)
	mutable expr_presence_matters : bool;
	mutable had_error : bool;
}

type method_kind =
	| MKNormal
	| MKGetter
	| MKSetter

module FieldError = struct
	let maybe_display_error com fctx s p =
		if not fctx.had_error then begin
			fctx.had_error <- true;
			display_error com s p
		end

	let invalid_modifier_combination fctx com fctx a b p =
		maybe_display_error com fctx (Printf.sprintf "Invalid modifier combination: %s + %s" a b) p

	let invalid_modifier com fctx m c p =
		maybe_display_error com fctx (Printf.sprintf "Invalid modifier: %s on %s" m c) p

	let invalid_modifier_only com fctx m c p =
		maybe_display_error com fctx (Printf.sprintf "Invalid modifier: %s is only supported %s" m c) p

	let invalid_modifier_on_property com fctx m p =
		maybe_display_error com fctx (Printf.sprintf "Invalid modifier: %s is not supported on properties" m) p

	let missing_expression com fctx reason p =
		maybe_display_error com fctx (Printf.sprintf "%s" reason) p

	let unexpected_expression com fctx reason p =
		maybe_display_error com fctx (Printf.sprintf "%s" reason) p
end

open FieldError

let dump_class_context cctx =
	Printer.s_record_fields "" [
		"tclass",Printer.s_tclass "\t" cctx.tclass;
		"is_lib",string_of_bool cctx.is_lib;
		"is_core_api",string_of_bool cctx.is_core_api;
		"is_class_debug",string_of_bool cctx.is_class_debug;
		"extends_public",string_of_bool cctx.extends_public;
		"abstract",Printer.s_opt (Printer.s_tabstract "\t") cctx.abstract;
		"force_constructor",string_of_bool cctx.force_constructor;
	]

let dump_field_context fctx =
	Printer.s_record_fields "" [
		"is_inline",string_of_bool fctx.is_inline;
		"is_static",string_of_bool fctx.is_static;
		"is_extern",string_of_bool fctx.is_extern;
		"is_macro",string_of_bool fctx.is_macro;
		"is_abstract_member",string_of_bool fctx.is_abstract_member;
		"is_display_field",string_of_bool fctx.is_display_field;
		"is_field_debug",string_of_bool fctx.is_field_debug;
		"field_kind",s_class_field_ref_kind fctx.field_kind;
		"do_bind",string_of_bool fctx.do_bind;
		"expr_presence_matters",string_of_bool fctx.expr_presence_matters;
	]

let is_java_native_function ctx meta pos = try
	match Meta.get Meta.Native meta with
		| (Meta.Native,[],_) ->
			warning ctx WDeprecated "@:native metadata for jni functions is deprecated. Use @:java.native instead." pos;
			true
		| _ -> false
	with | Not_found -> Meta.has Meta.NativeJni meta

(**** end of strict meta handling *****)

let get_method_args field =
	match field.cf_expr with
		| Some { eexpr = TFunction { tf_args = args } } -> args
		| _ -> raise Not_found

(**
	Get super constructor data required for @:structInit descendants.
*)
let get_struct_init_super_info ctx c p =
	match c.cl_super with
		| Some ({ cl_constructor = Some ctor } as csup, cparams) ->
			let args = (try get_method_args ctor with Not_found -> []) in
			let tl_rev,el_rev =
				List.fold_left (fun (args,exprs) (v,value) ->
					let opt = match value with
						| Some _ -> true
						| None -> Meta.has Meta.Optional v.v_meta
					in
					let t = if opt then ctx.t.tnull v.v_type else v.v_type in
					(v.v_name,opt,t) :: args,(mk (TLocal v) v.v_type p) :: exprs
				) ([],[]) args
			in
			let super_expr = mk (TCall (mk (TConst TSuper) (TInst (csup,cparams)) p, List.rev el_rev)) ctx.t.tvoid p in
			(args,Some super_expr,List.rev tl_rev)
		| _ ->
			[],None,[]

(**
	Generates a constructor for a @:structInit class `c` if it does not have one yet.
*)
let ensure_struct_init_constructor ctx c ast_fields p =
	match c.cl_constructor with
	| Some _ ->
		()
	| None ->
		let field_has_default_expr field_name =
			List.exists
				(fun ast_field ->
					match ast_field.cff_name with
						| (name, _) when name <> field_name -> false
						| _ ->
							match ast_field.cff_kind with
								| FVar (_, Some _) | FProp (_, _, _, Some _) -> true
								| _ -> false
				)
				ast_fields
		in
		let super_args,super_expr,super_tl = get_struct_init_super_info ctx c p in
		let params = extract_param_types c.cl_params in
		let ethis = mk (TConst TThis) (TInst(c,params)) p in
		let doc_buf = Buffer.create 0 in
		let args,el,tl = List.fold_left (fun (args,el,tl) cf -> match cf.cf_kind with
			| Var { v_write = AccNever } -> args,el,tl
			| Var _ ->
				let has_default_expr = field_has_default_expr cf.cf_name in
				let opt = has_default_expr || (Meta.has Meta.Optional cf.cf_meta) in
				let t = if opt then ctx.t.tnull cf.cf_type else cf.cf_type in
				let v = alloc_var VGenerated cf.cf_name t cf.cf_name_pos in
				let ef = mk (TField(ethis,FInstance(c,params,cf))) cf.cf_type p in
				let ev = mk (TLocal v) v.v_type p in
				if opt && not (Meta.has Meta.Optional v.v_meta) then
					v.v_meta <- (Meta.Optional,[],null_pos) :: v.v_meta;
				(* this.field = <constructor_argument> *)
				let assign_expr = mk (TBinop(OpAssign,ef,ev)) cf.cf_type p in
				let e =
					if has_default_expr then
						begin
							(* <constructor_argument> != null *)
							let condition = mk (TBinop(OpNotEq, ev, (null t p))) ctx.t.tbool p in
							(* if(<constructor_argument> != null) this.field = <constructor_argument> *)
							mk (TIf(condition, assign_expr, None)) ctx.t.tvoid p
						end
					else
						assign_expr
				in
				begin match gen_doc_text_opt cf.cf_doc with
				| None ->
					()
				| Some doc ->
					Buffer.add_string doc_buf "@param ";
					Buffer.add_string doc_buf cf.cf_name;
					Buffer.add_string doc_buf " ";
					let doc = ExtString.String.trim doc in
					Buffer.add_string doc_buf doc;
					Buffer.add_string doc_buf "\n";
				end;
				(v,None) :: args,e :: el,(cf.cf_name,opt,t) :: tl
			| Method _ ->
				args,el,tl
		) ([],[],[]) (List.rev c.cl_ordered_fields) in
		let el = match super_expr with Some e -> e :: el | None -> el in
		let tf = {
			tf_args = args @ super_args;
			tf_type = ctx.t.tvoid;
			tf_expr = mk (TBlock el) ctx.t.tvoid p
		} in
		let e = mk (TFunction tf) (TFun(tl @ super_tl,ctx.t.tvoid)) p in
		let cf = mk_field "new" e.etype p null_pos in
		cf.cf_doc <- doc_from_string (Buffer.contents doc_buf);
		cf.cf_expr <- Some e;
		cf.cf_type <- e.etype;
		cf.cf_meta <- [Meta.CompilerGenerated,[],null_pos; Meta.InheritDoc,[],null_pos];
		cf.cf_kind <- Method MethNormal;
		c.cl_constructor <- Some cf;
		delay ctx.g PTypeField (fun() -> InheritDoc.build_class_field_doc ctx (Some c) cf)

let transform_abstract_field com this_t a_t a f =
	let stat = List.mem_assoc AStatic f.cff_access in
	let p = f.cff_pos in
	match f.cff_kind with
	| FProp ((("get" | "never"),_),(("set" | "never"),_),_,_) when not stat ->
		f
	| FProp _ when not stat && not (List.mem_assoc AEnum f.cff_access) ->
		raise_typing_error "Member property accessors must be get/set or never" p;
	| FFun fu when fst f.cff_name = "new" && not stat ->
		let init p = (EVars [mk_evar ~t:this_t ~meta:([Meta.This,[],null_pos]) ("this",null_pos)],p) in
		let cast e = (ECast(e,None)),pos e in
		let ret p = (EReturn (Some (cast (EConst (Ident "this"),p))),p) in
		let meta = (Meta.NoCompletion,[],null_pos) :: f.cff_meta in
		if Meta.has Meta.MultiType a.a_meta then begin
			if List.mem_assoc AInline f.cff_access then raise_typing_error "inline on MultiType constructor" f.cff_pos;
			if fu.f_expr <> None then display_error com "MultiType constructors cannot have a body" f.cff_pos;
			f.cff_access <- (AExtern,null_pos) :: f.cff_access;
		end;
		(try
			let _, p = List.find (fun (acc, _) -> acc = AMacro) f.cff_access in
			raise_typing_error "Invalid modifier: macro on abstract constructor" p
		with Not_found -> ());
		(* We don't want the generated expression positions to shadow the real code. *)
		let p = { p with pmax = p.pmin } in
		let fu = {
			fu with
			f_expr = (match fu.f_expr with
			| None -> None
			| Some (EBlock el,_) -> Some (EBlock (init p :: el @ [ret p]),p)
			| Some e -> Some (EBlock [init p;e;ret p],p)
			);
			f_type = Some a_t;
		} in
		{ f with cff_name = "_new",pos f.cff_name; cff_kind = FFun fu; cff_meta = meta }
	| FFun fu when not stat ->
		if Meta.has Meta.From f.cff_meta then raise_typing_error "@:from cast functions must be static" f.cff_pos;
		{ f with cff_kind = FFun fu }
	| _ ->
		f

type enum_abstract_mode =
	| EAString
	| EAInt of int ref
	| EAOther

type enum_constructor_visibility =
	| VUnknown
	| VPublic of placed_access
	| VPrivate of placed_access

let build_enum_abstract ctx c a fields p =
	let mode =
		if does_unify a.a_this ctx.t.tint then EAInt (ref 0)
		else if does_unify a.a_this ctx.t.tstring then EAString
		else EAOther
	in
	let set_field field ct e =
		field.cff_access <- (AInline,null_pos) :: field.cff_access;
		let e = (ECast(e,None),(pos e)) in
		field.cff_kind <- FVar(ct,Some e)
	and field_is_set field =
		match field.cff_kind with
		| FVar(Some _, Some ((ECast _),_)) -> List.exists (fun (access,_) -> access = AInline) field.cff_access
		| _ -> false
	in
	List.iter (fun field ->
		match field.cff_kind with
		| FVar(ct,eo) when not (List.mem_assoc AStatic field.cff_access) && not (field_is_set field) ->
			let check_visibility_conflict visibility p1 =
				match visibility with
				| VUnknown ->
					()
				| VPublic(access,p2) | VPrivate(access,p2) ->
					display_error ctx.com (Printf.sprintf "Conflicting access modifier %s" (Ast.s_access access)) p1;
					display_error ~depth:1 ctx.com "Conflicts with this" p2;
			in
			let rec loop visibility acc = match acc with
				| (AExtern,p) :: acc ->
					display_error ctx.com "Invalid modifier: extern on field of enum abstract" p;
					loop visibility acc
				| (APrivate,p) as access :: acc ->
					check_visibility_conflict visibility p;
					loop (VPrivate access) acc
				| (APublic,p) as access :: acc ->
					check_visibility_conflict visibility p;
					loop (VPublic access) acc
				| _ :: acc ->
					loop visibility acc
				| [] ->
					visibility
			in
			let visibility = loop VUnknown field.cff_access in
			field.cff_access <- (AEnum,null_pos) :: [match visibility with VPublic acc | VPrivate acc -> acc | VUnknown -> (APublic,null_pos)];
			field.cff_meta <- (Meta.Enum,[],null_pos) :: field.cff_meta;
			let ct = match ct with
				| Some _ -> ct
				| None -> Some (TExprToExpr.convert_type (TAbstract(a,extract_param_types a.a_params)),null_pos)
			in
			begin match eo with
				| None ->
					if not (has_class_flag c CExtern) then begin match mode with
						| EAString ->
							set_field field ct (EConst (String (fst field.cff_name,SDoubleQuotes)),null_pos)
						| EAInt i ->
							set_field field ct (EConst (Int (string_of_int !i, None)),null_pos);
							incr i;
						| EAOther ->
							display_error ctx.com "Value required" field.cff_pos
					end else field.cff_kind <- FProp(("default",null_pos),("never",null_pos),ct,None)
				| Some e ->
					begin match mode,e with
						| EAInt i,(EConst(Int (s, None)),_) ->
							begin try
								let i' = int_of_string s in
								i := (i' + 1)
							with _ ->
								()
							end
						| _ -> ()
					end;
					set_field field ct e
			end
		| _ ->
			()
	) fields;
	EVars [mk_evar ~t:(CTAnonymous fields,p) ("",null_pos)],p

let resolve_type_import ctx p i =
	try
		let mt,_ = ctx.m.import_resolution#find_type_import i in
		let path = t_path mt in
		snd path :: (List.rev (fst path))
	with Not_found ->
		[i]

let build_module_def ctx mt meta fvars fbuild =
	let is_typedef = match mt with TTypeDecl _ -> true | _ -> false in
	let loop f_build = function
		| Meta.Build,args,p when not is_typedef -> (fun () ->
				let epath, el = (match args with
					| [ECall (epath,el),p] -> epath, el
					| _ -> raise_typing_error "Invalid build parameters" p
				) in
				let cpath, meth =
					let sl = try string_list_of_expr_path_raise ~root_cb:(resolve_type_import ctx p) epath with Exit -> raise_typing_error "Build call parameter must be a class path" p in
					match sl with
					| meth :: name :: pack ->
						(List.rev pack,name), meth
					| _ ->
						raise_typing_error "Invalid macro path" p
				in
				if ctx.com.is_macro_context then raise_typing_error "You cannot use @:build inside a macro : make sure that your type is not used in macro" p;
				let old = ctx.c.get_build_infos in
				ctx.c.get_build_infos <- (fun() -> Some (mt, extract_param_types (t_infos mt).mt_params, fvars()));
				let r = try ctx.g.do_macro ctx MBuild cpath meth el p with e -> ctx.c.get_build_infos <- old; raise e in
				ctx.c.get_build_infos <- old;
				(match r with
				| MError | MMacroInMacro -> raise_typing_error "Build failure" p
				| MSuccess e -> fbuild e)
			) :: f_build
		| Meta.Using,el,p -> (fun () ->
			List.iter (fun e ->
				try
					let path = List.rev (string_pos_list_of_expr_path_raise e) in
					let types,filter_classes = ImportHandling.handle_using ctx path (pos e) in
					let ti =
						match mt with
							| TClassDecl { cl_kind = KAbstractImpl a } -> t_infos (TAbstractDecl a)
							| _ -> t_infos mt
					in
					(* Delay for #10107, but use delay_late to make sure base classes run before their children do. *)
					delay_late ctx.g PConnectField (fun () ->
						ti.mt_using <- (filter_classes types) @ ti.mt_using
					)
				with Exit ->
					raise_typing_error "dot path expected" (pos e)
			) el;
		) :: f_build
		| _ ->
			f_build
	in
	(* let errors go through to prevent resume if build fails *)
	let f_build = List.fold_left loop [] meta in
	let f_enum = match mt with
		| TClassDecl ({cl_kind = KAbstractImpl a} as c) when a.a_enum ->
			Some (fun () ->
				let e = build_enum_abstract ctx c a (fvars()) a.a_name_pos in
				fbuild e;
			)
		| TClassDecl { cl_super = csup; cl_implements = interfaces; cl_kind = kind } ->
			(* Go for @:using in parents and interfaces *)
			let ti = t_infos mt in
			let inherit_using (c,_) =
				ti.mt_using <- ti.mt_using @ (t_infos (TClassDecl c)).mt_using
			in
			delay_late ctx.g PConnectField (fun () ->
				Option.may inherit_using csup;
				List.iter inherit_using interfaces;
			);
			None
		| _ ->
			None
	in
	List.iter (fun f -> f()) (List.rev f_build);
	(match f_enum with None -> () | Some f -> f())

let create_class_context c p =
	let abstract = match c.cl_kind with
		| KAbstractImpl a -> Some a
		| _ -> None
	in
	let is_lib = Meta.has Meta.LibType c.cl_meta in
	let rec extends_public c =
		Meta.has Meta.PublicFields c.cl_meta ||
		match c.cl_super with
		| None -> false
		| Some (c,_) -> extends_public c
	in
	let cctx = {
		tclass = c;
		is_lib = is_lib;
		is_core_api = Meta.has Meta.CoreApi c.cl_meta;
		is_class_debug = Meta.has (Meta.Custom ":debug.typeload") c.cl_meta;
		extends_public = extends_public c;
		abstract = abstract;
		force_constructor = false;
		uninitialized_final = [];
		delayed_expr = [];
		has_display_field = false;
	} in
	cctx

let create_typer_context_for_class ctx cctx p =
	incr stats.s_classes_built;
	let c = cctx.tclass in
	if cctx.is_lib && not (has_class_flag c CExtern) then ctx.com.error "@:libType can only be used in extern classes" c.cl_pos;
	if Meta.has Meta.Macro c.cl_meta then display_error ctx.com "Macro classes are no longer allowed in haxe 3" c.cl_pos;
	TyperManager.clone_for_class ctx c

let create_field_context ctx cctx cff is_display_file display_modifier =
	let is_static = List.mem_assoc AStatic cff.cff_access in
	let is_static,is_abstract_member = if cctx.abstract <> None && not is_static then true,true else is_static,false in
	let is_extern = ref (List.mem_assoc AExtern cff.cff_access) in
	let is_abstract = List.mem_assoc AAbstract cff.cff_access in
	let is_final = ref (List.mem_assoc AFinal cff.cff_access) in
	List.iter (fun (m,_,p) ->
		match m with
		| Meta.Final ->
			is_final := true;
			if p <> null_pos then
				warning ctx WDeprecated "`@:final` is deprecated in favor of `final`" p;
		| Meta.Extern ->
			if p <> null_pos then
				warning ctx WDeprecated "`@:extern` is deprecated in favor of `extern`" p;
			is_extern := true;
		| _ ->
			()
	) cff.cff_meta;
	let is_inline = List.mem_assoc AInline cff.cff_access in
	let override = try Some (List.assoc AOverride cff.cff_access) with Not_found -> None in
	let overload = try Some (List.assoc AOverload cff.cff_access) with Not_found -> None in
	let is_macro = List.mem_assoc AMacro cff.cff_access in
	let field_kind = match fst cff.cff_name with
		| "new" -> CfrConstructor
		| "__init__" when is_static -> CfrInit
		| _ -> if is_static then CfrStatic else CfrMember
	in
	let default = try
		let (_,_,p) = Meta.get Meta.JavaDefault cff.cff_meta in
		Some p
	with Not_found ->
		None
	in
	let c = cctx.tclass in
	let fctx = {
		is_inline = is_inline;
		is_static = is_static;
		default = default;
		override = override;
		overload = overload;
		is_macro = is_macro;
		is_extern = !is_extern;
		is_abstract = is_abstract;
		is_final = !is_final;
		is_display_field = is_display_file && DisplayPosition.display_position#enclosed_in cff.cff_pos;
		is_field_debug = cctx.is_class_debug || Meta.has (Meta.Custom ":debug.typeload") cff.cff_meta;
		display_modifier = display_modifier;
		is_abstract_member = is_abstract_member;
		is_generic = Meta.has Meta.Generic cff.cff_meta;
		field_kind = field_kind;
		do_bind = (((not ((has_class_flag c CExtern) || !is_extern) || is_inline) && not is_abstract && not (has_class_flag c CInterface)) || field_kind = CfrInit);
		expr_presence_matters = false;
		had_error = false;
	} in
	if fctx.is_display_field then cctx.has_display_field <- true;
	fctx

let create_typer_context_for_field ctx cctx fctx cff =
	DeprecationCheck.check_is ctx.com ctx.m.curmod ctx.c.curclass.cl_meta cff.cff_meta (fst cff.cff_name) cff.cff_meta (snd cff.cff_name);
	let params = if fctx.is_static && not fctx.is_abstract_member && not (Meta.has Meta.LibType cctx.tclass.cl_meta) (* TODO: remove this *) then [] else ctx.type_params in
	let ctx = TyperManager.clone_for_field ctx null_field params in

	let c = cctx.tclass in
	if (fctx.is_abstract && not (has_meta Meta.LibType c.cl_meta)) then begin
		if fctx.is_static then
			invalid_modifier_combination fctx ctx.com fctx "abstract" "static" (pos cff.cff_name)
		else if fctx.is_final then
			invalid_modifier_combination fctx ctx.com fctx "abstract" "final" (pos cff.cff_name)
		else if fctx.is_inline then
			invalid_modifier_combination fctx ctx.com fctx "abstract" "inline" (pos cff.cff_name)
		else if not (has_class_flag c CAbstract) then begin
			display_error ctx.com "This class should be declared abstract because it has at least one abstract field" c.cl_name_pos;
			display_error ctx.com "First abstract field was here" (pos cff.cff_name);
			add_class_flag c CAbstract;
		end;
	end;
	ctx

let is_public (ctx,cctx) access parent =
	let c = cctx.tclass in
	if List.mem_assoc APrivate access then
		false
	else if List.mem_assoc APublic access then
		true
	else match parent with
		| Some cf -> (has_class_field_flag cf CfPublic)
		| _ -> (has_class_flag c CExtern) || (has_class_flag c CInterface) || cctx.extends_public || (match c.cl_kind with KModuleFields _ -> true | _ -> false)

let rec get_parent c name =
	match c.cl_super with
	| None -> None
	| Some (csup,_) ->
		try
			Some (PMap.find name csup.cl_fields)
		with
			Not_found -> get_parent csup name

let transform_abstract_field2 ctx a cff =
	let a_t = TExprToExpr.convert_type' (TAbstract(a,extract_param_types a.a_params)) in
	let this_t = TExprToExpr.convert_type' a.a_this in (* TODO: better pos? *)
	transform_abstract_field ctx.com this_t a_t a cff

let transform_field (ctx,cctx) c f fields p =
	let f = match cctx.abstract with
		| Some a ->
			transform_abstract_field2 ctx a f
		| None ->
			f
	in
	if List.mem_assoc AMacro f.cff_access then
		(match ctx.g.macros with
		| Some (_,mctx) when mctx.com.module_lut#get_type_lut#mem c.cl_path ->
			(* assume that if we had already a macro with the same name, it has not been changed during the @:build operation *)
			if not (List.exists (fun f2 -> f2.cff_name = f.cff_name && List.mem_assoc AMacro f2.cff_access) (!fields)) then
				raise_typing_error "Class build macro cannot return a macro function when the class has already been compiled into the macro context" p
		| _ -> ());
	f

let type_var_field ctx t e stat do_display p =
	let e = if do_display then Display.preprocess_expr ctx.com e else e in
	let e = type_expr ctx e (WithType.with_type t) in
	let e = AbstractCast.cast_or_unify ctx t e p in
	e

let type_var_field ctx t e stat do_display p =
	let save = TypeloadFunction.save_field_state ctx in
	Std.finally save (type_var_field ctx t e stat do_display) p

let build_fields (ctx,cctx) c fields =
	let fields = ref fields in
	let get_fields() = !fields in
	let pending = ref [] in
	c.cl_build <- (fun() -> BuildMacro pending);
	build_module_def ctx (TClassDecl c) c.cl_meta get_fields (fun (e,p) ->
		match e with
		| EVars [{ ev_type = Some (CTAnonymous f,p); ev_expr = None }] ->
			let f = List.map (fun f -> transform_field (ctx,cctx) c f fields p) f in
			fields := f
		| _ -> raise_typing_error "Class build macro must return a single variable with anonymous fields" p
	);
	c.cl_build <- (fun() -> Building [c]);
	List.iter (fun f -> f()) !pending;
	!fields

let check_field_display ctx fctx c cf =
	if fctx.is_display_field then begin
		let scope, cf = match c.cl_kind with
			| KAbstractImpl _ ->
				if has_class_field_flag cf CfImpl then
					(if cf.cf_name = "_new" then
						CFSConstructor, {cf with cf_name = "new"}
					else
						CFSMember, cf)
				else
					CFSStatic, cf;
			| _ ->
				(if fctx.is_static then
					CFSStatic
				else if fctx.field_kind = CfrConstructor then
					CFSConstructor
				else
					CFSMember), cf;
		in
		let origin = match c.cl_kind with
			| KAbstractImpl a -> Self (TAbstractDecl a)
			| _ -> Self (TClassDecl c)
		in
		DisplayEmitter.maybe_display_field ctx origin scope cf cf.cf_name_pos;
		DisplayEmitter.check_field_modifiers ctx c cf fctx.override fctx.display_modifier;
	end

module TypeBinding = struct

	let bind_type ctx cctx fctx cf r p =
		let c = cctx.tclass in
		let rec is_full_type t =
			match t with
			| TFun (args,ret) -> is_full_type ret && List.for_all (fun (_,_,t) -> is_full_type t) args
			| TMono r -> (match r.tm_type with None -> false | Some t -> is_full_type t)
			| TAbstract _ | TInst _ | TEnum _ | TLazy _ | TDynamic _ | TAnon _ | TType _ -> true
		in
		let force_macro display =
			(* force macro system loading of this class in order to get completion *)
			delay ctx.g PTypeField (fun() ->
				try
					ignore(ctx.g.do_macro ctx MDisplay c.cl_path cf.cf_name [] p)
				with
				| Exit ->
					()
				| Error _ when display ->
					()
			)
		in
		let handle_display_field () =
			if fctx.is_macro && not ctx.com.is_macro_context then
				force_macro true
			else begin
				cf.cf_type <- TLazy r;
				cctx.delayed_expr <- (ctx,Some r) :: cctx.delayed_expr;
			end
		in
		if ctx.com.display.dms_full_typing then begin
			if fctx.is_macro && not ctx.com.is_macro_context then
				force_macro false
			else begin
				cf.cf_type <- TLazy r;
				cctx.delayed_expr <- (ctx,Some r) :: cctx.delayed_expr;
			end
		end else if ctx.com.display.dms_force_macro_typing && fctx.is_macro && not ctx.com.is_macro_context then
			force_macro true
		else begin
			if fctx.is_display_field then begin
				handle_display_field()
			end else begin
				if not (is_full_type cf.cf_type) then begin
					cctx.delayed_expr <- (ctx, None) :: cctx.delayed_expr;
					cf.cf_type <- TLazy r;
				end else if fctx.expr_presence_matters then
					cf.cf_expr <- Some (mk (TConst TNull) t_dynamic null_pos)
			end
		end

	let check_redefinition ctx cctx fctx cf =
		let c = cctx.tclass in
		let rec get_declared f = function
			| None -> None
			| Some (c,a) when PMap.exists f c.cl_fields ->
				Some (c,a)
			| Some (c,_) ->
				let ret = get_declared f c.cl_super in
				match ret with
					| Some r -> Some r
					| None ->
						let rec loop ifaces = match ifaces with
							| [] -> None
							| i :: ifaces -> match get_declared f (Some i) with
								| Some r -> Some r
								| None -> loop ifaces
						in
						loop c.cl_implements
		in
		if not fctx.is_static && not cctx.is_lib then begin match get_declared cf.cf_name c.cl_super with
				| None -> ()
				| Some (csup,_) ->
					display_error ctx.com ("Redefinition of variable " ^ cf.cf_name ^ " in subclass is not allowed. Previously declared at " ^ (s_type_path csup.cl_path) ) cf.cf_name_pos
		end

	let bind_var_expression ctx_f cctx fctx cf e =
		let c = cctx.tclass in
		let t = cf.cf_type in
		let p = cf.cf_pos in
		let ctx = TyperManager.clone_for_expr ctx_f (if fctx.is_static then FunStatic else FunMember) false in
		if (has_class_flag c CInterface) then unexpected_expression ctx.com fctx "Initialization on field of interface" (pos e);
		cf.cf_meta <- ((Meta.Value,[e],null_pos) :: cf.cf_meta);
		let check_cast e =
			(* insert cast to keep explicit field type (issue #1901) *)
			if type_iseq e.etype cf.cf_type then
				e
			else begin match e.eexpr,follow cf.cf_type with
				| TConst (TInt i),TAbstract({a_path=[],"Float"},_) ->
					(* turn int constant to float constant if expected type is float *)
					{e with eexpr = TConst (TFloat (Int32.to_string i)); etype = cf.cf_type}
				| _ ->
					mk_cast e cf.cf_type e.epos
			end
		in
		let r = make_lazy ~force:false ctx.g t (fun r ->
			(* type constant init fields (issue #1956) *)
			if not ctx.g.return_partial_type || (match fst e with EConst _ -> true | _ -> false) then begin
				enter_field_typing_pass ctx.g ("bind_var_expression",fst ctx.c.curclass.cl_path @ [snd ctx.c.curclass.cl_path;ctx.f.curfield.cf_name]);
				if (Meta.has (Meta.Custom ":debug.typing") (c.cl_meta @ cf.cf_meta)) then ctx.com.print (Printf.sprintf "Typing field %s.%s\n" (s_type_path c.cl_path) cf.cf_name);
				let e = type_var_field ctx t e fctx.is_static fctx.is_display_field p in
				let maybe_run_analyzer e = match e.eexpr with
					| TConst _ | TLocal _ | TFunction _ -> e
					| _ -> !analyzer_run_on_expr_ref ctx.com (Printf.sprintf "%s.%s" (s_type_path cctx.tclass.cl_path) cf.cf_name) e
				in
				let require_constant_expression e msg =
					match Optimizer.make_constant_expression ctx (maybe_run_analyzer e) with
					| Some e -> e
					| None -> display_error ctx.com msg p; e
				in
				let e = (match cf.cf_kind with
				| Var v when (has_class_flag c CExtern) || fctx.is_extern ->
					if not fctx.is_static then begin
						unexpected_expression ctx.com fctx "on extern non-static variable" p;
						e
					end else if not fctx.is_inline then begin
						unexpected_expression ctx.com fctx "on extern non-inline variable" p;
						e
					end else require_constant_expression e "Extern variable initialization must be a constant value"
				| Var v when not (is_physical_field cf) ->
					(* disallow initialization of non-physical fields (issue #1958) *)
					unexpected_expression ctx.com fctx "on field that is not a real variable" p; e
				| Var v when not fctx.is_static ->
					let e = begin
						let rec check_this e = match e.eexpr with
							| TConst TThis ->
								display_error ctx.com "Cannot access this or other member field in variable initialization" e.epos;
								raise Exit
							| TLocal v when (match ctx.f.vthis with Some v2 -> v == v2 | None -> false) ->
								display_error ctx.com "Cannot access this or other member field in variable initialization" e.epos;
								raise Exit
							| _ ->
							Type.iter check_this e
						in
						(try check_this e with Exit -> ());
						e
					end in
					e
				| Var v when v.v_read = AccInline && (ctx.g.doinline || is_forced_inline (Some c) cf) ->
					let e = require_constant_expression e "Inline variable initialization must be a constant value" in
					begin match c.cl_kind with
						| KAbstractImpl a when has_class_field_flag cf CfEnum && a.a_enum ->
							unify ctx t (TAbstract(a,(Monomorph.spawn_constrained_monos (fun t -> t) a.a_params))) p;
							let e1 = match e.eexpr with TCast(e1,None) -> e1 | _ -> e in
							unify ctx e1.etype a.a_this e1.epos
						| _ ->
							()
					end;
					e
				| _ ->
					e
				) in
				let e = check_cast e in
				cf.cf_expr <- Some e;
				cf.cf_type <- t;
				check_field_display ctx fctx c cf;
			end;
			t
		) "bind_var" in
		if not fctx.is_static then cctx.force_constructor <- true;
		bind_type ctx cctx fctx cf r (snd e)

	let bind_var ctx cctx fctx cf e =
		let c = cctx.tclass in
		check_redefinition ctx cctx fctx cf;
		match e with
		| None ->
			check_field_display ctx fctx c cf;
		| Some e ->
			bind_var_expression ctx cctx fctx cf e

	let bind_method ctx_f cctx fctx fmode cf t args ret e p =
		let c = cctx.tclass in
		let ctx = TyperManager.clone_for_expr ctx_f fmode true in
		let bind r =
			incr stats.s_methods_typed;
			if (Meta.has (Meta.Custom ":debug.typing") (c.cl_meta @ cf.cf_meta)) then ctx.com.print (Printf.sprintf "Typing method %s.%s\n" (s_type_path c.cl_path) cf.cf_name);
			begin match ctx.com.platform with
				| Jvm when is_java_native_function ctx cf.cf_meta cf.cf_pos ->
					if e <> None then
						warning ctx WDeprecated "@:java.native function definitions shouldn't include an expression. This behaviour is deprecated." cf.cf_pos;
					cf.cf_expr <- None;
					cf.cf_type <- t
				| _ ->
					if Meta.has Meta.DisplayOverride cf.cf_meta then DisplayEmitter.check_field_modifiers ctx c cf fctx.override fctx.display_modifier;
					let f_check = match fctx.field_kind with
						| CfrMember ->
							begin match TypeloadCheck.check_overriding ctx c cf with
							| NothingToDo ->
								(fun () -> ())
							| NormalOverride rctx ->
								(fun () ->
									TypeloadCheck.check_override_field ctx cf.cf_name_pos rctx
								)
							| OverloadOverride f ->
								f
							end
						| _ ->
							(fun () -> ())
					in
					let e = TypeloadFunction.type_function ctx args ret e fctx.is_display_field p in
					f_check();
					(* Disabled for now, see https://github.com/HaxeFoundation/haxe/issues/3033 *)
					(* List.iter (fun (v,_) ->
						if v.v_name <> "_" && has_mono v.v_type then warning ctx WTemp "Uninferred function argument, please add a type-hint" v.v_pos;
					) fargs; *)
					let tf = {
						tf_args = args#for_expr ctx;
						tf_type = ret;
						tf_expr = e;
					} in
					if fctx.field_kind = CfrInit then
						(match e.eexpr with
						| TBlock [] | TBlock [{ eexpr = TConst _ }] | TConst _ | TObjectDecl [] -> ()
						| _ -> TClass.set_cl_init c e);
					cf.cf_expr <- Some (mk (TFunction tf) t p);
					cf.cf_type <- t;
					check_field_display ctx fctx c cf;
			end;
		in
		let maybe_bind r =
			if not ctx.g.return_partial_type then bind r;
			t
		in
		let r = make_lazy ~force:false ctx.g t maybe_bind "type_fun" in
		bind_type ctx cctx fctx cf r p
end

let load_variable_type_hint ctx fctx eo p = function
	| None when eo = None ->
		missing_expression ctx.com fctx "Variable requires type-hint or initialization" p;
		t_dynamic
	| None ->
		mk_mono()
	| Some t ->
		load_type_hint ctx p LoadNormal (Some t)

let create_variable (ctx,cctx,fctx) c f t eo p =
	let is_abstract_enum_field = List.mem_assoc AEnum f.cff_access in
	if fctx.is_abstract_member && not is_abstract_enum_field then raise_typing_error "Cannot declare member variable in abstract" p;
	if fctx.is_inline && not fctx.is_static then invalid_modifier ctx.com fctx "inline" "non-static variable" p;
	if fctx.is_inline && eo = None then missing_expression ctx.com fctx "Inline variable must be initialized" p;
	let missing_initialization =
		fctx.is_final
		&& not (fctx.is_extern || (has_class_flag c CExtern) || (has_class_flag c CInterface))
		&& eo = None
	in
	if missing_initialization && fctx.is_static && fctx.is_final then
		missing_expression ctx.com fctx "Static final variable must be initialized" p;
	let t = load_variable_type_hint ctx fctx eo (pos f.cff_name) t in
	let kind = if fctx.is_inline then
		{ v_read = AccInline ; v_write = AccNever }
	else if fctx.is_final then
		{ v_read = AccNormal ; v_write = if fctx.is_static then AccNever else AccCtor }
	else
		{ v_read = AccNormal ; v_write = AccNormal }
	in
	let cf = {
		(mk_field (fst f.cff_name) ~public:(is_public (ctx,cctx) f.cff_access None) t f.cff_pos (pos f.cff_name)) with
		cf_doc = f.cff_doc;
		cf_meta = f.cff_meta;
		cf_kind = Var kind;
	} in
	if fctx.is_final then begin
		if missing_initialization && not fctx.is_static then
			cctx.uninitialized_final <- cf :: cctx.uninitialized_final;
		add_class_field_flag cf CfFinal;
	end;
	if fctx.is_extern then add_class_field_flag cf CfExtern;
	if fctx.is_abstract_member then begin
		cf.cf_meta <- ((Meta.Custom ":impl"),[],null_pos) :: cf.cf_meta;
		add_class_field_flag cf CfImpl;
	end;
	if is_abstract_enum_field then add_class_field_flag cf CfEnum;
	ctx.f.curfield <- cf;
	TypeBinding.bind_var ctx cctx fctx cf eo;
	cf

let check_abstract (ctx,cctx,fctx) a c cf fd t ret p =
	let m = mk_mono() in
	let ta = TAbstract(a,List.map (fun _ -> mk_mono()) a.a_params) in
	let tthis = if fctx.is_abstract_member || Meta.has Meta.To cf.cf_meta then monomorphs a.a_params a.a_this else a.a_this in
	let allows_no_expr = ref (Meta.has Meta.CoreType a.a_meta) in
	let allow_no_expr () = if not (has_class_field_flag cf CfExtern) then begin
		allows_no_expr := true;
		fctx.expr_presence_matters <- true;
	end in
	let handle_from () =
		let r = make_lazy ctx.g t (fun r ->
			(* the return type of a from-function must be the abstract, not the underlying type *)
			if not fctx.is_macro then (try type_eq EqStrict ret ta with Unify_error l -> raise_typing_error_ext (make_error (Unify l) p));
			match t with
				| TFun([_,_,t],_) -> t
				| TFun([(_,_,t1);(_,true,t2)],_) when is_pos_infos t2 -> t1
				| _ -> raise_typing_error ("@:from cast functions must accept exactly one argument") p
		) "@:from" in
		a.a_from_field <- (TLazy r,cf) :: a.a_from_field;
	in
	let handle_to () =
		if fctx.is_macro then invalid_modifier ctx.com fctx "macro" "cast function" p;
		let are_valid_args args =
			match args with
			| [_] -> true
			| [_; (_,true,t)] when is_pos_infos t -> true
			| _ -> false
		in
		(match cf.cf_kind, cf.cf_type with
		| Var _, _ ->
			raise_typing_error "Invalid metadata: @:to must be used on method of abstract" p
		| Method _, TFun(args, _) when not fctx.is_abstract_member && not (are_valid_args args) ->
			if not (Meta.has Meta.MultiType a.a_meta) then (* TODO: get rid of this check once multitype is removed *)
			raise_typing_error "static @:to method should have one argument" p
		| Method _, TFun(args, _) when fctx.is_abstract_member && not (are_valid_args args) ->
			if not (Meta.has Meta.MultiType a.a_meta) then (* TODO: get rid of this check once multitype is removed *)
			raise_typing_error "@:to method should have no arguments" p
		| _ -> ()
		);
		(* TODO: this doesn't seem quite right... *)
		if not (has_class_field_flag cf CfImpl) then add_class_field_flag cf CfImpl;
		let resolve_m args =
			(try unify_raise t (tfun (tthis :: args) m) cf.cf_pos with Error ({ err_message = Unify l; } as err) -> raise_typing_error_ext err);
			match follow m with
				| TMono _ when (match t with TFun(_,r) -> r == t_dynamic | _ -> false) -> t_dynamic
				| m -> m
		in
		let is_multitype_cast = Meta.has Meta.MultiType a.a_meta && not fctx.is_abstract_member in
		if is_multitype_cast && not (Meta.has Meta.MultiType cf.cf_meta) then
			cf.cf_meta <- (Meta.MultiType,[],null_pos) :: cf.cf_meta;
		let r = make_lazy ctx.g t (fun r ->
			let args = if is_multitype_cast then begin
				let ctor = try
					PMap.find "_new" c.cl_statics
				with Not_found ->
					raise_typing_error "Constructor of multi-type abstract must be defined before the individual @:to-functions are" cf.cf_pos
				in
				(* delay ctx PFinal (fun () -> unify ctx m tthis f.cff_pos); *)
				let args = match follow (monomorphs a.a_params ctor.cf_type) with
					| TFun(args,_) -> List.map (fun (_,_,t) -> t) args
					| _ -> die "" __LOC__
				in
				args
			end else
				match cf.cf_type with
				| TFun([_;(_,true,t)],_) when is_pos_infos t -> [t]
				| _ -> []
			in
			let t = resolve_m args in
			t
		) "@:to" in
		a.a_to_field <- (TLazy r, cf) :: a.a_to_field
	in
	let handle_array_access () =
		if fctx.is_macro then invalid_modifier ctx.com fctx "macro" "array-access function" p;
		a.a_array <- cf :: a.a_array;
		allow_no_expr();
	in
	let handle_resolve () =
		let targ = if fctx.is_abstract_member then tthis else ta in
		let check_fun t1 t2 =
			if not fctx.is_macro then begin
				if not (type_iseq targ t1) then raise_typing_error ("First argument type must be " ^ (s_type (print_context()) targ)) cf.cf_pos;
				if not (type_iseq ctx.t.tstring t2) then raise_typing_error ("Second argument type must be String") cf.cf_pos
			end
		in
		begin match follow t with
			| TFun((_,_,t1) :: (_,_,t2) :: args,_) when is_empty_or_pos_infos args ->
				if a.a_read <> None then raise_typing_error "Multiple resolve-read methods are not supported" cf.cf_pos;
				check_fun t1 t2;
				a.a_read <- Some cf;
			| TFun((_,_,t1) :: (_,_,t2) :: (_,_,t3) :: args,_) when is_empty_or_pos_infos args ->
				if a.a_write <> None then raise_typing_error "Multiple resolve-write methods are not supported" cf.cf_pos;
				check_fun t1 t2;
				a.a_write <- Some cf;
			| _ ->
				raise_typing_error ("Field type of resolve must be " ^ (s_type (print_context()) targ) ^ " -> String -> T") cf.cf_pos
		end;
	in
	let handle_op e = match fst e with
		| (EArrayDecl _) ->
			handle_array_access()
		| EBinop(OpAssign,_,_) ->
			raise_typing_error "Assignment overloading is not supported" p;
		| EBinop(OpAssignOp OpNullCoal,_,_)
		| EBinop(OpNullCoal,_,_) ->
			raise_typing_error "Null coalescing overloading is not supported" p;
		| ETernary(_,_,_) ->
			raise_typing_error "Ternary overloading is not supported" p;
		| EBinop(op,_,_) ->
			if fctx.is_macro then invalid_modifier ctx.com fctx "macro" "operator function" p;
			let targ = if fctx.is_abstract_member then tthis else ta in
			let left_eq,right_eq =
				match follow t with
				| TFun([(_,_,t1);(_,_,t2)],_) ->
					type_iseq targ t1,type_iseq targ t2
				| TFun([(_,_,t1);(_,_,t2);(_,true,t3)],_) when is_pos_infos t3 ->
					type_iseq targ t1,type_iseq targ t2
				| _ ->
					if fctx.is_abstract_member then
						raise_typing_error ("Member @:op functions must accept exactly one argument") cf.cf_pos
					else
						raise_typing_error ("Static @:op functions must accept exactly two arguments") cf.cf_pos
			in
			if not (left_eq || right_eq) then raise_typing_error ("The left or right argument type must be " ^ (s_type (print_context()) targ)) cf.cf_pos;
			if right_eq && Meta.has Meta.Commutative cf.cf_meta then raise_typing_error ("Invalid metadata: @:commutative is only allowed if the right argument is not " ^ (s_type (print_context()) targ)) cf.cf_pos;
			a.a_ops <- (op,cf) :: a.a_ops;
			allow_no_expr();
		| EUnop(op,flag,_) ->
			if fctx.is_macro then invalid_modifier ctx.com fctx "macro" "operator function" p;
			let targ = if fctx.is_abstract_member then tthis else ta in
			(try type_eq EqStrict t (tfun [targ] (mk_mono())) with Unify_error l -> raise_error_msg (Unify l) cf.cf_pos);
			a.a_unops <- (op,flag,cf) :: a.a_unops;
			allow_no_expr();
		| ECall _ ->
			begin match a.a_call with
			| None ->
				a.a_call <- Some cf
			| Some cf' ->
				cf'.cf_overloads <- cf :: cf'.cf_overloads
			end;
			allow_no_expr();
		| EField _ ->
			handle_resolve()
		| _ ->
			raise_typing_error ("Invalid @:op expresssions, should be an operator or a call") (pos e)
	in
	let check_meta m = match m with
		| (Meta.From,_,_) ->
			handle_from()
		| (Meta.To,_,_) ->
			handle_to()
		| (Meta.Op,[e],_) ->
			handle_op e
		| (Meta.ArrayAccess,_,_) ->
			handle_array_access()
		| (Meta.Resolve,_,_) ->
			handle_resolve()
		| _ -> ();
	in
	List.iter check_meta cf.cf_meta;
	if cf.cf_name = "_new" && Meta.has Meta.MultiType a.a_meta then fctx.do_bind <- false;
	if fd.f_expr = None then begin
		if fctx.is_inline then missing_expression ctx.com fctx "Inline functions must have an expression" cf.cf_pos;
		if fd.f_type = None then raise_typing_error ("Functions without expressions must have an explicit return type") cf.cf_pos;
		if !allows_no_expr then begin
			cf.cf_meta <- (Meta.NoExpr,[],null_pos) :: cf.cf_meta;
			fctx.do_bind <- false;
		end
	end

let type_opt (ctx,cctx,fctx) p mode t =
	let c = cctx.tclass in
	let is_truly_extern =
		(has_class_flag c CExtern || fctx.is_extern)
		&& not fctx.is_inline (* if it's inline, we can infer the type from the expression *)
	in
	match t with
	| None when is_truly_extern || (has_class_flag c CInterface) ->
		display_error ctx.com "Type required for extern classes and interfaces" p;
		t_dynamic
	| None when cctx.is_core_api ->
		display_error ctx.com "Type required for core api classes" p;
		t_dynamic
	| None when fctx.is_abstract ->
		display_error ctx.com "Type required for abstract functions" p;
		t_dynamic
	| _ ->
		Typeload.load_type_hint ctx p mode t

let setup_args_ret ctx cctx fctx name fd p =
	let c = cctx.tclass in
	let mk = lazy (
		if String.length name < 4 then
			MKNormal
		else match String.sub name 0 4 with
		| "get_" ->
			begin match fd.f_args with
			| [] -> MKGetter
			| _ -> MKNormal
			end
		| "set_" ->
			begin match fd.f_args with
			| [_] -> MKSetter
			| _ -> MKNormal
			end
		| _ ->
			MKNormal
	) in
	let try_find_property_type () =
		let name = String.sub name 4 (String.length name - 4) in
		let cf = if fctx.is_static then PMap.find name c.cl_statics else PMap.find name c.cl_fields (* TODO: inheritance? *) in
		match Lazy.force mk, cf.cf_kind with
			| MKGetter, Var({v_read = AccCall}) | MKSetter, Var({v_write = AccCall}) -> cf.cf_type
			| _ -> raise Not_found;
	in
	let maybe_use_property_type th check def =
		if th = None && check() then
			try
				try_find_property_type()
			with Not_found ->
				def()
		else
			def()
	in
	let ret = if fctx.field_kind = CfrConstructor then
		ctx.t.tvoid
	else begin
		let def () =
			type_opt (ctx,cctx,fctx) p LoadReturn fd.f_type
		in
		maybe_use_property_type fd.f_type (fun () -> match Lazy.force mk with MKGetter | MKSetter -> true | _ -> false) def
	end in
	let abstract_this = match cctx.abstract with
		| Some a when fctx.is_abstract_member && name <> "_new" (* TODO: this sucks *) && not fctx.is_macro ->
			Some a.a_this
		| _ ->
			None
	in
	let is_extern = fctx.is_extern || has_class_flag ctx.c.curclass CExtern in
	let type_arg i opt cto p =
		let def () =
			type_opt (ctx,cctx,fctx) p LoadNormal cto
		in
		if i = 0 then maybe_use_property_type cto (fun () -> match Lazy.force mk with MKSetter -> true | _ -> false) def else def()
	in
	let args = new FunctionArguments.function_arguments ctx.com type_arg is_extern fctx.is_display_field abstract_this fd.f_args in
	args,ret

let create_method (ctx,cctx,fctx) c f fd p =
	let name = fst f.cff_name in
	let params = TypeloadFunction.type_function_params ctx fd TPHMethod name p in
	if fctx.is_generic then begin
		if params = [] then raise_typing_error "Generic functions must have type parameters" p;
	end;
	let fd = if fctx.is_macro && not ctx.com.is_macro_context && not fctx.is_static then
		(* remove display of first argument which will contain the "this" expression *)
		{ fd with f_args = match fd.f_args with [] -> [] | _ :: l -> l }
	else
		fd
	in
	let fd = if not fctx.is_macro then
		fd
	else begin
		if ctx.com.is_macro_context then begin
			(* a class with a macro cannot be extern in macro context (issue #2015) *)
			remove_class_flag c CExtern;
			let texpr = make_ptp_ct (mk_type_path (["haxe";"macro"],"Expr")) null_pos in
			(* ExprOf type parameter might contain platform-specific type, let's replace it by Expr *)
			let no_expr_of (t,p) = match t with
				| CTPath { path = {tpackage = ["haxe";"macro"]; tname = "Expr"; tsub = Some ("ExprOf"); tparams = [TPType _] }}
				| CTPath { path = {tpackage = []; tname = ("ExprOf"); tsub = None; tparams = [TPType _] }} -> Some (texpr,p)
				| t -> Some (t,p)
			in
			{
				f_params = fd.f_params;
				f_type = (match fd.f_type with None -> Some (texpr,null_pos) | Some t -> no_expr_of t);
				f_args = List.map (fun (a,o,m,t,e) -> a,o,m,(match t with None -> Some (texpr,null_pos) | Some t -> no_expr_of t),e) fd.f_args;
				f_expr = fd.f_expr;
			}
		end else
			let tdyn = Some (make_ptp_th (mk_type_path ([],"Dynamic")) null_pos) in
			let to_dyn p ptp = match ptp.path with
				| { tpackage = ["haxe";"macro"]; tname = "Expr"; tsub = Some ("ExprOf"); tparams = [TPType t] } -> Some t
				| { tpackage = []; tname = ("ExprOf"); tsub = None; tparams = [TPType t] } -> Some t
				| { tpackage = ["haxe"]; tname = ("PosInfos"); tsub = None; tparams = [] } -> raise_typing_error "haxe.PosInfos is not allowed on macro functions, use Context.currentPos() instead" p
				| _ -> tdyn
			in
			{
				f_params = fd.f_params;
				f_type = (match fd.f_type with Some (CTPath t,p) -> to_dyn p t | _ -> tdyn);
				f_args = List.map (fun (a,o,m,t,_) -> a,o,m,(match t with Some (CTPath t,p) -> to_dyn p t | _ -> tdyn),None) fd.f_args;
				f_expr = None;
			}
	end in
	begin match (has_class_flag c CInterface),fctx.field_kind with
		| true,CfrConstructor ->
			raise_typing_error "An interface cannot have a constructor" p;
		| true,_ ->
			if not fctx.is_static && fd.f_expr <> None then unexpected_expression ctx.com fctx ("An interface method cannot have a body") p;
			if fctx.is_inline && (has_class_flag c CInterface) then invalid_modifier ctx.com fctx "inline" "method of interface" p;
		| false,CfrConstructor ->
			if fctx.is_static then invalid_modifier ctx.com fctx "static" "constructor" p;
			begin match fd.f_type with
				| None -> ()
				| Some (CTPath ({ path = {tpackage = []; tname = "Void" } as tp}),p) ->
					if ctx.m.is_display_file && DisplayPosition.display_position#enclosed_in p then
						ignore(load_instance ~allow_display:true ctx (make_ptp tp p) ParamNormal LoadReturn); (* VOIDTODO *)
				| _ -> raise_typing_error "A class constructor can't have a return type" p;
			end
		| false,_ ->
			()
	end;
	let parent = (if not fctx.is_static then get_parent c name else None) in
	let dynamic = List.mem_assoc ADynamic f.cff_access || (match parent with Some { cf_kind = Method MethDynamic } -> true | _ -> false) in
	if dynamic then begin
		if fctx.is_abstract then invalid_modifier_combination fctx ctx.com fctx "abstract" "dynamic" p;
		if fctx.is_inline then invalid_modifier_combination fctx ctx.com fctx "dynamic" "inline" p;
		if fctx.is_abstract_member then invalid_modifier ctx.com fctx "dynamic" "method of abstract" p;
	end;
	let is_override = Option.is_some fctx.override in
	if (is_override && fctx.is_static) then invalid_modifier_combination fctx ctx.com fctx "override" "static" p;

	ctx.type_params <- params @ ctx.type_params;
	let args,ret = setup_args_ret ctx cctx fctx (fst f.cff_name) fd p in
	let t = TFun (args#for_type,ret) in
	let cf = {
		(mk_field name ~public:(is_public (ctx,cctx) f.cff_access parent) t f.cff_pos (pos f.cff_name)) with
		cf_doc = f.cff_doc;
		cf_meta = f.cff_meta;
		cf_kind = Method (if fctx.is_macro then MethMacro else if fctx.is_inline then MethInline else if dynamic then MethDynamic else MethNormal);
		cf_params = params;
	} in
	if fctx.is_final then add_class_field_flag cf CfFinal;
	if fctx.is_extern then add_class_field_flag cf CfExtern;
	if fctx.is_abstract then begin
		if fctx.field_kind = CfrConstructor then begin
			let p =
				try List.assoc AAbstract f.cff_access
				with Not_found -> p
			in
			invalid_modifier ctx.com fctx "abstract" "constructor" p
		end;
		add_class_field_flag cf CfAbstract;
	end;
	if fctx.is_abstract_member then add_class_field_flag cf CfImpl;
	if fctx.is_generic then add_class_field_flag cf CfGeneric;
	begin match fctx.default with
	| Some p ->
		begin match ctx.com.platform with
		| Jvm ->
			if not (has_class_flag ctx.c.curclass CExtern) || not (has_class_flag c CInterface) then invalid_modifier_only ctx.com fctx "default" "on extern interfaces" p;
			add_class_field_flag cf CfDefault;
		| _ ->
			invalid_modifier_only ctx.com fctx "default" "on the Java target" p
		end;
	| None ->
		()
	end;
	begin match fctx.overload with
	| Some p ->
		if ctx.com.config.pf_overload then
			add_class_field_flag cf CfOverload
		else if fctx.field_kind = CfrConstructor then
			invalid_modifier ctx.com fctx "overload" "constructor" p
		else begin
			add_class_field_flag cf CfOverload;
			if not (has_class_flag c CExtern || fctx.is_extern) then
				invalid_modifier_only ctx.com fctx "overload" "on extern functions" p
		end
	| None ->
		()
	end;
	cf.cf_meta <- List.map (fun (m,el,p) -> match m,el with
		| Meta.AstSource,[] -> (m,(match fd.f_expr with None -> [] | Some e -> [e]),p)
		| _ -> m,el,p
	) cf.cf_meta;
	Option.may (fun cf_parent ->
		if not (Meta.has Meta.Native cf.cf_meta) then
			try
				let native_meta = Meta.get Meta.Native cf_parent.cf_meta in
				cf.cf_meta <- native_meta :: cf.cf_meta;
			with Not_found ->
				()
	) parent;
	generate_args_meta ctx.com (Some c) (fun meta -> cf.cf_meta <- meta :: cf.cf_meta) fd.f_args;
	let fmode = match cctx.abstract with
		| Some a ->
			check_abstract (ctx,cctx,fctx) a c cf fd t ret p;
			if fctx.is_abstract_member then FunMemberAbstract else FunStatic
		| _ ->
			if fctx.field_kind = CfrConstructor then FunConstructor else if fctx.is_static then FunStatic else FunMember
	in
	init_meta_overloads ctx (Some c) cf;
	ctx.f.curfield <- cf;
	if fctx.do_bind then
		TypeBinding.bind_method ctx cctx fctx fmode cf t args ret fd.f_expr (match fd.f_expr with Some e -> snd e | None -> f.cff_pos)
	else begin
		if fctx.is_display_field then begin
			delay ctx.g PTypeField (fun () ->
				(* We never enter type_function so we're missing out on the argument processing there. Let's do it here. *)
				let ctx = TyperManager.clone_for_expr ctx fmode true in
				ignore(args#for_expr ctx)
			);
			check_field_display ctx fctx c cf;
		end else
			delay ctx.g PTypeField (fun () ->
				let ctx = TyperManager.clone_for_expr ctx fmode true in
				args#verify_extern ctx
			);
		if fd.f_expr <> None then begin
			if fctx.is_abstract then unexpected_expression ctx.com fctx "Abstract methods may not have an expression" p
			else if not (fctx.is_inline || fctx.is_macro) then warning ctx WExternWithExpr "Extern non-inline function may not have an expression" p;
		end;
	end;
	cf

let create_property (ctx,cctx,fctx) c f (get,set,t,eo) p =
	let name = fst f.cff_name in
	let ret = (match t, eo with
		| None, None -> raise_typing_error "Property requires type-hint or initialization" p;
		| None, _ -> mk_mono()
		| Some t, _ -> load_type_hint ctx p LoadNormal (Some t)
	) in
	let t_get,t_set = match cctx.abstract with
		| Some a when fctx.is_abstract_member ->
			if Meta.has Meta.IsVar f.cff_meta then raise_typing_error "Abstract properties cannot be real variables" f.cff_pos;
			let ta = apply_params a.a_params (extract_param_types a.a_params) a.a_this in
			tfun [ta] ret, tfun [ta;ret] ret
		| _ -> tfun [] ret, TFun(["value",false,ret],ret)
	in
	let find_accessor m =
		if fctx.is_static then begin
			let cf = PMap.find m c.cl_statics in
			(cf.cf_type,cf) :: (List.map (fun cf -> cf.cf_type,cf) cf.cf_overloads)
		end else
			get_overloads ctx.com c m
	in
	let cf = {
		(mk_field name ~public:(is_public (ctx,cctx) f.cff_access None) ret f.cff_pos (pos f.cff_name)) with
		cf_doc = f.cff_doc;
		cf_meta = f.cff_meta;
	} in
	if fctx.is_abstract_member then add_class_field_flag cf CfImpl;
	let check_method m t is_getter =
		try
			let overloads = find_accessor m in
			let rec get_overload overl = match overl with
				| [tf] ->
					tf
				| (t2,f2) :: overl ->
					if type_iseq t t2 then
						(t2,f2)
					else
						get_overload overl
				| [] ->
					raise Not_found
			in
			let t2, f2 = get_overload overloads in
			f2.cf_meta <- List.fold_left (fun acc ((m,_,_) as meta) -> match m with
				| Meta.Deprecated -> meta :: acc
				| _ -> acc
			) f2.cf_meta f.cff_meta;
			(* Now that we know there is a field, we have to delay the actual unification even further. The reason is that unification could resolve
			   TLazy, which would then cause field typing before we're done with our PConnectField pass. This could cause interface fields to not
			   be generated in time. *)
			delay ctx.g PForce (fun () ->
				try
					(match f2.cf_kind with
						| Method MethMacro ->
							display_error ctx.com (f2.cf_name ^ ": Macro methods cannot be used as property accessor") p;
							display_error ~depth:1 ctx.com (compl_msg (f2.cf_name ^ ": Accessor method is here")) f2.cf_pos;
						| _ -> ());
					unify_raise t2 t f2.cf_pos;
					if (fctx.is_abstract_member && not (has_class_field_flag f2 CfImpl)) || (has_class_field_flag f2 CfImpl && not (fctx.is_abstract_member)) then
						display_error ctx.com "Mixing abstract implementation and static properties/accessors is not allowed" f2.cf_pos;
				with Error ({ err_message = Unify _ } as err) ->
					raise_error (make_error ~sub:[err] (Custom ("In method " ^ m ^ " required by property " ^ name)) err.err_pos)
			)
		with
			| Not_found ->
				let generate_field () =
					let cf = mk_field m t p null_pos in
					cf.cf_meta <- [Meta.CompilerGenerated,[],null_pos;Meta.NoCompletion,[],null_pos];
					cf.cf_kind <- Method MethNormal;
					cf
				in
				if (has_class_flag c CInterface) then begin
					let cf = generate_field () in
					c.cl_fields <- PMap.add cf.cf_name cf c.cl_fields;
					c.cl_ordered_fields <- cf :: c.cl_ordered_fields;
				end else if Diagnostics.error_in_diagnostics_run ctx.com f.cff_pos then begin
					let cf_accessor = generate_field() in
					remove_class_field_flag cf_accessor CfPublic;
					if fctx.is_static then add_class_field_flag cf_accessor CfStatic;
					let diag = {
						mf_pos = (pos f.cff_name);
						mf_on = TClassDecl c;
						mf_fields = [(cf_accessor,t,CompletionItem.CompletionType.from_type (Display.get_import_status ctx) t)];
						mf_cause = PropertyAccessor(cf,is_getter);
					} in
					let display = ctx.com.display_information in
					display.module_diagnostics <- MissingFields diag :: display.module_diagnostics
				end else if not (has_class_flag c CExtern) then begin
					try
						let _, _, f2 = (if not fctx.is_static then let f = PMap.find m c.cl_statics in None, f.cf_type, f else class_field c (extract_param_types c.cl_params) m) in
						display_error ctx.com (Printf.sprintf "Method %s is no valid accessor for %s because it is %sstatic" m (name) (if fctx.is_static then "not " else "")) f2.cf_pos
					with Not_found ->
						display_error ctx.com ("Method " ^ m ^ " required by property " ^ name ^ " is missing") p
				end
	in
	let display_accessor m p =
		try
			let cf = match find_accessor m with [_,cf] -> cf | _ -> raise Not_found in
			DisplayEmitter.display_field ctx (Self (TClassDecl c)) (if fctx.is_static then CFSStatic else CFSMember) cf p
		with Not_found ->
			()
	in
	let delay_check = delay ctx.g PConnectField in
	let get = (match get with
		| "null",_ -> AccNo
		| "dynamic",_ -> AccCall
		| "never",_ -> AccNever
		| "default",_ -> AccNormal
		| "get",pget ->
			let get = "get_" ^ name in
			if fctx.is_display_field && DisplayPosition.display_position#enclosed_in pget then delay ctx.g PConnectField (fun () -> display_accessor get pget);
			if not cctx.is_lib then delay_check (fun() -> check_method get t_get true);
			AccCall
		| _,pget ->
			display_error ctx.com (name ^ ": Custom property accessor is no longer supported, please use `get`") pget;
			AccCall
	) in
	let set = (match set with
		| "null",_ ->
			(* standard flash library read-only variables can't be accessed for writing, even in subclasses *)
			if (has_class_flag c CExtern) && (match c.cl_path with "flash" :: _	, _ -> true | _ -> false) && ctx.com.platform = Flash then
				AccNever
			else
				AccNo
		| "never",_ -> AccNever
		| "dynamic",_ -> AccCall
		| "default",_ -> AccNormal
		| "set",pset ->
			let set = "set_" ^ name in
			if fctx.is_display_field && DisplayPosition.display_position#enclosed_in pset then delay ctx.g PConnectField (fun () -> display_accessor set pset);
			if not cctx.is_lib then delay_check (fun() -> check_method set t_set false);
			AccCall
		| _,pset ->
			display_error ctx.com (name ^ ": Custom property accessor is no longer supported, please use `set`") pset;
			AccCall
	) in
	if (set = AccNever && get = AccNever)  then raise_typing_error (name ^ ": Unsupported property combination") p;
	cf.cf_kind <- Var { v_read = get; v_write = set };
	if fctx.is_extern then add_class_field_flag cf CfExtern;
	if List.mem_assoc AEnum f.cff_access then add_class_field_flag cf CfEnum;
	ctx.f.curfield <- cf;
	TypeBinding.bind_var ctx cctx fctx cf eo;
	cf

(**
	Emit compilation error on `final static function`
*)
let reject_final_static_method ctx cctx fctx f =
	if fctx.is_static && fctx.is_final && not (has_class_flag cctx.tclass CExtern) then
		let p =
			try snd (List.find (fun (a,p) -> a = AFinal) f.cff_access)
			with Not_found ->
				try match Meta.get Meta.Final f.cff_meta with _, _, p -> p
				with Not_found ->
					try snd (List.find (fun (a,p) -> a = AStatic) f.cff_access)
					with Not_found -> f.cff_pos
		in
		invalid_modifier_combination fctx ctx.com fctx "final" "static" p

let init_field (ctx,cctx,fctx) f =
	let c = cctx.tclass in
	let name = fst f.cff_name in
	TypeloadCheck.check_global_metadata ctx f.cff_meta (fun m -> f.cff_meta <- m :: f.cff_meta) c.cl_module.m_path c.cl_path (Some name);
	let p = f.cff_pos in
	if not (has_class_flag c CExtern) && not (Meta.has Meta.Native f.cff_meta) then Naming.check_field_name ctx.com name p;
	List.iter (fun acc ->
		match (fst acc, f.cff_kind) with
		| AFinal, FProp _ when not (has_class_flag c CExtern) && ctx.com.platform <> Jvm -> invalid_modifier_on_property ctx.com fctx (Ast.s_placed_access acc) (snd acc)
		| APublic, _ | APrivate, _ | AStatic, _ | AFinal, _ | AExtern, _ -> ()
		| ADynamic, FFun _ | AOverride, FFun _ | AMacro, FFun _ | AInline, FFun _ | AInline, FVar _ | AAbstract, FFun _ | AOverload, FFun _ -> ()
		| AEnum, (FVar _ | FProp _) -> ()
		| _, FVar _ -> display_error ctx.com ("Invalid accessor '" ^ Ast.s_placed_access acc ^ "' for variable " ^ name) (snd acc)
		| _, FProp _ -> display_error ctx.com ("Invalid accessor '" ^ Ast.s_placed_access acc ^ "' for property " ^ name) (snd acc)
		| _, FFun _ -> display_error ctx.com ("Invalid accessor '" ^ Ast.s_placed_access acc ^ "' for function " ^ name) (snd acc)
	) f.cff_access;
	begin match fctx.override with
		| Some _ ->
			(match c.cl_super with
			| None ->
				let p =
					try List.assoc AOverride f.cff_access
					with Not_found -> p
				in
				invalid_modifier ctx.com fctx "override" "field of class that has no parent" p
			| _ -> ()
			);
		| None -> ()
	end;
	let cf =
		match f.cff_kind with
		| FVar (t,e) ->
			create_variable (ctx,cctx,fctx) c f t e p
		| FFun fd ->
			reject_final_static_method ctx cctx fctx f;
			create_method (ctx,cctx,fctx) c f fd p
		| FProp (get,set,t,eo) ->
			create_property (ctx,cctx,fctx) c f (get,set,t,eo) p
	in
	(if (fctx.is_static || fctx.is_macro && ctx.com.is_macro_context) then add_class_field_flag cf CfStatic);
	if Meta.has Meta.InheritDoc cf.cf_meta then
		delay ctx.g PTypeField (fun() -> InheritDoc.build_class_field_doc ctx (Some c) cf);
	cf

let check_overload ctx f fs is_extern_class =
	try
		let f2 =
			List.find (fun f2 ->
				f != f2 &&
				Overloads.same_overload_args f.cf_type f2.cf_type f f2
			) fs
		in
		display_error ctx.com ("Another overloaded field of same signature was already declared : " ^ f.cf_name) f.cf_pos;
		display_error ~depth:1 ctx.com (compl_msg "The second field is declared here") f2.cf_pos;
		false
	with Not_found -> try
		if ctx.com.platform <> Jvm || is_extern_class then raise Not_found;
		let get_vmtype = ambiguate_funs in
		let f2 =
			List.find (fun f2 ->
				f != f2 &&
				Overloads.same_overload_args ~get_vmtype f.cf_type f2.cf_type f f2
			) fs
		in
		(* Don't bother checking this on externs and assume the users know what they're doing (issue #11131) *)
		if has_class_field_flag f CfExtern && has_class_field_flag f2 CfExtern then raise Not_found;
		display_error ctx.com (
			"Another overloaded field of similar signature was already declared : " ^
			f.cf_name ^
			"\nThe signatures are different in Haxe, but not in the target language"
		) f.cf_pos;
		display_error ~depth:1 ctx.com (compl_msg "The second field is declared here") f2.cf_pos;
		false
	with Not_found ->
		true

let check_overloads ctx c =
	(* check if field with same signature was declared more than once *)
	let is_extern = has_class_flag c CExtern in
	let check_field f =
		if has_class_field_flag f CfOverload then begin
			let all = f :: f.cf_overloads in
			ignore(List.fold_left (fun b f -> b && check_overload ctx f all is_extern) true all)
		end
	in
	List.iter check_field c.cl_ordered_fields;
	List.iter check_field c.cl_ordered_statics;
	Option.may check_field c.cl_constructor

let finalize_class cctx =
	(* push delays in reverse order so they will be run in correct order *)
	List.iter (fun (ctx,r) ->
		(match r with
		| None -> ()
		| Some r -> delay ctx.g PTypeField (fun() -> ignore(lazy_type r)))
	) cctx.delayed_expr

let check_functional_interface ctx c =
	match TClass.get_singular_interface_field c.cl_ordered_fields with
	| None ->
		()
	| Some cf ->
		add_class_flag c CFunctionalInterface;
		ctx.com.functional_interface_lut#add c.cl_path (c,cf)

let init_class ctx_c cctx c p herits fields =
	let com = ctx_c.com in
	if cctx.is_class_debug then print_endline ("Created class context: " ^ dump_class_context cctx);
	let fields = build_fields (ctx_c,cctx) c fields in
	if cctx.is_core_api && com.display.dms_check_core_api then delay ctx_c.g PForce (fun() -> init_core_api ctx_c c);
	if not cctx.is_lib then begin
		delay ctx_c.g PForce (fun() -> check_overloads ctx_c c);
		begin match c.cl_super with
		| Some(csup,tl) ->
			if (has_class_flag csup CAbstract) && not (has_class_flag c CAbstract) then
				delay ctx_c.g PForce (fun () -> TypeloadCheck.Inheritance.check_abstract_class ctx_c c csup tl);
		| None ->
			()
		end
	end;
	let rec has_field f = function
		| None -> false
		| Some (c,_) ->
			PMap.exists f c.cl_fields || has_field f c.cl_super || List.exists (fun i -> has_field f (Some i)) c.cl_implements
	in
	let rec check_require = function
		| [] -> None
		| (Meta.Require,conds,_) :: l ->
			let rec loop = function
				| [] -> check_require l
				| e :: l ->
					let sc = match fst e with
						| EConst (Ident s) -> s
						| EBinop ((OpEq|OpNotEq|OpGt|OpGte|OpLt|OpLte) as op,(EConst (Ident s),_),(EConst ((Int (_,_) | Float (_,_) | String _) as c),_)) -> s ^ s_binop op ^ s_constant c
						| _ -> ""
					in
					if not (ParserEntry.is_true (ParserEntry.eval com.defines e)) then
						Some (sc,(match List.rev l with (EConst (String(msg,_)),_) :: _ -> Some msg | _ -> None))
					else
						loop l
			in
			loop conds
		| _ :: l ->
			check_require l
	in
	let cl_req = check_require c.cl_meta in
	let has_init = ref false in
	List.iter (fun f ->
		let p = f.cff_pos in
		let display_modifier = Typeload.check_field_access ctx_c f in
		let fctx = create_field_context ctx_c cctx f ctx_c.m.is_display_file display_modifier in
		let ctx = create_typer_context_for_field ctx_c cctx fctx f in
		try
			if fctx.is_field_debug then print_endline ("Created field context: " ^ dump_field_context fctx);
			let cf = init_field (ctx,cctx,fctx) f in
			if fctx.field_kind = CfrInit then begin
				if !has_init then
					display_error ctx.com ("Duplicate class field declaration : " ^ (s_type_path c.cl_path) ^ "." ^ cf.cf_name) cf.cf_name_pos
				else
					has_init := true
			end;
			if fctx.is_field_debug then print_endline ("Created field: " ^ Printer.s_tclass_field "" cf);
			if fctx.is_static && (has_class_flag c CInterface) && fctx.field_kind <> CfrInit && not cctx.is_lib && not ((has_class_flag c CExtern)) then
				raise_typing_error "You can only declare static fields in extern interfaces" p;
			let req = check_require f.cff_meta in
			let req = (match req with None -> if fctx.is_static || fctx.field_kind = CfrConstructor then cl_req else None | _ -> req) in
			(match req with
			| None -> ()
			| Some r -> cf.cf_kind <- Var { v_read = AccRequire (fst r, snd r); v_write = AccRequire (fst r, snd r) });
			begin match fctx.field_kind with
			| CfrConstructor ->
				begin match c.cl_super with
				| Some ({ cl_constructor = Some ctor_sup } as c, _) when not (has_class_flag c CExtern) && has_class_field_flag ctor_sup CfFinal ->
					ctx.com.error "Cannot override final constructor" cf.cf_pos
				| _ -> ()
				end;
				begin match c.cl_constructor with
				| None ->
					c.cl_constructor <- Some cf
				| Some ctor when ctx.com.config.pf_overload ->
					if has_class_field_flag cf CfOverload && has_class_field_flag ctor CfOverload then
						ctor.cf_overloads <- cf :: ctor.cf_overloads
					else
						display_error ctx.com ("If using overloaded constructors, all constructors must be declared with 'overload'") (if has_class_field_flag cf CfOverload then ctor.cf_pos else cf.cf_pos)
				| Some ctor ->
						display_error ctx.com "Duplicate constructor" p
				end
			| CfrInit ->
				()
			| CfrStatic | CfrMember ->
				let dup = if fctx.is_static then PMap.exists cf.cf_name c.cl_fields || has_field cf.cf_name c.cl_super else PMap.exists cf.cf_name c.cl_statics in
				if not (has_class_flag c CExtern) && dup then raise_typing_error ("Same field name can't be used for both static and instance : " ^ cf.cf_name) p;
				if fctx.override <> None then
					add_class_field_flag cf CfOverride;
				let is_var cf = match cf.cf_kind with
					| Var {v_read = AccRequire _; v_write = AccRequire _} -> false
					| Var _ -> true
					| _ -> false
				in
				if PMap.mem cf.cf_name (if fctx.is_static then c.cl_statics else c.cl_fields) then
					if has_class_field_flag cf CfOverload && not (is_var cf) then
						let mainf = PMap.find cf.cf_name (if fctx.is_static then c.cl_statics else c.cl_fields) in
						if is_var mainf then display_error ctx.com "Cannot declare a variable with same name as a method" mainf.cf_pos;
						(if not (has_class_field_flag mainf CfOverload) then display_error ctx.com ("Overloaded methods must have 'overload' accessor") mainf.cf_pos);
						mainf.cf_overloads <- cf :: cf.cf_overloads @ mainf.cf_overloads
					else
						let type_kind,path = match c.cl_kind with
							| KAbstractImpl a -> "abstract",a.a_path
							| KModuleFields m -> "module",m.m_path
							| _ -> "class",c.cl_path
						in
						display_error ctx.com ("Duplicate " ^ type_kind ^ " field declaration : " ^ s_type_path path ^ "." ^ cf.cf_name) cf.cf_name_pos
				else
				TClass.add_field c cf
			end
		with Error ({ err_message = Custom _; err_pos = p2 } as err) when p = p2 ->
			display_error_ext ctx.com err
	) fields;
	begin match cctx.abstract with
		| Some a ->
			a.a_to_field <- List.rev a.a_to_field;
			a.a_from_field <- List.rev a.a_from_field;
			a.a_ops <- List.rev a.a_ops;
			a.a_unops <- List.rev a.a_unops;
			a.a_array <- List.rev a.a_array;
		| None ->
			if (has_class_flag c CFunctionalInterface) && com.platform = Jvm then check_functional_interface ctx_c c;
	end;
	c.cl_ordered_statics <- List.rev c.cl_ordered_statics;
	c.cl_ordered_fields <- List.rev c.cl_ordered_fields;
	delay ctx_c.g PConnectField (fun () -> match follow c.cl_type with
		| TAnon an ->
			an.a_fields <- c.cl_statics
		| _ ->
			die "" __LOC__
	);
	(*
		make sure a default contructor with same access as super one will be added to the class structure at some point.
	*)
	let has_struct_init, struct_init_pos =
		try
			let _,_,p = Meta.get Meta.StructInit c.cl_meta in
			true, p
		with Not_found ->
			false, null_pos
	in
	if has_struct_init then
		if (has_class_flag c CInterface) then
			display_error com "@:structInit is not allowed on interfaces" struct_init_pos
		else
			ensure_struct_init_constructor ctx_c c fields p;
	begin match cctx.uninitialized_final with
		| cf :: cfl when c.cl_constructor = None && not (has_class_flag c CAbstract) ->
			if Diagnostics.error_in_diagnostics_run com cf.cf_name_pos then begin
				let diag = {
					mf_pos = c.cl_name_pos;
					mf_on = TClassDecl c;
					mf_fields = [];
					mf_cause = FinalFields (cf :: cfl);
				} in
				let display = com.display_information in
				display.module_diagnostics <- MissingFields diag :: display.module_diagnostics
			end else begin
				display_error com "This class has uninitialized final vars, which requires a constructor" p;
				display_error com "Example of an uninitialized final var" cf.cf_name_pos;
			end
		| _ ->
			()
	end;
	if not has_struct_init then
		(* add_constructor does not deal with overloads correctly *)
		if not com.config.pf_overload then TypeloadFunction.add_constructor ctx_c c cctx.force_constructor p;
	finalize_class cctx
