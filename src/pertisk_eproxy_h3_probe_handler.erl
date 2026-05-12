-module(pertisk_eproxy_h3_probe_handler).

-export([handle_request/5]).

handle_request(Conn, StreamId, Method, Path, Headers) ->
    T0 = erlang:monotonic_time(millisecond),
    Host = authority_host(Headers),
    ok = quic_h3:send_response(Conn, StreamId, 200, [{<<"content-type">>, <<"text/plain">>}]),
    _ = quic_h3:send_data(Conn, StreamId, <<"h3 probe ok">>, true),
    Dt = max(0, erlang:monotonic_time(millisecond) - T0),
    catch pertisk_eproxy_access_log:log_proxy(Host, Method, Path, 200, Dt, 'HTTP/3'),
    ok.

authority_host(Headers) ->
    case lists:keyfind(<<":authority">>, 1, Headers) of
        {_, V} when is_binary(V) -> V;
        _ -> <<"-">>
    end.
