%% @doc Reconcile Gateway API HTTPRoute objects into eproxy sites/backends.
-module(pertisk_gateway_reconciler).

-export([reconcile/1, reconcile/3, merge_results/2]).

-define(DEFAULT_BACKEND_PORT, 80).
-define(GATEWAY_CLASS_ANNOTATION, <<"pertisk.io/gateway-class">>).
-define(TLS_SECRET_ANNOTATION, <<"pertisk.io/tls-secret">>).
-define(TLS_SECRET_NS_ANNOTATION, <<"pertisk.io/tls-secret-namespace">>).

-spec reconcile([map()]) ->
    {ok, #{sites := [map()], backends := [map()], tls := [map()]}}.
reconcile(Routes) ->
    reconcile(Routes, [], []).

-spec reconcile([map()], [map()], [map()]) ->
    {ok, #{sites := [map()], backends := [map()], tls := [map()]}}.
reconcile(Routes, Gateways, Secrets) ->
    ClassFilter = pertisk_ingress_env:ingress_class(),
    ListenerTls = listener_tls_map(Gateways, ClassFilter),
    {Backends0, Sites0, TlsRefs0} = lists:foldl(
        fun(Route, {Bs, Ss, Ts}) ->
            case route_matches_class(Route, ClassFilter) of
                false -> {Bs, Ss, Ts};
                true -> reconcile_one_route(Route, ListenerTls, Bs, Ss, Ts)
            end
        end,
        {[], [], []},
        Routes
    ),
    TlsEntries = pertisk_ingress_reconciler:load_tls_from_refs(TlsRefs0, Secrets),
    {ok, #{
        sites => Sites0,
        backends => dedupe_backends(Backends0),
        tls => TlsEntries
    }}.

merge_results(A, B) ->
    #{
        sites => maps:get(sites, A, []) ++ maps:get(sites, B, []),
        backends => dedupe_backends(maps:get(backends, A, []) ++ maps:get(backends, B, [])),
        tls => maps:get(tls, A, []) ++ maps:get(tls, B, [])
    }.

route_matches_class(_Route, all) ->
    true;
