-module(pertisk_eproxy_handler_tests).

-include_lib("eunit/include/eunit.hrl").

parse_upstream_host_port_test() ->
    ?assertEqual({"example.com", 80, tcp}, pertisk_eproxy_handler:parse_upstream("example.com")),
    ?assertEqual({"example.com", 8080, tcp}, pertisk_eproxy_handler:parse_upstream("example.com:8080")).

parse_upstream_https_test() ->
    ?assertEqual({"secure.example.com", 443, tls}, pertisk_eproxy_handler:parse_upstream("https://secure.example.com")).

parse_upstream_trims_slash_test() ->
    ?assertEqual({"host", 80, tcp}, pertisk_eproxy_handler:parse_upstream("host/")).

parse_upstream_binary_test() ->
    ?assertEqual({"127.0.0.1", 8080, tcp}, pertisk_eproxy_handler:parse_upstream(<<"127.0.0.1:8080">>)).

parse_upstream_http_scheme_test() ->
    ?assertEqual({"example.com", 80, tcp}, pertisk_eproxy_handler:parse_upstream("http://example.com")).

parse_upstream_https_custom_port_test() ->
    ?assertEqual({"secure.example.com", 8443, tls}, pertisk_eproxy_handler:parse_upstream("https://secure.example.com:8443")).

parse_upstream_ws_schemes_test() ->
    ?assertEqual({"ws.example.com", 80, tcp}, pertisk_eproxy_handler:parse_upstream("ws://ws.example.com")),
    ?assertEqual({"wss.example.com", 443, tls}, pertisk_eproxy_handler:parse_upstream("wss://wss.example.com")).

parse_upstream_ipv6_bracket_test() ->
    ?assertEqual({"::1", 8080, tcp}, pertisk_eproxy_handler:parse_upstream("[::1]:8080")).

parse_upstream_invalid_port_uses_default_port_test() ->
    ?assertEqual({"host:not-a-port", 80, tcp}, pertisk_eproxy_handler:parse_upstream("host:not-a-port")).

is_event_stream_accept_test() ->
    ?assert(pertisk_eproxy_handler:is_event_stream_accept(<<"text/event-stream">>)),
    ?assert(pertisk_eproxy_handler:is_event_stream_accept(<<"application/json, text/event-stream">>)),
    ?assertNot(pertisk_eproxy_handler:is_event_stream_accept(<<"application/json">>)).

is_sse_proxy_path_test() ->
    ?assert(pertisk_eproxy_handler:is_sse_proxy_path(<<"/api/v1/stream/foo">>)),
    ?assert(pertisk_eproxy_handler:is_sse_proxy_path(<<"/user/events">>)),
    ?assertNot(pertisk_eproxy_handler:is_sse_proxy_path(<<"/api/health">>)).

