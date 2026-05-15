%%%-------------------------------------------------------------------
%% @doc Primary logger filter: drop noisy quic_closed teardown from erlang_quic
%%      (gen_statem / proc_lib) after normal HTTP/3 responses.
%%%-------------------------------------------------------------------

-module(pertisk_eproxy_log_filter).

-export([drop_quic_closed/2]).

-spec drop_quic_closed(logger:log_event(), term()) -> logger:log_event() | stop.
drop_quic_closed(#{level := error, msg := Msg, meta := Meta} = Log, _) ->
    case term_has_quic_closed(Msg) of
        false ->
            Log;
        true ->
            case maps:get(mfa, Meta, undefined) of
                {gen_statem, error_info, 7} ->
                    stop;
                {proc_lib, crash_report, 4} ->
                    stop;
                _ ->
                    Log
            end
    end;
drop_quic_closed(Log, _) ->
    Log.

-spec term_has_quic_closed(term()) -> boolean().
term_has_quic_closed(Msg) ->
    Bin = iolist_to_binary(io_lib:format("~5000p", [Msg])),
    nomatch =/= binary:match(Bin, <<"quic_closed">>).
