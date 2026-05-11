%% @doc Top-level supervisor for pertisk_eproxy.
-module(pertisk_eproxy_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy  => one_for_one,
        intensity => 10,
        period    => 60
    },
    Children = [
        %% Config manager (ETS-backed, hot-reload capable)
        #{id       => pertisk_eproxy_config,
          start    => {pertisk_eproxy_config, start_link, []},
          restart  => permanent,
          shutdown => 5000,
          type     => worker},

        %% Backend supervisor (one gen_server per backend)
        #{id       => pertisk_eproxy_backend_sup,
          start    => {pertisk_eproxy_backend_sup, start_link, []},
          restart  => permanent,
          shutdown => infinity,
          type     => supervisor},

        %% Metrics server
        #{id       => pertisk_eproxy_metrics,
          start    => {pertisk_eproxy_metrics, start_link, []},
          restart  => permanent,
          shutdown => 5000,
          type     => worker}
    ],
    {ok, {SupFlags, Children}}.
