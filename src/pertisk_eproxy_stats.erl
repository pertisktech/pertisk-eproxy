%% @doc JSON-friendly metrics snapshot for the admin UI.
%%
%% Request totals are derived from {@link pertisk_eproxy_metrics}: counter labels
%% include `proto` (http1, tls_h1, h2, h3, grpc) so HTTP/3 and HTTP/2 are visible
%% in the admin Metrics charts.

-module(pertisk_eproxy_stats).

-export([snapshot/0]).

-define(REG, default).

snapshot() ->
    WallMs = element(1, erlang:statistics(wall_clock)),
    UptimeSecs = max(0, WallMs div 1000),
    LogEntries = try pertisk_eproxy_access_log:count() catch _:_ -> 0 end,
    ConnPerSite = connections_per_host(),
    ActiveConn = sum_gauge(pertisk_eproxy_upstream_connections),
    BytesSent = sum_counter_metric(pertisk_eproxy_bytes_sent_total),
    BytesRecv = sum_counter_metric(pertisk_eproxy_bytes_received_total),
    L = counter_values(pertisk_eproxy_requests_total),
    Http1 = sum_proto(L, <<"http1">>),
    Admin = sum_proto(L, <<"admin">>),
    TlsH1 = sum_proto(L, <<"tls_h1">>),
    H2 = sum_proto(L, <<"h2">>),
    H3 = sum_proto(L, <<"h3">>),
    Grpc = sum_proto(L, <<"grpc">>),
    SiteH2 = host_sums_by_proto(L, <<"h2">>),
    SiteH3 = host_sums_by_proto(L, <<"h3">>),
    SiteReq = sum_site_requests(),
    SiteRecv = counter_sums_by_label(pertisk_eproxy_site_bytes_received_total, site),
    SiteSent = counter_sums_by_label(pertisk_eproxy_site_bytes_sent_total, site),
    RatioGlobal = case H2 of
        0 -> 0.0;
        _ -> H3 / H2
    end,
    RatioByHost = site_h3_vs_h2_ratio_map(SiteH2, SiteH3),
    #{
        <<"log_entries">> => LogEntries,
        <<"uptime_secs">> => UptimeSecs,
        %% Cleartext HTTP/1.x + management API (same chart line so idle admin shows activity)
        <<"http_requests_total">> => Http1 + Admin,
        <<"management_requests_total">> => Admin,
        %% TLS HTTP/1.x + HTTP/2 on Cowboy HTTPS (chart "HTTPS"); QUIC/H3 is separate
        <<"https_requests_total">> => TlsH1 + H2,
        <<"grpc_requests_total">> => Grpc,
        <<"h2_requests_total">> => H2,
        <<"h3_requests_total">> => H3,
        <<"h3_vs_h2_ratio">> => RatioGlobal,
        <<"site_h2_requests_total">> => SiteH2,
        <<"site_h3_requests_total">> => SiteH3,
        <<"site_requests_total">> => SiteReq,
        <<"site_bytes_received_total">> => SiteRecv,
        <<"site_bytes_sent_total">> => SiteSent,
        <<"site_h3_vs_h2_ratio">> => RatioByHost,
        <<"active_connections">> => ActiveConn,
        <<"connections_per_site">> => ConnPerSite,
        <<"bytes_sent_total">> => BytesSent,
        <<"bytes_received_total">> => BytesRecv
    }.

