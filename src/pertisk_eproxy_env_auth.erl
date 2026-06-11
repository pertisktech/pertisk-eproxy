%% @doc Ingress admin auth from environment (PERTISK_ADMIN / PERTISK_PASSWORD).
%% Stateless signed bearer tokens ('ptskv1.…') work across replicas without SQLite.
-module(pertisk_eproxy_env_auth).

-export([
    configure/0,
    auth_mode_atom/0,
    supports_local/0,
    supports_sso/0,
    login_required/0,
    env_credentials_configured/0,
    login/2,
    issue_bearer_token/1,
    verify_bearer_token/1,
    verify_api_token/1,
    session_ttl_secs/0
]).

-define(TOKEN_PREFIX, <<"ptskv1">>).

%% ---------------------------------------------------------------------------
%% Startup (ingress mode)
%% ---------------------------------------------------------------------------

-spec configure() -> ok.
configure() ->
    set_auth0_from_env(),
    Mode = parse_auth_mode(os:getenv("PERTISK_AUTH_MODE"), both),
    application:set_env(pertisk_eproxy, ingress_auth_mode, Mode),
    HasLocal = env_credentials_configured(),
    HasSso = auth0_configured(),
    SupportsLocal = HasLocal andalso mode_allows_local(Mode),
    SupportsSso = HasSso andalso mode_allows_sso(Mode),
    application:set_env(pertisk_eproxy, ingress_supports_local, SupportsLocal),
    application:set_env(pertisk_eproxy, ingress_supports_sso, SupportsSso),
    case SupportsLocal orelse SupportsSso of
        true ->
            application:set_env(pertisk_eproxy, admin_auth, local),
            lager:info(
                "Ingress mode: admin login enabled (local=~p, sso=~p, mode=~p)",
                [SupportsLocal, SupportsSso, Mode]
            );
        false ->
            application:set_env(pertisk_eproxy, admin_auth, disabled),
            lager:warning(
                "Ingress mode: admin login not configured "
                "(set PERTISK_ADMIN/PERTISK_PASSWORD and/or Auth0 env vars)"
            )
    end,
    ok.

auth_mode_atom() ->
    application:get_env(pertisk_eproxy, ingress_auth_mode, both).

supports_local() ->
    application:get_env(pertisk_eproxy, ingress_supports_local, false).

supports_sso() ->
    application:get_env(pertisk_eproxy, ingress_supports_sso, false).

login_required() ->
    supports_local() orelse supports_sso().

env_credentials_configured() ->
    case {env_trimmed("PERTISK_ADMIN"), env_trimmed("PERTISK_PASSWORD")} of
        {U, P} when is_binary(U), byte_size(U) > 0, is_binary(P), byte_size(P) > 0 ->
            true;
        _ ->
            false
    end.

%% ---------------------------------------------------------------------------
%% Login / tokens
%% ---------------------------------------------------------------------------

-spec login(term(), term()) -> {ok, map()} | {error, term()}.
login(User, Pass) ->
    case env_credentials_configured() of
        false ->
            {error, env_not_configured};
        true ->
            UBin = as_bin(User),
            PBin = as_bin(Pass),
            case {env_trimmed("PERTISK_ADMIN"), env_trimmed("PERTISK_PASSWORD")} of
                {UBin, PBin} ->
                    issue_bearer_token(UBin);
                _ ->
                    {error, invalid_credentials}
            end
    end.

