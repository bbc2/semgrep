(*
   Convert Dockerfile-specific AST to generic AST.
*)

module PI = Parse_info
module G = AST_generic
open AST_dockerfile

type env = AST_bash.input_kind

let stmt_of_expr loc (e : G.expr) : G.stmt = G.s (G.ExprStmt (e, fst loc))

let call ((orig_name, name_tok) : string wrap) ((args_start, args_end) : Loc.t)
    (args : G.argument list) : G.expr =
  let name = (String.uppercase_ascii orig_name, name_tok) in
  let func = G.N (G.Id (name, G.empty_id_info ())) |> G.e in
  G.Call (func, (args_start, args, args_end)) |> G.e

(* Same as 'call' but assumes all the arguments are ordinary, non-optional
   arguments, specified as 'expr'. *)
let call_exprs (name : string wrap) (loc : Loc.t) (args : G.expr list) : G.expr
    =
  let args = Common.map (fun e -> G.Arg e) args in
  call name loc args

let make_hidden_function loc name : G.expr =
  let id = "!dockerfile_" ^ name ^ "!" in
  let id_info = G.empty_id_info ~hidden:true () in
  G.N (G.Id ((id, fst loc), id_info)) |> G.e

let call_shell loc (shell_compat : shell_compatibility) args =
  let shell_name =
    match shell_compat with
    | Sh -> "sh"
    | Cmd -> "cmd"
    | Powershell -> "powershell"
    | Other name -> name
  in
  let func = make_hidden_function loc shell_name in
  let args = Common.map (fun e -> G.Arg e) args in
  let args_start, args_end = loc in
  G.Call (func, (args_start, args, args_end)) |> G.e

let bracket (loc : Loc.t) x : 'a bracket =
  let start, end_ = loc in
  (start, x, end_)

let expr_of_stmt (st : G.stmt) : G.expr = G.stmt_to_expr st

let expr_of_stmts loc (stmts : G.stmt list) : G.expr =
  G.Block (bracket loc stmts) |> G.s |> expr_of_stmt

let string_expr s : G.expr = G.L (G.String s) |> G.e

let argv ((open_, args, close) : string_array) : G.expr =
  G.Container (G.Array, (open_, Common.map string_expr args, close)) |> G.e

(*
   Return the arguments to pass to the dockerfile command e.g. the arguments
   to CMD.
*)
let argv_or_shell env x : G.expr list =
  match x with
  | Argv array -> [ argv array ]
  | Sh_command (loc, x) ->
      let args = Bash_to_generic.program env x |> expr_of_stmts loc in
      [ call_shell loc Sh [ args ] ]
  | Other_shell_command (shell_compat, code) ->
      let args = [ string_expr code ] in
      let loc = wrap_loc code in
      [ call_shell loc shell_compat args ]

let opt_param_arg (x : param option) : G.argument list =
  match x with
  | None -> []
  | Some (_loc, (dashdash, (name_str, name_tok), _eq, value)) ->
      let option_tok = PI.combine_infos dashdash [ name_tok ] in
      let option_str = PI.str_of_info dashdash ^ name_str in
      [ G.ArgKwd (G.ArgOptional, (option_str, option_tok), string_expr value) ]

let from (opt_param : param option) (image_spec : image_spec) _TODO_opt_alias :
    G.argument list =
  (* TODO: metavariable for image name *)
  (* TODO: metavariable for image tag, metavariable for image digest *)
  let opt_param = opt_param_arg opt_param in
  let name = G.Arg (string_expr image_spec.name) in
  let tag =
    match image_spec.tag with
    | None -> []
    | Some (colon, tag) ->
        [ G.ArgKwd (G.ArgOptional, (":", colon), string_expr tag) ]
  in
  let digest =
    match image_spec.digest with
    | None -> []
    | Some (at, digest) ->
        [ G.ArgKwd (G.ArgOptional, ("@", at), string_expr digest) ]
  in
  opt_param @ (name :: tag) @ digest

(* Return the literal with single quotes or double quotes *)
let string_of_str = function
  | Unquoted x -> x
  | Quoted x -> x

let label_pairs (kv_pairs : label_pair list) : G.argument list =
  kv_pairs
  |> Common.map (fun (key, _eq, value) ->
         let value = string_of_str value in
         G.ArgKwd (G.ArgRequired, key, string_expr value))

let add_or_copy (opt_param : param option) (src : path) (dst : path) =
  let opt_param = opt_param_arg opt_param in
  opt_param @ [ G.Arg (string_expr src); G.Arg (string_expr dst) ]

let user_args (user : string wrap) (group : (tok * string wrap) option) =
  let user = G.Arg (string_expr user) in
  let group =
    match group with
    | None -> []
    | Some (colon, group) ->
        [ G.ArgKwd (G.ArgOptional, (":", colon), string_expr group) ]
  in
  user :: group

let rec instruction_expr env (x : instruction) : G.expr =
  match x with
  | From (loc, name, opt_param, image_spec, opt_alias) ->
      let args = from opt_param image_spec opt_alias in
      call name loc args
  | Run (loc, name, x) -> call_exprs name loc (argv_or_shell env x)
  | Cmd (loc, name, x) -> call_exprs name loc (argv_or_shell env x)
  | Label (loc, name, kv_pairs) -> call name loc (label_pairs kv_pairs)
  | Expose (loc, name, port_protos) ->
      let args = Common.map string_expr port_protos in
      call_exprs name loc args
  | Env (loc, name, pairs) -> call name loc (label_pairs pairs)
  | Add (loc, name, param, src, dst) ->
      call name loc (add_or_copy param src dst)
  | Copy (loc, name, param, src, dst) ->
      call name loc (add_or_copy param src dst)
  | Entrypoint (loc, name, x) -> call_exprs name loc (argv_or_shell env x)
  | Volume (loc, name, _) -> call name loc []
  | User (loc, name, user, group) -> call name loc (user_args user group)
  | Workdir (loc, name, dir) -> call_exprs name loc [ string_expr dir ]
  | Arg (loc, name, _) -> call name loc []
  | Onbuild (loc, name, instr) ->
      call_exprs name loc [ instruction_expr env instr ]
  | Stopsignal (loc, name, _) -> call name loc []
  | Healthcheck (loc, name, _) -> call name loc []
  | Shell (loc, name, array) -> call_exprs name loc [ argv array ]
  | Maintainer (loc, name, _) -> call name loc []
  | Cross_build_xxx (loc, name, _) -> call name loc []
  | Instr_semgrep_ellipsis tok -> G.Ellipsis tok |> G.e
  | Instr_TODO (orig_name, tok) -> call ("TODO_" ^ orig_name, tok) (tok, tok) []

let instruction env (x : instruction) : G.stmt =
  let expr = instruction_expr env x in
  stmt_of_expr (instruction_loc x) expr

let program (env : env) (x : program) : G.stmt list =
  Common.map (instruction env) x

let any (env : env) x : G.any =
  match program env x with
  | [ stmt ] -> G.S stmt
  | stmts -> G.Ss stmts
