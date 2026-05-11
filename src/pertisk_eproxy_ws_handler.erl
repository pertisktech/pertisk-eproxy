%% @doc WebSocket reverse proxy handler for pertisk_eproxy.
%%
%% Upgraded when pertisk_eproxy_handler detects an `Upgrade: websocket` header.
%% The handler:
%%   1. Connects to the upstream via gun with a WebSocket upgrade.
%%   2. Bridges frames in both directions until either side closes.
%%
%% Uses cowboy_websocket on the client side and gun on the upstream side.

-module(pertisk_eproxy_ws_handler).
-behaviour(cowboy_websocket).

-export([init/2]).
-export([websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

-define(CONNECT_TIMEOUT, 10000).

%% Called from pertisk_eproxy_handler when a WebSocket upgrade is detected.
init(Req, _State) ->
    Host    = cowboy_req:host(Req),
    Path    = cowboy_req:path(Req),
    Qs      = cowboy_req:qs(Req),
    ClientIp = client_ip(Req),

    case pertisk_eproxy_router:route(Host, Path) of
        {error, no_route} ->
            Req2 = cowboy_req:reply(404, #{}, <<"No route">>, Req),
            {ok, Req2, #{}};
        {ok, #{upstream_path := UpPath, backend := BackendName}} ->
            case pertisk_eproxy_backend:pick_upstream(BackendName, ClientIp) of
                {error, no_healthy_upstream} ->
                    Req2 = cowboy_req:reply(502, #{}, <<"No upstream">>, Req),
                    {ok, Req2, #{}};
                {ok, UpstreamAddr} ->
                    FullPath = case Qs of
                        <<>> -> UpPath;
                        _    -> <<UpPath/binary, "?", Qs/binary>>
                    end,
                    WsState = #{
                        host          => Host,
                        backend       => BackendName,
                        upstream_addr => UpstreamAddr,
                        upstream_path => FullPath,
                        conn_pid      => undefined,
                        stream_ref    => undefined
                    },
                    %% Upgrade the cowboy connection to WebSocket.
                    {cowboy_websocket, Req, WsState,
                     #{idle_timeout => 300000}}
            end
    end.

websocket_init(State = #{upstream_addr := UpAddr, upstream_path := UpPath, host := Host}) ->
    {UpHost, UpPort, Transport} = parse_upstream(UpAddr),
    GunOpts = #{transport => Transport, protocols => [http]},
    case gun:open(UpHost, UpPort, GunOpts) of
        {ok, ConnPid} ->
            case gun:await_up(ConnPid, ?CONNECT_TIMEOUT) of
                {ok, _} ->
                    Headers = [{<<"host">>, Host}],
                    StreamRef = gun:ws_upgrade(ConnPid, UpPath, Headers),
                    {ok, State#{conn_pid => ConnPid, stream_ref => StreamRef}};
                {error, Reason} ->
                    lager:warning("WS upstream connect failed: ~p", [Reason]),
                    gun:close(ConnPid),
                    {stop, State}
            end;
        {error, Reason} ->
            lager:warning("WS upstream open failed: ~p", [Reason]),
            {stop, State}
    end.

%% Frame from client → forward to upstream.
websocket_handle(Frame, State = #{conn_pid := ConnPid, stream_ref := SRef})
    when ConnPid =/= undefined ->
    gun:ws_send(ConnPid, SRef, Frame),
    {ok, State};
websocket_handle(_Frame, State) ->
    {ok, State}.

%% Message from gun (upstream) → forward to client, or handle close/errors.
websocket_info({gun_ws, _ConnPid, _SRef, Frame}, State) ->
    {[Frame], State};

websocket_info({gun_ws, _ConnPid, _SRef, close}, State) ->
    {[close], State};

websocket_info({gun_upgrade, _ConnPid, _SRef, [<<"websocket">>], _Headers}, State) ->
    %% Upgrade to upstream WS confirmed.
    {ok, State};

websocket_info({gun_error, _ConnPid, _SRef, Reason}, State) ->
    lager:warning("WS upstream error: ~p", [Reason]),
    {[close], State};

websocket_info({gun_down, _ConnPid, _Proto, Reason, _Killed}, State) ->
    lager:info("WS upstream down: ~p", [Reason]),
    {[close], State};

websocket_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _Req, #{conn_pid := ConnPid, backend := BackendName,
                             upstream_addr := Addr})
    when ConnPid =/= undefined ->
    gun:close(ConnPid),
    pertisk_eproxy_backend:done_upstream(BackendName, Addr, ok),
    ok;
terminate(_Reason, _Req, _State) ->
    ok.

%% -------------------------------------------------------------------------
%% Helpers
%% -------------------------------------------------------------------------

client_ip(Req) ->
    case cowboy_req:header(<<"x-forwarded-for">>, Req) of
        undefined ->
            {PeerIp, _} = cowboy_req:peer(Req),
            list_to_binary(inet:ntoa(PeerIp));
        XFF ->
            hd(binary:split(XFF, [<<", ">>, <<",">>]))
    end.

parse_upstream(Addr) when is_binary(Addr) ->
    parse_upstream(binary_to_list(Addr));
parse_upstream("https://" ++ Rest) ->
    {Host, Port} = split_host_port(Rest, 443),
    {Host, Port, tls};
parse_upstream("http://" ++ Rest) ->
    {Host, Port} = split_host_port(Rest, 80),
    {Host, Port, tcp};
parse_upstream(Addr) ->
    {Host, Port} = split_host_port(Addr, 80),
    {Host, Port, tcp}.

split_host_port(Addr, Default) ->
    case string:split(Addr, ":", trailing) of
        [Host, PortStr] -> {Host, list_to_integer(string:trim(PortStr, trailing, "/"))};
        [Host]          -> {Host, Default}
    end.
