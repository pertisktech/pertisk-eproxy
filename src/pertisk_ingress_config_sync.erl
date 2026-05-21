%% @doc Apply reconciled Kubernetes config to the running proxy (hot-reload).
-module(pertisk_ingress_config_sync).

-export([apply/1, apply_reconcile_result/1]).

%% @doc Apply full reconcile result map.
-spec apply_reconcile_result(#{sites := [map()], backends := [map()], tls := [map()]}) ->
    ok | {error, term()}.
apply_reconcile_result(#{sites := Sites, backends := Backends, tls := Tls}) ->
    apply(#{sites => Sites, backends => Backends, tls => Tls}).

-spec apply(map()) -> ok | {error, term()}.
apply(#{sites := Sites, backends := Backends, tls := Tls}) ->
    case sync_tls(Tls) of
        ok ->
            case pertisk_eproxy_config:sync_ingress(Sites, Backends) of
                ok ->
                    maybe_reload_proxy_tls(Sites, Backends, Tls),
                    pertisk_ingress_status:record_success(Sites, Backends, Tls),
                    ok;
                {error, _} = Err ->
                    pertisk_ingress_status:record_error(Err),
                    Err
            end;
        {error, _} = Err ->
            pertisk_ingress_status:record_error(Err),
            Err
    end.

sync_tls(TlsEntries) when is_list(TlsEntries) ->
    OldHosts = pertisk_ingress_tls:all_hosts(),
    pertisk_ingress_tls:clear(),
    lists:foreach(
        fun(#{hosts := Hosts, cert_pem := CertPem, key_pem := KeyPem,
              namespace := Ns, secret := Secret}) ->
            case pertisk_ingress_tls:write_pem_files(Ns, Secret, CertPem, KeyPem) of
                {ok, {CertPath, KeyPath}} ->
                    ok = pertisk_ingress_tls:set_hosts(
                        Hosts, CertPem, KeyPem, CertPath, KeyPath
                    );
                {error, Reason} ->
                    lager:warning("Failed to write K8s TLS files for ~s/~s: ~p", [Ns, Secret, Reason])
            end
        end,
        TlsEntries
    ),
    NewHosts = lists:flatmap(fun(#{hosts := H}) -> H end, TlsEntries),
    Removed = lists:filter(fun(H) -> not lists:member(H, NewHosts) end, OldHosts),
    ok = pertisk_ingress_tls:remove_hosts(Removed),
    ok;
sync_tls(_) ->
    ok.

maybe_reload_proxy_tls(Sites, Backends, Tls) ->
    Sig = erlang:phash2({Sites, Backends, Tls}),
    case persistent_term:get(pertisk_ingress_config_sync, last_sig, undefined) of
        Sig ->
            ok;
        _ ->
            persistent_term:put(pertisk_ingress_config_sync, last_sig, Sig),
            case Tls =/= [] orelse Sites =/= [] of
                true ->
                    lager:info(
                        "Ingress TLS/routing updated (~p site(s), ~p TLS secret(s)); reloading HTTPS/HTTP/3",
                        [length(Sites), length(Tls)]
                    ),
                    _ = catch pertisk_eproxy_app:reload_proxy_tls_listeners();
                false ->
                    lager:info("Ingress reconcile empty; HTTPS/HTTP/3 not started (no localhost fallback)"),
                    _ = catch pertisk_eproxy_app:reload_proxy_tls_listeners(),
                    ok
            end
    end.
