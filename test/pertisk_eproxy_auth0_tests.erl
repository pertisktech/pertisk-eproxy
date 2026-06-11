-module(pertisk_eproxy_auth0_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TEST_KID, <<"test-kid">>).

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

%% ---------------------------------------------------------------------------
%% JWKS / verify_bearer (httpc mock)
%% ---------------------------------------------------------------------------

clear_jwks_cache() ->
    catch ets:delete(pertisk_eproxy_auth0_jwks),
    ok.

with_auth0_env(Fun) ->
    application:set_env(pertisk_eproxy, admin_auth0_domain, <<"tenant.auth0.com">>),
    application:set_env(pertisk_eproxy, admin_auth0_client_id, <<"client-id">>),
    try
        Fun()
    after
        clear_auth0_env(),
        clear_jwks_cache()
    end.

with_httpc_jwks_mock(JwksBody, Fun) ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {Url, _}, _Opts, _HttpOpts) ->
        case string:find(Url, "/.well-known/jwks.json") of
            nomatch ->
                meck:passthrough([httpc, request, [get, {Url, []}, [], []]]);
            _ ->
                {ok, {{http, 200, 'OK'}, [], JwksBody}}
        end
    end),
    try
        Fun()
    after
        meck:unload(httpc)
    end.

test_jwk_and_jwks() ->
    Jwk = jose_jwk:generate_key({rsa, 2048}),
    {_, PubMap} = jose_jwk:to_public_map(jose_jwk:to_public(Jwk)),
    KeyMap = PubMap#{<<"kid">> => ?TEST_KID, <<"use">> => <<"sig">>, <<"alg">> => <<"RS256">>},
    JwksBody = thoas:encode(#{<<"keys">> => [KeyMap]}),
    {Jwk, JwksBody}.

sign_test_token(Jwk, Claims) ->
    Jwt = jose_jwt:from_map(Claims),
    Jws = jose_jwt:sign(Jwk, #{<<"alg">> => <<"RS256">>, <<"kid">> => ?TEST_KID}, Jwt),
    {_, Compact} = jose_jws:compact(Jws),
    Compact.

base_claims() ->
    #{
        <<"iss">> => <<"https://tenant.auth0.com/">>,
        <<"aud">> => <<"client-id">>,
        <<"exp">> => erlang:system_time(second) + 3600,
        <<"email">> => <<"user@example.com">>
    }.

verify_bearer_valid_token_test() ->
    with_auth0_env(fun() ->
        {Jwk, JwksBody} = test_jwk_and_jwks(),
        Token = sign_test_token(Jwk, base_claims()),
        with_httpc_jwks_mock(JwksBody, fun() ->
            ?assertMatch({ok, <<"user@example.com">>, _}, pertisk_eproxy_auth0:verify_bearer(Token))
        end)
    end).

verify_bearer_jwks_http_error_test() ->
    with_auth0_env(fun() ->
        {Jwk, _} = test_jwk_and_jwks(),
        Token = sign_test_token(Jwk, base_claims()),
        meck:new(httpc, [unstick, passthrough]),
        meck:expect(httpc, request, fun(get, {_Url, _}, _Opts, _HttpOpts) ->
            {error, timeout}
        end),
        try
            ?assertMatch({error, {jwks_http, _}}, pertisk_eproxy_auth0:verify_bearer(Token))
        after
            meck:unload(httpc)
        end
    end).

verify_bearer_jwks_no_keys_test() ->
    with_auth0_env(fun() ->
        {Jwk, _} = test_jwk_and_jwks(),
        Token = sign_test_token(Jwk, base_claims()),
        with_httpc_jwks_mock(thoas:encode(#{}), fun() ->
            ?assertEqual({error, jwks_no_keys}, pertisk_eproxy_auth0:verify_bearer(Token))
        end)
    end).

verify_bearer_token_expired_test() ->
    with_auth0_env(fun() ->
        {Jwk, JwksBody} = test_jwk_and_jwks(),
        Claims = (base_claims())#{<<"exp">> => erlang:system_time(second) - 3600},
        Token = sign_test_token(Jwk, Claims),
        with_httpc_jwks_mock(JwksBody, fun() ->
            ?assertEqual({error, token_expired}, pertisk_eproxy_auth0:verify_bearer(Token))
        end)
    end).

verify_bearer_bad_issuer_test() ->
    with_auth0_env(fun() ->
        {Jwk, JwksBody} = test_jwk_and_jwks(),
        Claims = (base_claims())#{<<"iss">> => <<"https://evil.example/">>},
        Token = sign_test_token(Jwk, Claims),
        with_httpc_jwks_mock(JwksBody, fun() ->
            ?assertEqual({error, bad_issuer}, pertisk_eproxy_auth0:verify_bearer(Token))
        end)
    end).

verify_bearer_bad_audience_test() ->
    with_auth0_env(fun() ->
        {Jwk, JwksBody} = test_jwk_and_jwks(),
        Claims = (base_claims())#{<<"aud">> => <<"wrong-audience">>},
        Token = sign_test_token(Jwk, Claims),
        with_httpc_jwks_mock(JwksBody, fun() ->
            ?assertEqual({error, bad_audience}, pertisk_eproxy_auth0:verify_bearer(Token))
        end)
    end).

verify_bearer_jwks_cache_hit_test() ->
    with_auth0_env(fun() ->
        {Jwk, JwksBody} = test_jwk_and_jwks(),
        Token = sign_test_token(Jwk, base_claims()),
        with_httpc_jwks_mock(JwksBody, fun() ->
            ?assertMatch({ok, _, _}, pertisk_eproxy_auth0:verify_bearer(Token)),
            Calls1 = meck:num_calls(httpc, request, '_'),
            ?assertMatch({ok, _, _}, pertisk_eproxy_auth0:verify_bearer(Token)),
            ?assertEqual(Calls1, meck:num_calls(httpc, request, '_'))
        end)
    end).

auth0_public_config_domain_trim_test() ->
    application:set_env(pertisk_eproxy, admin_auth0_domain, <<"https://tenant.auth0.com/">>),
    application:set_env(pertisk_eproxy, admin_auth0_client_id, <<"client-id">>),
    try
        M = pertisk_eproxy_auth0:auth0_public_config(),
        ?assertEqual(<<"tenant.auth0.com">>, maps:get(<<"auth0_domain">>, M))
    after
        clear_auth0_env()
    end.

verify_bearer_with_audience_claim_test() ->
    application:set_env(pertisk_eproxy, admin_auth0_domain, <<"tenant.auth0.com">>),
    application:set_env(pertisk_eproxy, admin_auth0_client_id, <<"client-id">>),
    application:set_env(pertisk_eproxy, admin_auth0_audience, <<"https://api.example">>),
    try
        {Jwk, JwksBody} = test_jwk_and_jwks(),
        Claims =
            (base_claims())#{
                <<"aud">> => [<<"https://api.example">>, <<"client-id">>]
            },
        Token = sign_test_token(Jwk, Claims),
        with_httpc_jwks_mock(JwksBody, fun() ->
            ?assertMatch({ok, _, _}, pertisk_eproxy_auth0:verify_bearer(Token))
        end)
    after
        clear_auth0_env(),
        clear_jwks_cache()
    end.

verify_bearer_custom_issuer_test() ->
    application:set_env(pertisk_eproxy, admin_auth0_domain, <<"tenant.auth0.com">>),
    application:set_env(pertisk_eproxy, admin_auth0_client_id, <<"client-id">>),
    application:set_env(pertisk_eproxy, admin_auth0_issuer, <<"https://auth.example.com">>),
    try
        {Jwk, JwksBody} = test_jwk_and_jwks(),
        Claims = (base_claims())#{<<"iss">> => <<"https://auth.example.com/">>},
        Token = sign_test_token(Jwk, Claims),
        with_httpc_jwks_mock(JwksBody, fun() ->
            ?assertMatch({ok, _, _}, pertisk_eproxy_auth0:verify_bearer(Token))
        end)
    after
        clear_auth0_env(),
        clear_jwks_cache()
    end.

verify_bearer_jwks_http_non_200_test() ->
    with_auth0_env(fun() ->
        {Jwk, _} = test_jwk_and_jwks(),
        Token = sign_test_token(Jwk, base_claims()),
        meck:new(httpc, [unstick, passthrough]),
        meck:expect(httpc, request, fun(get, {_Url, _}, _Opts, _HttpOpts) ->
            {ok, {{http, 503, 'Service Unavailable'}, [], <<"unavailable">>}}
        end),
        try
            ?assertMatch({error, {jwks_http, 503, _}}, pertisk_eproxy_auth0:verify_bearer(Token))
        after
            meck:unload(httpc)
        end
    end).
