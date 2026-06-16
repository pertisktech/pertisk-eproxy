%% @doc Single source for GET /api/management and realtime 'management' JSON object.
-module(pertisk_eproxy_admin_management_snapshot).

-export([snapshot/0, app_version/0, init_cpu_sample/0]).

-define(CPU_PREV_KEY, {pertisk_eproxy, management_cpu_prev}).
-define(CPU_LAST_PCT_KEY, {pertisk_eproxy, management_cpu_last_pct}).
%% Ignore samples closer than this — concurrent /api/management + WS ticks share one baseline.
-define(CPU_SAMPLE_MIN_MS, 2000).

%% @doc Seed wall/runtime counters so the first '/api/management' response can compute CPU%.
init_cpu_sample() ->
    {W, _} = erlang:statistics(wall_clock),
    {R, _} = erlang:statistics(runtime),
    persistent_term:put(?CPU_PREV_KEY, {W, R}),
    ok.

snapshot() ->
    C = pertisk_eproxy_config:get_config(),
    HttpPort = maps:get(http_port, C, 80),
    MgmtPort = maps:get(management_port, C, 9080),
    MgmtAddr = maps:get(management_addr, C, {0, 0, 0, 0}),
    ModeBin =
        case pertisk_eproxy_config:ingress_mode() of
            true -> <<"ingress">>;
            false -> <<"proxy">>
        end,
    HttpsAddr = case maps:find(https_port, C) of
        {ok, Hp} -> iolist_to_binary(io_lib:format("0.0.0.0:~w", [Hp]));
        _ -> <<>>
    end,
    TlsInfoBeam = case code:which(pertisk_eproxy_tls_cert_info) of
        Path when is_list(Path) -> list_to_binary(Path);
        _ -> <<>>
    end,
    PI = process_info_json(),
    MemBytes = maps:get(<<"memory_total_bytes">>, PI, 0),
    CpuPct = beam_cpu_usage_percent(),
    MetricsEnabled = pertisk_eproxy_config:metrics_enabled(),
    {MetricsAddr, MetricsPort} = pertisk_eproxy_config:metrics_listen(),
    Base = #{
        <<"version">> => app_version(),
        <<"mode">> => ModeBin,
        <<"http_addr">> => iolist_to_binary(io_lib:format("0.0.0.0:~w", [HttpPort])),
        <<"https_addr">> => HttpsAddr,
        <<"management_addr">> => iolist_to_binary([inet:ntoa(MgmtAddr), $:, integer_to_list(MgmtPort)]),
        <<"metrics_enabled">> => MetricsEnabled,
        <<"metrics_addr">> => iolist_to_binary([inet:ntoa(MetricsAddr), $:, integer_to_list(MetricsPort)]),
        <<"log_level">> => log_level_bin(),
        <<"proxy_access_log">> => proxy_access_log_json(),
        <<"config_file">> => config_file_path_bin(),
        <<"db_path">> => db_path_bin(),
        <<"leader_election">> => leader_election_json(),
        <<"http_versions">> => http_versions_list(C),
        <<"loaded_tls_cert_info_beam">> => TlsInfoBeam,
        <<"listeners">> => listeners_json(C, HttpPort, MgmtAddr, MgmtPort),
        <<"process_info">> => PI,
        <<"process_memory_bytes">> => MemBytes,
        <<"process_cpu_usage_percent">> => CpuPct,
        <<"runtime_capabilities">> => runtime_capabilities(C)
    },
    maps:merge(Base, pertisk_eproxy_public_ip:snapshot()).

app_version() ->
    case env_version() of
        undefined ->
            case application:get_key(pertisk_eproxy, vsn) of
                {ok, V} when is_list(V) -> list_to_binary(V);
                {ok, V} when is_binary(V) -> V;
                _ -> <<"0.1.0">>
            end;
        V ->
            V
    end.

env_version() ->
    case os:getenv("PERTISK_VERSION") of
        false ->
            undefined;
        V ->
            T = string:trim(V),
            case T of
                "" -> undefined;
                _ -> list_to_binary(T)
            end
    end.

db_file_path() ->
    case application:get_env(pertisk_eproxy, db_file) of
        {ok, F} when is_list(F) -> F;
        {ok, F} when is_binary(F) -> binary_to_list(F);
        _ -> "data/proxy.db"
    end.

%% Ingress mode does not use SQLite for routing; omit path from management JSON.
db_path_bin() ->
    case pertisk_eproxy_config:ingress_mode() of
        true -> null;
        false -> list_to_binary(db_file_path())
    end.

leader_election_json() ->
    case pertisk_eproxy_config:ingress_mode() of
        false ->
            null;
        true ->
            #{
                <<"enabled">> => pertisk_ingress_env:leader_election_enabled(),
                <<"is_leader">> => pertisk_ingress_leader:is_leader(),
                <<"namespace">> => pertisk_ingress_env:leader_namespace(),
                <<"lease_name">> => pertisk_ingress_env:leader_lease_name()
            }
    end.

