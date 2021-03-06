open Core
open Core_extended.Std
open Async
open Email_message.Std

module Log = Mail_log

let compare _ _ = `You_are_using_poly_compare
let _silence_unused_warning = compare

(* Includes parent id and an incrementing counter. *)
module Id  = struct
  include String

  let counter = ref 0

  let create ~original_msg =
    let parent_id = Envelope.id original_msg in
    let t =
      sprintf !"%{Envelope.Id}-%s" parent_id
        (Common.urlbase64_encode_float ~length:6 (!counter |> Int.to_float))
    in
    incr counter;
    t
  ;;
end

module Status = struct
  type t =
    [ `Send_now
    | `Send_at of Time.t
    | `Sending
    | `Frozen
    | `Removed
    | `Quarantined of string
    | `Delivered
    ] [@@deriving sexp, bin_io, compare]
end

module Meta_queue = struct
  type t =
    | Active
    | Frozen
    | Removed
    | Quarantine
  [@@deriving sexp, enumerate, compare, bin_io]

  let to_dirname = function
    | Active     -> "active"
    | Frozen     -> "frozen"
    | Removed    -> "removed"
    | Quarantine -> "quarantine"
  ;;

  let of_status status =
    match status with
    | `Frozen                           -> Some Frozen
    | `Send_now | `Send_at _ | `Sending -> Some Active
    | `Removed                          -> Some Removed
    | `Quarantined _                    -> Some Quarantine
    | `Delivered                        -> None
  ;;

  let of_status' status =
    match of_status status with
    | Some queue  -> Ok queue
    | None        ->
      Or_error.error_s
        [%message "Specified status not associated with a queue"
                    (status : Status.t)]
  ;;
end

module Email_queue = struct
  type t =
    | Email
  [@@deriving sexp, enumerate]

  let to_dirname = function
    | Email -> "email"
end

(* A value of type t should only be modified via [On_disk_spool].  This guarantees
   that all changes are properly flushed to disk. *)
type t =
  { spool_dir                    : string
  ; id                           : Id.t
  (* with default so that sexps without a flowid still parse. *)
  ; flows                        : Log.Flows.t [@default Log.Flows.none]
  ; parent_id                    : Envelope.Id.t
  ; spool_date                   : Time.t
  ; next_hop_choices             : Address.t list
  (* The head of this list is the time at which we should attempt a delivery
     after the next time a delivery fails. *)
  ; mutable retry_intervals      : Retry_interval.t list
  ; mutable remaining_recipients : Email_address.t list
  (* Currently not used, but saved to disk to aid in triaging frozen messages and failed
     deliveries. Addresses on this list will not be included in remaining_recipients,
     and would otherwise be lost to the ether. *)
  ; mutable failed_recipients    : Email_address.t list
  ; mutable relay_attempts       : (Time.t * Error.t) list
  ; mutable status               : Status.t
  ; mutable envelope_info        : Envelope.Info.t
  } [@@deriving fields, sexp, bin_io]

(* type alias to make code more readable below *)
type meta = t [@@deriving sexp]

let compare t1 t2 =
  Sexp.compare (sexp_of_t t1) (sexp_of_t t2)
;;

let status t =
  match t.status with
  | `Send_at time when Time.(time < now ()) -> `Send_now
  | status -> status
;;

(* Both multispools share a registry directory, so we append ".body" for what we put in
   the [Email] queue *)
let email_filename str = str ^ ".body"

(* Throttle to pass to multispool. Don't hit the max open files system limit *)
let throttle = Throttle.create ~continue_on_error:true ~max_concurrent_jobs:400

module Meta_on_disk = struct
  module Simple = struct
    module T = struct
      type t = meta [@@deriving sexp]
    end

    include T
    include Sexpable.To_stringable (T)

    module Queue = Meta_queue

    module Name_generator = struct
      type t = Envelope.t
      let next original_msg ~attempt:_ = Id.create ~original_msg
    end

    module Throttle = struct
      let enqueue f = Throttle.enqueue throttle f
    end
  end

  include Multispool.Make_spoolable(Simple)
end

module Email_on_disk = struct
  type t = Email.t

  let load_from_disk ~path =
    let open Deferred.Or_error.Let_syntax in
    let%map contents =
      Deferred.Or_error.try_with (fun () ->
        Reader.file_contents path)
    in
    Email.of_string contents
  ;;

  let save_to_disk ?temp_file ~path email =
    Deferred.Or_error.try_with (fun () ->
      Writer.with_file_atomic ?temp_file ~fsync:true path ~f:(fun writer ->
        String_monoid.iter (Email.to_string_monoid email) ~f:(function
          | String_monoid.Underlying.Char c ->
            Writer.write_char writer c
          | String str ->
            Writer.write writer str
          | Bigstring bstr ->
            Writer.schedule_bigstring writer bstr);
        return ()))
  ;;

  module Queue = Email_queue

  module Name_generator = struct
    type t = string

    let next msgid ~attempt =
      if attempt > 0
      then raise_s [%message "Unexpected file in email queue" (msgid : string)];
      email_filename msgid
    ;;
  end

  module Throttle = struct
    let enqueue f = Throttle.enqueue throttle f
  end
end

module Email_spool = Multispool.Make(Email_on_disk)
module Meta_spool = struct
  include Multispool.Make(Meta_on_disk)

  let create str =
    let open Deferred.Or_error.Let_syntax in
    let%bind (_ : Email_spool.t) = Email_spool.create str in
    create str
  ;;

  (* Hide optional argument from the interface *)
  let load str = load str

  let ls t queues =
    Deferred.Or_error.List.concat_map queues ~f:(fun queue -> list t queue)
  ;;
end

(* This name is more appropriate outside this module *)
module On_disk_spool = struct
  include Meta_spool

  module Queue = Meta_queue
end

(* We use 2 multispools at the same path to get more type safety with the queues, but
   unfortunately this means functions like this *)
let email_spool_of_meta_spool meta_spool =
  Email_spool.load_unsafe (Meta_spool.dir meta_spool)
;;

let email_entry_of_meta_entry meta_entry =
  Email_spool.Entry.create
    (email_spool_of_meta_spool (Meta_spool.Entry.spool meta_entry))
    Email
    ~name:(email_filename (Meta_spool.Entry.name meta_entry))
;;

let entry t =
  let open Deferred.Or_error.Let_syntax in
  let open Meta_spool in
  let spool = load_unsafe t.spool_dir in
  let%map queue = Meta_queue.of_status' t.status |> Deferred.return in
  Entry.create spool queue ~name:t.id
;;

let enqueue meta_spool queue ~meta ~id ~email =
  Meta_spool.enqueue meta_spool queue meta (`Use id)
  >>=? fun (_ : Meta_spool.Entry.t) ->
  let email_spool = email_spool_of_meta_spool meta_spool in
  Email_spool.Unique_name.reserve email_spool (id :> string)
  >>=? fun email_name ->
  Email_spool.enqueue email_spool Email email (`Use email_name)
  >>|? fun (_ : Email_spool.Entry.t) ->
  ()
;;

let create spool ~log:_ ~initial_status envelope_with_next_hop ~flows ~original_msg =
  let parent_id = Envelope.id original_msg in
  let next_hop_choices =
    Envelope.With_next_hop.next_hop_choices envelope_with_next_hop
  in
  let retry_intervals =
    Envelope.With_next_hop.retry_intervals envelope_with_next_hop
  in
  let envelope = Envelope.With_next_hop.envelope envelope_with_next_hop in
  let remaining_recipients = Envelope.recipients envelope in
  Meta_queue.of_status' initial_status |> Deferred.return
  >>=? fun queue ->
  Meta_spool.Unique_name.reserve spool original_msg
  >>=? fun id ->
  let meta =
    Fields.create
      ~spool_dir:(Meta_spool.dir spool)
      ~spool_date:(Time.now ())
      ~remaining_recipients
      ~failed_recipients:[]
      ~next_hop_choices
      ~retry_intervals
      ~relay_attempts:[]
      ~parent_id
      ~status:initial_status
      ~id:(id :> string)
      ~flows
      ~envelope_info:(Envelope.info envelope)
  in
  let email = Envelope.email envelope in
  enqueue spool queue ~meta ~id ~email
  >>|? fun () ->
  meta
;;

let load meta_entry =
  Meta_spool.Entry.contents_unsafe meta_entry
;;

let load_email meta_entry =
  Email_spool.Entry.contents_unsafe (email_entry_of_meta_entry meta_entry)
;;

let load_with_envelope meta_entry =
  let open Deferred.Or_error.Let_syntax in
  let%bind meta = load meta_entry in
  let%map email =
    Email_spool.Entry.contents_unsafe (email_entry_of_meta_entry meta_entry)
  in
  meta, Envelope.create' ~info:(envelope_info meta) ~email
;;

let last_relay_attempt t =
  List.hd t.relay_attempts
;;

let with_file t
      (f : (unit -> Envelope.t Or_error.t Deferred.t) ->
       [`Sync_meta | `Sync_email of Email.t | `Unlink] Or_error.t Deferred.t)
  : unit Or_error.t Deferred.t =
  entry t
  >>=? fun meta_entry ->
  return (Meta_queue.of_status' t.status)
  >>=? fun original_queue ->
  Meta_spool.with_entry meta_entry
    ~f:(fun meta ->
      match compare t meta = 0 with
      | false ->
        let e =
          Error.create
            "spooled message in memory differs from spooled message on disk"
            (`In_memory t, `On_disk meta, `Entry meta_entry)
            [%sexp_of: [`In_memory of t] * [`On_disk of t] * [`Entry of Meta_spool.Entry.t]]
        in
        return (`Save (meta, original_queue), Error e)
      | true ->
        let get_envelope () =
          load_email meta_entry
          >>|? fun email ->
          Envelope.create' ~info:(envelope_info meta) ~email
        in
        f get_envelope
        >>= function
        | Error _ as e -> return (`Save (meta, original_queue), e)
        | Ok (`Unlink) ->
          Email_spool.Entry.remove_unsafe (email_entry_of_meta_entry meta_entry)
          >>= fun result ->
          return (`Remove, result)
        | Ok (`Sync_email email) ->
          Email_spool.Entry.save_unsafe (email_entry_of_meta_entry meta_entry) email
          >>| fun result ->
          (`Save (meta, original_queue), result)
        | Ok `Sync_meta ->
          (* Derive queue from mutable [t.status] as it may have changed in [~f] *)
          Meta_queue.of_status' t.status
          |> Or_error.tag ~tag:(Sexp.to_string (sexp_of_t t))
          |> Deferred.return
          >>= function
          | Error _ as e -> return (`Save (meta, original_queue), e)
          | Ok new_queue ->
            return (`Save (t, new_queue), Ok ())
    )
  >>| Or_error.join
;;

let map_email t ~f =
  with_file t (fun get_envelope ->
    get_envelope ()
    >>=? fun envelope ->
    let email' = f (Envelope.email envelope) in
    return (Ok (`Sync_email email')))
;;

let freeze t ~log =
  with_file t (fun _get_envelope ->
    Log.info log (lazy (Log.Message.create
                          ~here:[%here]
                          ~flows:t.flows
                          ~component:["spool"]
                          ~spool_id:t.id
                          "frozen"));
    t.status <- `Frozen;
    return (Ok `Sync_meta))
