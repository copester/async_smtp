open Core
open Async
open Email_message.Std


module Envelope_status = Client.Envelope_status

include (Email.Simple : module type of Email.Simple with module Expert := Email.Simple.Expert)

let default_server = `Inet (Host_and_port.create ~host:"localhost" ~port:25)

let client_log = Lazy.map Async.Log.Global.log ~f:(fun log ->
  Mail_log.adjust_log_levels ~remap_info_to:`Debug log)

module Expert = struct
  include Email.Simple.Expert

  let send' ?(log=Lazy.force client_log) ?(server=default_server) ~sender ?sender_args ~recipients email =
    let message = Envelope.create ~sender ?sender_args ~recipients ~rejected_recipients:[] ~email () in
    Client.Tcp.with_ server ~log ~f:(fun client ->
      Client.send_envelope client ~log message)

  let send ?log ?server ~sender ?sender_args ~recipients email =
    send' ?log ?server ~sender ?sender_args ~recipients email
    >>|? Envelope_status.ok_or_error ~allow_rejected_recipients:false
    >>| Or_error.join
    >>| Or_error.ignore
end

let send'
      ?log
      ?server
      ?(from=Email_address.local_address ())
      ?sender_args
      ~to_
      ?(cc=[])
      ?(bcc=[])
      ?reply_to
      ~subject
      ?id
      ?in_reply_to
      ?date
      ?auto_generated
      ?extra_headers
      ?attachments
      content =
  let email =
    create
      ~from
      ~to_
      ~cc
      ?reply_to
      ~subject
      ?id
      ?in_reply_to
      ?date
      ?auto_generated
      ?extra_headers
      ?attachments
      content in
  let recipients = to_ @ cc @ bcc in
  let sender = `Email from in
  let server = Option.map server ~f:(fun hp -> `Inet hp) in
  Expert.send' ?log ?server ~sender ?sender_args ~recipients email

let send
      ?log
      ?server
      ?from
      ?sender_args
      ~to_
      ?cc
      ?bcc
      ?reply_to
      ~subject
      ?id
      ?in_reply_to
      ?date
      ?auto_generated
      ?extra_headers
      ?attachments
      content =
  send'
    ?log
    ?server
    ?from
    ?sender_args
    ~to_
    ?cc
    ?bcc
    ?reply_to
    ~subject
    ?id
    ?in_reply_to
    ?date
    ?auto_generated
    ?extra_headers
    ?attachments
    content
  >>|? Envelope_status.ok_or_error ~allow_rejected_recipients:false
  >>| Or_error.join
  >>| Or_error.ignore
