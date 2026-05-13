%% @doc Map path + listener mode to proxy handlers (Ranch HTTP/1.1).
-module(pertisk_eproxy_http_dispatch).

-export([handle/1]).

-spec handle(pertisk_req:req()) ->
    {http_reply, pos_integer(), #{binary() => binary()}, binary()}
    | {ws_proxy, pertisk_req:req()}
    | {admin_ws, pertisk_req:req()}.
handle(Req) ->
    Path = pertisk_req:path(Req),
    case {Path, is_ws_upgrade(Req)} of
        {<<"/api/realtime">>, true} ->
            case use_admin_realtime_ws(Req) of
                true ->
                    {admin_ws, Req};
                false ->
                    {ws_proxy, Req}
            end;
        {<<"/api/realtime">>, false} ->
            H = #{<<"content-type">> => <<"text/plain">>},
            {http_reply, 426, H, <<"Upgrade Required">>};
        _ ->
            case pertisk_eproxy_proxy_http:handle(Req) of
                {reply, Status, Hdr, Body} ->
                    {http_reply, Status, Hdr, Body}
            end
    end.

is_ws_upgrade(Req) ->
    Upgrade = pertisk_req:header(Req, <<"upgrade">>, <<>>),
    Conn = pertisk_req:header(Req, <<"connection">>, <<>>),
    U = string:lowercase(Upgrade),
    C = string:lowercase(Conn),
    U =:= <<"websocket">> andalso
        (binary:match(C, <<"upgrade">>) =/= nomatch orelse byte_size(C) =:= 0).

%% Admin SPA connects with ?token=… (local auth) or, when auth is off, on proxy_admin deployments.
use_admin_realtime_ws(Req) ->
    case pertisk_eproxy_auth:auth_mode() of
        local ->
            Qm = maps:from_list(pertisk_req:qparse(Req)),
            maps:get(<<"token">>, Qm, <<>>) =/= <<>>;
        disabled ->
            maps:get(mode, pertisk_eproxy_config:get_config(), proxy) =:= proxy_admin;
        _ ->
            false
    end.
