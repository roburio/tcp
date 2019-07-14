(* (c) 2017-2019 Hannes Mehnert, all rights reserved *)

let src = Logs.Src.create "tcp.input" ~doc:"TCP input"
module Log = (val Logs.src_log src : Logs.LOG)

open State

open Rresult.R.Infix

let guard p e = if p then Ok () else Error e

(* in general, some flag combinations are always bad:
    only one of syn, fin, rst can ever be reasonably set.
 *)

(* FreeBSD uses: inpcb, which points to socket (SO_ACCEPTCON) AND its pcb  *)
(*  pcb points back to its inpcb, socket has at least the functionality:
  sbdrop, abavail, sbcut_locked, .sb_hiwat, sbreserve_locked, .sb_flags, sbused,
  sbsndptr, sbsndmbuf, .sb_state (used for CANTRCVMORE), sbappendstream_locked, sbspace
 *)

(* input rules from netsem
deliver_in_1 - passive open - handle_noconnn
deliver_in_1b - drop bad for listening - handle_noconn
deliver_in_2 - active open - handle_conn
deliver_in_2a - bad or boring, RST or ignore - handle_conn
deliver_in_2b - simultaneous open - handle_conn
deliver_in_3 - data, fin, ack in established - handle_conn
deliver_in_3a - data with invalid checksum - validate_segment fails
deliver_in_3b - data when process gone away - not handled
deliver_in_3c - stupid ack or land in SYN_RCVD - handle_conn and validate_segment fails
deliver_in_3d - valid ack in SYN_RCVD - handle_conn
deliver_in_4 - drop non-sane or martian segment - validate_segment fails
deliver_in_5 - drop with RST sth not matching any socket - handle_noconn
deliver_in_6 - drop sane segment in CLOSED - not handled (no CLOSED, handle_noconn may reset)
deliver_in_7 - recv RST and zap - handle_conn
deliver_in_8 - recv SYN in yy - handle_conn
deliver_in_9 - recv SYN in TIME_WAIT (in case there's no LISTEN) - not handled
??deliver_in_10 - stupid flag combinations are dropped (without reset)
*)

let handle_noconn t now id seg =
  match
    (* TL;DR: if there's a listener, and it is a SYN, we do sth useful. otherwise RST *)
    guard (IS.mem seg.Segment.dst_port t.listeners) () >>= fun () ->
    (* deliver_in_1 - passive open *)
    guard (Segment.Flags.only `SYN seg.Segment.flags) () >>| fun () ->
    (* segment is acceptable -- checked above *)
    (* broadcast/multicast already handled by decode_and_validate *)
    (* best_match also done implicitly -- connection table already dealt with *)
    (* there can't be anything in TIME_WAIT, otherwise we wouldn't end up here *)
    (* TODO check RFC 1122 Section 4.2.2.13 whether this actually happens (socket reusage) *)
    (* TODO resource management: limit number of outstanding connection attempts *)
    let conn =
      let advmss = Subr.tcp_mssopt id in
      let rcvbufsize, sndbufsize, t_maxseg', snd_cwnd' =
        let bw_delay_product_for_rt = None in
        Subr.calculate_buf_sizes advmss (Segment.mss seg)
          bw_delay_product_for_rt Params.so_rcvbuf Params.so_sndbuf
      in
      let rcv_wnd = rcvbufsize in
      let tf_doing_ws, snd_scale =
        match Segment.ws seg with
        | Some x when x <= Params.tcp_maxwinscale -> true, x
        | _ -> false, 0
      in
      let request_r_scale, rcv_scale = if tf_doing_ws then Params.scale, Params.scale else 0, 0 in
      let iss = Sequence.of_int32 (Randomconv.int32 t.rng)
      and ack' = Sequence.incr seg.Segment.seq (* ACK the SYN *)
      in
      let t_rttseg = Some (now, iss) in
      let control_block = {
        initial_cb with
        tt_rexmt = Some (Timers.timer now (Rexmt, 0) Params.tcp_backoff.(0)) ;
        t_idletime = now ;
        iss ;
        irs = seg.Segment.seq ;
        rcv_wnd = rcvbufsize ;
        tf_rxwin0sent = (rcv_wnd = 0) ;
        rcv_adv = Sequence.addi ack' rcv_wnd ;
        rcv_nxt = ack' ;
        snd_una = iss ;
        snd_max = Sequence.incr iss ;
        snd_nxt = Sequence.incr iss ;
        snd_cwnd = snd_cwnd' ;
        t_maxseg = t_maxseg' ;
        t_advmss = advmss ;
        tf_doing_ws ; snd_scale ; rcv_scale ;
        request_r_scale ;
        last_ack_sent = ack' ;
        t_rttseg }
      in
      conn_state ~rcvbufsize ~sndbufsize Syn_received control_block
    in
    let reply = Segment.make_syn_ack conn.control_block id in
    Log.debug (fun m -> m "%a passive open %a" Connection.pp id pp_conn_state conn);
    ({ t with connections = CM.add id conn t.connections }, Some reply)
  with
  | Ok (t, reply) -> t, reply
  | Error () ->
    (* deliver_in_1b - we do less checks and potentially send more resets *)
    (* deliver_in_5 / deliver_in_6 *)
    t, Segment.dropwithreset seg

let in_window cb seg =
  (* from table in 793bis13 3.3 *)
  let seq = seg.Segment.seq
  and max = Sequence.addi cb.rcv_nxt cb.rcv_wnd
  in
  match Cstruct.len seg.Segment.payload, cb.rcv_wnd with
  | 0, 0 -> Sequence.equal seq cb.rcv_nxt
  | 0, _ -> Sequence.less_equal cb.rcv_nxt seq && Sequence.less seq max
  | _, 0 -> false
  | dl, _ ->
    (*assert dl > 0*)
    let rseq = Sequence.addi seq (pred dl) in
    (Sequence.less_equal cb.rcv_nxt seq && Sequence.less seq max) ||
    (Sequence.less_equal cb.rcv_nxt rseq && Sequence.less rseq max)

let di3_topstuff cb seg =
  Ok (cb, cb.rcv_wnd = 0 && seg.Segment.window > 0)

let di3_ackstuff cb seg =
  let snd_una, fin_acked =
    if Segment.Flags.mem `ACK seg.Segment.flags then
      Sequence.max cb.snd_una seg.Segment.ack,
      Sequence.equal seg.Segment.ack (Sequence.incr cb.snd_nxt)
    else
      cb.snd_una, false
  in
  Ok ({ cb with snd_una }, fin_acked)

let di3_datastuff cb seg =
  let rcv_wnd = seg.Segment.window (* really always? *)
  and rcv_nxt, fin =
    if Sequence.equal seg.Segment.seq cb.rcv_nxt then begin
      if Cstruct.len seg.Segment.payload > 0 then
        Log.info (fun m -> m "received data: %a" Cstruct.hexdump_pp seg.Segment.payload);
      let is_fin = Segment.Flags.mem `FIN seg.Segment.flags in
      if is_fin then Log.info (fun m -> m "received fin");
      let nxt = Sequence.addi seg.Segment.seq (Cstruct.len seg.Segment.payload) in
      (if is_fin then Sequence.incr nxt else nxt), is_fin
    end else (* push segment to reassembly queue *)
      cb.rcv_nxt, false
  in
  (* may reassemble! *)
  Ok ({ cb with rcv_wnd ; rcv_nxt }, Sequence.greater rcv_nxt cb.rcv_nxt, fin)

let di3_ststuff conn rcvd_fin ourfinisacked =
  match conn.tcp_state, rcvd_fin with
  | Established, false -> Established
  | Established, true -> Close_wait
  | Close_wait, _ -> Close_wait
  | Fin_wait_1, false when ourfinisacked -> Fin_wait_2
  | Fin_wait_1, false -> Fin_wait_1
  | Fin_wait_1, true when ourfinisacked -> Time_wait
  | Fin_wait_1, true -> Closing
  | Fin_wait_2, false -> Fin_wait_2
  | Fin_wait_2, true -> Time_wait
  | Closing, _ when ourfinisacked -> Time_wait
  | Closing, _ -> Closing
  | Last_ack, false -> Last_ack
  | Last_ack, true -> assert false
  | Time_wait, _ -> Time_wait
  | _ -> assert false

let deliver_in_3 id conn seg =
  (* we expect at most FIN PSH ACK - we drop with reset all other combinations *)
  let flags = seg.Segment.flags in
  guard Segment.Flags.(is_empty flags || only `ACK flags || or_ack `FIN flags ||
                       or_ack `PSH flags || exact [ `FIN ; `PSH ] flags ||
                       exact [ `FIN ; `PSH ; `ACK  ] flags)
    (`Reset "flags empty | ACK | or_ack FIN | or_ack PSH | FIN PSH | FIN PSH ACK") >>= fun () ->
  (* PAWS, timers, rcv_wnd may have opened! *)
  di3_topstuff conn.control_block seg >>= fun (cb', _wnd) ->
  (* ACK processing *)
  di3_ackstuff cb' seg >>= fun (cb'', ourfinisacked) ->
  (* may have some fresh data to report which needs to be acked *)
  di3_datastuff cb'' seg >>| fun (cb''', ack, fin) ->
  (* state and FIN processing *)
  let conn' = { conn with control_block = cb''' ; cantrcvmore = conn.cantrcvmore || fin } in
  let tcp_state = di3_ststuff conn' fin ourfinisacked in
  { conn' with tcp_state },
  if ack then
    Some (Segment.make_ack conn'.control_block
            (match tcp_state with Close_wait -> true | _ -> false) id)
  else
    None

let deliver_in_2 now id conn seg =
  let cb = conn.control_block in
  guard (Sequence.equal seg.Segment.ack cb.snd_nxt) (`Drop "ack = snd_nxt") >>| fun () ->
  let tf_doing_ws, rcv_scale, snd_scale =
    match Segment.ws seg with
    | None -> false, 0, 0
    | Some x -> true, cb.request_r_scale, x
  in
  let rcvbufsize, sndbufsize, t_maxseg, snd_cwnd =
    let bw_delay_product_for_rt = None in
    Subr.calculate_buf_sizes cb.t_advmss (Segment.mss seg) bw_delay_product_for_rt
      conn.rcvbufsize conn.sndbufsize
  in
  let rcv_wnd = Subr.calculate_bsd_rcv_wnd conn in

  let t_softerror, t_rttseg, t_rttinf, tt_rexmt =
    (*: update RTT estimators from timestamp or roundtrip time :*)
    let emission_time = match cb.t_rttseg with
      | Some (ts0, seq0) when Sequence.greater seg.Segment.ack seq0 -> Some ts0
      | _ -> None
    in
    (*: clear soft error, cancel timer, and update estimators if we successfully timed a segment round-trip :*)
    let t_softerror', t_rttseg', t_rttinf' =
      match emission_time with
      | Some ts -> None, None, Subr.update_rtt (Mtime.span now ts) cb.t_rttinf
      | _ ->
        cb.t_softerror, cb.t_rttseg, cb.t_rttinf
    in
    (*: mess with retransmit timer if appropriate :*)
    let tt_rexmt' =
      if Sequence.equal seg.Segment.ack cb.snd_max then
        (*: if acked everything, stop :*)
        None
        (*: [[needoutput = 1]] -- see below :*)
      else cb.tt_rexmt

    (*        match cb.tt_rexmt with*)
(*        | Some (RexmtSyn, _) ->
          (*: if partial ack, restart from current backoff value,
              which is always zero because of the above updates to
              the RTT estimators and shift value. :*)
          start_tt_rexmtsyn h.arch 0 T t_rttinf' *)
(*        | None | Some (Rexmt. _) ->
          (*: ditto :*)
          start_tt_rexmt h.arch 0 T t_rttinf' *)
(*         |_ ->  else if emission_time <> NONE then
               case cb.tt_rexmt of
                  (*: bizarre but true. |tcp_input.c:1766| says c.f.~Phil Karn's retransmit algorithm :*)
                  NONE => NONE
                | SOME (Timed((mode,shift),d)) => SOME (Timed((mode,0),d))
           else
               (*: do nothing :*)
               cb.tt_rexmt *)
    in
    t_softerror', t_rttseg', t_rttinf', tt_rexmt'
  in

  let rcv_nxt = Sequence.incr seg.seq in

  let control_block = {
    cb with
    tt_rexmt ;
    t_idletime = now ;
    tt_conn_est = None ;
    tt_delack = None ;
    snd_una = Sequence.incr cb.iss ;
    (* snd_nxt / snd_max when fin / closed / cantsndmore *)
    snd_wl1 = Sequence.incr seg.seq ;
    snd_wl2 = seg.ack ;
    (* snd_wnd = win ; *)
    snd_cwnd ;
    rcv_scale ;
    snd_scale ;
    tf_doing_ws ;
    irs = seg.seq ;
    rcv_nxt ;
    rcv_wnd ;
    tf_rxwin0sent = (rcv_wnd = 0) ;
    rcv_adv = Sequence.addi rcv_nxt ((min (rcv_wnd lsr rcv_scale) Params.tcp_maxwin) lsl rcv_scale) ;
    t_maxseg ;
    last_ack_sent = rcv_nxt ;
    t_softerror ;
    t_rttseg ;
    t_rttinf ;
  }
  in
  { conn with control_block ; tcp_state = Established ; rcvbufsize ; sndbufsize },
  Segment.make_ack control_block false id

let deliver_in_2b _conn _seg =
  (* simultaneous open: accept anything, send syn+ack *)
  assert false

let deliver_in_2a conn seg =
  (* well well, the remote could have leftover state and send us a ack+fin... but that's fine to drop (and unlikely to happen now that we have random)
     server.exe: [DEBUG] 10.0.42.2:20 -> 10.0.42.1:1234 handle_conn TCP syn sent cb snd_una 0 snd_nxt 1 snd_wl1 0 snd_wl2 0 iss 0 rcv_wnd 65000 rcv_nxt 0 irs 0 seg AF seq 3062921918 ack 1 window 65535 opts 0 bytes data
     server.exe: [ERROR] dropping segment in syn sent failed condition RA *)
  guard (Segment.Flags.exact [ `ACK ; `RST ] seg.Segment.flags) (`Drop "RA") >>= fun () ->
  guard (Sequence.equal seg.Segment.ack conn.control_block.snd_nxt) (`Drop "ACK in-window")

let deliver_in_3c_3d conn seg =
  (* deliver_in_3c and syn_received parts of deliver_in_3 (now deliver_in_3d) *)
  (* TODO hostLTS:15801: [[SYN]] flag set may be set in the final segment of a simultaneous open :*)
  let cb = conn.control_block in
  (* what is the current state? *)
  (* - we acked the initial syn, their seq should be rcv_nxt (or?) *)
  (* - furthermore, it should be >= irs -- that's redundant with above *)
  (* if their seq is good (but their ack isn't or it is no ack), reset *)
  guard (Sequence.equal seg.Segment.seq cb.rcv_nxt) (`Drop "seq = rcv_nxt") >>= fun () ->
  (* - we sent our syn, so we expect an appropriate ack for the syn! *)
  (* - we didn't send out more data, so that ack should be exact *)
  (* if their seq is not good, drop packet *)
  guard (Segment.Flags.only `ACK seg.Segment.flags) (`Reset "only ACK flag") >>= fun () ->
  (* hostLTS:15828 - well, more or less ;) *)
  (* auxFns:2252 ack < snd_una || snd_max < ack -> break LAND DoS, prevent ACK storm *)
  guard (Sequence.equal seg.Segment.ack cb.snd_nxt) (`Reset "ack = snd_nxt") >>| fun () ->
  (* not (ack <= tcp_sock.cb.snd_una \/ ack > tcp_sock.cb.snd_max) *)
  (* TODO rtt measurement likely *)
  (* expect (assume for now): no data in that segment !? *)
  let control_block = {
    cb with snd_una = seg.Segment.ack ;
            (* snd_wnd = seg.Segment.window ; *)
            snd_wl1 = seg.Segment.seq ; (* need to check with model, from RFC 1122 4.2.2.20 *)
            snd_wl2 = seg.Segment.ack ;
  } in
  (* if not cantsendmore established else if ourfinisacked fin_wait2 else fin_wait_1 *)
  { conn with control_block ; tcp_state = Established }

let deliver_in_7 id conn seg =
  (* guard rcv_nxt = seg.seq *)
  let cb = conn.control_block in
  if Sequence.equal cb.rcv_nxt seg.Segment.seq then
    (* we rely that dropwithreset does not RST if a RST was received *)
    Error (`Reset "received valid reset")
  else
    Ok (Segment.make_ack cb false id)

let deliver_in_8 id conn _seg =
  Ok (Segment.make_ack conn.control_block false id)

let handle_conn t now id conn seg =
  Log.debug (fun m -> m "%a handle_conn %a@ seg %a" Connection.pp id pp_conn_state conn Segment.pp seg);
  let add conn' =
    Log.debug (fun m -> m "%a now %a" Connection.pp id pp_conn_state conn');
    { t with connections = CM.add id conn' t.connections }
  and drop () =
    Log.debug (fun m -> m "%a dropped" Connection.pp id);
    { t with connections = CM.remove id t.connections }
  in
  let r = match conn.tcp_state with
    | Syn_sent ->
      let flags = seg.Segment.flags in
      begin match Segment.Flags.(exact [ `SYN ; `ACK ] flags, only `SYN flags) with
        | true, true -> assert false
        | true, false -> deliver_in_2 now id conn seg >>| fun (c', o) -> add c', Some o
        | false, true -> deliver_in_2b conn seg >>| fun (c', o) -> add c', Some o
        | false, false -> deliver_in_2a conn seg >>| fun () -> drop (), None
      end
    | Syn_received -> deliver_in_3c_3d conn seg >>| fun conn' -> add conn', None
    | _ ->
      guard (in_window conn.control_block seg) (`Drop "in_window") >>= fun () ->
      let flags = seg.Segment.flags in
      (* RFC 5961: challenge acks for SYN and (RST where seq != rcv_nxt), keep state *)
      match Segment.Flags.(or_ack `RST flags, or_ack `SYN flags) with
      | true, true -> assert false
      | true, false -> deliver_in_7 id conn seg >>| fun seg' -> t, Some seg'
      | false, true -> deliver_in_8 id conn seg >>| fun seg' -> t, Some seg'
      | false, false -> deliver_in_3 id conn seg >>| fun (conn', d) -> add conn', d
  in
  match r with
  | Ok (t, a) -> t, a
  | Error (`Drop msg) ->
    Log.err (fun m -> m "dropping segment in %a failed condition %s" pp_fsm conn.tcp_state msg);
    t, None
  | Error (`Reset msg) ->
    Log.err (fun m -> m "reset in %a %s" pp_fsm conn.tcp_state msg);
    drop (), Segment.dropwithreset seg

let handle t now ~src ~dst data =
  match Segment.decode_and_validate ~src ~dst data with
  | Error (`Msg msg) ->
    Log.err (fun m -> m "dropping invalid segment %s" msg);
    (t, [])
  | Ok (seg, id) ->
    (* deliver_in_3a deliver_in_4 are done now! *)
    let pkt = src, seg.Segment.src_port, dst, seg.Segment.dst_port in
    Log.info (fun m -> m "%a TCP %a" Connection.pp pkt Segment.pp seg) ;
    let t', out = match CM.find_opt id t.connections with
      | None -> handle_noconn t now id seg
      | Some conn -> handle_conn t now id conn seg
    in
    t', match out with
    | None -> Log.info (fun m -> m "no answer"); []
    | Some d ->
      Log.info (fun m -> m "answer %a" Segment.pp d);
      [ `Data (src, Segment.encode_and_checksum ~src:dst ~dst:src d) ]

(* - timer : t -> t * Cstruct.t list * [ `Timeout of connection | `Error of connection ]

on individual sockets:
- shutdown_read
- shutdown_write *)

(* there's the ability to connect a socket to itself (using e.g. external fragments) *)
