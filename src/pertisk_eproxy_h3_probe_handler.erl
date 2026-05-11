-module(pertisk_eproxy_h3_probe_handler).

-export([handle_request/5]).

handle_request(Conn, StreamId, _Method, _Path, _Headers) ->
    ok = quic_h3:send_response(Conn, StreamId, 200, [{<<"content-type">>, <<"text/plain">>}]),
    _ = quic_h3:send_data(Conn, StreamId, <<"h3 probe ok">>, true),
    ok.
