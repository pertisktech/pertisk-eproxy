-module(pertisk_eproxy_h3_probe_handler_tests).

-include_lib("eunit/include/eunit.hrl").

unload_mocks(Mods) ->
    lists:foreach(
        fun(Mod) ->
            case lists:member(Mod, meck:mocked()) of
                true -> pertisk_eproxy_test_helpers:unload_mocks([Mod]);
                false -> ok
            end
        end,
        Mods
    ).

with_quic_h3_mock(Fun) ->
    unload_mocks([quic_h3, pertisk_eproxy_access_log]),
    meck:new(quic_h3, [unstick]),
    meck:new(pertisk_eproxy_access_log, [unstick]),
    meck:expect(quic_h3, send_response, fun(_Conn, _Stream, _Status, _Hdrs) -> ok end),
    meck:expect(quic_h3, send_data, fun(_Conn, _Stream, _Data, _Fin) -> ok end),
    meck:expect(pertisk_eproxy_access_log, log_proxy, fun(_, _, _, _, _, _, _) -> ok end),
    try Fun() after unload_mocks([quic_h3, pertisk_eproxy_access_log]) end.

handle_request_ok_test() ->
    with_quic_h3_mock(fun() ->
        Headers = [{<<":authority">>, <<"probe.example.com">>}],
        ?assertEqual(ok,
            pertisk_eproxy_h3_probe_handler:handle_request(self(), 1, <<"GET">>, <<"/">>, Headers))
    end).

handle_request_missing_authority_test() ->
    with_quic_h3_mock(fun() ->
        ?assertEqual(ok,
            pertisk_eproxy_h3_probe_handler:handle_request(self(), 2, <<"HEAD">>, <<"/h3">>, []))
    end).
