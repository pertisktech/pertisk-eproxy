%% @doc {@link pertisk_h3_transport} implementation backed by benoitc/erlang_quic (`quic_h3`, `quic`).
-module(pertisk_h3_transport_erlang_quic).

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
    _ = application:ensure_all_started(quic),
    ok.

start_server(Name, Port, Opts) ->
    quic_h3:start_server(Name, Port, Opts).

stop_server(Name) ->
    quic_h3:stop_server(Name).

send_response(Conn, StreamId, Status, Headers) ->
    quic_h3:send_response(Conn, StreamId, Status, Headers).

send_data(Conn, StreamId, Data, Fin) ->
    quic_h3:send_data(Conn, StreamId, Data, Fin).

set_stream_handler(Conn, StreamId, HandlerPid) ->
    quic_h3:set_stream_handler(Conn, StreamId, HandlerPid).

collect_request_body(Conn, StreamId, Acc, TimeoutMs) ->
    collect_request_body(Conn, StreamId, Acc, TimeoutMs, undefined).

%% When {@code ExpectCL} is set, return as soon as that many body bytes are buffered.
%% Chrome often sends a full {@code content-length} body with FIN on a later QUIC/H3 frame;
%% waiting only for {@code Fin} matched ~{@code H3_BODY_AUTH_CAP_MS} on small POSTs (e.g. auth refresh).
collect_request_body(_Conn, _StreamId, _Acc, _TimeoutMs, 0) ->
    <<>>;
collect_request_body(_Conn, _StreamId, Acc, _TimeoutMs, CL) when is_integer(CL), CL > 0, byte_size(Acc) >= CL ->
    binary:part(Acc, 0, CL);
collect_request_body(_Conn, _StreamId, Acc, TimeoutMs, undefined) when TimeoutMs =< 0 ->
    Acc;
collect_request_body(_Conn, _StreamId, Acc, TimeoutMs, CL) when is_integer(CL), TimeoutMs =< 0 ->
    Acc;
collect_request_body(Conn, StreamId, Acc, TimeoutMs, undefined) ->
    T0 = erlang:monotonic_time(millisecond),
    receive
        {quic_h3, Conn, {data, StreamId, Data, true}} ->
            <<Acc/binary, Data/binary>>;
        {quic_h3, Conn, {data, StreamId, Data, false}} ->
            Elapsed = erlang:monotonic_time(millisecond) - T0,
            Remaining = TimeoutMs - Elapsed,
            collect_request_body(Conn, StreamId, <<Acc/binary, Data/binary>>, Remaining, undefined)
    after TimeoutMs ->
        Acc
    end;
collect_request_body(Conn, StreamId, Acc, TimeoutMs, CL) when is_integer(CL), CL > 0 ->
    T0 = erlang:monotonic_time(millisecond),
    receive
        {quic_h3, Conn, {data, StreamId, Data, Fin}} ->
            NewAcc = <<Acc/binary, Data/binary>>,
            case byte_size(NewAcc) >= CL of
                true ->
                    binary:part(NewAcc, 0, CL);
                false when Fin =:= true ->
                    NewAcc;
                false ->
                    Elapsed = erlang:monotonic_time(millisecond) - T0,
                    Remaining = TimeoutMs - Elapsed,
                    collect_request_body(Conn, StreamId, NewAcc, Remaining, CL)
            end
    after TimeoutMs ->
        Acc
    end.

client_peer_ip(H3Conn, Headers) ->
    case lists:keyfind(<<"x-forwarded-for">>, 1, Headers) of
        {_, Xff} when is_binary(Xff) ->
            hd(binary:split(Xff, [<<", ">>, <<",">>]));
        _ ->
            try
                QuicConn = quic_h3:get_quic_conn(H3Conn),
                case quic:peername(QuicConn) of
                    {ok, {PeerIp, _Port}} -> list_to_binary(inet:ntoa(PeerIp));
                    _ -> <<"127.0.0.1">>
                end
            catch
                _:_ -> <<"127.0.0.1">>
            end
    end.
