-module(pertisk_eproxy_admin_ws_handler_tests).

-include_lib("eunit/include/eunit.hrl").

ensure_env() ->
    pertisk_eproxy_test_helpers:ensure_config(),
    case whereis(pertisk_eproxy_access_log) of
        undefined -> {ok, _} = pertisk_eproxy_access_log:start_link();
        _ -> ok
    end.

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

with_mock_req(Opts, Fun) ->
    unload_mocks([cowboy_req, pertisk_eproxy_response_headers, pertisk_eproxy_auth]),
    meck:new(cowboy_req, [unstick]),
    meck:new(pertisk_eproxy_response_headers, [unstick]),
    meck:expect(pertisk_eproxy_response_headers, merge, fun(H) -> H end),
    meck:expect(pertisk_eproxy_response_headers, apply_cowboy_req, fun(Req) -> Req end),
    meck:expect(cowboy_req, host, fun(_) -> maps:get(host, Opts, <<"localhost">>) end),
    meck:expect(cowboy_req, path, fun(_) -> maps:get(path, Opts, <<"/api/realtime">>) end),
    meck:expect(cowboy_req, version, fun(_) -> 'HTTP/1.1' end),
    meck:expect(cowboy_req, header, fun(Key, _Req, Default) ->
        maps:get(Key, maps:get(headers, Opts, #{}), Default)
    end),
    meck:expect(cowboy_req, reply, fun(Status, _Hdrs, Body, Req) ->
        Req#{reply => {Status, Body}}
    end),
    OldAuth = application:get_env(pertisk_eproxy, admin_auth),
    application:set_env(pertisk_eproxy, admin_auth, maps:get(auth_mode, Opts, disabled)),
    meck:new(pertisk_eproxy_auth, [unstick]),
    meck:expect(pertisk_eproxy_auth, auth_mode, fun() -> maps:get(auth_mode, Opts, disabled) end),
    meck:expect(pertisk_eproxy_auth, bearer_from_request, fun(_) ->
        maps:get(bearer, Opts, error)
    end),
    meck:expect(pertisk_eproxy_auth, verify_token, fun(Token) ->
        maps:get(verify, Opts, {ok, Token})
    end),
    try Fun(#{}) after
        unload_mocks([cowboy_req, pertisk_eproxy_response_headers, pertisk_eproxy_auth]),
        case OldAuth of
            {ok, V} -> application:set_env(pertisk_eproxy, admin_auth, V);
            undefined -> application:unset_env(pertisk_eproxy, admin_auth)
        end
    end.

with_server(Fun) ->
    case whereis(pertisk_eproxy_admin_realtime) of
        undefined ->
            {ok, Pid} = pertisk_eproxy_admin_realtime:start_link(),
            try Fun() after pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000) end;
        _ ->
            Fun()
    end.

init_auth_disabled_upgrades_test() ->
    ensure_env(),
    with_mock_req(#{auth_mode => disabled}, fun(Req) ->
        ?assertMatch({cowboy_websocket, _, #{authenticated := true}, _},
            pertisk_eproxy_admin_ws_handler:init(Req, #{}))
    end).

init_local_valid_token_test() ->
    ensure_env(),
    with_mock_req(#{
        auth_mode => local,
        bearer => {ok, <<"good-token">>},
        verify => {ok, <<"admin">>}
    }, fun(Req) ->
        ?assertMatch({cowboy_websocket, _, #{authenticated := true}, _},
            pertisk_eproxy_admin_ws_handler:init(Req, #{}))
    end).

init_local_pending_auth_test() ->
    ensure_env(),
    with_mock_req(#{auth_mode => local, bearer => error}, fun(Req) ->
        ?assertMatch({cowboy_websocket, _, #{authenticated := false}, _},
            pertisk_eproxy_admin_ws_handler:init(Req, #{}))
    end).

init_local_invalid_token_test() ->
    ensure_env(),
    with_mock_req(#{
        auth_mode => local,
        bearer => {ok, <<"bad">>},
        verify => {error, unauthorized}
    }, fun(Req) ->
        ?assertMatch({ok, #{reply := {401, _}}, _},
            pertisk_eproxy_admin_ws_handler:init(Req, #{}))
    end).

websocket_init_authenticated_test() ->
    ensure_env(),
    with_server(fun() ->
        State = #{authenticated => true},
        ?assertMatch({[{text, _}], #{timer_ref := _}},
            pertisk_eproxy_admin_ws_handler:websocket_init(State))
    end).

websocket_init_pending_auth_test() ->
    State = #{authenticated => false},
    ?assertMatch({ok, #{auth_ref := _}},
        pertisk_eproxy_admin_ws_handler:websocket_init(State)).

websocket_handle_auth_success_test() ->
    ensure_env(),
    unload_mocks([pertisk_eproxy_auth]),
    meck:new(pertisk_eproxy_auth, [unstick]),
    meck:expect(pertisk_eproxy_auth, verify_token, fun(_) -> {ok, <<"user">>} end),
    with_server(fun() ->
        Frame = thoas:encode(#{<<"type">> => <<"auth">>, <<"token">> => <<"secret">>}),
        State = #{authenticated => false},
        ?assertMatch({[{text, _}], #{authenticated := true, timer_ref := _}},
            pertisk_eproxy_admin_ws_handler:websocket_handle({text, Frame}, State))
    end),
    pertisk_eproxy_test_helpers:unload_mocks([pertisk_eproxy_auth]).

websocket_handle_auth_bad_frame_test() ->
    State = #{authenticated => false},
    ?assertMatch({[{close, 4401, _}], _},
        pertisk_eproxy_admin_ws_handler:websocket_handle({text, <<"not-json">>}, State)).

websocket_handle_auth_invalid_token_test() ->
    unload_mocks([pertisk_eproxy_auth]),
    meck:new(pertisk_eproxy_auth, [unstick]),
    meck:expect(pertisk_eproxy_auth, verify_token, fun(_) -> {error, unauthorized} end),
    Frame = thoas:encode(#{<<"type">> => <<"auth">>, <<"token">> => <<"bad">>}),
    State = #{authenticated => false},
    ?assertMatch({[{close, 4401, _}], _},
        pertisk_eproxy_admin_ws_handler:websocket_handle({text, Frame}, State)),
    pertisk_eproxy_test_helpers:unload_mocks([pertisk_eproxy_auth]).

websocket_handle_ignores_when_authenticated_test() ->
    State = #{authenticated => true},
    ?assertMatch({ok, _},
        pertisk_eproxy_admin_ws_handler:websocket_handle({text, <<"ping">>}, State)).

websocket_info_push_test() ->
    State = #{authenticated => true},
    ?assertMatch({[{text, <<"push">>}], _},
        pertisk_eproxy_admin_ws_handler:websocket_info({admin_ws_push, <<"push">>}, State)).

websocket_info_tick_test() ->
    ensure_env(),
    with_server(fun() ->
        TRef = erlang:send_after(60000, self(), noop),
        State = #{authenticated => true, timer_ref => TRef},
        ?assertMatch({[{text, _}], #{timer_ref := _}},
            pertisk_eproxy_admin_ws_handler:websocket_info(tick, State))
    end).

websocket_info_auth_timeout_test() ->
    State = #{authenticated => false},
    ?assertMatch({[{close, 4401, _}], _},
        pertisk_eproxy_admin_ws_handler:websocket_info(auth_timeout, State)).

websocket_info_other_test() ->
    State = #{authenticated => true},
    ?assertMatch({ok, _},
        pertisk_eproxy_admin_ws_handler:websocket_info(other, State)).

terminate_cancels_timer_test() ->
    ensure_env(),
    with_server(fun() ->
        TRef = erlang:send_after(60000, self(), noop),
        ?assertEqual(ok, pertisk_eproxy_admin_ws_handler:terminate(normal, #{}, #{timer_ref => TRef}))
    end).

terminate_atom_state_test() ->
    ?assertEqual(ok, pertisk_eproxy_admin_ws_handler:terminate(normal, #{}, realtime)).
