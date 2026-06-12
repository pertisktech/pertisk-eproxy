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
        ?assertEqual(error, pertisk_eproxy_env_auth:verify_api_token(<<"api-xecret">>)),
        ?assert(pertisk_eproxy_env_auth:api_token_configured())
    after
        application:unset_env(pertisk_eproxy, runtime_api_token),
        restore_env("PERTISK_API_TOKEN", Old)
    end.

rotate_api_token_test() ->
    with_creds(fun() ->
        application:unset_env(pertisk_eproxy, runtime_api_token),
        ?assertMatch({ok, Token} when is_binary(Token), pertisk_eproxy_env_auth:rotate_api_token(<<"secret">>)),
        ?assert(pertisk_eproxy_env_auth:api_token_configured())
    end).

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

auth_mode_atom_and_login_required_test() ->
    with_creds(fun() ->
        ok = pertisk_eproxy_env_auth:configure(),
        ?assertEqual(both, pertisk_eproxy_env_auth:auth_mode_atom()),
        ?assert(pertisk_eproxy_env_auth:login_required()),
        ?assert(pertisk_eproxy_env_auth:supports_local()),
        ?assertNot(pertisk_eproxy_env_auth:supports_sso())
    end).

configure_without_creds_disables_login_test() ->
    OldAdmin = os:getenv("PERTISK_ADMIN"),
    OldPass = os:getenv("PERTISK_PASSWORD"),
    os:unsetenv("PERTISK_ADMIN"),
    os:unsetenv("PERTISK_PASSWORD"),
    try
        application:ensure_all_started(lager),
        ?assertEqual(ok, pertisk_eproxy_env_auth:configure()),
        ?assertNot(pertisk_eproxy_env_auth:login_required())
    after
        restore_env("PERTISK_ADMIN", OldAdmin),
        restore_env("PERTISK_PASSWORD", OldPass)
    end.

