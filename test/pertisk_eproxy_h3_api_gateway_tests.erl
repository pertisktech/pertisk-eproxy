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
                    pertisk_eproxy_test_helpers:ignoring_errors(
                fun() -> pertisk_eproxy_test_helpers:unload_mocks([Mod]) end
            );
                false ->
                    ok
            end
        end,
        Mods
    ).

with_quic_h3_mock(Fun) ->
    unload_mocks([quic_h3, pertisk_eproxy_rate_limit]),
    pertisk_eproxy_rate_limit:reset(),
    meck:new(quic_h3, [unstick, no_link]),
    meck:expect(quic_h3, send_response, fun(_, _, _, _) -> ok end),
    meck:expect(quic_h3, send_data, fun(_, _, _, _) -> ok end),
    meck:expect(quic_h3, set_stream_handler, fun(_, _, _) -> {ok, []} end),
    meck:new(pertisk_eproxy_rate_limit, [unstick, no_link]),
    meck:expect(pertisk_eproxy_rate_limit, check, fun(_, _) -> allow end),
    meck:expect(pertisk_eproxy_rate_limit, check, fun(_, _, _) -> allow end),
    try
        Fun()
    after
        unload_mocks([quic_h3, pertisk_eproxy_rate_limit])
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

head_proxied_empty_body_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        capture_h3_status(fun() ->
            with_gun_h3_proxy_mock(#{awaits => [{response, fin, 200, []}]}, fun() ->
                with_proxied_site(fun(#{host := H}) ->
                    ?assertEqual(ok, h3(self(), 1, <<"HEAD">>, <<"/">>, auth(H))),
                    ?assertEqual(200, get(h3_sent_status))
                end)
            end)
        end)
    end).

admin_upstream_fallback_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Host = <<"admin.example.com">>,
    Site = #{
        host => Host,
        backend => <<"web">>,
        routes => [#{path => <<"/api">>, path_type => prefix}]
    },
    Backend = #{
        name => <<"web">>,
        algorithm => round_robin,
        upstreams => [#{addr => <<"127.0.0.1:9">>, weight => 1}]
    },
    pertisk_eproxy_test_helpers:sync_router([Site], [Backend]),
    try
        with_quic_h3_mock(fun() ->
            capture_h3_status(fun() ->
                unload_mocks([gun, pertisk_eproxy_upstream_pool]),
                meck:new(gun, [unstick, no_link]),
                meck:new(pertisk_eproxy_upstream_pool, [unstick, no_link]),
                meck:expect(pertisk_eproxy_upstream_pool, checkout, fun(_, _, _, _, _) ->
                    {ok, ?GUN_MOCK_PID}
                end),
                meck:expect(pertisk_eproxy_upstream_pool, invalidate, fun(_) -> ok end),
                meck:expect(gun, open, fun(_, _, _) -> {ok, ?GUN_MOCK_PID} end),
                meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
                meck:expect(gun, request, fun(_, _, _, _, _) -> ?GUN_MOCK_STREAM end),
                meck:expect(gun, await, fun(_, _, _) -> {error, timeout} end),
                meck:expect(gun, close, fun(_) -> ok end),
                try
                    ?assertEqual(
                        ok,
                        h3(self(), 1, <<"GET">>, <<"/api/health">>, auth(Host))
                    ),
                    ?assertEqual(200, get(h3_sent_status))
                after
                    unload_mocks([gun, pertisk_eproxy_upstream_pool])
                end
            end)
        end)
    after
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

sse_early_flush_idle_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    N = <<"h3sseflush">>,
    Up = #{addr => <<"backend.local:8080">>, weight => 1},
    Site = #{
        host => <<"sse-flush.test">>,
        backend => N,
        routes => [#{path => <<"/api/v1/stream">>, path_type => prefix}]
    },
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(N, [Up]),
    true = erlang:unlink(Pid),
    pertisk_eproxy_test_helpers:sync_router([Site], [#{name => N, algorithm => round_robin, upstreams => [Up]}]),
    Headers =
        auth(<<"sse-flush.test">>) ++
        [
            {<<"accept">>, <<"text/event-stream">>},
            {<<"authorization">>, <<"Bearer token">>}
        ],
    try
        with_quic_h3_mock(fun() ->
            capture_h3_status(fun() ->
                with_sse_gun_mock([{error, timeout}, {response, nofin, 200, []}, {data, fin, <<"evt">>}], fun() ->
                    ?assertEqual(
                        ok,
                        h3(self(), 1, <<"GET">>, <<"/api/v1/stream/events">>, Headers)
                    ),
                    ?assertEqual(200, get(h3_sent_status))
                end)
            end)
        end)
    after
        pertisk_eproxy_test_helpers:stop_backend(N),
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

console_query_alt_svc_clear_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        meck:expect(quic_h3, send_response, fun(_, _, _, Hdrs) -> put(h3_resp_hdrs, Hdrs), ok end),
        with_gun_h3_proxy_mock(fun() ->
            with_proxied_site(fun(#{host := H}) ->
                ?assertEqual(
                    ok,
                    h3(self(), 1, <<"GET">>, <<"/shell">>, auth(H) ++ [{<<"x">>, <<"1">>}])
                ),
                Hdrs = get(h3_resp_hdrs),
                ?assertEqual({<<"alt-svc">>, <<"clear">>}, lists:keyfind(<<"alt-svc">>, 1, Hdrs))
            end)
        end)
    end).

upstream_500_admin_fallback_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Host = <<"admin.example.com">>,
    Site = #{
        host => Host,
        backend => <<"web">>,
        routes => [#{path => <<"/api">>, path_type => prefix}]
    },
    Backend = #{
        name => <<"web">>,
        algorithm => round_robin,
        upstreams => [#{addr => <<"backend.local:8080">>, weight => 1}]
    },
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(<<"web">>, [
        #{addr => <<"backend.local:8080">>, weight => 1}
    ]),
    true = erlang:unlink(Pid),
    pertisk_eproxy_test_helpers:sync_router([Site], [Backend]),
    try
        with_quic_h3_mock(fun() ->
            capture_h3_status(fun() ->
                with_gun_h3_proxy_mock(#{awaits => [{response, fin, 503, []}]}, fun() ->
                    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/api/health">>, auth(Host))),
                    ?assertEqual(200, get(h3_sent_status))
                end)
            end)
        end)
    after
        pertisk_eproxy_test_helpers:stop_backend(<<"web">>),
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

argocd_cookie_bearer_forward_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        with_gun_h3_proxy_mock(fun() ->
            with_proxied_site(fun(#{host := H}) ->
                Hdr =
                    auth(H) ++
                    [{<<"cookie">>, <<"argocd.token=secret-token; other=1">>}],
                ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, Hdr)),
                ?assertEqual(1, meck:num_calls(gun, request, '_'))
            end)
        end)
    end).

sse_fin_short_body_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    N = <<"h3ssefin">>,
    Up = #{addr => <<"backend.local:8080">>, weight => 1},
    Site = #{
        host => <<"sse-fin.test">>,
        backend => N,
        routes => [#{path => <<"/user/events">>, path_type => prefix}]
    },
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(N, [Up]),
    true = erlang:unlink(Pid),
    pertisk_eproxy_test_helpers:sync_router([Site], [#{name => N, algorithm => round_robin, upstreams => [Up]}]),
    try
        with_quic_h3_mock(fun() ->
            unload_mocks([gun]),
            meck:new(gun, [unstick, no_link]),
            Ref = make_ref(),
            put({gun_await_queue, Ref}, [{response, fin, 200, []}]),
            meck:expect(gun, open, fun(_, _, _) -> {ok, ?GUN_MOCK_PID} end),
            meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
            meck:expect(gun, request, fun(_, _, _, _, _) -> ?GUN_MOCK_STREAM end),
            meck:expect(gun, await, fun(_, _, _) -> gun_dequeue_await(Ref) end),
            meck:expect(gun, await_body, fun(_, _, _) -> {ok, <<"payload">>} end),
            meck:expect(gun, close, fun(_) -> ok end),
            try
                H = auth(<<"sse-fin.test">>) ++ [{<<"accept">>, <<"text/event-stream">>}],
                ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/user/events">>, H))
            after
                erase({gun_await_queue, Ref}),
                unload_mocks([gun])
            end
        end)
    after
        pertisk_eproxy_test_helpers:stop_backend(N),
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

proxied_options_success_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        capture_h3_status(fun() ->
            with_gun_h3_proxy_mock(#{awaits => [{response, fin, 204, []}]}, fun() ->
                with_proxied_site(fun(#{host := H}) ->
                    ?assertEqual(ok, h3(self(), 1, <<"OPTIONS">>, <<"/">>, auth(H))),
                    ?assertEqual(204, get(h3_sent_status))
                end)
            end)
        end)
    end).

gateway_tls_config() ->
    Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
    Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
    #{
        https_port => 18443,
        quic_port => 18443,
        tls_cert_file => Cert,
        tls_key_file => Key,
        sites => [],
        h3_idle_timeout_secs => 300,
        h3_keepalive_interval_secs => 20,
        h3_quic_pool_size => 4
    }.

with_gateway_start_mock(Fun) ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    unload_mocks([quic_h3]),
    meck:new(quic_h3, [unstick, no_link]),
    meck:expect(quic_h3, start_server, fun(_, _, _) -> {ok, self()} end),
    meck:expect(quic_h3, stop_server, fun(_) -> ok end),
    try
        Fun()
    after
        pertisk_eproxy_test_helpers:ignoring_errors(fun() -> pertisk_eproxy_h3_api_gateway:stop() end),
        pertisk_eproxy_test_helpers:ignoring_errors(fun() -> pertisk_eproxy_h3_api_gateway:stop_probe() end),
        unload_mocks([quic_h3])
    end.

gateway_start_ok_test() ->
    with_gateway_start_mock(fun() ->
        ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(gateway_tls_config()))
    end).

gateway_start_probe_ok_test() ->
    with_gateway_start_mock(fun() ->
        ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start_probe(gateway_tls_config()))
    end).

gateway_start_missing_cert_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_deps(),
    Config = (gateway_tls_config())#{
        tls_cert_file => "/nonexistent/cert.pem",
        tls_key_file => "/nonexistent/key.pem"
    },
    ?assertMatch({error, {missing_tls_file, cert, _}}, pertisk_eproxy_h3_api_gateway:start(Config)).

gateway_start_quic_failure_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    unload_mocks([quic_h3]),
    meck:new(quic_h3, [unstick, no_link]),
    meck:expect(quic_h3, start_server, fun(_, _, _) -> {error, eaddrinuse} end),
    try
        ?assertMatch({error, _}, pertisk_eproxy_h3_api_gateway:start(gateway_tls_config()))
    after
        unload_mocks([quic_h3])
    end.

h3_send_connection_gone_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    pertisk_eproxy_test_helpers:sync_router([], []),
    unload_mocks([quic_h3]),
    meck:new(quic_h3, [unstick, no_link]),
    meck:expect(quic_h3, send_response, fun(_, _, _, _) -> {error, closed} end),
    meck:expect(quic_h3, send_data, fun(_, _, _, _) -> ok end),
    try
        ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/missing">>, auth(<<"unknown.test">>)))
    after
        unload_mocks([quic_h3])
    end.

h3_handle_request_internal_error_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    unload_mocks([quic_h3, pertisk_eproxy_router]),
    meck:new(quic_h3, [unstick, no_link]),
    meck:new(pertisk_eproxy_router, [unstick, no_link]),
    meck:expect(quic_h3, send_response, fun(_, _, S, _) -> put(h3_sent_status, S), ok end),
    meck:expect(quic_h3, send_data, fun(_, _, _, _) -> ok end),
    meck:expect(pertisk_eproxy_router, route, fun(_, _) -> throw(test_crash) end),
    try
        ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/crash">>, auth(<<"example.com">>))),
        ?assertEqual(500, get(h3_sent_status))
    after
        unload_mocks([quic_h3, pertisk_eproxy_router])
    end.

