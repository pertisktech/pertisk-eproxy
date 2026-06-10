-module(pertisk_eproxy_access_log_tests).

-include_lib("eunit/include/eunit.hrl").

is_health_path_api_health_test() ->
    ?assert(pertisk_eproxy_access_log:is_health_path(<<"/api/health">>)).

is_health_path_variants_test() ->
    ?assert(pertisk_eproxy_access_log:is_health_path(<<"/health">>)),
    ?assert(pertisk_eproxy_access_log:is_health_path(<<"/healthz">>)),
    ?assert(pertisk_eproxy_access_log:is_health_path(<<"/readyz">>)).

is_health_path_other_test() ->
    ?assertNot(pertisk_eproxy_access_log:is_health_path(<<"/api/config">>)).
