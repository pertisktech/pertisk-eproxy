%% @doc Dynamic supervisor for per-backend gen_server workers.
-module(pertisk_eproxy_backend_sup).
-behaviour(supervisor).

-export([start_link/0, start_backend/1, stop_backend/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy  => one_for_one,
        intensity => 10,
        period    => 60
    },
    %% Children started dynamically via start_backend/1
    {ok, {SupFlags, []}}.

%% Start a backend worker for the given backend config map.
start_backend(Backend = #{name := Name}) ->
    ChildSpec = #{
        id       => {backend, Name},
        start    => {pertisk_eproxy_backend, start_link, [Backend]},
        restart  => transient,
        shutdown => 5000,
        type     => worker
    },
    supervisor:start_child(?MODULE, ChildSpec).

%% Stop (and remove) a backend worker by name.
stop_backend(Name) ->
    supervisor:terminate_child(?MODULE, {backend, Name}),
    supervisor:delete_child(?MODULE, {backend, Name}).
