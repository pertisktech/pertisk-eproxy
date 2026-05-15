%%%-------------------------------------------------------------------
%% @doc Primary logger filter:
%%      - Replace huge OTP supervisor events (progress + start_error) with short
%%        strings so jsonlog does not choke on funs / cert DER / nested sslsocket
%%        terms ("FORMATTER CRASH" in the console).
%%      - Drop noisy quic_closed teardown from erlang_quic (gen_statem / proc_lib)
%%        after normal HTTP/3 responses.
%%      - Drop duplicate proc_lib crash_report for quic_listener init + einval when
%%        supervisor start_error already summarizes the failure.
%%      - Shorten OTP ssl TLS alert notices (ssl_alert / ssl_logger report maps) so
%%        jsonlog does not dump huge #alert{} tuples and metadata.
%%%-------------------------------------------------------------------

-module(pertisk_eproxy_log_filter).

-export([primary/2]).

-spec primary(logger:log_event(), term()) -> logger:log_event() | stop.
primary(Log, Extra) ->
    case maybe_drop_logger_noise(Log) of
        stop ->
            stop;
        Log0 ->
            Log1 = maybe_simplify_supervisor_logs(Log0),
            Log2 = maybe_simplify_ssl_alert_logs(Log1),
            drop_quic_closed(Log2, Extra)
    end.

%% Duplicate detail: supervisor already logs start_error; crash_report is huge JSON.
-spec maybe_drop_logger_noise(logger:log_event()) -> logger:log_event() | stop.
maybe_drop_logger_noise(
    #{
        level := error,
        meta := #{mfa := {proc_lib, crash_report, _}},
        msg := Msg
    } = Log
) ->
    case quic_listener_einval_crash(Msg) of
        true -> stop;
        false -> Log
    end;
maybe_drop_logger_noise(Log) ->
    Log.

-spec quic_listener_einval_crash(term()) -> boolean().
quic_listener_einval_crash(Msg) ->
    Bin = iolist_to_binary(io_lib:format("~8000p", [Msg])),
    nomatch =/= binary:match(Bin, <<"quic_listener">>) andalso
        nomatch =/= binary:match(Bin, <<"einval">>).

%% OTP logs child starts at info with full childspec (Ranch SSL acceptors include
%% entire #{} ssl options). jsonlog then JSON-encodes that map and crashes or prints
%% unusable megabyte lines.
%%
%% start_error at error level repeats the same material in `offender` / mfargs.
-spec maybe_simplify_supervisor_logs(logger:log_event()) -> logger:log_event().
maybe_simplify_supervisor_logs(
    #{
        level := info,
        meta := #{mfa := {supervisor, report_progress, _}}
    } = Log
) ->
    Log#{msg => {string, <<"supervisor: child progress (details omitted)">>}};
maybe_simplify_supervisor_logs(
    #{
        level := info,
        meta := #{mfa := {supervisor_bridge, report_progress, _}}
    } = Log
) ->
    Log#{msg => {string, <<"supervisor_bridge: child progress (details omitted)">>}};
maybe_simplify_supervisor_logs(
    #{
        level := error,
        msg := {report, #{label := {supervisor, start_error}, report := Rep}}
    } = Log
) ->
    Log#{msg => {string, supervisor_start_error_summary(Rep)}};
maybe_simplify_supervisor_logs(Log) ->
    Log.

%% ssl_logger passes a map (protocol, role, alerter, statename, alert) with report_cb;
%% jsonlog ~p of #alert{} is noisy.
-spec maybe_simplify_ssl_alert_logs(logger:log_event()) -> logger:log_event().
maybe_simplify_ssl_alert_logs(
    #{
        meta := #{mfa := {ssl_alert, decode, _}},
        msg := Msg
    } = Log
) ->
    case ssl_alert_report_from_msg(Msg) of
        {ok, Summary} ->
            Log#{msg => {string, Summary}};
        error ->
            Log
    end;
maybe_simplify_ssl_alert_logs(Log) ->
    Log.

-spec ssl_alert_report_from_msg(term()) -> {ok, binary()} | error.
ssl_alert_report_from_msg(
    #{protocol := Prot, role := Role, alerter := Alt, statename := SN, alert := Alert}
) ->
    {ok, ssl_alert_summary(Prot, Role, Alt, SN, Alert)};