log_level_bin() ->
    list_to_binary(pertisk_eproxy_log_level:label(pertisk_eproxy_log_level:configured())).

proxy_access_log_json() ->
    case os:getenv("PERTISK_PROXY_ACCESS_LOG") of
        "false" -> false;
        "0" -> false;
        "true" -> true;
        "1" -> true;
        _ ->
            C = pertisk_eproxy_config:get_config(),
            case maps:get(proxy_access_log, C, true) of
                false -> false;
                _ -> true
            end
    end.

config_file_path_bin() ->
    case application:get_env(pertisk_eproxy, config_file) of
        {ok, F} when is_list(F) -> list_to_binary(F);
        {ok, F} when is_binary(F) -> F;
        undefined -> <<"config/proxy.json">>
    end.

http_versions_list(C) ->
    Base = case maps:find(https_port, C) of
        {ok, _} -> [<<"http/1.1">>, <<"http/2">>];
        error -> [<<"http/1.1">>]
    end,
    case http3_offered(C) of
        true -> Base ++ [<<"http/3">>];
        false -> Base
    end.

%% HTTP/3 is offered on UDP (erlang_quic gateway and/or Cowboy QUIC when built).
http3_offered(C) ->
    Gw = maps:get(h3_api_gateway_enabled, C, true),
    Cowboy = maps:get(quic_enabled, C, false) andalso erlang:function_exported(cowboy, start_quic, 3),
    Gw orelse Cowboy.

listeners_json(C, HttpPort, MgmtAddr, MgmtPort) ->
    MgmtBind = iolist_to_binary(inet:ntoa(MgmtAddr)),
    L0 = [
        #{
            <<"id">> => <<"proxy_http">>,
            <<"description">> => <<"Reverse proxy HTTP (Cowboy)">>,
            <<"protocol">> => <<"tcp">>,
            <<"bind">> => <<"0.0.0.0 and ::">>,
            <<"port">> => HttpPort,
            <<"tls">> => false,
            <<"stack">> => <<"dual_stack">>
        }
    ],
    L1 = case maps:find(https_port, C) of
        {ok, Hp} ->
            L0 ++ [#{
                <<"id">> => <<"proxy_https">>,
                <<"description">> => <<"Reverse proxy HTTPS (ALPN h2, http/1.1)">>,
                <<"protocol">> => <<"tcp">>,
                <<"bind">> => <<"0.0.0.0 and ::">>,
                <<"port">> => Hp,
                <<"tls">> => true,
                <<"stack">> => <<"dual_stack">>
            }];
        error ->
            L0
    end,
    MgmtTls = maps:get(management_tls_enabled, C, false) =:= true,
    MgmtDesc = case MgmtTls of
        true  -> <<"Admin API + UI (management, ALPN h2+http/1.1)">>;
        false -> <<"Admin API + UI (management listener)">>
    end,
    L2 = L1 ++ [#{
        <<"id">> => <<"management">>,
        <<"description">> => MgmtDesc,
        <<"protocol">> => <<"tcp">>,
        <<"bind">> => MgmtBind,
        <<"port">> => MgmtPort,
        <<"tls">> => MgmtTls,
        <<"stack">> => <<"single_bind">>
    }],
    L2b = case pertisk_eproxy_config:metrics_enabled() of
        false ->
            L2;
        true ->
            {MetricsBind, MetricsPort} = pertisk_eproxy_config:metrics_listen(),
            L2 ++ [#{
                <<"id">> => <<"metrics">>,
                <<"description">> => <<"Prometheus metrics server">>,
                <<"protocol">> => <<"tcp">>,
                <<"bind">> => iolist_to_binary(inet:ntoa(MetricsBind)),
                <<"port">> => MetricsPort,
                <<"tls">> => false,
                <<"stack">> => <<"single_bind">>
            }]
    end,
    L3 = case {maps:get(quic_enabled, C, false), maps:get(quic_port, C, undefined)} of
        {true, P} when is_integer(P) ->
            L2b ++ [#{
                <<"id">> => <<"proxy_quic">>,
                <<"description">> => <<"HTTP/3 via Cowboy QUIC (when built with quicer)">>,
                <<"protocol">> => <<"udp">>,
                <<"bind">> => <<"0.0.0.0 and ::">>,
                <<"port">> => P,
                <<"tls">> => true,
                <<"stack">> => <<"dual_stack">>
            }];
        _ ->
            L2b
    end,
    case maps:get(h3_api_gateway_enabled, C, true) of
        true ->
            %% Keep snapshot in sync with pertisk_eproxy_h3_api_gateway:start/1 port selection.
            GwPort = case maps:get(quic_port, C, undefined) of
                Qp when is_integer(Qp), Qp > 0 -> Qp;
                _ ->
                    case maps:get(https_port, C, 443) of
                        Hp2 when is_integer(Hp2), Hp2 > 0 -> Hp2;
                        _ -> 443
                    end
            end,
            {GwBind, GwStack} = pertisk_eproxy_h3_api_gateway:management_listener_bind_stack(),
            L3 ++ [#{
                <<"id">> => <<"h3_api_gateway">>,
                <<"description">> => <<"HTTP/3 API gateway (erlang_quic / Msquic)">>,
                <<"protocol">> => <<"udp">>,
                <<"bind">> => GwBind,
                <<"port">> => GwPort,
                <<"tls">> => true,
                <<"stack">> => GwStack
            }];
        false ->
            L3
    end.

