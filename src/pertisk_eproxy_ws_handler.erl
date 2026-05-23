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
%% Gun keeps protocol=gun_http until the WS handshake finishes; ws_send goes to gun_ws only after.
-define(MAX_WS_OUT_BUFFER, 64).

%% Called from pertisk_eproxy_handler when a WebSocket upgrade is detected.
init(Req, _State) ->
    Host    = cowboy_req:host(Req),
    Path    = cowboy_req:path(Req),
    Qs      = cowboy_req:qs(Req),
    ClientIp = client_ip(Req),

    case pertisk_eproxy_router:route(Host, Path) of
        {error, no_route} ->
            lager:warning("WS no route for host=~s path=~s", [Host, Path]),
            Req2 = cowboy_req:reply(404, pertisk_eproxy_response_headers:merge(#{}), <<"No route">>, Req),
            {ok, Req2, #{}};
        {ok, #{upstream_path := UpPath, backend := BackendName}} ->
            case pertisk_eproxy_backend:pick_upstream(BackendName, ClientIp) of
                {error, no_healthy_upstream} ->
                    lager:warning(
                        "WS no healthy upstream for backend=~s host=~s path=~s",
                        [BackendName, Host, Path]
                    ),
                    Req2 = cowboy_req:reply(502, pertisk_eproxy_response_headers:merge(#{}), <<"No upstream">>, Req),
                    {ok, Req2, #{}};
                {ok, UpstreamAddr} ->
                    FullPath = case Qs of
                        <<>> -> UpPath;
                        _    -> <<UpPath/binary, "?", Qs/binary>>
                    end,
                    WsHeaders = ws_forward_headers(Req, Host, ClientIp, FullPath),
                    ReqWs = maybe_set_ws_subprotocol(Req),
                    WsState = #{
                        host                => Host,
                        backend             => BackendName,
                        upstream_addr       => UpstreamAddr,
                        upstream_path       => FullPath,
                        ws_headers          => WsHeaders,
                        conn_pid            => undefined,
                        stream_ref          => undefined,
                        upstream_ws_ready   => false,
                        ws_out_buffer       => []
                    },
                    %% Upgrade the cowboy connection to WebSocket.
                    {cowboy_websocket, pertisk_eproxy_response_headers:apply_cowboy_req(ReqWs),
                        WsState, #{idle_timeout => 300000}}
            end
    end.

websocket_init(State = #{upstream_addr := UpAddr, upstream_path := UpPath, ws_headers := Headers}) ->
    {UpHost, UpPort, Transport} = pertisk_eproxy_handler:parse_upstream(UpAddr),
    GunOpts = ws_gun_opts(UpHost, Transport),
    HasCookie = lists:keymember(<<"cookie">>, 1, Headers),
    HasProto = lists:keymember(<<"sec-websocket-protocol">>, 1, Headers),
    HasOrigin = lists:keymember(<<"origin">>, 1, Headers),
    lager:info(
        "WS upstream opening host=~s port=~p upstream=~s path=~s cookie=~p subproto=~p origin=~p",
        [UpHost, UpPort, UpAddr, UpPath, HasCookie, HasProto, HasOrigin]
    ),
    case gun:open(UpHost, UpPort, GunOpts) of
        {ok, ConnPid} ->
            case gun:await_up(ConnPid, ?CONNECT_TIMEOUT) of
                {ok, _} ->
                    StreamRef = gun:ws_upgrade(ConnPid, UpPath, Headers),
                    {ok, State#{
                        conn_pid => ConnPid,
                        stream_ref => StreamRef,
                        upstream_ws_ready => false,
                        ws_out_buffer => []
                    }};
                {error, Reason} ->
                    lager:warning(
                        "WS upstream connect failed host=~s port=~p upstream=~s path=~s reason=~p",
                        [UpHost, UpPort, UpAddr, UpPath, Reason]
                    ),
                    gun:close(ConnPid),
                    {stop, State}
            end;
        {error, Reason} ->
            lager:warning(
                "WS upstream open failed host=~s port=~p upstream=~s path=~s reason=~p",
                [UpHost, UpPort, UpAddr, UpPath, Reason]
            ),
            {stop, State}
    end.

%% Frame from client → forward to upstream (only after Gun has switched to gun_ws).
websocket_handle(Frame, State = #{conn_pid := ConnPid, stream_ref := SRef, upstream_ws_ready := true})
    when ConnPid =/= undefined ->
    gun:ws_send(ConnPid, SRef, Frame),
    {ok, State};
websocket_handle(Frame, State = #{conn_pid := ConnPid, ws_out_buffer := Buf})
    when ConnPid =/= undefined ->
    case length(Buf) >= ?MAX_WS_OUT_BUFFER of
        true ->
            lager:warning("WS outbound buffer full during upstream upgrade (~p frames)", [?MAX_WS_OUT_BUFFER]),
            {ok, State};
        false ->
            {ok, State#{ws_out_buffer => Buf ++ [Frame]}}
    end;
websocket_handle(_Frame, State) ->
    {ok, State}.

%% Message from gun (upstream) → forward to client, or handle close/errors.

websocket_info({gun_ws, _ConnPid, _SRef, close}, State) ->
    {[close], State};

websocket_info({gun_ws, _ConnPid, _SRef, Frame}, State) ->
    {[Frame], State};

websocket_info(
    {gun_upgrade, ConnPid, SRef, Protocols, Headers},
    State = #{conn_pid := ConnPid, stream_ref := SRef, ws_out_buffer := Buf}
) ->
    case is_ws_upgrade_protocols(Protocols) of
        true ->
            lager:info(
                "WS upstream upgraded protocols=~p buffered_frames=~p",
                [Protocols, length(Buf)]
            ),
            lists:foreach(fun(F) -> gun:ws_send(ConnPid, SRef, F) end, Buf),
            {ok, State#{upstream_ws_ready => true, ws_out_buffer => []}};
        false ->
            lager:warning(
                "WS upstream unexpected upgrade protocols=~p headers=~p",
                [Protocols, Headers]
            ),
            {[close], State}
    end;

websocket_info(
    {gun_response, ConnPid, SRef, _Fin, 101, Headers},
    State = #{conn_pid := ConnPid, stream_ref := SRef, ws_out_buffer := Buf}
) ->
    lager:info(
        "WS upstream 101 response headers=~p buffered_frames=~p",
        [Headers, length(Buf)]
    ),
    lists:foreach(fun(F) -> gun:ws_send(ConnPid, SRef, F) end, Buf),
    {ok, State#{upstream_ws_ready => true, ws_out_buffer => []}};

websocket_info(
    {gun_response, ConnPid, SRef, _Fin, Status, Headers},
    State = #{conn_pid := ConnPid, stream_ref := SRef, upstream_addr := UpAddr, upstream_path := UpPath}
) when Status =/= 101 ->
    lager:warning(
        "WS upstream rejected upgrade upstream=~s path=~s status=~p headers=~p",
        [UpAddr, UpPath, Status, Headers]
    ),
    {[close], State};

websocket_info({gun_error, _ConnPid, _SRef, Reason}, State) ->
    lager:warning("WS upstream error: ~p", [Reason]),
    {[close], State};

websocket_info({gun_down, _ConnPid, _Proto, Reason, _Killed}, State) ->
    lager:info("WS upstream down: ~p", [Reason]),
    {[close], State};

websocket_info(_Info, State) ->
    {ok, State}.

is_ws_upgrade_protocols([<<"websocket">> | _]) ->
    true;
is_ws_upgrade_protocols([websocket | _]) ->
    true;
is_ws_upgrade_protocols(_) ->
    false.

ws_gun_opts(tls) ->
    #{
        transport => tls,
        protocols => [http],
        %% Force classic WS Upgrade over HTTP/1.1; upstream h2 ALPN can reject ws_upgrade.
        tls_opts => [{alpn_advertised_protocols, [<<"http/1.1">>]}]
    };
ws_gun_opts(Transport) ->
    #{transport => Transport, protocols => [http]}.

ws_gun_opts(UpHost, tls) ->
    Base = ws_gun_opts(tls),
    Tls0 = maps:get(tls_opts, Base, []),
    Base#{tls_opts => [{verify, verify_none} | maybe_sni_opt(UpHost)] ++ Tls0};
ws_gun_opts(_UpHost, Transport) ->
    ws_gun_opts(Transport).

maybe_sni_opt(UpHost) when is_list(UpHost) ->
    case inet:parse_address(UpHost) of
        {ok, _Ip} -> [{server_name_indication, disable}];
        _ -> [{server_name_indication, UpHost}]
    end;
maybe_sni_opt(UpHost) when is_binary(UpHost) ->
    maybe_sni_opt(binary_to_list(UpHost));
maybe_sni_opt(_) ->
    [{server_name_indication, disable}].

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

ws_forward_headers(Req, OrigHost, ClientIp, UpPath) ->
    InHeaders = cowboy_req:headers(Req),
    Proto = case cowboy_req:scheme(Req) of
        https -> <<"https">>;
        <<"https">> -> <<"https">>;
        _ -> <<"http">>
    end,
    ProtoVsn = version_to_bin(cowboy_req:version(Req)),
    IsConsolePath = skip_forwarded_for(OrigHost, UpPath),
    %% Gun builds WS transport headers; only forward app-relevant headers.
    Base0 = #{
        <<"host">> => OrigHost,
        <<"x-forwarded-proto">> => Proto,
        <<"x-forwarded-proto-version">> => ProtoVsn
    },
    Base =
        case skip_forwarded_for(OrigHost, UpPath) of
            true ->
                Base0;
            false ->
                XFF = case maps:get(<<"x-forwarded-for">>, InHeaders, undefined) of
                    undefined -> ClientIp;
                    Existing -> <<Existing/binary, ", ", ClientIp/binary>>
                end,
                Base0#{<<"x-forwarded-for">> => XFF}
        end,
    %% Proxmox console WS can be strict; keep handshake headers minimal.
    Keep =
        case IsConsolePath of
            true ->
                [
                    <<"authorization">>,
                    <<"cookie">>,
                    <<"origin">>,
                    <<"referer">>,
                    <<"user-agent">>,
                    <<"sec-websocket-protocol">>,
                    <<"x-eproxy-bearer">>
                ];
            false ->
                [
                    <<"authorization">>,
                    <<"cookie">>,
                    <<"origin">>,
                    <<"referer">>,
                    <<"user-agent">>,
                    <<"sec-websocket-protocol">>,
                    <<"x-eproxy-bearer">>
                ]
        end,
    Out = lists:foldl(
        fun(K, Acc) ->
            case maps:get(K, InHeaders, undefined) of
                undefined -> Acc;
                V -> Acc#{K => V}
            end
        end,
        Base,
        Keep
    ),
    case IsConsolePath of
        true ->
            %% Keep this close to reverse-proxy defaults that are known to work with Proxmox consoles.
            maps:to_list(maps:without([<<"x-forwarded-proto">>, <<"x-forwarded-proto-version">>], Out));
        false ->
            maps:to_list(Out)
    end.

skip_forwarded_for(Host, Path) when is_binary(Host), is_binary(Path) ->
    HostL = string:lowercase(Host),
    IsProxmoxHost = binary:match(HostL, <<"proxmox">>) =/= nomatch,
    IsConsolePath =
        binary:match(Path, <<"/termproxy">>) =/= nomatch orelse
        binary:match(Path, <<"/vncproxy">>) =/= nomatch orelse
        binary:match(Path, <<"/vncwebsocket">>) =/= nomatch,
    IsProxmoxHost andalso IsConsolePath;
skip_forwarded_for(_, _) ->
    false.

maybe_set_ws_subprotocol(Req0) ->
    case select_ws_subprotocol(cowboy_req:header(<<"sec-websocket-protocol">>, Req0, undefined)) of
        undefined ->
            Req0;
        Proto ->
            lager:info("WS selecting subprotocol ~s", [Proto]),
            cowboy_req:set_resp_header(<<"sec-websocket-protocol">>, Proto, Req0)
    end.

select_ws_subprotocol(undefined) ->
    undefined;
select_ws_subprotocol(<<>>) ->
    undefined;
select_ws_subprotocol(Bin) when is_binary(Bin) ->
    case [string:trim(P, both) || P <- binary:split(Bin, <<",">>, [global])] of
        [] -> undefined;
        [<<>> | Rest] -> select_ws_subprotocol(list_to_binary(string:join([binary_to_list(R) || R <- Rest], ",")));
        [First | _] -> First
    end.

version_to_bin('HTTP/1.0') -> <<"HTTP/1.0">>;
version_to_bin('HTTP/1.1') -> <<"HTTP/1.1">>;
version_to_bin('HTTP/2') -> <<"HTTP/2">>;
version_to_bin('HTTP/3') -> <<"HTTP/3">>;
version_to_bin(_) -> <<"HTTP/1.1">>.