vncproxy_skips_x_forwarded_for_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        with_gun_h3_proxy_mock(fun() ->
            with_proxied_site(fun(#{host := H}) ->
                ?assertEqual(
                    ok,
                    h3(self(), 1, <<"GET">>, <<"/vncproxy">>, auth(H) ++ [{<<"x">>, <<"1">>}])
                ),
                ?assertEqual({<<"GET">>, <<"/vncproxy">>}, get(gun_last_request))
            end)
        end)
    end).

argocd_token_v2_cookie_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        with_gun_h3_proxy_mock(fun() ->
            with_proxied_site(fun(#{host := H}) ->
                Hdr = auth(H) ++ [{<<"cookie">>, <<"argocd.token.v2=v2-secret; other=1">>}],
                ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, Hdr)),
                ?assertEqual(1, meck:num_calls(gun, request, '_'))
            end)
        end)
    end).

proxied_upstream_local_admin_error_502_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Mgmt = pertisk_eproxy_config:management_loopback_upstream_bin(),
    Site = #{
        host => <<"mgmt-err.test">>,
        backend => <<"mgmt-backend">>,
        routes => [#{path => <<"/">>, path_type => prefix}]
    },
    Backend = #{
        name => <<"mgmt-backend">>,
        algorithm => round_robin,
        upstreams => [#{addr => Mgmt, weight => 1}]
    },
    pertisk_eproxy_test_helpers:sync_router([Site], [Backend]),
    try
        with_quic_h3_mock(fun() ->
            capture_h3_status(fun() ->
                unload_mocks([pertisk_eproxy_h3_local_admin]),
                meck:new(pertisk_eproxy_h3_local_admin, [unstick, no_link]),
                meck:expect(pertisk_eproxy_h3_local_admin, try_dispatch, fun(_, _, _, _, _, _, _) ->
                    {error, timeout}
                end),
                try
                    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, auth(<<"mgmt-err.test">>))),
                    ?assertEqual(502, get(h3_sent_status))
                after
                    unload_mocks([pertisk_eproxy_h3_local_admin])
                end
            end)
        end)
    after
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

sse_upstream_error_502_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    N = <<"h3sseerr">>,
    Up = #{addr => <<"backend.local:8080">>, weight => 1},
    Site = #{
        host => <<"sse-err.test">>,
        backend => N,
        routes => [#{path => <<"/events">>, path_type => prefix}]
    },
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(N, [Up]),
    true = erlang:unlink(Pid),
    pertisk_eproxy_test_helpers:sync_router([Site], [#{name => N, algorithm => round_robin, upstreams => [Up]}]),
    try
        with_quic_h3_mock(fun() ->
            capture_h3_status(fun() ->
                with_sse_gun_mock([{error, {down, normal}}], fun() ->
                    H = auth(<<"sse-err.test">>) ++ [{<<"accept">>, <<"text/event-stream">>}],
                    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/events">>, H)),
                    ?assertEqual(502, get(h3_sent_status))
                end)
            end)
        end)
    after
        pertisk_eproxy_test_helpers:stop_backend(N),
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

duplicate_header_merge_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    pertisk_eproxy_test_helpers:sync_router([], []),
    Headers =
        auth(<<"example.com">>) ++
        [
            {<<"x-custom">>, <<"a">>},
            {<<"x-custom">>, <<"b">>}
        ],
    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/missing">>, Headers)).

grpc_is_grpc_h3_request_false_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    pertisk_eproxy_test_helpers:sync_router([], []),
    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/missing">>, auth(<<"example.com">>))).

gateway_start_with_h3_qpack_static_warning_test() ->
    with_gateway_start_mock(fun() ->
        Config = (gateway_tls_config())#{h3_qpack_static => true},
        ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(Config))
    end).

gateway_start_with_sni_site_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
    Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
    Db = pertisk_eproxy_test_helpers:tmp_db(),
    _ = file:delete(Db),
    CertName = iolist_to_binary(["sni-test-", integer_to_list(erlang:unique_integer([monotonic, positive]))]),
    OldDb = application:get_env(pertisk_eproxy, db_file),
    pertisk_eproxy_test_helpers:with_db_lock(fun() ->
        application:set_env(pertisk_eproxy, db_file, Db),
        {ok, CertId} = pertisk_eproxy_db:insert_certificate_pem(Db, CertName, Cert, Key),
        Config = (gateway_tls_config())#{
            sites => [#{host => <<"sni.example.com">>, certificate => integer_to_binary(CertId)}]
        },
        with_gateway_start_mock(fun() ->
            ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(Config))
        end),
        case OldDb of
            {ok, V} -> application:set_env(pertisk_eproxy, db_file, V);
            undefined -> application:unset_env(pertisk_eproxy, db_file)
        end
    end).

gateway_start_https_port_only_test() ->
    Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
    Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
    Config = #{
        https_port => 18443,
        tls_cert_file => Cert,
        tls_key_file => Key,
        sites => []
    },
    with_gateway_start_mock(fun() ->
        ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(Config))
    end).

gateway_start_v6_only_fallback_test() ->
    with_gateway_start_mock(fun() ->
        unload_mocks([quic_h3]),
        meck:new(quic_h3, [unstick, no_link]),
        meck:expect(quic_h3, start_server, fun(Name, _, _) ->
            case Name of
                pertisk_eproxy_h3_api_v4 -> {error, eaddrinuse};
                _ -> {ok, self()}
            end
        end),
        meck:expect(quic_h3, stop_server, fun(_) -> ok end),
        ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(gateway_tls_config()))
    end).

gateway_start_split_bind_fallback_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    unload_mocks([quic_h3]),
    meck:new(quic_h3, [unstick, no_link]),
    Ref = make_ref(), put({quic_start_count, Ref}, 0),
    meck:expect(quic_h3, start_server, fun(_, _, _) ->
        N = get({quic_start_count, Ref}) + 1,
        put({quic_start_count, Ref}, N),
        case N of
            1 -> {error, eaddrinuse};
            2 -> {error, eaddrinuse};
            _ -> {ok, self()}
        end
    end),
    meck:expect(quic_h3, stop_server, fun(_) -> ok end),
    try
        ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(gateway_tls_config()))
    after
        erase({quic_start_count, Ref}),
        pertisk_eproxy_test_helpers:ignoring_errors(fun() -> pertisk_eproxy_h3_api_gateway:stop() end),
        unload_mocks([quic_h3])
    end.

gateway_start_incompatible_qpack_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_deps(),
    unload_mocks([quic_qpack]),
    meck:new(quic_qpack, [unstick, no_link]),
    meck:expect(quic_qpack, encode, fun(_) -> <<1, 2, 3>> end),
    try
        ?assertEqual({error, incompatible_quic_qpack},
            pertisk_eproxy_h3_api_gateway:start(gateway_tls_config()))
    after
        unload_mocks([quic_qpack])
    end.

gateway_start_probe_missing_cert_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_deps(),
    Config = (gateway_tls_config())#{
        tls_cert_file => "/nonexistent/cert.pem",
        tls_key_file => "/nonexistent/key.pem"
    },
    ?assertMatch({error, {missing_tls_file, cert, _}},
        pertisk_eproxy_h3_api_gateway:start_probe(Config)).

websockify_skips_x_forwarded_for_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        with_gun_h3_proxy_mock(fun() ->
            with_proxied_site(fun(#{host := H}) ->
                ?assertEqual(
                    ok,
                    h3(self(), 1, <<"GET">>, <<"/websockify">>, auth(H) ++ [{<<"x">>, <<"1">>}])
                )
            end)
        end)
    end).

post_with_streamed_body_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        meck:expect(quic_h3, set_stream_handler, fun(_, _, _) ->
            {ok, [{<<"{\"a\":1">>, false}, {<<"}">>, true}]}
        end),
        with_gun_h3_proxy_mock(fun() ->
            with_proxied_site(fun(#{host := H}) ->
                Hdr = auth(H) ++ [
                    {<<"content-type">>, <<"application/json">>},
                    {<<"content-length">>, <<"8">>}
                ],
                ?assertEqual(ok, h3(self(), 1, <<"POST">>, <<"/api/data">>, Hdr))
            end)
        end)
    end).

