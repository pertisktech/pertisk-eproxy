%%%-------------------------------------------------------------------
%% @doc Admin management interface with REST API
%% @end
%%%-------------------------------------------------------------------

-module(pertisk_eproxy_admin).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([add_upstream/2, remove_upstream/1, list_upstreams/0, get_status/0]).

-define(SERVER, ?MODULE).
-define(DEFAULT_ADMIN_PORT, 8080).
-define(DEFAULT_UPSTREAMS_FILE, "config/upstreams.json").

-record(state, {
    upstreams = #{}
}).

%%%===================================================================
%% API functions
%%%===================================================================

-spec start_link() -> {ok, Pid} | {error, Reason}
    when Pid :: pid(),
         Reason :: term().
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec add_upstream(Host, Config) -> ok | {error, Reason}
    when Host :: binary() | string(),
         Config :: map(),
         Reason :: term().
add_upstream(Host, Config) ->
    gen_server:call(?SERVER, {add_upstream, Host, Config}).

-spec remove_upstream(Host) -> ok | {error, Reason}
    when Host :: binary() | string(),
         Reason :: term().
remove_upstream(Host) ->
    gen_server:call(?SERVER, {remove_upstream, Host}).

-spec list_upstreams() -> list().
list_upstreams() ->
    gen_server:call(?SERVER, list_upstreams).

-spec get_status() -> map().
get_status() ->
    gen_server:call(?SERVER, get_status).

%%%===================================================================
%% gen_server callbacks
%%%===================================================================

-spec init(Args) -> {ok, State}
    when Args :: term(),
         State :: #state{}.
