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
    ok = install_log_filters(),
    io:format("Starting pertisk_eproxy application~n"),
    pertisk_eproxy_sup:start_link().

-spec stop(State) -> ok
    when State :: term().
stop(_State) ->
    _ = logger:remove_primary_filter(pertisk_eproxy_primary),
    io:format("Stopping pertisk_eproxy application~n"),
    ok.

-spec install_log_filters() -> ok.
install_log_filters() ->
    _ = logger:remove_primary_filter(pertisk_eproxy_primary),
    %% Legacy id from older releases (safe no-op if absent)
    _ = logger:remove_primary_filter(drop_quic_closed),
    ok =
        logger:add_primary_filter(
            pertisk_eproxy_primary,
            {fun pertisk_eproxy_log_filter:primary/2, []}
        ).

%%%===================================================================
%% Internal functions
%%%===================================================================
