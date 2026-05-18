%% @doc Admin realtime Server-Sent Events stream (H3-friendly fallback path).
-module(pertisk_eproxy_admin_sse_handler).
-behaviour(cowboy_handler).

-export([init/2]).

-define(TICK_MS, 2000).
-define(MAX_TICKS, 1800). %% ~1 hour before client reconnect.

init(Req, _State) ->
    case authorize(Req) of
        ok ->
            Host = cowboy_req:host(Req),
            Headers0 = #{
                <<"content-type">> => <<"text/event-stream; charset=utf-8">>,
                <<"cache-control">> => <<"no-cache, no-transform">>,
                <<"connection">> => <<"keep-alive">>
            },
            Headers = pertisk_eproxy_alt_svc:merge_response_headers(Req, Host, Headers0),
            Req2 = cowboy_req:stream_reply(200, Headers, Req),
            Req3 = send_snapshot_event(Req2),
            stream_ticks(Req3, ?MAX_TICKS),
            {ok, Req3, #{}};
        {error, unauthorized} ->
            Req2 = cowboy_req:reply(401, #{<<"content-type">> => <<"application/json">>},
                                    <<"{\"error\":\"Unauthorized\"}">>, Req),
            {ok, Req2, #{}}
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
