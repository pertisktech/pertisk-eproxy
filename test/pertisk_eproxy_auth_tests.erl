-module(pertisk_eproxy_auth_tests).

-include_lib("eunit/include/eunit.hrl").

bearer_from_x_eproxy_header_test() ->
    Req = #{headers => #{<<"x-eproxy-bearer">> => <<"Bearer my-token">>}},
    ?assertEqual({ok, <<"my-token">>}, pertisk_eproxy_auth:bearer_from_request(Req)).

bearer_missing_test() ->
    Req = #{headers => #{}},
    ?assertEqual(error, pertisk_eproxy_auth:bearer_from_request(Req)).

auth_config_map_proxy_mode_test() ->
    application:ensure_all_started(lager),
    case whereis(pertisk_eproxy_config) of
        undefined -> {ok, _} = pertisk_eproxy_config:start_link();
        _ -> ok
    end,
    Old = os:getenv("PERTISK_MODE"),
    os:putenv("PERTISK_MODE", "proxy"),
    try
        M = pertisk_eproxy_auth:auth_config_map(),
        ?assert(is_map(M))
    after
        case Old of false -> os:unsetenv("PERTISK_MODE"); V -> os:putenv("PERTISK_MODE", V) end
    end.

auth_mode_reads_application_env_test() ->
    ?assert(is_atom(pertisk_eproxy_auth:auth_mode())).
