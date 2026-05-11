%% @doc Admin realtime websocket stream for the SPA.
-module(pertisk_eproxy_admin_ws_handler).
-behaviour(cowboy_websocket).

-export([init/2]).
-export([websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

-define(TICK_MS, 2000).
-define(IDLE_TIMEOUT_MS, 60000).

init(Req, _State) ->
    case authorize(Req) of
        ok ->
            log_ws_upgrade(Req),
            {cowboy_websocket, Req, #{}, #{idle_timeout => ?IDLE_TIMEOUT_MS}};
        {error, unauthorized} ->
            Req2 = cowboy_req:reply(401, #{<<"content-type">> => <<"application/json">>},
                                    <<"{\"error\":\"Unauthorized\"}">>, Req),
            {ok, Req2, #{}}
    end.

websocket_init(State) ->
    TRef = erlang:send_after(?TICK_MS, self(), tick),
    Msg = snapshot_json(),
    {[{text, Msg}], State#{timer_ref => TRef}}.

websocket_handle(_Frame, State) ->
    {ok, State}.

websocket_info(tick, State) ->
    Msg = snapshot_json(),
    TRef = erlang:send_after(?TICK_MS, self(), tick),
    {[{text, Msg}], State#{timer_ref => TRef}};
websocket_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _Req, State) ->
    case maps:get(timer_ref, State, undefined) of
        undefined -> ok;
        TRef -> erlang:cancel_timer(TRef), ok
    end.

authorize(Req) ->
    case pertisk_eproxy_auth:auth_mode() of
        disabled ->
            ok;
        local ->
            Qs = maps:from_list(cowboy_req:parse_qs(Req)),
            case maps:get(<<"token">>, Qs, <<>>) of
                <<>> ->
                    {error, unauthorized};
                Token ->
                    case pertisk_eproxy_auth:verify_token(Token) of
                        {ok, _User} -> ok;
                        {error, _} -> {error, unauthorized}
                    end
            end
    end.

snapshot_json() ->
    Data = #{
        <<"stats">> => pertisk_eproxy_stats:snapshot(),
        <<"management">> => management_info(),
        <<"logs">> => pertisk_eproxy_access_log:list(undefined, undefined),
        <<"certificates">> => certificate_rows()
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

management_info() ->
    C = pertisk_eproxy_config:get_config(),
    HttpPort = maps:get(http_port, C, 8080),
    MgmtPort = maps:get(management_port, C, 9080),
    MgmtAddr = maps:get(management_addr, C, {127, 0, 0, 1}),
    Mode0 = maps:get(mode, C, proxy_admin),
    ModeBin = case Mode0 of
        proxy_admin -> <<"proxy">>;
        proxy -> <<"proxy">>;
        M -> atom_to_binary(M, utf8)
    end,
    HttpsAddr = case maps:find(https_port, C) of
        {ok, Hp} -> iolist_to_binary(io_lib:format("0.0.0.0:~w", [Hp]));
        _ -> <<>>
    end,
    TlsInfoBeam = case code:which(pertisk_eproxy_tls_cert_info) of
        Path when is_list(Path) -> list_to_binary(Path);
        _ -> <<>>
    end,
    #{
        <<"version">> => app_version(),
        <<"mode">> => ModeBin,
        <<"http_addr">> => iolist_to_binary(io_lib:format("0.0.0.0:~w", [HttpPort])),
        <<"https_addr">> => HttpsAddr,
        <<"management_addr">> => iolist_to_binary([inet:ntoa(MgmtAddr), $:, integer_to_list(MgmtPort)]),
        <<"db_path">> => iolist_to_binary(db_file_path()),
        <<"http_versions">> => [<<"1.1">>, <<"2">>],
        <<"loaded_tls_cert_info_beam">> => TlsInfoBeam
    }.

app_version() ->
    case application:get_key(pertisk_eproxy, vsn) of
        {ok, V} when is_list(V) -> list_to_binary(V);
        {ok, V} when is_binary(V) -> V;
        _ -> <<"0.1.0">>
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
    pertisk_eproxy_access_log:log_proxy(Host, <<"GET">>, Path, 101, 0, Proto),
    ok.
