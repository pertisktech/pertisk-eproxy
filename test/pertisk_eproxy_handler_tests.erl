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