sse_upstream_heartbeat_timeout_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    N = <<"h3ssehb">>, Up = #{addr => <<"backend.local:8080">>, weight => 1},
    Site = #{host => <<"sse-hb.test">>, backend => N, routes => [#{path => <<"/">>, path_type => prefix}]},
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(N, [Up]), true = erlang:unlink(Pid),
    pertisk_eproxy_test_helpers:sync_router([Site], [#{name => N, algorithm => round_robin, upstreams => [Up]}]),
    try
        with_quic_h3_mock(fun() ->
            unload_mocks([gun]),
            meck:new(gun, [unstick, no_link]),
            Ref = make_ref(),
            put({gun_await_queue, Ref}, [{response, nofin, 200, []}, {error, timeout}, {data, fin, <<"evt">>}]),
            meck:expect(gun, open, fun(_, _, _) -> {ok, ?GUN_MOCK_PID} end),
            meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
            meck:expect(gun, request, fun(_, _, _, _, _) -> ?GUN_MOCK_STREAM end),
            meck:expect(gun, await, fun(_, _, _) -> gun_dequeue_await(Ref) end),
            meck:expect(gun, close, fun(_) -> ok end),
            try
                H = auth(<<"sse-hb.test">>) ++ [{<<"accept">>, <<"text/event-stream">>}],
                ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/stream">>, H))
            after
                erase({gun_await_queue, Ref}), unload_mocks([gun])
            end
        end)
    after
        pertisk_eproxy_test_helpers:stop_backend(N),
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

sse_upstream_trailers_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    N = <<"h3ssetr">>, Up = #{addr => <<"backend.local:8080">>, weight => 1},
    Site = #{host => <<"sse-tr.test">>, backend => N, routes => [#{path => <<"/">>, path_type => prefix}]},
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(N, [Up]), true = erlang:unlink(Pid),
    pertisk_eproxy_test_helpers:sync_router([Site], [#{name => N, algorithm => round_robin, upstreams => [Up]}]),
    try
        with_quic_h3_mock(fun() ->
            with_sse_gun_mock([{response, nofin, 200, []}, {trailers, #{}}], fun() ->
                H = auth(<<"sse-tr.test">>) ++ [{<<"accept">>, <<"text/event-stream">>}],
                ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/events">>, H))
            end)
        end)
    after
        pertisk_eproxy_test_helpers:stop_backend(N),
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

sse_upstream_send_error_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    N = <<"h3sseerr2">>, Up = #{addr => <<"backend.local:8080">>, weight => 1},
    Site = #{host => <<"sse-send.test">>, backend => N, routes => [#{path => <<"/">>, path_type => prefix}]},
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(N, [Up]), true = erlang:unlink(Pid),
    pertisk_eproxy_test_helpers:sync_router([Site], [#{name => N, algorithm => round_robin, upstreams => [Up]}]),
    try
        with_quic_h3_mock(fun() ->
            meck:expect(quic_h3, send_data, fun(_, _, _, _) -> {error, closed} end),
            with_sse_gun_mock([{response, nofin, 200, []}, {data, nofin, <<"chunk">>}], fun() ->
                H = auth(<<"sse-send.test">>) ++ [{<<"accept">>, <<"text/event-stream">>}],
                ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/stream">>, H))
            end)
        end)
    after
        pertisk_eproxy_test_helpers:stop_backend(N),
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

proxied_upstream_error_no_fallback_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        capture_h3_status(fun() ->
            with_gun_h3_proxy_mock(#{awaits => [{error, {down, normal}}]}, fun() ->
                with_proxied_site(fun(#{host := H}) ->
                    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/fail">>, auth(H))),
                    ?assertEqual(502, get(h3_sent_status))
                end)
            end)
        end)
    end).

h3_reply_status_send_error_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    pertisk_eproxy_test_helpers:sync_router([], []),
    unload_mocks([quic_h3]),
    meck:new(quic_h3, [unstick, no_link]),
    meck:expect(quic_h3, send_response, fun(_, _, _, _) -> {error, {invalid_state, draining}} end),
    meck:expect(quic_h3, send_data, fun(_, _, _, _) -> ok end),
    try
        ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/missing">>, auth(<<"unknown.test">>)))
    after
        unload_mocks([quic_h3])
    end.

grpc_h3_has_grpc_metadata_false_branch_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Headers = auth(<<"example.com">>) ++ [{<<"other-header">>, <<"1">>}],
    ?assertEqual(ok, h3(self(), 1, <<"POST">>, <<"/">>, Headers)).

gateway_start_full_quic_opts_test() ->
    Config = (gateway_tls_config())#{
        h3_idle_timeout_secs => 0,
        h3_keepalive_interval_secs => 0,
        h3_quic_pool_size => 0,
        h3_max_streams => 100,
        h3_stream_receive_window => 65536,
        h3_conn_receive_window => 65536,
        h3_pmtu_enabled => false
    },
    with_gateway_start_mock(fun() ->
        ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(Config))
    end).

gateway_start_with_ingress_tls_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
    Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
    unload_mocks([pertisk_ingress_env, pertisk_ingress_tls, quic_h3]),
    meck:new(pertisk_ingress_env, [unstick, no_link]),
    meck:new(pertisk_ingress_tls, [unstick, no_link]),
    meck:new(quic_h3, [unstick, no_link]),
    meck:expect(pertisk_ingress_env, enabled, fun() -> true end),
    meck:expect(pertisk_ingress_tls, paths_for_host, fun(_) -> {ok, {Cert, Key}} end),
    meck:expect(quic_h3, start_server, fun(_, _, _) -> {ok, self()} end),
    meck:expect(quic_h3, stop_server, fun(_) -> ok end),
    try
        Config = #{sites => [#{host => <<"ingress.example.com">>}], https_port => 18443},
        ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(Config))
    after
        pertisk_eproxy_test_helpers:ignoring_errors(fun() -> pertisk_eproxy_h3_api_gateway:stop() end),
        unload_mocks([pertisk_ingress_env, pertisk_ingress_tls, quic_h3])
    end.

gateway_start_v4_only_success_test() ->
    with_gateway_start_mock(fun() ->
        unload_mocks([quic_h3]),
        meck:new(quic_h3, [unstick, no_link]),
        meck:expect(quic_h3, start_server, fun(Name, _, _) ->
            case Name of
                pertisk_eproxy_h3_api_v4 -> {error, eaddrinuse};
                _ -> {ok, self()}
            end
        end),
        meck:expect(quic_h3, stop_server, fun(_) -> ok end),
        ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(gateway_tls_config()))
    end).

proxied_put_success_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        capture_h3_status(fun() ->
            with_gun_h3_proxy_mock(#{awaits => [{response, fin, 200, []}]}, fun() ->
                with_proxied_site(fun(#{host := H}) ->
                    Hdr = auth(H) ++ [{<<"content-length">>, <<"0">>}],
                    ?assertEqual(ok, h3(self(), 1, <<"PUT">>, <<"/api/item">>, Hdr)),
                    ?assertEqual(200, get(h3_sent_status))
                end)
            end)
        end)
    end).

novnc_console_path_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        with_gun_h3_proxy_mock(fun() ->
            with_proxied_site(fun(#{host := H}) ->
                ?assertEqual(
                    ok,
                    h3(self(), 1, <<"GET">>, <<"/novnc">>, auth(H) ++ [{<<"x">>, <<"1">>}])
                )
            end)
        end)
    end).

sse_upstream_multiple_chunks_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    N = <<"h3ssemulti">>, Up = #{addr => <<"backend.local:8080">>, weight => 1},
    Site = #{host => <<"sse-multi.test">>, backend => N, routes => [#{path => <<"/">>, path_type => prefix}]},
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(N, [Up]), true = erlang:unlink(Pid),
    pertisk_eproxy_test_helpers:sync_router([Site], [#{name => N, algorithm => round_robin, upstreams => [Up]}]),
    try
        with_quic_h3_mock(fun() ->
            with_sse_gun_mock(
                [{response, nofin, 200, []}, {data, nofin, <<"a">>}, {data, nofin, <<"b">>}, {data, fin, <<"c">>}],
                fun() ->
                    H = auth(<<"sse-multi.test">>) ++ [{<<"accept">>, <<"text/event-stream">>}],
                    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/feed">>, H))
                end
            )
        end)
    after
        pertisk_eproxy_test_helpers:stop_backend(N),
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

benchmark_post_skips_fast_path_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    ?assertEqual(ok, h3(self(), 1, <<"POST">>, <<"/api/ingress/live">>, auth(<<"localhost">>))).

proxied_with_existing_xff_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        with_gun_h3_proxy_mock(fun() ->
            with_proxied_site(fun(#{host := H}) ->
                Hdr = auth(H) ++ [{<<"x-forwarded-for">>, <<"203.0.113.1">>}],
                ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, Hdr))
            end)
        end)
    end).

advertise_http3_disabled_clears_alt_svc_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Site = #{
        host => <<"no-h3.test">>,
        backend => <<"web">>,
        advertise_http3 => false,
        routes => [#{path => <<"/">>, path_type => prefix}]
    },
    Backend = #{
        name => <<"web">>,
        algorithm => round_robin,
        upstreams => [#{addr => <<"backend.local:8080">>, weight => 1}]
    },
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(<<"web">>, [
        #{addr => <<"backend.local:8080">>, weight => 1}
    ]),
    true = erlang:unlink(Pid),
    pertisk_eproxy_test_helpers:sync_router([Site], [Backend]),
    try
        with_quic_h3_mock(fun() ->
            meck:expect(quic_h3, send_response, fun(_, _, _, Hdrs) -> put(h3_resp_hdrs, Hdrs), ok end),
            with_gun_h3_proxy_mock(fun() ->
                ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, auth(<<"no-h3.test">>))),
                ?assertEqual({<<"alt-svc">>, <<"clear">>}, lists:keyfind(<<"alt-svc">>, 1, get(h3_resp_hdrs)))
            end)
        end)
    after
        pertisk_eproxy_test_helpers:stop_backend(<<"web">>),
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

admin_api_local_fallback_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Host = <<"admin.example.com">>,
    Site = #{
        host => Host,
        backend => <<"web">>,
        routes => [#{path => <<"/api">>, path_type => prefix}]
    },
    Backend = #{
        name => <<"web">>,
        algorithm => round_robin,
        upstreams => [#{addr => <<"backend.local:8080">>, weight => 1}]
    },
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(<<"web">>, [
        #{addr => <<"backend.local:8080">>, weight => 1}
    ]),
    true = erlang:unlink(Pid),
    pertisk_eproxy_test_helpers:sync_router([Site], [Backend]),
    try
        with_quic_h3_mock(fun() ->
            capture_h3_status(fun() ->
                with_gun_h3_proxy_mock(#{awaits => [{error, timeout}]}, fun() ->
                    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/api/version">>, auth(Host))),
                    ?assertEqual(200, get(h3_sent_status))
                end)
            end)
        end)
    after
        pertisk_eproxy_test_helpers:stop_backend(<<"web">>),
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

sse_idle_fin_body_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    N = <<"h3sseidlefin">>, Up = #{addr => <<"backend.local:8080">>, weight => 1},
    Site = #{host => <<"sse-idle.test">>, backend => N, routes => [#{path => <<"/">>, path_type => prefix}]},
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(N, [Up]), true = erlang:unlink(Pid),
    pertisk_eproxy_test_helpers:sync_router([Site], [#{name => N, algorithm => round_robin, upstreams => [Up]}]),
    try
        with_quic_h3_mock(fun() ->
            unload_mocks([gun]),
            meck:new(gun, [unstick, no_link]),
            Ref = make_ref(),
            put({gun_await_queue, Ref}, [{error, timeout}, {response, fin, 200, []}]),
            meck:expect(gun, open, fun(_, _, _) -> {ok, ?GUN_MOCK_PID} end),
            meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
            meck:expect(gun, request, fun(_, _, _, _, _) -> ?GUN_MOCK_STREAM end),
            meck:expect(gun, await, fun(_, _, _) -> gun_dequeue_await(Ref) end),
            meck:expect(gun, await_body, fun(_, _, _) -> {ok, <<"payload">>} end),
            meck:expect(gun, close, fun(_) -> ok end),
            try
                H = auth(<<"sse-idle.test">>) ++ [{<<"accept">>, <<"text/event-stream">>}],
                ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/events">>, H))
            after
                erase({gun_await_queue, Ref}), unload_mocks([gun])
            end
        end)
    after
        pertisk_eproxy_test_helpers:stop_backend(N),
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

gateway_start_missing_key_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_deps(),
    Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
    Config = (gateway_tls_config())#{
        tls_cert_file => Cert,
        tls_key_file => "/nonexistent/listener.key"
    },
    ?assertMatch({error, {missing_tls_file, key, _}}, pertisk_eproxy_h3_api_gateway:start(Config)).

gateway_start_no_tls_files_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_deps(),
    Config = #{
        https_port => 18443,
        sites => [],
        tls_cert_file => "/nonexistent/h3-cert.pem",
        tls_key_file => "/nonexistent/h3-key.pem"
    },
    ?assertMatch({error, {missing_tls_file, cert, _}},
        pertisk_eproxy_h3_api_gateway:start(Config)).

gateway_start_invalid_cert_pem_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_deps(),
    Tmp = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "h3-bad-cert-" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = file:make_dir(Tmp),
    BadCert = filename:join([Tmp, "bad.pem"]),
    Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
    ok = file:write_file(BadCert, <<"not-pem">>),
    try
        Config = (gateway_tls_config())#{tls_cert_file => BadCert, tls_key_file => Key},
        ?assertMatch({error, {invalid_listener_pem, _, _}}, pertisk_eproxy_h3_api_gateway:start(Config))
    after
        ok = file:delete(BadCert),
        ok = file:del_dir(Tmp)
    end.

gateway_start_ingress_default_tls_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
    Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
    unload_mocks([pertisk_ingress_env, pertisk_ingress_tls, quic_h3]),
    meck:new(pertisk_ingress_env, [unstick, no_link]),
    meck:new(pertisk_ingress_tls, [unstick, no_link]),
    meck:new(quic_h3, [unstick, no_link]),
    meck:expect(pertisk_ingress_env, enabled, fun() -> true end),
    meck:expect(pertisk_ingress_tls, paths_for_host, fun(_) -> {ok, {Cert, Key}} end),
    meck:expect(quic_h3, start_server, fun(_, _, _) -> {ok, self()} end),
    meck:expect(quic_h3, stop_server, fun(_) -> ok end),
    try
        IngressHost = <<"ingress-default.test">>,
        Config = #{sites => [#{host => IngressHost}], https_port => 18443},
        ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(Config))
    after
        pertisk_eproxy_test_helpers:ignoring_errors(fun() -> pertisk_eproxy_h3_api_gateway:stop() end),
        unload_mocks([pertisk_ingress_env, pertisk_ingress_tls, quic_h3])
    end.

gateway_start_ingress_sni_site_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
    Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
    unload_mocks([pertisk_ingress_env, pertisk_ingress_tls, quic_h3]),
    meck:new(pertisk_ingress_env, [unstick, no_link]),
    meck:new(pertisk_ingress_tls, [unstick, no_link]),
    meck:new(quic_h3, [unstick, no_link]),
    meck:expect(pertisk_ingress_env, enabled, fun() -> true end),
    meck:expect(pertisk_ingress_tls, paths_for_host, fun(<<"ingress-sni.test">>) -> {ok, {Cert, Key}}; (_) -> error end),
    meck:expect(quic_h3, start_server, fun(_, _, _) -> {ok, self()} end),
    meck:expect(quic_h3, stop_server, fun(_) -> ok end),
    try
        SniHost = <<"ingress-sni.test">>,
        Config = (gateway_tls_config())#{sites => [#{host => SniHost}]},
        ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(Config))
    after
        pertisk_eproxy_test_helpers:ignoring_errors(fun() -> pertisk_eproxy_h3_api_gateway:stop() end),
        unload_mocks([pertisk_ingress_env, pertisk_ingress_tls, quic_h3])
    end.

