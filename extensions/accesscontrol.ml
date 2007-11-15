(* Ocsigen
 * http://www.ocsigen.org
 * Module accesscontrol.ml
 * Copyright (C) 2007 Vincent Balat
 * Laboratoire PPS - CNRS Universit� Paris Diderot
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exception; 
 * either version 2.1 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *)

(** Filtering requests in the configuration file *)

(* 

Then load it dynamically from Ocsigen's config file:
   <extension module=".../accesscontrol.cmo"/>

*)

open Lwt
open Extensions
open Simplexmlparser



(*****************************************************************************)

type filter =
  | Filter_Ip of (int32 * int32)
  | Filter_path of Netstring_pcre.regexp
  | Filter_method of Http_frame.Http_header.http_method
  | Filter_Header of string * Netstring_pcre.regexp

type filters =
  | Allow_or of filter list
  | Deny_and of filter list
  | Allow_and of filter list
  | Deny_or of filter list
  | Forbidden
  | Notfound


(*****************************************************************************)
let rec parse_global_config = function
  | [] -> ()
  | _ -> raise (Error_in_config_file 
                  ("Unexpected content inside accesscontrol config"))

let _ = parse_global_config (Extensions.get_config ())





(*****************************************************************************)
(* Finding access pattern *)

let find_access access_pattern ri = 
  let one_access = function
    | Filter_Ip (ip32, mask) -> 
        let r = Int32.logand (Lazy.force ri.ri_ip32) mask = ip32 in
        if r then 
          Messages.debug2 "--Access control: IP matches mask"
        else
          Messages.debug2 "--Access control: IP does not match mask";
        r
    | Filter_path regexp ->
        let r =
          Netstring_pcre.string_match 
            regexp (Lazy.force ri.ri_sub_path_string) 0 <> None
        in
        if r then 
          Messages.debug 
            (fun () -> "--Access control: Path "^
              (Lazy.force ri.ri_sub_path_string)^" matches regexp")
        else
          Messages.debug
            (fun () -> "--Access control: Path "^
              (Lazy.force ri.ri_sub_path_string)^" does not match regexp");
        r
    | Filter_method meth -> 
        let r = meth = ri.ri_method in
        if r then 
          Messages.debug2 "--Access control: Method matches"
        else
          Messages.debug2 "--Access control: Method does not match";
        r
    | Filter_Header (name, regexp) -> 
        let r =
          List.exists
            (fun a -> Netstring_pcre.string_match regexp a 0 <> None)
            (Http_headers.find_all 
               (Http_headers.name name) 
               ri.ri_http_frame.Http_frame.header.Http_frame.Http_header.headers)
        in
        if r then 
          Messages.debug2 "--Access control: Header matches regexp"
        else
          Messages.debug2 "--Access control: Header does not match regexp";
        r
  in
  match access_pattern with
  | Allow_or l -> List.fold_left (fun beg a -> beg || one_access a) false l
  | Allow_and l -> List.fold_left (fun beg a -> beg && one_access a) true l
  | Deny_or l -> 
      not (List.fold_left (fun beg a -> beg || one_access a) false l)
  | Deny_and l -> 
      not (List.fold_left (fun beg a -> beg && one_access a) true l)
  | Forbidden -> raise (Ocsigen_http_error 403)
  | Notfound -> raise (Ocsigen_http_error 404)



let gen test err charset ri = 
  try
    if find_access test ri then begin
      Messages.debug2 "--Access control: => Access granted!";
      Lwt.return (Ext_not_found err)
    end
    else begin
      Messages.debug2 "--Access control: => Access denied!";
      Lwt.return (Ext_stop 403)
    end
  with 
  | e -> 
      Messages.debug2 "--Access control: taking in charge an error";
      fail e (* for example Ocsigen_http_error 404 or 403 *)
        (* server.ml has a default handler for HTTP errors *)




(*****************************************************************************)
(** Configuration for each site.
    These tags are inside <site ...>...</site> in the config file.
        
   For example:
   <site dir="">
     <accesscontrol regexp="" dest="" />
   </site>

 *)


let parse_config path charset = 
  let rec parse_sub = function
    | Element ("ip", [("value", s)], []) -> 
        (try
          Filter_Ip (Ocsimisc.parse_ip_netmask s)
        with Failure _ -> 
          raise (Error_in_config_file "Bad ip/netmask value in <ip/>"))
    | Element ("header", [("name", s); ("regexp", r)], []) -> 
        (try
          Filter_Header (s, Netstring_pcre.regexp r)
        with Failure _ -> 
          raise (Error_in_config_file
                   "Bad regular expression in <header/>"))
    | Element ("method", [("value", s)], []) -> 
        (try
          Filter_method (Framepp.method_of_string s)
        with Failure _ -> 
          raise (Error_in_config_file "Bad method value in <method/>"))
    | Element ("path", [("regexp", s)], []) -> 
        (try
          Filter_path (Netstring_pcre.regexp s)
        with Failure _ -> 
          raise (Error_in_config_file
                   "Bad regular expression in <path/>"))
    | Element (t, _, _) -> raise (Error_in_config_file ("(accesscontrol extension) Problem with tag <"^t^"> in configuration file."))
    | _ -> raise (Error_in_config_file "(accesscontrol extension) Bad data")
  in
  function
  | Element ("allow", [("type","or")], sub) -> 
      Page_gen (gen (Allow_or (List.map parse_sub sub)))
  | Element ("deny", [("type","or")], sub) -> 
      Page_gen (gen (Deny_or (List.map parse_sub sub)))
  | Element ("allow", [("type","and")], sub) -> 
      Page_gen (gen (Allow_and (List.map parse_sub sub)))
  | Element ("deny", [("type","and")], sub) -> 
      Page_gen (gen (Deny_and (List.map parse_sub sub)))
  | Element ("forbidden", [], sub) -> 
      Page_gen (gen Forbidden)
  | Element ("notfound", [], sub) -> 
      Page_gen (gen Notfound)
  | Element ("allow", _, _)
  | Element ("deny", _, _) -> 
      raise 
        (Error_in_config_file
           "(accesscontrol extension) Please specify type=\"or\" or type=\"and\" for <allow> and <deny>")
  | Element (t, _, _) -> raise (Bad_config_tag_for_extension t)
  | _ -> raise (Error_in_config_file "(accesscontrol extension) Bad data")



(*****************************************************************************)
(** Function to be called at the beginning of the initialisation phase 
    of the server (actually each time the config file is reloaded) *)
let start_init () =
  ()

(** Function to be called at the end of the initialisation phase *)
let end_init () =
  ()




(*****************************************************************************)
(** Registration of the extension *)
let _ = register_extension
    ((fun hostpattern -> parse_config),
     start_init,
     end_init,
     raise)
