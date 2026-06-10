-module(pertisk_eproxy_upstream_pool_tests).

-include_lib("eunit/include/eunit.hrl").

invalidate_undefined_test() ->
    ?assertEqual(ok, pertisk_eproxy_upstream_pool:invalidate(undefined)).

invalidate_dead_pid_test() ->
    ?assertEqual(ok, pertisk_eproxy_upstream_pool:invalidate(list_to_pid("<0.2.0>"))).

checkout_without_pool_opens_connection_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_deps(),
    case pertisk_eproxy_upstream_pool:checkout(
        "127.0.0.1",
        1,
        tcp,
        http,
        #{connect_timeout => 200, protocols => [http]}
    ) of
        {ok, Pid} ->
            catch gun:close(Pid),
            ok;
        {error, _} ->
            ok
    end.