-spec issue_bearer_token(binary()) -> {ok, map()} | {error, term()}.
issue_bearer_token(Username) when is_binary(Username) ->
    case signing_secret() of
        undefined ->
            {error, signing_secret_not_configured};
        _Secret ->
            Ttl = session_ttl_secs(),
            Exp = erlang:system_time(second) + Ttl,
            Payload = #{<<"sub">> => Username, <<"exp">> => Exp},
            PayloadBin = thoas:encode(Payload),
            PayloadB64 = jose_jwa_base64url:encode(PayloadBin),
            Sig = crypto:mac(hmac, sha256, signing_secret(), PayloadB64),
            SigB64 = jose_jwa_base64url:encode(Sig),
            Token = <<?TOKEN_PREFIX/binary, ".", PayloadB64/binary, ".", SigB64/binary>>,
            {ok, #{token => Token, username => Username, expires_in => Ttl}}
    end.

-spec verify_bearer_token(binary()) -> {ok, binary(), non_neg_integer()} | {error, term()}.
verify_bearer_token(<<"ptskv1.", Rest/binary>>) ->
    case signing_secret() of
        undefined ->
            {error, unauthorized};
        Secret ->
            case binary:split(Rest, <<".">>, []) of
                [PayloadB64, SigB64] ->
                    Expected = crypto:mac(hmac, sha256, Secret, PayloadB64),
                    ExpectedB64 = jose_jwa_base64url:encode(Expected),
                    case crypto:hash_equals(SigB64, ExpectedB64) of
                        true ->
                            decode_and_check_claims(PayloadB64);
                        false ->
                            {error, unauthorized}
                    end;
                _ ->
                    {error, unauthorized}
            end
    end;
verify_bearer_token(_) ->
    {error, unauthorized}.

-spec verify_api_token(binary()) -> {ok, binary(), non_neg_integer()} | error.
verify_api_token(Token) when is_binary(Token) ->
    case env_trimmed("PERTISK_API_TOKEN") of
        Api when is_binary(Api), byte_size(Api) > 0 ->
            case crypto:hash_equals(Api, Token) of
                true -> {ok, <<"api">>, session_ttl_secs()};
                false -> error
            end;
        _ ->
            error
    end;
verify_api_token(_) ->
    error.

session_ttl_secs() ->
    case os:getenv("PERTISK_SESSION_TTL_SECS") of
        false ->
            86400;
        V ->
            case string:to_integer(string:trim(V)) of
                {T, []} when T > 0 -> T;
                _ -> 86400
            end
    end.

%% ---------------------------------------------------------------------------
%% Internals
%% ---------------------------------------------------------------------------

decode_and_check_claims(PayloadB64) ->
    try
        PayloadBin = jose_jwa_base64url:decode(PayloadB64),
        case thoas:decode(PayloadBin) of
            {ok, #{<<"sub">> := Sub, <<"exp">> := Exp}}
                when is_binary(Sub), is_integer(Exp) ->
                Now = erlang:system_time(second),
                if
                    Exp > Now ->
                        {ok, Sub, max(0, Exp - Now)};
                    true ->
                        {error, unauthorized}
                end;
            {error, _} ->
                {error, unauthorized};
            _ ->
                {error, unauthorized}
        end
    catch
        _:_ -> {error, unauthorized}
    end.

signing_secret() ->
    case env_trimmed("PERTISK_AUTH_SIGNING_SECRET") of
        S when is_binary(S), byte_size(S) > 0 ->
            S;
        _ ->
            env_trimmed("PERTISK_PASSWORD")
    end.

set_auth0_from_env() ->
    maps:foreach(
        fun(Env, AppKey) ->
            case env_trimmed(Env) of
                V when is_binary(V), byte_size(V) > 0 ->
                    application:set_env(pertisk_eproxy, AppKey, V);
                _ ->
                    ok
            end
        end,
        #{
            "PERTISK_AUTH0_DOMAIN" => admin_auth0_domain,
            "PERTISK_AUTH0_CLIENT_ID" => admin_auth0_client_id,
            "PERTISK_AUTH0_AUDIENCE" => admin_auth0_audience,
            "PERTISK_AUTH0_ISSUER" => admin_auth0_issuer
        }
    ).

auth0_configured() ->
    case pertisk_eproxy_auth0:auth0_public_config() of
        #{<<"supports_sso">> := true} -> true;
        _ -> false
    end.

parse_auth_mode(false, Default) -> Default;
parse_auth_mode(V, Default) when is_list(V) ->
    case string:lowercase(string:trim(V)) of
        "local" -> local;
        "sso" -> sso;
        "auth0" -> sso;
        "both" -> both;
        _ -> Default
    end.

mode_allows_local(local) -> true;
mode_allows_local(both) -> true;
mode_allows_local(_) -> false.

mode_allows_sso(sso) -> true;
mode_allows_sso(both) -> true;
mode_allows_sso(_) -> false.

env_trimmed(Name) ->
    case os:getenv(Name) of
        false ->
            undefined;
        V ->
            T = string:trim(V),
            case T of
                "" -> undefined;
                _ -> unicode:characters_to_binary(T, utf8)
            end
    end.

as_bin(V) when is_binary(V) -> V;
as_bin(V) when is_list(V) -> unicode:characters_to_binary(V, utf8);
as_bin(V) -> iolist_to_binary(io_lib:format("~p", [V])).
