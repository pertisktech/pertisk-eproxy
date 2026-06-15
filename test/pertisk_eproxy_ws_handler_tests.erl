-module(pertisk_eproxy_ws_handler_tests).

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

with_mock_req(Opts, Fun) ->
    unload_mocks([cowboy_req, pertisk_eproxy_response_headers]),
    meck:new(cowboy_req, [unstick]),
    meck:new(pertisk_eproxy_response_headers, [unstick]),
    meck:expect(pertisk_eproxy_response_headers, merge, fun(H) -> H end),
    meck:expect(pertisk_eproxy_response_headers, apply_cowboy_req, fun(Req) -> Req end),
    Host = maps:get(host, Opts, <<"ws.example">>),
    Path = maps:get(path, Opts, <<"/ws">>),
    Qs = maps:get(qs, Opts, <<>>),
    Headers = maps:get(headers, Opts, #{}),
    Peer = maps:get(peer, Opts, {{127, 0, 0, 1}, 12345}),
    Version = maps:get(version, Opts, 'HTTP/1.1'),
    Scheme = maps:get(scheme, Opts, http),
    meck:expect(cowboy_req, host, fun(_) -> Host end),
    meck:expect(cowboy_req, path, fun(_) -> Path end),
    meck:expect(cowboy_req, qs, fun(_) -> Qs end),
    meck:expect(cowboy_req, headers, fun(_) -> Headers end),
    meck:expect(cowboy_req, header, fun(Key, _Req) ->
        case Key of
            <<"x-forwarded-for">> -> maps:get(xff, Opts, undefined);
            _ -> undefined
        end
    end),
    meck:expect(cowboy_req, header, fun(Key, _Req, Default) ->
        case Key of
            <<"sec-websocket-protocol">> -> maps:get(subproto, Opts, Default);
            _ -> Default
        end
    end),
    meck:expect(cowboy_req, peer, fun(_) -> Peer end),
    meck:expect(cowboy_req, version, fun(_) -> Version end),
    meck:expect(cowboy_req, scheme, fun(_) -> Scheme end),
    meck:expect(cowboy_req, set_resp_header, fun(K, V, Req) ->
        H = maps:get(resp_headers, Req, #{}),
        Req#{resp_headers => H#{K => V}}
    end),
    meck:expect(cowboy_req, reply, fun(Status, _Hdrs, Body, Req) ->
        Req#{reply => {Status, Body}}
    end),
    Req = maps:get(req, Opts, #{}),
    try Fun(Req) after
        pertisk_eproxy_test_helpers:unload_mocks([cowboy_req, pertisk_eproxy_response_headers])
    end.

ws_state() ->
    #{
        host => <<"ws.example">>,
        backend => <<"web">>,
        upstream_addr => <<"127.0.0.1:8080">>,
        upstream_path => <<"/ws">>,
        ws_headers => [],
        conn_pid => self(),
        stream_ref => stream1,
        upstream_ws_ready => false,
        ws_out_buffer => []
    }.

init_no_route_test() ->
    unload_mocks([pertisk_eproxy_router, pertisk_eproxy_backend, cowboy_req, gun]),
    meck:new(pertisk_eproxy_router, [unstick]),
    meck:expect(pertisk_eproxy_router, route, fun(_, _) -> {error, no_route} end),
    with_mock_req(#{host => <<"1.2.3.4">>, path => <<"/api/realtime">>}, fun(Req) ->
        ?assertMatch({ok, #{reply := {404, _}}, _}, pertisk_eproxy_ws_handler:init(Req, #{}))
    end),
    with_mock_req(#{host => <<"missing.example">>, path => <<"/ws">>}, fun(Req) ->
        ?assertMatch({ok, #{reply := {404, _}}, _}, pertisk_eproxy_ws_handler:init(Req, #{}))
    end),
    pertisk_eproxy_test_helpers:unload_mocks([pertisk_eproxy_router]).

init_no_healthy_upstream_test() ->
    unload_mocks([pertisk_eproxy_router, pertisk_eproxy_backend, cowboy_req, gun]),
    meck:new(pertisk_eproxy_router, [unstick]),
    meck:expect(pertisk_eproxy_router, route, fun(_, _) ->
        {ok, #{upstream_path => <<"/">>, backend => <<"web">>}}
    end),
    meck:new(pertisk_eproxy_backend, [unstick]),
    meck:expect(pertisk_eproxy_backend, pick_upstream, fun(_, _) -> {error, no_healthy_upstream} end),
    with_mock_req(#{}, fun(Req) ->
        ?assertMatch({ok, #{reply := {502, _}}, _}, pertisk_eproxy_ws_handler:init(Req, #{}))
    end),
    pertisk_eproxy_test_helpers:unload_mocks([pertisk_eproxy_backend, pertisk_eproxy_router]).

init_upgrade_success_test() ->
    unload_mocks([pertisk_eproxy_router, pertisk_eproxy_backend, cowboy_req, gun]),
    meck:new(pertisk_eproxy_router, [unstick]),
    meck:expect(pertisk_eproxy_router, route, fun(_, _) ->
        {ok, #{upstream_path => <<"/up">>, backend => <<"web">>}}
    end),
    meck:new(pertisk_eproxy_backend, [unstick]),
    meck:expect(pertisk_eproxy_backend, pick_upstream, fun(_, _) ->
        {ok, <<"127.0.0.1:8080">>}
    end),
    with_mock_req(#{
        qs => <<"a=1">>,
        headers => #{<<"cookie">> => <<"s=1">>},
        subproto => <<"chat, base64">>
    }, fun(Req) ->
        ?assertMatch({cowboy_websocket, _, #{upstream_path := <<"/up?a=1">>}, _},
            pertisk_eproxy_ws_handler:init(Req, #{}))
    end),
    pertisk_eproxy_test_helpers:unload_mocks([pertisk_eproxy_backend, pertisk_eproxy_router]).

init_console_subprotocol_test() ->
    unload_mocks([pertisk_eproxy_router, pertisk_eproxy_backend, cowboy_req, gun]),
    meck:new(pertisk_eproxy_router, [unstick]),
    meck:expect(pertisk_eproxy_router, route, fun(_, _) ->
        {ok, #{upstream_path => <<"/api2/json/novnc/termproxy">>, backend => <<"web">>}}
    end),
    meck:new(pertisk_eproxy_backend, [unstick]),
    meck:expect(pertisk_eproxy_backend, pick_upstream, fun(_, _) ->
        {ok, <<"127.0.0.1:8080">>}
    end),
    with_mock_req(#{
        path => <<"/api2/json/novnc/termproxy">>,
        subproto => <<"base64, binary">>
    }, fun(Req) ->
        ?assertMatch({cowboy_websocket, _, _, _}, pertisk_eproxy_ws_handler:init(Req, #{}))
    end),
    pertisk_eproxy_test_helpers:unload_mocks([pertisk_eproxy_backend, pertisk_eproxy_router]).

websocket_init_success_test() ->
    unload_mocks([gun]),
    meck:new(gun, [unstick]),
    meck:expect(gun, open, fun(_, _, _) -> {ok, gun_pid} end),
    meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
    meck:expect(gun, ws_upgrade, fun(_, _, _) -> stream1 end),
    State = (ws_state())#{upstream_addr => <<"127.0.0.1:8080">>},
    ?assertMatch({ok, #{conn_pid := gun_pid}}, pertisk_eproxy_ws_handler:websocket_init(State)),
    pertisk_eproxy_test_helpers:unload_mocks([gun]).

websocket_init_k8s_sync_handshake_test() ->
    unload_mocks([gun]),
    meck:new(gun, [unstick]),
    meck:expect(gun, open, fun(_, _, _) -> {ok, self()} end),
    meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
    meck:expect(gun, ws_upgrade, fun(_ConnPid, _Path, _Headers) ->
        self() ! {gun_upgrade, self(), stream1, [<<"websocket">>], []},
        stream1
    end),
    State = (ws_state())#{
        upstream_addr => <<"127.0.0.1:8080">>,
        k8s_remote_cmd => true,
        upstream_path => <<"/api/v1/namespaces/default/pods/nginx-pod/exec">>
    },
    ?assertMatch(
        {ok, #{conn_pid := _, stream_ref := stream1, upstream_ws_ready := true}},
        pertisk_eproxy_ws_handler:websocket_init(State)
    ),
    pertisk_eproxy_test_helpers:unload_mocks([gun]).

websocket_init_open_failure_test() ->
    unload_mocks([gun]),
    meck:new(gun, [unstick]),
    meck:expect(gun, open, fun(_, _, _) -> {error, refused} end),
    ?assertMatch({stop, _}, pertisk_eproxy_ws_handler:websocket_init(ws_state())),
    pertisk_eproxy_test_helpers:unload_mocks([gun]).

websocket_init_await_failure_test() ->
    unload_mocks([gun]),
    meck:new(gun, [unstick]),
    meck:expect(gun, open, fun(_, _, _) -> {ok, gun_pid} end),
    meck:expect(gun, await_up, fun(_, _) -> {error, timeout} end),
    meck:expect(gun, close, fun(_) -> ok end),
    ?assertMatch({stop, _}, pertisk_eproxy_ws_handler:websocket_init(ws_state())),
    pertisk_eproxy_test_helpers:unload_mocks([gun]).

websocket_init_tls_upstream_test() ->
    unload_mocks([gun]),
    meck:new(gun, [unstick]),
    meck:expect(gun, open, fun(Host, 443, Opts) ->
        ?assertEqual(tls, maps:get(transport, Opts)),
        {ok, gun_pid}
    end),
    meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
    meck:expect(gun, ws_upgrade, fun(_, _, _) -> stream1 end),
    State = (ws_state())#{upstream_addr => <<"https://secure.example">>},
    ?assertMatch({ok, _}, pertisk_eproxy_ws_handler:websocket_init(State)),
    pertisk_eproxy_test_helpers:unload_mocks([gun]).

websocket_handle_paths_test() ->
    unload_mocks([gun]),
    meck:new(gun, [unstick]),
    meck:expect(gun, ws_send, fun(_, _, _) -> ok end),
    Ready = (ws_state())#{upstream_ws_ready => true},
    ?assertMatch({ok, _}, pertisk_eproxy_ws_handler:websocket_handle({text, <<"hi">>}, Ready)),
    Buf = (ws_state())#{ws_out_buffer => []},
    ?assertMatch({ok, #{ws_out_buffer := [_]}},
        pertisk_eproxy_ws_handler:websocket_handle({text, <<"hi">>}, Buf)),
    Full = Buf#{ws_out_buffer => lists:duplicate(64, {text, <<"x">>})},
    ?assertMatch({ok, _}, pertisk_eproxy_ws_handler:websocket_handle({text, <<"y">>}, Full)),
    ?assertMatch({ok, _},
        pertisk_eproxy_ws_handler:websocket_handle({text, <<"z">>}, (ws_state())#{conn_pid => undefined})),
    pertisk_eproxy_test_helpers:unload_mocks([gun]).

websocket_info_paths_test() ->
    unload_mocks([gun]),
    meck:new(gun, [unstick]),
    meck:expect(gun, ws_send, fun(_, _, _) -> ok end),
    State = ws_state(),
    ?assertMatch({[close], _},
        pertisk_eproxy_ws_handler:websocket_info({gun_ws, self(), stream1, close}, State)),
    ?assertMatch({[{text, <<"x">>}], _},
        pertisk_eproxy_ws_handler:websocket_info({gun_ws, self(), stream1, {text, <<"x">>}}, State)),
    Up = pertisk_eproxy_ws_handler:websocket_info(
        {gun_upgrade, self(), stream1, [<<"websocket">>], []},
        State#{ws_out_buffer => [{text, <<"buf">>}], upstream_ws_ready => false}
    ),
    ?assertMatch({ok, #{upstream_ws_ready := true, ws_out_buffer := []}}, Up),
    BadUp = pertisk_eproxy_ws_handler:websocket_info(
        {gun_upgrade, self(), stream1, [<<"h2">>], []},
        State
    ),
    ?assertMatch({[close], _}, BadUp),
    Resp101 = pertisk_eproxy_ws_handler:websocket_info(
        {gun_response, self(), stream1, fin, 101, #{}},
        State#{ws_out_buffer => [{text, <<"a">>}], upstream_ws_ready => false}
    ),
    ?assertMatch({ok, #{upstream_ws_ready := true}}, Resp101),
    ?assertMatch({[close], _},
        pertisk_eproxy_ws_handler:websocket_info(
            {gun_response, self(), stream1, fin, 403, #{}}, State
        )),
    ?assertMatch({[close], _},
        pertisk_eproxy_ws_handler:websocket_info({gun_error, self(), stream1, timeout}, State)),
    ?assertMatch({[close], _},
        pertisk_eproxy_ws_handler:websocket_info({gun_error, self(), stream1, {closed, normal}}, State)),
    ?assertMatch({[close], _},
        pertisk_eproxy_ws_handler:websocket_info({gun_down, self(), http, normal, []}, State)),
    ?assertMatch({ok, _},
        pertisk_eproxy_ws_handler:websocket_info(ignored, State)),
    pertisk_eproxy_test_helpers:unload_mocks([gun]).

terminate_paths_test() ->
    unload_mocks([gun, pertisk_eproxy_backend]),
    meck:new(gun, [unstick]),
    meck:expect(gun, close, fun(_) -> ok end),
    meck:new(pertisk_eproxy_backend, [unstick]),
    meck:expect(pertisk_eproxy_backend, done_upstream, fun(_, _, _) -> ok end),
    State = (ws_state())#{conn_pid => gun_pid},
    ?assertEqual(ok, pertisk_eproxy_ws_handler:terminate(normal, req, State)),
    ?assertEqual(ok, pertisk_eproxy_ws_handler:terminate(normal, req,
        maps:remove(conn_pid, State))),
    ?assertEqual(ok, pertisk_eproxy_ws_handler:terminate(normal, req, #{})),
    pertisk_eproxy_test_helpers:unload_mocks([pertisk_eproxy_backend, gun]).

init_forwarded_headers_test() ->
    unload_mocks([pertisk_eproxy_router, pertisk_eproxy_backend, cowboy_req, gun]),
    meck:new(pertisk_eproxy_router, [unstick]),
    meck:expect(pertisk_eproxy_router, route, fun(_, _) ->
        {ok, #{upstream_path => <<"/">>, backend => <<"web">>}}
    end),
    meck:new(pertisk_eproxy_backend, [unstick]),
    meck:expect(pertisk_eproxy_backend, pick_upstream, fun(_, _) -> {ok, <<"127.0.0.1:8080">>} end),
    with_mock_req(#{
        headers => #{
            <<"x-forwarded-for">> => <<"10.0.0.1">>,
            <<"x-forwarded-proto">> => <<"https">>,
            <<"authorization">> => <<"Bearer x">>
        },
        xff => <<"10.0.0.1">>,
        scheme => https,
        version => 'HTTP/2'
    }, fun(Req) ->
        ?assertMatch({cowboy_websocket, _, _, _}, pertisk_eproxy_ws_handler:init(Req, #{}))
    end),
    pertisk_eproxy_test_helpers:unload_mocks([pertisk_eproxy_backend, pertisk_eproxy_router]).

init_k8s_exec_forwarded_headers_test() ->
    unload_mocks([pertisk_eproxy_router, pertisk_eproxy_backend, cowboy_req, gun]),
    meck:new(pertisk_eproxy_router, [unstick]),
    meck:expect(pertisk_eproxy_router, route, fun(_, _) ->
        {ok, #{
            upstream_path =>
                <<"/api/v1/namespaces/default/pods/nginx-pod/exec">>,
            backend => <<"omni">>
        }}
    end),
    meck:new(pertisk_eproxy_backend, [unstick]),
    meck:expect(pertisk_eproxy_backend, pick_upstream, fun(_, _) ->
        {ok, <<"omni.internal:443">>}
    end),
    K8sProto =
        <<"v5.channel.k8s.io, v4.channel.k8s.io, v3.channel.k8s.io, channel.k8s.io">>,
    with_mock_req(#{
        host => <<"kube.omni.example">>,
        path => <<"/api/v1/namespaces/default/pods/nginx-pod/exec">>,
        qs => <<"command=sh&stdin=1&stdout=1&stderr=1&tty=1">>,
        headers => #{
            <<"authorization">> => <<"Bearer cluster-token">>,
            <<"sec-websocket-protocol">> => K8sProto
        },
        subproto => K8sProto
    }, fun(Req) ->
        Result = pertisk_eproxy_ws_handler:init(Req, #{}),
        ?assertMatch(
            {cowboy_websocket, _, #{k8s_remote_cmd := true}, #{idle_timeout := infinity, compress := false}},
            Result
        ),
        {cowboy_websocket, _, #{ws_headers := Hdrs}, _} = Result,
        ?assertEqual(
            {<<"host">>, <<"kube.omni.example">>},
            lists:keyfind(<<"host">>, 1, Hdrs)
        ),
        ?assertEqual(
            false,
            lists:keymember(<<"x-forwarded-for">>, 1, Hdrs)
        ),
        ?assertEqual(
            {<<"sec-websocket-protocol">>, K8sProto},
            lists:keyfind(<<"sec-websocket-protocol">>, 1, Hdrs)
        )
    end),
    pertisk_eproxy_test_helpers:unload_mocks([pertisk_eproxy_backend, pertisk_eproxy_router]).
