(*pp camlp4o -I `ocamlfind query lwt.syntax` lwt-syntax-options.cma lwt-syntax.cma *)

(*
  OCaml HTTP - do it yourself (fully OCaml) HTTP daemon

  Copyright (C) <2002-2005> Stefano Zacchiroli <zack@cs.unibo.it>
  Copyright (C) <2009> Anil Madhavapeddy <anil@recoil.org>

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU Library General Public License as
  published by the Free Software Foundation, version 2.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU Library General Public License for more details.

  You should have received a copy of the GNU Library General Public
  License along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307
  USA
*)

open Printf
open Lwt

open Http_common
open Http_types
open Http_constants

let (bindings_sep, binding_sep, pieces_sep, header_sep) =
  (Pcre.regexp "&", Pcre.regexp "=", Pcre.regexp " ", Pcre.regexp ":")
let header_RE = Pcre.regexp "([^:]*):(.*)"

let url_decode url = Netencoding.Url.decode ~plus:true url

let split_query_params query =
  let bindings = Pcre.split ~rex:bindings_sep query in
  match bindings with
  | [] -> raise (Malformed_query query)
  | bindings ->
      List.map
        (fun binding ->
          match Pcre.split ~rex:binding_sep binding with
          | [ ""; b ] -> (* '=b' *)
              raise (Malformed_query_part (binding, query))
          | [ a; b ]  -> (* 'a=b' *) (url_decode a, url_decode b)
          | [ a ]     -> (* 'a=' || 'a' *) (url_decode a, "")
          | _ -> raise (Malformed_query_part (binding, query)))
        bindings

let patch_empty_path = function "" -> "/" | s -> s
let debug_dump_request path params =
  debug_print
    (sprintf
      "recevied request; path: %s; params: %s"
      path
      (String.concat ", " (List.map (fun (n, v) -> n ^ "=" ^ v) params)))

let parse_request_fst_line ic =
  lwt request_line = Lwt_io.read_line ic in
  debug_print (sprintf "HTTP request line (not yet parsed): %s" request_line);
  try_lwt begin
    match Pcre.split ~rex:pieces_sep request_line with
      | [ meth_raw; uri_raw; http_version_raw ] ->
          return (method_of_string meth_raw,
		  Http_parser_sanity.url_of_string uri_raw,
		  version_of_string http_version_raw)
      | _ -> fail (Malformed_request request_line)
  end with | Malformed_URL url -> fail (Malformed_request_URI url)

let parse_response_fst_line ic =
  lwt response_line = Lwt_io.read_line ic in
  debug_print (sprintf "HTTP response line (not yet parsed): %s" response_line);
  try_lwt
    (match Pcre.split ~rex:pieces_sep response_line with
    | version_raw :: code_raw :: _ ->
        return (version_of_string version_raw,             (* method *)
        status_of_code (int_of_string code_raw))    (* status *)
    | _ -> fail (Malformed_response response_line))
  with 
  | Malformed_URL _ | Invalid_code _ | Failure "int_of_string" ->
     fail (Malformed_response response_line)
  | e -> fail e

let parse_path uri = patch_empty_path (String.concat "/" (Neturl.url_path uri))
let parse_query_get_params uri =
  try (* act on HTTP encoded URIs *)
    split_query_params (Neturl.url_query ~encoded:true uri)
  with Not_found -> []

let parse_headers ic =
  (* consume also trailing "^\r\n$" line *)
  let rec parse_headers' headers =
    Lwt_io.read_line ic >>= function
    | "" -> return (List.rev headers)
    | line ->
        lwt subs = 
          try_lwt 
            return (Pcre.extract ~rex:header_RE line)
          with Not_found -> fail (Invalid_header line) in
        lwt header =
          try_lwt
            return (subs.(1))
          with Invalid_argument "Array.get" -> fail (Invalid_header line) in
        lwt value =
          try_lwt
            return (Http_parser_sanity.normalize_header_value subs.(2))
          with Invalid_argument "Array.get" -> return "" in
        Http_parser_sanity.heal_header (header, value);
        parse_headers' ((header, value) :: headers)
  in
  parse_headers' []

let parse_request ic =
  lwt (meth, uri, version) = parse_request_fst_line ic in
  let path = parse_path uri in
  let query_get_params = parse_query_get_params uri in
  debug_dump_request path query_get_params;
  return (path, query_get_params)

