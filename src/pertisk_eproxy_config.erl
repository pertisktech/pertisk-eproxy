%% @doc Configuration manager for pertisk_eproxy.
%%
%% Loads proxy config from SQLite database at startup.
%% Stores config in an ETS table for fast concurrent reads.
%%
%% Config is stored as JSON and cached in ETS:
%%   - mode (proxy | proxy_admin)
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
-export([get_config/0, get_sites/0, get_backends/0,
         get_certificates/0, get_dns_providers/0,
         get_backend/1, get_router/0,
         reload/0, put_config/1, json_to_config_pub/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(TAB, pertisk_eproxy_config_tab).
-define(SERVER, ?MODULE).

%% ---------------------------------------------------------------------------
%% Public API
%% ---------------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Return the top-level config map.
-spec get_config() -> map().
get_config() ->
    case ets:lookup(?TAB, config) of
        [{config, C}] -> C;
        []            -> #{}
    end.

%% Return list of site maps.
-spec get_sites() -> [map()].
get_sites() ->
    case ets:lookup(?TAB, sites) of
        [{sites, S}] -> S;
        []           -> []
    end.

%% Return list of backend maps.
-spec get_backends() -> [map()].
get_backends() ->
    case ets:lookup(?TAB, backends) of
        [{backends, B}] -> B;
        []              -> []
    end.

%% Return list of certificate record names.
-spec get_certificates() -> [binary() | list()].
get_certificates() ->
    case ets:lookup(?TAB, certificates) of
        [{certificates, C}] -> C;
        []                  -> []
    end.

%% Return list of DNS provider display names (for validation / UI).
-spec get_dns_providers() -> [list()].
get_dns_providers() ->
    case ets:lookup(?TAB, dns_providers) of
        [{dns_providers, D}] when is_list(D) ->
            [dns_provider_entry_name(P) || P <- D];
        [] ->
            []
    end.

%% Return a single backend map by name, or error.
-spec get_backend(binary()) -> {ok, map()} | error.
get_backend(Name) ->
    case ets:lookup(?TAB, {backend, Name}) of
        [{_, B}] -> {ok, B};
        []       -> error
    end.

%% Return the compiled router (pertisk_eproxy_router).
-spec get_router() -> pertisk_eproxy_router:router().
get_router() ->
    case ets:lookup(?TAB, router) of
        [{router, R}] -> R;
        []            -> pertisk_eproxy_router:empty()
    end.

%% Trigger a hot-reload from the config file.
-spec reload() -> ok | {error, term()}.
reload() ->
    gen_server:call(?SERVER, reload, 15000).

%% Replace the in-memory config with a new map (does NOT write to file).
%% Spawns/stops backend workers as needed and refreshes the router.
-spec put_config(map()) -> ok | {error, term()}.
put_config(Config) ->
    gen_server:call(?SERVER, {put_config, Config}, 15000).

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
    Reply = case load_config() of
        {ok, Config} -> apply_config(Config), ok;
        {error, R}   -> {error, R}
    end,
    {reply, Reply, State};

handle_call({put_config, Config}, _From, State) ->
    case persist_runtime_config(Config) of
        ok ->
            apply_config(Config),
            {reply, ok, State};
        {error, R} ->
            {reply, {error, {persist_runtime_config, R}}, State}
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

config_file() ->
    case application:get_env(pertisk_eproxy, config_file) of
        {ok, F} -> F;
        undefined -> "config/proxy.json"
    end.

load_config() ->
    DbPath = db_file(),
    case pertisk_eproxy_db:get_runtime_config(DbPath) of
        {ok, Cfg} when is_map(Cfg) ->
            _ = pertisk_eproxy_db:ensure_certificates_seeded(DbPath, maps:get(certificates, Cfg, [])),
            _ = pertisk_eproxy_db:ensure_dns_providers_seeded(DbPath, maps:get(dns_providers, Cfg, [])),
            {ok, Cfg};
        not_found ->
            load_config_from_file_and_seed(DbPath);
        {error, Reason} ->
            lager:warning("Runtime config in SQLite unavailable (~p), falling back to file", [Reason]),
            load_config_from_file_and_seed(DbPath)
    end.

load_config_from_file_and_seed(DbPath) ->
    File = config_file(),
    case file:read_file(File) of
        {ok, Bin} ->
            case thoas:decode(Bin) of
                {ok, Json} ->
                    Cfg = json_to_config(Json),
                    _ = pertisk_eproxy_db:ensure_certificates_seeded(DbPath, maps:get(certificates, Cfg, [])),
                    _ = pertisk_eproxy_db:ensure_dns_providers_seeded(DbPath, maps:get(dns_providers, Cfg, [])),
                    _ = persist_runtime_config(DbPath, Cfg),
                    {ok, Cfg};
                {error, Reason} ->
                    {error, {json_parse, Reason}}
            end;
        {error, Reason} ->
            {error, {file_read, Reason}}
    end.

persist_runtime_config(Config) ->
    persist_runtime_config(db_file(), Config).

persist_runtime_config(DbPath, Config) ->
    pertisk_eproxy_db:put_runtime_config(DbPath, Config).

db_file() ->
    case application:get_env(pertisk_eproxy, db_file) of
        {ok, F} -> F;
        undefined -> "data/proxy.db"
    end.

%% JSON `null` or non-lists must not crash list comprehensions (maps:get/3 default is
%% ignored when the key is present with value `null`).
-spec json_as_list(term()) -> list().
json_as_list(undefined) -> [];
json_as_list(null) -> [];
json_as_list(L) when is_list(L) -> L;
json_as_list(_) -> [].

%% Parse JSON map into internal config map with atom keys and typed values.
json_to_config(Json) ->
    Sites    = parse_sites(maps:get(<<"sites">>,    Json, undefined)),
    Backends = parse_backends(maps:get(<<"backends">>, Json, undefined)),
    Certificates = parse_string_list(maps:get(<<"certificates">>, Json, undefined)),
    DnsProviders  = parse_dns_providers(maps:get(<<"dns_providers">>, Json, undefined)),
    Config = #{
        mode            => parse_mode(maps:get(<<"mode">>, Json, <<"proxy_admin">>)),
        http_addr       => parse_addr(maps:get(<<"http_addr">>, Json, <<"0.0.0.0">>)),
        http_port       => maps:get(<<"http_port">>, Json, 8080),
        https_port      => parse_opt_int(maps:get(<<"https_port">>, Json, null)),
        management_addr => parse_addr(maps:get(<<"management_addr">>, Json, <<"127.0.0.1">>)),
        management_port => maps:get(<<"management_port">>, Json, 9080),
        tls_cert_file   => parse_opt_str(maps:get(<<"tls_cert_file">>, Json, null)),
        tls_key_file    => parse_opt_str(maps:get(<<"tls_key_file">>,  Json, null)),
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
        acme_contact_email => parse_opt_str(maps:get(<<"acme_contact_email">>, S, null)),
        routes  => parse_routes(maps:get(<<"routes">>, S, undefined))
    }.

parse_routes(In) ->
    [parse_route(R) || R <- json_as_list(In), is_map(R)].

parse_route(R) ->
    #{
        path      => maps:get(<<"path">>,      R, <<"/">>),
        path_type => parse_path_type(maps:get(<<"path_type">>, R, <<"prefix">>)),
        rewrite   => parse_opt_str(maps:get(<<"rewrite">>, R, null))
    }.

