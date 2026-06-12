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
