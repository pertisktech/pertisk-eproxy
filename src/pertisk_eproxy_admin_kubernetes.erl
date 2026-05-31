%% @doc Kubernetes admin API for ingress mode (Sites add/edit Ingress via ekub).
-module(pertisk_eproxy_admin_kubernetes).

-export([
    available/0,
    namespaces/0,
    pods/1,
    services/1,
    tls_secrets/1,
    list_ingresses/0,
    get_ingress/2,
    create_ingress/1,
    update_ingress/3,
    delete_ingress/2
]).

-define(API_VERSION, <<"networking.k8s.io/v1">>).
-define(BACKEND_NAMESPACE_ANNOTATION, <<"pertisk.tech/backend-namespace">>).
-define(BACKEND_NAMESPACE_ANNOTATION_LEGACY, <<"pertisk.io/backend-namespace">>).
-define(BACKEND_NAMESPACES_ANNOTATION, <<"pertisk.tech/backend-namespaces">>).
-define(BACKEND_NAMESPACES_ANNOTATION_LEGACY, <<"pertisk.io/backend-namespaces">>).

available() ->
    pertisk_eproxy_config:ingress_mode().

%% Dashboard: all controller replicas in the release namespace.
pods(Namespace) ->
    with_conn(fun(Conn) ->
        Ns = case trim_optional(Namespace) of
            <<>> -> pertisk_ingress_env:leader_namespace();
            N -> N
        end,
        case ekub_read_pods(Conn, Ns) of
            {ok, List} ->
                Metrics = ekub_read_pod_metrics_map(Conn, Ns),
                {ok, controller_pod_rows(List, Metrics)};
            {error, Reason} ->
                case is_k8s_forbidden(Reason) of
                    true -> {ok, []};
                    false -> {error, Reason}
                end
        end
    end).

%% ekub API discovery registers "pod"/"pods" for every API group; later groups
%% (e.g. metrics.k8s.io) overwrite the alias, so ekub:read(pod, ...) hits the wrong API.
-define(CORE_V1_GROUP, {<<"">>, <<"v1">>}).

ekub_read_pods(Conn, Ns) ->
    {Api, Access} = Conn,
    Endpoint = ekub_api:endpoint(?CORE_V1_GROUP, pod, Ns, "", {Api, Access}),
    case Endpoint of
        <<>> ->
            {error, pod_resource_not_found};
        _ ->
            ekub_core:http_request(Endpoint, [], Access)
    end.

%% PodMetrics (metrics-server); same ekub alias pitfall as core pods — pin API group/version.
-define(METRICS_POD_GROUPS, [
    {<<"metrics.k8s.io">>, <<"v1beta1">>},
    {<<"metrics.k8s.io">>, <<"v1">>}
]).

ekub_read_pod_metrics_map(Conn, Ns) ->
    lists:foldl(
        fun(Group, Acc) ->
            case map_size(Acc) > 0 of
                true ->
                    Acc;
                false ->
                    case ekub_read_pod_metrics(Conn, Ns, Group) of
                        {ok, Map} -> Map;
                        _ -> Acc
                    end
            end
        end,
        #{},
        ?METRICS_POD_GROUPS
    ).

