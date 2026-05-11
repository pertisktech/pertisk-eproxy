%% @doc Optional QUIC/HTTP3 bootstrap shim.
%% This module does not implement QUIC itself; it attempts to start an external
%% QUIC engine if one is present in the runtime (for example `quicer`).
-module(pertisk_eproxy_quic).

-export([start/2, stop/0]).

-include_lib("lager/include/lager.hrl").

-define(TAB, ?MODULE).

-spec start(non_neg_integer(), map()) -> ok | {error, term()}.
start(Port, _Config) ->
    ensure_tab(),
    case code:which(quicer_listener) of
        non_existing ->
            lager:warning("QUIC requested on udp/:~w but no QUIC engine found (missing quicer_listener). HTTP/3 will remain unavailable.", [Port]),
            {error, quic_engine_missing};
        _ ->
            case catch apply(quicer_listener, start_link, [#{port => Port}]) of
                {ok, Pid} when is_pid(Pid) ->
                    ets:insert(?TAB, {quic_pid, Pid}),
                    lager:info("QUIC listener started on udp/:~w", [Port]),
                    ok;
                {'EXIT', Reason} ->
                    lager:error("Failed to start QUIC listener on udp/:~w: ~p", [Port, Reason]),
                    {error, Reason};
                Other ->
                    lager:error("Unexpected QUIC start result on udp/:~w: ~p", [Port, Other]),
                    {error, Other}
            end
    end.

-spec stop() -> ok.
stop() ->
    ensure_tab(),
    case ets:lookup(?TAB, quic_pid) of
        [{quic_pid, Pid}] when is_pid(Pid) ->
            _ = catch exit(Pid, shutdown),
            ets:delete(?TAB, quic_pid),
            ok;
        _ ->
            ok
    end.

ensure_tab() ->
    case ets:info(?TAB) of
        undefined -> ets:new(?TAB, [named_table, public, set]);
        _ -> ok
    end.
