-module(pertisk_eproxy_metrics_handler_tests).

-include_lib("eunit/include/eunit.hrl").

unload_mocks(Mods) ->
    lists:foreach(
        fun(Mod) ->
            case lists:member(Mod, meck:mocked()) of
                true -> meck:unload(Mod);
                false -> ok
            end
        end,
        Mods
    ).

with_mock_req(Fun) ->
    unload_mocks([cowboy_req]),
    meck:new(cowboy_req, [unstick]),
    meck:expect(cowboy_req, reply, fun(Status, _Hdrs, Body, Req) ->
        Req#{reply => {Status, Body}}
    end),
    try Fun(#{}) after unload_mocks([cowboy_req]) end.

init_metrics_returns_200_test() ->
    pertisk_eproxy_test_helpers:ensure_metrics(),
    with_mock_req(fun(Req) ->
        ?assertMatch({ok, #{reply := {200, _}}, undefined},
            pertisk_eproxy_metrics_handler:init(Req, metrics))
    end).

init_health_returns_ok_test() ->
    with_mock_req(fun(Req) ->
        ?assertMatch({ok, #{reply := {200, <<"OK">>}}, undefined},
            pertisk_eproxy_metrics_handler:init(Req, health))
    end).
