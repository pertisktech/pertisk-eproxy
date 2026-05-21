%% @doc Kubernetes admin API for ingress mode (Sites add/edit Ingress via ekub).
-module(pertisk_eproxy_admin_kubernetes).

-export([
    available/0,
    namespaces/0,
    services/1,
    tls_secrets/1,
    get_ingress/2,
    create_ingress/1,
    update_ingress/3,
    delete_ingress/2
]).

-define(API_VERSION, <<"networking.k8s.io/v1">>).

available() ->
    pertisk_eproxy_config:ingress_mode().

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
                        pertisk_ingress_watcher:reconcile_now(),
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
                                pertisk_ingress_watcher:reconcile_now(),
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
    pertisk_ingress_watcher:reconcile_now(),
    {ok, #{
        message => <<"Ingress deleted">>,
        name => Name,
        namespace => Namespace
    }}.

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
        throw:{bad_request, Msg} -> {error, Msg}
    end.

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
    case maps:get(<<"service_port">>, Route, undefined) of
        N when is_integer(N) -> #{<<"number">> => N};
        _ ->
            case maps:get(<<"service_port_name">>, Route, undefined) of
                Name when is_binary(Name), Name =/= <<>> -> #{<<"name">> => trim(Name)};
                _ -> throw({bad_request, <<"each route requires service_port or service_port_name">>})
            end
    end.

backend_port_from_body(Body) ->
    case maps:get(<<"service_port">>, Body, undefined) of
        N when is_integer(N) -> #{<<"number">> => N};
        _ ->
            case maps:get(<<"service_port_name">>, Body, undefined) of
                Name when is_binary(Name), Name =/= <<>> -> #{<<"name">> => trim(Name)};
                _ -> throw({bad_request, <<"service_port or service_port_name is required">>})
            end
    end.

maybe_tls_spec(Spec, Host, IngressNs, Body, Current) ->
    TlsNs = maps:get(<<"tls_secret_namespace">>, Body, undefined),
    TlsName = maps:get(<<"tls_secret_name">>, Body, undefined),
    case {tls_bin(TlsNs), tls_bin(TlsName)} of
        {Ns, Name} when Ns =/= <<>>, Name =/= <<>> ->
            if
                Ns =/= IngressNs ->
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
maybe_null(V) -> V.

trim(B) when is_binary(B) ->
    list_to_binary(string:trim(binary_to_list(B), both));
trim(V) when is_list(V) ->
    trim(iolist_to_binary(V)).

trim_required(B, Msg) ->
    T = trim(B),
    case T of
        <<>> -> throw({bad_request, Msg});
        _ -> T
    end.