gateway_start_acme_sni_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
    Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
    AcmeDir = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "h3-acme-" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    CertDir = filename:join([AcmeDir, "certs", "slug1"]),
    ok = filelib:ensure_dir(filename:join([CertDir, "x"])),
    {ok, _} = file:copy(Cert, filename:join([CertDir, "fullchain.pem"])),
    {ok, _} = file:copy(Key, filename:join([CertDir, "privkey.pem"])),
    OldAcme = application:get_env(pertisk_eproxy, acme_data_dir),
    application:set_env(pertisk_eproxy, acme_data_dir, AcmeDir),
    try
        Config = (gateway_tls_config())#{
            sites => [#{host => <<"acme-sni.test">>, certificate => <<"acme/slug1">>}]
        },
        with_gateway_start_mock(fun() ->
            ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(Config))
        end)
    after
        case OldAcme of
            {ok, V} -> application:set_env(pertisk_eproxy, acme_data_dir, V);
            undefined -> application:unset_env(pertisk_eproxy, acme_data_dir)
        end,
        _ = os:cmd("rm -rf " ++ AcmeDir)
    end.

gateway_start_sni_by_cert_name_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
    Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
    Db = pertisk_eproxy_test_helpers:tmp_db(),
    _ = file:delete(Db),
    OldDb = application:get_env(pertisk_eproxy, db_file),
    pertisk_eproxy_test_helpers:with_db_lock(fun() ->
        application:set_env(pertisk_eproxy, db_file, Db),
        CertName = iolist_to_binary(["named-sni-", integer_to_list(erlang:unique_integer([monotonic, positive]))]),
        {ok, _} = pertisk_eproxy_db:insert_certificate_pem(Db, CertName, Cert, Key),
        Config = (gateway_tls_config())#{
            sites => [#{host => <<"named-sni.test">>, certificate => CertName}]
        },
        with_gateway_start_mock(fun() ->
            ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(Config))
        end),
        case OldDb of
            {ok, V} -> application:set_env(pertisk_eproxy, db_file, V);
            undefined -> application:unset_env(pertisk_eproxy, db_file)
        end
    end).

gateway_start_unix_v4_only_test() ->
    with_gateway_start_mock(fun() ->
        unload_mocks([quic_h3]),
        meck:new(quic_h3, [unstick, no_link]),
        meck:expect(quic_h3, start_server, fun(Name, _, _) ->
            case Name of
                pertisk_eproxy_h3_api_v4 -> {ok, self()};
                pertisk_eproxy_h3_api -> {error, eaddrinuse};
                _ -> {ok, self()}
            end
        end),
        meck:expect(quic_h3, stop_server, fun(_) -> ok end),
        ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(gateway_tls_config()))
    end).

post_body_collect_via_messages_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Conn = self(),
    Part1 = <<"{\"x">>,
    Part2 = <<":1}">>,
    with_quic_h3_mock(fun() ->
        meck:expect(quic_h3, set_stream_handler, fun(C, Sid, _) ->
            Parent = self(),
            spawn(fun() ->
                timer:sleep(5),
                Parent ! {quic_h3, C, {data, Sid, Part1, false}},
                Parent ! {quic_h3, C, {data, Sid, Part2, true}}
            end),
            ok
        end),
        with_gun_h3_proxy_mock(fun() ->
            with_proxied_site(fun(#{host := H}) ->
                Hdr = auth(H) ++ [
                    {<<"content-type">>, <<"application/json">>},
                    {<<"content-length">>, <<"8">>}
                ],
                ?assertEqual(ok, h3(Conn, 1, <<"POST">>, <<"/api/data">>, Hdr))
            end)
        end)
    end).

post_body_set_stream_handler_error_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        meck:expect(quic_h3, set_stream_handler, fun(_, _, _) -> {error, bad} end),
        with_gun_h3_proxy_mock(fun() ->
            with_proxied_site(fun(#{host := H}) ->
                Hdr = auth(H) ++ [{<<"content-length">>, <<"4">>}],
                ?assertEqual(ok, h3(self(), 1, <<"POST">>, <<"/api/data">>, Hdr))
            end)
        end)
    end).

proxied_nofin_await_body_error_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        capture_h3_status(fun() ->
            with_gun_h3_proxy_mock(
                #{awaits => [{response, nofin, 200, []}], await_body => {error, timeout}},
                fun() ->
                    with_proxied_site(fun(#{host := H}) ->
                        ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/stream">>, auth(H))),
                        ?assertEqual(502, get(h3_sent_status))
                    end)
                end
            )
        end)
    end).

proxied_gun_open_failure_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        capture_h3_status(fun() ->
            unload_mocks([gun, pertisk_eproxy_upstream_pool]),
            meck:new(gun, [unstick, no_link]),
            meck:new(pertisk_eproxy_upstream_pool, [unstick, no_link]),
            meck:expect(pertisk_eproxy_upstream_pool, checkout, fun(_, _, _, _, _) ->
                {error, no_pool}
            end),
            meck:expect(gun, open, fun(_, _, _) -> {error, econnrefused} end),
            try
                with_proxied_site(fun(#{host := H}) ->
                    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, auth(H))),
                    ?assertEqual(502, get(h3_sent_status))
                end)
            after
                unload_mocks([gun, pertisk_eproxy_upstream_pool])
            end
        end)
    end).

proxied_gun_await_up_failure_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        capture_h3_status(fun() ->
            unload_mocks([gun, pertisk_eproxy_upstream_pool]),
            meck:new(gun, [unstick, no_link]),
            meck:new(pertisk_eproxy_upstream_pool, [unstick, no_link]),
            meck:expect(pertisk_eproxy_upstream_pool, checkout, fun(_, _, _, _, _) ->
                {error, no_pool}
            end),
            meck:expect(gun, open, fun(_, _, _) -> {ok, ?GUN_MOCK_PID} end),
            meck:expect(gun, await_up, fun(_, _) -> {error, timeout} end),
            meck:expect(gun, close, fun(_) -> ok end),
            try
                with_proxied_site(fun(#{host := H}) ->
                    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, auth(H))),
                    ?assertEqual(502, get(h3_sent_status))
                end)
            after
                unload_mocks([gun, pertisk_eproxy_upstream_pool])
            end
        end)
    end).

sse_upstream_response_send_error_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    N = <<"h3ssersp">>, Up = #{addr => <<"backend.local:8080">>, weight => 1},
    Site = #{host => <<"sse-rsp.test">>, backend => N, routes => [#{path => <<"/">>, path_type => prefix}]},
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(N, [Up]), true = erlang:unlink(Pid),
    pertisk_eproxy_test_helpers:sync_router([Site], [#{name => N, algorithm => round_robin, upstreams => [Up]}]),
    try
        with_quic_h3_mock(fun() ->
            meck:expect(quic_h3, send_response, fun(_, _, _, _) -> {error, closed} end),
            with_sse_gun_mock([{response, nofin, 200, []}], fun() ->
                H = auth(<<"sse-rsp.test">>) ++ [{<<"accept">>, <<"text/event-stream">>}],
                ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/events">>, H))
            end)
        end)
    after
        pertisk_eproxy_test_helpers:stop_backend(N),
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

sse_idle_heartbeat_connection_gone_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    N = <<"h3sseidlegone">>, Up = #{addr => <<"backend.local:8080">>, weight => 1},
    Site = #{host => <<"sse-idle-gone.test">>, backend => N, routes => [#{path => <<"/api/v1/stream">>, path_type => prefix}]},
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(N, [Up]), true = erlang:unlink(Pid),
    pertisk_eproxy_test_helpers:sync_router([Site], [#{name => N, algorithm => round_robin, upstreams => [Up]}]),
    Headers =
        auth(<<"sse-idle-gone.test">>) ++
        [
            {<<"accept">>, <<"text/event-stream">>},
            {<<"authorization">>, <<"Bearer tok">>}
        ],
    try
        with_quic_h3_mock(fun() ->
            Calls = counters:new(1, []),
            meck:expect(quic_h3, send_data, fun(_, _, Data, _) ->
                case counters:get(Calls, 1) of
                    0 ->
                        counters:add(Calls, 1, 1),
                        ok;
                    _ ->
                        case Data of
                            <<":\n\n">> -> {error, connection_gone};
                            _ -> ok
                        end
                end
            end),
            with_sse_gun_mock([{error, timeout}, {error, timeout}], fun() ->
                ?assertEqual(
                    ok,
                    h3(self(), 1, <<"GET">>, <<"/api/v1/stream/events">>, Headers)
                )
            end)
        end)
    after
        pertisk_eproxy_test_helpers:stop_backend(N),
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

sse_upstream_unexpected_await_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    N = <<"h3sseunk">>, Up = #{addr => <<"backend.local:8080">>, weight => 1},
    Site = #{host => <<"sse-unk.test">>, backend => N, routes => [#{path => <<"/">>, path_type => prefix}]},
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(N, [Up]), true = erlang:unlink(Pid),
    pertisk_eproxy_test_helpers:sync_router([Site], [#{name => N, algorithm => round_robin, upstreams => [Up]}]),
    try
        with_quic_h3_mock(fun() ->
            with_sse_gun_mock([{response, nofin, 200, []}, {wtf, unexpected}], fun() ->
                H = auth(<<"sse-unk.test">>) ++ [{<<"accept">>, <<"text/event-stream">>}],
                ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/events">>, H))
            end)
        end)
    after
        pertisk_eproxy_test_helpers:stop_backend(N),
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

gateway_start_ingress_tls_decode_entry_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
    Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
    {ok, CertBin} = file:read_file(Cert),
    {ok, KeyBin} = file:read_file(Key),
    unload_mocks([pertisk_ingress_env, pertisk_ingress_tls, quic_h3]),
    meck:new(pertisk_ingress_env, [unstick, no_link]),
    meck:new(pertisk_ingress_tls, [unstick, no_link, passthrough]),
    meck:new(quic_h3, [unstick, no_link]),
    meck:expect(pertisk_ingress_env, enabled, fun() -> true end),
    meck:expect(pertisk_ingress_tls, paths_for_host, fun(_) -> error end),
    Entry = #{cert_pem => CertBin, key_pem => KeyBin},
    meck:expect(pertisk_ingress_tls, lookup, fun(_) -> {ok, Entry} end),
    meck:expect(quic_h3, start_server, fun(_, _, _) -> {ok, self()} end),
    meck:expect(quic_h3, stop_server, fun(_) -> ok end),
    try
        Config = #{
            sites => [#{host => list_to_binary("ingress-decode.test")}],
            https_port => 18443
        },
        ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(Config))
    after
        pertisk_eproxy_test_helpers:ignoring_errors(fun() -> pertisk_eproxy_h3_api_gateway:stop() end),
        unload_mocks([pertisk_ingress_env, pertisk_ingress_tls, quic_h3])
    end.

gateway_start_ingress_sni_lookup_only_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
    Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
    {ok, CertBin} = file:read_file(Cert),
    {ok, KeyBin} = file:read_file(Key),
    Entry = #{cert_pem => CertBin, key_pem => KeyBin},
    LookupHost = <<"ing-lookup.test">>,
    unload_mocks([pertisk_ingress_env, pertisk_ingress_tls, quic_h3]),
    meck:new(pertisk_ingress_env, [unstick, no_link]),
    meck:new(pertisk_ingress_tls, [unstick, no_link, passthrough]),
    meck:new(quic_h3, [unstick, no_link]),
    meck:expect(pertisk_ingress_env, enabled, fun() -> true end),
    meck:expect(pertisk_ingress_tls, paths_for_host, fun(_) -> error end),
    meck:expect(pertisk_ingress_tls, lookup, fun(H) when H =:= LookupHost -> {ok, Entry}; (_) -> error end),
    meck:expect(quic_h3, start_server, fun(_, _, _) -> {ok, self()} end),
    meck:expect(quic_h3, stop_server, fun(_) -> ok end),
    try
        Config = (gateway_tls_config())#{sites => [#{host => LookupHost}]},
        ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(Config))
    after
        pertisk_eproxy_test_helpers:ignoring_errors(fun() -> pertisk_eproxy_h3_api_gateway:stop() end),
        unload_mocks([pertisk_ingress_env, pertisk_ingress_tls, quic_h3])
    end.

gateway_start_low_idle_timeout_test() ->
    Config = (gateway_tls_config())#{h3_idle_timeout_secs => 30},
    with_gateway_start_mock(fun() ->
        ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(Config))
    end).

gateway_start_invalid_quic_tuning_test() ->
    Config = (gateway_tls_config())#{
        h3_max_udp_payload_size => 100,
        h3_max_streams => -1,
        h3_quic_pool_size => -5
    },
    with_gateway_start_mock(fun() ->
        ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(Config))
    end).

proxied_nofin_body_trailers_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        with_gun_h3_proxy_mock(
            #{awaits => [{response, nofin, 200, []}], await_body => {ok, <<"body">>, #{}}},
            fun() ->
                with_proxied_site(fun(#{host := H}) ->
                    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/t">>, auth(H)))
                end)
            end
        )
    end).

proxied_retry_checkout_fails_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        capture_h3_status(fun() ->
            unload_mocks([gun, pertisk_eproxy_upstream_pool]),
            meck:new(gun, [unstick, no_link]),
            meck:new(pertisk_eproxy_upstream_pool, [unstick, no_link]),
            CRef = make_ref(),
            put({checkout_n, CRef}, 0),
            meck:expect(pertisk_eproxy_upstream_pool, checkout, fun(_, _, _, _, _) ->
                N = get({checkout_n, CRef}) + 1,
                put({checkout_n, CRef}, N),
                case N of
                    1 -> {ok, ?GUN_MOCK_PID};
                    _ -> {error, pool_exhausted}
                end
            end),
            meck:expect(pertisk_eproxy_upstream_pool, invalidate, fun(_) -> ok end),
            meck:expect(gun, open, fun(_, _, _) -> {ok, ?GUN_MOCK_PID} end),
            meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
            meck:expect(gun, request, fun(_, _, _, _, _) -> ?GUN_MOCK_STREAM end),
            meck:expect(gun, await, fun(_, _, _) -> {error, {down, normal}} end),
            meck:expect(gun, close, fun(_) -> ok end),
            try
                with_proxied_site(fun(#{host := H}) ->
                    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, auth(H))),
                    ?assertEqual(502, get(h3_sent_status))
                end)
            after
                erase({checkout_n, CRef}),
                unload_mocks([gun, pertisk_eproxy_upstream_pool])
            end
        end)
    end).