route_matches_class(Route, {ok, WantClass}) ->
    Meta = maps:get(<<"metadata">>, Route, #{}),
    Annotations = maps:get(<<"annotations">>, Meta, #{}),
    case maps:get(?GATEWAY_CLASS_ANNOTATION, Annotations, WantClass) of
        Class when is_binary(Class) -> Class =:= WantClass;
        _ -> false
    end.

gateway_matches_class(_Gateway, all) ->
    true;
gateway_matches_class(Gateway, {ok, WantClass}) ->
    Spec = maps:get(<<"spec">>, Gateway, #{}),
    maps:get(<<"gatewayClassName">>, Spec, undefined) =:= WantClass.

listener_tls_map(Gateways, ClassFilter) ->
    lists:foldl(
        fun(Gateway, Acc) ->
            case gateway_matches_class(Gateway, ClassFilter) of
                false -> Acc;
                true -> maps:merge(Acc, listener_tls_from_gateway(Gateway))
            end
        end,
        #{},
        Gateways
    ).

listener_tls_from_gateway(Gateway) ->
    Meta = maps:get(<<"metadata">>, Gateway, #{}),
    GwNs = namespace_of(Meta),
    Spec = maps:get(<<"spec">>, Gateway, #{}),
    Listeners = maps:get(<<"listeners">>, Spec, []),
    lists:foldl(
        fun(Listener, Acc) ->
            HostPattern = maps:get(<<"hostname">>, Listener, <<"*">>),
            case listener_secret_ref(Listener, GwNs) of
                undefined -> Acc;
                {SecretNs, SecretName} ->
                    maps:put(HostPattern, {SecretNs, SecretName}, Acc)
            end
        end,
        #{},
        Listeners
    ).

listener_secret_ref(Listener, GwNs) ->
    Tls = maps:get(<<"tls">>, Listener, #{}),
    Refs = maps:get(<<"certificateRefs">>, Tls, []),
    case Refs of
        [#{<<"name">> := Name} = Ref | _] ->
            RefNs = cert_ref_namespace(Ref, GwNs),
            {RefNs, Name};
        _ ->
            undefined
    end.

cert_ref_namespace(#{<<"namespace">> := Ns}, _) when is_binary(Ns), Ns =/= <<>> ->
    Ns;
cert_ref_namespace(_, GwNs) ->
    GwNs.

reconcile_one_route(Route, ListenerTls, Backends, Sites, TlsRefs) ->
    Meta = maps:get(<<"metadata">>, Route, #{}),
    Ns = namespace_of(Meta),
    RouteName = name_of(Meta),
    Spec = maps:get(<<"spec">>, Route, #{}),
    Hostnames = maps:get(<<"hostnames">>, Spec, []),
    Rules = maps:get(<<"rules">>, Spec, []),
    Hosts = case Hostnames of
        [] -> [<<"*">>];
        Hs -> Hs
    end,
    lists:foldl(
        fun(Host, {Bs, Ss, Ts}) ->
            lists:foldl(
                fun(Rule, {Bs2, Ss2, Ts2}) ->
                    reconcile_rule(Rule, Host, Route, ListenerTls, Ns, RouteName, Bs2, Ss2, Ts2)
                end,
                {Bs, Ss, Ts},
                Rules
            )
        end,
        {Backends, Sites, TlsRefs},
        Hosts
    ).

reconcile_rule(Rule, Host, Route, ListenerTls, Ns, RouteName, Backends, Sites, TlsRefs) ->
    Matches = maps:get(<<"matches">>, Rule, [#{}]),
    BackendRefs = maps:get(<<"backendRefs">>, Rule, []),
    case BackendRefs of
        [#{<<"name">> := SvcName, <<"port">> := Port} | _] ->
            reconcile_matches(Matches, Host, Route, ListenerTls, Ns, RouteName, SvcName, Port, Backends, Sites, TlsRefs);
        [#{<<"name">> := SvcName} | _] ->
            reconcile_matches(Matches, Host, Route, ListenerTls, Ns, RouteName, SvcName, ?DEFAULT_BACKEND_PORT, Backends, Sites, TlsRefs);
        _ ->
            {Backends, Sites, TlsRefs}
    end.

reconcile_matches(Matches, Host, Route, ListenerTls, Ns, RouteName, SvcName, PortNum, Backends, Sites, TlsRefs) ->
    BackendName = iolist_to_binary([
        SvcName, <<".">>, Ns, <<".gateway.">>, RouteName, <<":">>, integer_to_binary(PortNum)
    ]),
    Addr = cluster_service_addr(SvcName, Ns, PortNum),
    Backends1 = case lists:any(fun(#{name := N}) -> N =:= BackendName end, Backends) of
        true -> Backends;
        false ->
            [
                #{
                    name => BackendName,
                    algorithm => round_robin,
                    upstreams => [#{addr => Addr, weight => 1}],
                    health_path => undefined,
                    health_interval_secs => 10
                }
                | Backends
            ]
    end,
    {CertRef, TlsRefs1} = tls_for_host(Host, Route, ListenerTls, Ns, TlsRefs),
    lists:foldl(
        fun(Match, {Bs, Ss, Ts}) ->
            {PathBin, PathType} = path_from_match(Match),
            RouteSpec = #{
                path => PathBin,
                path_type => PathType,
                rewrite => undefined,
                sse_early_flush => undefined
            },
            Site = #{
                host => Host,
                backend => BackendName,
                certificate => CertRef,
                dns_provider => undefined,
                challenge_type => undefined,
                wildcard => undefined,
                acme_wildcard_base => undefined,
                acme_contact_email => undefined,
                advertise_http3 => true,
                sse_early_flush => undefined,
                auth_url => undefined,
                rate_limit_rps => undefined,
                rate_limit_burst => undefined,
                routes => [RouteSpec],
                ingress_namespace => Ns,
                ingress_name => RouteName
            },
            {Bs, [Site | Ss], Ts}
        end,
        {Backends1, Sites, TlsRefs1},
        Matches
    ).

tls_for_host(Host, Route, ListenerTls, RouteNs, TlsRefs) ->
    case resolve_tls_secret(Host, Route, ListenerTls, RouteNs) of
        undefined ->
            {undefined, TlsRefs};
        {SecretNs, SecretName} ->
            CertRef = pertisk_ingress_tls:cert_ref(SecretNs, SecretName),
            Ref = {SecretNs, SecretName, [Host]},
            {CertRef, add_tls_ref(Ref, TlsRefs)}
    end.

resolve_tls_secret(Host, Route, ListenerTls, RouteNs) ->
    Meta = maps:get(<<"metadata">>, Route, #{}),
    Annotations = maps:get(<<"annotations">>, Meta, #{}),
    case maps:get(?TLS_SECRET_ANNOTATION, Annotations, undefined) of
        Secret when is_binary(Secret), Secret =/= <<>> ->
            SecretNs = maps:get(?TLS_SECRET_NS_ANNOTATION, Annotations, RouteNs),
            {SecretNs, Secret};
        _ ->
            listener_tls_for_host(Host, ListenerTls)
    end.

listener_tls_for_host(Host, ListenerTls) ->
    Matching = [
        {Pattern, Ref}
     || {Pattern, Ref} <- maps:to_list(ListenerTls),
        hostname_matches(Host, Pattern)
    ],
    case Matching of
        [] -> undefined;
        [{_, Ref}] -> Ref;
        _ ->
            [{_Pattern, Ref} | _] = lists:sort(Matching),
            Ref
    end.

add_tls_ref({Ns, Secret, Hosts}, TlsRefs) ->
    {Others, Found} = lists:partition(
        fun({ExistingNs, ExistingSecret, _}) ->
            not (ExistingNs =:= Ns andalso ExistingSecret =:= Secret)
        end,
        TlsRefs
    ),
    case Found of
        [{_, _, ExistingHosts}] ->
            [{Ns, Secret, lists:usort(ExistingHosts ++ Hosts)} | Others];
        [] ->
            [{Ns, Secret, Hosts} | Others]
    end.

hostname_matches(_Host, <<>>) ->
    false;
hostname_matches(_Host, <<"*">>) ->
    true;
hostname_matches(Host, <<$*, Rest/binary>>) ->
    case Rest of
        <<".", Suffix/binary>> when byte_size(Suffix) > 0 ->
            suffix_match(Host, Suffix);
        _ ->
            false
    end;
hostname_matches(Host, Pattern) ->
    Host =:= Pattern.

suffix_match(Host, Suffix) ->
    HostSize = byte_size(Host),
    SuffixSize = byte_size(Suffix),
    HostSize >= SuffixSize
        andalso binary:part(Host, HostSize - SuffixSize, SuffixSize) =:= Suffix.

path_from_match(#{<<"path">> := #{<<"value">> := Path} = PathMap}) when is_binary(Path) ->
    {Path, path_type_from_match(maps:get(<<"type">>, PathMap, <<"PathPrefix">>))};
path_from_match(_) ->
    {<<"/">>, prefix}.

path_type_from_match(<<"Exact">>) -> exact;
path_type_from_match(<<"PathPrefix">>) -> prefix;
path_type_from_match(_) -> prefix.

cluster_service_addr(SvcName, Ns, PortNum) ->
    iolist_to_binary([
        SvcName, <<".">>, Ns, <<".svc.cluster.local:">>, integer_to_binary(PortNum)
    ]).

dedupe_backends(Backends) ->
    {_, Unique} = lists:foldl(
        fun(B = #{name := Name}, {Seen, Acc}) ->
            case sets:is_element(Name, Seen) of
                true -> {Seen, Acc};
                false -> {sets:add_element(Name, Seen), [B | Acc]}
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
