(* Functoria *)

module DNS_client =
  Dns_client_mirage.Make (Mirage_crypto_rng) (Time) (Mclock) (Pclock)
    (Tcpip_stack_socket.V4V6)

module Happy_eyeballs =
  Happy_eyeballs_mirage.Make (Time) (Mclock) (Tcpip_stack_socket.V4V6)
    (DNS_client)

module Mimic_happy_eyeballs =
  Mimic_happy_eyeballs.Make (Tcpip_stack_socket.V4V6) (DNS_client)
    (Happy_eyeballs)

module HTTP_server = Paf_mirage.Make (Tcpip_stack_socket.V4V6.TCP)

module HTTP_client =
  Http_mirage_client.Make (Pclock) (Tcpip_stack_socket.V4V6.TCP)
    (Mimic_happy_eyeballs)

let http_1_1_error_handler ?notify (ipaddr, port) ?request:_ error respond =
  let contents =
    match error with
    | `Bad_gateway -> Fmt.str "Bad gateway (%a:%d)" Ipaddr.pp ipaddr port
    | `Bad_request -> Fmt.str "Bad request (%a:%d)" Ipaddr.pp ipaddr port
    | `Exn exn ->
      Fmt.str "Exception %S (%a:%d)" (Printexc.to_string exn) Ipaddr.pp ipaddr
        port
    | `Internal_server_error ->
      Fmt.str "Internal server error (%a:%d)" Ipaddr.pp ipaddr port in
  let open Httpaf in
  Option.iter (fun push -> push (Some ((ipaddr, port), error))) notify
  ; let headers =
      Headers.of_list
        [
          "content-type", "text/plain"
        ; "content-length", string_of_int (String.length contents)
        ; "connection", "close"
        ] in
    let body = respond headers in
    Body.write_string body contents
    ; Body.close_writer body

let alpn_error_handler :
    type reqd headers request response ro wo.
       ?notify:(((Ipaddr.t * int) * Alpn.server_error) option -> unit)
    -> Ipaddr.t * int
    -> (reqd, headers, request, response, ro, wo) Alpn.protocol
    -> ?request:request
    -> Alpn.server_error
    -> (headers -> wo)
    -> unit =
 fun ?notify (ipaddr, port) protocol ?request:_ error respond ->
  let contents =
    match error with
    | `Bad_gateway -> Fmt.str "Bad gateway (%a:%d)" Ipaddr.pp ipaddr port
    | `Bad_request -> Fmt.str "Bad request (%a:%d)" Ipaddr.pp ipaddr port
    | `Exn exn ->
      Fmt.str "Exception %S (%a:%d)" (Printexc.to_string exn) Ipaddr.pp ipaddr
        port
    | `Internal_server_error ->
      Fmt.str "Internal server error (%a:%d)" Ipaddr.pp ipaddr port in
  Option.iter (fun push -> push (Some ((ipaddr, port), error))) notify
  ; let headers =
      [
        "content-type", "text/plain"
      ; "content-length", string_of_int (String.length contents)
      ] in
    match protocol with
    | Alpn.HTTP_1_1 _ ->
      let open Httpaf in
      let headers = Headers.of_list (("connection", "close") :: headers) in
      let body = respond headers in
      Body.write_string body contents
      ; Body.close_writer body
    | Alpn.H2 _ ->
      let open H2 in
      let headers = Headers.of_list headers in
      let body = respond headers in
      H2.Body.Writer.write_string body contents
      ; H2.Body.Writer.close body

type alpn_handler = {
    handler:
      'reqd 'headers 'request 'response 'ro 'wo.
         'reqd
      -> ('reqd, 'headers, 'request, 'response, 'ro, 'wo) Alpn.protocol
      -> unit
}
[@@unboxed]

let server ?error ?stop stack = function
  | `HTTP_1_1 (port, handler) ->
    let open Lwt.Syntax in
    let+ http_server = HTTP_server.init ~port stack in
    let http_service =
      HTTP_server.http_service
        ~error_handler:(http_1_1_error_handler ?notify:error)
        (fun _flow (_ipaddr, _port) -> handler) in
    HTTP_server.serve ?stop http_service http_server
  | `ALPN (tls, port, handler) ->
    let open Lwt.Syntax in
    let alpn_handler =
      {
        Alpn.error=
          (fun edn protocol ?request v respond ->
            alpn_error_handler ?notify:error edn protocol ?request v respond)
      ; Alpn.request=
          (fun _flow (_ipaddr, _port) reqd protocol ->
            handler.handler reqd protocol)
      } in
    let+ http_server = HTTP_server.init ~port stack in
    let alpn_service = HTTP_server.alpn_service ~tls alpn_handler in
    HTTP_server.serve ?stop alpn_service http_server