post_zero_content_length_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        meck:expect(quic_h3, set_stream_handler, fun(_, _, _) -> ok end),
        with_gun_h3_proxy_mock(fun() ->
            with_proxied_site(fun(#{host := H}) ->
                Hdr = auth(H) ++ [{<<"content-length">>, <<"0">>}],
                ?assertEqual(ok, h3(self(), 1, <<"POST">>, <<"/api/data">>, Hdr))
            end)
        end)
    end).

post_invalid_content_length_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        meck:expect(quic_h3, set_stream_handler, fun(_, _, _) -> ok end),
        with_gun_h3_proxy_mock(fun() ->
            with_proxied_site(fun(#{host := H}) ->
                ClHdr = list_to_binary("  not-a-number  "),
                Hdr = auth(H) ++ [{<<"content-length">>, ClHdr}],
                ?assertEqual(ok, h3(self(), 1, <<"POST">>, <<"/api/data">>, Hdr))
            end)
        end)
    end).

sse_upstream_loop_heartbeat_ok_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    N = <<"h3ssehbok">>, Up = #{addr => <<"backend.local:8080">>, weight => 1},
    Site = #{host => <<"sse-hb-ok.test">>, backend => N, routes => [#{path => <<"/">>, path_type => prefix}]},
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(N, [Up]), true = erlang:unlink(Pid),
    pertisk_eproxy_test_helpers:sync_router([Site], [#{name => N, algorithm => round_robin, upstreams => [Up]}]),
    try
        with_quic_h3_mock(fun() ->
            with_sse_gun_mock(
                [{response, nofin, 200, []}, {error, timeout}, {data, fin, <<"done">>}],
                fun() ->
                    H = auth(<<"sse-hb-ok.test">>) ++ [{<<"accept">>, <<"text/event-stream">>}],
                    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/stream">>, H))
                end
            )
        end)
    after
        pertisk_eproxy_test_helpers:stop_backend(N),
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

sse_fin_response_send_error_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    N = <<"h3ssefinerr">>, Up = #{addr => <<"backend.local:8080">>, weight => 1},
    Site = #{host => <<"sse-fin-err.test">>, backend => N, routes => [#{path => <<"/">>, path_type => prefix}]},
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(N, [Up]), true = erlang:unlink(Pid),
    pertisk_eproxy_test_helpers:sync_router([Site], [#{name => N, algorithm => round_robin, upstreams => [Up]}]),
    try
        with_quic_h3_mock(fun() ->
            meck:expect(quic_h3, send_response, fun(_, _, _, _) -> {error, closed} end),
            unload_mocks([gun]),
            meck:new(gun, [unstick, no_link]),
            Ref = make_ref(),
            put({gun_await_queue, Ref}, [{response, fin, 200, []}]),
            meck:expect(gun, open, fun(_, _, _) -> {ok, ?GUN_MOCK_PID} end),
            meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
            meck:expect(gun, request, fun(_, _, _, _, _) -> ?GUN_MOCK_STREAM end),
            meck:expect(gun, await, fun(_, _, _) -> gun_dequeue_await(Ref) end),
            meck:expect(gun, await_body, fun(_, _, _) -> {ok, <<"x">>} end),
            meck:expect(gun, close, fun(_) -> ok end),
            try
                H = auth(<<"sse-fin-err.test">>) ++ [{<<"accept">>, <<"text/event-stream">>}],
                ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/events">>, H))
            after
                erase({gun_await_queue, Ref}), unload_mocks([gun])
            end
        end)
    after
        pertisk_eproxy_test_helpers:stop_backend(N),
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

novnc_console_query_alt_svc_clear_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        meck:expect(quic_h3, send_response, fun(_, _, _, Hdrs) -> put(h3_resp_hdrs, Hdrs), ok end),
        with_gun_h3_proxy_mock(fun() ->
            with_proxied_site(fun(#{host := H}) ->
                ?assertEqual(
                    ok,
                    h3(self(), 1, <<"GET">>, <<"/novnc?console=1">>, auth(H) ++ [{<<"x">>, <<"1">>}])
                ),
                ?assertEqual({<<"alt-svc">>, <<"clear">>}, lists:keyfind(<<"alt-svc">>, 1, get(h3_resp_hdrs)))
            end)
        end)
    end).

gateway_start_whitespace_site_host_sni_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
    Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
    Db = pertisk_eproxy_test_helpers:tmp_db(),
    _ = file:delete(Db),
    OldDb = application:get_env(pertisk_eproxy, db_file),
    pertisk_eproxy_test_helpers:with_db_lock(fun() ->
        application:set_env(pertisk_eproxy, db_file, Db),
        WsName = iolist_to_binary(["ws-sni-", integer_to_list(erlang:unique_integer([monotonic, positive]))]),
        {ok, Id} = pertisk_eproxy_db:insert_certificate_pem(Db, WsName, Cert, Key),
        Config = (gateway_tls_config())#{
            sites => [#{host => <<"  trim-host.test  ">>, certificate => integer_to_binary(Id)}]
        },
        with_gateway_start_mock(fun() ->
            ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(Config))
        end),
        case OldDb of
            {ok, V} -> application:set_env(pertisk_eproxy, db_file, V);
            undefined -> application:unset_env(pertisk_eproxy, db_file)
        end
    end).

with_os_type_mock(OsType, Fun) ->
    case lists:member(os, meck:mocked()) of
        true -> ok;
        false -> meck:new(os, [unstick, no_link, passthrough])
    end,
    meck:expect(os, type, fun() -> OsType end),
    try
        Fun()
    after
        %% Restore real os:type/0; keep passthrough mock (unload crashes code_server).
        pertisk_eproxy_test_helpers:ignoring_errors(fun() -> meck:delete(os, type, 0) end)
    end.

with_linux_os_mock(Fun) ->
    with_os_type_mock({unix, linux}, Fun).

gateway_start_linux_dual_stack_udp_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    OldCfg = pertisk_eproxy_config:get_config(),
    ok = pertisk_eproxy_test_helpers:put_config_retry(OldCfg#{h3_udp_bind => dual_stack}),
    unload_mocks([quic_h3]),
    meck:new(quic_h3, [unstick, no_link]),
    meck:expect(quic_h3, start_server, fun(_, _, _) -> {ok, self()} end),
    meck:expect(quic_h3, stop_server, fun(_) -> ok end),
    try
        with_linux_os_mock(fun() ->
            ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(gateway_tls_config()))
        end)
    after
        pertisk_eproxy_test_helpers:ignoring_errors(fun() -> pertisk_eproxy_h3_api_gateway:stop() end),
        ok = pertisk_eproxy_test_helpers:put_config_retry(OldCfg),
        unload_mocks([quic_h3])
    end.

gateway_start_linux_dual_stack_fallback_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    OldCfg = pertisk_eproxy_config:get_config(),
    ok = pertisk_eproxy_test_helpers:put_config_retry(OldCfg#{h3_udp_bind => dual_stack}),
    unload_mocks([quic_h3]),
    meck:new(quic_h3, [unstick, no_link]),
    Ref = make_ref(),
    put({linux_ds_n, Ref}, 0),
    meck:expect(quic_h3, start_server, fun(_, _, _) ->
        N = get({linux_ds_n, Ref}) + 1,
        put({linux_ds_n, Ref}, N),
        case N of
            1 -> {error, eaddrinuse};
            _ -> {ok, self()}
        end
    end),
    meck:expect(quic_h3, stop_server, fun(_) -> ok end),
    try
        with_linux_os_mock(fun() ->
            ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(gateway_tls_config()))
        end)
    after
        pertisk_eproxy_test_helpers:ignoring_errors(fun() -> pertisk_eproxy_h3_api_gateway:stop() end),
        erase({linux_ds_n, Ref}),
        ok = pertisk_eproxy_test_helpers:put_config_retry(OldCfg),
        unload_mocks([quic_h3])
    end.

gateway_start_linux_split_udp_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    OldCfg = pertisk_eproxy_config:get_config(),
    ok = pertisk_eproxy_test_helpers:put_config_retry(OldCfg#{h3_udp_bind => split}),
    unload_mocks([quic_h3]),
    meck:new(quic_h3, [unstick, no_link]),
    meck:expect(quic_h3, start_server, fun(_, _, _) -> {ok, self()} end),
    meck:expect(quic_h3, stop_server, fun(_) -> ok end),
    try
        with_linux_os_mock(fun() ->
            ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(gateway_tls_config()))
        end)
    after
        pertisk_eproxy_test_helpers:ignoring_errors(fun() -> pertisk_eproxy_h3_api_gateway:stop() end),
        ok = pertisk_eproxy_test_helpers:put_config_retry(OldCfg),
        unload_mocks([quic_h3])
    end.

gateway_start_linux_split_v4_fail_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    OldCfg = pertisk_eproxy_config:get_config(),
    ok = pertisk_eproxy_test_helpers:put_config_retry(OldCfg#{h3_udp_bind => split}),
    unload_mocks([quic_h3]),
    meck:new(quic_h3, [unstick, no_link]),
    meck:expect(quic_h3, start_server, fun(Name, _, _) ->
        case Name of
            pertisk_eproxy_h3_api_v4 -> {error, eaddrinuse};
            _ -> {ok, self()}
        end
    end),
    meck:expect(quic_h3, stop_server, fun(_) -> ok end),
    try
        with_linux_os_mock(fun() ->
            ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(gateway_tls_config()))
        end)
    after
        pertisk_eproxy_test_helpers:ignoring_errors(fun() -> pertisk_eproxy_h3_api_gateway:stop() end),
        ok = pertisk_eproxy_test_helpers:put_config_retry(OldCfg),
        unload_mocks([quic_h3])
    end.

proxied_gun_binary_status_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        capture_h3_status(fun() ->
            with_gun_h3_proxy_mock(#{awaits => [{response, fin, <<"200">>, []}]}, fun() ->
                with_proxied_site(fun(#{host := H}) ->
                    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, auth(H))),
                    ?assertEqual(200, get(h3_sent_status))
                end)
            end)
        end)
    end).

h3_send_response_timeout_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    pertisk_eproxy_test_helpers:sync_router([], []),
    unload_mocks([quic_h3]),
    meck:new(quic_h3, [unstick, no_link]),
    meck:expect(quic_h3, send_response, fun(_, _, _, _) -> {error, timeout} end),
    meck:expect(quic_h3, send_data, fun(_, _, _, _) -> ok end),
    try
        ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/missing">>, auth(<<"unknown.test">>)))
    after
        unload_mocks([quic_h3])
    end.

gateway_start_linux_split_both_fail_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    OldCfg = pertisk_eproxy_config:get_config(),
    ok = pertisk_eproxy_test_helpers:put_config_retry(OldCfg#{h3_udp_bind => split}),
    unload_mocks([quic_h3]),
    meck:new(quic_h3, [unstick, no_link]),
    meck:expect(quic_h3, start_server, fun(_, _, _) -> {error, eaddrinuse} end),
    meck:expect(quic_h3, stop_server, fun(_) -> ok end),
    try
        with_linux_os_mock(fun() ->
            ?assertMatch(
                {error, {failed_quic_udp_listener_v6, _}},
                pertisk_eproxy_h3_api_gateway:start(gateway_tls_config())
            )
        end)
    after
        ok = pertisk_eproxy_test_helpers:put_config_retry(OldCfg),
        unload_mocks([quic_h3])
    end.

gateway_start_linux_split_v4_fail_v6_ok_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    OldCfg = pertisk_eproxy_config:get_config(),
    ok = pertisk_eproxy_test_helpers:put_config_retry(OldCfg#{h3_udp_bind => split}),
    unload_mocks([quic_h3]),
    meck:new(quic_h3, [unstick, no_link]),
    meck:expect(quic_h3, start_server, fun(Name, _, _) ->
        case Name of
            pertisk_eproxy_h3_api_v4 -> {error, eaddrinuse};
            _ -> {ok, self()}
        end
    end),
    meck:expect(quic_h3, stop_server, fun(_) -> ok end),
    try
        with_linux_os_mock(fun() ->
            ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(gateway_tls_config()))
        end)
    after
        pertisk_eproxy_test_helpers:ignoring_errors(fun() -> pertisk_eproxy_h3_api_gateway:stop() end),
        ok = pertisk_eproxy_test_helpers:put_config_retry(OldCfg),
        unload_mocks([quic_h3])
    end.

gateway_start_linux_split_v6_fail_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    OldCfg = pertisk_eproxy_config:get_config(),
    ok = pertisk_eproxy_test_helpers:put_config_retry(OldCfg#{h3_udp_bind => split}),
    unload_mocks([quic_h3]),
    meck:new(quic_h3, [unstick, no_link]),
    meck:expect(quic_h3, start_server, fun(Name, _, _) ->
        case Name of
            pertisk_eproxy_h3_api_v4 -> {ok, self()};
            pertisk_eproxy_h3_api -> {error, eaddrinuse};
            _ -> {ok, self()}
        end
    end),
    meck:expect(quic_h3, stop_server, fun(_) -> ok end),
    try
        with_linux_os_mock(fun() ->
            ?assertMatch(
                {error, {failed_quic_udp_listener_v6, _}},
                pertisk_eproxy_h3_api_gateway:start(gateway_tls_config())
            )
        end)
    after
        ok = pertisk_eproxy_test_helpers:put_config_retry(OldCfg),
        unload_mocks([quic_h3])
    end.

gateway_start_probe_linux_dual_stack_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    OldCfg = pertisk_eproxy_config:get_config(),
    ok = pertisk_eproxy_test_helpers:put_config_retry(OldCfg#{h3_udp_bind => dual_stack}),
    unload_mocks([quic_h3]),
    meck:new(quic_h3, [unstick, no_link]),
    meck:expect(quic_h3, start_server, fun(_, _, _) -> {ok, self()} end),
    meck:expect(quic_h3, stop_server, fun(_) -> ok end),
    try
        with_linux_os_mock(fun() ->
            ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start_probe(gateway_tls_config()))
        end)
    after
        pertisk_eproxy_test_helpers:ignoring_errors(fun() -> pertisk_eproxy_h3_api_gateway:stop_probe() end),
        ok = pertisk_eproxy_test_helpers:put_config_retry(OldCfg),
        unload_mocks([quic_h3])
    end.

proxied_gun_invalid_status_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        capture_h3_status(fun() ->
            with_gun_h3_proxy_mock(#{awaits => [{response, fin, <<"not-status">>, []}]}, fun() ->
                with_proxied_site(fun(#{host := H}) ->
                    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, auth(H))),
                    ?assertEqual(502, get(h3_sent_status))
                end)
            end)
        end)
    end).

gateway_start_acme_sni_missing_files_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    AcmeDir = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "h3-acme-miss-" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = filelib:ensure_dir(filename:join([AcmeDir, "certs", "x"])),
    OldAcme = application:get_env(pertisk_eproxy, acme_data_dir),
    application:set_env(pertisk_eproxy, acme_data_dir, AcmeDir),
    try
        Config = (gateway_tls_config())#{
            sites => [#{host => <<"acme-miss.test">>, certificate => <<"acme/missing">>}]
        },
        with_gateway_start_mock(fun() ->
            ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(Config))
        end)
    after
        case OldAcme of
            {ok, V} -> application:set_env(pertisk_eproxy, acme_data_dir, V);
            undefined -> application:unset_env(pertisk_eproxy, acme_data_dir)
        end,
        _ = os:cmd("rm -rf " ++ AcmeDir)
    end.

