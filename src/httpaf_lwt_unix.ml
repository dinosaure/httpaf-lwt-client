(*----------------------------------------------------------------------------
    Copyright (c) 2018 Inhabited Type LLC.
    Copyright (c) 2018 Anton Bachin

    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions
    are met:

    1. Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.

    3. Neither the name of the author nor the names of his contributors
       may be used to endorse or promote products derived from this software
       without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE CONTRIBUTORS ``AS IS'' AND ANY EXPRESS
    OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
    WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
    DISCLAIMED.  IN NO EVENT SHALL THE AUTHORS OR CONTRIBUTORS BE LIABLE FOR
    ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
    DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
    OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
    HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
    STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
    ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
  ----------------------------------------------------------------------------*)

open Lwt.Infix

module Buffer : sig
  type t

  val create : int -> t

  val get : t -> f:(Lwt_bytes.t -> off:int -> len:int -> int) -> int
  val put : t -> f:(Lwt_bytes.t -> off:int -> len:int -> int Lwt.t) -> int Lwt.t
end = struct
  type t =
    { buffer      : Lwt_bytes.t
    ; mutable off : int
    ; mutable len : int }

  let create size =
    let buffer = Lwt_bytes.create size in
    { buffer; off = 0; len = 0 }

  let compress t =
    if t.len = 0
    then begin
      t.off <- 0;
      t.len <- 0;
    end else if t.off > 0
    then begin
      Lwt_bytes.blit t.buffer t.off t.buffer 0 t.len;
      t.off <- 0;
    end

  let get t ~f =
    let n = f t.buffer ~off:t.off ~len:t.len in
    t.off <- t.off + n;
    t.len <- t.len - n;
    if t.len = 0
    then t.off <- 0;
    n

  let put t ~f =
    compress t;
    f t.buffer ~off:(t.off + t.len) ~len:(Lwt_bytes.length t.buffer - t.len)
    >>= fun n ->
    t.len <- t.len + n;
    Lwt.return n
end

let read fd buffer =
  Lwt.catch
    (fun () ->
       Buffer.put buffer ~f:(fun bigstring ~off ~len ->
           match fd with
           | `Plain fd -> Lwt_bytes.read fd bigstring off len
           | `Tls t -> Tls_lwt.Unix.read_bytes t bigstring off len))
    (function
    | Unix.Unix_error (Unix.EBADF, _, _) as exn ->
      Logs.err (fun m -> m "bad fd in read");
      Lwt.fail exn
    | exn ->
      Logs.err (fun m -> m "exception read %s" (Printexc.to_string exn));
      (match fd with `Plain fd -> Lwt_unix.close fd | `Tls t -> Tls_lwt.Unix.close t) >>= fun () ->
      Lwt.fail exn)

  >>= fun bytes_read ->
  if bytes_read = 0 then
    Lwt.return `Eof
  else
    Lwt.return (`Ok bytes_read)

let shutdown socket command =
  try Lwt_unix.shutdown socket command
  with Unix.Unix_error (Unix.ENOTCONN, _, _) -> ()

module Config = Httpaf.Config

module Client = struct
  let request ?(config=Config.default) socket request ~error_handler ~response_handler =
    let module Client_connection = Httpaf.Client_connection in
    let request_body, connection =
      Client_connection.request ~config request ~error_handler ~response_handler in


    let read_buffer = Buffer.create config.read_buffer_size in
    let read_loop_exited, notify_read_loop_exited = Lwt.wait () in

    let read_loop () =
      let rec read_loop_step () =
        match Client_connection.next_read_operation connection with
        | `Read ->
          read socket read_buffer >>= begin function
          | `Eof ->
            Buffer.get read_buffer ~f:(fun bigstring ~off ~len ->
              Client_connection.read_eof connection bigstring ~off ~len)
            |> ignore;
            read_loop_step ()
          | `Ok _ ->
            Buffer.get read_buffer ~f:(fun bigstring ~off ~len ->
              Client_connection.read connection bigstring ~off ~len)
            |> ignore;
            read_loop_step ()
          end

        | `Close ->
          Lwt.wakeup_later notify_read_loop_exited ();
          match socket with
          | `Plain socket ->
            if not (Lwt_unix.state socket = Lwt_unix.Closed) then begin
              shutdown socket Unix.SHUTDOWN_RECEIVE
            end;
            Lwt.return_unit
          | `Tls _t -> (* no shutdown of receive part in TLS *)
            Lwt.return_unit
      in

      Lwt.async (fun () ->
        Lwt.catch
          read_loop_step
          (fun exn ->
            Client_connection.report_exn connection exn;
            Lwt.return_unit))
    in


    let writev =
      match socket with
      | `Plain socket -> Faraday_lwt_unix.writev_of_fd socket
      | `Tls t ->
        fun vs ->
          let cs =
            List.map (fun { Faraday.buffer ; off ; len } ->
                Cstruct.of_bigarray ~off ~len buffer) vs
          in
          Lwt.catch (fun () ->
              Tls_lwt.Unix.writev t cs >|= fun () ->
              `Ok (Cstruct.lenv cs))
            (fun exn ->
               Logs.err (fun m -> m "exception writev: %s" (Printexc.to_string exn));
               Tls_lwt.Unix.close t >|= fun () ->
               `Closed)
    in
    let write_loop_exited, notify_write_loop_exited = Lwt.wait () in

    let rec write_loop () =
      let rec write_loop_step () =
        match Client_connection.next_write_operation connection with
        | `Write io_vectors ->
          writev io_vectors >>= fun result ->
          Client_connection.report_write_result connection result;
          write_loop_step ()

        | `Yield ->
          Client_connection.yield_writer connection write_loop;
          Lwt.return_unit

        | `Close _ ->
          Lwt.wakeup_later notify_write_loop_exited ();
          Lwt.return_unit
      in

      Lwt.async (fun () ->
        Lwt.catch
          write_loop_step
          (fun exn ->
            Client_connection.report_exn connection exn;
            Lwt.return_unit))
    in


    read_loop ();
    write_loop ();

    Lwt.async (fun () ->
      Lwt.join [read_loop_exited; write_loop_exited] >>= fun () ->

      match socket with
      | `Plain socket ->
        if Lwt_unix.state socket <> Lwt_unix.Closed then
          Lwt.catch
            (fun () -> Lwt_unix.close socket)
            (fun _exn -> Lwt.return_unit)
        else
          Lwt.return_unit
      | `Tls t -> Tls_lwt.Unix.close t);

    request_body
end
