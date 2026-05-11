%% @doc JSON-friendly metrics snapshot for the admin UI (rproxy-compatible subset).

-module(pertisk_eproxy_stats).

-export([snapshot/0]).

-define(REG, default).

snapshot() ->
    WallMs = element(1, erlang:statistics(wall_clock)),
    UptimeSecs = max(0, WallMs div 1000),
    ReqTotal = sum_counter(pertisk_eproxy_requests_total),
    LogEntries = try pertisk_eproxy_access_log:count() catch _:_ -> 0 end,
    ConnPerSite = connections_per_host(),
    ActiveConn = sum_gauge(pertisk_eproxy_upstream_connections),
    #{
        <<"log_entries">> => LogEntries,
        <<"uptime_secs">> => UptimeSecs,
        <<"http_requests_total">> => ReqTotal,
        <<"https_requests_total">> => 0,
        <<"grpc_requests_total">> => 0,
        <<"h2_requests_total">> => 0,
        <<"h3_requests_total">> => 0,
        <<"h3_vs_h2_ratio">> => 0.0,
        <<"site_h2_requests_total">> => #{},
        <<"site_h3_requests_total">> => #{},
        <<"site_h3_vs_h2_ratio">> => #{},
        <<"active_connections">> => ActiveConn,
        <<"connections_per_site">> => ConnPerSite,
        <<"bytes_sent_total">> => 0,
        <<"bytes_received_total">> => 0
    }.

connections_per_host() ->
    try
        L = prometheus_counter:values(?REG, pertisk_eproxy_requests_total),
        M = lists:foldl(
            fun({[H, _Status], N}, Acc) ->
                maps:update_with(H, fun(V) -> V + N end, N, Acc)
            end,
            #{},
            L
        ),
        %% UI expects string keys for JSON object
        maps:fold(
            fun(K, V, Acc) -> Acc#{iolist_to_binary(io_lib:format("~s", [K])) => V} end,
            #{},
            M
        )
    catch _:_ ->
        #{}
    end.

sum_counter(Name) ->
    try
        L = prometheus_counter:values(?REG, Name),
        lists:sum([V || {_Labels, V} <- L])
    catch _:_ ->
        0
    end.

sum_gauge(Name) ->
    try
        L = prometheus_gauge:values(?REG, Name),
        lists:sum([V || {_Labels, V} <- L])
    catch _:_ ->
        0
    end.
