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
