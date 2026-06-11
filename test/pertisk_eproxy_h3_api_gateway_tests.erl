-module(pertisk_eproxy_h3_api_gateway_tests).

-include_lib("eunit/include/eunit.hrl").

h3(Conn, StreamId, Method, Path, Headers) ->
    pertisk_eproxy_h3_api_gateway:handle_request(Conn, StreamId, Method, Path, Headers).

auth(Authority) ->
    [{<<":authority">>, Authority}].

-define(GUN_MOCK_PID, gun_h3_mock_conn).
-define(GUN_MOCK_STREAM, gun_h3_mock_stream).

unload_mocks(Mods) ->
    lists:foreach(
        fun(Mod) ->
            case lists:member(Mod, meck:mocked()) of
                true ->
                    try meck:unload(Mod) catch _:_ -> ok end;
                false ->
                    ok
            end
        end,
        Mods
    ).

with_quic_h3_mock(Fun) ->
    unload_mocks([quic_h3]),
    meck:new(quic_h3, [unstick, no_link]),
    meck:expect(quic_h3, send_response, fun(_, _, _, _) -> ok end),
    meck:expect(quic_h3, send_data, fun(_, _, _, _) -> ok end),
    meck:expect(quic_h3, set_stream_handler, fun(_, _, _) -> {ok, []} end),
    try
        Fun()
    after
        unload_mocks([quic_h3])
    end.

