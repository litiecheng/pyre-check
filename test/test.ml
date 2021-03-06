(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core
open OUnit2

open Analysis
open Ast
open Pyre
open PyreParser


let () =
  Log.initialize_for_tests ();
  Statistics.disable ();
  Type.Cache.disable ();
  Service.Scheduler.mock () |> ignore


let parse_untrimmed
    ?(path = "test.py")
    ?(qualifier = [])
    ?(debug = true)
    ?(strict = false)
    ?(declare = false)
    ?(version = 3)
    ?(autogenerated = false)
    ?(silent = false)
    ?(docstring = None)
    ?(ignore_lines = [])
    source =
  let buffer = Lexing.from_string (source ^ "\n") in
  buffer.Lexing.lex_curr_p <- {
    buffer.Lexing.lex_curr_p with
    Lexing.pos_fname = path;
  };
  try
    let source =
      let state = Lexer.State.initial () in
      let metadata =
        Source.Metadata.create
          ~autogenerated
          ~debug
          ~declare
          ~ignore_lines
          ~strict
          ~version
          ~number_of_lines:(-1)
          ()
      in
      Source.create
        ~docstring
        ~metadata
        ~path
        ~qualifier
        (ParserGenerator.parse (Lexer.read state) buffer)
    in
    source
  with
  | Pyre.ParserError _
  | ParserGenerator.Error ->
      let location =
        Location.create
          ~start:buffer.Lexing.lex_curr_p
          ~stop:buffer.Lexing.lex_curr_p
      in
      let line = location.Location.start.Location.line - 1
      and column = location.Location.start.Location.column in

      let header =
        Format.asprintf
          "\nCould not parse test at %a"
          Location.pp location
      in
      let indicator =
        if column > 0 then (String.make (column - 1) ' ') ^ "^" else "^" in
      let error =
        match List.nth (String.split source ~on:'\n') line with
        | Some line -> Format.asprintf "%s:\n  %s\n  %s" header line indicator
        | None -> header ^ "." in
      if not silent then
        Printf.printf "%s" error;
      failwith "Could not parse test"


let trim_extra_indentation source =
  let is_non_empty line =
    not (String.for_all ~f:Char.is_whitespace line) in
  let minimum_indent lines =
    let indent line =
      String.to_list line
      |> List.take_while ~f:Char.is_whitespace
      |> List.length in
    List.filter lines ~f:is_non_empty
    |> List.map ~f:indent
    |> List.fold ~init:Int.max_value ~f:Int.min in
  let strip_line minimum_indent line =
    if not (is_non_empty line) then
      line
    else
      String.slice line minimum_indent (String.length line) in
  let strip_lines minimum_indent = List.map ~f:(strip_line minimum_indent) in
  let lines =
    String.rstrip source
    |> String.split ~on:'\n' in
  let minimum_indent = minimum_indent lines in
  strip_lines minimum_indent lines
  |> String.concat ~sep:"\n"


let parse
    ?(path = "test.py")
    ?(qualifier = [])
    ?(debug = true)
    ?(version = 3)
    ?(docstring = None)
    ?local_mode
    source =
  let ({ Source.metadata; _ } as source) =
    trim_extra_indentation source
    |> parse_untrimmed ~path ~qualifier ~debug ~version ~docstring
  in
  match local_mode with
  | Some local_mode ->
      { source with Source.metadata = { metadata with Source.Metadata.local_mode } }
  | _ ->
      source

let parse_list named_sources =
  let create_file (name, source) =
    File.create
      ~content:(Some (trim_extra_indentation source))
      (Path.create_relative ~root:(Path.current_working_directory ()) ~relative:name)
  in
  Service.Parser.parse_sources_list
    ~configuration:(Configuration.create ~source_root:(Path.current_working_directory ()) ())
    ~scheduler:(Service.Scheduler.mock ())
    ~files:(List.map ~f:create_file named_sources)

let parse_single_statement source =
  match parse source with
  | { Source.statements = [statement]; _ } -> statement
  | _ -> failwith "Could not parse single statement"


let parse_last_statement source =
  match parse source with
  | { Source.statements; _ } when List.length statements > 0 ->
      List.last_exn statements
  | _ -> failwith "Could not parse last statement"


let parse_single_define source =
  match parse_single_statement source with
  | { Node.value = Statement.Define define; _ } -> define
  | { Node.value = Statement.Stub (Statement.Stub.Define define); _ } -> define
  | _ -> failwith "Could not parse single define"


let parse_single_class source =
  match parse_single_statement source with
  | { Node.value = Statement.Class definition; _ } -> definition
  | _ -> failwith "Could not parse single define"


let parse_single_expression source =
  match parse_single_statement source with
  | { Node.value = Statement.Expression expression; _ } -> expression
  | _ -> failwith "Could not parse single expression."


let parse_single_access source =
  match parse_single_expression source with
  | { Node.value = Expression.Access access; _ } -> access
  | _ -> failwith "Could not parse single access"


let parse_callable callable =
  parse_single_expression callable
  |> Type.create ~aliases:(fun _ -> None)


let diff ~print format (left, right) =
  let escape string =
    String.substr_replace_all string ~pattern:"\"" ~with_:"\\\""
    |> String.substr_replace_all ~pattern:"`" ~with_:"'"
    |> String.substr_replace_all ~pattern:"$" ~with_:"?"
  in
  let input =
    Format.sprintf
      "bash -c \"diff -u <(echo \\\"%s\\\") <(echo \\\"%s\\\")\""
      (escape (Format.asprintf "%a" print left))
      (escape (Format.asprintf "%a" print right))
    |> Unix.open_process_in in
  Format.fprintf format "\n%s" (In_channel.input_all input);
  In_channel.close input


let assert_source_equal =
  assert_equal
    ~cmp:Source.equal
    ~printer:(fun source -> Format.asprintf "%a" Source.pp source)
    ~pp_diff:(diff ~print:Source.pp)


let add_defaults_to_environment environment_handler =
  let source =
    parse {|
      class unittest.mock.Base: ...
      class unittest.mock.Mock(unittest.mock.Base): ...
      class unittest.mock.NonCallableMock: ...
    |};
  in
  Service.Environment.populate environment_handler [source]


(* Expression helpers. *)
let (~+) value =
  Node.create_with_default_location value


let (~~) = Identifier.create


let (!) name =
  let open Expression in
  +Access (Access.create name)


let (!!) name =
  +Statement.Expression !name


(* Assertion helpers. *)
let assert_true =
  assert_bool ""


let assert_false test =
  assert_bool "" (not test)


let assert_is_some test =
  assert_true (Option.is_some test)


let assert_is_none test =
  assert_true (Option.is_none test)


let assert_unreached () =
  assert_true false


let mock_path path =
  Path.create_relative ~root:(Path.current_working_directory ()) ~relative:path


(* Override `OUnit`s functions the return absolute paths. *)
let bracket_tmpdir ?suffix context =
  bracket_tmpdir ?suffix context
  |> Filename.realpath


let bracket_tmpfile ?suffix context =
  bracket_tmpfile ?suffix context
  |> (fun (filename, channel) -> Filename.realpath filename, channel)
