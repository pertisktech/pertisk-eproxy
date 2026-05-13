%% @doc Placeholder {@link pertisk_h3_transport} for future Quicer/msquic HTTP/3.
%%
%% Quicer today exposes QUIC streams, not an HTTP/3 server API equivalent to {@code quic_h3}.
%% {@link start_server/3} returns `{error, {not_implemented, quicer_h3}}' so the proxy logs
%% and continues without UDP listeners when `{@code h3_transport, quicer}' is set.
-module(pertisk_h3_transport_quicer_stub).

-behaviour(pertisk_h3_transport).

-export([
    ensure_deps_started/0,
    start_server/3,
    stop_server/1,
    send_response/4,
    send_data/4,
    set_stream_handler/3,
    collect_request_body/4,
    collect_request_body/5,
    client_peer_ip/2
]).

ensure_deps_started() ->
    %% When `quicer' is added to the release, this will preload the app; otherwise ignore.
    _ = application:ensure_all_started(quicer),
    ok.

start_server(_Name, _Port, _Opts) ->
    {error, {not_implemented, quicer_h3}}.

stop_server(_Name) ->
    ok.

send_response(_Conn, _StreamId, _Status, _Headers) ->
    {error, not_implemented}.

send_data(_Conn, _StreamId, _Data, _Fin) ->
    {error, not_implemented}.

set_stream_handler(_Conn, _StreamId, _HandlerPid) ->
    ok.

collect_request_body(Conn, StreamId, Acc, TimeoutMs) ->
    collect_request_body(Conn, StreamId, Acc, TimeoutMs, undefined).

collect_request_body(_Conn, _StreamId, Acc, _TimeoutMs, _ExpectCL) ->
    Acc.

client_peer_ip(_Conn, _Headers) ->
    <<"127.0.0.1">>.