ekub_read_pod_metrics(Conn, Ns, Group) ->
    {Api, Access} = Conn,
    Endpoint = ekub_api:endpoint(Group, pod, Ns, "", {Api, Access}),
    case Endpoint of
        <<>> ->
            {error, pod_metrics_not_found};
        _ ->
            case ekub_core:http_request(Endpoint, [], Access) of
                {ok, List} ->
                    {ok, pod_metrics_map(items_from_list(List))};
                {error, Reason} = Err ->
                    case is_k8s_forbidden(Reason) of
                        true -> {ok, #{}};
                        false -> Err
                    end
            end
    end.

pod_metrics_map(Items) ->
    lists:foldl(
        fun(Item, Acc) ->
            Key = {meta_name(Item), meta_namespace(Item)},
            maps:put(Key, pod_metrics_usage(Item), Acc)
        end,
        #{},
        Items
    ).

pod_metrics_usage(Item) ->
    Containers = maps:get(<<"containers">>, Item, []),
    {CpuSum, MemSum, CpuAny, MemAny} = lists:foldl(
        fun(C, {CAcc, MAcc, CAny, MAny}) ->
            Usage = maps:get(<<"usage">>, C, #{}),
            {C2, CAny2} = add_quantity(cpu_quantity_to_millicores(maps:get(<<"cpu">>, Usage, undefined)), CAcc, CAny),
            {M2, MAny2} = add_quantity(memory_quantity_to_bytes(maps:get(<<"memory">>, Usage, undefined)), MAcc, MAny),
            {C2, M2, CAny2, MAny2}
        end,
        {0, 0, false, false},
        Containers
    ),
    {
        usage_metric(CpuSum, CpuAny),
        usage_metric(MemSum, MemAny)
    }.

add_quantity(undefined, Acc, Any) ->
    {Acc, Any};
add_quantity(null, Acc, Any) ->
    {Acc, Any};
add_quantity(V, Acc, _Any) when is_integer(V) ->
    {Acc + V, true}.

usage_metric(_Sum, false) ->
    null;
usage_metric(Sum, true) ->
    Sum.

controller_pod_rows(List, MetricsMap) ->
    [
        pod_row(P, maps:get({meta_name(P), meta_namespace(P)}, MetricsMap, {null, null}))
     || P <- items_from_list(List),
        is_controller_pod(P)
    ].

%% Match deployment pod name prefix OR Helm selector labels (not both required).
is_controller_pod(Pod) ->
    controller_pod_by_name(Pod) orelse controller_pod_by_labels(Pod).

controller_pod_by_name(Pod) ->
    Name = meta_name(Pod),
    Prefix = controller_pod_name_prefix(),
    case byte_size(Prefix) of
        0 ->
            false;
        _ ->
            case binary:match(Name, Prefix) of
                {0, _} -> true;
                _ -> false
            end
    end.

controller_pod_name_prefix() ->
    <<(pertisk_ingress_env:controller_pod_name())/binary, "-">>.

controller_pod_by_labels(Pod) ->
    case pertisk_ingress_env:controller_pod_label_selector() of
        <<>> ->
            false;
        Sel ->
            pod_matches_label_selector(Pod, Sel)
    end.

pod_matches_label_selector(Pod, SelBin) ->
    Labels = maps:get(<<"labels">>, maps:get(<<"metadata">>, Pod, #{}), #{}),
    lists:all(
        fun({Key, Val}) ->
            maps:get(Key, Labels, undefined) =:= Val
        end,
        parse_label_selector(SelBin)
    ).

parse_label_selector(SelBin) when is_binary(SelBin) ->
    Parts = string:split(binary_to_list(SelBin), ",", all),
    lists:filtermap(
        fun(Part) ->
            P = string:trim(Part),
            case string:split(P, "=", leading) of
                [K, V] ->
                    {true, {list_to_binary(string:trim(K)), list_to_binary(string:trim(V))}};
                _ ->
                    false
            end
        end,
        Parts
    ).

namespaces() ->
    %% Cluster-scoped: never pass watch-namespace filter (unlike ingress/secret list).
    with_conn(fun(Conn) ->
        case ekub:read(namespace, Conn) of
            {ok, List} ->
                Rows = [
                    #{name => meta_name(Ns), created_at => meta_created_at(Ns)}
                    || Ns <- items_from_list(List)
                ],
                {ok, Rows};
            {error, Reason} ->
                {error, Reason}
        end
    end).

services(Namespace) ->
    case namespace_required(Namespace) of
        {error, Msg} -> {error, Msg};
        {ok, Ns} ->
            services_in_namespace(Ns)
    end.

services_in_namespace(Ns) ->
    with_conn(fun(Conn) ->
        case ekub:read(service, Ns, [], Conn) of
            {ok, List} ->
                Rows = [service_row(Svc) || Svc <- items_from_list(List)],
                {ok, Rows};
            {error, Reason} ->
                {error, Reason}
        end
    end).

tls_secrets(Namespace) ->
    with_conn(fun(Conn) ->
        Query = list_query(),
        Read = case Namespace of
            <<>> -> ekub:read(secret, Query, Conn);
            Ns -> ekub:read(secret, Ns, [], Conn)
        end,
        case Read of
            {ok, List} ->
                Rows = [
                    #{
                        namespace => meta_namespace(S),
                        name => meta_name(S),
                        issued_at => null,
                        expires_at => null
                    }
                    || S <- items_from_list(List), is_tls_secret(S)
                ],
                case Rows of
                    [] ->
                        fallback_tls_secrets_from_ingresses(Conn, Namespace, {ok, Rows});
                    _ ->
                        {ok, Rows}
                end;
            {error, Reason} ->
                fallback_tls_secrets_from_ingresses(Conn, Namespace, {error, Reason})
        end
    end).

fallback_tls_secrets_from_ingresses(Conn, Namespace, Fallback) ->
    IngressRead = case Namespace of
        <<>> -> ekub:read(ingress, list_query(), Conn);
        Ns -> ekub:read(ingress, Ns, [], Conn)
    end,
    case IngressRead of
        {ok, IngressList} ->
            Inferred = infer_tls_rows_from_ingresses(items_from_list(IngressList)),
            case Inferred of
                [] -> Fallback;
                _ -> {ok, Inferred}
            end;
        {error, _} ->
            Fallback
    end.

infer_tls_rows_from_ingresses(Ingresses) ->
    Rows0 = lists:flatmap(
        fun(I) ->
            Ns = meta_namespace(I),
            Spec = maps:get(<<"spec">>, I, #{}),
            Tls = maps:get(<<"tls">>, Spec, []),
            [
                # {
                    namespace => Ns,
                    name => Secret,
                    issued_at => null,
                    expires_at => null
                }
                || T <- Tls,
                   is_map(T),
                   Secret <- [maps:get(<<"secretName">>, T, undefined)],
                   is_binary(Secret), Secret =/= <<>>
            ]
        end,
        Ingresses
    ),
    dedupe_tls_rows(Rows0).

dedupe_tls_rows(Rows) ->
    {_Seen, Out} = lists:foldl(
        fun(Row, {Seen, Acc}) ->
            Key = {maps:get(namespace, Row, <<>>), maps:get(name, Row, <<>>)},
            case sets:is_element(Key, Seen) of
                true -> {Seen, Acc};
                false -> {sets:add_element(Key, Seen), [Row | Acc]}
            end
        end,
        {sets:new(), []},
        Rows
    ),
    lists:reverse(Out).

list_ingresses() ->
    with_conn(fun(Conn) ->
        case ekub:read(ingress, list_query(), Conn) of
            {ok, List} ->
                ClassFilter = pertisk_ingress_env:ingress_class(),
                Rows = [
                    ingress_list_row(I)
                    || I <- items_from_list(List),
                       pertisk_ingress_reconciler:ingress_matches_class(I, ClassFilter)
                ],
                {ok, Rows};
            {error, Reason} ->
                {error, Reason}
        end
    end).

get_ingress(Namespace, Name) ->
    with_conn(fun(Conn) ->
        case ekub:read(ingress, Namespace, Name, Conn) of
            {ok, Ingress} when is_map(Ingress) ->
                case ingress_form_row(Ingress) of
                    {ok, Row} -> {ok, Row};
                    {error, Msg} -> {error, Msg}
                end;
            {error, Reason} ->
                {error, Reason}
        end
    end).

create_ingress(Body) ->
    with_conn(fun(Conn) ->
        case build_ingress_resource(Body, undefined) of
            {ok, Resource, Ns} ->
                case ekub:create(Resource, Ns, Conn) of
                    {ok, _} ->
                        reconcile_after_ingress_write(),
                        Meta = maps:get(<<"metadata">>, Resource, #{}),
                        {ok, #{
                            message => <<"Ingress created">>,
                            name => maps:get(<<"name">>, Meta, <<>>),
                            namespace => Ns
                        }};
                    {error, Reason} ->
                        {error, Reason}
                end;
            {error, Msg} ->
                {error, Msg}
        end
    end).

update_ingress(Namespace, Name, Body) ->
    with_conn(fun(Conn) ->
        case ekub:read(ingress, Namespace, Name, Conn) of
            {ok, Current} when is_map(Current) ->
                case build_ingress_resource(Body, Current) of
                    {ok, Resource, Ns} ->
                        case ekub:replace(Resource, Ns, Conn) of
                            {ok, _} ->
                                reconcile_after_ingress_write(),
                                {ok, #{
                                    message => <<"Ingress updated">>,
                                    name => Name,
                                    namespace => Ns
                                }};
                            {error, Reason} ->
                                {error, Reason}
                        end;
                    {error, Msg} ->
                        {error, Msg}
                end;
            {error, Reason} ->
                {error, Reason}
        end
    end).

delete_ingress(Namespace, Name) ->
    with_conn(fun(Conn) ->
        case ekub:delete(ingress, Namespace, Name, Conn) of
            {ok, _} ->
                reconcile_after_ingress_delete(Namespace, Name);
            {error, #{<<"code">> := 404}} ->
                reconcile_after_ingress_delete(Namespace, Name);
            {error, #{<<"reason">> := <<"NotFound">>}} ->
                reconcile_after_ingress_delete(Namespace, Name);
            {error, DelReason} ->
                {error, DelReason}
        end
    end).

reconcile_after_ingress_delete(Namespace, Name) ->
    reconcile_after_ingress_write(),
    {ok, #{
        message => <<"Ingress deleted">>,
        name => Name,
        namespace => Namespace
    }}.

reconcile_after_ingress_write() ->
    %% Do not block the admin HTTP response on a full-cluster reconcile (ingress/proxy timeouts).
    pertisk_ingress_watcher:trigger_reconcile().

%% ---------------------------------------------------------------------------
%% Internal
%% ---------------------------------------------------------------------------

with_conn(Fun) ->
    case available() of
        false ->
            {error, not_available};
        true ->
            case pertisk_ingress_ekub:init() of
                {ok, Conn} -> Fun(Conn);
                {error, Reason} -> {error, Reason}
            end
    end.

list_query() ->
    case pertisk_ingress_env:namespace() of
        all_namespaces -> [];
        Ns when is_binary(Ns) -> [{namespace, Ns}]
    end.

namespace_required(<<>>) ->
    {error, <<"namespace query parameter is required">>};
namespace_required(Ns) when is_binary(Ns) ->
    {ok, Ns}.

pod_row(Pod, {CpuMilli, MemBytes}) ->
    Spec = maps:get(<<"spec">>, Pod, #{}),
    Status = maps:get(<<"status">>, Pod, #{}),
    NodeName = maps:get(<<"nodeName">>, Spec, undefined),
    {Ready, Restarts} = pod_ready_restarts(maps:get(<<"containerStatuses">>, Status, [])),
    #{
        <<"name">> => meta_name(Pod),
        <<"namespace">> => meta_namespace(Pod),
        <<"phase">> => maps:get(<<"phase">>, Status, <<"Unknown">>),
        <<"node">> => maybe_null(NodeName),
        <<"node_name">> => maybe_null(NodeName),
        <<"pod_ip">> => maybe_null(maps:get(<<"podIP">>, Status, undefined)),
        <<"ready">> => Ready,
        <<"restarts">> => Restarts,
        <<"cpu_usage_millicores">> => maybe_null(CpuMilli),
        <<"memory_usage_bytes">> => maybe_null(MemBytes),
        <<"created_at">> => meta_created_at(Pod)
    }.

%% Kubernetes resource.Quantity (subset; matches metrics-server / kubectl top).
cpu_quantity_to_millicores(undefined) ->
    undefined;
cpu_quantity_to_millicores(Q) when is_binary(Q) ->
    case parse_quantity_parts(Q) of
        {ok, Num, <<>>} ->
            trunc(Num * 1000);
        {ok, Num, <<"n">>} ->
            %% metrics-server reports CPU in nanocores (e.g. "18273417n"); round for kubectl-like display
            round(Num / 1000000);
        {ok, Num, <<"u">>} ->
            trunc(Num / 1000);
        {ok, Num, <<"m">>} ->
            trunc(Num);
        _ ->
            undefined
    end.

memory_quantity_to_bytes(undefined) ->
    undefined;
memory_quantity_to_bytes(Q) when is_binary(Q) ->
    case parse_quantity_parts(Q) of
        {ok, Num, <<>>} ->
            trunc(Num);
        {ok, Num, <<"Ki">>} ->
            trunc(Num * 1024);
        {ok, Num, <<"Mi">>} ->
            trunc(Num * 1024 * 1024);
        {ok, Num, <<"Gi">>} ->
            trunc(Num * 1024 * 1024 * 1024);
        {ok, Num, <<"Ti">>} ->
            trunc(Num * 1024 * 1024 * 1024 * 1024);
        {ok, Num, <<"Pi">>} ->
            trunc(Num * 1024 * 1024 * 1024 * 1024 * 1024);
        {ok, Num, <<"Ei">>} ->
            trunc(Num * 1024 * 1024 * 1024 * 1024 * 1024 * 1024);
        {ok, Num, <<"K">>} ->
            trunc(Num * 1000);
        {ok, Num, <<"M">>} ->
            trunc(Num * 1000 * 1000);
        {ok, Num, <<"G">>} ->
            trunc(Num * 1000 * 1000 * 1000);
        {ok, Num, <<"T">>} ->
            trunc(Num * 1000 * 1000 * 1000 * 1000);
        {ok, Num, <<"P">>} ->
            trunc(Num * 1000 * 1000 * 1000 * 1000 * 1000);
        {ok, Num, <<"E">>} ->
            trunc(Num * 1000 * 1000 * 1000 * 1000 * 1000 * 1000);
        _ ->
            undefined
    end.

parse_quantity_parts(Q) ->
    case re:run(Q, "^([0-9]+(?:\\.[0-9]+)?)([A-Za-z]*)$", [{capture, all_but_first, binary}]) of
        {match, [NumBin, Suffix]} ->
            try
                Num =
                    case binary:match(NumBin, <<".">>) of
                        nomatch -> binary_to_integer(NumBin) * 1.0;
                        _ -> binary_to_float(NumBin)
                    end,
                {ok, Num, Suffix}
            catch
                _:_ -> error
            end;
        _ ->
            error
    end.

pod_ready_restarts([]) ->
    {<<"0/0">>, 0};
pod_ready_restarts(Cs) when is_list(Cs) ->
    Total = length(Cs),
    ReadyCount = length([C || C <- Cs, maps:get(<<"ready">>, C, false) =:= true]),
    Restarts = lists:sum([maps:get(<<"restartCount">>, C, 0) || C <- Cs]),
    Ready = iolist_to_binary(io_lib:format("~w/~w", [ReadyCount, Total])),
    {Ready, Restarts}.

service_row(Svc) ->
    Spec = maps:get(<<"spec">>, Svc, #{}),
    Status = maps:get(<<"status">>, Svc, #{}),
    Ports = maps:get(<<"ports">>, Spec, []),
    PortDetails = [service_port_detail(P) || P <- Ports],
    PortStrs = [service_port_str(P) || P <- Ports],
    #{
        name => meta_name(Svc),
        namespace => meta_namespace(Svc),
        type => maps:get(<<"type">>, Spec, <<"ClusterIP">>),
        cluster_ip => maybe_null(maps:get(<<"clusterIP">>, Spec, undefined)),
        external_ip => external_ip_from_status(Status),
        ports => PortStrs,
        ports_detail => PortDetails,
        created_at => meta_created_at(Svc)
    }.

service_port_detail(P) ->
    #{
        port => maps:get(<<"port">>, P, 0),
        name => maybe_null(maps:get(<<"name">>, P, undefined)),
        protocol => maps:get(<<"protocol">>, P, <<"TCP">>)
    }.

service_port_str(P) ->
    Num = maps:get(<<"port">>, P, 0),
    Proto = maps:get(<<"protocol">>, P, <<"TCP">>),
    iolist_to_binary([integer_to_binary(Num), <<"/">>, Proto]).

external_ip_from_status(Status) ->
    case maps:get(<<"loadBalancer">>, Status, undefined) of
        #{<<"ingress">> := Ingresses} when is_list(Ingresses) ->
            Ips = [
                Ip
                || #{<<"ip">> := Ip} <- Ingresses,
                   is_binary(Ip), Ip =/= <<>>
            ],
            case Ips of
                [] -> null;
                _ -> iolist_to_binary(string:join([binary_to_list(I) || I <- Ips], ", "))
            end;
        _ ->
            null
    end.

ingress_list_row(Ingress) ->
    Ns = meta_namespace(Ingress),
    Name = meta_name(Ingress),
    Spec = maps:get(<<"spec">>, Ingress, #{}),
    Rules = maps:get(<<"rules">>, Spec, []),
    Host =
        case Rules of
            [#{<<"host">> := H} | _] when is_binary(H) -> H;
            _ -> <<>>
        end,
    #{
        namespace => Ns,
        name => Name,
        host => Host,
        ingress_class_name => maps:get(<<"ingressClassName">>, Spec, null),
        tls_secret_name => tls_secret_from_spec(Spec)
    }.

ingress_form_row(Ingress) ->
    Ns = meta_namespace(Ingress),
    Name = meta_name(Ingress),
    ServiceNs = backend_namespace_from_meta(Ingress, Ns),
    ServiceNsByName = backend_namespace_map_from_meta(Ingress),
    Spec = maps:get(<<"spec">>, Ingress, undefined),
    case Spec of
        undefined ->
            {error, <<"Ingress has no spec">>};
        _ ->
            Rules = maps:get(<<"rules">>, Spec, []),
            case Rules of
                [Rule | _] ->
                    Host = maps:get(<<"host">>, Rule, <<"*">>),
                    Routes = paths_from_rule(Rule, ServiceNs, ServiceNsByName),
                    TlsSecret = tls_secret_from_spec(Spec),
                    First = hd(Routes),
                    {ok, #{
                        namespace => Ns,
                        name => Name,
                        host => Host,
                        service_namespace => ServiceNs,
                        routes => Routes,
                        path => maps:get(path, First, <<"/">>),
                        path_type => maps:get(path_type, First, <<"Prefix">>),
                        tls_secret_namespace => tls_secret_namespace(TlsSecret, Ns),
                        tls_secret_name => TlsSecret,
                        service_name => maps:get(service_name, First, <<>>),
                        service_port => maps:get(service_port, First, null),
                        service_port_name => maps:get(service_port_name, First, null),
                        ingress_class_name => maps:get(<<"ingressClassName">>, Spec, null)
                    }};
                [] ->
                    {error, <<"Ingress has no rules">>}
            end
    end.

paths_from_rule(Rule, DefaultServiceNs, ServiceNsByName) ->
    case maps:get(<<"http">>, Rule, undefined) of
        #{<<"paths">> := Paths} when is_list(Paths), Paths =/= [] ->
            [path_row(P, DefaultServiceNs, ServiceNsByName) || P <- Paths];
        _ ->
            [#{
                path => <<"/">>,
                path_type => <<"Prefix">>,
                service_namespace => DefaultServiceNs,
                service_name => <<>>,
                service_port => null,
                service_port_name => null
            }]
    end.

path_row(Path, DefaultServiceNs, ServiceNsByName) ->
    {SvcName, PortNum, PortName} = backend_from_path(Path),
    ServiceNs = resolve_backend_service_namespace(SvcName, DefaultServiceNs, ServiceNsByName),
    #{
        path => maps:get(<<"path">>, Path, <<"/">>),
        path_type => maps:get(<<"pathType">>, Path, <<"Prefix">>),
        service_namespace => ServiceNs,
        service_name => SvcName,
        service_port => PortNum,
        service_port_name => PortName
    }.

backend_from_path(#{<<"backend">> := #{<<"service">> := #{<<"name">> := Name, <<"port">> := Port}}}) ->
    {Num, PName} = service_port_fields(Port),
    {Name, Num, PName};
backend_from_path(_) ->
    {<<>>, null, null}.

service_port_fields(#{<<"number">> := N}) when is_integer(N) ->
    {N, null};
service_port_fields(#{<<"name">> := Name}) when is_binary(Name) ->
    {null, Name};
service_port_fields(_) ->
    {null, null}.

tls_secret_from_spec(Spec) ->
    case maps:get(<<"tls">>, Spec, []) of
        [Tls | _] -> maps:get(<<"secretName">>, Tls, null);
        _ -> null
    end.

tls_secret_namespace(null, _Ns) ->
    null;
tls_secret_namespace(_, Ns) ->
    Ns.

build_ingress_resource(Body, Current) ->
    try
        Host = trim_required(maps:get(<<"host">>, Body, <<>>), <<"host is required">>),
        ServiceNs = trim_required(
            maps:get(<<"service_namespace">>, Body, <<>>),
            <<"service_namespace is required">>
        ),
        IngressNs = case maps:get(<<"ingress_namespace">>, Body, undefined) of
            V when is_binary(V), V =/= <<>> -> trim(V);
            _ -> ServiceNs
        end,
        IngressName = case maps:get(<<"name">>, Body, undefined) of
            V2 when is_binary(V2), V2 =/= <<>> ->
                trim(V2);
            _ when Current =/= undefined ->
                meta_name(Current);
            _ ->
                host_to_ingress_name(Host)
        end,
        Paths = paths_from_body(Body),
        ServiceNsByName = route_backend_namespaces(Body, ServiceNs),
        Class = ingress_class_from_body(Body),
        Spec0 = #{
            <<"rules">> => [
                #{
                    <<"host">> => Host,
                    <<"http">> => #{<<"paths">> => Paths}
                }
            ]
        },
        Spec1 = case Class of
            undefined -> Spec0;
            C -> Spec0#{<<"ingressClassName">> => C}
        end,
        Spec2 = maybe_tls_spec(Spec1, Host, IngressNs, Body, Current),
        Meta0 = case Current of
            undefined ->
                #{<<"name">> => IngressName, <<"namespace">> => IngressNs};
            Cur ->
                maps:get(<<"metadata">>, Cur, #{})
        end,
        Meta1 = maps:merge(Meta0, #{<<"name">> => IngressName, <<"namespace">> => IngressNs}),
        Meta = set_backend_namespace_meta(Meta1, ServiceNs, ServiceNsByName),
        Resource = #{
            <<"apiVersion">> => ?API_VERSION,
            <<"kind">> => <<"Ingress">>,
            <<"metadata">> => Meta,
            <<"spec">> => Spec2
        },
        {ok, Resource, IngressNs}
    catch
        throw:{bad_request, Msg} ->
            {error, Msg};
        error:Reason ->
            {error, format_build_error(Reason)};
        exit:Reason ->
            {error, format_build_error(Reason)}
    end.

format_build_error(Reason) ->
    iolist_to_binary(io_lib:format("ingress build failed: ~p", [Reason])).

paths_from_body(Body) ->
    Routes = maps:get(<<"routes">>, Body, undefined),
    case Routes of
        [_ | _] = List ->
            [path_from_route(R, Body) || R <- List];
        _ ->
            [path_from_legacy_body(Body)]
    end.

path_from_route(Route, _Body) ->
    Path = case maps:get(<<"path">>, Route, <<>>) of
        <<>> -> <<"/">>;
        P -> trim(P)
    end,
    PathType = case maps:get(<<"path_type">>, Route, <<"Prefix">>) of
        <<>> -> <<"Prefix">>;
        PT -> trim(PT)
    end,
    SvcName = trim_required(maps:get(<<"service_name">>, Route, <<>>), <<"each route requires service_name">>),
    Port = backend_port_from_route(Route),
    http_path(Path, PathType, SvcName, Port).

path_from_legacy_body(Body) ->
    _ServiceNs = trim_required(maps:get(<<"service_namespace">>, Body, <<>>), <<"service_namespace is required">>),
    Path = case maps:get(<<"path">>, Body, <<"/">>) of
        <<>> -> <<"/">>;
        P -> trim(P)
    end,
    PathType = case maps:get(<<"path_type">>, Body, <<"Prefix">>) of
        <<>> -> <<"Prefix">>;
        PT -> trim(PT)
    end,
    SvcName = trim_required(maps:get(<<"service_name">>, Body, <<>>), <<"service_name is required">>),
    Port = backend_port_from_body(Body),
    http_path(Path, PathType, SvcName, Port).

http_path(Path, PathType, SvcName, Port) ->
    #{
        <<"path">> => Path,
        <<"pathType">> => PathType,
        <<"backend">> => #{
            <<"service">> => #{
                <<"name">> => SvcName,
                <<"port">> => Port
            }
        }
    }.

backend_port_from_route(Route) ->
    backend_port_from_fields(
        maps:get(<<"service_port">>, Route, undefined),
        maps:get(<<"service_port_name">>, Route, undefined),
        <<"each route requires service_port or service_port_name">>
    ).

backend_port_from_body(Body) ->
    backend_port_from_fields(
        maps:get(<<"service_port">>, Body, undefined),
        maps:get(<<"service_port_name">>, Body, undefined),
        <<"service_port or service_port_name is required">>
    ).

backend_port_from_fields(Port, PortName, ErrMsg) ->
    case Port of
        N when is_integer(N), N > 0 ->
            #{<<"number">> => N};
        _ ->
            case coerce_binary(PortName) of
                <<>> ->
                    throw({bad_request, ErrMsg});
                Name ->
                    #{<<"name">> => Name}
            end
    end.

maybe_tls_spec(Spec, Host, IngressNs, Body, Current) ->
    TlsNs0 = maps:get(<<"tls_secret_namespace">>, Body, undefined),
    TlsName = maps:get(<<"tls_secret_name">>, Body, undefined),
    TlsNs = case tls_bin(TlsNs0) of
        <<>> -> IngressNs;
        Ns -> Ns
    end,
    case {TlsNs, tls_bin(TlsName)} of
        {SecretNs, Name} when SecretNs =/= <<>>, Name =/= <<>> ->
            if
                SecretNs =/= IngressNs ->
                    throw({bad_request, <<"TLS secret must be in the same namespace as the Ingress">>});
                true ->
                    Spec#{
                        <<"tls">> => [
                            #{
                                <<"hosts">> => [Host],
                                <<"secretName">> => Name
                            }
                        ]
                    }
            end;
        _ when Current =/= undefined ->
            %% Replace must clear prior tls when admin UI selects "No TLS"
            Spec#{<<"tls">> => []};
        _ ->
            Spec
    end.