management_listener_bind_stack_linux_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    OldCfg = pertisk_eproxy_config:get_config(),
    ok = pertisk_eproxy_test_helpers:put_config_retry(OldCfg#{h3_udp_bind => dual_stack}),
    try
        with_linux_os_mock(fun() ->
            {Bind, Stack} = pertisk_eproxy_h3_api_gateway:management_listener_bind_stack(),
            ?assertEqual(<<"[::]:udp">>, Bind),
            ?assertEqual(<<"dual_stack">>, Stack)
        end)
    after
        ok = pertisk_eproxy_test_helpers:put_config_retry(OldCfg)
    end.

proxied_gun_request_crash_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        capture_h3_status(fun() ->
            unload_mocks([gun, pertisk_eproxy_upstream_pool]),
            meck:new(gun, [unstick, no_link]),
            meck:new(pertisk_eproxy_upstream_pool, [unstick, no_link]),
            meck:expect(pertisk_eproxy_upstream_pool, checkout, fun(_, _, _, _, _) ->
                {ok, ?GUN_MOCK_PID}
            end),
            meck:expect(pertisk_eproxy_upstream_pool, invalidate, fun(_) -> ok end),
            meck:expect(gun, open, fun(_, _, _) -> {ok, ?GUN_MOCK_PID} end),
            meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
            meck:expect(gun, request, fun(_, _, _, _, _) -> throw(proxy_crash) end),
            meck:expect(gun, close, fun(_) -> ok end),
            try
                with_proxied_site(fun(#{host := H}) ->
                    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, auth(H))),
                    ?assertEqual(502, get(h3_sent_status))
                end)
            after
                unload_mocks([gun, pertisk_eproxy_upstream_pool])
            end
        end)
    end).

proxied_await_body_unexpected_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        capture_h3_status(fun() ->
            with_gun_h3_proxy_mock(
                #{awaits => [{response, nofin, 200, []}], await_body => {unexpected, junk}},
                fun() ->
                    with_proxied_site(fun(#{host := H}) ->
                        ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/stream">>, auth(H))),
                        ?assertEqual(502, get(h3_sent_status))
                    end)
                end
            )
        end)
    end).

gateway_start_all_listeners_fail_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    unload_mocks([quic_h3]),
    meck:new(quic_h3, [unstick, no_link]),
    meck:expect(quic_h3, start_server, fun(_, _, _) -> {error, eaddrinuse} end),
    try
        ?assertMatch({error, {failed_quic_udp_listener, _}},
            pertisk_eproxy_h3_api_gateway:start(gateway_tls_config()))
    after
        unload_mocks([quic_h3])
    end.

gateway_start_invalid_sni_db_cert_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Db = pertisk_eproxy_test_helpers:tmp_db(),
    _ = file:delete(Db),
    OldDb = application:get_env(pertisk_eproxy, db_file),
    BadCert = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "bad-sni-" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".pem"
    ]),
    BadKey = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "bad-sni-" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".key"
    ]),
    ok = file:write_file(BadCert, <<"not-pem">>),
    ok = file:write_file(BadKey, <<"not-pem">>),
    CertName = iolist_to_binary(["bad-sni-", integer_to_list(erlang:unique_integer([monotonic, positive]))]),
    pertisk_eproxy_test_helpers:with_db_lock(fun() ->
        application:set_env(pertisk_eproxy, db_file, Db),
        {ok, Id} = pertisk_eproxy_db:insert_certificate_pem(Db, CertName, BadCert, BadKey),
        Config = (gateway_tls_config())#{
            sites => [#{host => <<"bad-sni.test">>, certificate => integer_to_binary(Id)}]
        },
        with_gateway_start_mock(fun() ->
            ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(Config))
        end),
        case OldDb of
            {ok, V} -> application:set_env(pertisk_eproxy, db_file, V);
            undefined -> application:unset_env(pertisk_eproxy, db_file)
        end
    end),
    _ = file:delete(BadCert),
    _ = file:delete(BadKey).

h3_handle_request_exit_noproc_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    pertisk_eproxy_test_helpers:sync_router([], []),
    unload_mocks([quic_h3]),
    meck:new(quic_h3, [unstick, no_link]),
    meck:expect(quic_h3, send_response, fun(_, _, _, _) -> exit(noproc) end),
    meck:expect(quic_h3, send_data, fun(_, _, _, _) -> ok end),
    try
        ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/missing">>, auth(<<"unknown.test">>)))
    after
        unload_mocks([quic_h3])
    end.

