%% @doc Optional admin API authentication (local password) and guest mode.

-module(pertisk_eproxy_auth).
-behaviour(gen_server).

-export([start_link/0]).
-export([auth_mode/0, auth_config_map/0, login/2, verify_request/1, verify_token/1, logout/1, refresh/1,
         bearer_from_request/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(TAB, pertisk_eproxy_sessions).

-record(session, {token :: binary(), user :: binary(), exp :: integer()}).

%% ---------------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

auth_mode() ->
    application:get_env(pertisk_eproxy, admin_auth, disabled).

auth_config_map() ->
    Dm = deployment_mode_bin(),
    case pertisk_ingress_env:enabled() of
        true ->
            ingress_auth_config_map(Dm);
        false ->
            proxy_auth_config_map(Dm)
    end.

proxy_auth_config_map(Dm) ->
    case auth_mode() of
        local ->
            SsoCfg = pertisk_eproxy_auth0:auth0_public_config(),
            Base = #{
                <<"supports_local">> => true,
                <<"supports_sso">> => maps:get(<<"supports_sso">>, SsoCfg, false),
                <<"guest_mode">> => false,
                <<"deployment_mode">> => Dm
            },
            M0 = maps:merge(Base, SsoCfg),
            case maps:get(<<"supports_sso">>, M0, false) of
                true ->
                    M0#{<<"mode">> => <<"both">>};
                false ->
                    M0#{<<"mode">> => <<"local">>}
            end;
        _ ->
            #{
                <<"supports_local">> => false,
                <<"supports_sso">> => false,
                <<"guest_mode">> => true,
                <<"mode">> => <<"local">>,
                <<"deployment_mode">> => Dm
            }
    end.

ingress_auth_config_map(Dm) ->
    SupportsLocal = pertisk_eproxy_env_auth:supports_local(),
    SupportsSso = pertisk_eproxy_env_auth:supports_sso(),
    SsoCfg = pertisk_eproxy_auth0:auth0_public_config(),
    ModeBin =
        case pertisk_eproxy_env_auth:auth_mode_atom() of
            local -> <<"local">>;
            sso -> <<"sso">>;
            both -> <<"both">>
        end,
    Base = #{
        <<"mode">> => ModeBin,
        <<"supports_local">> => SupportsLocal,
        <<"supports_sso">> => SupportsSso,
        <<"guest_mode">> => not pertisk_eproxy_env_auth:login_required(),
        <<"deployment_mode">> => Dm
    },
    maps:merge(Base, SsoCfg).

deployment_mode_bin() ->
    C = pertisk_eproxy_config:get_config(),
    case maps:get(mode, C, proxy) of
        proxy -> <<"proxy">>;
        M -> atom_to_binary(M, utf8)
    end.

login(User, Pass) ->
    case auth_mode() of
        local ->
            case ingress_local_login_allowed() of
                false ->
                    {error, login_disabled};
                true ->
                    case use_env_login() of
                        true ->
                            pertisk_eproxy_env_auth:login(User, Pass);
                        false ->
                            sqlite_login(User, Pass)
                    end
            end;
        _ ->
            {error, login_disabled}
    end.

ingress_local_login_allowed() ->
    case pertisk_ingress_env:enabled() of
        true -> pertisk_eproxy_env_auth:supports_local();
        false -> true
    end.

use_env_login() ->
    %% Env credentials are ingress-only; proxy mode should authenticate against SQLite admin_users.
    pertisk_ingress_env:enabled().

