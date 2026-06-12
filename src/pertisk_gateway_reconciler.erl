%% @doc Reconcile Gateway API HTTPRoute objects into eproxy sites/backends.
-module(pertisk_gateway_reconciler).

-export([reconcile/1, merge_results/2]).

-define(DEFAULT_BACKEND_PORT, 80).
-define(GATEWAY_CLASS_ANNOTATION, <<"pertisk.io/gateway-class">>).

-spec reconcile([map()]) ->
    {ok, #{sites := [map()], backends := [map()], tls := [map()]}}.
reconcile(Routes) ->
    ClassFilter = pertisk_ingress_env:ingress_class(),
    {Backends0, Sites0} = lists:foldl(
        fun(Route, {Bs, Ss}) ->
            case route_matches_class(Route, ClassFilter) of
                false -> {Bs, Ss};
                true -> reconcile_one_route(Route, Bs, Ss)
            end
        end,
        {[], []},
        Routes
    ),
    {ok, #{
        sites => Sites0,
        backends => dedupe_backends(Backends0),
        tls => []
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

reconcile_one_route(Route, Backends, Sites) ->
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
        fun(Host, {Bs, Ss}) ->
            lists:foldl(
                fun(Rule, {Bs2, Ss2}) ->
                    reconcile_rule(Rule, Host, Ns, RouteName, Bs2, Ss2)
                end,
                {Bs, Ss},
                Rules
            )
        end,
        {Backends, Sites},
        Hosts
    ).

reconcile_rule(Rule, Host, Ns, RouteName, Backends, Sites) ->
    Matches = maps:get(<<"matches">>, Rule, [#{}]),
    BackendRefs = maps:get(<<"backendRefs">>, Rule, []),
    case BackendRefs of
        [#{<<"name">> := SvcName, <<"port">> := Port} | _] ->
            reconcile_matches(Matches, Host, Ns, RouteName, SvcName, Port, Backends, Sites);
        [#{<<"name">> := SvcName} | _] ->
            reconcile_matches(Matches, Host, Ns, RouteName, SvcName, ?DEFAULT_BACKEND_PORT, Backends, Sites);
        _ ->
            {Backends, Sites}
    end.

reconcile_matches(Matches, Host, Ns, RouteName, SvcName, PortNum, Backends, Sites) ->
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
    lists:foldl(
        fun(Match, {Bs, Ss}) ->
            {PathBin, PathType} = path_from_match(Match),
            Route = #{
                path => PathBin,
                path_type => PathType,
                rewrite => undefined,
                sse_early_flush => undefined
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
                advertise_http3 => true,
                sse_early_flush => undefined,
                auth_url => undefined,
                rate_limit_rps => undefined,
                rate_limit_burst => undefined,
                routes => [Route],
                ingress_namespace => Ns,
                ingress_name => RouteName
            },
            {Bs, [Site | Ss]}
        end,
        {Backends1, Sites},
        Matches
    ).

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