parse_path_type(<<"exact">>)  -> exact;
parse_path_type(<<"prefix">>) -> prefix;
parse_path_type(_)            -> prefix.

parse_backends(In) ->
    [parse_backend(B) || B <- json_as_list(In), is_map(B)].

parse_string_list(In) ->
    [Str || V <- json_as_list(In), Str <- [parse_opt_str(V)], Str =/= undefined].

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
        health_interval_secs => maps:get(<<"health_interval_secs">>, B, 30)
    }.

parse_algorithm(<<"round_robin">>)      -> round_robin;
parse_algorithm(<<"least_connections">>) -> least_connections;
parse_algorithm(<<"ip_hash">>)          -> ip_hash;
parse_algorithm(_)                      -> round_robin.

parse_mode(<<"proxy">>) -> proxy;
parse_mode(<<"proxy_admin">>) -> proxy_admin;
parse_mode(_) -> proxy_admin.

parse_upstreams(In) ->
    [#{addr => maps:get(<<"addr">>, U), weight => maps:get(<<"weight">>, U, 1)}
     || U <- json_as_list(In), is_map(U)].

parse_addr(Bin) ->
    case inet:parse_address(binary_to_list(Bin)) of
        {ok, Addr} -> Addr;
        _          -> {0,0,0,0}
    end.

parse_opt_int(null)             -> undefined;
parse_opt_int(V) when is_integer(V) -> V;
parse_opt_int(_)                -> undefined.

parse_opt_str(null)              -> undefined;
parse_opt_str(V) when is_binary(V) -> binary_to_list(V);
parse_opt_str(_)                 -> undefined.

parse_opt_bool(true) -> true;
parse_opt_bool(false) -> false;
parse_opt_bool(_) -> undefined.

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

    %% Rebuild the router from sites
    Router = pertisk_eproxy_router:build(Sites),
    ets:insert(?TAB, {router, Router}),

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