let stack () =
  let open Lwt.Syntax in
  let ip = Ipaddr.V4.(Prefix.make 8 localhost) in
  let ipv4_only = true and ipv6_only = false in
  let* tcpv4v6 =
    Tcpip_stack_socket.V4V6.TCP.connect ~ipv4_only ~ipv6_only ip None
  in
  let* udpv4v6 =
    Tcpip_stack_socket.V4V6.UDP.connect ~ipv4_only ~ipv6_only ip None
  in
  Tcpip_stack_socket.V4V6.connect udpv4v6 tcpv4v6

let test01 =
  Alcotest_lwt.test_case "Simple Hello World! (GET)" `Quick @@ fun _sw () ->
  let open Lwt.Syntax in
  let stop = Lwt_switch.create () in
  let handler reqd =
    let open Httpaf in
    let contents = "Hello World!" in
    let headers =
      Headers.of_list
        [
          "content-type", "text/plain"
        ; "content-length", string_of_int (String.length contents)
        ; "connection", "close"
        ] in
    let response = Response.create ~headers `OK in
    Reqd.respond_with_string reqd response contents in
  let* stack = stack () in
  let happy_eyeballs = Happy_eyeballs.create stack in
  let* ctx = Mimic_happy_eyeballs.connect happy_eyeballs in
  let* t = HTTP_client.connect ctx in
  let* (`Initialized _thread) =
    server ~stop (Tcpip_stack_socket.V4V6.tcp stack) (`HTTP_1_1 (8080, handler))
  in
  let* result =
    Http_mirage_client.request t "http://localhost:8080/"
      (fun _response buf str -> Buffer.add_string buf str ; Lwt.return buf)
      (Buffer.create 0x100) in
  match result with
  | Error err ->
    let* () = Lwt_switch.turn_off stop in
    let* () = Tcpip_stack_socket.V4V6.disconnect stack in
    Alcotest.failf "Client error: %a" Mimic.pp_error err
  | Ok (_response, buf) ->
    let* () = Lwt_switch.turn_off stop in
    let* () = Tcpip_stack_socket.V4V6.disconnect stack in
    let body = Buffer.contents buf in
    Alcotest.(check string) "body" "Hello World!" body
    ; Lwt.return_unit

let random_string ~len =
  let res = Bytes.create len in
  for i = 0 to len - 1 do
    Bytes.set res i (Char.chr (Random.bits () land 0xff))
  done
  ; Bytes.unsafe_to_string res

let test02 =
  Alcotest_lwt.test_case "Repeat (POST)" `Quick @@ fun _sw () ->
  let open Lwt.Syntax in
  let stop = Lwt_switch.create () in
  let handler reqd =
    let open Httpaf in
    let {Request.meth; _} = Reqd.request reqd in
    if meth <> `POST then invalid_arg "Invalid HTTP method"
    ; let headers = Headers.of_list ["content-type", "text/plain"] in
      let response = Response.create ~headers `OK in
      let src = Reqd.request_body reqd in
      let dst = Reqd.respond_with_streaming reqd response in
      let rec on_eof () = Body.close_reader src ; Body.close_writer dst
      and on_read buf ~off ~len =
        Body.write_bigstring dst ~off ~len buf
        ; Body.schedule_read src ~on_eof ~on_read in
      Body.schedule_read src ~on_eof ~on_read in
  let* stack = stack () in
  let happy_eyeballs = Happy_eyeballs.create stack in
  let* ctx = Mimic_happy_eyeballs.connect happy_eyeballs in
  let* t = HTTP_client.connect ctx in
  let* (`Initialized _thread) =
    server ~stop (Tcpip_stack_socket.V4V6.tcp stack) (`HTTP_1_1 (8080, handler))
  in
  let str = random_string ~len:0x1000 in
  let* result =
    Http_mirage_client.request ~meth:`POST ~body:str t "http://localhost:8080/"
      (fun _response buf str -> Buffer.add_string buf str ; Lwt.return buf)
      (Buffer.create 0x1000) in
  match result with
  | Error err ->
    let* () = Lwt_switch.turn_off stop in
    let* () = Tcpip_stack_socket.V4V6.disconnect stack in
    Alcotest.failf "Client error: %a" Mimic.pp_error err
  | Ok (_response, buf) ->
    let* () = Lwt_switch.turn_off stop in
    let* () = Tcpip_stack_socket.V4V6.disconnect stack in
    let body = Buffer.contents buf in
    Alcotest.(check string) "body" str body
    ; Lwt.return_unit

let () =
  Alcotest_lwt.run "http-mirage-client" ["http/1.1", [test01; test02]]
  |> Lwt_main.run
