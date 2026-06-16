%% @doc Admin realtime Server-Sent Events stream (H3-friendly fallback path).
-module(pertisk_eproxy_admin_sse_handler).
-behaviour(cowboy_handler).

-export([init/2, authorize/1, stream_authorized/1, snapshot_json/0]).

-define(TICK_MS, 2000).
-define(MAX_TICKS, 1800). %% ~1 hour before client reconnect.

max_ticks() ->
    application:get_env(pertisk_eproxy, admin_sse_max_ticks, ?MAX_TICKS).

init(Req, _State) ->
    case authorize(Req) of
        ok ->
            case stream_authorized(Req) of
                {ok, Req2} ->
                    {ok, Req2, #{}};
                {error, _} ->
                    {ok, reply_error(Req, 500, <<"Internal Server Error">>), #{}}
            end;
        {error, unauthorized} ->
            {ok, reply_unauthorized(Req), #{}}
    end.

%% @doc Authorize an SSE request (query `token` or Bearer headers).
-spec authorize(cowboy_req:req()) -> ok | {error, unauthorized}.
authorize(Req) ->
    Qs = cowboy_req:qs(Req),
    Headers = cowboy_req:headers(Req),
    pertisk_eproxy_auth:authorize_realtime_sse(Qs, Headers).

%% @doc Start an authorized SSE stream; blocks until the client disconnects or max ticks.
-spec stream_authorized(cowboy_req:req()) -> {ok, cowboy_req:req()} | {error, term()}.
stream_authorized(Req) ->
    try
        Host = cowboy_req:host(Req),
        Headers0 = pertisk_eproxy_response_headers:merge(#{
            <<"content-type">> => <<"text/event-stream; charset=utf-8">>,
            <<"cache-control">> => <<"no-cache, no-transform">>,
            <<"connection">> => <<"keep-alive">>
        }),
        Headers = pertisk_eproxy_alt_svc:merge_response_headers(Req, Host, Headers0),
        Req2 = cowboy_req:stream_reply(200, Headers, Req),
        Req3 = send_snapshot_event(Req2),
        stream_ticks(Req3, max_ticks()),
        {ok, Req3}
    catch
        Class:Reason ->
            lager:warning("admin realtime-sse stream failed: ~p:~p", [Class, Reason]),
            {error, {Class, Reason}}
    end.

stream_ticks(Req, Remaining) when Remaining =< 0 ->
    _ = catch cowboy_req:stream_body(<<"event: end\ndata: {\"reason\":\"reconnect\"}\n\n">>, fin, Req),
    ok;
stream_ticks(Req, Remaining) ->
    receive
    after ?TICK_MS ->
        case catch send_snapshot_event(Req) of
            ok ->
                stream_ticks(Req, Remaining - 1);
            _ ->
                ok
        end
    end.

send_snapshot_event(Req) ->
    Json = snapshot_json(),
    Payload = iolist_to_binary([<<"event: snapshot\ndata: ">>, Json, <<"\n\n">>]),
    cowboy_req:stream_body(Payload, nofin, Req).

snapshot_json() ->
    try
        thoas:encode(snapshot_data())
    catch
        Class:Reason ->
            lager:warning("admin sse snapshot_json encode failed: ~p:~p", [Class, Reason]),
            <<"{\"error\":\"snapshot_failed\"}">>
    end.

snapshot_data() ->
    #{
        <<"stats">> => pertisk_eproxy_stats:snapshot(),
        <<"management">> => pertisk_eproxy_admin_management_snapshot:snapshot(),
        <<"logs">> => safe_access_logs(),
        <<"certificates">> => certificate_rows(),
        <<"ssl_jobs">> => pertisk_eproxy_admin_realtime:ssl_jobs_snapshot()
    }.

safe_access_logs() ->
    try pertisk_eproxy_access_log:list(undefined, undefined) catch _:_ -> [] end.

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

reply_unauthorized(Req) ->
    reply_error(
        Req,
        401,
        pertisk_eproxy_response_headers:merge(#{<<"content-type">> => <<"application/json">>}),
        <<"{\"error\":\"Unauthorized\"}">>
    ).

reply_error(Req, Status, Body) when is_binary(Body) ->
    reply_error(
        Req,
        Status,
        pertisk_eproxy_response_headers:merge(#{<<"content-type">> => <<"text/plain">>}),
        Body
    ).

reply_error(Req, Status, Headers, Body) ->
    cowboy_req:reply(Status, Headers, Body, Req).