tls_bin(V) when is_binary(V) -> trim(V);
tls_bin(_) -> <<>>.

ingress_class_from_body(Body) ->
    case maps:get(<<"ingress_class_name">>, Body, undefined) of
        C when is_binary(C), C =/= <<>> -> trim(C);
        _ ->
            case pertisk_ingress_env:ingress_class() of
                {ok, Class} -> Class;
                all -> undefined
            end
    end.

host_to_ingress_name(Host) ->
    binary:replace(binary:replace(Host, <<".">>, <<"-">>, [global]), <<"*">>, <<"wildcard">>, [global]).

items_from_list(#{<<"items">> := Items}) when is_list(Items) ->
    Items;
items_from_list(Items) when is_list(Items) ->
    Items;
items_from_list(Obj) when is_map(Obj) ->
    case maps:is_key(<<"items">>, Obj) of
        true -> maps:get(<<"items">>, Obj, []);
        false -> [Obj]
    end;
items_from_list(_) ->
    [].

is_tls_secret(#{<<"type">> := <<"kubernetes.io/tls">>}) ->
    true;
is_tls_secret(#{<<"data">> := Data}) when is_map(Data) ->
    maps:is_key(<<"tls.crt">>, Data);
is_tls_secret(_) ->
    false.

meta_name(Obj) ->
    maps:get(<<"name">>, maps:get(<<"metadata">>, Obj, #{}), <<"">>).

meta_namespace(Obj) ->
    maps:get(<<"namespace">>, maps:get(<<"metadata">>, Obj, #{}), <<"default">>).

meta_created_at(Obj) ->
    case maps:get(<<"creationTimestamp">>, maps:get(<<"metadata">>, Obj, #{}), undefined) of
        T when is_binary(T) -> T;
        _ -> null
    end.

maybe_null(undefined) -> null;
maybe_null(null) -> null;
maybe_null(V) -> V.

trim(V) ->
    case coerce_binary(V) of
        <<>> -> <<>>;
        B -> list_to_binary(string:trim(binary_to_list(B), both))
    end.

trim_required(V, Msg) ->
    T = trim(V),
    case T of
        <<>> -> throw({bad_request, Msg});
        _ -> T
    end.

trim_optional(V) ->
    trim(V).

is_k8s_forbidden({error, Reason}) ->
    is_k8s_forbidden(Reason);
is_k8s_forbidden(Reason) when is_map(Reason) ->
    case Reason of
        #{<<"code">> := 403} -> true;
        #{<<"code">> := <<"403">>} -> true;
        #{<<"reason">> := <<"Forbidden">>} -> true;
        #{<<"status">> := #{<<"code">> := 403}} -> true;
        #{<<"status">> := #{<<"code">> := <<"403">>} } -> true;
        #{<<"status">> := #{<<"reason">> := <<"Forbidden">>} } -> true;
        _ ->
            case maps:get(<<"message">>, Reason, <<>>) of
                Msg when is_binary(Msg) ->
                    binary:match(Msg, <<"Forbidden">>) =/= nomatch orelse
                        binary:match(Msg, <<"forbidden">>) =/= nomatch;
                _ ->
                    false
            end
    end;
is_k8s_forbidden(_) ->
    false.

%% JSON null / numbers must not crash trim/trim_required (thoas decodes null as null).
coerce_binary(null) -> <<>>;
coerce_binary(undefined) -> <<>>;
coerce_binary(B) when is_binary(B) -> B;
coerce_binary(L) when is_list(L) -> list_to_binary(L);
coerce_binary(N) when is_integer(N) -> integer_to_binary(N);
coerce_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
coerce_binary(_) -> <<>>.

route_backend_namespaces(Body, DefaultNs) ->
    Routes = maps:get(<<"routes">>, Body, undefined),
    case Routes of
        [_ | _] = List ->
            lists:foldl(
                fun(Route, Acc) ->
                    Svc = trim(maps:get(<<"service_name">>, Route, <<>>)),
                    case Svc of
                        <<>> ->
                            Acc;
                        _ ->
                            Ns = service_namespace_from_route(Route, DefaultNs),
                            maps:put(Svc, Ns, Acc)
                    end
                end,
                #{},
                List
            );
        _ ->
            LegacySvc = trim(maps:get(<<"service_name">>, Body, <<>>)),
            case LegacySvc of
                <<>> -> #{};
                _ -> #{LegacySvc => DefaultNs}
            end
    end.

service_namespace_from_route(Route, DefaultNs) ->
    case trim(maps:get(<<"service_namespace">>, Route, <<>>)) of
        <<>> -> DefaultNs;
        Ns -> Ns
    end.

resolve_backend_service_namespace(<<>>, DefaultNs, _ByService) ->
    DefaultNs;
resolve_backend_service_namespace(SvcName, DefaultNs, ByService) ->
    maps:get(SvcName, ByService, DefaultNs).

backend_namespace_from_meta(Ingress, DefaultNs) ->
    Meta = maps:get(<<"metadata">>, Ingress, #{}),
    Annotations = maps:get(<<"annotations">>, Meta, #{}),
    case maps:get(?BACKEND_NAMESPACE_ANNOTATION, Annotations, undefined) of
        Ns when is_binary(Ns), Ns =/= <<>> ->
            Ns;
        _ ->
            case maps:get(?BACKEND_NAMESPACE_ANNOTATION_LEGACY, Annotations, undefined) of
                Legacy when is_binary(Legacy), Legacy =/= <<>> -> Legacy;
                _ -> DefaultNs
            end
    end.

backend_namespace_map_from_meta(Ingress) ->
    Meta = maps:get(<<"metadata">>, Ingress, #{}),
    Annotations = maps:get(<<"annotations">>, Meta, #{}),
    Encoded = case maps:get(?BACKEND_NAMESPACES_ANNOTATION, Annotations, undefined) of
        Json when is_binary(Json), Json =/= <<>> -> Json;
        _ -> maps:get(?BACKEND_NAMESPACES_ANNOTATION_LEGACY, Annotations, <<>>)
    end,
    decode_backend_namespace_map(Encoded).

decode_backend_namespace_map(Json) when is_binary(Json), Json =/= <<>> ->
    case thoas:decode(Json) of
        {ok, Map} when is_map(Map) ->
            maps:fold(
                fun(K, V, Acc) ->
                    Key = coerce_binary(K),
                    Val = trim(V),
                    case {Key, Val} of
                        {<<>>, _} -> Acc;
                        {_, <<>>} -> Acc;
                        _ -> maps:put(Key, Val, Acc)
                    end
                end,
                #{},
                Map
            );
        _ ->
            #{}
    end;
decode_backend_namespace_map(_) ->
    #{}.

set_backend_namespace_meta(Meta, ServiceNs, ServiceNsByName) ->
    EncodedServiceNsByName = thoas:encode(ServiceNsByName),
    Anns0 = maps:get(<<"annotations">>, Meta, #{}),
    Anns1 = Anns0#{
        ?BACKEND_NAMESPACE_ANNOTATION => ServiceNs,
        ?BACKEND_NAMESPACE_ANNOTATION_LEGACY => ServiceNs,
        ?BACKEND_NAMESPACES_ANNOTATION => EncodedServiceNsByName,
        ?BACKEND_NAMESPACES_ANNOTATION_LEGACY => EncodedServiceNsByName
    },
    Meta#{<<"annotations">> => Anns1}.
