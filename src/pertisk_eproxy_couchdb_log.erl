%% @doc Optional CouchDB access-log sink (best-effort, non-blocking for request path).
-module(pertisk_eproxy_couchdb_log).
-behaviour(gen_server).

-export([start_link/0, log/1, status/0]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(RETRY_MS, 5000).

-record(st, {
    enabled = false :: boolean(),
    url = undefined :: undefined | binary(),
    db_name = <<"pertisk-eproxy">> :: binary(),
    username = undefined :: undefined | binary(),
    password = undefined :: undefined | binary(),
    create_db = true :: boolean(),
    db = undefined,
    retry_ref = undefined :: undefined | reference()
}).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec log(map()) -> ok.
log(Entry) when is_map(Entry) ->
    %% gen_server:cast is no-op if server isn't registered yet, so this is safe.
    gen_server:cast(?SERVER, {log, Entry}),
    ok;
log(_) ->
    ok.

-spec status() -> map().
status() ->
    try
        gen_server:call(?SERVER, status, 1000)
    catch
        _:_ -> #{alive => false}
    end.

init([]) ->
    %% Start couchbeam early so first save doesn't pay the cost.
    _ = application:ensure_all_started(couchbeam),
    St = load_config(),
    lager:info("couchdb log init: enabled=~p url=~p db=~p auth=~p",
               [St#st.enabled, St#st.url, St#st.db_name,
                St#st.username =/= undefined andalso St#st.password =/= undefined]),
    %% Defer first connection attempt so init never blocks on the network.
    {ok, St, {continue, connect}}.

handle_continue(connect, St) ->
    {noreply, try_connect(St)}.

handle_call(status, _From, St) ->
    Reply = #{
        alive => true,
        enabled => St#st.enabled,
        url => St#st.url,
        db => St#st.db_name,
        connected => St#st.db =/= undefined
    },
    {reply, Reply, St};
handle_call(_Req, _From, St) ->
    {reply, ok, St}.

handle_cast({log, _Entry}, #st{enabled = false} = St) ->
    {noreply, St};
handle_cast({log, _Entry}, #st{db = undefined} = St) ->
    %% Not connected yet; drop best-effort. Reconnect is timer-driven.
    {noreply, St};
handle_cast({log, Entry}, #st{db = Db} = St) ->
    Doc = entry_to_doc(Entry),
    case couchbeam:save_doc(Db, Doc) of
        {ok, _} ->
            {noreply, St};
        {error, Reason} ->
            lager:warning("couchdb log save failed: ~p", [Reason]),
            {noreply, schedule_retry(St#st{db = undefined})}
    end;
handle_cast(_Msg, St) ->
    {noreply, St}.

handle_info({retry_connect, Ref}, #st{retry_ref = Ref} = St) ->
    {noreply, try_connect(St#st{retry_ref = undefined})};
handle_info({retry_connect, _}, St) ->
    {noreply, St};
handle_info(_Info, St) ->
    {noreply, St}.

terminate(_Reason, _St) ->
    ok.

code_change(_OldVsn, St, _Extra) ->
    {ok, St}.

load_config() ->
    Raw = case application:get_env(pertisk_eproxy, couchdb_log) of
        {ok, V} -> V;
        _ -> #{}
    end,
    Enabled = cfg_bool(Raw, enabled, false),
    #st{
        enabled = Enabled,
        url = cfg_bin(Raw, url, undefined),
        db_name = cfg_bin(Raw, db, <<"pertisk-eproxy">>),
        username = cfg_bin(Raw, username, undefined),
        password = cfg_bin(Raw, password, undefined),
        create_db = cfg_bool(Raw, create_db, true)
    }.

try_connect(#st{enabled = false} = St) ->
    St;
try_connect(#st{url = undefined} = St) ->
    lager:warning("couchdb log: enabled but url not configured", []),
    St;
try_connect(#st{db = Db} = St) when Db =/= undefined ->
    St;
try_connect(St) ->
    case ensure_db(St) of
        {ok, Db} ->
            lager:info("couchdb log connected: url=~ts db=~ts", [St#st.url, St#st.db_name]),
            St#st{db = Db, retry_ref = undefined};
        {error, Reason} ->
            lager:warning("couchdb log connect failed: ~p", [Reason]),
            schedule_retry(St#st{db = undefined})
    end.

schedule_retry(#st{retry_ref = Ref} = St) when is_reference(Ref) ->
    St;
schedule_retry(St) ->
    Ref = make_ref(),
    _ = erlang:send_after(?RETRY_MS, self(), {retry_connect, Ref}),
    St#st{retry_ref = Ref}.

ensure_db(#st{url = Url, db_name = DbName, username = User, password = Pass, create_db = Create}) ->
    Opts = case {User, Pass} of
        {undefined, _} -> [];
        {_, undefined} -> [];
        {U, P} -> [{basic_auth, {U, P}}]
    end,
    Server = couchbeam:server_connection(Url, Opts),
    case Create of
        true -> couchbeam:open_or_create_db(Server, DbName);
        false -> couchbeam:open_db(Server, DbName)
    end.

entry_to_doc(Entry) ->
    Ts = maps:get(<<"timestamp">>, Entry, iolist_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second), [{offset, "Z"}]))),
    Id = iolist_to_binary([Ts, "-", integer_to_binary(erlang:unique_integer([monotonic, positive]))]),
    Entry#{
        <<"_id">> => Id,
        <<"source">> => <<"pertisk-eproxy">>,
        <<"log_type">> => <<"access">>
    }.

cfg_get(Map, Key, Default) when is_map(Map) ->
    maps:get(Key, Map, Default);
cfg_get(List, Key, Default) when is_list(List) ->
    proplists:get_value(Key, List, Default);
cfg_get(_, _Key, Default) ->
    Default.

cfg_bool(Data, Key, Default) ->
    case cfg_get(Data, Key, Default) of
        true -> true;
        false -> false;
        _ -> Default
    end.

cfg_bin(Data, Key, Default) ->
    case cfg_get(Data, Key, Default) of
        undefined -> undefined;
        V when is_binary(V) -> V;
        V when is_list(V) -> list_to_binary(V);
        V when is_atom(V) -> atom_to_binary(V, utf8);
        _ -> Default
    end.
