%% @doc HTTP reverse proxy handler for pertisk_eproxy.
%%
%% This cowboy handler intercepts all requests on the proxy listeners,
%% performs routing, picks an upstream, and forwards the request via gun.
%%
%% Features:
%%   - Path-based routing (exact / prefix) via pertisk_eproxy_router
%%   - Load balancing via pertisk_eproxy_backend (round-robin / least-conn / ip-hash)
%%   - WebSocket upgrade detection → delegates to pertisk_eproxy_ws_handler
%%   - Forwards X-Forwarded-For, X-Forwarded-Proto, X-Forwarded-Proto-Version
%%   - Preserves original Host header to upstream
%%   - Streaming response body (chunked friendly)
%%   - Per-request timeout (default 60 s)

-module(pertisk_eproxy_handler).
-behaviour(cowboy_handler).

-export([init/2]).

-define(REQUEST_TIMEOUT, 60000).
-define(CONNECT_TIMEOUT, 10000).

init(Req, State) ->
    Method = cowboy_req:method(Req),
    Host   = cowboy_req:host(Req),
    Path   = cowboy_req:path(Req),
    Qs     = cowboy_req:qs(Req),

    %% Check for WebSocket upgrade
    case is_websocket_upgrade(Req) of
        true ->
            pertisk_eproxy_ws_handler:init(Req, State);
        false ->
            handle_http(Req, State, Method, Host, Path, Qs)
    end.