init([]) ->
    io:format("Initializing admin management interface~n"),
    AdminPort = application:get_env(pertisk_eproxy, admin_port, ?DEFAULT_ADMIN_PORT),
    ListenIP = application:get_env(pertisk_eproxy, listen_addr, "any"),
    ConfiguredUpstreams = load_configured_upstreams(),

    case start_admin_server(AdminPort, ListenIP) of
        ok ->
            io:format("Started admin interface on ~s:~w~n", [ListenIP, AdminPort]),
            {ok, #state{upstreams = ConfiguredUpstreams}};
        {error, Reason} ->
            io:format("Failed to start admin interface: ~p~n", [Reason]),
            {ok, #state{upstreams = ConfiguredUpstreams}}
    end.

-spec handle_call(Request, From, State) -> {reply, Reply, State}
    when Request :: term(),
         From :: {pid(), reference()},
         State :: #state{},
         Reply :: term().
handle_call({add_upstream, Host, Config}, _From, State) ->
    NewUpstreams = maps:put(Host, Config, State#state.upstreams),
    NewState = State#state{upstreams = NewUpstreams},
    ok = persist_upstreams(NewUpstreams),
    io:format("Added upstream: ~p => ~p~n", [Host, Config]),
    {reply, ok, NewState};

handle_call({remove_upstream, Host}, _From, State) ->
    NewUpstreams = maps:remove(Host, State#state.upstreams),
    NewState = State#state{upstreams = NewUpstreams},
    ok = persist_upstreams(NewUpstreams),
    io:format("Removed upstream: ~p~n", [Host]),
    {reply, ok, NewState};

handle_call(list_upstreams, _From, State) ->
    Upstreams = maps:to_list(State#state.upstreams),
    {reply, Upstreams, State};

handle_call(get_status, _From, State) ->
    Status = #{
        upstreams_count => maps:size(State#state.upstreams),
        admin_port => application:get_env(pertisk_eproxy, admin_port, ?DEFAULT_ADMIN_PORT),
        compression_methods => application:get_env(pertisk_eproxy, compression_methods, []),
        acme_enabled => application:get_env(pertisk_eproxy, acme_enabled, false)
    },
    {reply, Status, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-spec handle_cast(Request, State) -> {noreply, State}
    when Request :: term(),
         State :: #state{}.
handle_cast(_Request, State) ->
    {noreply, State}.

-spec handle_info(Info, State) -> {noreply, State}
    when Info :: term(),
         State :: #state{}.
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(Reason, State) -> ok
    when Reason :: term(),
         State :: #state{}.
terminate(_Reason, _State) ->
    io:format("Admin interface terminated~n"),
    ok.

-spec code_change(OldVsn, State, Extra) -> {ok, NewState}
    when OldVsn :: term(),
         State :: #state{},
         Extra :: term(),
         NewState :: #state{}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%% Internal functions
%%%===================================================================

-spec start_admin_server(AdminPort, ListenIP) -> ok | {error, Reason}
    when AdminPort :: integer(),
         ListenIP :: string(),
         Reason :: term().
start_admin_server(AdminPort, ListenIP) ->
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/api/status", pertisk_eproxy_admin_handler, [status]},
            {"/api/upstreams", pertisk_eproxy_admin_handler, [upstreams]},
            {"/api/upstreams/:host", pertisk_eproxy_admin_handler, [upstream]},
            {"/api/certs", pertisk_eproxy_admin_handler, [certs]},
            {"/static/[...]", cowboy_static, {priv_dir, pertisk_eproxy, "static/static"}},
            {"/asset-manifest.json", cowboy_static, {priv_file, pertisk_eproxy, "static/asset-manifest.json"}},
            {"/manifest.json", cowboy_static, {priv_file, pertisk_eproxy, "static/manifest.json"}},
            {"/favicon.ico", cowboy_static, {priv_file, pertisk_eproxy, "static/favicon.ico"}},
            {"/logo192.png", cowboy_static, {priv_file, pertisk_eproxy, "static/logo192.png"}},
            {"/logo512.png", cowboy_static, {priv_file, pertisk_eproxy, "static/logo512.png"}},
            {"/", cowboy_static, {priv_file, pertisk_eproxy, "static/index.html"}},
            {"/dashboard", cowboy_static, {priv_file, pertisk_eproxy, "static/index.html"}},
            {"/sites", cowboy_static, {priv_file, pertisk_eproxy, "static/index.html"}},
            {"/certificates", cowboy_static, {priv_file, pertisk_eproxy, "static/index.html"}},
            {"/settings", cowboy_static, {priv_file, pertisk_eproxy, "static/index.html"}}
        ]}
    ]),

    start_admin_listener(ListenIP, AdminPort, Dispatch).

-spec start_admin_listener(string(), integer(), cowboy_router:dispatch_rules()) -> ok | {error, term()}.
start_admin_listener("any", Port, Dispatch) ->
    start_admin_listener_all_families(Port, Dispatch);
start_admin_listener("*", Port, Dispatch) ->
    start_admin_listener_all_families(Port, Dispatch);
start_admin_listener(IP, Port, Dispatch) ->
    case inet:parse_address(IP) of
        {ok, ParsedIP} when tuple_size(ParsedIP) =:= 4 ->
            start_admin_listener_named(admin_listener_v4, [{ip, ParsedIP}, {port, Port}], Dispatch);
        {ok, ParsedIP} when tuple_size(ParsedIP) =:= 8 ->
            start_admin_listener_named(
                admin_listener_v6,
                [inet6, {ipv6_v6only, true}, {ip, ParsedIP}, {port, Port}],
                Dispatch
            );
        {error, Reason} ->
            {error, Reason}
    end.

-spec start_admin_listener_all_families(integer(), cowboy_router:dispatch_rules()) -> ok | {error, term()}.
start_admin_listener_all_families(Port, Dispatch) ->
    case start_admin_listener_named(admin_listener_v4, [{ip, {0, 0, 0, 0}}, {port, Port}], Dispatch) of
        ok ->
            case start_admin_listener_named(
                admin_listener_v6,
                [inet6, {ipv6_v6only, true}, {ip, {0, 0, 0, 0, 0, 0, 0, 0}}, {port, Port}],
                Dispatch
            ) of
                ok -> ok;
                {error, Reason} -> {error, {admin_ipv6_listener_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {admin_ipv4_listener_failed, Reason}}
    end.

-spec start_admin_listener_named(atom(), list(), cowboy_router:dispatch_rules()) -> ok | {error, term()}.
start_admin_listener_named(Name, TransportOptions, Dispatch) ->
    case cowboy:start_clear(Name, TransportOptions, #{env => #{dispatch => Dispatch}}) of
        {ok, _Pid} -> ok;
        {error, Reason} -> {error, Reason}
    end.

%% Merge static config defaults with persisted UI changes; persisted values win.
-spec load_configured_upstreams() -> map().
load_configured_upstreams() ->
    Configured = maps:from_list(application:get_env(pertisk_eproxy, upstreams, [])),
    Persisted = load_persisted_upstreams(),
    maps:merge(Configured, Persisted).

-spec load_persisted_upstreams() -> map().
load_persisted_upstreams() ->
    UpstreamsFile = application:get_env(pertisk_eproxy, upstreams_file, ?DEFAULT_UPSTREAMS_FILE),
    case file:read_file(UpstreamsFile) of
        {ok, Contents} ->
            try
                Decoded = jiffy:decode(Contents, [return_maps]),
                DecodedUpstreams = maps:get(<<"upstreams">>, Decoded, []),
                maps:from_list([
                    {maps:get(<<"host">>, Upstream), maps:get(<<"config">>, Upstream)}
                    || Upstream <- DecodedUpstreams
                ])
            catch
                _:Reason ->
                    io:format("Failed to decode persisted upstreams: ~p~n", [Reason]),
                    #{}
            end;
        {error, enoent} ->
            #{};
        {error, Reason} ->
            io:format("Failed to read upstreams file: ~p~n", [Reason]),
            #{}
    end.

-spec persist_upstreams(map()) -> ok.
persist_upstreams(Upstreams) ->
    UpstreamsFile = application:get_env(pertisk_eproxy, upstreams_file, ?DEFAULT_UPSTREAMS_FILE),
    ok = filelib:ensure_dir(UpstreamsFile),
    Encoded = jiffy:encode(#{
        upstreams => [
            #{host => Host, config => Config}
            || {Host, Config} <- maps:to_list(Upstreams)
        ]
    }),
    ok = file:write_file(UpstreamsFile, Encoded).