issue_bearer_token_empty_username_roundtrip_test() ->
    with_creds(fun() ->
        {ok, #{token := Token, username := <<>>}} =
            pertisk_eproxy_env_auth:issue_bearer_token(<<>>),
        ?assertMatch({ok, <<>>, _}, pertisk_eproxy_env_auth:verify_bearer_token(Token))
    end).

verify_bearer_token_rejects_wrong_prefix_test() ->
    with_creds(fun() ->
        ?assertEqual({error, unauthorized}, pertisk_eproxy_env_auth:verify_bearer_token(<<"ept_abc">>))
    end).

session_ttl_secs_default_test() ->
    Old = os:getenv("PERTISK_SESSION_TTL_SECS"),
    os:unsetenv("PERTISK_SESSION_TTL_SECS"),
    try
        ?assertEqual(86400, pertisk_eproxy_env_auth:session_ttl_secs())
    after
        restore_env("PERTISK_SESSION_TTL_SECS", Old)
    end.

login_env_not_configured_test() ->
    OldAdmin = os:getenv("PERTISK_ADMIN"),
    OldPass = os:getenv("PERTISK_PASSWORD"),
    os:unsetenv("PERTISK_ADMIN"),
    os:unsetenv("PERTISK_PASSWORD"),
    try
        ?assertEqual({error, env_not_configured}, pertisk_eproxy_env_auth:login(<<"admin">>, <<"secret">>))
    after
        restore_env("PERTISK_ADMIN", OldAdmin),
        restore_env("PERTISK_PASSWORD", OldPass)
    end.

issue_bearer_token_no_signing_secret_test() ->
    OldAdmin = os:getenv("PERTISK_ADMIN"),
    OldPass = os:getenv("PERTISK_PASSWORD"),
    OldSecret = os:getenv("PERTISK_AUTH_SIGNING_SECRET"),
    os:putenv("PERTISK_ADMIN", "admin"),
    os:unsetenv("PERTISK_PASSWORD"),
    os:unsetenv("PERTISK_AUTH_SIGNING_SECRET"),
    try
        ?assertEqual({error, signing_secret_not_configured},
            pertisk_eproxy_env_auth:issue_bearer_token(<<"admin">>))
    after
        restore_env("PERTISK_ADMIN", OldAdmin),
        restore_env("PERTISK_PASSWORD", OldPass),
        restore_env("PERTISK_AUTH_SIGNING_SECRET", OldSecret)
    end.

verify_bearer_token_no_signing_secret_test() ->
    OldSecret = os:getenv("PERTISK_AUTH_SIGNING_SECRET"),
    OldPass = os:getenv("PERTISK_PASSWORD"),
    os:unsetenv("PERTISK_AUTH_SIGNING_SECRET"),
    os:unsetenv("PERTISK_PASSWORD"),
    try
        ?assertEqual({error, unauthorized},
            pertisk_eproxy_env_auth:verify_bearer_token(<<"ptskv1.abc.def">>))
    after
        restore_env("PERTISK_AUTH_SIGNING_SECRET", OldSecret),
        restore_env("PERTISK_PASSWORD", OldPass)
    end.

verify_bearer_token_bad_signature_test() ->
    with_creds(fun() ->
        {ok, #{token := Token}} = pertisk_eproxy_env_auth:issue_bearer_token(<<"admin">>),
        os:putenv("PERTISK_AUTH_SIGNING_SECRET", "different-secret"),
        ?assertEqual({error, unauthorized}, pertisk_eproxy_env_auth:verify_bearer_token(Token))
    end).

verify_bearer_token_malformed_parts_test() ->
    with_creds(fun() ->
        ?assertEqual({error, unauthorized}, pertisk_eproxy_env_auth:verify_bearer_token(<<"ptskv1.onlyonepart">>))
    end).

verify_bearer_token_expired_test() ->
    with_creds(fun() ->
        Secret = os:getenv("PERTISK_AUTH_SIGNING_SECRET"),
        Payload = #{<<"sub">> => <<"admin">>, <<"exp">> => 1},
        PayloadBin = thoas:encode(Payload),
        PayloadB64 = jose_jwa_base64url:encode(PayloadBin),
        Sig = crypto:mac(hmac, sha256, Secret, PayloadB64),
        SigB64 = jose_jwa_base64url:encode(Sig),
        Token = <<"ptskv1.", PayloadB64/binary, ".", SigB64/binary>>,
        ?assertEqual({error, unauthorized}, pertisk_eproxy_env_auth:verify_bearer_token(Token))
    end).

verify_api_token_non_binary_test() ->
    ?assertEqual(error, pertisk_eproxy_env_auth:verify_api_token(not_a_binary)).

session_ttl_invalid_value_test() ->
    Old = os:getenv("PERTISK_SESSION_TTL_SECS"),
    os:putenv("PERTISK_SESSION_TTL_SECS", "not-a-number"),
    try
        ?assertEqual(86400, pertisk_eproxy_env_auth:session_ttl_secs())
    after
        restore_env("PERTISK_SESSION_TTL_SECS", Old)
    end.

login_accepts_string_credentials_test() ->
    with_creds(fun() ->
        ?assertMatch({ok, #{username := <<"admin">>}},
            pertisk_eproxy_env_auth:login("admin", "secret"))
    end).

configure_local_mode_only_test() ->
    OldMode = os:getenv("PERTISK_AUTH_MODE"),
    OldAuth = application:get_env(pertisk_eproxy, admin_auth),
    os:putenv("PERTISK_AUTH_MODE", "local"),
    with_creds(fun() ->
        application:ensure_all_started(lager),
        ?assertEqual(ok, pertisk_eproxy_env_auth:configure()),
        ?assertEqual(local, pertisk_eproxy_env_auth:auth_mode_atom()),
        ?assert(pertisk_eproxy_env_auth:supports_local()),
        ?assertNot(pertisk_eproxy_env_auth:supports_sso())
    end),
    restore_env("PERTISK_AUTH_MODE", OldMode),
    restore_application_env(pertisk_eproxy, admin_auth, OldAuth).

configure_sso_mode_only_test() ->
    OldMode = os:getenv("PERTISK_AUTH_MODE"),
    OldDomain = os:getenv("PERTISK_AUTH0_DOMAIN"),
    OldClient = os:getenv("PERTISK_AUTH0_CLIENT_ID"),
    OldAuth = application:get_env(pertisk_eproxy, admin_auth),
    OldSupportsLocal = application:get_env(pertisk_eproxy, ingress_supports_local),
    OldSupportsSso = application:get_env(pertisk_eproxy, ingress_supports_sso),
    OldAuthMode = application:get_env(pertisk_eproxy, ingress_auth_mode),
    os:putenv("PERTISK_AUTH_MODE", "sso"),
    os:putenv("PERTISK_AUTH0_DOMAIN", "example.auth0.com"),
    os:putenv("PERTISK_AUTH0_CLIENT_ID", "client-id"),
    OldAdmin = os:getenv("PERTISK_ADMIN"),
    OldPass = os:getenv("PERTISK_PASSWORD"),
    os:unsetenv("PERTISK_ADMIN"),
    os:unsetenv("PERTISK_PASSWORD"),
    try
        application:ensure_all_started(lager),
        ?assertEqual(ok, pertisk_eproxy_env_auth:configure()),
        ?assertEqual(sso, pertisk_eproxy_env_auth:auth_mode_atom()),
        ?assertNot(pertisk_eproxy_env_auth:supports_local()),
        ?assert(pertisk_eproxy_env_auth:supports_sso())
    after
        restore_env("PERTISK_AUTH_MODE", OldMode),
        restore_env("PERTISK_AUTH0_DOMAIN", OldDomain),
        restore_env("PERTISK_AUTH0_CLIENT_ID", OldClient),
        restore_env("PERTISK_ADMIN", OldAdmin),
        restore_env("PERTISK_PASSWORD", OldPass),
        restore_application_env(pertisk_eproxy, admin_auth, OldAuth),
        restore_application_env(pertisk_eproxy, ingress_supports_local, OldSupportsLocal),
        restore_application_env(pertisk_eproxy, ingress_supports_sso, OldSupportsSso),
        restore_application_env(pertisk_eproxy, ingress_auth_mode, OldAuthMode)
    end.

restore_application_env(App, Key, undefined) ->
    application:unset_env(App, Key);
restore_application_env(App, Key, {ok, Val}) ->
    application:set_env(App, Key, Val).