h3_management_only_backend_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Host = <<"mgmt-only-h3.test">>,
    Mgmt = pertisk_eproxy_config:management_loopback_upstream_bin(),
    pertisk_eproxy_test_helpers:sync_router(
        [#{host => Host, backend => <<"mgmt">>, routes => [#{path => <<"/">>, path_type => prefix}]}],
        [#{name => <<"mgmt">>, algorithm => round_robin, upstreams => [#{addr => Mgmt, weight => 1}]}]
    ),
    try
        with_quic_h3_mock(fun() ->
            capture_h3_status(fun() ->
                ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/api/version">>, auth(Host))),
                ?assertEqual(200, get(h3_sent_status))
            end)
        end)
    after
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

h3_loopback_upstream_dispatch_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Mgmt = pertisk_eproxy_config:management_loopback_upstream_bin(),
    Host = <<"loopback-h3.test">>,
    Site = #{
        host => Host,
        backend => <<"loop">>,
        routes => [#{path => <<"/">>, path_type => prefix}]
    },
    Backend = #{
        name => <<"loop">>,
        algorithm => round_robin,
        upstreams => [#{addr => Mgmt, weight => 1}]
    },
    pertisk_eproxy_test_helpers:sync_router([Site], [Backend]),
    try
        with_quic_h3_mock(fun() ->
            capture_h3_status(fun() ->
                ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/api/health">>, auth(Host))),
                ?assertEqual(200, get(h3_sent_status))
            end)
        end)
    after
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

termproxy_skips_x_forwarded_for_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        with_gun_h3_proxy_mock(fun() ->
            with_proxied_site(fun(#{host := H}) ->
                ?assertEqual(
                    ok,
                    h3(self(), 1, <<"GET">>, <<"/termproxy">>, auth(H) ++ [{<<"x">>, <<"1">>}])
                )
            end)
        end)
    end).

vncwebsocket_skips_x_forwarded_for_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        with_gun_h3_proxy_mock(fun() ->
            with_proxied_site(fun(#{host := H}) ->
                ?assertEqual(
                    ok,
                    h3(self(), 1, <<"GET">>, <<"/vncwebsocket">>, auth(H) ++ [{<<"x">>, <<"1">>}])
                )
            end)
        end)
    end).

h3_mgmt_upstream_local_admin_error_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Mgmt = pertisk_eproxy_config:management_loopback_upstream_bin(),
    Site = #{
        host => <<"mgmt-err2.test">>,
        backend => <<"loop">>,
        routes => [#{path => <<"/">>, path_type => prefix}]
    },
    Backend = #{
        name => <<"loop">>,
        algorithm => round_robin,
        upstreams => [#{addr => Mgmt, weight => 1}]
    },
    pertisk_eproxy_test_helpers:sync_router([Site], [Backend]),
    try
        with_quic_h3_mock(fun() ->
            capture_h3_status(fun() ->
                unload_mocks([pertisk_eproxy_h3_local_admin]),
                meck:new(pertisk_eproxy_h3_local_admin, [unstick, no_link]),
                meck:expect(pertisk_eproxy_h3_local_admin, try_dispatch, fun(_, _, _, _, _, _, _) ->
                    {error, timeout}
                end),
                try
                    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, auth(<<"mgmt-err2.test">>))),
                    ?assertEqual(502, get(h3_sent_status))
                after
                    unload_mocks([pertisk_eproxy_h3_local_admin])
                end
            end)
        end)
    after
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

management_listener_bind_stack_freebsd_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    OldCfg = pertisk_eproxy_config:get_config(),
    ok = pertisk_eproxy_test_helpers:put_config_retry(OldCfg#{h3_udp_bind => dual_stack}),
    try
        with_os_type_mock({unix, freebsd}, fun() ->
            {Bind, Stack} = pertisk_eproxy_h3_api_gateway:management_listener_bind_stack(),
            ?assertEqual(<<":: + 0.0.0.0">>, Bind),
            ?assertEqual(<<"split_v4_v6">>, Stack)
        end)
    after
        ok = pertisk_eproxy_test_helpers:put_config_retry(OldCfg)
    end.

management_listener_bind_stack_linux_split_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    OldCfg = pertisk_eproxy_config:get_config(),
    ok = pertisk_eproxy_test_helpers:put_config_retry(OldCfg#{h3_udp_bind => split}),
    try
        with_linux_os_mock(fun() ->
            {Bind, Stack} = pertisk_eproxy_h3_api_gateway:management_listener_bind_stack(),
            ?assertEqual(<<":: + 0.0.0.0">>, Bind),
            ?assertEqual(<<"split_v4_v6">>, Stack)
        end)
    after
        ok = pertisk_eproxy_test_helpers:put_config_retry(OldCfg)
    end.

management_listener_bind_stack_win32_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    try
        with_os_type_mock(win32, fun() ->
            {Bind, Stack} = pertisk_eproxy_h3_api_gateway:management_listener_bind_stack(),
            ?assertEqual(<<"0.0.0.0">>, Bind),
            ?assertEqual(<<"ipv4">>, Stack)
        end)
    after
        ok
    end.

gateway_start_probe_https_port_fallback_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Config = maps:without([quic_port], gateway_tls_config()),
    with_gateway_start_mock(fun() ->
        ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start_probe(Config))
    end).

h3_mgmt_port_upstream_dispatch_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Port = maps:get(management_port, pertisk_eproxy_config:get_config(), 9080),
    MgmtAddr = iolist_to_binary(["10.0.0.5:", integer_to_list(Port)]),
    Site = #{
        host => <<"mgmtport.test">>,
        backend => <<"mixed">>,
        routes => [#{path => <<"/">>, path_type => prefix}]
    },
    Backend = #{
        name => <<"mixed">>,
        algorithm => round_robin,
        upstreams => [
            #{addr => <<"backend.local:8080">>, weight => 1},
            #{addr => MgmtAddr, weight => 1}
        ]
    },
    pertisk_eproxy_test_helpers:sync_router([Site], [Backend]),
    try
        with_quic_h3_mock(fun() ->
            capture_h3_status(fun() ->
                unload_mocks([pertisk_eproxy_backend]),
                meck:new(pertisk_eproxy_backend, [unstick, no_link]),
                meck:expect(pertisk_eproxy_backend, pick_upstream, fun(_, _) -> {ok, MgmtAddr} end),
                meck:expect(pertisk_eproxy_backend, done_upstream, fun(_, _, _) -> ok end),
                try
                    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/api/health">>, auth(<<"mgmtport.test">>))),
                    ?assertEqual(200, get(h3_sent_status))
                after
                    unload_mocks([pertisk_eproxy_backend])
                end
            end)
        end)
    after
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

h3_mgmt_port_unsupported_gun_fallback_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Port = maps:get(management_port, pertisk_eproxy_config:get_config(), 9080),
    MgmtAddr = iolist_to_binary(["10.0.0.5:", integer_to_list(Port)]),
    Site = #{
        host => <<"mgmtfb.test">>,
        backend => <<"mixed">>,
        routes => [#{path => <<"/">>, path_type => prefix}]
    },
    Backend = #{
        name => <<"mixed">>,
        algorithm => round_robin,
        upstreams => [
            #{addr => <<"backend.local:8080">>, weight => 1},
            #{addr => MgmtAddr, weight => 1}
        ]
    },
    pertisk_eproxy_test_helpers:sync_router([Site], [Backend]),
    try
        with_quic_h3_mock(fun() ->
            capture_h3_status(fun() ->
                unload_mocks([pertisk_eproxy_backend, pertisk_eproxy_h3_local_admin, gun]),
                meck:new(pertisk_eproxy_backend, [unstick, no_link]),
                meck:new(pertisk_eproxy_h3_local_admin, [unstick, no_link]),
                meck:new(gun, [unstick, no_link]),
                meck:expect(pertisk_eproxy_backend, pick_upstream, fun(_, _) -> {ok, MgmtAddr} end),
                meck:expect(pertisk_eproxy_backend, done_upstream, fun(_, _, _) -> ok end),
                meck:expect(pertisk_eproxy_h3_local_admin, try_dispatch, fun(_, _, _, _, _, _, _) ->
                    {error, unsupported}
                end),
                meck:expect(gun, open, fun(Host, PortBin, _) ->
                    put(gun_open_target, {Host, PortBin}),
                    {ok, ?GUN_MOCK_PID}
                end),
                meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
                meck:expect(gun, request, fun(_, _, _, _, _) -> ?GUN_MOCK_STREAM end),
                meck:expect(gun, await, fun(_, _, _) -> {response, fin, 200, []} end),
                meck:expect(gun, close, fun(_) -> ok end),
                try
                    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/other">>, auth(<<"mgmtfb.test">>))),
                    ?assertEqual(200, get(h3_sent_status)),
                    {OpenHost, OpenPort} = get(gun_open_target),
                    ?assertEqual("127.0.0.1", OpenHost),
                    ?assertEqual(Port, OpenPort)
                after
                    erase(gun_open_target),
                    unload_mocks([pertisk_eproxy_backend, pertisk_eproxy_h3_local_admin, gun])
                end
            end)
        end)
    after
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

loopback_ephemeral_open_direct_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Up = #{addr => <<"127.0.0.1:9">>, weight => 1},
    Site = #{
        host => <<"loop-direct.test">>,
        backend => <<"web">>,
        routes => [#{path => <<"/">>, path_type => prefix}]
    },
    Backend = #{
        name => <<"web">>,
        algorithm => round_robin,
        upstreams => [Up]
    },
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(<<"web">>, [Up]),
    true = erlang:unlink(Pid),
    pertisk_eproxy_test_helpers:sync_router([Site], [Backend]),
    try
        with_quic_h3_mock(fun() ->
            capture_h3_status(fun() ->
                unload_mocks([gun, pertisk_eproxy_upstream_pool]),
                meck:new(gun, [unstick, no_link]),
                meck:new(pertisk_eproxy_upstream_pool, [unstick, no_link]),
                meck:expect(pertisk_eproxy_upstream_pool, checkout, fun(_, _, _, _, _) ->
                    {error, should_not_checkout}
                end),
                meck:expect(gun, open, fun(_, _, _) -> {ok, ?GUN_MOCK_PID} end),
                meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
                meck:expect(gun, request, fun(_, _, _, _, _) -> ?GUN_MOCK_STREAM end),
                meck:expect(gun, await, fun(_, _, _) -> {response, fin, 200, []} end),
                meck:expect(gun, close, fun(_) -> ok end),
                try
                    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, auth(<<"loop-direct.test">>))),
                    ?assertEqual(200, get(h3_sent_status)),
                    ?assertEqual(0, meck:num_calls(pertisk_eproxy_upstream_pool, checkout, '_'))
                after
                    unload_mocks([gun, pertisk_eproxy_upstream_pool])
                end
            end)
        end)
    after
        pertisk_eproxy_test_helpers:stop_backend(<<"web">>),
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

proxy_retry_shutdown_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        capture_h3_status(fun() ->
            unload_mocks([gun, pertisk_eproxy_upstream_pool]),
            meck:new(gun, [unstick, no_link]),
            meck:new(pertisk_eproxy_upstream_pool, [unstick, no_link]),
            CRef = make_ref(),
            put({gun_checkout_count, CRef}, 0),
            meck:expect(pertisk_eproxy_upstream_pool, checkout, fun(_, _, _, _, _) ->
                N = get({gun_checkout_count, CRef}) + 1,
                put({gun_checkout_count, CRef}, N),
                {ok, ?GUN_MOCK_PID}
            end),
            meck:expect(pertisk_eproxy_upstream_pool, invalidate, fun(_) -> ok end),
            meck:expect(gun, open, fun(_, _, _) -> {ok, ?GUN_MOCK_PID} end),
            meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
            meck:expect(gun, request, fun(_, _, _, _, _) -> ?GUN_MOCK_STREAM end),
            ARef = make_ref(),
            put({gun_await_queue, ARef}, [{error, {down, shutdown}}, {response, fin, 200, []}]),
            meck:expect(gun, await, fun(_, _, _) -> gun_dequeue_await(ARef) end),
            meck:expect(gun, await_body, fun(_, _, _) -> {ok, <<"ok">>} end),
            meck:expect(gun, close, fun(_) -> ok end),
            try
                with_proxied_site(fun(#{host := H}) ->
                    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, auth(H))),
                    ?assertEqual(2, get({gun_checkout_count, CRef})),
                    ?assertEqual(200, get(h3_sent_status))
                end)
            after
                erase({gun_checkout_count, CRef}),
                erase({gun_await_queue, ARef}),
                unload_mocks([gun, pertisk_eproxy_upstream_pool])
            end
        end)
    end).