ssl_alert_report_from_msg({report, #{protocol := _, alert := _, role := _, alerter := _} = R}) ->
    ssl_alert_report_from_msg(R);
ssl_alert_report_from_msg(_) ->
    error.

-spec ssl_alert_summary(term(), term(), term(), term(), term()) -> binary().
ssl_alert_summary(Prot, Role, Alt, SN, Alert) ->
    iolist_to_binary(
        io_lib:format(
            "ssl TLS alert: protocol=~ts role=~0p alerter=~0p state=~0p ~ts",
            [ssl_alert_protocol_txt(Prot), Role, Alt, SN, ssl_alert_short(Alert)]
        )
    ).

-spec ssl_alert_protocol_txt(term()) -> binary().
ssl_alert_protocol_txt(P) when is_atom(P) ->
    atom_to_binary(P, utf8);
ssl_alert_protocol_txt(P) when is_binary(P) ->
    P;
ssl_alert_protocol_txt(P) when is_list(P) ->
    try iolist_to_binary(P) of
        B -> B
    catch
        _:_ -> <<"">>
    end;
ssl_alert_protocol_txt(_) ->
    <<"">>.

-spec ssl_alert_short(term()) -> binary().
ssl_alert_short(A) when is_tuple(A), tuple_size(A) >= 3, element(1, A) =:= alert ->
    Level = element(2, A),
    Desc = element(3, A),
    iolist_to_binary(io_lib:format("alert(level=~w,description=~w)", [Level, Desc]));
ssl_alert_short(A) ->
    iolist_to_binary(io_lib:format("alert(~120p)", [A])).

-spec supervisor_start_error_summary(term()) -> binary().
supervisor_start_error_summary(Rep) when is_map(Rep) ->
    Sup = maps:get(supervisor, Rep, undefined),
    Ctx = maps_get_first([errorContext, error_context], Rep, undefined),
    Reason = maps:get(reason, Rep, undefined),
    OffId = offender_child_id(maps:get(offender, Rep, undefined)),
    iolist_to_binary(
        io_lib:format(
            "supervisor start_error: sup=~0p context=~0p reason=~0p offender_id=~0p (mfargs omitted)",
            [Sup, Ctx, Reason, OffId]
        )
    );
supervisor_start_error_summary(Rep) when is_list(Rep) ->
    supervisor_start_error_summary(report_list_to_map(Rep));
supervisor_start_error_summary(Rep) ->
    iolist_to_binary(io_lib:format("supervisor start_error (unparsed report): ~2000p", [Rep])).

-spec report_list_to_map([{term(), term()}]) -> map().
report_list_to_map(L) ->
    lists:foldl(fun({K, V}, Acc) -> Acc#{K => V} end, #{}, L).

-spec maps_get_first([K], #{K => V}, V) -> V.
maps_get_first([], _Map, Def) ->
    Def;
maps_get_first([K | Rest], Map, Def) ->
    case maps:find(K, Map) of
        {ok, V} -> V;
        error -> maps_get_first(Rest, Map, Def)
    end.

-spec offender_child_id(term()) -> term().
offender_child_id(Off) when is_tuple(Off), tuple_size(Off) >= 1 ->
    element(1, Off);
offender_child_id(Off) when is_map(Off) ->
    maps_get_first([id, child_id], Off, undefined);
offender_child_id(Off) when is_list(Off) ->
    %% OTP supervisor report uses a proplist-like [{pid,...},{id,...},{mfargs,...},...]
    case lists:keyfind(id, 1, Off) of
        {id, Id} ->
            Id;
        false ->
            case lists:keyfind(name, 1, Off) of
                {name, Nm} -> Nm;
                false -> mfargs_summary(Off)
            end
    end;
offender_child_id(Off) ->
    Off.

-spec mfargs_summary(term()) -> term().
mfargs_summary(Off) when is_list(Off) ->
    case lists:keyfind(mfargs, 1, Off) of
        {mfargs, {M, F, _}} when is_atom(M), is_atom(F) ->
            {M, F};
        {mfargs, _} ->
            undefined;
        false -> undefined
    end;
mfargs_summary(_) ->
    undefined.

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
