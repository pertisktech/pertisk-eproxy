%% @doc Optional admin API authentication (local password) and guest mode.

-module(pertisk_eproxy_auth).
-behaviour(gen_server).

-export([start_link/0]).
-export([auth_mode/0, auth_config_map/0, login/2, verify_request/1, verify_token/1, logout/1, refresh/1]).
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
    case auth_mode() of
        local ->
            #{
                <<"supports_local">> => true,
                <<"supports_sso">> => false,
                <<"guest_mode">> => false,
                <<"mode">> => <<"local">>
            };
        _ ->
            #{
                <<"supports_local">> => false,
                <<"supports_sso">> => false,
                <<"guest_mode">> => true,
                <<"mode">> => <<"local">>
            }
    end.

login(User, Pass) ->
    case auth_mode() of
        local ->
            Expected = application:get_env(pertisk_eproxy, admin_password, <<"admin">>),
            UBin = as_bin(User),
            PBin = as_bin(Pass),
            case PBin =:= Expected of
                true ->
                    Token = new_token(),
                    Exp = erlang:system_time(second) + 86400,
                    true = ets:insert(?TAB, #session{token = Token, user = UBin, exp = Exp}),
                    {ok, #{token => Token, username => UBin, expires_in => 86400}};
                false ->
                    {error, invalid_credentials}
            end;
        _ ->
            {error, login_disabled}
    end.

verify_request(Req) ->
    case auth_mode() of
        disabled ->
            ok;
        local ->
            case cowboy_req:parse_header(<<"authorization">>, Req) of
                {bearer, Token} ->
                    verify_token(Token);
                _ ->
                    {error, unauthorized}
            end
    end.

verify_token(Token) when is_binary(Token) ->
    Now = erlang:system_time(second),
    case ets:lookup(?TAB, Token) of
        [#session{exp = Exp, user = U}] when Exp > Now ->
            {ok, U};
        _ ->
            {error, unauthorized}
    end;
verify_token(_) ->
    {error, unauthorized}.

logout(Token) when is_binary(Token) ->
    ets:delete(?TAB, Token),
    ok;
logout(_) ->
    ok.

refresh(Token) when is_binary(Token) ->
    Now = erlang:system_time(second),
    case ets:lookup(?TAB, Token) of
        [#session{user = U, exp = OldExp} = S] when OldExp > Now ->
            Exp = Now + 86400,
            true = ets:insert(?TAB, S#session{exp = Exp}),
            {ok, #{token => Token, username => U, expires_in => 86400}};
        _ ->
            {error, unauthorized}
    end;
refresh(_) ->
    {error, unauthorized}.

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

as_bin(V) when is_binary(V) -> V;
as_bin(V) when is_list(V) -> unicode:characters_to_binary(V, utf8);
as_bin(V) -> iolist_to_binary(io_lib:format("~p", [V])).
