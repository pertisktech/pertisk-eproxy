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

available() ->
    pertisk_eproxy_config:ingress_mode().

%% Dashboard lists controller pods in the release namespace (not cluster-wide).
pods(Namespace) ->
    with_conn(fun(Conn) ->
        Ns = case trim_optional(Namespace) of
            <<>> -> pertisk_ingress_env:leader_namespace();
            N -> N
        end,
        case ekub:read(pod, Ns, [], Conn) of
            {ok, List} ->
                Rows = [pod_row(P) || P <- items_from_list(List)],
                {ok, Rows};
            {error, Reason} ->
                case is_k8s_forbidden(Reason) of
                    true ->
                        {ok, self_pod_fallback_rows(Ns)};
                    false ->
                        {error, Reason}
                end
        end
    end).

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
        case ekub:read(service, Ns, list_query(), Conn) of
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
            Ns -> ekub:read(secret, Ns, Query, Conn)
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
                {ok, Rows};
            {error, Reason} ->
                {error, Reason}
        end
    end).

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

pod_row(Pod) ->
    Spec = maps:get(<<"spec">>, Pod, #{}),
    Status = maps:get(<<"status">>, Pod, #{}),
    NodeName = maps:get(<<"nodeName">>, Spec, undefined),
    {Ready, Restarts} = pod_ready_restarts(maps:get(<<"containerStatuses">>, Status, [])),
    #{
        name => meta_name(Pod),
        namespace => meta_namespace(Pod),
        phase => maps:get(<<"phase">>, Status, <<"Unknown">>),
        node => maybe_null(NodeName),
        node_name => maybe_null(NodeName),
        pod_ip => maybe_null(maps:get(<<"podIP">>, Status, undefined)),
        ready => Ready,
        restarts => Restarts,
        cpu_usage_millicores => null,
        memory_usage_bytes => null,
        created_at => meta_created_at(Pod)
    }.

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
    Spec = maps:get(<<"spec">>, Ingress, undefined),
    case Spec of
        undefined ->
            {error, <<"Ingress has no spec">>};
        _ ->
            Rules = maps:get(<<"rules">>, Spec, []),
            case Rules of
                [Rule | _] ->
                    Host = maps:get(<<"host">>, Rule, <<"*">>),
                    Routes = paths_from_rule(Rule),
                    TlsSecret = tls_secret_from_spec(Spec),
                    First = hd(Routes),
                    {ok, #{
                        namespace => Ns,
                        name => Name,
                        host => Host,
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

paths_from_rule(Rule) ->
    case maps:get(<<"http">>, Rule, undefined) of
        #{<<"paths">> := Paths} when is_list(Paths), Paths =/= [] ->
            [path_row(P) || P <- Paths];
        _ ->
            [#{
                path => <<"/">>,
                path_type => <<"Prefix">>,
                service_name => <<>>,
                service_port => null,
                service_port_name => null
            }]
    end.

path_row(Path) ->
    {SvcName, PortNum, PortName} = backend_from_path(Path),
    #{
        path => maps:get(<<"path">>, Path, <<"/">>),
        path_type => maps:get(<<"pathType">>, Path, <<"Prefix">>),
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
        Meta = maps:merge(Meta0, #{<<"name">> => IngressName, <<"namespace">> => IngressNs}),
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

path_from_route(Route, Body) ->
    ServiceNs = trim(maps:get(<<"service_namespace">>, Body, <<>>)),
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
    http_path(Path, PathType, SvcName, ServiceNs, Port).

path_from_legacy_body(Body) ->
    ServiceNs = trim_required(maps:get(<<"service_namespace">>, Body, <<>>), <<"service_namespace is required">>),
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
    http_path(Path, PathType, SvcName, ServiceNs, Port).

http_path(Path, PathType, SvcName, _ServiceNs, Port) ->
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

%% When RBAC denies pod list, expose at least this replica (from downward API).
self_pod_fallback_rows(Ns) ->
    PodName = env_bin([<<"PERTISK_POD_NAME">>, <<"POD_NAME">>]),
    PodNs = env_bin([<<"POD_NAMESPACE">>]),
    case {PodName, PodNs} of
        {<<>>, _} -> [];
        {_, <<>>} -> [];
        {Name, Namespace} when Namespace =:= Ns ->
            [#{
                name => Name,
                namespace => Namespace,
                phase => <<"Running">>,
                node => null,
                node_name => null,
                pod_ip => null,
                ready => <<"1/1">>,
                restarts => 0,
                cpu_usage_millicores => null,
                memory_usage_bytes => null,
                created_at => null
            }];
        _ ->
            []
    end.

env_bin(Keys) ->
    case first_env(Keys) of
        {ok, V} -> V;
        error -> <<>>
    end.

first_env([Key | Rest]) ->
    case os:getenv(binary_to_list(Key)) of
        false -> first_env(Rest);
        "" -> first_env(Rest);
        V -> {ok, list_to_binary(string:trim(V))}
    end;
first_env([]) ->
    error.

%% JSON null / numbers must not crash trim/trim_required (thoas decodes null as null).
coerce_binary(null) -> <<>>;
coerce_binary(undefined) -> <<>>;
coerce_binary(B) when is_binary(B) -> B;
coerce_binary(L) when is_list(L) -> list_to_binary(L);
coerce_binary(N) when is_integer(N) -> integer_to_binary(N);
coerce_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
coerce_binary(_) -> <<>>.
