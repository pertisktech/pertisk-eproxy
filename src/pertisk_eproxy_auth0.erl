%% @doc Auth0 JWT verification for admin API (JWKS, iss/aud/exp).
-module(pertisk_eproxy_auth0).

-export([auth0_public_config/0, verify_bearer/1, maybe_prefetch_jwks/0]).

-define(JWKS_CACHE, pertisk_eproxy_auth0_jwks).
-define(JWKS_TTL_SEC, 900).
-define(JWKS_FAIL_CACHE_SEC, 120).
-define(EXP_LEEWAY_SEC, 90).

%% ---------------------------------------------------------------------------
%% Public config for GET /api/auth/config (SPA + Auth0 SDK)
%% ---------------------------------------------------------------------------

-spec auth0_public_config() -> map().
auth0_public_config() ->
    case auth0_configured() of
        {true, Domain, ClientId, Audience} ->
            M = #{
                <<"supports_sso">> => true,
                <<"auth0_domain">> => Domain,
                <<"auth0_client_id">> => ClientId
            },
            case Audience of
                undefined -> M;
                A -> M#{<<"auth0_audience">> => A}
            end;
        false ->
            #{}
    end.

auth0_configured() ->
    case {domain_bin(), client_id_bin()} of
        {D, C} when is_binary(D), byte_size(D) > 0, is_binary(C), byte_size(C) > 0 ->
            {true, D, C, audience_bin()};
        _ ->
            false
    end.

%% @doc Warm JWKS in the background after startup so the first SSO/JWT request does not block on HTTPS.
-spec maybe_prefetch_jwks() -> ok.
maybe_prefetch_jwks() ->
    case auth0_configured() of
        {true, Domain, _, _} ->
            _ = spawn(fun() ->
                case fetch_jwks_json(Domain) of
                    {ok, _} ->
                        ok;
                    Err ->
                        lager:warning("Auth0 JWKS prefetch failed (SSO may be slow until JWKS is reachable): ~p", [Err])
                end
            end),
            ok;
        false ->
            ok
    end.

%% @doc Verify RS256 (or other JWS) access token from Auth0. Returns username display and token exp (unix sec).
-spec verify_bearer(binary()) -> {ok, binary(), integer()} | {error, term()}.
verify_bearer(Token) when is_binary(Token) ->
    try
        verify_bearer_impl(Token)
    catch
        Class:Reason:Stack ->
            lager:warning("verify_bearer crash ~p:~p stack ~p", [Class, Reason, Stack]),
            {error, verify_crash}
    end;
verify_bearer(_) ->
    {error, badarg}.

verify_bearer_impl(Token) when is_binary(Token) ->
    case is_compact_jwt(Token) of
        false ->
            {error, not_jwt};
        true ->
            case auth0_configured() of
                false ->
                    {error, auth0_disabled};
                {true, Domain, ClientId, Audience} ->
                    Issuer = issuer_for_verify(Domain),
                    case fetch_jwks_json(Domain) of
                        {ok, JwksBody} ->
                            verify_jwt_with_jwks(Token, JwksBody, Issuer, ClientId, Audience);
                        Err ->
                            Err
                    end
            end
    end.

%% ---------------------------------------------------------------------------
is_compact_jwt(Bin) ->
    case binary:split(Bin, <<".">>, [global]) of
        [_, _, _] -> true;
        _ -> false
    end.

domain_bin() ->
    case application:get_env(pertisk_eproxy, admin_auth0_domain) of
        {ok, D} when is_binary(D) -> trim_domain(D);
        {ok, D} when is_list(D) -> trim_domain(unicode:characters_to_binary(D, utf8));
        _ -> undefined
    end.

trim_domain(D) ->
    D1 = binary_trim(D),
    case D1 of
        <<"https://", Rest/binary>> ->
            trim_domain(binary_trim_trailing_slash(Rest));
        _ ->
            binary_trim_trailing_slash(D1)
    end.

binary_trim(B) ->
    re:replace(B, <<"^\\s+|\\s+$">>, <<>>, [{return, binary}, global]).

binary_trim_trailing_slash(B) ->
    case binary:last(B) of
        $/ -> binary_part(B, 0, byte_size(B) - 1);
        _ -> B
    end.

