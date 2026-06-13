-module(pertisk_k8s_time_tests).

-include_lib("eunit/include/eunit.hrl").

rfc3339_now_has_fractional_seconds_test() ->
    Now = pertisk_k8s_time:rfc3339_now(),
    ?assertMatch(<<_:19/binary, ".", _:6/binary, "Z">>, Now).
