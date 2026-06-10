-module(pertisk_eproxy_auth0_tests).

-include_lib("eunit/include/eunit.hrl").

auth0_public_config_empty_when_unconfigured_test() ->
    clear_auth0_env(),
    ?assertEqual(#{}, pertisk_eproxy_auth0:auth0_public_config()).

auth0_public_config_with_domain_and_client_test() ->
    OldDomain = application:get_env(pertisk_eproxy, admin_auth0_domain),
    OldClient = application:get_env(pertisk_eproxy, admin_auth0_client_id),
    application:set_env(pertisk_eproxy, admin_auth0_domain, <<"tenant.auth0.com">>),
    application:set_env(pertisk_eproxy, admin_auth0_client_id, <<"client-id">>),
    try
        M = pertisk_eproxy_auth0:auth0_public_config(),
        ?assertEqual(true, maps:get(<<"supports_sso">>, M)),
        ?assertEqual(<<"tenant.auth0.com">>, maps:get(<<"auth0_domain">>, M)),
        ?assertEqual(<<"client-id">>, maps:get(<<"auth0_client_id">>, M))
    after
        restore_env(admin_auth0_domain, OldDomain),
        restore_env(admin_auth0_client_id, OldClient)
    end.

clear_auth0_env() ->
    application:unset_env(pertisk_eproxy, admin_auth0_domain),
    application:unset_env(pertisk_eproxy, admin_auth0_client_id),
    application:unset_env(pertisk_eproxy, admin_auth0_audience).

restore_env(Key, undefined) ->
    application:unset_env(pertisk_eproxy, Key);
restore_env(Key, Val) ->
    application:set_env(pertisk_eproxy, Key, Val).
