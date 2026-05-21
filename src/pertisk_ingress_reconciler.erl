%% @doc Transform Kubernetes Ingress + Secret objects into eproxy sites/backends/TLS.
-module(pertisk_ingress_reconciler).

-export([reconcile/2]).

-define(DEFAULT_BACKEND_PORT, 80).

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
                                Path, Host, Ns, IngressName, Bs2, Ss2, Ts2
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
    {Backends1, Sites1, TlsRefs2}.

reconcile_path(Path, Host, Ns, IngressName, Backends, Sites, TlsRefs) ->
    BackendSpec = maps:get(<<"backend">>, Path, #{}),
    BackendName = backend_name_for(BackendSpec, IngressName),
    Upstreams = upstreams_from_backend(BackendSpec, Ns),
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
        advertise_http3 => true,
        routes => [Route],
        ingress_namespace => Ns,
        ingress_name => IngressName
    },
    {Backends1, [Site | Sites], TlsRefs}.

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

backend_name_for(#{<<"service">> := #{<<"name">> := SvcName, <<"port">> := Port}}, IngressName) ->
    PortNum = backend_port_number(Port),
    iolist_to_binary([SvcName, <<".">>, IngressName, <<":">>, integer_to_binary(PortNum)]);
backend_name_for(#{<<"resource">> := #{<<"name">> := ResName}}, IngressName) ->
    iolist_to_binary([<<"resource.">>, ResName, <<".">>, IngressName]);
backend_name_for(_, IngressName) ->
    iolist_to_binary([<<"default.">>, IngressName]).

backend_port_number(#{<<"number">> := N}) when is_integer(N) -> N;
backend_port_number(_) -> ?DEFAULT_BACKEND_PORT.

upstreams_from_backend(#{<<"service">> := #{<<"name">> := SvcName, <<"port">> := Port}}, Ns) ->
    PortNum = backend_port_number(Port),
    Addr = iolist_to_binary([
        SvcName, <<".">>, Ns, <<".svc.cluster.local:">>, integer_to_binary(PortNum)
    ]),
    [#{addr => Addr, weight => 1}];
upstreams_from_backend(_, _) ->
    [].

ingress_matches_class(Ingress, {ok, WantClass}) ->
    Spec = maps:get(<<"spec">>, Ingress, #{}),
    case maps:get(<<"ingressClassName">>, Spec, undefined) of
        undefined -> true;
        Class when is_binary(Class) -> Class =:= WantClass;
        _ -> false
    end;
ingress_matches_class(_Ingress, all) ->
    true.

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
