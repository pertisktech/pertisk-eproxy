#!/usr/bin/env python3
"""Patch erlang_quic quic_h3_connection for pertisk HTTP/3 reliability.

1. Reverts the incorrect \"sync GET invoke_handler\" change (gen_statem:call to self deadlock).

2. Defers handler work until quic_h3_connection is in state `connected/`:
   - `quic_h3:send_response/4` uses gen_statem:call; only `connected({call,...},{send_response,...})`
     handles it. Running invoke_handler during `h3_connecting/` left calls unanswered → hang / ERR_CLOSING.

3. Implementation: queue {StreamId, Method, Path, Headers} in the connection process (process dictionary),
   cast `pertisk_flush_deferred_h3_handlers` to self. In `h3_connecting` the flush cast is a no-op (queue
   kept). In `connected(enter)` and `connected(cast, pertisk_flush_deferred_h3_handlers, ...)` drain the
   queue and call invoke_handler/5 (spawned work, send_response then works).
"""
from __future__ import annotations

import sys
from pathlib import Path

MARKER = "pertisk-deferred-h3-invoke"

OLD_NOTIFY_DIRECT = """notify_headers_received(StreamId, Headers, Stream, Owner, server) ->
    Method = Stream#h3_stream.method,
    Path = Stream#h3_stream.path,
    Owner ! {quic_h3, self(), {request, StreamId, Method, Path, Headers}},
    invoke_handler(self(), StreamId, Method, Path, Headers);"""

OLD_NOTIFY_CAST_INVOKE = """notify_headers_received(StreamId, Headers, Stream, Owner, server) ->
    Method = Stream#h3_stream.method,
    Path = Stream#h3_stream.path,
    Owner ! {quic_h3, self(), {request, StreamId, Method, Path, Headers}},
    %% pertisk-deferred-h3-invoke: run handler after this transition commits stream state
    gen_statem:cast(self(), {pertisk_invoke_h3_handler, StreamId, Method, Path, Headers}),
    ok;"""

NEW_NOTIFY = """notify_headers_received(StreamId, Headers, Stream, Owner, server) ->
    Method = Stream#h3_stream.method,
    Path = Stream#h3_stream.path,
    Owner ! {quic_h3, self(), {request, StreamId, Method, Path, Headers}},
    %% pertisk-deferred-h3-invoke: queue until connected/ — send_response is only handled there
    ok = pertisk_queue_deferred_h3_handler(StreamId, Method, Path, Headers),
    gen_statem:cast(self(), pertisk_flush_deferred_h3_handlers),
    ok;"""

SYNC_INVOKE = """invoke_handler(Conn, StreamId, Method, Path, Headers) ->
    case get(h3_handler) of
        undefined ->
            ok;
        Fun when is_function(Fun, 5) ->
            %% pertisk: POST/PUT/PATCH must spawn so the state machine can deliver body
            %% frames while the handler blocks in receive; GET/HEAD/etc. run inline so
            %% response frames are ordered before the stack unwinds (fixes H3 clients).
            MethodBin = iolist_to_binary(Method),
            NeedsSpawn =
                MethodBin =:= <<"POST">>
                orelse MethodBin =:= <<"PUT">>
                orelse MethodBin =:= <<"PATCH">>,
            Wrap = fun() ->
                try
                    Fun(Conn, StreamId, Method, Path, Headers)
                catch
                    Class:Reason:Stack ->
                        error_logger:error_msg(
                            "HTTP/3 handler error: ~p:~p~n~p~n",
                            [Class, Reason, Stack]
                        )
                end
            end,
            case NeedsSpawn of
                true -> spawn(Wrap);
                false -> Wrap()
            end;
        Module when is_atom(Module) ->
            MethodBin = iolist_to_binary(Method),
            NeedsSpawn =
                MethodBin =:= <<"POST">>
                orelse MethodBin =:= <<"PUT">>
                orelse MethodBin =:= <<"PATCH">>,
            Wrap = fun() ->
                try
                    Module:handle_request(Conn, StreamId, Method, Path, Headers)
                catch
                    Class:Reason:Stack ->
                        error_logger:error_msg(
                            "HTTP/3 handler error: ~p:~p~n~p~n",
                            [Class, Reason, Stack]
                        )
                end
            end,
            case NeedsSpawn of
                true -> spawn(Wrap);
                false -> Wrap()
            end
    end."""

UPSTREAM_INVOKE = """invoke_handler(Conn, StreamId, Method, Path, Headers) ->
    case get(h3_handler) of
        undefined ->
            ok;
        Fun when is_function(Fun, 5) ->
            %% Spawn to avoid blocking the connection process
            spawn(fun() ->
                try
                    Fun(Conn, StreamId, Method, Path, Headers)
                catch
                    Class:Reason:Stack ->
                        error_logger:error_msg(
                            "HTTP/3 handler error: ~p:~p~n~p~n",
                            [Class, Reason, Stack]
                        )
                end
            end);
        Module when is_atom(Module) ->
            spawn(fun() ->
                try
                    Module:handle_request(Conn, StreamId, Method, Path, Headers)
                catch
                    Class:Reason:Stack ->
                        error_logger:error_msg(
                            "HTTP/3 handler error: ~p:~p~n~p~n",
                            [Class, Reason, Stack]
                        )
                end
            end)
    end."""

