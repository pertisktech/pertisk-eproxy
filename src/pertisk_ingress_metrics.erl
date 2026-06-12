%% @doc Prometheus metrics for the Kubernetes ingress controller.
-module(pertisk_ingress_metrics).

-export([setup/0, record_reconcile/2, set_gauges/3]).

setup() ->
    prometheus_counter:declare([
        {name, pertisk_ingress_reconcile_total},
        {help, "Ingress reconcile attempts"},
        {labels, [result]}
    ]),
    prometheus_gauge:declare([
        {name, pertisk_ingress_sites},
        {help, "Sites programmed from Kubernetes Ingress"}
    ]),
    prometheus_gauge:declare([
        {name, pertisk_ingress_backends},
        {help, "Backends programmed from Kubernetes Ingress"}
    ]),
    prometheus_gauge:declare([
        {name, pertisk_ingress_tls_secrets},
        {help, "TLS secrets loaded from Kubernetes"}
    ]),
    prometheus_gauge:declare([
        {name, pertisk_ingress_leader},
        {help, "Whether this pod holds the ingress leader lease (1=yes)"}
    ]),
    ok.

record_reconcile(ok, _Details) ->
    prometheus_counter:inc(pertisk_ingress_reconcile_total, [success]);
record_reconcile({error, _}, _Details) ->
    prometheus_counter:inc(pertisk_ingress_reconcile_total, [error]);
record_reconcile(_, _) ->
    ok.

set_gauges(Sites, Backends, TlsCount) when is_list(Sites), is_list(Backends) ->
    prometheus_gauge:set(pertisk_ingress_sites, length(Sites)),
    prometheus_gauge:set(pertisk_ingress_backends, length(Backends)),
    prometheus_gauge:set(pertisk_ingress_tls_secrets, TlsCount),
    case pertisk_ingress_leader:is_leader() of
        true -> prometheus_gauge:set(pertisk_ingress_leader, 1);
        false -> prometheus_gauge:set(pertisk_ingress_leader, 0)
    end,
    ok.