client_id_bin() ->
    case application:get_env(pertisk_eproxy, admin_auth0_client_id) of
        {ok, C} when is_binary(C) -> trim_domain(C);
        {ok, C} when is_list(C) -> trim_domain(unicode:characters_to_binary(C, utf8));
        _ -> undefined
    end.

audience_bin() ->
    case application:get_env(pertisk_eproxy, admin_auth0_audience) of
        {ok, A} when is_binary(A) ->
            T = binary_trim(A),
            case T of <<>> -> undefined; _ -> T end;
        {ok, A} when is_list(A) ->
            T = binary_trim(unicode:characters_to_binary(A, utf8)),
            case T of <<>> -> undefined; _ -> T end;
        _ ->
            undefined
    end.

issuer_bin(Domain) ->
    <<"https://", Domain/binary, "/">>.

%% Optional override when access tokens use a custom-domain 'iss' (defaults to https://<admin_auth0_domain>/).
issuer_for_verify(Domain) ->
    case application:get_env(pertisk_eproxy, admin_auth0_issuer) of
        {ok, I} when is_binary(I), byte_size(I) > 0 ->
            binary_trim_trailing_slash(binary_trim(I));
        {ok, I} when is_list(I) ->
            binary_trim_trailing_slash(binary_trim(unicode:characters_to_binary(I, utf8)));
        _ ->
            issuer_bin(Domain)
    end.

userinfo_audience(Domain) ->
    <<"https://", Domain/binary, "/userinfo">>.

%% ---------------------------------------------------------------------------
%% JWKS cache (named public ets). Do not rely on ets:info/2 for existence — on some paths the name is not
%% registered yet and callers can reach lookup before creation → badarg on ets:lookup. Always try ets:new/2;
%% duplicate name raises badarg (race or already created).
ensure_jwks_cache() ->
    try
        _ = ets:new(?JWKS_CACHE, [named_table, public, set, {read_concurrency, true}])
    catch
        error:badarg ->
            ok
    end,
    ok.

fetch_jwks_json(Domain) ->
    ensure_jwks_cache(),
    Now = erlang:system_time(second),
    case jwks_cache_get(Now) of
        {ok, Body} ->
            {ok, Body};
        miss ->
            case jwks_fail_cached(Now) of
                true ->
                    {error, jwks_unreachable_cached};
                false ->
                    %% global:trans/2 requires Id = {ResourceId, LockRequesterId} (not a bare 3-tuple).
                    case
                        global:trans(
                            {{?MODULE, jwks, Domain}, self()},
                            fun() ->
                                Now2 = erlang:system_time(second),
                                case jwks_cache_get(Now2) of
                                    {ok, Body2} ->
                                        {ok, Body2};
                                    miss ->
                                        Url = "https://" ++ binary_to_list(Domain) ++ "/.well-known/jwks.json",
                                        case httpc_request_get(Url) of
                                            {ok, Body} when is_binary(Body) ->
                                                Ts = erlang:system_time(second),
                                                _ = ets:insert(?JWKS_CACHE, {jwks, Body, Ts}),
                                                _ = ets:delete(?JWKS_CACHE, jwks_fail),
                                                {ok, Body};
                                            Err ->
                                                _ = ets:insert(?JWKS_CACHE, {jwks_fail, erlang:system_time(second)}),
                                                Err
                                        end
                                end
                            end
                        )
                    of
                        aborted ->
                            %% Holder may have populated the cache; try once more without fetching.
                            case jwks_cache_get(erlang:system_time(second)) of
                                {ok, Body3} -> {ok, Body3};
                                miss -> {error, jwks_lock_busy}
                            end;
                        TransRes ->
                            TransRes
                    end
            end
    end.

jwks_cache_get(Now) ->
    ensure_jwks_cache(),
    case ets:lookup(?JWKS_CACHE, jwks) of
        [{jwks, Body, Fetched}] when is_binary(Body), is_integer(Fetched), Now - Fetched < ?JWKS_TTL_SEC ->
            {ok, Body};
        _ ->
            miss
    end.

jwks_fail_cached(Now) ->
    ensure_jwks_cache(),
    case ets:lookup(?JWKS_CACHE, jwks_fail) of
        [{jwks_fail, Ts}] when is_integer(Ts), Now - Ts < ?JWKS_FAIL_CACHE_SEC ->
            true;
        _ ->
            false
    end.

httpc_request_get(Url) ->
    _ = application:ensure_all_started(ssl),
    _ = application:ensure_all_started(inets),
    Req = {Url, []},
    SniHost = jwks_https_hostname(Url),
    HttpOpts =
        [
            %% Keep well under typical browser/proxy patience; slow/unreachable Auth0 should fail fast.
            {timeout, 4500},
            {connect_timeout, 2500},
            {ssl, ssl_opts(SniHost)}
        ],
    case httpc:request(get, Req, HttpOpts, [{body_format, binary}]) of
        {ok, {{_, 200, _}, _Hdrs, Body}} ->
            {ok, Body};
        {ok, {{_, Code, _}, _, Body}} ->
            {error, {jwks_http, Code, Body}};
        {error, Reason} ->
            {error, {jwks_http, Reason}}
    end.

%% @doc TLS for JWKS HTTPS. Auth0 presents wildcard SANs ('*.us.auth0.com'); need HTTPS match_fun + explicit SNI or hostname_check fails (OTP default is stricter than browsers).
jwks_https_hostname(Url0) when is_list(Url0) ->
    jwks_https_hostname(unicode:characters_to_binary(Url0));
jwks_https_hostname(Url) when is_binary(Url) ->
    try
        case uri_string:parse(Url) of
            #{host := Host} when is_binary(Host) ->
                Host;
            #{host := Host} when is_list(Host) ->
                unicode:characters_to_binary(Host, utf8);
            _ ->
                undefined
        end
    catch
        _:_ ->
            undefined
    end;
jwks_https_hostname(_) ->
    undefined.

ssl_opts(SniHost) ->
    %% RFC 6125 wildcard SANs (e.g. tenant.us.auth0.com vs *.us.auth0.com).
    MatchOpts =
        try
            F = public_key:pkix_verify_hostname_match_fun(https),
            [{customize_hostname_check, [{match_fun, F}]}]
        catch
            _:_ ->
                []
        end,
    %% ssl expects server_name_indication as hostname() (string), not binary — binaries trigger {options,...}.
    SniOpts =
        case SniHost of
            H when is_binary(H), byte_size(H) > 0 ->
                [{server_name_indication, unicode:characters_to_list(H, utf8)}];
            _ ->
                []
        end,
    CacertOpts =
        try
            Cs = public_key:cacerts_get(),
            [{cacerts, Cs}]
        catch
            _:_ ->
                []
        end,
    [{verify, verify_peer}, {depth, 5}] ++ SniOpts ++ MatchOpts ++ CacertOpts.

%% ---------------------------------------------------------------------------
verify_jwt_with_jwks(Token, JwksBody, Issuer, ClientId, Audience) ->
    case thoas:decode(JwksBody) of
        {ok, #{<<"keys">> := Keys}} when is_list(Keys) ->
            Kid = header_kid(Token),
            KeyMaps = filter_keys(Keys, Kid),
            try_verify_keys(Token, KeyMaps, Issuer, ClientId, Audience);
        {ok, _} ->
            {error, jwks_no_keys};
        {error, _} = E ->
            E
    end.

header_kid(Token) ->
    try
        Jws = jose_jws:peek_protected(Token),
        case jose_jws:to_map(Jws) of
            {_, H} when is_map(H) ->
                maps:get(<<"kid">>, H, undefined);
            _ ->
                undefined
        end
    catch
        _:_ ->
            undefined
    end.

filter_keys(Keys, undefined) ->
    Keys;
filter_keys(Keys, Kid) when is_binary(Kid) ->
    Matched =
        lists:filter(
            fun(Km) when is_map(Km) ->
                maps:get(<<"kid">>, Km, undefined) =:= Kid;
               (_) ->
                false
            end,
            Keys
        ),
    case Matched of
        [] -> Keys;
        _ -> Matched
    end.

try_verify_keys(_Token, [], _Issuer, _ClientId, _Audience) ->
    {error, jwks_no_matching_key};
try_verify_keys(Token, [KeyMap | Rest], Issuer, ClientId, Audience) ->
    try
        Jwk = jose_jwk:from_map(KeyMap),
        case jose_jwt:verify(Jwk, Token) of
            {true, Jwt, _Jws} ->
                case validate_claims(Jwt, Issuer, ClientId, Audience) of
                    {ok, User, Exp} ->
                        {ok, User, Exp};
                    Err ->
                        Err
                end;
            {false, _, _} ->
                try_verify_keys(Token, Rest, Issuer, ClientId, Audience)
        end
    catch
        _:_ ->
            try_verify_keys(Token, Rest, Issuer, ClientId, Audience)
    end.

validate_claims(Jwt, Issuer, ClientId, Audience) ->
    {_, Fields} = jose_jwt:to_map(Jwt),
    Now = erlang:system_time(second),
    Iss = maps:get(<<"iss">>, Fields, undefined),
    Exp = maps:get(<<"exp">>, Fields, 0),
    Aud = maps:get(<<"aud">>, Fields, undefined),
    ExpAt = exp_unix(Exp),
    ExpOk = ExpAt > (Now - ?EXP_LEEWAY_SEC),
    case {iss_ok(Iss, Issuer), ExpOk, aud_ok(Aud, ClientId, Audience)} of
        {true, true, true} ->
            {ok, username_from_claims(Fields), ExpAt};
        {false, _, _} ->
            {error, bad_issuer};
        {_, false, _} ->
            {error, token_expired};
        {_, _, false} ->
            {error, bad_audience}
    end.

iss_ok(Iss, Issuer) when is_binary(Iss), is_binary(Issuer) ->
    NIss = binary_trim_trailing_slash(Iss),
    NWant = binary_trim_trailing_slash(Issuer),
    NIss =:= NWant;
iss_ok(_, _) ->
    false.

aud_ok(Aud, ClientId, Audience) ->
    Domain = domain_bin(),
    Userinfo =
        case Domain of
            D when is_binary(D) -> userinfo_audience(D);
            _ -> <<>>
        end,
    Expected0 =
        case Audience of
            undefined ->
                [ClientId, Userinfo];
            A ->
                [A, ClientId, Userinfo]
        end,
    Expected = lists:usort(lists:filter(fun(E) -> is_binary(E) andalso byte_size(E) > 0 end, Expected0)),
    NormExpected = lists:usort([norm_aud_str(E) || E <- Expected]),
    AudVals = aud_list(Aud),
    NormAuds = [norm_aud_str(A) || A <- AudVals],
    lists:any(fun(N) -> lists:member(N, NormExpected) end, NormAuds).

%% Auth0 may emit 'aud' with or without a trailing slash vs dashboard "Identifier".
norm_aud_str(B) when is_binary(B) ->
    binary_trim_trailing_slash(B);
norm_aud_str(_) ->
    <<>>.

aud_list(undefined) ->
    [];
aud_list(L) when is_list(L) ->
    lists:filtermap(fun aud_elem/1, L);
aud_list(B) when is_binary(B) ->
    [B];
aud_list(_) ->
    [].

aud_elem(V) when is_binary(V) ->
    case byte_size(V) of
        0 -> false;
        _ -> {true, V}
    end;
aud_elem(V) when is_list(V) ->
    try
        B = unicode:characters_to_binary(V, utf8),
        aud_elem(B)
    catch
        _:_ ->
            false
    end;
aud_elem(_) ->
    false.

%% Normalize JWT 'exp' (JSON number may decode as integer or float).
exp_unix(Exp) when is_integer(Exp) -> Exp;
exp_unix(Exp) when is_float(Exp) -> erlang:round(Exp);
exp_unix(_) -> 0.

username_from_claims(Fields) ->
    case maps:get(<<"email">>, Fields, undefined) of
        E when is_binary(E), byte_size(E) > 0 ->
            E;
        _ ->
            as_bin(maps:get(<<"name">>, Fields, maps:get(<<"sub">>, Fields, <<"user">>)))
    end.

as_bin(V) when is_binary(V) -> V;
as_bin(V) when is_list(V) -> unicode:characters_to_binary(V, utf8);
as_bin(V) -> iolist_to_binary(io_lib:format("~p", [V])).
