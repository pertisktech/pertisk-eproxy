%% @doc Configuration manager for pertisk_eproxy.
%%
%% Stores proxy config in an ETS table for fast concurrent reads.
%% Supports hot-reload: call reload/0 or PUT /api/reload to re-read config
%% from the config file without restarting any listeners.
%%
%% Config format (JSON file pointed to by app env `config_file`):
%%
%%   {
%%     "http_addr":        "0.0.0.0",
%%     "http_port":        8080,
%%     "https_port":       8443,
%%     "management_addr":  "127.0.0.1",
%%     "management_port":  9080,
%%     "tls_cert_file":    "/path/to/cert.pem",
%%     "tls_key_file":     "/path/to/key.pem",
%%     "sites": [
%%       {
%%         "host":    "example.com",
%%         "backend": "my-backend",
%%         "routes": [
%%           {"path": "/api", "path_type": "prefix", "rewrite": "/"},
%%           {"path": "/",    "path_type": "prefix"}
%%         ]
%%       }
%%     ],
%%     "backends": [
%%       {
%%         "name":      "my-backend",
%%         "algorithm": "round_robin",
%%         "upstreams": [
%%           {"addr": "127.0.0.1:3000", "weight": 1},
%%           {"addr": "127.0.0.1:3001", "weight": 1}
%%         ],
%%         "health_path":          "/health",
%%         "health_interval_secs": 30
%%       }
%%     ]
%%   }

-module(pertisk_eproxy_config).
-behaviour(gen_server).

-export([start_link/0]).
-export([get_config/0, get_sites/0, get_backends/0,
         get_backend/1, get_router/0,
         reload/0, put_config/1]).
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
    apply_config(Config),
    {reply, ok, State};

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
    File = config_file(),
    case file:read_file(File) of
        {ok, Bin} ->
            case thoas:decode(Bin) of
                {ok, Json}      -> {ok, json_to_config(Json)};
                {error, Reason} -> {error, {json_parse, Reason}}
            end;
        {error, Reason} ->
            {error, {file_read, Reason}}
    end.

%% Parse JSON map into internal config map with atom keys and typed values.
json_to_config(Json) ->
    Sites    = parse_sites(maps:get(<<"sites">>,    Json, [])),
    Backends = parse_backends(maps:get(<<"backends">>, Json, [])),
    Config = #{
        http_addr       => parse_addr(maps:get(<<"http_addr">>, Json, <<"0.0.0.0">>)),
        http_port       => maps:get(<<"http_port">>, Json, 8080),
        https_port      => parse_opt_int(maps:get(<<"https_port">>, Json, null)),
        management_addr => parse_addr(maps:get(<<"management_addr">>, Json, <<"127.0.0.1">>)),
        management_port => maps:get(<<"management_port">>, Json, 9080),
        tls_cert_file   => parse_opt_str(maps:get(<<"tls_cert_file">>, Json, null)),
        tls_key_file    => parse_opt_str(maps:get(<<"tls_key_file">>,  Json, null)),
        sites           => Sites,
        backends        => Backends
    },
    maps:filter(fun(_K, V) -> V =/= undefined end, Config).

parse_sites(List) ->
    [parse_site(S) || S <- List].

parse_site(S) ->
    #{
        host    => maps:get(<<"host">>,    S),
        backend => maps:get(<<"backend">>, S),
        routes  => parse_routes(maps:get(<<"routes">>, S, []))
    }.

parse_routes(List) ->
    [parse_route(R) || R <- List].

parse_route(R) ->
    #{
        path      => maps:get(<<"path">>,      R, <<"/">>),
        path_type => parse_path_type(maps:get(<<"path_type">>, R, <<"prefix">>)),
        rewrite   => parse_opt_str(maps:get(<<"rewrite">>, R, null))
    }.

parse_path_type(<<"exact">>)  -> exact;
parse_path_type(<<"prefix">>) -> prefix;
parse_path_type(_)            -> prefix.

parse_backends(List) ->
    [parse_backend(B) || B <- List].

parse_backend(B) ->
    #{
        name                 => maps:get(<<"name">>, B),
        algorithm            => parse_algorithm(maps:get(<<"algorithm">>, B, <<"round_robin">>)),
        upstreams            => parse_upstreams(maps:get(<<"upstreams">>, B, [])),
        health_path          => parse_opt_str(maps:get(<<"health_path">>, B, null)),
        health_interval_secs => maps:get(<<"health_interval_secs">>, B, 30)
    }.

parse_algorithm(<<"round_robin">>)      -> round_robin;
parse_algorithm(<<"least_connections">>) -> least_connections;
parse_algorithm(<<"ip_hash">>)          -> ip_hash;
parse_algorithm(_)                      -> round_robin.

parse_upstreams(List) ->
    [#{addr => maps:get(<<"addr">>, U), weight => maps:get(<<"weight">>, U, 1)}
     || U <- List].

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

%% Apply a config map: store in ETS, sync backend workers, rebuild router.
apply_config(Config) ->
    Sites    = maps:get(sites,    Config, []),
    Backends = maps:get(backends, Config, []),

    ets:insert(?TAB, {config,   Config}),
    ets:insert(?TAB, {sites,    Sites}),
    ets:insert(?TAB, {backends, Backends}),

    %% Index backends by name for fast lookup
    lists:foreach(fun(B = #{name := Name}) ->
        ets:insert(?TAB, {{backend, Name}, B})
    end, Backends),

    %% Sync backend worker processes
    sync_backend_workers(Backends),

    %% Rebuild the router from sites
    Router = pertisk_eproxy_router:build(Sites),
    ets:insert(?TAB, {router, Router}),

    lager:info("Config applied: ~w site(s), ~w backend(s)",
               [length(Sites), length(Backends)]).

sync_backend_workers(Backends) ->
    %% Start workers for new backends; existing ones will receive updated config.
    lists:foreach(fun(B = #{name := Name}) ->
        case pertisk_eproxy_backend:whereis(Name) of
            undefined ->
                pertisk_eproxy_backend_sup:start_backend(B);
            _Pid ->
                pertisk_eproxy_backend:update(Name, B)
        end
    end, Backends).
