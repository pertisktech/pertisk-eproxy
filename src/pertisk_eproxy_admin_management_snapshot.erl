%% @doc Single source for GET /api/management and realtime `management` JSON object.
-module(pertisk_eproxy_admin_management_snapshot).

-export([snapshot/0, app_version/0, init_cpu_sample/0]).

-define(CPU_PREV_KEY, {pertisk_eproxy, management_cpu_prev}).

%% @doc Seed wall/runtime counters so the first `/api/management` response can compute CPU%.
init_cpu_sample() ->
    {W, _} = erlang:statistics(wall_clock),
    {R, _} = erlang:statistics(runtime),
    persistent_term:put(?CPU_PREV_KEY, {W, R}),
    ok.

snapshot() ->
    C = pertisk_eproxy_config:get_config(),
    HttpPort = maps:get(http_port, C, 8080),
    MgmtPort = maps:get(management_port, C, 9080),
    MgmtAddr = maps:get(management_addr, C, {127, 0, 0, 1}),
    Mode0 = maps:get(mode, C, proxy_admin),
    ModeBin = case Mode0 of
        proxy -> <<"proxy">>;
        proxy_admin -> <<"proxy_admin">>;
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
    PI = process_info_json(),
    MemBytes = maps:get(<<"memory_total_bytes">>, PI, 0),
    CpuPct = beam_cpu_usage_percent(),
    Base = #{
        <<"version">> => app_version(),
        <<"mode">> => ModeBin,
        <<"http_addr">> => iolist_to_binary(io_lib:format("0.0.0.0:~w", [HttpPort])),
        <<"https_addr">> => HttpsAddr,
        <<"management_addr">> => iolist_to_binary([inet:ntoa(MgmtAddr), $:, integer_to_list(MgmtPort)]),
        <<"db_path">> => iolist_to_binary(db_file_path()),
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
    L2 = L1 ++ [#{
        <<"id">> => <<"management">>,
        <<"description">> => <<"Admin API + UI (management listener)">>,
        <<"protocol">> => <<"tcp">>,
        <<"bind">> => MgmtBind,
        <<"port">> => MgmtPort,
        <<"tls">> => false,
        <<"stack">> => <<"single_bind">>
    }],
    L3 = case {maps:get(quic_enabled, C, false), maps:get(quic_port, C, undefined)} of
        {true, P} when is_integer(P) ->
            L2 ++ [#{
                <<"id">> => <<"proxy_quic">>,
                <<"description">> => <<"HTTP/3 via Cowboy QUIC (when built with quicer)">>,
                <<"protocol">> => <<"udp">>,
                <<"bind">> => <<"0.0.0.0 and ::">>,
                <<"port">> => P,
                <<"tls">> => true,
                <<"stack">> => <<"dual_stack">>
            }];
        _ ->
            L2
    end,
    case maps:get(h3_api_gateway_enabled, C, true) of
        true ->
            GwPort = case maps:get(quic_port, C, undefined) of
                Qp when is_integer(Qp) -> Qp;
                _ ->
                    case maps:find(https_port, C) of
                        {ok, Hp2} -> Hp2;
                        error -> HttpPort
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
            persistent_term:put(?CPU_PREV_KEY, {Wall, Run}),
            Dw = Wall - W0,
            Dr = Run - R0,
            if
                Dw < 1 ->
                    null;
                true ->
                    P = 100.0 * (Dr / Dw),
                    round(P * 100) / 100.0
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
        <<"os_type">> => os_type_bin(),
        <<"os_version">> => os_version_bin()
    }.

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