HELPERS_BEFORE_INVOKE = """pertisk_queue_deferred_h3_handler(StreamId, Method, Path, Headers) ->
    Q0 =
        case get(pertisk_deferred_h3_handler_q) of
            undefined -> queue:new();
            Q -> Q
        end,
    put(pertisk_deferred_h3_handler_q, queue:in({StreamId, Method, Path, Headers}, Q0)),
    ok.

pertisk_drain_deferred_h3_handlers() ->
    case erase(pertisk_deferred_h3_handler_q) of
        undefined ->
            ok;
        Q ->
            lists:foreach(
                fun({StreamId, Method, Path, Headers}) ->
                    _ = invoke_handler(self(), StreamId, Method, Path, Headers)
                end,
                queue:to_list(Q)
            )
    end.

"""

OLD_CONNECTED_ENTER = """connected(enter, _OldState, #state{owner = Owner} = State) ->
    Owner ! {quic_h3, self(), connected},
    {keep_state, State};"""

NEW_CONNECTED_ENTER = """connected(enter, _OldState, #state{owner = Owner} = State) ->
    Owner ! {quic_h3, self(), connected},
    pertisk_drain_deferred_h3_handlers(),
    {keep_state, State};"""

OLD_CAST_INVOKE_CONNECTED = """connected(cast, {pertisk_invoke_h3_handler, StreamId, Method, Path, Headers}, State) ->
    _ = invoke_handler(self(), StreamId, Method, Path, Headers),
    {keep_state, State};
"""

CAST_FLUSH_CONNECTED = """connected(cast, pertisk_flush_deferred_h3_handlers, State) ->
    pertisk_drain_deferred_h3_handlers(),
    {keep_state, State};
"""

OLD_CAST_INVOKE_H3_CONNECTING = """h3_connecting(cast, {pertisk_invoke_h3_handler, StreamId, Method, Path, Headers}, State) ->
    _ = invoke_handler(self(), StreamId, Method, Path, Headers),
    {keep_state, State};
"""

CAST_FLUSH_H3_CONNECTING = """h3_connecting(cast, pertisk_flush_deferred_h3_handlers, State) ->
    {keep_state, State};
"""

ANCHOR_CONNECTED_FLUSH = "connected(cast, {cancel_push, PushId}, #state{role = client} = State) ->"
ANCHOR_H3_CATCHALL = "h3_connecting(_EventType, _Event, _State) ->"


def fully_patched(text: str) -> bool:
    return (
        "pertisk_queue_deferred_h3_handler(StreamId, Method, Path, Headers) ->" in text
        and "pertisk_flush_deferred_h3_handlers" in text
        and "connected(cast, pertisk_flush_deferred_h3_handlers" in text
        and "h3_connecting(cast, pertisk_flush_deferred_h3_handlers" in text
        and "{pertisk_invoke_h3_handler, StreamId" not in text
    )


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: patch_quic_h3_invoke_handler.py <quic_h3_connection.erl>", file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    if not path.is_file():
        print(f"patch: skip, missing {path}", file=sys.stderr)
        return 0
    text = path.read_text(encoding="utf8")
    if fully_patched(text):
        return 0

    t = text

    if "pertisk: POST/PUT/PATCH must spawn" in t:
        if SYNC_INVOKE not in t:
            print("patch: expected sync invoke_handler block not found", file=sys.stderr)
            return 1
        t = t.replace(SYNC_INVOKE, UPSTREAM_INVOKE, 1)

    if OLD_NOTIFY_CAST_INVOKE in t:
        t = t.replace(OLD_NOTIFY_CAST_INVOKE, NEW_NOTIFY, 1)
    elif OLD_NOTIFY_DIRECT in t:
        t = t.replace(OLD_NOTIFY_DIRECT, NEW_NOTIFY, 1)
    elif "pertisk_queue_deferred_h3_handler" not in t:
        print("patch: notify_headers_received server clause not found", file=sys.stderr)
        return 1

    if "pertisk_queue_deferred_h3_handler(StreamId, Method, Path, Headers) ->" not in t:
        anchor = "invoke_handler(Conn, StreamId, Method, Path, Headers) ->"
        if anchor not in t:
            print("patch: invoke_handler anchor not found", file=sys.stderr)
            return 1
        t = t.replace(anchor, HELPERS_BEFORE_INVOKE + anchor, 1)

    if OLD_CAST_INVOKE_CONNECTED in t:
        t = t.replace(OLD_CAST_INVOKE_CONNECTED, CAST_FLUSH_CONNECTED, 1)
    elif "connected(cast, pertisk_flush_deferred_h3_handlers" not in t:
        if ANCHOR_CONNECTED_FLUSH not in t:
            print("patch: anchor for connected flush cast not found", file=sys.stderr)
            return 1
        t = t.replace(ANCHOR_CONNECTED_FLUSH, CAST_FLUSH_CONNECTED + ANCHOR_CONNECTED_FLUSH, 1)

    if OLD_CAST_INVOKE_H3_CONNECTING in t:
        t = t.replace(OLD_CAST_INVOKE_H3_CONNECTING, CAST_FLUSH_H3_CONNECTING, 1)
    elif "h3_connecting(cast, pertisk_flush_deferred_h3_handlers" not in t:
        if ANCHOR_H3_CATCHALL not in t:
            print("patch: anchor for h3_connecting flush cast not found", file=sys.stderr)
            return 1
        t = t.replace(ANCHOR_H3_CATCHALL, CAST_FLUSH_H3_CONNECTING + ANCHOR_H3_CATCHALL, 1)

    if OLD_CONNECTED_ENTER in t:
        t = t.replace(OLD_CONNECTED_ENTER, NEW_CONNECTED_ENTER, 1)
    elif "pertisk_drain_deferred_h3_handlers()" not in t:
        print("patch: connected(enter) must call pertisk_drain_deferred_h3_handlers/0", file=sys.stderr)
        return 1

    if t == text:
        print(f"patch: no changes for {path}", file=sys.stderr)
        return 0
    path.write_text(t, encoding="utf8")
    print(f"patch: updated {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