with_gun_h3_proxy_mock(Fun) -> with_gun_h3_proxy_mock(#{}, Fun).
with_gun_h3_proxy_mock(Opts, Fun) when is_map(Opts), is_function(Fun, 0) ->
    unload_mocks([gun, pertisk_eproxy_upstream_pool]),
    meck:new(gun, [unstick, no_link]),
    meck:new(pertisk_eproxy_upstream_pool, [unstick, no_link]),
    Checkout = maps:get(checkout, Opts, {ok, ?GUN_MOCK_PID}),
    meck:expect(pertisk_eproxy_upstream_pool, checkout, fun(_, _, _, _, _) -> Checkout end),
    meck:expect(pertisk_eproxy_upstream_pool, invalidate, fun(_) -> ok end),
    meck:expect(gun, open, fun(_, _, _) -> {ok, ?GUN_MOCK_PID} end),
    meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
    meck:expect(gun, request, fun(_, M, P, _, _) -> put(gun_last_request, {M, P}), ?GUN_MOCK_STREAM end),
    Ref = make_ref(), put({gun_await_queue, Ref}, maps:get(awaits, Opts, [{response, fin, 200, []}])),
    meck:expect(gun, await, fun(_, _, _) -> gun_dequeue_await(Ref) end),
    meck:expect(gun, await_body, fun(_, _, _) -> maps:get(await_body, Opts, {ok, <<"upstream">>}) end),
    meck:expect(gun, close, fun(_) -> ok end),
    try Fun() after erase({gun_await_queue, Ref}), erase(gun_last_request), unload_mocks([gun, pertisk_eproxy_upstream_pool]) end.
gun_dequeue_await(Ref) ->
    case get({gun_await_queue, Ref}) of [N | R] -> put({gun_await_queue, Ref}, R), N; [] -> {error, unexpected_await} end.
with_proxied_site(Fun) ->
    Name = <<"h3proxy">>, Up = #{addr => <<"backend.local:8080">>, weight => 1},
    Site = #{host => <<"proxy.test">>, backend => Name, routes => [#{path => <<"/">>, path_type => prefix}]},
    Backend = #{name => Name, algorithm => round_robin, upstreams => [Up]},
    _ = pertisk_eproxy_test_helpers:stop_backend(Name),
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(Name, [Up]), true = erlang:unlink(Pid),
    pertisk_eproxy_test_helpers:sync_router([Site], [Backend]),
    try Fun(#{host => <<"proxy.test">>, backend => Name})
    after pertisk_eproxy_test_helpers:stop_backend(Name), pertisk_eproxy_test_helpers:sync_router([], []) end.
with_sse_gun_mock(Awaits, Fun) ->
    unload_mocks([gun]),
    meck:new(gun, [unstick, no_link]),
    Ref = make_ref(),
    put({gun_await_queue, Ref}, Awaits),
    meck:expect(gun, open, fun(_, _, _) -> {ok, ?GUN_MOCK_PID} end),
    meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
    meck:expect(gun, request, fun(_, _, _, _, _) -> ?GUN_MOCK_STREAM end),
    meck:expect(gun, await, fun(_, _, _) -> gun_dequeue_await(Ref) end),
    meck:expect(gun, close, fun(_) -> ok end),
    try Fun() after erase({gun_await_queue, Ref}), unload_mocks([gun]) end.
capture_h3_status(Fun) ->
    meck:expect(quic_h3, send_response, fun(_, _, S, _) -> put(h3_sent_status, S), ok end), Fun().

management_listener_bind_stack_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    {Bind, Stack} = pertisk_eproxy_h3_api_gateway:management_listener_bind_stack(),
    ?assert(is_binary(Bind)),
    ?assert(is_binary(Stack)),
    ?assert(byte_size(Bind) > 0),
    ?assert(byte_size(Stack) > 0).

grpc_content_type_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Headers = auth(<<"example.com">>) ++ [{<<"content-type">>, <<"application/grpc">>}],
    ?assertEqual(ok, h3(self(), 1, <<"POST">>, <<"/">>, Headers)).

grpc_web_content_type_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Headers = auth(<<"example.com">>) ++ [{<<"content-type">>, <<"application/grpc-web+proto">>}],
    ?assertEqual(ok, h3(self(), 1, <<"POST">>, <<"/service">>, Headers)).

connect_protocol_content_type_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Headers = auth(<<"example.com">>) ++ [{<<"content-type">>, <<"application/connect+json">>}],
    ?assertEqual(ok, h3(self(), 1, <<"POST">>, <<"/">>, Headers)).

grpc_metadata_header_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Headers = auth(<<"example.com">>) ++ [{<<"grpc-metadata-x-test">>, <<"1">>}],
    ?assertEqual(ok, h3(self(), 1, <<"POST">>, <<"/">>, Headers)).

grpc_timeout_header_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Headers = auth(<<"example.com">>) ++ [{<<"grpc-timeout">>, <<"1S">>}],
    ?assertEqual(ok, h3(self(), 1, <<"POST">>, <<"/">>, Headers)).

x_grpc_web_header_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Headers = auth(<<"example.com">>) ++ [{<<"x-grpc-web">>, <<"1">>}],
    ?assertEqual(ok, h3(self(), 1, <<"POST">>, <<"/">>, Headers)).

benchmark_ingress_live_get_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/api/ingress/live">>, auth(<<"localhost">>))).

benchmark_ingress_live_head_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    ?assertEqual(ok, h3(self(), 1, <<"HEAD">>, <<"/api/ingress/live">>, auth(<<"localhost">>))).

benchmark_health_get_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/api/health">>, auth(<<"localhost">>))).

no_route_404_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    pertisk_eproxy_test_helpers:sync_router([], []),
    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/missing">>, auth(<<"unknown.test">>))).

authority_strips_port_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    pertisk_eproxy_test_helpers:sync_router([], []),
    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, auth(<<"host.example.com:443">>))).

auth_refresh_skips_body_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    pertisk_eproxy_test_helpers:sync_router([], []),
    ?assertEqual(
        ok,
        h3(self(), 1, <<"POST">>, <<"/api/auth/refresh">>, auth(<<"example.com">>))
    ).

stop_is_ok_test() ->
    ?assertEqual(ok, pertisk_eproxy_h3_api_gateway:stop()),
    ?assertEqual(ok, pertisk_eproxy_h3_api_gateway:stop_probe()).