handle_http(Req, State, Method, Host, Path, Qs) ->
    T0 = erlang:monotonic_time(millisecond),
    Vsn = cowboy_req:version(Req),
    case pertisk_eproxy_router:route(Host, Path) of
        {error, no_route} ->
            pertisk_eproxy_metrics:inc_request(Host, <<"404">>),
            H404 = maybe_add_alt_svc(Req, Host, #{<<"content-type">> => <<"text/plain">>}),
            Req2 = cowboy_req:reply(404, H404,
                                    <<"No route found for host: ", Host/binary>>, Req),
            log_access(Host, Method, Path, 404, T0, Vsn),
            {ok, Req2, State};
        {ok, #{upstream_path := UpstreamPath, backend := BackendName}} ->
            ClientIp = client_ip(Req),
            case pertisk_eproxy_backend:pick_upstream(BackendName, ClientIp) of
                {error, no_healthy_upstream} ->
                    pertisk_eproxy_metrics:inc_request(Host, <<"502">>),
                    H502 = maybe_add_alt_svc(Req, Host, #{<<"content-type">> => <<"text/plain">>}),
                    Req2 = cowboy_req:reply(502, H502,
                                            <<"Bad Gateway: no healthy upstream">>, Req),
                    log_access(Host, Method, Path, 502, T0, Vsn),
                    {ok, Req2, State};
                {ok, UpstreamAddr} ->
                    Result = proxy_request(Req, Method, Host, UpstreamPath, Qs,
                                           UpstreamAddr, ClientIp),
                    case Result of
                        {ok, StatusCode, Req2} ->
                            StatusBin = integer_to_binary(StatusCode),
                            pertisk_eproxy_metrics:inc_request(Host, StatusBin),
                            pertisk_eproxy_backend:done_upstream(BackendName, UpstreamAddr, ok),
                            log_access(Host, Method, Path, StatusCode, T0, Vsn),
                            {ok, Req2, State};
                        {error, Reason} ->
                            pertisk_eproxy_metrics:inc_request(Host, <<"502">>),
                            pertisk_eproxy_backend:done_upstream(BackendName, UpstreamAddr, error),
                            lager:warning("Proxy error ~p for ~s~s -> ~s",
                                          [Reason, Host, Path, UpstreamAddr]),
                            H502 = maybe_add_alt_svc(Req, Host, #{<<"content-type">> => <<"text/plain">>}),
                            Req2 = cowboy_req:reply(502, H502,
                                                    <<"Bad Gateway">>, Req),
                            log_access(Host, Method, Path, 502, T0, Vsn),
                            {ok, Req2, State}
                    end
            end
    end.

log_access(Host, Method, Path, Status, T0, Vsn) ->
    Dt = max(0, erlang:monotonic_time(millisecond) - T0),
    catch pertisk_eproxy_access_log:log_proxy(Host, Method, Path, Status, Dt, Vsn).

%% -------------------------------------------------------------------------
%% Core proxy logic using gun
%% -------------------------------------------------------------------------

proxy_request(Req, Method, Host, UpstreamPath, Qs, UpstreamAddr, ClientIp) ->
    {UpHost, UpPort, Transport} = parse_upstream(UpstreamAddr),
    FullPath = case Qs of
        <<>> -> UpstreamPath;
        _    -> <<UpstreamPath/binary, "?", Qs/binary>>
    end,

    GunOpts = #{
        transport  => Transport,
        protocols  => [http],
        connect_timeout => ?CONNECT_TIMEOUT
    },

    case gun:open(UpHost, UpPort, GunOpts) of
        {error, Reason} ->
            {error, {connect, Reason}};
        {ok, ConnPid} ->
            case gun:await_up(ConnPid, ?CONNECT_TIMEOUT) of
                {error, Reason} ->
                    gun:close(ConnPid),
                    {error, {await_up, Reason}};
                {ok, _Protocol} ->
                    do_proxy(Req, ConnPid, Method, Host, FullPath, ClientIp)
            end
    end.

do_proxy(Req, ConnPid, Method, Host, FullPath, ClientIp) ->
    HeadersMap = forward_headers(Req, Host, ClientIp),
    Headers = maps:to_list(HeadersMap),
    {ok, Body} = read_body(Req),

    GunMethod = method_to_gun(Method),
    StreamRef = gun:request(ConnPid, GunMethod, FullPath, Headers, Body),

    Result = case gun:await(ConnPid, StreamRef, ?REQUEST_TIMEOUT) of
        {response, nofin, Status, RespHeaders} ->
            {ok, RespBody} = gun:await_body(ConnPid, StreamRef, ?REQUEST_TIMEOUT),
            RawHeaders  = headers_to_map(RespHeaders),
            CowboyHeaders = maybe_add_alt_svc(Req, Host, RawHeaders),
            Req2 = cowboy_req:reply(Status, CowboyHeaders, RespBody, Req),
            {ok, Status, Req2};
        {response, fin, Status, RespHeaders} ->
            RawHeaders = headers_to_map(RespHeaders),
            CowboyHeaders = maybe_add_alt_svc(Req, Host, RawHeaders),
            Req2 = cowboy_req:reply(Status, CowboyHeaders, <<>>, Req),
            {ok, Status, Req2};
        {error, Reason} ->
            {error, Reason}
    end,
    gun:close(ConnPid),
    Result.

%% -------------------------------------------------------------------------
%% Header helpers
%% -------------------------------------------------------------------------

forward_headers(Req, OrigHost, ClientIp) ->
    InHeaders = cowboy_req:headers(Req),
    Proto     = case cowboy_req:port(Req) of
        443 -> <<"https">>;
        _   -> <<"http">>
    end,
    ProtoVsn  = version_to_bin(cowboy_req:version(Req)),

    %% Start from original headers, drop hop-by-hop
    Filtered = maps:without([<<"connection">>, <<"keep-alive">>, <<"te">>,
                              <<"trailers">>, <<"transfer-encoding">>,
                              <<"upgrade">>], InHeaders),

    %% Preserve original Host
    Base = Filtered#{
        <<"host">>                     => OrigHost,
        <<"x-forwarded-proto">>        => Proto,
        <<"x-forwarded-proto-version">> => ProtoVsn
    },

    %% X-Forwarded-For: append client IP
    XFF = case maps:find(<<"x-forwarded-for">>, Base) of
        {ok, Existing} -> <<Existing/binary, ", ", ClientIp/binary>>;
        error          -> ClientIp
    end,
    Base#{<<"x-forwarded-for">> => XFF}.

version_to_bin('HTTP/1.0') -> <<"HTTP/1.0">>;
version_to_bin('HTTP/1.1') -> <<"HTTP/1.1">>;
version_to_bin('HTTP/2')   -> <<"HTTP/2">>;
version_to_bin(_)          -> <<"HTTP/1.1">>.

headers_to_map(List) ->
    %% Remove hop-by-hop headers from upstream response
    HopByHop = [<<"connection">>, <<"keep-alive">>, <<"proxy-authenticate">>,
                 <<"proxy-authorization">>, <<"te">>, <<"trailers">>,
                 <<"transfer-encoding">>, <<"upgrade">>],
    Filtered = [{K, V} || {K, V} <- List,
                            not lists:member(string:lowercase(K), HopByHop)],
    maps:from_list(Filtered).

%% -------------------------------------------------------------------------
%% Utilities
%% -------------------------------------------------------------------------

is_websocket_upgrade(Req) ->
    Upgrade = cowboy_req:header(<<"upgrade">>, Req, <<>>),
    string:lowercase(Upgrade) =:= <<"websocket">>.

client_ip(Req) ->
    case cowboy_req:header(<<"x-forwarded-for">>, Req) of
        undefined ->
            {PeerIp, _Port} = cowboy_req:peer(Req),
            list_to_binary(inet:ntoa(PeerIp));
        XFF ->
            %% Use leftmost IP (original client)
            hd(binary:split(XFF, [<<", ">>, <<",">>]))
    end.

read_body(Req) ->
    read_body(Req, <<>>).
read_body(Req, Acc) ->
    case cowboy_req:read_body(Req, #{length => 1048576, period => 5000}) of
        {ok,   Data, _Req2} -> {ok, <<Acc/binary, Data/binary>>};
        {more, Data,  Req2} -> read_body(Req2, <<Acc/binary, Data/binary>>)
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

split_host_port(Addr, DefaultPort) ->
    case string:split(Addr, ":", trailing) of
        [Host, PortStr] ->
            {Host, list_to_integer(string:trim(PortStr, trailing, "/"))};
        [Host] ->
            {Host, DefaultPort}
    end.

method_to_gun(<<"GET">>)     -> <<"GET">>;
method_to_gun(<<"POST">>)    -> <<"POST">>;
method_to_gun(<<"PUT">>)     -> <<"PUT">>;
method_to_gun(<<"PATCH">>)   -> <<"PATCH">>;
method_to_gun(<<"DELETE">>)  -> <<"DELETE">>;
method_to_gun(<<"HEAD">>)    -> <<"HEAD">>;
method_to_gun(<<"OPTIONS">>) -> <<"OPTIONS">>;
method_to_gun(M)             -> M.

maybe_add_alt_svc(Req, Host, Headers) ->
    case {cowboy_req:port(Req), site_advertise_http3(Host)} of
        {443, true} -> Headers#{<<"alt-svc">> => <<"h3=\":443\"; ma=86400">>};
        _ -> Headers
    end.

site_advertise_http3(Host) ->
    Config = pertisk_eproxy_config:get_config(),
    Sites = maps:get(sites, Config, []),
    case find_site_for_host(Sites, string:lowercase(Host)) of
        undefined -> true;
        Site -> maps:get(advertise_http3, Site, true) =/= false
    end.

find_site_for_host([], _Host) -> undefined;
find_site_for_host([Site | Rest], Host) ->
    SiteHost = string:lowercase(maps:get(host, Site, <<>>)),
    case host_matches(Host, SiteHost) of
        true -> Site;
        false -> find_site_for_host(Rest, Host)
    end.

host_matches(Host, <<"*.", Suffix/binary>>) ->
    case binary:match(Host, <<".">>) of
        nomatch -> false;
        {Pos, _} ->
            HostSuffix = binary:part(Host, Pos + 1, byte_size(Host) - Pos - 1),
            HostSuffix =:= Suffix
    end;
host_matches(Host, SiteHost) ->
    Host =:= SiteHost.
