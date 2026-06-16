%% @doc Configuration manager for pertisk_eproxy.
%%
%% **Proxy:** runtime config and sites/backends are stored in SQLite
%% ('data/proxy.db'); JSON file seeds the DB only when that file does not exist yet.
%%
%% **Ingress:** listener settings come from 'config/ingress.json' (or 'PERTISK_CONFIG_FILE');
%% sites/backends are applied only via {@link sync_ingress/2} from Kubernetes manifests
%% (standard 'networking.k8s.io/v1' Ingress + TLS Secrets). SQLite is not used.
%%
%% All modes cache the active config in ETS for fast concurrent reads.
%%
%% Config is stored as JSON and cached in ETS:
%%   - mode (proxy | ingress)
%%   - sites (host, backend, certificate, dns_provider, routes)
%%   - backends (name, algorithm, health_path, health_interval_secs)
%%   - certificates (legacy string labels in JSON; site TLS picks use GET /api/certificates)
%%   - dns_providers (list of #{name, provider_type, credentials} or legacy strings in JSON)
%%
%% All server config (HTTP/HTTPS/management ports, TLS certs) is passed
%% via config/sys.config and application environment variables.

-module(pertisk_eproxy_config).
-behaviour(gen_server).

-export([start_link/0]).
-export([get_config/0, get_sites/0, get_backends/0, site_auth_url/1, site_rate_limit/1,
         get_certificates/0, get_dns_providers/0,
         get_backend/1, get_router/0,
         management_upstream_bin/0,
         management_loopback_upstream_bin/0,
         is_management_upstream_addr/1,
         backend_is_management_only/1,
         metrics_enabled/0, metrics_listen/0,
         reload/0, put_config/1, sync_ingress/2,
         ingress_mode/0, proxy_mode/0, json_to_config_pub/1,
         db_file/0, data_dir/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(TAB, pertisk_eproxy_config_tab).
-define(SERVER, ?MODULE).
%% Saves can block on SQLite (shell sqlite3) and backend supervisor sync; 15s was too tight in the field.
-define(CONFIG_CALL_TIMEOUT_MS, 60000).

%% ---------------------------------------------------------------------------
%% Public API
%% ---------------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Return the top-level config map.
-spec get_config() -> map().
get_config() ->
    case safe_lookup(config) of
        [{config, C}] -> C;
        []            -> #{}
    end.

%% @doc 'Host:port' for the management listener (for access logs when forwarding to it).
-spec management_upstream_bin() -> binary().
management_upstream_bin() ->
    C = get_config(),
    Port = maps:get(management_port, C, 9080),
    Addr = maps:get(management_addr, C, {0, 0, 0, 0}),
    iolist_to_binary([inet:ntoa(Addr), $:, integer_to_list(Port)]).

%% @doc Loopback address for in-pod hops to :9080 (avoids ClusterIP hairpin / missing Service DNS).
-spec management_loopback_upstream_bin() -> binary().
management_loopback_upstream_bin() ->
    Port = maps:get(management_port, get_config(), 9080),
    iolist_to_binary(["127.0.0.1:", integer_to_binary(Port)]).

-spec is_management_upstream_addr(binary()) -> boolean().
is_management_upstream_addr(UpstreamAddr) ->
    try
        {_Host, Port, _} = pertisk_eproxy_handler:parse_upstream(UpstreamAddr),
        Port =:= maps:get(management_port, get_config(), 9080)
    catch
        _:_ ->
            false
    end.

%% @doc True when every upstream for this backend is the in-pod management listener.
-spec backend_is_management_only(binary()) -> boolean().
backend_is_management_only(BackendName) when is_binary(BackendName) ->
    Mgmt = management_loopback_upstream_bin(),
    case lists:filter(fun(#{name := N}) -> N =:= BackendName end, get_backends()) of
        [#{upstreams := Ups}] when is_list(Ups), Ups =/= [] ->
            lists:all(
                fun(#{addr := Addr}) ->
                    is_management_upstream_addr(Addr) orelse Addr =:= Mgmt
                end,
                Ups
            );
        _ ->
            false
    end;
backend_is_management_only(_) ->
    false.

%% @doc Whether the dedicated Prometheus listener should start (default true).
-spec metrics_enabled() -> boolean().
metrics_enabled() ->
    case os:getenv("PERTISK_METRICS_ENABLED") of
        "false" -> false;
        "0" -> false;
        "true" -> true;
        "1" -> true;
        _ ->
            case maps:get(metrics_enabled, get_config(), true) of
                false -> false;
                _ -> true
            end
    end.

%% @doc Bind address/port for the Prometheus listener ('PERTISK_METRICS_ADDR' overrides JSON).
-spec metrics_listen() -> {inet:ip_address(), pos_integer()}.
metrics_listen() ->
    case os:getenv("PERTISK_METRICS_ADDR") of
        false ->
            metrics_listen_from_config();
        Env when is_list(Env) ->
            case parse_host_port(string:trim(Env)) of
                {ok, Addr, Port} ->
                    {Addr, Port};
                error ->
                    metrics_listen_from_config()
            end
    end.

metrics_listen_from_config() ->
    C = get_config(),
    Addr = maps:get(metrics_addr, C, {0, 0, 0, 0}),
    Port = maps:get(metrics_port, C, 9090),
    {Addr, Port}.

%% Return list of site maps.
-spec get_sites() -> [map()].
get_sites() ->
    case safe_lookup(sites) of
        [{sites, S}] -> S;
        []           -> []
    end.

-spec site_auth_url(binary()) -> binary() | undefined.
site_auth_url(SiteHost) when is_binary(SiteHost) ->
    case find_site_by_host(SiteHost, get_sites()) of
        {ok, Site} -> maps:get(auth_url, Site, undefined);
        error -> undefined
    end.

-spec site_rate_limit(binary()) -> {ok, pos_integer(), pos_integer()} | error.
site_rate_limit(SiteHost) when is_binary(SiteHost) ->
    case find_site_by_host(SiteHost, get_sites()) of
        {ok, Site} ->
            case {maps:get(rate_limit_rps, Site, undefined),
                  maps:get(rate_limit_burst, Site, undefined)} of
                {Rps, Burst} when is_integer(Rps), Rps > 0, is_integer(Burst), Burst > 0 ->
                    {ok, Rps, Burst};
                _ ->
                    error
            end;
        error ->
            error
    end.

find_site_by_host(Host, Sites) ->
    case lists:dropwhile(fun(S) -> maps:get(host, S, <<>>) =/= Host end, Sites) of
        [Site | _] -> {ok, Site};
        [] -> error
    end.

%% Return list of backend maps.
-spec get_backends() -> [map()].
get_backends() ->
    case safe_lookup(backends) of
        [{backends, B}] -> B;
        []              -> []
    end.

%% Return list of certificate record names.
-spec get_certificates() -> [binary() | list()].
get_certificates() ->
    case safe_lookup(certificates) of
        [{certificates, C}] -> C;
        []                  -> []
    end.

%% Return list of DNS provider display names (for validation / UI).
-spec get_dns_providers() -> [list()].
get_dns_providers() ->
    case safe_lookup(dns_providers) of
        [{dns_providers, D}] when is_list(D) ->
            [dns_provider_entry_name(P) || P <- D];
        [] ->
            []
    end.

%% Return a single backend map by name, or error.
-spec get_backend(binary()) -> {ok, map()} | error.
get_backend(Name) ->
    case safe_lookup({backend, Name}) of
        [{_, B}] -> {ok, B};
        []       -> error
    end.

%% Return the compiled router (pertisk_eproxy_router).
-spec get_router() -> pertisk_eproxy_router:router().
get_router() ->
    case safe_lookup(router) of
        [{router, R}] -> R;
        []            -> pertisk_eproxy_router:empty()
    end.

safe_lookup(Key) ->
    try ets:lookup(?TAB, Key) of
        Rows -> Rows
    catch
        error:badarg ->
            []
    end.

%% Trigger a hot-reload from the config file.
-spec reload() -> ok | {error, term()}.
reload() ->
    gen_server:call(?SERVER, reload, ?CONFIG_CALL_TIMEOUT_MS).

%% @doc Replace sites/backends from Kubernetes ingress reconcile (does not persist to SQLite).
-spec sync_ingress([map()], [map()]) -> ok | {error, term()}.
sync_ingress(Sites, Backends) ->
    gen_server:call(?SERVER, {sync_ingress, Sites, Backends}, ?CONFIG_CALL_TIMEOUT_MS).

-spec ingress_mode() -> boolean().
ingress_mode() ->
    pertisk_ingress_env:ingress_mode()
        orelse maps:get(mode, get_config(), proxy) =:= ingress.

-spec proxy_mode() -> boolean().
proxy_mode() ->
    not ingress_mode().

%% Replace the in-memory config with a new map (does NOT write to file).
%% Spawns/stops backend workers as needed and refreshes the router.
-spec put_config(map()) -> ok | {error, term()}.
put_config(Config) ->
    gen_server:call(?SERVER, {put_config, Config}, ?CONFIG_CALL_TIMEOUT_MS).

%% ---------------------------------------------------------------------------
%% gen_server callbacks
%% ---------------------------------------------------------------------------

init([]) ->
    ?TAB = ets:new(?TAB, [named_table, protected, set, {read_concurrency, true}]),
    case load_config() of
        {ok, Config} ->
            apply_config(Config),
            {ok, #{file => config_file()}};
        {error, Reason} ->
            lager:warning("Config load failed: ~p — starting with empty config", [Reason]),
            {ok, #{file => config_file()}}
    end.

handle_call(reload, _From, State) ->
    Reply = case ingress_mode() of
        true ->
            pertisk_ingress_watcher:trigger_reconcile(),
            ok;
        false ->
            case load_config() of
                {ok, Config} ->
                    apply_config(Config),
                    _ = spawn(fun() -> pertisk_eproxy_acme_dns:schedule_scan() end),
                    ok;
                {error, R} -> {error, R}
            end
    end,
    {reply, Reply, State};

handle_call({sync_ingress, Sites, Backends}, _From, State) ->
    Config0 = get_config(),
    Config1 = Config0#{sites => Sites, backends => Backends},
    apply_config(Config1),
    {reply, ok, State};

handle_call({put_config, Config}, _From, State) ->
    case ingress_mode() of
        true ->
            {reply, {error, ingress_manifest_mode}, State};
        false ->
            put_config_proxy(Config, State)
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ---------------------------------------------------------------------------
%% Internal
%% ---------------------------------------------------------------------------

put_config_proxy(Config, State) ->
    PrevConfig = get_config(),
    T0 = erlang:monotonic_time(millisecond),
    case validate_proxy_tls_site_bindings(Config, PrevConfig) of
        ok ->
            case persist_runtime_config(Config) of
                ok ->
                    T1 = erlang:monotonic_time(millisecond),
                    apply_config(Config),
                    T2 = erlang:monotonic_time(millisecond),
                    PersistMs = T1 - T0,
                    ApplyMs = T2 - T1,
                    TotalMs = T2 - T0,
                    case TotalMs > 1000 of
                        true ->
                            lager:info(
                                "put_config timing: persist=~wms apply=~wms total=~wms",
                                [PersistMs, ApplyMs, TotalMs]
                            );
                        false ->
                            ok
                    end,
                    maybe_schedule_acme_scan(PrevConfig, Config),
                    {reply, ok, State};
                {error, R} ->
                    lager:error("put_config persist_runtime_config failed: ~p", [R]),
                    {reply, {error, {persist_runtime_config, R}}, State}
            end;
        {error, _} = Err ->
            lager:warning("put_config tls validation failed: ~p", [Err]),
            {reply, Err, State}
    end.

validate_proxy_tls_site_bindings(Config, PrevConfig) when is_map(Config), is_map(PrevConfig) ->
    Sites = maps:get(sites, Config, []),
    PrevSites = maps:get(sites, PrevConfig, []),
    SitesToValidate = sites_requiring_tls_validation(Sites, PrevSites),
    DbPath = db_file(),
    case pertisk_eproxy_db:list_certificates(DbPath) of
        {ok, Rows} ->
            RowsById = maps:from_list(
                [{integer_to_binary(maps:get(id, R)), R} || R <- Rows, maps:is_key(id, R)]
            ),
            RowsByName = maps:from_list(
                [
                    {cert_name_bin(maps:get(name, R, undefined)), R}
                    || R <- Rows,
                       cert_name_bin(maps:get(name, R, undefined)) =/= undefined
                ]
            ),
            validate_sites_tls_bindings(SitesToValidate, RowsById, RowsByName);
        {error, Reason} ->
            {error, {tls_validation_cert_store_unavailable, Reason}}
    end;
validate_proxy_tls_site_bindings(Config, _PrevConfig) when is_map(Config) ->
    validate_proxy_tls_site_bindings(Config, #{});
validate_proxy_tls_site_bindings(_, _) ->
    ok.

sites_requiring_tls_validation(Sites, PrevSites) when is_list(Sites), is_list(PrevSites) ->
    PrevKeys = maps:from_list(
        [
            {Host, Cert}
            || Site <- PrevSites,
               is_map(Site),
               Host <- [site_host_bin(maps:get(host, Site, undefined))],
               Host =/= undefined,
               Cert <- [cert_ref_bin(maps:get(certificate, Site, undefined))]
        ]
    ),
    [
        Site
        || Site <- Sites,
           is_map(Site),
           Host <- [site_host_bin(maps:get(host, Site, undefined))],
           Host =/= undefined,
           Cert <- [cert_ref_bin(maps:get(certificate, Site, undefined))],
           maps:get(Host, PrevKeys, '__missing__') =/= Cert
    ];
sites_requiring_tls_validation(_, _) ->
    [].

validate_sites_tls_bindings([], _RowsById, _RowsByName) ->
    ok;
validate_sites_tls_bindings([Site | Rest], RowsById, RowsByName) when is_map(Site) ->
    HostBin = site_host_bin(maps:get(host, Site, undefined)),
    CertRef = cert_ref_bin(maps:get(certificate, Site, undefined)),
    case {HostBin, CertRef} of
        {undefined, _} ->
            validate_sites_tls_bindings(Rest, RowsById, RowsByName);
        {_, undefined} ->
            validate_sites_tls_bindings(Rest, RowsById, RowsByName);
        {_, <<"k8s/", _/binary>>} ->
            validate_sites_tls_bindings(Rest, RowsById, RowsByName);
        {_, <<"acme/", _/binary>>} ->
            %% ACME refs are managed asynchronously; do not block config writes/deletes
            %% on transient host/cert mismatch during issuance or rotation.
            validate_sites_tls_bindings(Rest, RowsById, RowsByName);
        {Host, Ref} ->
            case cert_row_for_ref(Ref, RowsById, RowsByName) of
                {ok, Row} ->
                    case cert_source_type_bin(maps:get(source_type, Row, undefined)) of
                        <<"tls_listener">> ->
                            %% Listener TLS is a global/default certificate and may not match
                            %% every site host directly; do not block config writes/deletes.
                            validate_sites_tls_bindings(Rest, RowsById, RowsByName);
                        _ ->
                            case cert_pem_bin(maps:get(cert_pem, Row, undefined)) of
                                undefined ->
                                    case is_acme_ref(Ref) of
                                        true ->
                                            validate_sites_tls_bindings(Rest, RowsById, RowsByName);
                                        false ->
                                            {error, {tls_validation_missing_cert_pem, Host, Ref}}
                                    end;
                                CertPem ->
                                    case cert_matches_host(CertPem, Host) of
                                        true ->
                                            validate_sites_tls_bindings(Rest, RowsById, RowsByName);
                                        false ->
                                            {error, {tls_validation_host_mismatch, Host, Ref}}
                                    end
                            end
                    end;
                error ->
                    case is_acme_ref(Ref) of
                        true ->
                            validate_sites_tls_bindings(Rest, RowsById, RowsByName);
                        false ->
                            {error, {tls_validation_unknown_certificate, Host, Ref}}
                    end
            end
    end;
validate_sites_tls_bindings([_ | Rest], RowsById, RowsByName) ->
    validate_sites_tls_bindings(Rest, RowsById, RowsByName).

cert_row_for_ref(Ref, RowsById, RowsByName) ->
    case maps:get(Ref, RowsById, undefined) of
        undefined ->
            case maps:get(Ref, RowsByName, undefined) of
                undefined -> error;
                Row2 -> {ok, Row2}
            end;
        Row ->
            {ok, Row}
    end.

site_host_bin(undefined) -> undefined;
site_host_bin(null) -> undefined;
site_host_bin(B) when is_binary(B), B =/= <<>> -> B;
site_host_bin(L) when is_list(L), L =/= [] -> list_to_binary(L);
site_host_bin(_) -> undefined.

cert_ref_bin(undefined) -> undefined;
cert_ref_bin(null) -> undefined;
cert_ref_bin(B) when is_binary(B), B =/= <<>> -> B;
cert_ref_bin(L) when is_list(L), L =/= [] -> unicode:characters_to_binary(L, utf8);
cert_ref_bin(I) when is_integer(I) -> integer_to_binary(I);
cert_ref_bin(_) -> undefined.

cert_name_bin(undefined) -> undefined;
cert_name_bin(null) -> undefined;
cert_name_bin(B) when is_binary(B), B =/= <<>> -> B;
cert_name_bin(L) when is_list(L), L =/= [] -> unicode:characters_to_binary(L, utf8);
cert_name_bin(_) -> undefined.

cert_pem_bin(undefined) -> undefined;
cert_pem_bin(null) -> undefined;
cert_pem_bin(B) when is_binary(B), B =/= <<>> -> B;
cert_pem_bin(L) when is_list(L), L =/= [] -> unicode:characters_to_binary(L, utf8);
cert_pem_bin(_) -> undefined.

cert_source_type_bin(undefined) -> undefined;
cert_source_type_bin(null) -> undefined;
cert_source_type_bin(B) when is_binary(B), B =/= <<>> -> B;
cert_source_type_bin(L) when is_list(L), L =/= [] -> unicode:characters_to_binary(L, utf8);
cert_source_type_bin(_) -> undefined.

is_acme_ref(<<"acme/", _/binary>>) -> true;
is_acme_ref(_) -> false.

cert_matches_host(CertPem, Host) ->
    try
        CheckHost = cert_check_host(Host),
        case {CheckHost, pem_certificate_ders(CertPem)} of
            {undefined, _} ->
                false;
            {_, []} ->
                false;
            {HostName, Ders} ->
                MatchFun = public_key:pkix_verify_hostname_match_fun(https),
                lists:any(
                    fun(Der) ->
                        try
                            Cert = public_key:pkix_decode_cert(Der, otp),
                            public_key:pkix_verify_hostname(
                                Cert,
                                [{dns_id, HostName}],
                                [{match_fun, MatchFun}]
                            )
                        catch
                            _:_ -> false
                        end
                    end,
                    Ders
                )
        end
    catch
        _:_ -> false
    end.

pem_certificate_ders(CertPem) ->
    [
        Der
        || {'Certificate', Der, not_encrypted} <- public_key:pem_decode(CertPem)
    ].

%% For wildcard site hosts (*.example.com), verify coverage using one concrete label.
cert_check_host(<<"*.", Rest/binary>>) when Rest =/= <<>> ->
    <<"probe.", Rest/binary>>;
cert_check_host(Host) when is_binary(Host), Host =/= <<>> ->
    Host;
cert_check_host(_) ->
    undefined.

maybe_schedule_acme_scan(PrevConfig, NextConfig) ->
    case acme_scan_relevant_changed(PrevConfig, NextConfig) of
        true ->
            _ = spawn(fun() -> pertisk_eproxy_acme_dns:schedule_scan() end),
            ok;
        false ->
            ok
    end.

acme_scan_relevant_changed(PrevConfig, NextConfig) ->
    acme_scan_site_fingerprint(PrevConfig) =/= acme_scan_site_fingerprint(NextConfig).

acme_scan_site_fingerprint(Config) when is_map(Config) ->
    Sites0 = maps:get(sites, Config, []),
    Sites = [acme_site_fingerprint(S) || S <- Sites0, is_map(S)],
    lists:sort(Sites);
acme_scan_site_fingerprint(_) ->
    [].

acme_site_fingerprint(Site) ->
    #{
        host => maps:get(host, Site, undefined),
        certificate => maps:get(certificate, Site, undefined),
        dns_provider => maps:get(dns_provider, Site, undefined),
        challenge_type => maps:get(challenge_type, Site, undefined),
        wildcard => maps:get(wildcard, Site, undefined),
        acme_wildcard_base => maps:get(acme_wildcard_base, Site, undefined),
        acme_contact_email => maps:get(acme_contact_email, Site, undefined)
    }.

config_file() ->
    case os:getenv("PERTISK_CONFIG_FILE") of
        false ->
            case application:get_env(pertisk_eproxy, config_file) of
                {ok, F} -> F;
                undefined -> "config/proxy.json"
            end;
        F when is_list(F), F =/= "" ->
            F
    end.

load_config() ->
    case ingress_mode() of
        true -> load_ingress_config();
        false -> load_proxy_config()
    end.

%% Ingress: JSON file for ports/TLS/H3 flags only; routing from K8s manifests via sync_ingress/2.
load_ingress_config() ->
    File = config_file(),
    case read_config_file(File) of
        {ok, Cfg0} ->
            Cfg = Cfg0#{
                mode => ingress,
                sites => [],
                backends => []
            },
            lager:info(
                "Ingress mode: listener config from ~s; sites/backends from Kubernetes manifests"
            ),
            {ok, Cfg};
        {error, Reason} ->
            {error, Reason}
    end.

%% Proxy: SQLite is source of truth; 'proxy.json' seeds DB on **first deploy only**.
load_proxy_config() ->
    DbPath = db_file(),
    %% Snapshot whether the DB existed BEFORE we touch it. get_runtime_config/1
    %% runs CREATE TABLE IF NOT EXISTS, which causes SQLite to auto-create the
    %% file — making a post-hoc db_file_exists/1 check misleading on first deploy.
    DbExistedBefore = pertisk_eproxy_db:db_file_exists(DbPath),
    case pertisk_eproxy_db:get_runtime_config(DbPath) of
        {ok, Cfg0} when is_map(Cfg0) ->
            CfgA = sanitize_runtime_tls_paths(Cfg0),
            Cfg = cleanup_redacted_dns_providers(DbPath, CfgA),
            _ = pertisk_eproxy_db:ensure_certificates_seeded(DbPath, maps:get(certificates, Cfg, [])),
            _ = pertisk_eproxy_db:ensure_dns_providers_seeded(DbPath, maps:get(dns_providers, Cfg, [])),
            _ = pertisk_eproxy_db:ensure_admin_users(DbPath),
            _ = persist_runtime_config(DbPath, Cfg),
            {ok, Cfg};
        not_found ->
            case DbExistedBefore of
                false ->
                    load_proxy_config_first_deploy(DbPath);
                true ->
                    rebuild_runtime_config_from_db(DbPath)
            end;
        {error, Reason} ->
            case DbExistedBefore of
                true ->
                    lager:error(
                        "SQLite at ~s unavailable (~p); not re-seeding from proxy.json on upgrade",
                        [DbPath, Reason]
                    ),
                    {error, Reason};
                false ->
                    load_proxy_config_first_deploy(DbPath)
            end
    end.

load_proxy_config_first_deploy(DbPath) ->
    case pertisk_eproxy_db:init(DbPath) of
        {ok, _} ->
            lager:info(
                "First deploy: seeding SQLite from ~s into ~s",
                [config_file(), DbPath]
            ),
            load_proxy_config_from_file_and_seed(DbPath);
        {error, Reason} ->
            {error, Reason}
    end.

load_proxy_config_from_file_and_seed(DbPath) ->
    File = config_file(),
    case read_config_file(File) of
        {ok, Cfg0} ->
            Cfg = cleanup_redacted_dns_providers(DbPath, Cfg0),
            _ = pertisk_eproxy_db:ensure_certificates_seeded(DbPath, maps:get(certificates, Cfg, [])),
            _ = pertisk_eproxy_db:ensure_dns_providers_seeded(DbPath, maps:get(dns_providers, Cfg, [])),
            _ = persist_runtime_config(DbPath, Cfg),
            lager:info("SQLite seeded from ~s", [File]),
            {ok, Cfg};
        {error, Reason} ->
            {error, Reason}
    end.

%% Repair missing runtime_state row without overwriting sites/DNS from proxy.json defaults.
rebuild_runtime_config_from_db(DbPath) ->
    File = config_file(),
    case read_config_file(File) of
        {ok, Base} ->
            Sites = load_sites_from_db(DbPath),
            Backends = load_backends_from_db(DbPath),
            Dns = load_dns_providers_from_db(DbPath),
            Certs = load_certificate_names_from_db(DbPath),
            Cfg0 = Base#{
                sites => Sites,
                backends => Backends,
                dns_providers => Dns,
                certificates => Certs
            },
            Cfg = cleanup_redacted_dns_providers(DbPath, Cfg0),
            _ = pertisk_eproxy_db:ensure_certificates_seeded(DbPath, Certs),
            _ = pertisk_eproxy_db:ensure_dns_providers_seeded(DbPath, Dns),
            _ = pertisk_eproxy_db:ensure_admin_users(DbPath),
            _ = persist_runtime_config(DbPath, Cfg),
            lager:warning(
                "Rebuilt runtime_config from SQLite tables (listener defaults from ~s)",
                [File]
            ),
            {ok, Cfg};
        {error, Reason} ->
            {error, Reason}
    end.

load_sites_from_db(DbPath) ->
    case pertisk_eproxy_db:list_sites(DbPath) of
        {ok, Sites} -> Sites;
        _ -> []
    end.

load_backends_from_db(DbPath) ->
    case pertisk_eproxy_db:list_backends(DbPath) of
        {ok, Backends} -> Backends;
        _ -> []
    end.

load_dns_providers_from_db(DbPath) ->
    case pertisk_eproxy_db:list_dns_providers(DbPath) of
        {ok, Rows} ->
            [#{
                name => maps:get(name, R),
                provider_type => maps:get(provider_type, R),
                credentials => maps:get(credentials, R, #{})
            } || R <- Rows];
        _ ->
            []
    end.

cleanup_redacted_dns_providers(DbPath, Config) when is_map(Config) ->
    RuntimeProviders = maps:get(dns_providers, Config, []),
    RuntimeRemoved =
        [
            dns_provider_entry_name_bin(P)
            || P <- RuntimeProviders,
               is_map(P),
               dns_provider_entry_has_redacted(P)
        ],
    DbRemoved = cleanup_redacted_dns_providers_db(DbPath),
    Removed0 = RuntimeRemoved ++ DbRemoved,
    Removed = lists:usort([N || N <- Removed0, N =/= <<>>]),
    case Removed of
        [] ->
            Config;
        _ ->
            lists:foreach(
                fun(NameBin) ->
                    _ = pertisk_eproxy_db:delete_dns_provider_by_name(DbPath, NameBin)
                end,
                Removed
            ),
            KeepProviders =
                [
                    P
                    || P <- RuntimeProviders,
                       is_map(P),
                       not lists:member(dns_provider_entry_name_bin(P), Removed)
                ],
            lager:warning(
                "startup cleanup: removed dns providers with [redacted] credentials: ~p",
                [Removed]
            ),
            Config#{dns_providers => KeepProviders}
    end;
cleanup_redacted_dns_providers(_DbPath, Config) ->
    Config.

cleanup_redacted_dns_providers_db(DbPath) ->
    case pertisk_eproxy_db:list_dns_providers(DbPath) of
        {ok, Rows} ->
            [
                dns_provider_entry_name_bin(R)
                || R <- Rows,
                   is_map(R),
                   dns_provider_entry_has_redacted(R)
            ];
        _ ->
            []
    end.

dns_provider_entry_has_redacted(P) when is_map(P) ->
    Creds = maps:get(credentials, P, #{}),
    dns_credentials_has_redacted(Creds);
dns_provider_entry_has_redacted(_) ->
    false.

dns_credentials_has_redacted(M) when is_map(M) ->
    lists:any(
        fun({_K, V}) ->
            case V of
                VM when is_map(VM) -> dns_credentials_has_redacted(VM);
                _ -> is_redacted_dns_value(V)
            end
        end,
        maps:to_list(M)
    );
dns_credentials_has_redacted(_) ->
    false.

is_redacted_dns_value(V) when is_binary(V) ->
    string:lowercase(trim_bin(V)) =:= <<"[redacted]">>;
is_redacted_dns_value(V) when is_list(V) ->
    is_redacted_dns_value(unicode:characters_to_binary(V, utf8));
is_redacted_dns_value(_) ->
    false.

dns_provider_entry_name_bin(P) when is_map(P) ->
    case maps:get(name, P, <<>>) of
        N when is_binary(N) -> N;
        N when is_list(N) -> unicode:characters_to_binary(N, utf8);
        _ -> <<>>
    end;
dns_provider_entry_name_bin(_) ->
    <<>>.

load_certificate_names_from_db(DbPath) ->
    case pertisk_eproxy_db:list_certificates(DbPath) of
        {ok, Certs} ->
            [
                Name
                || C <- Certs,
                   maps:is_key(name, C),
                   Name <- [maps:get(name, C)],
                   is_valid_certificate_name(Name)
            ];
        _ ->
            []
    end.

read_config_file(File) ->
    case file:read_file(File) of
        {ok, Bin} ->
            case thoas:decode(Bin) of
                {ok, Json} -> {ok, json_to_config(Json)};
                {error, Reason} -> {error, {json_parse, Reason}}
            end;
        {error, Reason} ->
            {error, {file_read, Reason}}
    end.

persist_runtime_config(Config) ->
    case ingress_mode() of
        true -> ok;
        false -> persist_runtime_config(db_file(), Config)
    end.

persist_runtime_config(DbPath, Config) ->
    case pertisk_eproxy_db:put_runtime_config(DbPath, Config) of
        ok ->
            DnsProviders = maps:get(dns_providers, Config, []),
            case pertisk_eproxy_db:replace_dns_providers(DbPath, DnsProviders) of
                ok -> ok;
                {error, Reason} -> {error, {persist_dns_providers, Reason}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

db_file() ->
    case application:get_env(pertisk_eproxy, db_file) of
        {ok, F} -> F;
        undefined -> "data/proxy.db"
    end.

%% Writable data root (SQLite, generated TLS, K8s TLS cache).
-spec data_dir() -> string().
data_dir() ->
    filename:dirname(db_file()).

%% JSON 'null' or non-lists must not crash list comprehensions (maps:get/3 default is
%% ignored when the key is present with value 'null').
-spec json_as_list(term()) -> list().
json_as_list(undefined) -> [];
json_as_list(null) -> [];
json_as_list(L) when is_list(L) -> L;
json_as_list(_) -> [].

%% Parse JSON map into internal config map with atom keys and typed values.
json_to_config(Json) ->
    Sites    = parse_sites(maps:get(<<"sites">>,    Json, undefined)),
    Backends = parse_backends(maps:get(<<"backends">>, Json, undefined)),
    Certificates = parse_certificate_name_list(maps:get(<<"certificates">>, Json, undefined)),
    DnsProviders  = parse_dns_providers(maps:get(<<"dns_providers">>, Json, undefined)),
    Config = #{
        mode            => parse_mode(maps:get(<<"mode">>, Json, <<"proxy">>)),
        http_addr       => parse_addr(maps:get(<<"http_addr">>, Json, <<"0.0.0.0">>)),
        http_port       => maps:get(<<"http_port">>, Json, 80),
        http_num_acceptors => parse_opt_int(maps:get(<<"http_num_acceptors">>, Json, null)),
        https_port      => parse_opt_int(maps:get(<<"https_port">>, Json, null)),
        https_num_acceptors => parse_opt_int(maps:get(<<"https_num_acceptors">>, Json, null)),
        quic_enabled    => parse_opt_bool(maps:get(<<"quic_enabled">>, Json, false)),
        quic_port       => parse_opt_int(maps:get(<<"quic_port">>, Json, null)),
        quic_num_acceptors => parse_opt_int(maps:get(<<"quic_num_acceptors">>, Json, null)),
        proxy_max_connections => parse_opt_int(maps:get(<<"proxy_max_connections">>, Json, null)),
        alt_svc_port    => parse_opt_int(maps:get(<<"alt_svc_port">>, Json, null)),
        h3_api_gateway_enabled =>
            case maps:get(<<"h3_api_gateway_enabled">>, Json, undefined) of
                undefined -> undefined;
                V -> parse_opt_bool(V)
            end,
        h3_probe_enabled =>
            case maps:get(<<"h3_probe_enabled">>, Json, undefined) of
                undefined -> undefined;
                V -> parse_opt_bool(V)
            end,
        h3_probe_port => parse_opt_int(maps:get(<<"h3_probe_port">>, Json, null)),
        tls_http2_enabled =>
            case maps:get(<<"tls_http2_enabled">>, Json, undefined) of
                undefined -> undefined;
                V -> parse_opt_bool(V)
            end,
        h3_idle_timeout_secs =>
            parse_opt_int(maps:get(<<"h3_idle_timeout_secs">>, Json, null)),
        h3_keepalive_interval_secs =>
            parse_opt_int(maps:get(<<"h3_keepalive_interval_secs">>, Json, null)),
        %% dual_stack: one [::] UDP socket (IPv4+IPv6) — matches Quinn/Node/Go; best for Chrome.
        %% split: separate 0.0.0.0 + [::] reuseport listeners (legacy curl -4 workaround).
        h3_udp_bind => parse_h3_udp_bind(maps:get(<<"h3_udp_bind">>, Json, <<"dual_stack">>)),
        %% true = default static-only QPACK (maximum browser interop); false = dynamic table.
        h3_qpack_static => parse_opt_bool(maps:get(<<"h3_qpack_static">>, Json, true)),
        h3_quic_pool_size =>
            parse_opt_int(maps:get(<<"h3_quic_pool_size">>, Json, null)),
        h3_max_udp_payload_size =>
            parse_opt_int(maps:get(<<"h3_max_udp_payload_size">>, Json, null)),
        h3_pmtu_enabled =>
            case maps:get(<<"h3_pmtu_enabled">>, Json, undefined) of
                undefined -> undefined;
                V -> parse_opt_bool(V)
            end,
        h3_max_streams =>
            parse_opt_int(maps:get(<<"h3_max_streams">>, Json, null)),
        h3_stream_receive_window =>
            parse_opt_int(maps:get(<<"h3_stream_receive_window">>, Json, null)),
        h3_conn_receive_window =>
            parse_opt_int(maps:get(<<"h3_conn_receive_window">>, Json, null)),
        management_addr => parse_addr(maps:get(<<"management_addr">>, Json, <<"0.0.0.0">>)),
        management_port => maps:get(<<"management_port">>, Json, 9080),
        metrics_enabled =>
            case maps:get(<<"metrics_enabled">>, Json, undefined) of
                undefined -> undefined;
                V -> parse_opt_bool(V)
            end,
        metrics_addr => parse_addr(maps:get(<<"metrics_addr">>, Json, <<"0.0.0.0">>)),
        metrics_port =>
            case maps:get(<<"metrics_port">>, Json, null) of
                null -> 9090;
                V -> parse_opt_int(V)
            end,
        metrics_max_connections =>
            parse_opt_int(maps:get(<<"metrics_max_connections">>, Json, null)),
        log_level => parse_log_level(maps:get(<<"log_level">>, Json, null)),
        management_num_acceptors => parse_opt_int(maps:get(<<"management_num_acceptors">>, Json, null)),
        management_max_connections => parse_opt_int(maps:get(<<"management_max_connections">>, Json, null)),
        downstream_idle_timeout_ms => parse_opt_int(maps:get(<<"downstream_idle_timeout_ms">>, Json, null)),
        management_idle_timeout_ms => parse_opt_int(maps:get(<<"management_idle_timeout_ms">>, Json, null)),
        upstream_request_timeout_ms => parse_opt_int(maps:get(<<"upstream_request_timeout_ms">>, Json, null)),
        upstream_stream_request_timeout_ms =>
            parse_opt_int(maps:get(<<"upstream_stream_request_timeout_ms">>, Json, null)),
        upstream_pool_size => parse_opt_int(maps:get(<<"upstream_pool_size">>, Json, null)),
        upstream_pool_idle_timeout_secs =>
            parse_opt_int(maps:get(<<"upstream_pool_idle_timeout_secs">>, Json, null)),
        health_cache_refresh_ms =>
            parse_opt_int(maps:get(<<"health_cache_refresh_ms">>, Json, null)),
        rate_limit_enabled =>
            case maps:get(<<"rate_limit_enabled">>, Json, undefined) of
                undefined -> undefined;
                V -> parse_opt_bool(V)
            end,
        rate_limit_rps =>
            parse_opt_int(maps:get(<<"rate_limit_rps">>, Json, null)),
        rate_limit_burst =>
            parse_opt_int(maps:get(<<"rate_limit_burst">>, Json, null)),
        otel_enabled =>
            case maps:get(<<"otel_enabled">>, Json, undefined) of
                undefined -> undefined;
                V -> parse_opt_bool(V)
            end,
        otel_service_name =>
            parse_opt_str(maps:get(<<"otel_service_name">>, Json, null)),
        health_access_log =>
            case maps:get(<<"health_access_log">>, Json, undefined) of
                undefined -> undefined;
                V -> parse_opt_bool(V)
            end,
        health_access_log_sample =>
            parse_opt_int(maps:get(<<"health_access_log_sample">>, Json, null)),
        proxy_access_log =>
            case maps:get(<<"proxy_access_log">>, Json, undefined) of
                undefined -> undefined;
                V -> parse_opt_bool(V)
            end,
        sse_early_flush_enabled =>
            case maps:get(<<"sse_early_flush_enabled">>, Json, true) of
                false -> false;
                _ -> true
            end,
        sse_initial_headers_timeout_ms =>
            parse_opt_int(maps:get(<<"sse_initial_headers_timeout_ms">>, Json, null)),
        event_stream_heartbeat_ms =>
            parse_opt_int(maps:get(<<"event_stream_heartbeat_ms">>, Json, null)),
        %% When true, the management listener uses TLS (same certs as the HTTPS proxy).
        %% This allows browsers to negotiate HTTP/2 via ALPN, enabling WebSocket over HTTP/2 (RFC 8441).
        management_tls_enabled =>
            case maps:get(<<"management_tls_enabled">>, Json, false) of
                true  -> true;
                false -> false;
                _     -> false
            end,
        tls_cert_file   => parse_opt_tls_path(maps:get(<<"tls_cert_file">>, Json, null)),
        tls_key_file    => parse_opt_tls_path(maps:get(<<"tls_key_file">>,  Json, null)),
        sites           => Sites,
        backends        => Backends,
        certificates    => Certificates,
        dns_providers   => DnsProviders
    },
    maps:filter(fun(_K, V) -> V =/= undefined end, Config).

json_to_config_pub(Json) ->
    json_to_config(Json).

parse_sites(In) ->
    [parse_site(S) || S <- json_as_list(In), is_map(S)].

parse_site(S) ->
    #{
        host    => maps:get(<<"host">>,    S),
        backend => maps:get(<<"backend">>, S),
        certificate => parse_opt_str(maps:get(<<"certificate">>, S, null)),
        dns_provider => parse_opt_str(maps:get(<<"dns_provider">>, S, null)),
        challenge_type => parse_opt_challenge_type(maps:get(<<"challenge_type">>, S, null)),
        wildcard => parse_opt_bool(maps:get(<<"wildcard">>, S, null)),
        acme_wildcard_base => parse_opt_str(maps:get(<<"acme_wildcard_base">>, S, null)),
        acme_contact_email => parse_opt_str(maps:get(<<"acme_contact_email">>, S, null)),
        advertise_http3 => parse_opt_bool(maps:get(<<"advertise_http3">>, S, true)),
        sse_early_flush => parse_opt_bool(maps:get(<<"sse_early_flush">>, S, null)),
        auth_url => parse_opt_str(maps:get(<<"auth_url">>, S, null)),
        rate_limit_rps => parse_opt_int(maps:get(<<"rate_limit_rps">>, S, null)),
        rate_limit_burst => parse_opt_int(maps:get(<<"rate_limit_burst">>, S, null)),
        routes  => parse_routes(maps:get(<<"routes">>, S, undefined))
    }.

parse_routes(In) ->
    [parse_route(R) || R <- json_as_list(In), is_map(R)].

parse_route(R) ->
    #{
        path      => maps:get(<<"path">>,      R, <<"/">>),
        path_type => parse_path_type(maps:get(<<"path_type">>, R, <<"prefix">>)),
        rewrite   => parse_opt_str(maps:get(<<"rewrite">>, R, null)),
        sse_early_flush => parse_opt_bool(maps:get(<<"sse_early_flush">>, R, null))
    }.

parse_path_type(<<"exact">>)  -> exact;
parse_path_type(<<"prefix">>) -> prefix;
parse_path_type(_)            -> prefix.

parse_backends(In) ->
    [parse_backend(B) || B <- json_as_list(In), is_map(B)].

parse_string_list(In) ->
    [Str || V <- json_as_list(In), Str <- [parse_opt_str(V)], Str =/= undefined].

parse_certificate_name_list(In) ->
    [
        Str
        || V <- json_as_list(In),
           Str <- [parse_opt_str(V)],
           Str =/= undefined,
           is_valid_certificate_name(Str)
    ].

is_valid_certificate_name(undefined) -> false;
is_valid_certificate_name(<<>>) -> false;
is_valid_certificate_name(Bin) when is_binary(Bin) ->
    case trim_bin(Bin) of
        <<>> -> false;
        T -> not is_digits_only_bin(T)
    end;
is_valid_certificate_name(List) when is_list(List) ->
    is_valid_certificate_name(unicode:characters_to_binary(List, utf8));
is_valid_certificate_name(_) -> false.

trim_bin(Bin) when is_binary(Bin) ->
    unicode:characters_to_binary(string:trim(binary_to_list(Bin)), utf8).

is_digits_only_bin(Bin) when is_binary(Bin), Bin =/= <<>> ->
    lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary:bin_to_list(Bin));
is_digits_only_bin(_) ->
    false.

%% DNS providers: JSON array of strings (legacy) or objects
%% #{<<"name">>, <<"provider_type">>, <<"credentials">>}.
-spec parse_dns_providers(term()) -> [map()].
parse_dns_providers(In) ->
    lists:filtermap(fun parse_dns_provider_elem/1, json_as_list(In)).

parse_dns_provider_elem(Bin) when is_binary(Bin) ->
    case parse_opt_str(Bin) of
        undefined -> false;
        Name -> {true, #{name => Name, provider_type => "label", credentials => #{}}}
    end;
parse_dns_provider_elem(M) when is_map(M) ->
    case maps:get(<<"name">>, M, undefined) of
        undefined ->
            false;
        NameBin when is_binary(NameBin) ->
            parse_dns_provider_named(binary_to_list(NameBin), M);
        NameI when is_integer(NameI) ->
            parse_dns_provider_named(integer_to_list(NameI), M);
        _ ->
            false
    end;
parse_dns_provider_elem(_) ->
    false.

parse_dns_provider_named(Name, M) when is_list(Name) ->
    Pt = case maps:get(<<"provider_type">>, M, <<"label">>) of
        B when is_binary(B) -> binary_to_list(B);
        _ -> "label"
    end,
    Cred0 = maps:get(<<"credentials">>, M, #{}),
    Cred = case Cred0 of
        CM when is_map(CM) -> CM;
        _ -> #{}
    end,
    {true, #{name => Name, provider_type => Pt, credentials => Cred}}.

dns_provider_entry_name(#{name := N}) when is_list(N) -> N;
dns_provider_entry_name(#{name := N}) when is_binary(N) -> binary_to_list(N);
dns_provider_entry_name(Bin) when is_binary(Bin) -> binary_to_list(Bin);
dns_provider_entry_name(_) -> "".

parse_backend(B) ->
    #{
        name                 => maps:get(<<"name">>, B),
        algorithm            => parse_algorithm(maps:get(<<"algorithm">>, B, <<"round_robin">>)),
        upstreams            => parse_upstreams(maps:get(<<"upstreams">>, B, undefined)),
        health_path          => parse_opt_str(maps:get(<<"health_path">>, B, null)),
        health_interval_secs => maps:get(<<"health_interval_secs">>, B, 30),
        grpc_upstream        => parse_opt_bool(maps:get(<<"grpc_upstream">>, B, null))
    }.

parse_algorithm(<<"round_robin">>)      -> round_robin;
parse_algorithm(<<"least_connections">>) -> least_connections;
parse_algorithm(<<"ip_hash">>)          -> ip_hash;
parse_algorithm(_)                      -> round_robin.

parse_mode(<<"proxy">>) -> proxy;
parse_mode(<<"proxy_admin">>) -> proxy;
parse_mode(<<"ingress">>) -> ingress;
parse_mode(_) -> proxy.

parse_upstreams(In) ->
    [#{addr => maps:get(<<"addr">>, U), weight => maps:get(<<"weight">>, U, 1)}
     || U <- json_as_list(In), is_map(U)].

parse_addr(Bin) ->
    case inet:parse_address(binary_to_list(Bin)) of
        {ok, Addr} -> Addr;
        _          -> {0,0,0,0}
    end.

parse_log_level(null) ->
    undefined;
parse_log_level(V) ->
    case pertisk_eproxy_log_level:parse(V) of
        {ok, Level} -> Level;
        error -> undefined
    end.

parse_host_port(S) when is_list(S) ->
    case string:rchr(S, $:) of
        0 ->
            error;
        Pos ->
            HostPart = string:slice(S, 0, Pos),
            PortPart = string:slice(S, Pos + 1),
            case string:to_integer(PortPart) of
                {Port, ""} when Port > 0, Port =< 65535 ->
                    case inet:parse_address(HostPart) of
                        {ok, Addr} ->
                            {ok, Addr, Port};
                        _ ->
                            error
                    end;
                _ ->
                    error
            end
    end.

parse_opt_int(null)             -> undefined;
parse_opt_int(V) when is_integer(V) -> V;
parse_opt_int(_)                -> undefined.

parse_opt_str(null)              -> undefined;
parse_opt_str(V) when is_binary(V) -> binary_to_list(V);
parse_opt_str(_)                 -> undefined.

parse_opt_tls_path(null) -> undefined;
parse_opt_tls_path(V) when is_binary(V) ->
    parse_opt_tls_path(binary_to_list(V));
parse_opt_tls_path(V) when is_list(V) ->
    case string:trim(V) of
        [] -> undefined;
        "[redacted]" -> undefined;
        Path -> Path
    end;
parse_opt_tls_path(_) -> undefined.

sanitize_runtime_tls_paths(Cfg) when is_map(Cfg) ->
    Cert = sanitize_runtime_tls_value(maps:get(tls_cert_file, Cfg, undefined)),
    Key = sanitize_runtime_tls_value(maps:get(tls_key_file, Cfg, undefined)),
    %% TLS listener needs cert+key as a pair. If one side is redacted/invalid,
    %% clear both so normal default resolution can recover safely.
    case {Cert, Key} of
        {C, K} when C =/= undefined, K =/= undefined ->
            Cfg#{tls_cert_file => C, tls_key_file => K};
        _ ->
            maps:without([tls_cert_file, tls_key_file], Cfg)
    end.

sanitize_runtime_tls_value(undefined) -> undefined;
sanitize_runtime_tls_value(null) -> undefined;
sanitize_runtime_tls_value(V) when is_binary(V) ->
    sanitize_runtime_tls_value(binary_to_list(V));
sanitize_runtime_tls_value(V) when is_list(V) ->
    case string:trim(V) of
        [] -> undefined;
        "[redacted]" -> undefined;
        Path -> Path
    end;
sanitize_runtime_tls_value(_) -> undefined.

parse_opt_bool(true) -> true;
parse_opt_bool(false) -> false;
parse_opt_bool(_) -> undefined.

parse_h3_udp_bind(<<"dual_stack">>) -> dual_stack;
parse_h3_udp_bind(<<"split">>) -> split;
parse_h3_udp_bind(dual_stack) -> dual_stack;
parse_h3_udp_bind(split) -> split;
parse_h3_udp_bind(_) -> dual_stack.

parse_opt_challenge_type(<<"http-01">>) -> "http-01";
parse_opt_challenge_type(<<"dns-01">>) -> "dns-01";
parse_opt_challenge_type("http-01") -> "http-01";
parse_opt_challenge_type("dns-01") -> "dns-01";
parse_opt_challenge_type(_) -> undefined.

%% Apply a config map: store in ETS, sync backend workers, rebuild router.
apply_config(Config) ->
    Sites    = maps:get(sites,    Config, []),
    Backends = maps:get(backends, Config, []),
    Certificates = maps:get(certificates, Config, []),
    DnsProviders  = maps:get(dns_providers, Config, []),

    ets:insert(?TAB, {config,   Config}),
    ets:insert(?TAB, {sites,    Sites}),
    ets:insert(?TAB, {backends, Backends}),
    ets:insert(?TAB, {certificates, Certificates}),
    ets:insert(?TAB, {dns_providers, DnsProviders}),

    %% Index backends by name for fast lookup
    lists:foreach(fun(B = #{name := Name}) ->
        ets:insert(?TAB, {{backend, Name}, B})
    end, Backends),

    %% Sync backend worker processes
    sync_backend_workers(Backends),

    _ = pertisk_eproxy_health_cache:invalidate(),

    %% Rebuild the router from sites
    Router = pertisk_eproxy_router:build(Sites),
    ets:insert(?TAB, {router, Router}),

    _ = pertisk_eproxy_log_level:apply(),
    _ = pertisk_eproxy_access_log:refresh_hot_path_flags(),

    lager:info("Config applied: ~w site(s), ~w backend(s), ~w dns provider(s)",
               [length(Sites), length(Backends), length(DnsProviders)]).

sync_backend_workers(Backends) ->
    %% Guard: backend_sup may not be up yet during early init.
    case erlang:whereis(pertisk_eproxy_backend_sup) of
        undefined -> ok;
        _SupPid   -> do_sync_backend_workers(Backends)
    end.

do_sync_backend_workers(Backends) ->
    Wanted = sets:from_list([Name || #{name := Name} <- Backends]),
    %% Stop workers (and health checks) for backends no longer in config.
    lists:foreach(
        fun
            ({{backend, Name}, _Pid, worker, _}) ->
                case sets:is_element(Name, Wanted) of
                    true ->
                        ok;
                    false ->
                        ok = pertisk_eproxy_backend_sup:stop_backend(Name),
                        _ = ets:delete(?TAB, {backend, Name})
                end;
            (_) ->
                ok
        end,
        supervisor:which_children(pertisk_eproxy_backend_sup)
    ),
    lists:foreach(fun(B = #{name := Name}) ->
        case pertisk_eproxy_backend:whereis(Name) of
            undefined ->
                pertisk_eproxy_backend_sup:start_backend(B);
            _Pid ->
                pertisk_eproxy_backend:update(Name, B)
        end
    end, Backends).