%% BEAM scheduler time vs wall clock since the previous sample (same node).
%% Values above 100%% are normal on multi-core when several schedulers are busy.
beam_cpu_usage_percent() ->
    {Wall, _} = erlang:statistics(wall_clock),
    {Run, _} = erlang:statistics(runtime),
    case persistent_term:get(?CPU_PREV_KEY, undefined) of
        undefined ->
            persistent_term:put(?CPU_PREV_KEY, {Wall, Run}),
            null;
        {W0, R0} ->
            Dw = Wall - W0,
            Dr = Run - R0,
            if
                Dw < ?CPU_SAMPLE_MIN_MS ->
                    persistent_term:get(?CPU_LAST_PCT_KEY, null);
                true ->
                    persistent_term:put(?CPU_PREV_KEY, {Wall, Run}),
                    P = round(100.0 * (Dr / Dw) * 100) / 100.0,
                    persistent_term:put(?CPU_LAST_PCT_KEY, P),
                    P
            end
    end.

process_info_json() ->
    TotMem = try (erlang:memory(total)) catch _:_ -> 0 end,
    #{
        <<"node">> => atom_to_binary(node(), utf8),
        <<"os_pid">> => list_to_binary(os:getpid()),
        <<"hostname">> => hostname_bin(),
        <<"otp_release">> => list_to_binary(erlang:system_info(otp_release)),
        <<"erts_version">> => list_to_binary(erlang:system_info(version)),
        <<"system_architecture">> => list_to_binary(erlang:system_info(system_architecture)),
        <<"word_size">> => erlang:system_info(wordsize) * 8,
        <<"schedulers">> => erlang:system_info(schedulers),
        <<"logical_processors">> => erlang:system_info(logical_processors),
        <<"smp_enabled">> => erlang:system_info(smp_support),
        <<"thread_pool">> => try erlang:system_info(thread_pool_size) catch _:_ -> 0 end,
        <<"process_count">> => erlang:system_info(process_count),
        <<"process_limit">> => erlang:system_info(process_limit),
        <<"memory_total_bytes">> => TotMem,
        <<"memory_breakdown_bytes">> => memory_breakdown_json(),
        <<"os_type">> => os_type_bin(),
        <<"os_version">> => os_version_bin()
    }.

%% erlang:memory/0 categories (code, processes, system, …) — see erlang(3) memory/1.
memory_breakdown_json() ->
    try
        maps:from_list([
            {atom_to_binary(K, utf8), V}
         || {K, V} <- erlang:memory(), is_integer(V), V >= 0
        ])
    catch _:_ ->
        #{}
    end.

hostname_bin() ->
    case inet:gethostname() of
        {ok, H} -> list_to_binary(H);
        _ -> <<>>
    end.

os_type_bin() ->
    case os:type() of
        {Osf, _} -> atom_to_binary(Osf, utf8);
        Osf when is_atom(Osf) -> atom_to_binary(Osf, utf8)
    end.

os_version_bin() ->
    case os:version() of
        {Maj, Min, Rel} ->
            iolist_to_binary(io_lib:format("~w.~w.~w", [Maj, Min, Rel]));
        V ->
            iolist_to_binary(io_lib:format("~p", [V]))
    end.

runtime_capabilities(C) ->
    CowboyQuic = erlang:function_exported(cowboy, start_quic, 3),
    QuicerLoaded = app_loaded(quicer),
    H3Gw = maps:get(h3_api_gateway_enabled, C, true),
    #{
        <<"beam">> => list_to_binary(erlang:system_info(machine)),
        <<"jit">> => erlang:system_info(emu_flavor) =:= jit,
        <<"cowboy_quic">> => CowboyQuic,
        <<"quicer_application">> => QuicerLoaded,
        <<"h3_api_gateway_config">> => H3Gw,
        <<"tls_listener_configured">> => maps:is_key(https_port, C),
        <<"proxy_http3_udp">> => maps:get(quic_enabled, C, false)
    }.

app_loaded(Name) ->
    lists:keymember(Name, 1, application:loaded_applications()).