is_sse_proxy_request_test() ->
    H = #{<<"accept">> => <<"text/event-stream">>},
    ?assert(pertisk_eproxy_handler:is_sse_proxy_request(<<"/">>, H)),
    ?assert(pertisk_eproxy_handler:is_sse_proxy_request(<<"/api/v1/stream/x">>, #{})).

headers_have_sse_auth_map_test() ->
    ?assert(pertisk_eproxy_handler:headers_have_sse_auth(#{<<"authorization">> => <<"Bearer x">>})),
    ?assert(pertisk_eproxy_handler:headers_have_sse_auth(#{<<"cookie">> => <<"session=1">>})),
    ?assertNot(pertisk_eproxy_handler:headers_have_sse_auth(#{})).

headers_have_sse_auth_list_test() ->
    ?assert(pertisk_eproxy_handler:headers_have_sse_auth([{<<"authorization">>, <<"Bearer x">>}])),
    ?assertNot(pertisk_eproxy_handler:headers_have_sse_auth([])).

upstream_req_kind_test() ->
    H = #{<<"accept">> => <<"text/event-stream">>},
    ?assertEqual(eventstream, pertisk_eproxy_handler:upstream_req_kind(<<"/">>, H)),
    G = #{<<"content-type">> => <<"application/grpc">>},
    ?assertEqual(grpc, pertisk_eproxy_handler:upstream_req_kind(<<"/">>, G)),
    ?assertEqual(http, pertisk_eproxy_handler:upstream_req_kind(<<"/">>, #{})).

gun_protocols_for_eventstream_test() ->
    ?assertEqual([http2, http], pertisk_eproxy_handler:gun_protocols_for_eventstream(tls)),
    ?assertEqual([http], pertisk_eproxy_handler:gun_protocols_for_eventstream(tcp)).

eventstream_upstream_retryable_test() ->
    ?assert(pertisk_eproxy_handler:eventstream_upstream_retryable({connect, timeout})),
    ?assert(pertisk_eproxy_handler:eventstream_upstream_retryable(timeout)),
    ?assert(pertisk_eproxy_handler:eventstream_upstream_retryable({await_up, timeout})),
    ?assert(pertisk_eproxy_handler:eventstream_upstream_retryable({stream_error, closed})),
    ?assert(pertisk_eproxy_handler:eventstream_upstream_retryable({await_response_unexpected, bad})),
    ?assertNot(pertisk_eproxy_handler:eventstream_upstream_retryable({error, refused})).

parse_upstream_grpc_scheme_test() ->
    ?assertEqual({"grpc.example.com", 80, tcp}, pertisk_eproxy_handler:parse_upstream("grpc://grpc.example.com")).

parse_upstream_grpcs_scheme_test() ->
    ?assertEqual({"secure.example.com", 443, tls}, pertisk_eproxy_handler:parse_upstream("grpcs://secure.example.com")).

upstream_req_kind_connect_test() ->
    H = #{<<"content-type">> => <<"application/connect+json">>},
    ?assertEqual(grpc, pertisk_eproxy_handler:upstream_req_kind(<<"/">>, H)).

upstream_req_kind_grpc_web_test() ->
    H = #{<<"content-type">> => <<"application/grpc-web+proto">>},
    ?assertEqual(grpc, pertisk_eproxy_handler:upstream_req_kind(<<"/">>, H)).

upstream_req_kind_grpc_metadata_test() ->
    H = #{<<"grpc-metadata-x">> => <<"1">>},
    ?assertEqual(grpc, pertisk_eproxy_handler:upstream_req_kind(<<"/">>, H)).

is_connect_service_path_omni_test() ->
  ?assert(pertisk_eproxy_handler:is_connect_service_path(
      <<"/api/omni.resources.ResourceService/Watch">>
  )),
  ?assertNot(pertisk_eproxy_handler:is_connect_service_path(<<"/api/health">>)).

upstream_req_kind_connect_path_test() ->
    ?assertEqual(
        grpc,
        pertisk_eproxy_handler:upstream_req_kind(
            <<"/api/omni.resources.ResourceService/Get">>, #{}
        )
    ).

upstream_gun_opts_grpc_test() ->
    Opts = pertisk_eproxy_handler:upstream_gun_opts_with_port("host", 443, tls, grpc),
    ?assertEqual([http2], maps:get(protocols, Opts)).

upstream_gun_opts_http_test() ->
    Opts = pertisk_eproxy_handler:upstream_gun_opts_with_port("host", 443, tls, http),
    ?assertEqual([http2, http], maps:get(protocols, Opts)).

site_advertise_http3_default_test() ->
    pertisk_eproxy_test_helpers:sync_router(
        [#{host => <<"h3.example.com">>, backend => <<"b">>, routes => []}],
        []
    ),
    ?assert(pertisk_eproxy_handler:site_advertise_http3(<<"h3.example.com">>)).

site_advertise_http3_disabled_test() ->
    pertisk_eproxy_test_helpers:sync_router(
        [
            #{
                host => <<"noh3.example.com">>,
                backend => <<"b">>,
                routes => [],
                advertise_http3 => false
            }
        ],
        []
    ),
    ?assertNot(pertisk_eproxy_handler:site_advertise_http3(<<"noh3.example.com">>)).

eventstream_upstream_candidates_test() ->
    Cands = pertisk_eproxy_handler:eventstream_upstream_candidates(
        <<"127.0.0.1">>, 8080, tls, <<"/api/v1/stream">>
    ),
    ?assert(is_list(Cands)),
    ?assert(length(Cands) > 0).

eventstream_upstream_candidates_tcp_test() ->
    [Cand] = pertisk_eproxy_handler:eventstream_upstream_candidates(
        <<"127.0.0.1">>, 8080, tcp, <<"/user/events">>
    ),
    ?assertEqual(<<"127.0.0.1">>, maps:get(host, Cand)),
    ?assertEqual(8080, maps:get(port, Cand)),
    ?assertEqual(tcp, maps:get(transport, Cand)),
    ?assertEqual([http], maps:get(protocols, Cand)).

eventstream_upstream_candidates_tls_test() ->
    [Cand] = pertisk_eproxy_handler:eventstream_upstream_candidates(
        <<"127.0.0.1">>, 443, tls, <<"/api/v1/stream">>
    ),
    ?assertEqual([http2, http], maps:get(protocols, Cand)).

eventstream_initial_await_timeout_test() ->
    T = pertisk_eproxy_handler:eventstream_initial_await_timeout_ms(<<"127.0.0.1:8080">>),
    ?assert(is_integer(T)),
    ?assert(T > 0).

should_sse_early_flush_test() ->
    H = #{<<"authorization">> => <<"Bearer x">>},
    ?assert(pertisk_eproxy_handler:should_sse_early_flush(<<"host">>, <<"/api/v1/stream">>, H)),
    ?assertNot(pertisk_eproxy_handler:should_sse_early_flush(<<"host">>, <<"/">>, #{})).

unload_mocks(Mods) ->
    pertisk_eproxy_test_helpers:unload_mocks(Mods).

ensure_mock(Mod, Opts) ->
    case lists:member(Mod, meck:mocked()) of
        true ->
            pertisk_eproxy_test_helpers:unload_mock(Mod, 250);
        false ->
            ok
    end,
    meck:new(Mod, Opts).

with_handler_req(Opts, Fun) ->
    pertisk_eproxy_test_helpers:ensure_metrics(),
    ensure_mock(cowboy_req, [unstick, no_link]),
    ensure_mock(pertisk_eproxy_router, [unstick, no_link]),
    ensure_mock(pertisk_eproxy_backend, [unstick, no_link, passthrough]),
    ensure_mock(pertisk_eproxy_config, [unstick, no_link, passthrough]),
    ensure_mock(pertisk_eproxy_compression, [unstick, no_link]),
    ensure_mock(pertisk_eproxy_metrics, [unstick, no_link]),
    ensure_mock(pertisk_eproxy_access_log, [unstick, no_link]),
    ensure_mock(pertisk_eproxy_alt_svc, [unstick, no_link]),
    ensure_mock(pertisk_eproxy_response_headers, [unstick, no_link]),
    meck:expect(pertisk_eproxy_response_headers, merge, fun(H) -> H end),
    meck:expect(pertisk_eproxy_alt_svc, merge_response_headers, fun(_Req, _Host, H) -> H end),
    meck:expect(pertisk_eproxy_compression, maybe_compress_cowboy, fun(_, _, H, B) -> {H, B} end),
    meck:expect(pertisk_eproxy_metrics, inc_request, fun(_, _, _) -> ok end),
    meck:expect(pertisk_eproxy_metrics, inc_site_request, fun(_, _, _) -> ok end),
    meck:expect(pertisk_eproxy_access_log, log_proxy, fun(_, _, _, _, _, _, _, _) -> ok end),
    meck:expect(pertisk_eproxy_config, backend_is_management_only, fun(_) ->
        maps:get(mgmt_only, Opts, false)
    end),
    meck:expect(pertisk_eproxy_config, is_management_upstream_addr, fun(_) -> false end),
    meck:expect(cowboy_req, method, fun(_) -> maps:get(method, Opts, <<"GET">>) end),
    meck:expect(cowboy_req, host, fun(_) -> maps:get(host, Opts, <<"example.com">>) end),
    meck:expect(cowboy_req, path, fun(_) -> maps:get(path, Opts, <<"/">>) end),
    meck:expect(cowboy_req, qs, fun(_) -> maps:get(qs, Opts, <<>>) end),
    meck:expect(cowboy_req, version, fun(_) -> maps:get(version, Opts, 'HTTP/1.1') end),
    meck:expect(cowboy_req, scheme, fun(_) -> maps:get(scheme, Opts, http) end),
    meck:expect(cowboy_req, peer, fun(_) -> {{127, 0, 0, 1}, 12345} end),
    meck:expect(cowboy_req, headers, fun(_) -> maps:get(headers, Opts, #{}) end),
    HeaderFun = fun(Key, Default) ->
        maps:get(Key, maps:get(headers, Opts, #{}), Default)
    end,
    meck:expect(cowboy_req, header, 2, fun(Key, _Req) -> HeaderFun(Key, undefined) end),
    meck:expect(cowboy_req, header, 3, fun(Key, _Req, Default) -> HeaderFun(Key, Default) end),
    meck:expect(cowboy_req, reply, fun(Status, _Hdrs, Body, Req) ->
        Req#{reply => {Status, Body}}
    end),
    meck:expect(pertisk_eproxy_router, route, fun(_, _) -> maps:get(route, Opts, {error, no_route}) end),
    meck:expect(pertisk_eproxy_backend, pick_upstream, fun(_, _) ->
        maps:get(pick, Opts, {error, no_healthy_upstream})
    end),
    try Fun(#{}) after
        unload_mocks([
            cowboy_req, pertisk_eproxy_router, pertisk_eproxy_backend, pertisk_eproxy_config,
            pertisk_eproxy_compression, pertisk_eproxy_metrics, pertisk_eproxy_access_log,
            pertisk_eproxy_alt_svc, pertisk_eproxy_response_headers
        ])
    end.

init_no_route_404_test() ->
    with_handler_req(#{route => {error, no_route}}, fun(Req) ->
        ?assertMatch({ok, #{reply := {404, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
    end).

init_no_healthy_upstream_502_test() ->
    with_handler_req(#{
        route => {ok, #{
            upstream_path => <<"/">>,
            backend => <<"web">>,
            site_host => <<"example.com">>
        }},
        pick => {error, no_healthy_upstream}
    }, fun(Req) ->
        ?assertMatch({ok, #{reply := {502, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
    end).

init_websocket_upgrade_delegates_test() ->
    unload_mocks([cowboy_req, pertisk_eproxy_ws_handler]),
    meck:new(cowboy_req, [unstick, no_link]),
    meck:new(pertisk_eproxy_ws_handler, [unstick, no_link]),
    meck:expect(cowboy_req, method, fun(_) -> <<"GET">> end),
    meck:expect(cowboy_req, host, fun(_) -> <<"ws.example">> end),
    meck:expect(cowboy_req, path, fun(_) -> <<"/ws">> end),
    meck:expect(cowboy_req, qs, fun(_) -> <<>> end),
    meck:expect(cowboy_req, header, fun(<<"upgrade">>, _Req, _) -> <<"websocket">>; (_, _, D) -> D end),
    meck:expect(pertisk_eproxy_ws_handler, init, fun(Req, State) -> {cowboy_websocket, Req, State, #{}} end),
    try
        ?assertMatch({cowboy_websocket, _, _, _}, pertisk_eproxy_handler:init(#{}, #{}))
    after
        unload_mocks([cowboy_req, pertisk_eproxy_ws_handler])
    end.

add_body_mocks(_Req) ->
    meck:expect(cowboy_req, has_body, fun(_) -> false end),
    meck:expect(cowboy_req, read_body, fun(R) -> {ok, <<>>, R} end),
    meck:expect(cowboy_req, read_body, 2, fun(R, _Opts) -> {ok, <<>>, R} end).

init_proxy_gun_connect_error_test() ->
    with_handler_req(#{
        route => {ok, #{
            upstream_path => <<"/">>,
            backend => <<"web">>,
            site_host => <<"example.com">>
        }},
        pick => {ok, <<"127.0.0.1:8080">>}
    }, fun(Req) ->
        add_body_mocks(Req),
        unload_mocks([gun]),
        meck:new(gun, [unstick, no_link]),
        meck:expect(gun, open, fun(_, _, _) -> {error, refused} end),
        try
            ?assertMatch({ok, #{reply := {502, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            unload_mocks([gun])
        end
    end).

init_proxy_gun_await_up_error_test() ->
    with_handler_req(#{
        route => {ok, #{
            upstream_path => <<"/">>,
            backend => <<"web">>,
            site_host => <<"example.com">>
        }},
        pick => {ok, <<"127.0.0.1:8080">>}
    }, fun(Req) ->
        add_body_mocks(Req),
        unload_mocks([gun]),
        meck:new(gun, [unstick, no_link]),
        meck:expect(gun, open, fun(_, _, _) -> {ok, gun_pid} end),
        meck:expect(gun, await_up, fun(_, _) -> {error, timeout} end),
        meck:expect(gun, close, fun(_) -> ok end),
        try
            ?assertMatch({ok, #{reply := {502, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            unload_mocks([gun])
        end
    end).

init_http2_version_proto_test() ->
    with_handler_req(#{
        version => 'HTTP/2',
        route => {error, no_route}
    }, fun(Req) ->
        ?assertMatch({ok, #{reply := {404, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
    end).

init_https_scheme_proto_test() ->
    with_handler_req(#{
        scheme => https,
        route => {error, no_route}
    }, fun(Req) ->
        ?assertMatch({ok, #{reply := {404, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
    end).

with_eventstream_upstream_ok_test() ->
    unload_mocks([gun]),
    meck:new(gun, [unstick, no_link]),
    meck:expect(gun, open, fun(_, _, _) -> {ok, gun_pid} end),
    meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
    meck:expect(gun, close, fun(_) -> ok end),
    try
        Result = pertisk_eproxy_handler:with_eventstream_upstream(
            fun(ConnPid, _Meta) -> {ok, ConnPid} end,
            <<"127.0.0.1">>,
            8080,
            tcp,
            <<"/api/v1/stream">>
        ),
        ?assertMatch({ok, gun_pid}, Result)
    after
        unload_mocks([gun])
    end.

with_eventstream_upstream_connect_error_test() ->
    unload_mocks([gun]),
    meck:new(gun, [unstick, no_link]),
    meck:expect(gun, open, fun(_, _, _) -> {error, refused} end),
    try
        Result = pertisk_eproxy_handler:with_eventstream_upstream(
            fun(_ConnPid, _Meta) -> {ok, ok} end,
            <<"127.0.0.1">>,
            8080,
            tcp,
            <<"/api/v1/stream">>
        ),
        ?assertMatch({error, {connect, refused}}, Result)
    after
        unload_mocks([gun])
    end.

with_eventstream_upstream_await_up_error_test() ->
    unload_mocks([gun]),
    meck:new(gun, [unstick, no_link]),
    meck:expect(gun, open, fun(_, _, _) -> {ok, gun_pid} end),
    meck:expect(gun, await_up, fun(_, _) -> {error, timeout} end),
    meck:expect(gun, close, fun(_) -> ok end),
    try
        Result = pertisk_eproxy_handler:with_eventstream_upstream(
            fun(_ConnPid, _Meta) -> {ok, ok} end,
            <<"127.0.0.1">>,
            8080,
            tcp,
            <<"/api/v1/stream">>
        ),
        ?assertMatch({error, {await_up, timeout}}, Result)
    after
        unload_mocks([gun])
    end.

with_eventstream_upstream_fun_error_test() ->
    unload_mocks([gun]),
    meck:new(gun, [unstick, no_link]),
    meck:expect(gun, open, fun(_, _, _) -> {ok, gun_pid} end),
    meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
    meck:expect(gun, close, fun(_) -> ok end),
    try
        Result = pertisk_eproxy_handler:with_eventstream_upstream(
            fun(_ConnPid, _Meta) -> {error, refused} end,
            <<"127.0.0.1">>,
            8080,
            tcp,
            <<"/api/v1/stream">>
        ),
        ?assertEqual({error, refused}, Result)
    after
        unload_mocks([gun])
    end.

websocket_callbacks_delegate_test() ->
    unload_mocks([pertisk_eproxy_ws_handler]),
    meck:new(pertisk_eproxy_ws_handler, [unstick, no_link]),
    meck:expect(pertisk_eproxy_ws_handler, websocket_init, fun(S) -> {ok, ws_init, S} end),
    meck:expect(pertisk_eproxy_ws_handler, websocket_handle, fun(F, S) -> {ok, ws_handle, F, S} end),
    meck:expect(pertisk_eproxy_ws_handler, websocket_info, fun(I, S) -> {ok, ws_info, I, S} end),
    try
        ?assertEqual({ok, ws_init, #{st => 1}}, pertisk_eproxy_handler:websocket_init(#{st => 1})),
        ?assertEqual({ok, ws_handle, ping, #{}}, pertisk_eproxy_handler:websocket_handle(ping, #{})),
        ?assertEqual({ok, ws_info, down, #{}}, pertisk_eproxy_handler:websocket_info(down, #{}))
    after
        unload_mocks([pertisk_eproxy_ws_handler])
    end.

init_websocket_sec_key_upgrade_test() ->
    unload_mocks([cowboy_req, pertisk_eproxy_ws_handler]),
    meck:new(cowboy_req, [unstick, no_link]),
    meck:new(pertisk_eproxy_ws_handler, [unstick, no_link]),
    meck:expect(cowboy_req, method, fun(_) -> <<"GET">> end),
    meck:expect(cowboy_req, host, fun(_) -> <<"ws.example">> end),
    meck:expect(cowboy_req, path, fun(_) -> <<"/ws">> end),
    meck:expect(cowboy_req, qs, fun(_) -> <<>> end),
    meck:expect(cowboy_req, header, 3, fun
        (<<"upgrade">>, _Req, _Default) -> <<>>;
        (<<"sec-websocket-key">>, _Req, _Default) -> <<"dGhlIHNhbXBsZSBub25jZQ==">>;
        (_, _, Default) -> Default
    end),
    meck:expect(pertisk_eproxy_ws_handler, init, fun(Req, State) -> {cowboy_websocket, Req, State, #{}} end),
    try
        ?assertMatch({cowboy_websocket, _, _, _}, pertisk_eproxy_handler:init(#{}, #{}))
    after
        unload_mocks([cowboy_req, pertisk_eproxy_ws_handler])
    end.

init_management_only_backend_test() ->
    with_handler_req(#{
        mgmt_only => true,
        route => {ok, #{
            upstream_path => <<"/api/status">>,
            backend => <<"mgmt">>,
            site_host => <<"admin.example.com">>
        }}
    }, fun(Req) ->
        add_body_mocks(Req),
        unload_mocks([pertisk_eproxy_h3_local_admin]),
        meck:new(pertisk_eproxy_h3_local_admin, [unstick, no_link]),
        meck:expect(pertisk_eproxy_h3_local_admin, try_dispatch, fun(_, _, _, _, _, _, _) ->
            {ok, 200, [], <<"ok">>}
        end),
        try
            ?assertMatch({ok, #{reply := {200, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            unload_mocks([pertisk_eproxy_h3_local_admin])
        end
    end).

init_admin_fallback_no_upstream_test() ->
    with_handler_req(#{
        host => <<"admin.example.com">>,
        route => {ok, #{
            upstream_path => <<"/api/health">>,
            backend => <<"web">>,
            site_host => <<"admin.example.com">>
        }},
        pick => {error, no_healthy_upstream}
    }, fun(Req) ->
        add_body_mocks(Req),
        unload_mocks([pertisk_eproxy_h3_local_admin]),
        meck:new(pertisk_eproxy_h3_local_admin, [unstick, no_link]),
        meck:expect(pertisk_eproxy_h3_local_admin, try_dispatch, fun(_, _, _, _, _, _, _) ->
            {ok, 204, [], <<>>}
        end),
        try
            ?assertMatch({ok, #{reply := {204, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            unload_mocks([pertisk_eproxy_h3_local_admin])
        end
    end).

init_eventstream_gun_connect_error_test() ->
    with_handler_req(#{
        headers => #{<<"accept">> => <<"text/event-stream">>},
        route => {ok, #{
            upstream_path => <<"/api/v1/stream">>,
            backend => <<"web">>,
            site_host => <<"example.com">>
        }},
        pick => {ok, <<"127.0.0.1:8080">>}
    }, fun(Req) ->
        add_body_mocks(Req),
        unload_mocks([gun]),
        meck:new(gun, [unstick, no_link]),
        meck:expect(gun, open, fun(_, _, _) -> {error, refused} end),
        try
            ?assertMatch({ok, #{reply := {502, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            unload_mocks([gun])
        end
    end).

init_http3_version_proto_test() ->
    with_handler_req(#{
        version => 'HTTP/3',
        route => {error, no_route}
    }, fun(Req) ->
        ?assertMatch({ok, #{reply := {404, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
    end).

terminate_ok_test() ->
    ?assertEqual(ok, pertisk_eproxy_handler:terminate(normal, #{}, #{})).

init_proxy_gun_success_test() ->
    with_handler_req(#{
        route => {ok, #{
            upstream_path => <<"/api">>,
            backend => <<"web">>,
            site_host => <<"example.com">>
        }},
        pick => {ok, <<"backend.example.com:8080">>}
    }, fun(Req) ->
        add_body_mocks(Req),
        meck:expect(pertisk_eproxy_metrics, record_proxy_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_metrics, record_site_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_backend, done_upstream, fun(_, _, _) -> ok end),
        unload_mocks([gun, pertisk_eproxy_upstream_pool]),
        meck:new(gun, [unstick, no_link]),
        meck:new(pertisk_eproxy_upstream_pool, [unstick, no_link]),
        meck:expect(pertisk_eproxy_upstream_pool, checkout, fun(_, _, _, _, _) -> {ok, gun_pid} end),
        meck:expect(pertisk_eproxy_upstream_pool, invalidate, fun(_) -> ok end),
        meck:expect(gun, request, fun(_, _, _, _, _) -> stream_ref end),
        meck:expect(gun, await, fun(_, _, _) ->
            {response, fin, 200, [{<<"content-type">>, <<"text/plain">>}]}
        end),
        try
            ?assertMatch({ok, #{reply := {200, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            unload_mocks([gun, pertisk_eproxy_upstream_pool])
        end
    end).

init_proxy_gun_retry_after_down_test() ->
    with_handler_req(#{
        route => {ok, #{
            upstream_path => <<"/">>,
            backend => <<"web">>,
            site_host => <<"example.com">>
        }},
        pick => {ok, <<"backend.example.com:8080">>}
    }, fun(Req) ->
        add_body_mocks(Req),
        meck:expect(pertisk_eproxy_metrics, record_proxy_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_metrics, record_site_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_backend, done_upstream, fun(_, _, _) -> ok end),
        unload_mocks([gun, pertisk_eproxy_upstream_pool]),
        meck:new(gun, [unstick, no_link]),
        meck:new(pertisk_eproxy_upstream_pool, [unstick, no_link]),
        CRef = make_ref(),
        put({checkout_count, CRef}, 0),
        meck:expect(pertisk_eproxy_upstream_pool, checkout, fun(_, _, _, _, _) ->
            N = get({checkout_count, CRef}) + 1,
            put({checkout_count, CRef}, N),
            {ok, gun_pid}
        end),
        meck:expect(pertisk_eproxy_upstream_pool, invalidate, fun(_) -> ok end),
        meck:expect(gun, open, fun(_, _, _) -> {ok, gun_pid} end),
        meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
        meck:expect(gun, close, fun(_) -> ok end),
        meck:expect(gun, await_body, fun(_, _, _) -> {ok, <<"ok">>} end),
        ARef = make_ref(),
        put({gun_await_queue, ARef}, [{error, {down, normal}}, {response, fin, 200, []}]),
        meck:expect(gun, request, fun(_, _, _, _, _) -> stream_ref end),
        meck:expect(gun, await, fun(_, _, _) ->
            case get({gun_await_queue, ARef}) of
                [N | R] -> put({gun_await_queue, ARef}, R), N;
                [] -> {error, unexpected}
            end
        end),
        try
            ?assertMatch({ok, #{reply := {200, _}}, _}, pertisk_eproxy_handler:init(Req, #{})),
            ?assertEqual(2, get({checkout_count, CRef}))
        after
            erase({checkout_count, CRef}),
            erase({gun_await_queue, ARef}),
            unload_mocks([gun, pertisk_eproxy_upstream_pool])
        end
    end).

init_head_upstream_content_length_test() ->
    with_handler_req(#{
        method => <<"HEAD">>,
        route => {ok, #{
            upstream_path => <<"/resource">>,
            backend => <<"web">>,
            site_host => <<"example.com">>
        }},
        pick => {ok, <<"backend.example.com:8080">>}
    }, fun(Req) ->
        add_body_mocks(Req),
        meck:expect(pertisk_eproxy_metrics, record_proxy_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_metrics, record_site_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_backend, done_upstream, fun(_, _, _) -> ok end),
        unload_mocks([gun, pertisk_eproxy_upstream_pool]),
        meck:new(gun, [unstick, no_link]),
        meck:new(pertisk_eproxy_upstream_pool, [unstick, no_link]),
        meck:expect(pertisk_eproxy_upstream_pool, checkout, fun(_, _, _, _, _) -> {ok, gun_pid} end),
        meck:expect(pertisk_eproxy_upstream_pool, invalidate, fun(_) -> ok end),
        meck:expect(gun, request, fun(_, _, _, _, _) -> stream_ref end),
        meck:expect(gun, await, fun(_, _, _) ->
            {response, fin, 200, [{<<"content-length">>, <<"16">>}]}
        end),
        try
            ?assertMatch({ok, #{reply := {200, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            unload_mocks([gun, pertisk_eproxy_upstream_pool])
        end
    end).

init_grpc_fin_response_test() ->
    with_handler_req(#{
        headers => #{<<"content-type">> => <<"application/grpc">>},
        route => {ok, #{
            upstream_path => <<"/pkg.Service/Method">>,
            backend => <<"web">>,
            site_host => <<"example.com">>
        }},
        pick => {ok, <<"backend.example.com:8080">>}
    }, fun(Req) ->
        add_body_mocks(Req),
        meck:expect(pertisk_eproxy_metrics, record_proxy_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_metrics, record_site_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_backend, done_upstream, fun(_, _, _) -> ok end),
        unload_mocks([gun, pertisk_eproxy_upstream_pool]),
        meck:new(gun, [unstick, no_link]),
        meck:new(pertisk_eproxy_upstream_pool, [unstick, no_link]),
        meck:expect(pertisk_eproxy_upstream_pool, checkout, fun(_, _, _, _, _) -> {ok, gun_pid} end),
        meck:expect(pertisk_eproxy_upstream_pool, invalidate, fun(_) -> ok end),
        meck:expect(gun, request, fun(_, _, _, _, _) -> stream_ref end),
        meck:expect(gun, await, fun(_, _, _) -> {response, fin, 200, []} end),
        try
            ?assertMatch({ok, #{reply := {200, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            unload_mocks([gun, pertisk_eproxy_upstream_pool])
        end
    end).

init_loopback_gun_success_test() ->
    with_handler_req(#{
        route => {ok, #{
            upstream_path => <<"/">>,
            backend => <<"web">>,
            site_host => <<"example.com">>
        }},
        pick => {ok, <<"127.0.0.1:8080">>}
    }, fun(Req) ->
        add_body_mocks(Req),
        meck:expect(pertisk_eproxy_metrics, record_proxy_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_metrics, record_site_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_backend, done_upstream, fun(_, _, _) -> ok end),
        unload_mocks([gun]),
        meck:new(gun, [unstick, no_link]),
        meck:expect(gun, open, fun(_, _, _) -> {ok, gun_pid} end),
        meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
        meck:expect(gun, request, fun(_, _, _, _, _) -> stream_ref end),
        meck:expect(gun, await, fun(_, _, _) -> {response, fin, 204, []} end),
        meck:expect(gun, close, fun(_) -> ok end),
        try
            ?assertMatch({ok, #{reply := {204, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            unload_mocks([gun])
        end
    end).

init_management_upstream_local_admin_test() ->
    with_handler_req(#{
        route => {ok, #{
            upstream_path => <<"/api/status">>,
            backend => <<"mgmt">>,
            site_host => <<"admin.example.com">>
        }},
        pick => {ok, pertisk_eproxy_config:management_loopback_upstream_bin()}
    }, fun(Req) ->
        add_body_mocks(Req),
        meck:expect(pertisk_eproxy_config, is_management_upstream_addr, fun(_) -> true end),
        unload_mocks([pertisk_eproxy_h3_local_admin]),
        meck:new(pertisk_eproxy_h3_local_admin, [unstick, no_link]),
        meck:expect(pertisk_eproxy_h3_local_admin, try_dispatch, fun(_, _, _, _, _, _, _) ->
            {ok, 200, [], <<"local">>}
        end),
        try
            ?assertMatch({ok, #{reply := {200, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            unload_mocks([pertisk_eproxy_h3_local_admin])
        end
    end).

init_proxy_streaming_nofin_test() ->
    with_handler_req(#{
        route => {ok, #{
            upstream_path => <<"/data">>,
            backend => <<"web">>,
            site_host => <<"example.com">>
        }},
        pick => {ok, <<"backend.example.com:8080">>}
    }, fun(Req) ->
        add_body_mocks(Req),
        meck:expect(cowboy_req, stream_reply, fun(S, H, R) -> R#{stream_reply => {S, H}} end),
        meck:expect(cowboy_req, stream_body, fun(_, _, _R) -> ok end),
        meck:expect(pertisk_eproxy_metrics, record_proxy_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_metrics, record_site_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_backend, done_upstream, fun(_, _, _) -> ok end),
        unload_mocks([gun, pertisk_eproxy_upstream_pool]),
        meck:new(gun, [unstick, no_link]),
        meck:new(pertisk_eproxy_upstream_pool, [unstick, no_link]),
        meck:expect(pertisk_eproxy_upstream_pool, checkout, fun(_, _, _, _, _) -> {ok, gun_pid} end),
        meck:expect(pertisk_eproxy_upstream_pool, invalidate, fun(_) -> ok end),
        ARef = make_ref(),
        put({gun_await_queue, ARef}, [
            {response, nofin, 200, [{<<"content-type">>, <<"application/json">>}]},
            {data, fin, <<"ok">>}
        ]),
        meck:expect(gun, request, fun(_, _, _, _, _) -> stream_ref end),
        meck:expect(gun, await, fun(_, _, _) ->
            case get({gun_await_queue, ARef}) of
                [N | R] -> put({gun_await_queue, ARef}, R), N;
                [] -> {error, unexpected}
            end
        end),
        try
            ?assertMatch({ok, #{stream_reply := {200, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            erase({gun_await_queue, ARef}),
            unload_mocks([gun, pertisk_eproxy_upstream_pool])
        end
    end).

init_http10_proto_test() ->
    with_handler_req(#{
        version => 'HTTP/1.0',
        route => {error, no_route}
    }, fun(Req) ->
        ?assertMatch({ok, #{reply := {404, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
    end).

init_xff_client_ip_test() ->
    with_handler_req(#{
        headers => #{<<"x-forwarded-for">> => <<"203.0.113.9">>},
        route => {error, no_route}
    }, fun(Req) ->
        ?assertMatch({ok, #{reply := {404, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
    end).

init_rate_limit_deny_429_test() ->
    with_handler_req(#{
        route => {ok, #{
            upstream_path => <<"/">>,
            backend => <<"web">>,
            site_host => <<"example.com">>
        }}
    }, fun(Req) ->
        unload_mocks([pertisk_eproxy_rate_limit]),
        meck:new(pertisk_eproxy_rate_limit, [unstick, no_link]),
        meck:expect(pertisk_eproxy_rate_limit, check, fun(_, _, _) -> deny end),
        try
            ?assertMatch({ok, #{reply := {429, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            unload_mocks([pertisk_eproxy_rate_limit])
        end
    end).

init_auth_denied_403_test() ->
    with_handler_req(#{
        route => {ok, #{
            upstream_path => <<"/">>,
            backend => <<"web">>,
            site_host => <<"example.com">>
        }}
    }, fun(Req) ->
        unload_mocks([pertisk_eproxy_rate_limit, pertisk_eproxy_external_auth]),
        meck:new(pertisk_eproxy_rate_limit, [unstick, no_link]),
        meck:expect(pertisk_eproxy_rate_limit, check, fun(_, _, _) -> allow end),
        meck:new(pertisk_eproxy_external_auth, [unstick, no_link]),
        meck:expect(pertisk_eproxy_external_auth, authorize, fun(_, _, _, _, _, _) ->
            {error, {auth_denied, 403}}
        end),
        try
            ?assertMatch({ok, #{reply := {403, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            unload_mocks([pertisk_eproxy_rate_limit, pertisk_eproxy_external_auth])
        end
    end).

init_auth_unreachable_502_test() ->
    with_handler_req(#{
        route => {ok, #{
            upstream_path => <<"/">>,
            backend => <<"web">>,
            site_host => <<"example.com">>
        }}
    }, fun(Req) ->
        unload_mocks([pertisk_eproxy_rate_limit, pertisk_eproxy_external_auth]),
        meck:new(pertisk_eproxy_rate_limit, [unstick, no_link]),
        meck:expect(pertisk_eproxy_rate_limit, check, fun(_, _, _) -> allow end),
        meck:new(pertisk_eproxy_external_auth, [unstick, no_link]),
        meck:expect(pertisk_eproxy_external_auth, authorize, fun(_, _, _, _, _, _) ->
            {error, auth_unreachable}
        end),
        try
            ?assertMatch({ok, #{reply := {502, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            unload_mocks([pertisk_eproxy_rate_limit, pertisk_eproxy_external_auth])
        end
    end).

init_loopback_uses_ephemeral_connection_test() ->
    with_handler_req(#{
        route => {ok, #{
            upstream_path => <<"/">>,
            backend => <<"web">>,
            site_host => <<"example.com">>
        }},
        pick => {ok, <<"127.0.0.1:8080">>}
    }, fun(Req) ->
        add_body_mocks(Req),
        meck:expect(pertisk_eproxy_metrics, record_proxy_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_metrics, record_site_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_backend, done_upstream, fun(_, _, _) -> ok end),
        unload_mocks([gun, pertisk_eproxy_upstream_pool]),
        meck:new(gun, [unstick, no_link]),
        meck:new(pertisk_eproxy_upstream_pool, [unstick, no_link]),
        meck:expect(pertisk_eproxy_upstream_pool, checkout, fun(_, _, _, _, _) ->
            {error, should_not_checkout}
        end),
        meck:expect(pertisk_eproxy_upstream_pool, invalidate, fun(_) -> ok end),
        meck:expect(gun, open, fun(_, _, _) -> {ok, gun_pid} end),
        meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
        meck:expect(gun, request, fun(_, _, _, _, _) -> stream_ref end),
        meck:expect(gun, await, fun(_, _, _) -> {response, fin, 204, []} end),
        meck:expect(gun, close, fun(_) -> ok end),
        try
            ?assertMatch({ok, #{reply := {204, _}}, _}, pertisk_eproxy_handler:init(Req, #{})),
            ?assertEqual(0, meck:num_calls(pertisk_eproxy_upstream_pool, checkout, '_')),
            ?assertEqual(1, meck:num_calls(gun, open, '_'))
        after
            unload_mocks([gun, pertisk_eproxy_upstream_pool])
        end
    end).

init_loopback_uses_pooled_connection_when_enabled_test() ->
    with_handler_req(#{
        route => {ok, #{
            upstream_path => <<"/">>,
            backend => <<"web">>,
            site_host => <<"example.com">>
        }},
        pick => {ok, <<"127.0.0.1:8080">>}
    }, fun(Req) ->
        Config0 = pertisk_eproxy_config:get_config(),
        meck:expect(pertisk_eproxy_config, get_config, fun() ->
            maps:merge(Config0, #{upstream_loopback_pool_enabled => true})
        end),
        add_body_mocks(Req),
        meck:expect(pertisk_eproxy_metrics, record_proxy_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_metrics, record_site_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_backend, done_upstream, fun(_, _, _) -> ok end),
        unload_mocks([gun, pertisk_eproxy_upstream_pool]),
        meck:new(gun, [unstick, no_link]),
        meck:new(pertisk_eproxy_upstream_pool, [unstick, no_link]),
        meck:expect(pertisk_eproxy_upstream_pool, checkout, fun(_, _, _, _, _) ->
            {ok, gun_pid}
        end),
        meck:expect(pertisk_eproxy_upstream_pool, invalidate, fun(_) -> ok end),
        meck:expect(gun, request, fun(_, _, _, _, _) -> stream_ref end),
        meck:expect(gun, await, fun(_, _, _) -> {response, fin, 204, []} end),
        try
            ?assertMatch({ok, #{reply := {204, _}}, _}, pertisk_eproxy_handler:init(Req, #{})),
            ?assertEqual(1, meck:num_calls(pertisk_eproxy_upstream_pool, checkout, '_')),
            ?assertEqual(0, meck:num_calls(gun, open, '_'))
        after
            unload_mocks([gun, pertisk_eproxy_upstream_pool])
        end
    end).

init_eventstream_upstream_success_test() ->
    with_handler_req(#{
        headers => #{<<"accept">> => <<"text/event-stream">>},
        route => {ok, #{
            upstream_path => <<"/api/v1/stream">>,
            backend => <<"web">>,
            site_host => <<"example.com">>
        }},
        pick => {ok, <<"127.0.0.1:8080">>}
    }, fun(Req) ->
        add_body_mocks(Req),
        meck:expect(cowboy_req, stream_reply, fun(S, H, R) -> R#{stream_reply => {S, H}} end),
        meck:expect(cowboy_req, stream_body, fun(_, _, _R) -> ok end),
        meck:expect(pertisk_eproxy_metrics, record_proxy_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_metrics, record_site_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_backend, done_upstream, fun(_, _, _) -> ok end),
        unload_mocks([gun]),
        meck:new(gun, [unstick, no_link]),
        meck:expect(gun, open, fun(_, _, _) -> {ok, gun_pid} end),
        meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
        meck:expect(gun, request, fun(_, _, _, _, _) -> stream_ref end),
        meck:expect(gun, await, fun(_, _, _) ->
            {response, fin, 200, [{<<"content-type">>, <<"text/event-stream">>}]}
        end),
        meck:expect(gun, close, fun(_) -> ok end),
        try
            ?assertMatch({ok, #{reply := {200, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            unload_mocks([gun])
        end
    end).

init_proxy_set_cookie_response_test() ->
    with_handler_req(#{
        route => {ok, #{
            upstream_path => <<"/">>,
            backend => <<"web">>,
            site_host => <<"example.com">>
        }},
        pick => {ok, <<"backend.example.com:8080">>}
    }, fun(Req) ->
        add_body_mocks(Req),
        meck:expect(cowboy_req, set_resp_cookie, fun(Name, Value, R, _Opts) ->
            put(handler_set_cookie, {Name, Value}),
            R
        end),
        meck:expect(pertisk_eproxy_metrics, record_proxy_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_metrics, record_site_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_backend, done_upstream, fun(_, _, _) -> ok end),
        unload_mocks([gun, pertisk_eproxy_upstream_pool]),
        meck:new(gun, [unstick, no_link]),
        meck:new(pertisk_eproxy_upstream_pool, [unstick, no_link]),
        meck:expect(pertisk_eproxy_upstream_pool, checkout, fun(_, _, _, _, _) -> {ok, gun_pid} end),
        meck:expect(pertisk_eproxy_upstream_pool, invalidate, fun(_) -> ok end),
        meck:expect(gun, request, fun(_, _, _, _, _) -> stream_ref end),
        meck:expect(gun, await, fun(_, _, _) ->
            {response, fin, 200, [{<<"set-cookie">>, <<"session=abc; Path=/; HttpOnly">>}]}
        end),
        try
            ?assertMatch({ok, #{reply := {200, _}}, _}, pertisk_eproxy_handler:init(Req, #{})),
            ?assertEqual({<<"session">>, <<"abc">>}, get(handler_set_cookie))
        after
            erase(handler_set_cookie),
            unload_mocks([gun, pertisk_eproxy_upstream_pool])
        end
    end).

init_loopback_location_rewrite_test() ->
    with_handler_req(#{
        host => <<"registry.example.com">>,
        route => {ok, #{
            upstream_path => <<"/v2/">>,
            backend => <<"web">>,
            site_host => <<"registry.example.com">>
        }},
        pick => {ok, <<"127.0.0.1:8080">>}
    }, fun(Req) ->
        add_body_mocks(Req),
        meck:expect(cowboy_req, reply, fun(Status, Hdrs, Body, R) ->
            put(handler_reply_hdrs, Hdrs),
            R#{reply => {Status, Body}}
        end),
        meck:expect(pertisk_eproxy_metrics, record_proxy_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_metrics, record_site_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_backend, done_upstream, fun(_, _, _) -> ok end),
        unload_mocks([gun]),
        meck:new(gun, [unstick, no_link]),
        meck:expect(gun, open, fun(_, _, _) -> {ok, gun_pid} end),
        meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
        meck:expect(gun, request, fun(_, _, _, _, _) -> stream_ref end),
        meck:expect(gun, await, fun(_, _, _) ->
            {response, fin, 302, [{<<"location">>, <<"http://127.0.0.1:8099/v2/upload">>}]}
        end),
        meck:expect(gun, close, fun(_) -> ok end),
        try
            ?assertMatch({ok, #{reply := {302, _}}, _}, pertisk_eproxy_handler:init(Req, #{})),
            Hdrs = get(handler_reply_hdrs),
            ?assertEqual(
                <<"https://registry.example.com/v2/upload">>,
                maps:get(<<"location">>, Hdrs, undefined)
            )
        after
            erase(handler_reply_hdrs),
            unload_mocks([gun])
        end
    end).

init_management_only_local_admin_error_502_test() ->
    with_handler_req(#{
        mgmt_only => true,
        route => {ok, #{
            upstream_path => <<"/api/status">>,
            backend => <<"mgmt">>,
            site_host => <<"admin.example.com">>
        }}
    }, fun(Req) ->
        add_body_mocks(Req),
        unload_mocks([pertisk_eproxy_h3_local_admin]),
        meck:new(pertisk_eproxy_h3_local_admin, [unstick, no_link]),
        meck:expect(pertisk_eproxy_h3_local_admin, try_dispatch, fun(_, _, _, _, _, _, _) ->
            {error, refused}
        end),
        try
            ?assertMatch({ok, #{reply := {502, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            unload_mocks([pertisk_eproxy_h3_local_admin])
        end
    end).

init_grpc_nofin_trailers_test() ->
    with_handler_req(#{
        headers => #{<<"content-type">> => <<"application/grpc">>},
        route => {ok, #{
            upstream_path => <<"/pkg.Service/Method">>,
            backend => <<"web">>,
            site_host => <<"example.com">>
        }},
        pick => {ok, <<"backend.example.com:8080">>}
    }, fun(Req) ->
        add_body_mocks(Req),
        meck:expect(cowboy_req, stream_reply, fun(S, H, R) -> R#{stream_reply => {S, H}} end),
        meck:expect(cowboy_req, stream_trailers, fun(_T, R) -> put(handler_stream_trailers, true), R end),
        meck:expect(pertisk_eproxy_metrics, record_proxy_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_metrics, record_site_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_backend, done_upstream, fun(_, _, _) -> ok end),
        unload_mocks([gun, pertisk_eproxy_upstream_pool]),
        meck:new(gun, [unstick, no_link]),
        meck:new(pertisk_eproxy_upstream_pool, [unstick, no_link]),
        meck:expect(pertisk_eproxy_upstream_pool, checkout, fun(_, _, _, _, _) -> {ok, gun_pid} end),
        meck:expect(pertisk_eproxy_upstream_pool, invalidate, fun(_) -> ok end),
        ARef = make_ref(),
        put({gun_await_queue, ARef}, [
            {response, nofin, 200, [{<<"content-type">>, <<"application/grpc">>}]},
            {trailers, [{<<"grpc-status">>, <<"0">>}]}
        ]),
        meck:expect(gun, request, fun(_, _, _, _, _) -> stream_ref end),
        meck:expect(gun, await, fun(_, _, _) ->
            case get({gun_await_queue, ARef}) of
                [N | R] -> put({gun_await_queue, ARef}, R), N;
                [] -> {error, unexpected}
            end
        end),
        try
            ?assertMatch({ok, #{stream_reply := {200, _}}, _}, pertisk_eproxy_handler:init(Req, #{})),
            ?assertEqual(true, get(handler_stream_trailers))
        after
            erase({gun_await_queue, ARef}),
            erase(handler_stream_trailers),
            unload_mocks([gun, pertisk_eproxy_upstream_pool])
        end
    end).

proxmox_port_8006_http1_only_test() ->
    Opts = pertisk_eproxy_handler:upstream_gun_opts_with_port("pve.local", 8006, tls, http),
    ?assertEqual([http], maps:get(protocols, Opts)).

init_proxy_error_admin_fallback_test() ->
    with_handler_req(#{
        host => <<"admin.example.com">>,
        route => {ok, #{
            upstream_path => <<"/api/status">>,
            backend => <<"web">>,
            site_host => <<"admin.example.com">>
        }},
        pick => {ok, <<"127.0.0.1:8080">>}
    }, fun(Req) ->
        add_body_mocks(Req),
        unload_mocks([gun, pertisk_eproxy_h3_local_admin]),
        meck:new(gun, [unstick, no_link]),
        meck:new(pertisk_eproxy_h3_local_admin, [unstick, no_link]),
        meck:expect(gun, open, fun(_, _, _) -> {error, refused} end),
        meck:expect(pertisk_eproxy_h3_local_admin, try_dispatch, fun(_, _, _, _, _, _, _) ->
            {ok, 200, [], <<"fallback">>}
        end),
        try
            ?assertMatch({ok, #{reply := {200, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            unload_mocks([gun, pertisk_eproxy_h3_local_admin])
        end
    end).

init_stream_aborted_after_headers_test() ->
    with_handler_req(#{
        route => {ok, #{
            upstream_path => <<"/api/v1/watch/pods">>,
            backend => <<"web">>,
            site_host => <<"example.com">>
        }},
        pick => {ok, <<"backend.example.com:8080">>}
    }, fun(Req) ->
        add_body_mocks(Req),
        meck:expect(cowboy_req, stream_reply, fun(S, H, R) -> R#{stream_reply => {S, H}} end),
        meck:expect(cowboy_req, stream_body, fun(_, _, _R) -> ok end),
        meck:expect(pertisk_eproxy_metrics, record_proxy_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_metrics, record_site_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_backend, done_upstream, fun(_, _, _) -> ok end),
        unload_mocks([gun, pertisk_eproxy_upstream_pool]),
        meck:new(gun, [unstick, no_link]),
        meck:new(pertisk_eproxy_upstream_pool, [unstick, no_link]),
        ARef = make_ref(),
        put({gun_await_queue, ARef}, [
            {response, nofin, 200, [{<<"content-type">>, <<"application/json">>}]},
            {error, closed}
        ]),
        meck:expect(pertisk_eproxy_upstream_pool, checkout, fun(_, _, _, _, _) -> {ok, gun_pid} end),
        meck:expect(pertisk_eproxy_upstream_pool, invalidate, fun(_) -> ok end),
        meck:expect(gun, request, fun(_, _, _, _, _) -> stream_ref end),
        meck:expect(gun, await, fun(_, _, _) ->
            case get({gun_await_queue, ARef}) of
                [N | R] -> put({gun_await_queue, ARef}, R), N;
                [] -> {error, unexpected}
            end
        end),
        try
            ?assertMatch({ok, #{stream_reply := {200, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            erase({gun_await_queue, ARef}),
            unload_mocks([gun, pertisk_eproxy_upstream_pool])
        end
    end).

init_https_scheme_binary_proto_test() ->
    with_handler_req(#{
        scheme => <<"https">>,
        route => {error, no_route}
    }, fun(Req) ->
        ?assertMatch({ok, #{reply := {404, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
    end).

init_unknown_version_proto_test() ->
    with_handler_req(#{
        version => other,
        route => {error, no_route}
    }, fun(Req) ->
        ?assertMatch({ok, #{reply := {404, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
    end).

init_local_management_unsupported_fallback_test() ->
    with_handler_req(#{
        host => <<"admin.example.com">>,
        route => {ok, #{
            upstream_path => <<"/api/health">>,
            backend => <<"web">>,
            site_host => <<"admin.example.com">>
        }},
        pick => {error, no_healthy_upstream}
    }, fun(Req) ->
        add_body_mocks(Req),
        unload_mocks([pertisk_eproxy_h3_local_admin, gun]),
        meck:new(pertisk_eproxy_h3_local_admin, [unstick, no_link]),
        meck:new(gun, [unstick, no_link]),
        meck:expect(pertisk_eproxy_h3_local_admin, try_dispatch, fun(_, _, _, _, _, _, _) ->
            {error, unsupported}
        end),
        meck:expect(gun, open, fun(_, _, _) -> {error, refused} end),
        try
            ?assertMatch({ok, #{reply := {502, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            unload_mocks([pertisk_eproxy_h3_local_admin, gun])
        end
    end).

init_eventstream_nofin_fin_response_test() ->
    with_handler_req(#{
        headers => #{<<"accept">> => <<"text/event-stream">>},
        route => {ok, #{
            upstream_path => <<"/api/v1/stream">>,
            backend => <<"web">>,
            site_host => <<"example.com">>
        }},
        pick => {ok, <<"127.0.0.1:8080">>}
    }, fun(Req) ->
        add_body_mocks(Req),
        meck:expect(cowboy_req, stream_reply, fun(S, H, R) -> R#{stream_reply => {S, H}} end),
        meck:expect(cowboy_req, stream_body, fun(_, _, _R) -> ok end),
        meck:expect(pertisk_eproxy_metrics, record_proxy_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_metrics, record_site_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_backend, done_upstream, fun(_, _, _) -> ok end),
        unload_mocks([gun]),
        meck:new(gun, [unstick, no_link]),
        ARef = make_ref(),
        put({gun_await_queue, ARef}, [
            {response, nofin, 200, [{<<"content-type">>, <<"text/event-stream">>}]},
            {data, fin, <<"event: ping\ndata: ok\n\n">>}
        ]),
        meck:expect(gun, open, fun(_, _, _) -> {ok, gun_pid} end),
        meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
        meck:expect(gun, request, fun(_, _, _, _, _) -> stream_ref end),
        meck:expect(gun, await, fun(_, _, _) ->
            case get({gun_await_queue, ARef}) of
                [N | R] -> put({gun_await_queue, ARef}, R), N;
                [] -> {error, unexpected}
            end
        end),
        meck:expect(gun, close, fun(_) -> ok end),
        try
            ?assertMatch({ok, #{stream_reply := {200, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            erase({gun_await_queue, ARef}),
            unload_mocks([gun])
        end
    end).

init_proxy_upstream_error_no_admin_host_test() ->
    with_handler_req(#{
        route => {ok, #{
            upstream_path => <<"/">>,
            backend => <<"web">>,
            site_host => <<"example.com">>
        }},
        pick => {ok, <<"backend.example.com:8080">>}
    }, fun(Req) ->
        add_body_mocks(Req),
        meck:expect(pertisk_eproxy_backend, done_upstream, fun(_, _, error) -> ok end),
        unload_mocks([gun, pertisk_eproxy_upstream_pool]),
        meck:new(gun, [unstick, no_link]),
        meck:new(pertisk_eproxy_upstream_pool, [unstick, no_link]),
        meck:expect(pertisk_eproxy_upstream_pool, checkout, fun(_, _, _, _, _) -> {ok, gun_pid} end),
        meck:expect(pertisk_eproxy_upstream_pool, invalidate, fun(_) -> ok end),
        meck:expect(gun, request, fun(_, _, _, _, _) -> stream_ref end),
        meck:expect(gun, await, fun(_, _, _) -> {error, timeout} end),
        try
            ?assertMatch({ok, #{reply := {502, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            unload_mocks([gun, pertisk_eproxy_upstream_pool])
        end
    end).

init_management_only_list_method_test() ->
    with_handler_req(#{
        mgmt_only => true,
        method => "GET",
        route => {ok, #{
            upstream_path => <<"/api/status">>,
            backend => <<"mgmt">>,
            site_host => <<"admin.example.com">>
        }}
    }, fun(Req) ->
        add_body_mocks(Req),
        unload_mocks([pertisk_eproxy_h3_local_admin]),
        meck:new(pertisk_eproxy_h3_local_admin, [unstick, no_link]),
        meck:expect(pertisk_eproxy_h3_local_admin, try_dispatch, fun(_, _, _, _, _, _, _) ->
            {ok, 200, [], <<"ok">>}
        end),
        try
            ?assertMatch({ok, #{reply := {200, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            unload_mocks([pertisk_eproxy_h3_local_admin])
        end
    end).

init_proxy_with_query_string_test() ->
    with_handler_req(#{
        qs => <<"a=1">>,
        route => {ok, #{
            upstream_path => <<"/api">>,
            backend => <<"web">>,
            site_host => <<"example.com">>
        }},
        pick => {ok, <<"backend.example.com:8080">>}
    }, fun(Req) ->
        add_body_mocks(Req),
        meck:expect(pertisk_eproxy_metrics, record_proxy_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_metrics, record_site_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_backend, done_upstream, fun(_, _, _) -> ok end),
        unload_mocks([gun, pertisk_eproxy_upstream_pool]),
        meck:new(gun, [unstick, no_link]),
        meck:new(pertisk_eproxy_upstream_pool, [unstick, no_link]),
        meck:expect(pertisk_eproxy_upstream_pool, checkout, fun(_, _, _, _, _) -> {ok, gun_pid} end),
        meck:expect(pertisk_eproxy_upstream_pool, invalidate, fun(_) -> ok end),
        meck:expect(gun, request, fun(_Pid, _Method, Path, _Headers, _Body) ->
            put(handler_upstream_path, Path),
            stream_ref
        end),
        meck:expect(gun, await, fun(_, _, _) -> {response, fin, 200, []} end),
        try
            ?assertMatch({ok, #{reply := {200, _}}, _}, pertisk_eproxy_handler:init(Req, #{})),
            ?assertEqual(<<"/api?a=1">>, get(handler_upstream_path))
        after
            erase(handler_upstream_path),
            unload_mocks([gun, pertisk_eproxy_upstream_pool])
        end
    end).

init_eventstream_with_query_string_test() ->
    with_handler_req(#{
        qs => <<"watch=1">>,
        headers => #{<<"accept">> => <<"text/event-stream">>},
        route => {ok, #{
            upstream_path => <<"/api/v1/stream">>,
            backend => <<"web">>,
            site_host => <<"example.com">>
        }},
        pick => {ok, <<"127.0.0.1:8080">>}
    }, fun(Req) ->
        add_body_mocks(Req),
        meck:expect(cowboy_req, stream_reply, fun(S, H, R) -> R#{stream_reply => {S, H}} end),
        meck:expect(cowboy_req, stream_body, fun(_, _, _R) -> ok end),
        meck:expect(pertisk_eproxy_metrics, record_proxy_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_metrics, record_site_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_backend, done_upstream, fun(_, _, _) -> ok end),
        unload_mocks([gun]),
        meck:new(gun, [unstick, no_link]),
        meck:expect(gun, open, fun(_, _, _) -> {ok, gun_pid} end),
        meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
        meck:expect(gun, request, fun(_Pid, _Method, Path, _Headers, _Body) ->
            put(handler_es_path, Path),
            stream_ref
        end),
        meck:expect(gun, await, fun(_, _, _) ->
            {response, fin, 200, [{<<"content-type">>, <<"text/event-stream">>}]}
        end),
        meck:expect(gun, close, fun(_) -> ok end),
        try
            ?assertMatch({ok, #{reply := {200, _}}, _}, pertisk_eproxy_handler:init(Req, #{})),
            ?assertEqual(<<"/api/v1/stream?watch=1">>, get(handler_es_path))
        after
            erase(handler_es_path),
            unload_mocks([gun])
        end
    end).

init_proxy_http_scheme_binary_test() ->
    with_handler_req(#{
        scheme => <<"http">>,
        route => {error, no_route}
    }, fun(Req) ->
        ?assertMatch({ok, #{reply := {404, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
    end).

init_grpc_stream_data_chunks_test() ->
    with_handler_req(#{
        headers => #{<<"content-type">> => <<"application/grpc">>},
        route => {ok, #{
            upstream_path => <<"/pkg.Service/Method">>,
            backend => <<"web">>,
            site_host => <<"example.com">>
        }},
        pick => {ok, <<"backend.example.com:8080">>}
    }, fun(Req) ->
        add_body_mocks(Req),
        meck:expect(cowboy_req, stream_reply, fun(S, H, R) -> R#{stream_reply => {S, H}} end),
        meck:expect(cowboy_req, stream_body, fun(_, _, _R) -> ok end),
        meck:expect(pertisk_eproxy_metrics, record_proxy_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_metrics, record_site_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_backend, done_upstream, fun(_, _, _) -> ok end),
        unload_mocks([gun, pertisk_eproxy_upstream_pool]),
        meck:new(gun, [unstick, no_link]),
        meck:new(pertisk_eproxy_upstream_pool, [unstick, no_link]),
        meck:expect(pertisk_eproxy_upstream_pool, checkout, fun(_, _, _, _, _) -> {ok, gun_pid} end),
        meck:expect(pertisk_eproxy_upstream_pool, invalidate, fun(_) -> ok end),
        ARef = make_ref(),
        put({gun_await_queue, ARef}, [
            {response, nofin, 200, [{<<"content-type">>, <<"application/grpc">>}]},
            {data, nofin, <<"chunk1">>},
            {data, fin, <<"chunk2">>}
        ]),
        meck:expect(gun, request, fun(_, _, _, _, _) -> stream_ref end),
        meck:expect(gun, await, fun(_, _, _) ->
            case get({gun_await_queue, ARef}) of
                [N | R] -> put({gun_await_queue, ARef}, R), N;
                [] -> {error, unexpected}
            end
        end),
        try
            ?assertMatch({ok, #{stream_reply := {200, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            erase({gun_await_queue, ARef}),
            unload_mocks([gun, pertisk_eproxy_upstream_pool])
        end
    end).

init_admin_fallback_atom_method_test() ->
    with_handler_req(#{
        host => <<"admin.example.com">>,
        method => get,
        route => {ok, #{
            upstream_path => <<"/api/health">>,
            backend => <<"web">>,
            site_host => <<"admin.example.com">>
        }},
        pick => {error, no_healthy_upstream}
    }, fun(Req) ->
        add_body_mocks(Req),
        unload_mocks([pertisk_eproxy_h3_local_admin]),
        meck:new(pertisk_eproxy_h3_local_admin, [unstick, no_link]),
        meck:expect(pertisk_eproxy_h3_local_admin, try_dispatch, fun(_, _, _, _, _, _, _) ->
            {ok, 204, [], <<>>}
        end),
        try
            ?assertMatch({ok, #{reply := {204, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            unload_mocks([pertisk_eproxy_h3_local_admin])
        end
    end).

site_advertise_http3_exact_before_wildcard_test() ->
    pertisk_eproxy_test_helpers:sync_router(
        [
            #{host => <<"*.example.com">>, backend => <<"b">>, routes => [], advertise_http3 => true},
            #{host => <<"admin.example.com">>, backend => <<"b">>, routes => [], advertise_http3 => false}
        ],
        []
    ),
    ?assertNot(pertisk_eproxy_handler:site_advertise_http3(<<"admin.example.com">>)),
    pertisk_eproxy_test_helpers:sync_router([], []).

init_management_only_integer_method_test() ->
    with_handler_req(#{
        mgmt_only => true,
        method => 123,
        route => {ok, #{
            upstream_path => <<"/api/status">>,
            backend => <<"mgmt">>,
            site_host => <<"admin.example.com">>
        }},
        pick => {error, no_healthy_upstream}
    }, fun(Req) ->
        add_body_mocks(Req),
        unload_mocks([pertisk_eproxy_h3_local_admin]),
        meck:new(pertisk_eproxy_h3_local_admin, [unstick, no_link]),
        meck:expect(pertisk_eproxy_h3_local_admin, try_dispatch, fun
            (<<"GET">>, _, _, _, _, _, _) -> {ok, 200, [], <<"ok">>};
            (_, _, _, _, _, _, _) -> {error, unsupported}
        end),
        try
            ?assertMatch({ok, #{reply := {200, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            unload_mocks([pertisk_eproxy_h3_local_admin])
        end
    end).

init_local_management_dispatch_error_test() ->
    with_handler_req(#{
        host => <<"admin.example.com">>,
        route => {ok, #{
            upstream_path => <<"/api/status">>,
            backend => <<"web">>,
            site_host => <<"admin.example.com">>
        }},
        pick => {error, no_healthy_upstream}
    }, fun(Req) ->
        add_body_mocks(Req),
        unload_mocks([pertisk_eproxy_h3_local_admin]),
        meck:new(pertisk_eproxy_h3_local_admin, [unstick, no_link]),
        meck:expect(pertisk_eproxy_h3_local_admin, try_dispatch, fun(_, _, _, _, _, _, _) ->
            {error, refused}
        end),
        try
            ?assertMatch({ok, #{reply := {502, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            unload_mocks([pertisk_eproxy_h3_local_admin])
        end
    end).

init_proxy_upstream_hostname_not_ip_test() ->
    with_handler_req(#{
        route => {ok, #{
            upstream_path => <<"/">>,
            backend => <<"web">>,
            site_host => <<"example.com">>
        }},
        pick => {ok, <<"backend.internal:443">>}
    }, fun(Req) ->
        add_body_mocks(Req),
        meck:expect(pertisk_eproxy_metrics, record_proxy_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_metrics, record_site_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_backend, done_upstream, fun(_, _, _) -> ok end),
        unload_mocks([gun, pertisk_eproxy_upstream_pool]),
        meck:new(gun, [unstick, no_link]),
        meck:new(pertisk_eproxy_upstream_pool, [unstick, no_link]),
        meck:expect(pertisk_eproxy_upstream_pool, checkout, fun(_, _, _, _, _) -> {ok, gun_pid} end),
        meck:expect(pertisk_eproxy_upstream_pool, invalidate, fun(_) -> ok end),
        meck:expect(gun, request, fun(_, _, _, _, _) -> stream_ref end),
        meck:expect(gun, await, fun(_, _, _) -> {response, fin, 200, []} end),
        try
            ?assertMatch({ok, #{reply := {200, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            unload_mocks([gun, pertisk_eproxy_upstream_pool])
        end
    end).

init_loopback_localhost_upstream_test() ->
    with_handler_req(#{
        route => {ok, #{
            upstream_path => <<"/">>,
            backend => <<"web">>,
            site_host => <<"example.com">>
        }},
        pick => {ok, <<"localhost:8080">>}
    }, fun(Req) ->
        add_body_mocks(Req),
        meck:expect(pertisk_eproxy_metrics, record_proxy_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_metrics, record_site_bytes, fun(_, _, _) -> ok end),
        meck:expect(pertisk_eproxy_backend, done_upstream, fun(_, _, _) -> ok end),
        unload_mocks([gun]),
        meck:new(gun, [unstick, no_link]),
        meck:expect(gun, open, fun(_, _, _) -> {ok, gun_pid} end),
        meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
        meck:expect(gun, request, fun(_, _, _, _, _) -> stream_ref end),
        meck:expect(gun, await, fun(_, _, _) -> {response, fin, 204, []} end),
        meck:expect(gun, close, fun(_) -> ok end),
        try
            ?assertMatch({ok, #{reply := {204, _}}, _}, pertisk_eproxy_handler:init(Req, #{}))
        after
            unload_mocks([gun])
        end
    end).

headers_have_sse_auth_invalid_type_test() ->
    ?assertNot(pertisk_eproxy_handler:headers_have_sse_auth(42)).

upstream_req_kind_grpc_timeout_header_test() ->
    H = #{<<"grpc-timeout">> => <<"3S">>},
    ?assertEqual(grpc, pertisk_eproxy_handler:upstream_req_kind(<<"/">>, H)).

upstream_req_kind_x_grpc_web_header_test() ->
    H = #{<<"x-grpc-web">> => <<"1">>},
    ?assertEqual(grpc, pertisk_eproxy_handler:upstream_req_kind(<<"/">>, H)).

eventstream_initial_await_timeout_bad_config_defaults_test() ->
    unload_mocks([pertisk_eproxy_config]),
    meck:new(pertisk_eproxy_config, [unstick, no_link]),
    meck:expect(pertisk_eproxy_config, get_config, fun() -> #{sse_initial_headers_timeout_ms => <<"bad">>} end),
    try
        ?assertEqual(5000, pertisk_eproxy_handler:eventstream_initial_await_timeout_ms(#{}))
    after
        unload_mocks([pertisk_eproxy_config])
    end.

eventstream_initial_await_timeout_configured_test() ->
    unload_mocks([pertisk_eproxy_config]),
    meck:new(pertisk_eproxy_config, [unstick, no_link]),
    meck:expect(pertisk_eproxy_config, get_config, fun() -> #{sse_initial_headers_timeout_ms => 1234} end),
    try
        ?assertEqual(1234, pertisk_eproxy_handler:eventstream_initial_await_timeout_ms(#{}))
    after
        unload_mocks([pertisk_eproxy_config])
    end.
