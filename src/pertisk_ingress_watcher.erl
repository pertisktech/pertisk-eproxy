%% @doc Watch Kubernetes Ingress + TLS Secrets and reconcile proxy config.
-module(pertisk_ingress_watcher).
-behaviour(gen_server).

-export([start_link/0, trigger_reconcile/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

trigger_reconcile() ->
    gen_server:cast(?SERVER, reconcile).

init([]) ->
    pertisk_ingress_status:init(),
    case pertisk_ingress_ekub:init() of
        {ok, Conn} ->
            self() ! reconcile_now,
            self() ! start_watch,
            erlang:send_after(pertisk_ingress_env:reconcile_interval_ms(), self(), periodic_reconcile),
            {ok, #{
                conn => Conn,
                ingress_ref => undefined,
                secret_ref => undefined,
                last_resource_version => undefined
            }};
        {error, Reason} ->
            lager:error("Ingress watcher: ekub init failed: ~p", [Reason]),
            pertisk_ingress_status:set_watcher_state(error),
            {ok, #{conn => undefined, error => Reason}}
    end.

handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(reconcile, State) ->
    {noreply, maybe_reconcile(State)};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(start_watch, State = #{conn := Conn}) ->
    Query = watch_query(),
    case ekub:watch(ingress, Query, Conn) of
        {ok, Ref} ->
            pertisk_ingress_status:set_watcher_state(connected),
            %% Initial reconcile is triggered by periodic_reconcile at init; avoid duplicate reload storm.
            self() ! watch_poll,
            {noreply, State#{ingress_ref => Ref}};
        {error, Reason} ->
            lager:warning("Ingress watch failed: ~p — polling only", [Reason]),
            pertisk_ingress_status:set_watcher_state(error),
            Backoff = pertisk_ingress_env:watch_backoff_ms(),
            erlang:send_after(Backoff, self(), start_watch),
            {noreply, State}
    end;

handle_info(watch_poll, State = #{ingress_ref := Ref}) when Ref =/= undefined ->
    case ekub:watch(Ref) of
        {ok, done} ->
            _ = catch ekub:watch_close(Ref),
            self() ! start_watch,
            {noreply, State#{ingress_ref => undefined}};
        {ok, Events} when is_list(Events) ->
            _ = handle_watch_events(Events),
            self() ! watch_poll,
            {noreply, State};
        {error, timeout} ->
            self() ! watch_poll,
            {noreply, State};
        {error, req_not_found} ->
            lager:warning("Ingress watch closed (req_not_found), restarting watch"),
            _ = catch ekub:watch_close(Ref),
            self() ! start_watch,
            {noreply, State#{ingress_ref => undefined}};
        {error, Reason} ->
            lager:warning("Ingress watch read error: ~p", [Reason]),
            _ = catch ekub:watch_close(Ref),
            Backoff = pertisk_ingress_env:watch_backoff_ms(),
            erlang:send_after(Backoff, self(), start_watch),
            {noreply, State#{ingress_ref => undefined}}
    end;

handle_info(watch_poll, State) ->
    self() ! watch_poll,
    {noreply, State};

handle_info(reconcile_now, State) ->
    {noreply, maybe_reconcile(State)};

handle_info(periodic_reconcile, State) ->
    erlang:send_after(pertisk_ingress_env:reconcile_interval_ms(), self(), periodic_reconcile),
    {noreply, maybe_reconcile(State)};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

maybe_reconcile(State = #{conn := undefined}) ->
    State;
maybe_reconcile(State = #{conn := Conn}) ->
    %% Every replica lists Ingress/Secrets and applies config (read-only K8s API).
    %% Leader election only coordinates lease writes, not config fan-out.
    case full_reconcile(Conn) of
        ok ->
            State;
        {error, Err} ->
            lager:warning("Ingress reconcile failed: ~p", [Err]),
            State
    end.

full_reconcile(Conn) ->
    Query = list_query(),
    case ekub:read(ingress, Query, Conn) of
        {ok, ListObj} ->
            Ingresses = items_from_list(ListObj),
            Secrets = list_tls_secrets(Conn),
            case pertisk_ingress_reconciler:reconcile(Ingresses, Secrets) of
                {ok, Result} ->
                    pertisk_ingress_config_sync:apply_reconcile_result(Result);
                {error, _} = Err ->
                    Err
            end;
        {error, Reason} ->
            {error, {list_ingress, Reason}}
    end.

list_tls_secrets(Conn) ->
    Query = list_query(),
    case ekub:read(secret, Query, Conn) of
        {ok, ListObj} ->
            All = items_from_list(ListObj),
            [S || S <- All, is_tls_secret(S)];
        {error, Reason} ->
            lager:warning("List secrets failed: ~p", [Reason]),
            []
    end.

is_tls_secret(#{<<"type">> := <<"kubernetes.io/tls">>}) ->
    true;
is_tls_secret(#{<<"data">> := Data}) when is_map(Data) ->
    maps:is_key(<<"tls.crt">>, Data);
is_tls_secret(_) ->
    false.

items_from_list(#{<<"items">> := Items}) when is_list(Items) ->
    Items;
items_from_list(Obj) when is_map(Obj) ->
    case maps:is_key(<<"items">>, Obj) of
        true -> maps:get(<<"items">>, Obj, []);
        false -> [Obj]
    end;
items_from_list(_) ->
    [].

watch_query() ->
    base_query() ++ [{watch, true}].

list_query() ->
    base_query().

base_query() ->
    case pertisk_ingress_env:namespace() of
        all_namespaces -> [];
        Ns when is_binary(Ns) -> [{namespace, Ns}]
    end.

handle_watch_events(Events) ->
    Changed = lists:any(
        fun
            (#{<<"type">> := T}) when T =:= <<"ADDED">>; T =:= <<"MODIFIED">>; T =:= <<"DELETED">> ->
                true;
            (_) ->
                false
        end,
        Events
    ),
    case Changed of
        true -> trigger_reconcile();
        false -> ok
    end.
