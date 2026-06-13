-module(pertisk_eproxy_tracing_tests).

-include_lib("eunit/include/eunit.hrl").

parse_traceparent_test() ->
  TP = <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01">>,
  Ctx = pertisk_eproxy_tracing:request_context(#{<<"traceparent">> => TP}),
  ?assertMatch(#{trace_id := <<"4bf92f3577b34da6a3ce929d0e0e4736">>}, Ctx).

inject_headers_test() ->
  TP = <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01">>,
  Ctx = pertisk_eproxy_tracing:request_context(#{<<"traceparent">> => TP}),
  Out = pertisk_eproxy_tracing:inject_headers(#{}, Ctx),
  ?assert(maps:is_key(<<"traceparent">>, Out)).

parse_traceparent_invalid_test() ->
    ?assertEqual(undefined, pertisk_eproxy_tracing:request_context(#{<<"traceparent">> => <<"bad">>})).

request_context_non_map_test() ->
    ?assertEqual(undefined, pertisk_eproxy_tracing:request_context(not_a_map)).

inject_headers_undefined_context_test() ->
    ?assertEqual(#{<<"x">> => <<"1">>}, pertisk_eproxy_tracing:inject_headers(#{<<"x">> => <<"1">>}, undefined)).

otel_enabled_new_context_test() ->
    pertisk_eproxy_test_helpers:ensure_config(),
    C = pertisk_eproxy_config:get_config(),
    C2 = maps:put(otel_enabled, true, C),
    ok = pertisk_eproxy_test_helpers:put_config_retry(C2),
    try
        Ctx = pertisk_eproxy_tracing:request_context(#{}),
        ?assertMatch(#{trace_id := _, span_id := _, sampled := true}, Ctx),
        Out = pertisk_eproxy_tracing:inject_headers(#{}, Ctx),
        ?assert(maps:is_key(<<"traceparent">>, Out))
    after
        ok = pertisk_eproxy_test_helpers:put_config_retry(C)
    end.

traceparent_not_sampled_test() ->
    TP = <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00">>,
    Ctx = pertisk_eproxy_tracing:request_context(#{<<"traceparent">> => TP}),
    ?assertMatch(#{sampled := false}, Ctx).
