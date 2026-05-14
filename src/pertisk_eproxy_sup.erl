%%%-------------------------------------------------------------------
%% @doc pertisk_eproxy top level supervisor
%% @end
%%%-------------------------------------------------------------------

-module(pertisk_eproxy_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================
%% API functions
%%%===================================================================

-spec start_link() -> {ok, Pid} | {error, Reason}
    when Pid :: pid(),
         Reason :: term().
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%%===================================================================
%% Supervisor callbacks
%%%===================================================================

-spec init(Args) -> {ok, {SupFlags, ChildSpecs}}
    when Args :: term(),
         SupFlags :: supervisor:sup_flags(),
         ChildSpecs :: [supervisor:child_spec()].
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },

    ChildSpecs = [
        #{
            id => pertisk_eproxy_acme,
            start => {pertisk_eproxy_acme, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker
        },
        #{
            id => pertisk_eproxy_compression,
            start => {pertisk_eproxy_compression, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker
        },
        #{
            id => pertisk_eproxy_admin,
            start => {pertisk_eproxy_admin, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker
        },
        #{
            id => pertisk_eproxy_proxy,
            start => {pertisk_eproxy_proxy, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker
        }
    ],

    {ok, {SupFlags, ChildSpecs}}.

%%%===================================================================
%% Internal functions
%%%===================================================================