sqlite_login(User, Pass) ->
    UBin = as_bin(User),
    PBin = as_bin(Pass),
    DbPath = pertisk_eproxy_config:db_file(),
    case pertisk_eproxy_db:verify_admin_login(DbPath, UBin, PBin) of
        ok ->
            Token = new_token(),
            Exp = erlang:system_time(second) + 86400,
            true = ets:insert(?TAB, #session{token = Token, user = UBin, exp = Exp}),
            {ok, #{token => Token, username => UBin, expires_in => 86400}};
        {error, invalid_credentials} ->
            {error, invalid_credentials};
        {error, sqlite3_executable_not_found} ->
            lager:warning(
                "admin login DB error: sqlite3 CLI not found (install package `sqlite3` and/or set "
                "`{sqlite3_executable, \"/usr/bin/sqlite3\"}` under `pertisk_eproxy` in sys.config "
                "when the VM has a minimal PATH)"
            ),
            {error, invalid_credentials};
        {error, {sqlite3_cli, Msg}} ->
            lager:warning("admin login DB error: sqlite3 shell failed (~s)", [Msg]),
            {error, invalid_credentials};
        {error, Reason} ->
            lager:warning("admin login DB error: ~p", [Reason]),
            {error, invalid_credentials}
    end.

verify_request(Req) ->
    case auth_mode() of
        disabled ->
            ok;
        local ->
            case bearer_from_request(Req) of
                {ok, Token} ->
                    case verify_token(Token) of
                        {ok, _} -> ok;
                        Err -> Err
                    end;
                error ->
                    {error, unauthorized}
            end
    end.

%% @doc Prefer 'Authorization: Bearer', then 'X-Eproxy-Bearer' (raw JWT or 'Bearer …') for reverse proxies that strip Authorization.
-spec bearer_from_request(cowboy_req:req()) -> {ok, binary()} | error.
bearer_from_request(Req) ->
    case cowboy_req:header(<<"authorization">>, Req, <<>>) of
        <<>> ->
            bearer_from_x_eproxy_header(Req);
        _ ->
            case cowboy_req:parse_header(<<"authorization">>, Req) of
                {bearer, T} when is_binary(T), byte_size(T) > 0 ->
                    {ok, T};
                _ ->
                    bearer_from_x_eproxy_header(Req)
            end
    end.

bearer_from_x_eproxy_header(Req) ->
    case cowboy_req:header(<<"x-eproxy-bearer">>, Req) of
        undefined ->
            error;
        <<>> ->
            error;
        Raw when is_binary(Raw) ->
            Stripped = trim_bin(Raw),
            case strip_bearer_prefix(Stripped) of
                <<>> -> error;
                T -> {ok, T}
            end;
        _ ->
            error
    end.

trim_bin(B) when is_binary(B) ->
    re:replace(B, <<"^\\s+|\\s+$">>, <<>>, [{return, binary}, global]).

strip_bearer_prefix(<<"Bearer ", R/binary>>) -> trim_bin(R);
strip_bearer_prefix(<<"bearer ", R/binary>>) -> trim_bin(R);
strip_bearer_prefix(B) -> trim_bin(B).

verify_token(Token) when is_binary(Token) ->
    try
        verify_token_uncaught(Token)
    catch
        Class:Reason ->
            lager:warning("verify_token unexpected ~p:~p", [Class, Reason]),
            {error, unauthorized}
    end;
verify_token(_) ->
    {error, unauthorized}.

verify_token_uncaught(Token) when is_binary(Token) ->
    Now = erlang:system_time(second),
    case ets:lookup(?TAB, Token) of
        [#session{exp = Exp, user = U}] when Exp > Now ->
            {ok, U};
        _ ->
            case verify_env_or_sso_token(Token) of
                {ok, U} ->
                    {ok, U};
                {error, _} ->
                    {error, unauthorized}
            end
    end.

verify_env_or_sso_token(Token) ->
    case pertisk_eproxy_env_auth:verify_api_token(Token) of
        {ok, U, _} ->
            {ok, U};
        error ->
            case is_stateless_bearer_token(Token) of
                true ->
                    case pertisk_eproxy_env_auth:verify_bearer_token(Token) of
                        {ok, U, _} -> {ok, U};
                        {error, _} -> verify_auth0_token(Token)
                    end;
                false ->
                    case is_local_session_token(Token) of
                        true ->
                            {error, unauthorized};
                        false ->
                            verify_auth0_token(Token)
                    end
            end
    end.

verify_auth0_token(Token) ->
    case pertisk_eproxy_auth0:verify_bearer(Token) of
        {ok, User, _Exp} ->
            {ok, User};
        _ ->
            {error, unauthorized}
    end.

logout(Token) when is_binary(Token) ->
    ets:delete(?TAB, Token),
    ok;
logout(_) ->
    ok.

refresh(Token) when is_binary(Token) ->
    try
        refresh_uncaught(Token)
    catch
        Class:Reason ->
            lager:warning("refresh unexpected ~p:~p", [Class, Reason]),
            {error, unauthorized}
    end;
refresh(_) ->
    {error, unauthorized}.

refresh_uncaught(Token) when is_binary(Token) ->
    Now = erlang:system_time(second),
    case ets:lookup(?TAB, Token) of
        [#session{user = U, exp = OldExp} = S] when OldExp > Now ->
            Exp = Now + 86400,
            true = ets:insert(?TAB, S#session{exp = Exp}),
            {ok, #{token => Token, username => U, expires_in => 86400}};
        _ ->
            case is_stateless_bearer_token(Token) of
                true ->
                    case pertisk_eproxy_env_auth:verify_bearer_token(Token) of
                        {ok, U, _} ->
                            pertisk_eproxy_env_auth:issue_bearer_token(U);
                        {error, _} ->
                            {error, unauthorized}
                    end;
                false ->
                    case is_local_session_token(Token) of
                        true ->
                            {error, unauthorized};
                        false ->
                            case pertisk_eproxy_auth0:verify_bearer(Token) of
                                {ok, U, ExpAt} when ExpAt > (Now - 90) ->
                                    TTL = max(30, min(86400, ExpAt - Now)),
                                    {ok, #{token => Token, username => U, expires_in => TTL}};
                                _ ->
                                    {error, unauthorized}
                            end
                    end
            end
    end.

%% ---------------------------------------------------------------------------
init([]) ->
    _ = ets:new(?TAB, [named_table, set, public, {keypos, 2}]),
    {ok, #{}}.

handle_call(_Req, _From, St) ->
    {reply, ok, St}.

handle_cast(_Msg, St) ->
    {noreply, St}.

handle_info(_Info, St) ->
    {noreply, St}.

terminate(_Reason, _St) -> ok.
code_change(_OldVsn, St, _Extra) -> {ok, St}.

new_token() ->
    Hex = binary:encode_hex(crypto:strong_rand_bytes(16), lowercase),
    <<"ept_", Hex/binary>>.

%% Opaque local login tokens (not JWTs); avoids Auth0 JWKS when session expired or node restarted.
is_local_session_token(<<"ept_", _/binary>>) -> true;
is_local_session_token(_) -> false.

%% Stateless ingress bearer ('ptskv1.…') for multi-replica admin auth.
is_stateless_bearer_token(<<"ptskv1.", _/binary>>) -> true;
is_stateless_bearer_token(_) -> false.

as_bin(V) when is_binary(V) -> V;
as_bin(V) when is_list(V) -> unicode:characters_to_binary(V, utf8);
as_bin(V) -> iolist_to_binary(io_lib:format("~p", [V])).
