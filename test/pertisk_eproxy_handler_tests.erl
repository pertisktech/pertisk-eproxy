-module(pertisk_eproxy_handler_tests).

-include_lib("eunit/include/eunit.hrl").

parse_upstream_host_port_test() ->
    ?assertEqual({"example.com", 80, tcp}, pertisk_eproxy_handler:parse_upstream("example.com")),
    ?assertEqual({"example.com", 8080, tcp}, pertisk_eproxy_handler:parse_upstream("example.com:8080")).

parse_upstream_https_test() ->
    ?assertEqual({"secure.example.com", 443, tls}, pertisk_eproxy_handler:parse_upstream("https://secure.example.com")).

parse_upstream_trims_slash_test() ->
    ?assertEqual({"host", 80, tcp}, pertisk_eproxy_handler:parse_upstream("host/")).

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

eventstream_initial_await_timeout_test() ->
    T = pertisk_eproxy_handler:eventstream_initial_await_timeout_ms(<<"127.0.0.1:8080">>),
    ?assert(is_integer(T)),
    ?assert(T > 0).

should_sse_early_flush_test() ->
    H = #{<<"authorization">> => <<"Bearer x">>},
    ?assert(pertisk_eproxy_handler:should_sse_early_flush(<<"host">>, <<"/api/v1/stream">>, H)),
    ?assertNot(pertisk_eproxy_handler:should_sse_early_flush(<<"host">>, <<"/">>, #{})).

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

with_handler_req(Opts, Fun) ->
    unload_mocks([
        cowboy_req, pertisk_eproxy_router, pertisk_eproxy_backend, pertisk_eproxy_config,
        pertisk_eproxy_compression, pertisk_eproxy_metrics, pertisk_eproxy_access_log,
        pertisk_eproxy_alt_svc, pertisk_eproxy_response_headers
    ]),
    pertisk_eproxy_test_helpers:ensure_metrics(),
    meck:new(cowboy_req, [unstick]),
    meck:new(pertisk_eproxy_router, [unstick]),
    meck:new(pertisk_eproxy_backend, [unstick]),
    meck:new(pertisk_eproxy_config, [unstick, passthrough]),
    meck:new(pertisk_eproxy_compression, [unstick]),
    meck:new(pertisk_eproxy_metrics, [unstick]),
    meck:new(pertisk_eproxy_access_log, [unstick]),
    meck:new(pertisk_eproxy_alt_svc, [unstick]),
    meck:new(pertisk_eproxy_response_headers, [unstick]),
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
    meck:new(cowboy_req, [unstick]),
    meck:new(pertisk_eproxy_ws_handler, [unstick]),
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
