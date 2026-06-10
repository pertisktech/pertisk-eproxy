-module(pertisk_eproxy_h3_api_gateway_tests).

-include_lib("eunit/include/eunit.hrl").

h3(Conn, StreamId, Method, Path, Headers) ->
    pertisk_eproxy_h3_api_gateway:handle_request(Conn, StreamId, Method, Path, Headers).

auth(Authority) ->
    [{<<":authority">>, Authority}].

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
