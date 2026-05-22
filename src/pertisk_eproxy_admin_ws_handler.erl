%% @doc Admin realtime websocket stream for the SPA.
-module(pertisk_eproxy_admin_ws_handler).
-behaviour(cowboy_websocket).

-export([init/2]).
-export([websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

-define(TICK_MS, 2000).
-define(IDLE_TIMEOUT_MS, 60000).
-define(AUTH_TIMEOUT_MS, 5000).

init(Req, _State) ->
    case authorize(Req) of
        ok ->
            log_ws_upgrade(Req),
            {cowboy_websocket, Req, #{authenticated => true}, #{idle_timeout => ?IDLE_TIMEOUT_MS}};
        pending_auth ->
            log_ws_upgrade(Req),
            {cowboy_websocket, Req, #{authenticated => false}, #{idle_timeout => ?IDLE_TIMEOUT_MS}};
        {error, unauthorized} ->
            Req2 = cowboy_req:reply(
                401,
                pertisk_eproxy_response_headers:merge(#{<<"content-type">> => <<"application/json">>}),
                <<"{\"error\":\"Unauthorized\"}">>,
                Req
            ),
            {ok, Req2, #{}}
    end.

websocket_init(State = #{authenticated := true}) ->
    ok = pertisk_eproxy_admin_realtime:subscribe(self()),
    TRef = erlang:send_after(?TICK_MS, self(), tick),
    Msg = snapshot_json(),
    {[{text, Msg}], State#{timer_ref => TRef}};

websocket_init(State = #{authenticated := false}) ->
    AuthRef = erlang:send_after(?AUTH_TIMEOUT_MS, self(), auth_timeout),
    {ok, State#{auth_ref => AuthRef}}.

websocket_handle({text, Bin}, State = #{authenticated := false}) when is_binary(Bin) ->
    case auth_token_from_frame(Bin) of
        {ok, Token} ->
            case pertisk_eproxy_auth:verify_token(Token) of
                {ok, _User} ->
                    State1 = cancel_auth_timer(State#{authenticated => true}),
                    ok = pertisk_eproxy_admin_realtime:subscribe(self()),
                    TRef = erlang:send_after(?TICK_MS, self(), tick),
                    Msg = snapshot_json(),
                    {[{text, Msg}], State1#{timer_ref => TRef}};
                {error, _} ->
                    {[{close, 4401, <<"Unauthorized">>}], State}
            end;
        error ->
            {[{close, 4401, <<"Unauthorized">>}], State}
    end;
websocket_handle(_Frame, State = #{authenticated := false}) ->
    {ok, State};
websocket_handle(_Frame, State) ->
    {ok, State}.

websocket_info({admin_ws_push, Bin}, State = #{authenticated := true}) when is_binary(Bin) ->
    {[{text, Bin}], State};
websocket_info(tick, State = #{authenticated := true}) ->
    Msg = snapshot_json(),
    TRef = erlang:send_after(?TICK_MS, self(), tick),
    {[{text, Msg}], State#{timer_ref => TRef}};
websocket_info(auth_timeout, State = #{authenticated := false}) ->
    {[{close, 4401, <<"Unauthorized">>}], State};
websocket_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _Req, State) ->
    %% Dispatch passes route opts (atom `realtime`) as State if upgrade aborted early — only treat maps as WS state.
    _ = catch pertisk_eproxy_admin_realtime:unsubscribe(self()),
    case State of
        #{timer_ref := TRef} -> erlang:cancel_timer(TRef);
        _ -> ok
    end,
    ok.

authorize(Req) ->
    case pertisk_eproxy_auth:auth_mode() of
        disabled ->
            ok;
        local ->
            case pertisk_eproxy_auth:bearer_from_request(Req) of
                {ok, Token} ->
                    case pertisk_eproxy_auth:verify_token(Token) of
                        {ok, _User} -> ok;
                        {error, _} -> {error, unauthorized}
                    end;
                error ->
                    pending_auth
            end
    end.

auth_token_from_frame(Bin) when is_binary(Bin) ->
    case thoas:decode(Bin) of
        {ok, M} when is_map(M) ->
            case {maps:get(<<"type">>, M, undefined), maps:get(<<"token">>, M, undefined)} of
                {<<"auth">>, Token} when is_binary(Token), byte_size(Token) > 0 ->
                    {ok, Token};
                _Other ->
                    error
            end;
        _ ->
            error
    end.

cancel_auth_timer(State = #{auth_ref := Ref}) ->
    _ = erlang:cancel_timer(Ref),
    maps:remove(auth_ref, State);
cancel_auth_timer(State) ->
    State.

snapshot_json() ->
    Data = #{
        <<"stats">> => pertisk_eproxy_stats:snapshot(),
        <<"management">> => pertisk_eproxy_admin_management_snapshot:snapshot(),
        <<"logs">> => pertisk_eproxy_access_log:list(undefined, undefined),
        <<"certificates">> => certificate_rows(),
        <<"ssl_jobs">> => pertisk_eproxy_admin_realtime:ssl_jobs_snapshot()
    },
    thoas:encode(Data).

certificate_rows() ->
    case pertisk_eproxy_db:list_certificates(db_file_path()) of
        {ok, Certs} ->
            [#{
                <<"id">> => integer_to_binary(maps:get(id, C)),
                <<"hosts">> => [json_text(maps:get(name, C, <<>>))],
                <<"source_type">> => json_text(maps:get(source_type, C, <<"acme">>)),
                <<"challenge">> => challenge_for_source(maps:get(source_type, C, <<"acme">>))
             } || C <- Certs];
        _ ->
            []
    end.

challenge_for_source(Src0) ->
    Src = json_text(Src0),
    case Src of
        <<"imported_pem">> -> <<"imported PEM">>;
        _ -> <<"acme">>
    end.

db_file_path() ->
    case application:get_env(pertisk_eproxy, db_file) of
        {ok, F} when is_list(F) -> F;
        {ok, F} when is_binary(F) -> binary_to_list(F);
        _ -> "data/proxy.db"
    end.

json_text(V) when is_binary(V) -> V;
json_text(V) when is_list(V) -> list_to_binary(V);
json_text(V) -> iolist_to_binary(io_lib:format("~p", [V])).

log_ws_upgrade(Req) ->
    Host = cowboy_req:host(Req),
    Path = cowboy_req:path(Req),
    Proto = cowboy_req:version(Req),
    pertisk_eproxy_access_log:log_proxy(Host, <<"GET">>, Path, 101, 0, Proto, <<"management">>),
    ok.
