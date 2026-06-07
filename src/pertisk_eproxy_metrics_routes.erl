%% @doc Route table for the dedicated Prometheus metrics listener.
-module(pertisk_eproxy_metrics_routes).

-export([dispatch/0]).

-spec dispatch() -> cowboy_router:dispatch_rule().
dispatch() ->
    cowboy_router:compile([{'_', [
        {"/metrics", pertisk_eproxy_metrics_handler, metrics},
        {"/health", pertisk_eproxy_metrics_handler, health}
    ]}]).
