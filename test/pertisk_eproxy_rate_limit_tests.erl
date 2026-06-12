-module(pertisk_eproxy_rate_limit_tests).

-include_lib("eunit/include/eunit.hrl").

allow_when_disabled_test() ->
    ?assertEqual(allow, pertisk_eproxy_rate_limit:check(<<"1.2.3.4">>, <<"example.com">>)).

deny_when_burst_exhausted_test() ->
    pertisk_eproxy_test_helpers:ensure_config(),
    Config = pertisk_eproxy_config:get_config(),
    Config1 = Config#{
        rate_limit_enabled => true,
        rate_limit_rps => 1,
        rate_limit_burst => 1
    },
    ok = pertisk_eproxy_config:put_config(Config1),
    try
        ?assertEqual(allow, pertisk_eproxy_rate_limit:check(<<"9.9.9.9">>, <<"limited.example">>)),
        ?assertEqual(deny, pertisk_eproxy_rate_limit:check(<<"9.9.9.9">>, <<"limited.example">>))
    after
        ok = pertisk_eproxy_config:put_config(Config)
    end.
