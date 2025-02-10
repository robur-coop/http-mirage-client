type t

module type S = sig
  type nonrec t = t

  val connect : Mimic.ctx -> t Lwt.t
end

module Make
    (TCP : Tcpip.Tcp.S)
    (Happy_eyeballs : Mimic_happy_eyeballs.S with type flow = TCP.flow) : S

module Version = Httpaf.Version
module Status = H2.Status
module Headers = H2.Headers

type response = {
    version: Version.t
  ; status: Status.t
  ; reason: string
  ; headers: Headers.t
}

val request :
     ?config:[ `H2 of H2.Config.t | `HTTP_1_1 of Httpaf.Config.t ]
  -> ?tls_config:Tls.Config.client
  -> t
  -> ?authenticator:X509.Authenticator.t
  -> ?meth:Httpaf.Method.t
  -> ?headers:(string * string) list
  -> ?body:string
  -> ?max_redirect:int
  -> ?follow_redirect:bool
  -> string
  -> (response -> 'a -> string -> 'a Lwt.t)
  -> 'a
  -> (response * 'a, [> Mimic.error ]) result Lwt.t
(** [request ~config ~tls_config t ~authenticator ~meth ~headers ~body
     ~max_redirect ~follow_redirect url body_f body_init] does a HTTP request
    to [url] using [meth] and the HTTP protocol in [config]. The response is
    the value of this function. The body is provided in chunks (see [body_f]).
    If [follow_redirect] is enabled (true by default), [body_f] is not called
    with the potential body of the redirection.
    Reasonably defaults are used if not provided. *)
