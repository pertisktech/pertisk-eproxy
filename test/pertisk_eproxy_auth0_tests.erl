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

verify_bearer_not_jwt_test() ->
    clear_auth0_env(),
    application:set_env(pertisk_eproxy, admin_auth0_domain, <<"tenant.auth0.com">>),
    application:set_env(pertisk_eproxy, admin_auth0_client_id, <<"client-id">>),
    try
        ?assertEqual({error, not_jwt}, pertisk_eproxy_auth0:verify_bearer(<<"not-a-jwt">>))
    after
        clear_auth0_env()
    end.

verify_bearer_auth0_disabled_test() ->
    clear_auth0_env(),
    ?assertEqual({error, auth0_disabled}, pertisk_eproxy_auth0:verify_bearer(<<"a.b.c">>)).

verify_bearer_badarg_test() ->
    ?assertEqual({error, badarg}, pertisk_eproxy_auth0:verify_bearer(123)).

maybe_prefetch_jwks_unconfigured_test() ->
    clear_auth0_env(),
    ?assertEqual(ok, pertisk_eproxy_auth0:maybe_prefetch_jwks()).

maybe_prefetch_jwks_configured_test() ->
    application:set_env(pertisk_eproxy, admin_auth0_domain, <<"tenant.auth0.com">>),
    application:set_env(pertisk_eproxy, admin_auth0_client_id, <<"client-id">>),
    try
        ?assertEqual(ok, pertisk_eproxy_auth0:maybe_prefetch_jwks())
    after
        clear_auth0_env()
    end.

auth0_public_config_with_audience_test() ->
    application:set_env(pertisk_eproxy, admin_auth0_domain, <<"tenant.auth0.com">>),
    application:set_env(pertisk_eproxy, admin_auth0_client_id, <<"client-id">>),
    application:set_env(pertisk_eproxy, admin_auth0_audience, <<"https://api.example">>),
    try
        M = pertisk_eproxy_auth0:auth0_public_config(),
        ?assertEqual(<<"https://api.example">>, maps:get(<<"auth0_audience">>, M))
    after
        clear_auth0_env()
    end.