grpc_accept_encoding_header_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Headers =
        auth(<<"example.com">>) ++ [{<<"grpc-accept-encoding">>, <<"gzip">>}],
    ?assertEqual(ok, h3(self(), 1, <<"POST">>, <<"/">>, Headers)).

connect_timeout_header_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Headers =
        auth(<<"example.com">>) ++ [{<<"connect-timeout-ms">>, <<"5000">>}],
    ?assertEqual(ok, h3(self(), 1, <<"POST">>, <<"/">>, Headers)).

grpc_encoding_header_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Headers = auth(<<"example.com">>) ++ [{<<"grpc-encoding">>, <<"identity">>}],
    ?assertEqual(ok, h3(self(), 1, <<"POST">>, <<"/">>, Headers)).

benchmark_healthz_get_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/healthz">>, auth(<<"localhost">>))).

auth_logout_skips_body_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    pertisk_eproxy_test_helpers:sync_router([], []),
    ?assertEqual(
        ok,
        h3(self(), 1, <<"POST">>, <<"/api/auth/logout">>, auth(<<"example.com">>))
    ).

management_api_via_router_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Host = <<"h3-mgmt.test">>,
    pertisk_eproxy_test_helpers:sync_mgmt_site(Host),
    try
        ?assertEqual(
            ok,
            h3(self(), 1, <<"GET">>, <<"/api/version">>, auth(Host))
        )
    after
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

path_with_query_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    pertisk_eproxy_test_helpers:sync_router([], []),
    ?assertEqual(
        ok,
        h3(self(), 1, <<"GET">>, <<"/missing?x=1">>, auth(<<"unknown.test">>))
    ).

grpc_returns_421_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Headers = auth(<<"example.com">>) ++ [{<<"content-type">>, <<"application/grpc">>}],
    ?assertEqual(ok, h3(self(), 1, <<"POST">>, <<"/grpc.Service/Method">>, Headers)).

connect_proto_content_type_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Headers = auth(<<"example.com">>) ++ [{<<"content-type">>, <<"application/connect+proto">>}],
    ?assertEqual(ok, h3(self(), 1, <<"POST">>, <<"/connect">>, Headers)).

te_header_alone_not_grpc_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    pertisk_eproxy_test_helpers:sync_router([], []),
    Headers = auth(<<"example.com">>) ++ [{<<"te">>, <<"trailers">>}],
    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/missing">>, Headers)).

missing_authority_uses_dash_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    pertisk_eproxy_test_helpers:sync_router([], []),
    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/missing">>, [])).

x_forwarded_for_client_ip_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    pertisk_eproxy_test_helpers:sync_router([], []),
    Headers = [{<<":authority">>, <<"example.com">>}, {<<"x-forwarded-for">>, <<"203.0.113.1">>}],
    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/missing">>, Headers)).

options_no_route_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    pertisk_eproxy_test_helpers:sync_router([], []),
    ?assertEqual(ok, h3(self(), 1, <<"OPTIONS">>, <<"/missing">>, auth(<<"unknown.test">>))).

head_no_route_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    pertisk_eproxy_test_helpers:sync_router([], []),
    ?assertEqual(ok, h3(self(), 1, <<"HEAD">>, <<"/missing">>, auth(<<"unknown.test">>))).

benchmark_readyz_get_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/readyz">>, auth(<<"localhost">>))).

post_with_content_length_zero_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    pertisk_eproxy_test_helpers:sync_router([], []),
    Headers =
        auth(<<"example.com">>) ++
        [{<<"content-type">>, <<"application/json">>}, {<<"content-length">>, <<"0">>}],
    ?assertEqual(ok, h3(self(), 1, <<"POST">>, <<"/api/data">>, Headers)).

routed_site_get_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Site = #{
        host => <<"routed.test">>,
        backend => <<"web">>,
        routes => [#{path => <<"/">>, path_type => prefix}]
    },
    Backend = #{
        name => <<"web">>,
        algorithm => round_robin,
        upstreams => [#{addr => <<"127.0.0.1:9">>, weight => 1}]
    },
    pertisk_eproxy_test_helpers:sync_router([Site], [Backend]),
    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, auth(<<"routed.test">>))).