connections_per_host() ->
    try
        L = counter_values(pertisk_eproxy_requests_total),
        M = lists:foldl(
            fun({LP, N}, Acc) when is_list(LP) ->
                case label_value(LP, host) of
                    undefined -> Acc;
                    H -> maps:update_with(H, fun(V) -> V + N end, N, Acc)
                end;
               (_, Acc) ->
                Acc
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

counter_values(Name) ->
    try prometheus_counter:values(?REG, Name) of
        L when is_list(L) -> L
    catch _:_ ->
        []
    end.

sum_counter_metric(Name) ->
    try
        L = prometheus_counter:values(?REG, Name),
        lists:sum([V || {_LP, V} <- L])
    catch _:_ ->
        0
    end.

sum_proto(L, Proto) ->
    lists:sum([
        V
        || {LP, V} <- L,
           is_list(LP),
           label_value(LP, proto) =:= Proto
    ]).

host_sums_by_proto(L, Proto) ->
    M = lists:foldl(
        fun({LP, V}, Acc) when is_list(LP) ->
                case {label_value(LP, host), label_value(LP, proto)} of
                    {H, P} when H =/= undefined, P =:= Proto ->
                        maps:update_with(H, fun(Old) -> Old + V end, V, Acc);
                    _ ->
                        Acc
                end;
           (_, Acc) ->
                Acc
        end,
        #{},
        L
    ),
    maps:fold(
        fun(K, V, Acc) -> Acc#{iolist_to_binary(io_lib:format("~s", [K])) => V} end,
        #{},
        M
    ).

sum_site_requests() ->
    L = counter_values(pertisk_eproxy_site_requests_total),
    M = lists:foldl(
        fun({LP, V}, Acc) when is_list(LP) ->
                case label_value(LP, site) of
                    undefined -> Acc;
                    Site -> maps:update_with(Site, fun(Old) -> Old + V end, V, Acc)
                end;
           (_, Acc) ->
                Acc
        end,
        #{},
        L
    ),
    maps:fold(
        fun(K, V, Acc) -> Acc#{iolist_to_binary(io_lib:format("~s", [K])) => V} end,
        #{},
        M
    ).

counter_sums_by_label(Name, LabelKey) ->
    L = counter_values(Name),
    M = lists:foldl(
        fun({LP, V}, Acc) when is_list(LP) ->
                case label_value(LP, LabelKey) of
                    undefined -> Acc;
                    Label -> maps:update_with(Label, fun(Old) -> Old + V end, V, Acc)
                end;
           (_, Acc) ->
                Acc
        end,
        #{},
        L
    ),
    maps:fold(
        fun(K, V, Acc) -> Acc#{iolist_to_binary(io_lib:format("~s", [K])) => V} end,
        #{},
        M
    ).

site_h3_vs_h2_ratio_map(H2Map, H3Map) ->
    Keys = lists:usort(maps:keys(H2Map) ++ maps:keys(H3Map)),
    lists:foldl(
        fun(H, Acc) ->
            H2 = maps:get(H, H2Map, 0),
            H3 = maps:get(H, H3Map, 0),
            R = case H2 of
                0 -> 0.0;
                _ -> H3 / H2
            end,
            Acc#{H => R}
        end,
        #{},
        Keys
    ).

sum_gauge(Name) ->
    try
        L = prometheus_gauge:values(?REG, Name),
        lists:sum([V || {_Labels, V} <- L])
    catch _:_ ->
        0
    end.

%% prometheus.erl stores label *names* as printable lists (e.g. `"host"`), not atoms,
%% so `lists:keyfind(proto, 1, LP)` never matched and all protocol sums stayed 0.
-spec label_value([{term(), term()}], atom()) -> term() | undefined.
label_value(LP, Key) when is_list(LP), is_atom(Key) ->
    KeyStr = atom_to_list(Key),
    KeyBin = atom_to_binary(Key, utf8),
    case lists:keyfind(Key, 1, LP) of
        {Key, Val} -> Val;
        false ->
            case lists:keyfind(KeyStr, 1, LP) of
                {KeyStr, Val} -> Val;
                false ->
                    case lists:keyfind(KeyBin, 1, LP) of
                        {KeyBin, Val} -> Val;
                        false -> label_value_scan(LP, Key, KeyStr, KeyBin)
                    end
            end
    end.

label_value_scan([], _Key, _KeyStr, _KeyBin) -> undefined;
label_value_scan([{K, V} | Rest], Key, KeyStr, KeyBin) ->
    case label_key_matches(K, Key, KeyStr, KeyBin) of
        true -> V;
        false -> label_value_scan(Rest, Key, KeyStr, KeyBin)
    end.

label_key_matches(K, Key, KeyStr, KeyBin) ->
    K =:= Key orelse K =:= KeyStr orelse K =:= KeyBin
        orelse (is_binary(K) andalso K =:= KeyBin).
