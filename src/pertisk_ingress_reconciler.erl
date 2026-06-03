%% @doc Transform Kubernetes Ingress + Secret objects into eproxy sites/backends/TLS.
-module(pertisk_ingress_reconciler).

-export([reconcile/2, ingress_matches_class/2]).

-define(DEFAULT_BACKEND_PORT, 80).
-define(INGRESS_CLASS_ANNOTATION, <<"kubernetes.io/ingress.class">>).
-define(BACKEND_NAMESPACE_ANNOTATION, <<"pertisk.io/backend-namespace">>).
-define(BACKEND_NAMESPACE_ANNOTATION_LEGACY, <<"pertisk.tech/backend-namespace">>).
-define(BACKEND_NAMESPACES_ANNOTATION, <<"pertisk.io/backend-namespaces">>).
-define(BACKEND_NAMESPACES_ANNOTATION_LEGACY, <<"pertisk.tech/backend-namespaces">>).
-define(ADVERTISE_HTTP3_ANNOTATION, <<"pertisk.io/advertise-http3">>).
-define(ADVERTISE_HTTP3_ANNOTATION_LEGACY, <<"pertisk.tech/advertise-http3">>).

%% @doc Full reconcile from listed Ingress and Secret maps (ekub JSON objects).
-spec reconcile([map()], [map()]) ->
    {ok, #{sites := [map()], backends := [map()], tls := [map()]}} | {error, term()}.
reconcile(Ingresses, Secrets) ->
    try
        ClassFilter = pertisk_ingress_env:ingress_class(),
        {Backends0, Sites0, TlsRefs} = lists:foldl(
            fun(Ingress, {Bs, Ss, Ts}) ->
                case ingress_matches_class(Ingress, ClassFilter) of
                    false -> {Bs, Ss, Ts};
                    true ->
                        reconcile_one_ingress(Ingress, Bs, Ss, Ts)
                end
            end,
            {[], [], []},
            Ingresses
        ),
        Backends = dedupe_backends(Backends0),
        Sites = Sites0,
        TlsEntries = load_tls_entries(TlsRefs, secrets_index(Secrets)),
        {ok, #{sites => Sites, backends => Backends, tls => TlsEntries}}
    catch
        C:R:St ->
            {error, {reconcile_failed, C, R, St}}
    end.

%% ---------------------------------------------------------------------------
%% Ingress → sites/backends
%% ---------------------------------------------------------------------------

reconcile_one_ingress(Ingress, Backends, Sites, TlsRefs) ->
    Spec = maps:get(<<"spec">>, Ingress, #{}),
    Meta = maps:get(<<"metadata">>, Ingress, #{}),
    Ns = namespace_of(Meta),
    BackendNsDefault = backend_namespace_of(Meta, Ns),
    BackendNsByService = backend_namespace_map_of(Meta),
    AdvertiseHttp3 = advertise_http3_of(Meta),
    IngressName = name_of(Meta),
    Rules = maps:get(<<"rules">>, Spec, []),
    RuleHosts = [H || #{<<"host">> := H} <- Rules, is_binary(H)],
    {Backends1, Sites1, TlsRefs1} = lists:foldl(
        fun(Rule, {Bs, Ss, Ts}) ->
            Host = maps:get(<<"host">>, Rule, <<"*">>),
            case maps:get(<<"http">>, Rule, undefined) of
                undefined ->
                    {Bs, Ss, Ts};
                #{<<"paths">> := Paths} ->
                    lists:foldl(
                        fun(Path, {Bs2, Ss2, Ts2}) ->
                            reconcile_path(
                                Path,
                                Host,
                                Ns,
                                BackendNsDefault,
                                BackendNsByService,
                                AdvertiseHttp3,
                                IngressName,
                                Bs2,
                                Ss2,
                                Ts2
                            )
                        end,
                        {Bs, Ss, Ts},
                        Paths
                    )
            end
        end,
        {Backends, Sites, TlsRefs},
        Rules
    ),
    TlsRefs2 = collect_tls_refs(Spec, Ns, RuleHosts, TlsRefs1),
    CertRef = ingress_site_certificate(Ns, Spec),
    {Backends1, sites_with_certificate(Sites1, CertRef), TlsRefs2}.

reconcile_path(
    Path,
    Host,
    Ns,
    BackendNsDefault,
    BackendNsByService,
    AdvertiseHttp3,
    IngressName,
    Backends,
    Sites,
    TlsRefs
) ->
    BackendSpec = maps:get(<<"backend">>, Path, #{}),
    BackendNs = backend_namespace_for(BackendSpec, BackendNsDefault, BackendNsByService),
    BackendName = backend_name_for(BackendSpec, IngressName, BackendNs),
    Upstreams = upstreams_from_backend(BackendSpec, BackendNs),
    Backends1 = case lists:any(fun(#{name := N}) -> N =:= BackendName end, Backends) of
        true -> Backends;
        false ->
            [
                #{
                    name => BackendName,
                    algorithm => round_robin,
                    upstreams => Upstreams,
                    health_path => undefined,
                    health_interval_secs => 10
                }
                | Backends
            ]
    end,
    Route = #{
        path => maps:get(<<"path">>, Path, <<"/">>),
        path_type => parse_path_type(maps:get(<<"pathType">>, Path, <<"Prefix">>)),
        rewrite => undefined
    },
    Site = #{
        host => Host,
        backend => BackendName,
        certificate => undefined,
        dns_provider => undefined,
        challenge_type => undefined,
        wildcard => undefined,
        acme_wildcard_base => undefined,
        acme_contact_email => undefined,
        advertise_http3 => AdvertiseHttp3,
        routes => [Route],
        ingress_namespace => Ns,
        ingress_name => IngressName
    },
    {Backends1, [Site | Sites], TlsRefs}.

ingress_site_certificate(Ns, Spec) ->
    case ingress_tls_secret_name(Spec) of
        undefined -> undefined;
        Secret -> pertisk_ingress_tls:cert_ref(Ns, Secret)
    end.

ingress_tls_secret_name(Spec) ->
    case maps:get(<<"tls">>, Spec, []) of
        [#{<<"secretName">> := S} | _] when is_binary(S), S =/= <<>> -> S;
        _ -> undefined
    end.

sites_with_certificate(Sites, undefined) ->
    Sites;
sites_with_certificate(Sites, CertRef) ->
    [S#{certificate => CertRef} || S <- Sites].

collect_tls_refs(Spec, Ns, RuleHosts, TlsRefs) ->
    TlsList = maps:get(<<"tls">>, Spec, []),
    lists:foldl(
        fun(Tls, Acc) ->
            case maps:get(<<"secretName">>, Tls, undefined) of
                Secret when is_binary(Secret), Secret =/= <<>> ->
                    Hosts = case maps:get(<<"hosts">>, Tls, undefined) of
                        [] -> RuleHosts;
                        undefined -> RuleHosts;
                        Hs -> Hs
                    end,
                    case Hosts of
                        [] -> Acc;
                        _ -> [{Ns, Secret, Hosts} | Acc]
                    end;
                _ ->
                    Acc
            end
        end,
        TlsRefs,
        TlsList
    ).

backend_name_for(#{<<"service">> := #{<<"name">> := SvcName, <<"port">> := Port}}, IngressName, BackendNs) ->
    PortNum = backend_port_number(Port),
    iolist_to_binary([
        SvcName, <<".">>, BackendNs, <<".">>, IngressName, <<":">>, integer_to_binary(PortNum)
    ]);
backend_name_for(#{<<"resource">> := #{<<"name">> := ResName}}, IngressName, BackendNs) ->
    iolist_to_binary([<<"resource.">>, ResName, <<".">>, BackendNs, <<".">>, IngressName]);
backend_name_for(_, IngressName, BackendNs) ->
    iolist_to_binary([<<"default.">>, BackendNs, <<".">>, IngressName]).

backend_port_number(#{<<"number">> := N}) when is_integer(N) -> N;
backend_port_number(_) -> ?DEFAULT_BACKEND_PORT.

upstreams_from_backend(#{<<"service">> := #{<<"name">> := SvcName, <<"port">> := Port}}, Ns) ->
    PortNum = backend_port_number(Port),
    Addr = upstream_service_addr(SvcName, Ns, PortNum),
    [#{addr => Addr, weight => 1}];
upstreams_from_backend(_, _) ->
    [].

backend_namespace_of(Meta, DefaultNs) ->
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

backend_namespace_for(
    #{<<"service">> := #{<<"name">> := SvcName}},
    BackendNsDefault,
    BackendNsByService
) when is_binary(SvcName) ->
    maps:get(SvcName, BackendNsByService, BackendNsDefault);
backend_namespace_for(_, BackendNsDefault, _BackendNsByService) ->
    BackendNsDefault.

backend_namespace_map_of(Meta) ->
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
                    case {coerce_bin(K), coerce_nonempty_bin(V)} of
                        {<<>>, _} -> Acc;
                        {_, <<>>} -> Acc;
                        {Key, Ns} -> maps:put(Key, Ns, Acc)
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

advertise_http3_of(Meta) ->
    Annotations = maps:get(<<"annotations">>, Meta, #{}),
    parse_annotation_bool(
        maps:get(?ADVERTISE_HTTP3_ANNOTATION, Annotations,
            maps:get(?ADVERTISE_HTTP3_ANNOTATION_LEGACY, Annotations, undefined)
        ),
        true
    ).

parse_annotation_bool(true, _Default) -> true;
parse_annotation_bool(false, _Default) -> false;
parse_annotation_bool(<<"true">>, _Default) -> true;
parse_annotation_bool(<<"TRUE">>, _Default) -> true;
parse_annotation_bool(<<"True">>, _Default) -> true;
parse_annotation_bool(<<"1">>, _Default) -> true;
parse_annotation_bool(<<"yes">>, _Default) -> true;
parse_annotation_bool(<<"YES">>, _Default) -> true;
parse_annotation_bool(<<"false">>, _Default) -> false;
parse_annotation_bool(<<"FALSE">>, _Default) -> false;
parse_annotation_bool(<<"False">>, _Default) -> false;
parse_annotation_bool(<<"0">>, _Default) -> false;
parse_annotation_bool(<<"no">>, _Default) -> false;
parse_annotation_bool(<<"NO">>, _Default) -> false;
parse_annotation_bool(Value, Default) when is_binary(Value) ->
    parse_annotation_bool(list_to_binary(string:trim(binary_to_list(Value))), Default);
parse_annotation_bool(_, Default) ->
    Default.

coerce_bin(B) when is_binary(B) -> B;
coerce_bin(L) when is_list(L) -> list_to_binary(L);
coerce_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
coerce_bin(N) when is_integer(N) -> integer_to_binary(N);
coerce_bin(_) -> <<>>.

coerce_nonempty_bin(V) ->
    case coerce_bin(V) of
        <<>> -> <<>>;
        Bin -> list_to_binary(string:trim(binary_to_list(Bin)))
    end.

%% Ingress admin UI often targets Service :9080 (management). Use loopback, not *.svc.cluster.local.
upstream_service_addr(_SvcName, _Ns, PortNum) ->
    MgmtPort = maps:get(management_port, pertisk_eproxy_config:get_config(), 9080),
    case {pertisk_ingress_env:ingress_mode(), PortNum =:= MgmtPort} of
        {true, true} ->
            pertisk_eproxy_config:management_loopback_upstream_bin();
        _ ->
            cluster_service_addr(_SvcName, _Ns, PortNum)
    end.

cluster_service_addr(SvcName, Ns, PortNum) ->
    iolist_to_binary([
        SvcName, <<".">>, Ns, <<".svc.cluster.local:">>, integer_to_binary(PortNum)
    ]).

ingress_matches_class(Ingress, {ok, WantClass}) ->
    ingress_class_of(Ingress) =:= WantClass;
ingress_matches_class(_Ingress, all) ->
    true.

%% spec.ingressClassName or legacy kubernetes.io/ingress.class annotation
ingress_class_of(Ingress) ->
    Spec = maps:get(<<"spec">>, Ingress, #{}),
    Meta = maps:get(<<"metadata">>, Ingress, #{}),
    case maps:get(<<"ingressClassName">>, Spec, undefined) of
        Class when is_binary(Class), Class =/= <<>> ->
            Class;
        _ ->
            Annotations = maps:get(<<"annotations">>, Meta, #{}),
            case maps:get(?INGRESS_CLASS_ANNOTATION, Annotations, undefined) of
                Ann when is_binary(Ann), Ann =/= <<>> -> Ann;
                _ -> undefined
            end
    end.

parse_path_type(<<"Exact">>) -> exact;
parse_path_type(<<"Prefix">>) -> prefix;
parse_path_type(<<"ImplementationSpecific">>) -> prefix;
parse_path_type(_) -> prefix.

%% ---------------------------------------------------------------------------
%% TLS from secrets
%% ---------------------------------------------------------------------------

load_tls_entries(TlsRefs, SecretIndex) ->
    Grouped = group_tls_refs(TlsRefs),
    maps:fold(
        fun({Ns, Secret}, Hosts, Acc) ->
            case maps:get({Ns, Secret}, SecretIndex, undefined) of
                undefined ->
                    lager:warning("Ingress TLS: secret ~s/~s not found", [Ns, Secret]),
                    Acc;
                SecretObj ->
                    case tls_pem_from_secret(SecretObj) of
                        {ok, CertPem, KeyPem} ->
                            CertRef = pertisk_ingress_tls:cert_ref(Ns, Secret),
                            [
                                #{
                                    hosts => Hosts,
                                    namespace => Ns,
                                    secret => Secret,
                                    cert_ref => CertRef,
                                    cert_pem => CertPem,
                                    key_pem => KeyPem
                                }
                                | Acc
                            ];
                        {error, Reason} ->
                            lager:warning(
                                "Ingress TLS: skip ~s/~s: ~p",
                                [Ns, Secret, Reason]
                            ),
                            Acc
                    end
            end
        end,
        [],
        Grouped
    ).

group_tls_refs(TlsRefs) ->
    lists:foldl(
        fun({Ns, Secret, Hosts}, Acc) ->
            Key = {Ns, Secret},
            Existing = maps:get(Key, Acc, []),
            Merged = lists:usort(Existing ++ Hosts),
            maps:put(Key, Merged, Acc)
        end,
        #{},
        TlsRefs
    ).

tls_pem_from_secret(#{<<"type">> := Type, <<"data">> := Data}) when is_map(Data) ->
    TypeOk = (Type =:= <<"kubernetes.io/tls">>) orelse maps:is_key(<<"tls.crt">>, Data),
    case TypeOk of
        false ->
            {error, wrong_secret_type};
        true ->
            case {maps:get(<<"tls.crt">>, Data, undefined), maps:get(<<"tls.key">>, Data, undefined)} of
                {CertB64, KeyB64} when is_binary(CertB64), is_binary(KeyB64) ->
                    CertPem = base64:decode(CertB64),
                    KeyPem = base64:decode(KeyB64),
                    case {CertPem, KeyPem} of
                        {<<>>, _} -> {error, empty_cert};
                        {_, <<>>} -> {error, empty_key};
                        _ -> {ok, CertPem, KeyPem}
                    end;
                _ ->
                    {error, missing_tls_keys}
            end
    end;
tls_pem_from_secret(_) ->
    {error, invalid_secret}.

secrets_index(Secrets) ->
    maps:from_list([
        {secret_key(S), S}
     || S <- Secrets
    ]).

secret_key(#{<<"metadata">> := Meta}) ->
    {namespace_of(Meta), name_of(Meta)}.

%% ---------------------------------------------------------------------------

dedupe_backends(Backends) ->
    {_, Unique} = lists:foldl(
        fun(B = #{name := Name}, {Seen, Acc}) ->
            case sets:is_element(Name, Seen) of
                true -> {Seen, Acc};
                false ->
                    {sets:add_element(Name, Seen), [B | Acc]}
            end
        end,
        {sets:new(), []},
        Backends
    ),
    lists:reverse(Unique).

namespace_of(#{<<"namespace">> := Ns}) when is_binary(Ns) -> Ns;
namespace_of(_) -> <<"default">>.

name_of(#{<<"name">> := Name}) when is_binary(Name) -> Name;
name_of(_) -> <<"unknown">>.