cookie_header_merge_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    pertisk_eproxy_test_helpers:sync_router([], []),
    Headers =
        auth(<<"example.com">>) ++
        [
            {<<"cookie">>, <<"a=1">>},
            {<<"cookie">>, <<"b=2">>}
        ],
    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/missing">>, Headers)).

console_path_query_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    pertisk_eproxy_test_helpers:sync_router([], []),
    ?assertEqual(
        ok,
        h3(self(), 1, <<"GET">>, <<"/termproxy">>, auth(<<"example.com">>) ++ [{<<"x">>, <<"1">>}])
    ).

sse_routed_site_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    N = <<"websse">>,
    Up = #{addr => <<"backend.local:8080">>, weight => 1},
    Site = #{
        host => <<"sse.test">>,
        backend => N,
        routes => [#{path => <<"/api/v1/stream">>, path_type => prefix}]
    },
    Backend = #{name => N, algorithm => round_robin, upstreams => [Up]},
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(N, [Up]),
    true = erlang:unlink(Pid),
    pertisk_eproxy_test_helpers:sync_router([Site], [Backend]),
    Headers =
        auth(<<"sse.test">>) ++
        [
            {<<"accept">>, <<"text/event-stream">>},
            {<<"authorization">>, <<"Bearer token">>}
        ],
    try
        with_quic_h3_mock(fun() ->
            with_sse_gun_mock(
                [{response, nofin, 200, []}, {data, fin, <<"event">>}],
                fun() ->
                    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/api/v1/stream/events">>, Headers))
                end
            )
        end)
    after
        pertisk_eproxy_test_helpers:stop_backend(N),
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

delete_no_route_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    pertisk_eproxy_test_helpers:sync_router([], []),
    ?assertEqual(ok, h3(self(), 1, <<"DELETE">>, <<"/missing">>, auth(<<"unknown.test">>))).

patch_no_route_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    pertisk_eproxy_test_helpers:sync_router([], []),
    ?assertEqual(ok, h3(self(), 1, <<"PATCH">>, <<"/missing">>, auth(<<"unknown.test">>))).

routed_site_with_query_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Site = #{
        host => <<"q.test">>,
        backend => <<"web">>,
        routes => [#{path => <<"/">>, path_type => prefix}]
    },
    Backend = #{
        name => <<"web">>,
        algorithm => round_robin,
        upstreams => [#{addr => <<"127.0.0.1:9">>, weight => 1}]
    },
    pertisk_eproxy_test_helpers:sync_router([Site], [Backend]),
    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/?q=1">>, auth(<<"q.test">>))).

benchmark_ingress_ready_get_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/api/ingress/ready">>, auth(<<"localhost">>))).

auth_login_skips_body_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    pertisk_eproxy_test_helpers:sync_router([], []),
    ?assertEqual(
        ok,
        h3(self(), 1, <<"POST">>, <<"/api/auth/login">>, auth(<<"example.com">>))
    ).

grpc_accept_encoding_only_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Headers = auth(<<"example.com">>) ++ [{<<"grpc-accept-encoding">>, <<"gzip, deflate">>}],
    ?assertEqual(ok, h3(self(), 1, <<"POST">>, <<"/">>, Headers)).

user_agent_header_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    pertisk_eproxy_test_helpers:sync_router([], []),
    Headers = auth(<<"example.com">>) ++ [{<<"user-agent">>, <<"test-agent">>}],
    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/missing">>, Headers)).

accept_encoding_header_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    pertisk_eproxy_test_helpers:sync_router([], []),
    Headers = auth(<<"example.com">>) ++ [{<<"accept-encoding">>, <<"gzip">>}, {<<"accept">>, <<"*/*">>}],
    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/missing">>, Headers)).

