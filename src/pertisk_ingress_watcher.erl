%% @doc Watch Kubernetes Ingress + TLS Secrets and reconcile proxy config.
-module(pertisk_ingress_watcher).
-behaviour(gen_server).

-export([start_link/0, trigger_reconcile/0, reconcile_now/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(K8S_NETWORKING_V1, {<<"networking.k8s.io">>, <<"v1">>}).
-define(K8S_CORE_V1, {<<>>, <<"v1">>}).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

trigger_reconcile() ->
    gen_server:cast(?SERVER, reconcile).

%% @doc Run reconcile synchronously (admin CRUD waits for in-memory sites to update).
reconcile_now() ->
    case whereis(?SERVER) of
        undefined -> ok;
        _ -> gen_server:call(?SERVER, reconcile_now, 120000)
    end.

init([]) ->
    pertisk_ingress_status:init(),
    erlang:send_after(pertisk_ingress_env:reconcile_interval_ms(), self(), periodic_reconcile),
    case pertisk_ingress_ekub:init() of
        {ok, Conn} ->
            self() ! reconcile_now,
            self() ! start_watch,
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

handle_call(reconcile_now, _From, State) ->
    {reply, ok, maybe_reconcile(State)};

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
    case maybe_connect(State) of
        {ok, NewState} ->
            maybe_reconcile(NewState);
        {error, NewState} ->
            NewState
    end;
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

maybe_connect(State) ->
    case pertisk_ingress_ekub:init() of
        {ok, Conn} ->
            lager:info("Ingress watcher: ekub reconnected"),
            pertisk_ingress_status:set_watcher_state(disconnected),
            self() ! start_watch,
            {ok, State#{conn => Conn, error => undefined}};
        {error, Reason} ->
            lager:warning("Ingress watcher: ekub reconnect failed: ~p", [Reason]),
            pertisk_ingress_status:set_watcher_state(error),
            {error, State#{error => Reason}}
    end.

full_reconcile(Conn) ->
    Query = list_query(),
    case list_ingresses(Conn, Query) of
        {ok, ListObj} ->
            Ingresses = items_from_list(ListObj),
            Secrets = list_tls_secrets(Conn),
            IngressResult = pertisk_ingress_reconciler:reconcile(Ingresses, Secrets),
            MergedResult = merge_gateway_routes(Conn, IngressResult),
            case MergedResult of
                {ok, Result} ->
                    case pertisk_ingress_config_sync:apply_reconcile_result(Result) of
                        ok ->
                            pertisk_ingress_metrics:record_reconcile(ok, Result),
                            pertisk_ingress_metrics:set_gauges(
                                maps:get(sites, Result, []),
                                maps:get(backends, Result, []),
                                length(maps:get(tls, Result, []))
                            ),
                            pertisk_ingress_status_patcher:maybe_update(Ingresses, Conn),
                            ok;
                        {error, _} = ApplyErr ->
                            pertisk_ingress_metrics:record_reconcile(ApplyErr, Result),
                            ApplyErr
                    end;
                {error, _} = Err ->
                    pertisk_ingress_metrics:record_reconcile(Err, #{}),
                    Err
            end;
        {error, Reason} ->
            {error, {list_ingress, Reason}}
    end.

merge_gateway_routes(_Conn, {error, _} = Err) ->
    Err;
merge_gateway_routes(_Conn, {ok, IngressResult}) ->
    case pertisk_ingress_env:gateway_api_enabled() of
        false ->
            {ok, IngressResult};
        true ->
            case list_httproutes(_Conn, list_query()) of
                {ok, Routes} ->
                    case pertisk_gateway_reconciler:reconcile(Routes) of
                        {ok, GatewayResult} ->
                            {ok, pertisk_gateway_reconciler:merge_results(IngressResult, GatewayResult)};
                        {error, _} = GErr ->
                            GErr
                    end;
                {error, Reason} ->
                    lager:warning("Gateway API HTTPRoute list failed: ~p", [Reason]),
                    {ok, IngressResult}
            end
    end.

list_httproutes(Conn, Query) ->
    Api = {<<"gateway.networking.k8s.io">>, <<"v1">>},
    Read = case pertisk_ingress_env:namespace() of
        all_namespaces ->
            read_cluster_resource(Conn, Api, <<"httproutes">>, Query);
        Ns when is_binary(Ns) ->
            read_cluster_resource(Conn, Api, <<"httproutes">>, [{namespace, Ns} | Query])
    end,
    case Read of
        {ok, ListObj} -> {ok, items_from_list(ListObj)};
        {error, #{<<"code">> := 404}} -> {ok, []};
        {error, _} = Err -> Err
    end.

list_ingresses(Conn, Query) ->
    case pertisk_ingress_env:namespace() of
        all_namespaces ->
            read_cluster_resource(Conn, ?K8S_NETWORKING_V1, <<"ingresses">>, Query);
        _ ->
            ekub:read(ingress, Query, Conn)
    end.

list_tls_secrets(Conn) ->
    Query = list_query(),
    Read = case pertisk_ingress_env:namespace() of
        all_namespaces ->
            read_cluster_resource(Conn, ?K8S_CORE_V1, <<"secrets">>, Query);
        _ ->
            ekub:read(secret, Query, Conn)
    end,
    case Read of
        {ok, ListObj} ->
            All = items_from_list(ListObj),
            [S || S <- All, is_tls_secret(S)];
        {error, Reason} ->
            lager:warning("List secrets failed: ~p", [Reason]),
            []
    end.

read_cluster_resource({_Api, Access}, {Group, Version}, ResourceType, Query) ->
    Endpoint = ekub_api:endpoint(Group, Version, ResourceType, <<>>, <<>>, <<>>),
    case Endpoint of
        <<>> ->
            {error, {resource_not_found, ResourceType}};
        _ ->
            ekub_core:http_request(Endpoint, Query, Access)
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
