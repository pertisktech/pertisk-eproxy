%% @doc Supervisor for Kubernetes ingress controller processes.
-module(pertisk_ingress_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        #{id => pertisk_ingress_tls,
          start => {pertisk_ingress_tls, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker},
        #{id => pertisk_ingress_leader,
          start => {pertisk_ingress_leader, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker},
        #{id => pertisk_ingress_watcher,
          start => {pertisk_ingress_watcher, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker}
    ],
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 30
    },
    {ok, {SupFlags, Children}}.
