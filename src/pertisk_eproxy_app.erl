%%%-------------------------------------------------------------------
%% @doc pertisk_eproxy application startup callback module
%% @end
%%%-------------------------------------------------------------------

-module(pertisk_eproxy_app).
-behaviour(application).

-export([start/2, stop/1]).

%%%===================================================================
%% Application callbacks
%%%===================================================================

-spec start(StartType, StartArgs) -> {ok, Pid} | {error, Reason}
    when StartType :: application:start_type(),
         StartArgs :: term(),
         Pid :: pid(),
         Reason :: term().
start(_StartType, _StartArgs) ->
    io:format("Starting pertisk_eproxy application~n"),
    pertisk_eproxy_sup:start_link().

-spec stop(State) -> ok
    when State :: term().
stop(_State) ->
    io:format("Stopping pertisk_eproxy application~n"),
    ok.

%%%===================================================================
%% Internal functions
%%%===================================================================