;;

let mark_for_send_now ~retry_intervals t ~log =
  with_file t (fun _get_envelope ->
    Log.info log (lazy (Log.Message.create
                          ~here:[%here]
                          ~flows:t.flows
                          ~component:["spool"]
                          ~spool_id:t.id
                          "send_now"));
    t.status <- `Send_now;
    t.retry_intervals <- retry_intervals @ t.retry_intervals;
    return (Ok `Sync_meta))
;;

let remove t ~log =
  with_file t (fun _get_envelope ->
    Log.info log (lazy (Log.Message.create
                          ~here:[%here]
                          ~flows:t.flows
                          ~component:["spool"]
                          ~spool_id:t.id
                          "removing"));
    t.status <- `Removed;
    return (Ok `Sync_meta))
;;

let send_to_hops t ~log ~client_cache get_envelope =
  let hops_tag = Sexp.to_string ([%sexp_of: Address.t list] t.next_hop_choices) in
  Log.debug log (lazy (Log.Message.create
                         ~here:[%here]
                         ~flows:t.flows
                         ~component:["spool";"send"]
                         ~spool_id:t.id
                         ~tags:["hops", hops_tag]
                         "attempting delivery"));
  Client_cache.Tcp.with_'
    ~give_up:(Clock.after (sec 60.))
    ~cache:client_cache t.next_hop_choices
    ~f:(fun ~flows client ->
      let flows = Log.Flows.union t.flows flows in
      get_envelope ()
      >>=? fun envelope ->
      let envelope = Envelope.set envelope ~recipients:t.remaining_recipients () in
      Client.send_envelope client ~log ~flows ~component:["spool";"send"] envelope)
  >>= function
  | `Ok (hop, (Error e))
  | `Error_opening_resource (hop, e) ->
    (* The client logs many common failures, so this might be repetitive. But
       duplication in the error case is better than missing potential errors. *)
    let e = Error.tag ~tag:"Unable to send envelope" e in
    Log.info log (lazy (Log.Message.of_error
                          ~here:[%here]
                          ~flows:t.flows
                          ~component:["spool"; "send"]
                          ~spool_id:t.id
                          ~remote_address:hop
                          e));
    t.relay_attempts <- (Time.now (), e) :: t.relay_attempts;
    return `Try_later
  | `Gave_up_waiting_for_resource ->
    let e = Error.createf "Gave up waiting for client" in
    Log.info log (lazy (Log.Message.of_error
                          ~here:[%here]
                          ~flows:t.flows
                          ~component:["spool"; "send"]
                          ~spool_id:t.id
                          ~tags:["hops", hops_tag]
                          e));
    t.relay_attempts <- (Time.now (), e) :: t.relay_attempts;
    return `Try_later
  | `Cache_is_closed ->
    (* Shutdown is initiated, so stop trying to resend. *)
    Log.info log (lazy (Log.Message.create
                          ~here:[%here]
                          ~flows:t.flows
                          ~component:["spool"; "send"]
                          ~spool_id:t.id
                          ~tags:["hops", hops_tag]
                          "Cache is closed"));
    return `Try_later
  | `Ok (_hop, (Ok envelope_status)) ->
    match Client.Envelope_status.ok_or_error ~allow_rejected_recipients:false envelope_status with
    | Ok _msg_id ->
      (* Already logged by the client *)
      return `Done
    | Error e ->
      (* We are being conservative here for simplicity - if we get a permanent error
         from one hop, we assume that we would get the same error from the remaining
         hops. *)
      (* Already logged by the client *)
      t.relay_attempts <- (Time.now (), e) :: t.relay_attempts;
      match envelope_status with
      | Ok (_ (* envelope_id *), rejected_recipients)
      | Error (`No_recipients rejected_recipients) ->
        let permanently_failed_recipients, temporarily_failed_recipients =
          List.partition_map rejected_recipients ~f:(fun (recipient, reject) ->
            if Smtp_reply.is_permanent_error reject then `Fst recipient
            else `Snd recipient)
        in
        t.remaining_recipients <- temporarily_failed_recipients;
        t.failed_recipients <- t.failed_recipients @ permanently_failed_recipients;
        if List.is_empty t.remaining_recipients
        then (return `Fail_permanently)
        else (return `Try_later)
      | Error (`Rejected_sender r
              | `Rejected_sender_and_recipients (r,_)
              | `Rejected_body (r,_)) ->
        if Smtp_reply.is_permanent_error r
        then (return `Fail_permanently)
        else (return `Try_later)
;;

let do_send t ~log ~client_cache =
  with_file t (fun get_envelope ->
    t.status <- `Sending;
    send_to_hops t ~log ~client_cache get_envelope
    >>| function
    | `Done ->
      t.status <- `Delivered;
      Ok `Unlink
    | (`Fail_permanently | `Try_later) as fail ->
      match fail, t.retry_intervals with
      | `Fail_permanently, _ | `Try_later, [] ->
        t.status <- `Frozen;
        Ok `Sync_meta
      | `Try_later, r :: rs ->
        t.status <- `Send_at (Time.add (Time.now ()) (Retry_interval.to_span r));
        t.retry_intervals <- rs;
        Ok `Sync_meta)
;;

let send t ~log ~client_cache =
  match t.status with
  | `Send_now | `Send_at _ -> do_send t ~log ~client_cache
  | `Frozen ->
    return (Or_error.error_string
              "Message.send: message is frozen")
  | `Removed ->
    return (Or_error.error_string
              "Message.send: message is removed")
  | `Quarantined _ ->
    return (Or_error.error_string
              "Message.send: message is quarantined")
  | `Sending ->
    return (Or_error.error_string
              "Message.send: message is already being sent")
  | `Delivered ->
    return (Or_error.error_string
              "Message.send: message is delivered")
;;

let size_of_file t =
  let open Deferred.Or_error.Let_syntax in
  let%bind meta_entry = entry t in
  let%map stats = Email_spool.Entry.stat (email_entry_of_meta_entry meta_entry) in
  let size = Unix.Stats.size stats |> Float.of_int64 in
  Byte_units.create `Bytes size
;;

let time_on_spool t =
  Time.diff (Time.now ()) t.spool_date
;;

module T = struct
  type nonrec t = t [@@deriving sexp]

  let compare t1 t2 =
    Id.compare t1.id t2.id

  let hash t =
    Id.hash t.id
end

include Comparable.Make(T)
include Hashable.Make(T)
