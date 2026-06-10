-module(pertisk_eproxy_admin_kubernetes_tests).

-include_lib("eunit/include/eunit.hrl").

available_follows_ingress_mode_test() ->
    Old = os:getenv("PERTISK_MODE"),
    os:putenv("PERTISK_MODE", "ingress"),
    try
        ?assert(pertisk_eproxy_admin_kubernetes:available())
    after
        case Old of false -> os:unsetenv("PERTISK_MODE"); V -> os:putenv("PERTISK_MODE", V) end
    end,
    os:unsetenv("PERTISK_MODE"),
    ?assertNot(pertisk_eproxy_admin_kubernetes:available()).
