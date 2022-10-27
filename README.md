# An HTTP (http/1.1 or h2) client for MirageOS

This little library provides an HTTP client which can be usable inside a
unikernel/[MirageOS][mirage]. It follows the same API as
[http-lwt-client][http-lwt-client] which is pretty simple and uses:
- [happy-eyeballs][happy-eyeballs] to resolve domain-name
- [ocaml-tls][ocaml-tls] for the TLS layer
- [paf][paf] for the HTTP protocol

This library wants to be easy to use and it is associated to a MirageOS
_device_ in order to facilite `functoria` to compose everything (mainly the
TCP/IP stack) according to the user's target and give a _witness_ so as to
be able to allocate a new connection to a peer and process the HTTP flow.

## How to use it?

First, you need to describe a new `http_client` device:
```ocaml
open Mirage

type http_client = HTTP_client
let http_client = typ HTTP_client

let http_client =
  let connect _ modname = function
    | [ _pclock; _tcpv4v6; ctx ] ->
      Fmt.str {ocaml|%s.connect %s|ocaml} modname ctx
    | _ -> assert false in
  impl ~connect "Http_mirage_client.Make"
    (pclock @-> tcpv4v6 @-> git_client @-> http_client)
```

Then, you can decide how to construct such device:
```ocaml
let stack = generic_stackv4v6 default_network
let dns   = generic_dns_client stack
let tcp   = tcpv4v6_of_stackv4v6 stack

let http_client =
  (* XXX(dinosaure): it seems unconventional to use [git_happy_eyeballs] here
     when we want to do HTTP requests only. The name was not so good and we
     will fix that into the next release of the mirage tool. But structurally,
     you don't bring anything related to Git. It's just a bad choice of name. *)
  let happy_eyeballs = git_happy_eyeballs stack dns
    (generic_happy_eyeballs stack dns) in
  http_client $ default_posix_clock $ tcp $ happy_eyeballs
```

Finally, you can use the _witness_ into your `unikernel.ml`:
```ocaml
open Lwt.Infix

module Make (HTTP_client : Http_mirage_client.S) = struct
  let start http_client =
    let body_f _response acc data = Lwt.return (acc ^ data) in
    Http_mirage_client.one_request http_client "https://mirage.io/" body_f ""
    >>= function
    | Ok (resp, body) -> ...
    | Error _ -> ...
end
```

[mirage]: https://mirage.io/
[happy-eyeballs]: https://github.com/roburio/happy-eyeballs
[ocaml-tls]: https://github.com/mirleft/ocaml-tls
[paf]: https://github.com/dinosaure/paf-le-chien
[http-lwt-client]: https://github.com/roburio/http-lwt-client
