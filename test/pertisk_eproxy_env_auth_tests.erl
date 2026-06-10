-module(pertisk_eproxy_env_auth_tests).

-include_lib("eunit/include/eunit.hrl").

with_creds(Fun) ->
    OldAdmin = os:getenv("PERTISK_ADMIN"),
    OldPass = os:getenv("PERTISK_PASSWORD"),
    OldSecret = os:getenv("PERTISK_AUTH_SIGNING_SECRET"),
    os:putenv("PERTISK_ADMIN", "admin"),
    os:putenv("PERTISK_PASSWORD", "secret"),
    os:putenv("PERTISK_AUTH_SIGNING_SECRET", "signing-secret"),
    try Fun() after
        restore_env("PERTISK_ADMIN", OldAdmin),
        restore_env("PERTISK_PASSWORD", OldPass),
        restore_env("PERTISK_AUTH_SIGNING_SECRET", OldSecret)
    end.

restore_env(Key, false) -> os:unsetenv(Key);
restore_env(Key, Val) -> os:putenv(Key, Val).

env_credentials_configured_test() ->
    with_creds(fun() ->
        ?assert(pertisk_eproxy_env_auth:env_credentials_configured())
    end),
    os:unsetenv("PERTISK_ADMIN"),
    ?assertNot(pertisk_eproxy_env_auth:env_credentials_configured()).

login_success_test() ->
    with_creds(fun() ->
        ?assertMatch({ok, #{token := _, username := <<"admin">>}},
                     pertisk_eproxy_env_auth:login(<<"admin">>, <<"secret">>))
    end).

login_invalid_credentials_test() ->
    with_creds(fun() ->
        ?assertEqual({error, invalid_credentials}, pertisk_eproxy_env_auth:login(<<"admin">>, <<"wrong">>))
    end).

token_issue_and_verify_roundtrip_test() ->
    with_creds(fun() ->
        {ok, #{token := Token}} = pertisk_eproxy_env_auth:issue_bearer_token(<<"admin">>),
        ?assertMatch({ok, <<"admin">>, _}, pertisk_eproxy_env_auth:verify_bearer_token(Token))
    end).

verify_bearer_token_rejects_garbage_test() ->
    with_creds(fun() ->
        ?assertEqual({error, unauthorized}, pertisk_eproxy_env_auth:verify_bearer_token(<<"bad">>))
    end).

verify_api_token_test() ->
    Old = os:getenv("PERTISK_API_TOKEN"),
    os:putenv("PERTISK_API_TOKEN", "api-secret"),
    try
        ?assertMatch({ok, <<"api">>, _}, pertisk_eproxy_env_auth:verify_api_token(<<"api-secret">>)),
        ?assertEqual(error, pertisk_eproxy_env_auth:verify_api_token(<<"api-xecret">>))
    after
        restore_env("PERTISK_API_TOKEN", Old)
    end.

session_ttl_secs_test() ->
    Old = os:getenv("PERTISK_SESSION_TTL_SECS"),
    os:putenv("PERTISK_SESSION_TTL_SECS", "3600"),
    try
        ?assertEqual(3600, pertisk_eproxy_env_auth:session_ttl_secs())
    after
        restore_env("PERTISK_SESSION_TTL_SECS", Old)
    end.

configure_sets_ingress_auth_test() ->
    with_creds(fun() ->
        application:ensure_all_started(lager),
        ?assertEqual(ok, pertisk_eproxy_env_auth:configure()),
        ?assert(pertisk_eproxy_env_auth:supports_local())
    end).