proxied_get_success_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() -> with_gun_h3_proxy_mock(fun() ->
        with_proxied_site(fun(#{host := H}) -> ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, auth(H))) end)
    end) end).

proxied_nofin_stream_body_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() -> with_gun_h3_proxy_mock(#{awaits => [{response, nofin, 200, []}], await_body => {ok, <<"streamed">>}}, fun() ->
        with_proxied_site(fun(#{host := H}) -> ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/stream">>, auth(H))), ?assertEqual(1, meck:num_calls(gun, await_body, '_')) end)
    end) end).

proxied_gun_await_timeout_502_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() -> capture_h3_status(fun() -> with_gun_h3_proxy_mock(#{awaits => [{error, timeout}]}, fun() ->
        with_proxied_site(fun(#{host := H}) -> ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, auth(H))), ?assertEqual(502, get(h3_sent_status)) end)
    end) end) end).

proxied_pool_exhausted_502_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() -> capture_h3_status(fun() -> with_gun_h3_proxy_mock(#{checkout => {error, pool_exhausted}}, fun() ->
        with_proxied_site(fun(#{host := H}) -> ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, auth(H))), ?assertEqual(502, get(h3_sent_status)) end)
    end) end) end).

proxied_post_201_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() -> capture_h3_status(fun() -> with_gun_h3_proxy_mock(#{awaits => [{response, fin, 201, []}]}, fun() ->
        with_proxied_site(fun(#{host := H}) ->
            Hdr = auth(H) ++ [{<<"content-length">>, <<"0">>}],
            ?assertEqual(ok, h3(self(), 1, <<"POST">>, <<"/api/items">>, Hdr)), ?assertEqual(201, get(h3_sent_status))
        end)
    end) end) end).

proxied_get_404_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() -> capture_h3_status(fun() -> with_gun_h3_proxy_mock(#{awaits => [{response, fin, 404, []}]}, fun() ->
        with_proxied_site(fun(#{host := H}) -> ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/missing">>, auth(H))), ?assertEqual(404, get(h3_sent_status)) end)
    end) end) end).

proxied_get_query_string_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() -> with_gun_h3_proxy_mock(fun() ->
        with_proxied_site(fun(#{host := H}) -> ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/api?a=1">>, auth(H))), ?assertEqual({<<"GET">>, <<"/api?a=1">>}, get(gun_last_request)) end)
    end) end).

grpc_web_text_content_type_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Hdr = auth(<<"example.com">>) ++ [{<<"content-type">>, <<"application/grpc-web+text">>}],
    with_quic_h3_mock(fun() -> capture_h3_status(fun() ->
        ?assertEqual(ok, h3(self(), 1, <<"POST">>, <<"/service">>, Hdr)), ?assertEqual(421, get(h3_sent_status))
    end) end).

connect_json_content_type_421_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Hdr = auth(<<"example.com">>) ++ [{<<"content-type">>, <<"application/connect+json">>}],
    with_quic_h3_mock(fun() -> capture_h3_status(fun() ->
        ?assertEqual(ok, h3(self(), 1, <<"POST">>, <<"/connect">>, Hdr)), ?assertEqual(421, get(h3_sent_status))
    end) end).

sse_eventstream_streaming_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    N = <<"h3sse">>, Up = #{addr => <<"backend.local:8080">>, weight => 1},
    Site = #{host => <<"sse-mock.test">>, backend => N, routes => [#{path => <<"/api/v1/stream">>, path_type => prefix}]},
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(N, [Up]), true = erlang:unlink(Pid),
    pertisk_eproxy_test_helpers:sync_router([Site], [#{name => N, algorithm => round_robin, upstreams => [Up]}]),
    try with_quic_h3_mock(fun() -> with_sse_gun_mock([{response, nofin, 200, []}, {data, nofin, <<"d1">>}, {data, fin, <<"d2">>}], fun() ->
        H = auth(<<"sse-mock.test">>) ++ [{<<"accept">>, <<"text/event-stream">>}],
        ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/api/v1/stream/events">>, H)),
        ?assertEqual(3, meck:num_calls(quic_h3, send_data, '_'))
    end) end) after pertisk_eproxy_test_helpers:stop_backend(N), pertisk_eproxy_test_helpers:sync_router([], []) end.

sse_accept_header_streaming_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    N = <<"h3sseacc">>, Up = #{addr => <<"backend.local:8080">>, weight => 1},
    Site = #{host => <<"sse-acc.test">>, backend => N, routes => [#{path => <<"/">>, path_type => prefix}]},
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(N, [Up]), true = erlang:unlink(Pid),
    pertisk_eproxy_test_helpers:sync_router([Site], [#{name => N, algorithm => round_robin, upstreams => [Up]}]),
    try with_quic_h3_mock(fun() -> with_sse_gun_mock([{response, nofin, 200, []}, {data, fin, <<"ok">>}], fun() ->
        H = auth(<<"sse-acc.test">>) ++ [{<<"accept">>, <<"text/event-stream">>}],
        ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/events">>, H)), ?assertEqual(2, meck:num_calls(quic_h3, send_data, '_'))
    end) end) after pertisk_eproxy_test_helpers:stop_backend(N), pertisk_eproxy_test_helpers:sync_router([], []) end.

management_sites_api_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    OldAuth = application:get_env(pertisk_eproxy, admin_auth),
    application:unset_env(pertisk_eproxy, admin_auth),
    Host = <<"h3-mgmt-sites.test">>,
    pertisk_eproxy_test_helpers:sync_mgmt_site(Host),
    Mgmt = pertisk_eproxy_config:management_loopback_upstream_bin(),
    pertisk_eproxy_test_helpers:sync_router(
        [#{host => Host, backend => <<"mgmt">>, routes => [#{path => <<"/">>, path_type => prefix}]}],
        [#{name => <<"mgmt">>, algorithm => round_robin, upstreams => [#{addr => Mgmt, weight => 1}]}]
    ),
    try
        with_quic_h3_mock(fun() ->
            capture_h3_status(fun() ->
                ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/api/sites">>, auth(Host))),
                ?assertEqual(200, get(h3_sent_status))
            end)
        end)
    after
        case OldAuth of
            {ok, V} -> application:set_env(pertisk_eproxy, admin_auth, V);
            undefined -> application:unset_env(pertisk_eproxy, admin_auth)
        end,
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

h3_compression_applied_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    unload_mocks([pertisk_eproxy_compression]),
    meck:new(pertisk_eproxy_compression, [unstick, no_link]),
    meck:expect(pertisk_eproxy_compression, maybe_compress_h3, fun(_, _, H, _) -> {H, <<"compressed">>} end),
    try
        with_quic_h3_mock(fun() ->
            with_gun_h3_proxy_mock(fun() ->
                with_proxied_site(fun(#{host := H}) ->
                    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, auth(H))),
                    ?assertEqual(1, meck:num_calls(pertisk_eproxy_compression, maybe_compress_h3, '_'))
                end)
            end)
        end)
    after
        unload_mocks([pertisk_eproxy_compression])
    end.

alt_svc_header_on_proxy_success_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        meck:expect(quic_h3, send_response, fun(_, _, _, Hdrs) -> put(h3_resp_hdrs, Hdrs), ok end),
        with_gun_h3_proxy_mock(fun() -> with_proxied_site(fun(#{host := H}) ->
            ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, auth(H))),
            ?assert(lists:keymember(<<"alt-svc">>, 1, get(h3_resp_hdrs)))
        end) end)
    end).

no_healthy_upstream_502_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Site = #{
        host => <<"noup.test">>,
        backend => <<"ghost-backend">>,
        routes => [#{path => <<"/">>, path_type => prefix}]
    },
    pertisk_eproxy_test_helpers:sync_router([Site], []),
    try
        with_quic_h3_mock(fun() ->
            capture_h3_status(fun() ->
                ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, auth(<<"noup.test">>))),
                ?assertEqual(502, get(h3_sent_status))
            end)
        end)
    after
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

proxied_patch_success_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() -> with_gun_h3_proxy_mock(#{awaits => [{response, fin, 200, []}]}, fun() ->
        with_proxied_site(fun(#{host := H}) ->
            Hdr = auth(H) ++ [{<<"content-length">>, <<"0">>}],
            ?assertEqual(ok, h3(self(), 1, <<"PATCH">>, <<"/api/item/1">>, Hdr)),
            ?assertEqual({<<"PATCH">>, <<"/api/item/1">>}, get(gun_last_request))
        end)
    end) end).

proxied_delete_success_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() -> capture_h3_status(fun() -> with_gun_h3_proxy_mock(#{awaits => [{response, fin, 204, []}]}, fun() ->
        with_proxied_site(fun(#{host := H}) -> ?assertEqual(ok, h3(self(), 1, <<"DELETE">>, <<"/api/item/1">>, auth(H))), ?assertEqual(204, get(h3_sent_status)) end)
    end) end) end).

chunked_request_body_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    C1 = <<"{part">>, C2 = <<":1}">>, Body = <<C1/binary, C2/binary>>,
    with_quic_h3_mock(fun() ->
        meck:expect(quic_h3, set_stream_handler, fun(_, _, _) -> {ok, [{C1, false}, {C2, true}]} end),
        with_gun_h3_proxy_mock(fun() -> with_proxied_site(fun(#{host := H}) ->
            Hdr = auth(H) ++ [
                {<<"content-type">>, <<"application/json">>},
                {<<"transfer-encoding">>, <<"chunked">>},
                {<<"content-length">>, integer_to_binary(byte_size(Body))}
            ],
            ?assertEqual(ok, h3(self(), 1, <<"POST">>, <<"/api/data">>, Hdr)),
            ?assertEqual({<<"POST">>, <<"/api/data">>}, get(gun_last_request)),
            ?assertEqual(1, meck:num_calls(quic_h3, set_stream_handler, '_'))
        end) end)
    end).

proxy_retry_after_connection_closed_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() -> capture_h3_status(fun() ->
        unload_mocks([gun, pertisk_eproxy_upstream_pool]),
        meck:new(gun, [unstick, no_link]),
        meck:new(pertisk_eproxy_upstream_pool, [unstick, no_link]),
        CRef = make_ref(), put({gun_checkout_count, CRef}, 0),
        meck:expect(pertisk_eproxy_upstream_pool, checkout, fun(_, _, _, _, _) ->
            N = get({gun_checkout_count, CRef}) + 1, put({gun_checkout_count, CRef}, N), {ok, ?GUN_MOCK_PID} end),
        meck:expect(pertisk_eproxy_upstream_pool, invalidate, fun(_) -> ok end),
        meck:expect(gun, open, fun(_, _, _) -> {ok, ?GUN_MOCK_PID} end),
        meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
        meck:expect(gun, request, fun(_, _, _, _, _) -> ?GUN_MOCK_STREAM end),
        ARef = make_ref(), put({gun_await_queue, ARef}, [{error, {down, normal}}, {response, fin, 200, []}]),
        meck:expect(gun, await, fun(_, _, _) -> gun_dequeue_await(ARef) end),
        meck:expect(gun, await_body, fun(_, _, _) -> {ok, <<"ok">>} end),
        meck:expect(gun, close, fun(_) -> ok end),
        try with_proxied_site(fun(#{host := H}) ->
            ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, auth(H))),
            ?assertEqual(2, get({gun_checkout_count, CRef})), ?assertEqual(200, get(h3_sent_status))
        end) after erase({gun_checkout_count, CRef}), erase({gun_await_queue, ARef}), unload_mocks([gun, pertisk_eproxy_upstream_pool]) end
    end) end).
