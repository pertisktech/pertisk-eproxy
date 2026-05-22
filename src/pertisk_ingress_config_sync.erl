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
    try
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
        end
    catch
        C:R:St ->
            ApplyErr = {ingress_apply_failed, C, R, St},
            lager:error("Ingress config apply failed: ~p", [ApplyErr]),
            pertisk_ingress_status:record_error(ApplyErr),
            {error, ApplyErr}
    end.

sync_tls([]) ->
    %% Do not clear the TLS store on an empty reconcile (transient list/watch races).
    case pertisk_ingress_tls:all_hosts() of
        [] ->
            Sites = pertisk_eproxy_config:get_sites(),
            pertisk_ingress_tls:restore_from_disk_sites(Sites),
            case pertisk_ingress_tls:all_hosts() of
                [] ->
                    lager:warning(
                        "Ingress TLS sync: no TLS entries and no PEMs on disk (waiting for secrets)"
                    );
                _ ->
                    lager:info("Ingress TLS sync: restored ~p host(s) from disk cache",
                               [length(pertisk_ingress_tls:all_hosts())])
            end;
        _ ->
            lager:debug("Ingress TLS sync: empty TLS list from reconcile, keeping cached material")
    end,
    ok;
sync_tls(TlsEntries) when is_list(TlsEntries) ->
    OldHosts = pertisk_ingress_tls:all_hosts(),
    pertisk_ingress_tls:clear(),
    lists:foreach(
        fun(#{hosts := Hosts, cert_pem := CertPem, key_pem := KeyPem,
              namespace := Ns, secret := Secret}) ->
            case pertisk_ingress_tls:write_pem_files(Ns, Secret, CertPem, KeyPem) of
                {ok, {CertPath, KeyPath}} ->
                    case safe_set_tls_hosts(Hosts, CertPem, KeyPem, CertPath, KeyPath) of
                        ok -> ok;
                        {error, Reason} ->
                            lager:warning(
                                "Ingress TLS set_hosts failed for ~s/~s: ~p",
                                [Ns, Secret, Reason]
                            )
                    end;
                {error, Reason} ->
                    lager:warning("Failed to write K8s TLS files for ~s/~s: ~p", [Ns, Secret, Reason])
            end
        end,
        TlsEntries
    ),
    NewHosts = lists:flatmap(fun(#{hosts := H}) -> H end, TlsEntries),
    Removed = lists:filter(fun(H) -> not lists:member(H, NewHosts) end, OldHosts),
    ok = pertisk_ingress_tls:remove_hosts(Removed),
    ok.

maybe_reload_proxy_tls(Sites, Backends, Tls) ->
    Sig = stable_reload_sig(Sites, Backends, Tls),
    Last = application:get_env(pertisk_eproxy, ingress_tls_reload_sig, undefined),
    case Last of
        Sig ->
            ok;
        _ ->
            application:set_env(pertisk_eproxy, ingress_tls_reload_sig, Sig),
            case Tls =/= [] orelse Sites =/= [] of
                true ->
                    lager:info(
                        "Ingress TLS/routing updated (~p site(s), ~p TLS secret(s)); reloading HTTPS/HTTP/3",
                        [length(Sites), length(Tls)]
                    ),
                    safe_reload_proxy_tls();
                false ->
                    lager:info(
                        "Ingress reconcile empty; HTTPS/HTTP/3 not started (no localhost fallback)"
                    ),
                    safe_reload_proxy_tls(),
                    ok
            end
    end.

safe_set_tls_hosts(Hosts, CertPem, KeyPem, CertPath, KeyPath) ->
    try
        ok = pertisk_ingress_tls:set_hosts(Hosts, CertPem, KeyPem, CertPath, KeyPath),
        ok
    catch
        C:R ->
            {error, {C, R}}
    end.

safe_reload_proxy_tls() ->
    try
        pertisk_eproxy_app:reload_proxy_tls_listeners()
    catch
        C:R:St ->
            lager:error("reload_proxy_tls_listeners failed: ~p:~p ~p", [C, R, St]),
            ok
    end.

stable_reload_sig(Sites, Backends, Tls) ->
    %% K8s list/watch can return the same resources in different order.
    %% Keep reload decisions stable across ordering-only changes.
    StableSites = lists:sort(Sites),
    StableBackends = lists:sort(Backends),
    StableTls = lists:sort(Tls),
    erlang:phash2({StableSites, StableBackends, StableTls}).
