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
                    _ = catch pertisk_eproxy_app:reload_tls_listeners(),
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