sse_ephemeral_open_failure_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    N = <<"h3sseopen">>,
    Up = #{addr => <<"backend.local:8080">>, weight => 1},
    Site = #{
        host => <<"sse-open.test">>,
        backend => N,
        routes => [#{path => <<"/api/v1/stream">>, path_type => prefix}]
    },
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(N, [Up]),
    true = erlang:unlink(Pid),
    pertisk_eproxy_test_helpers:sync_router([Site], [#{name => N, algorithm => round_robin, upstreams => [Up]}]),
    Headers =
        auth(<<"sse-open.test">>) ++
        [{<<"accept">>, <<"text/event-stream">>}],
    try
        with_quic_h3_mock(fun() ->
            capture_h3_status(fun() ->
                unload_mocks([gun]),
                meck:new(gun, [unstick, no_link]),
                meck:expect(gun, open, fun(_, _, _) -> {error, econnrefused} end),
                try
                    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/api/v1/stream/events">>, Headers)),
                    ?assertEqual(502, get(h3_sent_status))
                after
                    unload_mocks([gun])
                end
            end)
        end)
    after
        pertisk_eproxy_test_helpers:stop_backend(N),
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

sse_idle_early_flush_immediate_fin_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    N = <<"h3sseidleimm">>,
    Up = #{addr => <<"backend.local:8080">>, weight => 1},
    Site = #{
        host => <<"sse-idle-imm.test">>,
        backend => N,
        routes => [#{path => <<"/api/v1/stream">>, path_type => prefix}]
    },
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(N, [Up]),
    true = erlang:unlink(Pid),
    pertisk_eproxy_test_helpers:sync_router([Site], [#{name => N, algorithm => round_robin, upstreams => [Up]}]),
    Headers =
        auth(<<"sse-idle-imm.test">>) ++
        [
            {<<"accept">>, <<"text/event-stream">>},
            {<<"authorization">>, <<"Bearer token">>}
        ],
    try
        with_quic_h3_mock(fun() ->
            unload_mocks([gun]),
            meck:new(gun, [unstick, no_link]),
            Ref = make_ref(),
            put({gun_await_queue, Ref}, [{error, timeout}, {response, fin, 200, []}]),
            meck:expect(gun, open, fun(_, _, _) -> {ok, ?GUN_MOCK_PID} end),
            meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
            meck:expect(gun, request, fun(_, _, _, _, _) -> ?GUN_MOCK_STREAM end),
            meck:expect(gun, await, fun(_, _, _) -> gun_dequeue_await(Ref) end),
            meck:expect(gun, await_body, fun(_, _, _) -> {ok, <<"done">>} end),
            meck:expect(gun, close, fun(_) -> ok end),
            try
                ?assertEqual(
                    ok,
                    h3(self(), 1, <<"GET">>, <<"/api/v1/stream/events">>, Headers)
                )
            after
                erase({gun_await_queue, Ref}),
                unload_mocks([gun])
            end
        end)
    after
        pertisk_eproxy_test_helpers:stop_backend(N),
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

h3_send_draining_state_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    pertisk_eproxy_test_helpers:sync_router([], []),
    unload_mocks([quic_h3]),
    meck:new(quic_h3, [unstick, no_link]),
    meck:expect(quic_h3, send_response, fun(_, _, _, _) -> {error, {invalid_state, draining}} end),
    meck:expect(quic_h3, send_data, fun(_, _, _, _) -> ok end),
    try
        ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/missing">>, auth(<<"unknown.test">>)))
    after
        unload_mocks([quic_h3])
    end.

proxied_trace_method_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        with_gun_h3_proxy_mock(fun() ->
            with_proxied_site(fun(#{host := H}) ->
                ?assertEqual(ok, h3(self(), 1, <<"TRACE">>, <<"/path">>, auth(H))),
                ?assertEqual({<<"TRACE">>, <<"/path">>}, get(gun_last_request))
            end)
        end)
    end).

argocd_cookie_missing_token_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_quic_h3_mock(fun() ->
        with_gun_h3_proxy_mock(fun() ->
            with_proxied_site(fun(#{host := H}) ->
                Hdr = auth(H) ++ [{<<"cookie">>, <<"other=1; session=abc">>}],
                ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, Hdr)),
                ?assertEqual(1, meck:num_calls(gun, request, '_'))
            end)
        end)
    end).

h3_empty_authority_route_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    pertisk_eproxy_test_helpers:sync_router([], []),
    with_quic_h3_mock(fun() ->
        capture_h3_status(fun() ->
            ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/missing">>, [{<<":authority">>, <<>>}])),
            ?assertEqual(404, get(h3_sent_status))
        end)
    end).

h3_send_data_timeout_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    pertisk_eproxy_test_helpers:sync_router([], []),
    unload_mocks([quic_h3]),
    meck:new(quic_h3, [unstick, no_link]),
    meck:expect(quic_h3, send_response, fun(_, _, _, _) -> ok end),
    meck:expect(quic_h3, send_data, fun(_, _, _, _) -> {error, timeout} end),
    try
        ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/missing">>, auth(<<"unknown.test">>)))
    after
        unload_mocks([quic_h3])
    end.

h3_mgmt_port_local_admin_error_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Port = maps:get(management_port, pertisk_eproxy_config:get_config(), 9080),
    MgmtAddr = iolist_to_binary(["10.0.0.5:", integer_to_list(Port)]),
    Site = #{
        host => <<"mgmtport-err.test">>,
        backend => <<"mixed">>,
        routes => [#{path => <<"/">>, path_type => prefix}]
    },
    Backend = #{
        name => <<"mixed">>,
        algorithm => round_robin,
        upstreams => [
            #{addr => <<"backend.local:8080">>, weight => 1},
            #{addr => MgmtAddr, weight => 1}
        ]
    },
    pertisk_eproxy_test_helpers:sync_router([Site], [Backend]),
    try
        with_quic_h3_mock(fun() ->
            capture_h3_status(fun() ->
                unload_mocks([pertisk_eproxy_backend, pertisk_eproxy_h3_local_admin]),
                meck:new(pertisk_eproxy_backend, [unstick, no_link]),
                meck:new(pertisk_eproxy_h3_local_admin, [unstick, no_link]),
                meck:expect(pertisk_eproxy_backend, pick_upstream, fun(_, _) -> {ok, MgmtAddr} end),
                meck:expect(pertisk_eproxy_backend, done_upstream, fun(_, _, _) -> ok end),
                meck:expect(pertisk_eproxy_h3_local_admin, try_dispatch, fun(_, _, _, _, _, _, _) ->
                    {error, timeout}
                end),
                try
                    ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, auth(<<"mgmtport-err.test">>))),
                    ?assertEqual(502, get(h3_sent_status))
                after
                    unload_mocks([pertisk_eproxy_backend, pertisk_eproxy_h3_local_admin])
                end
            end)
        end)
    after
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

gateway_start_https_port_fallback_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    Config = maps:without([quic_port], gateway_tls_config()),
    with_gateway_start_mock(fun() ->
        ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(Config))
    end).

gateway_start_tls_chain_info_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    CertPath = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
    Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
    {ok, LeafBin} = file:read_file(CertPath),
    Tmp = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "h3-chain-" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = file:make_dir(Tmp),
    ChainCert = filename:join([Tmp, "chain.pem"]),
    ok = file:write_file(ChainCert, <<LeafBin/binary, "\n", LeafBin/binary>>),
    try
        Config = (gateway_tls_config())#{
            tls_cert_file => ChainCert,
            tls_key_file => Key
        },
        with_gateway_start_mock(fun() ->
            ?assertMatch({ok, _}, pertisk_eproxy_h3_api_gateway:start(Config))
        end)
    after
        _ = file:del_dir_r(Tmp)
    end.

gateway_proxied_path_with_query_test() ->
    with_proxied_site(fun(#{host := Host}) ->
        with_quic_h3_mock(fun() ->
            with_gun_h3_proxy_mock(#{await_body => {ok, <<"ok">>}}, fun() ->
                Path = <<"/search?q=term">>,
                ?assertEqual(ok, h3(self(), 1, <<"GET">>, Path, auth(Host))),
                ?assertEqual({<<"GET">>, <<"/search?q=term">>}, get(gun_last_request))
            end)
        end)
    end).

gateway_authority_without_port_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    with_proxied_site(fun(#{host := Host}) ->
        with_quic_h3_mock(fun() ->
            with_gun_h3_proxy_mock(#{await_body => {ok, <<"ok">>}}, fun() ->
                ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, [{<<":authority">>, Host}]))
            end)
        end)
    end).

rate_limit_deny_429_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    unload_mocks([quic_h3, pertisk_eproxy_rate_limit, pertisk_eproxy_external_auth]),
    meck:new(quic_h3, [unstick, no_link]),
    meck:expect(quic_h3, send_response, fun(_, _, _, _) -> ok end),
    meck:expect(quic_h3, send_data, fun(_, _, _, _) -> ok end),
    meck:expect(quic_h3, set_stream_handler, fun(_, _, _) -> {ok, []} end),
    meck:new(pertisk_eproxy_rate_limit, [unstick, no_link]),
    meck:expect(pertisk_eproxy_rate_limit, check, fun(_, _, _) -> deny end),
    try
        capture_h3_status(fun() ->
            with_proxied_site(fun(#{host := H}) ->
                ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, auth(H))),
                ?assertEqual(429, get(h3_sent_status))
            end)
        end)
    after
        unload_mocks([quic_h3, pertisk_eproxy_rate_limit])
    end.

external_auth_denied_403_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    unload_mocks([quic_h3, pertisk_eproxy_rate_limit, pertisk_eproxy_external_auth]),
    meck:new(quic_h3, [unstick, no_link]),
    meck:expect(quic_h3, send_response, fun(_, _, _, _) -> ok end),
    meck:expect(quic_h3, send_data, fun(_, _, _, _) -> ok end),
    meck:expect(quic_h3, set_stream_handler, fun(_, _, _) -> {ok, []} end),
    meck:new(pertisk_eproxy_rate_limit, [unstick, no_link]),
    meck:expect(pertisk_eproxy_rate_limit, check, fun(_, _, _) -> allow end),
    meck:new(pertisk_eproxy_external_auth, [unstick, no_link]),
    meck:expect(pertisk_eproxy_external_auth, authorize, fun(_, _, _, _, _, _) ->
        {error, {auth_denied, 403}}
    end),
    try
        capture_h3_status(fun() ->
            with_proxied_site(fun(#{host := H}) ->
                ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, auth(H))),
                ?assertEqual(403, get(h3_sent_status))
            end)
        end)
    after
        unload_mocks([quic_h3, pertisk_eproxy_rate_limit, pertisk_eproxy_external_auth])
    end.

external_auth_unreachable_502_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_env(),
    unload_mocks([quic_h3, pertisk_eproxy_rate_limit, pertisk_eproxy_external_auth]),
    meck:new(quic_h3, [unstick, no_link]),
    meck:expect(quic_h3, send_response, fun(_, _, _, _) -> ok end),
    meck:expect(quic_h3, send_data, fun(_, _, _, _) -> ok end),
    meck:expect(quic_h3, set_stream_handler, fun(_, _, _) -> {ok, []} end),
    meck:new(pertisk_eproxy_rate_limit, [unstick, no_link]),
    meck:expect(pertisk_eproxy_rate_limit, check, fun(_, _, _) -> allow end),
    meck:new(pertisk_eproxy_external_auth, [unstick, no_link]),
    meck:expect(pertisk_eproxy_external_auth, authorize, fun(_, _, _, _, _, _) ->
        {error, auth_unreachable}
    end),
    try
        capture_h3_status(fun() ->
            with_proxied_site(fun(#{host := H}) ->
                ?assertEqual(ok, h3(self(), 1, <<"GET">>, <<"/">>, auth(H))),
                ?assertEqual(502, get(h3_sent_status))
            end)
        end)
    after
        unload_mocks([quic_h3, pertisk_eproxy_rate_limit, pertisk_eproxy_external_auth])
    end.
