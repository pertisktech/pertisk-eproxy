%% @doc Lager backend that mirrors warning/error log messages into the in-memory
%% ring buffer so they appear in the admin UI under "System" / "Crash/Error" tabs.
%% Handles all messages routed through lager, including OTP supervisor/crash reports.
-module(pertisk_eproxy_lager_ring_backend).

-behaviour(gen_event).

-export([init/1, handle_event/2, handle_call/2, handle_info/2,
         terminate/2, code_change/3]).

-record(st, {}).

%% ---------------------------------------------------------------------------

init(_Opts) ->
    {ok, #st{}}.

handle_event({log, Message}, St) ->
    %% Proxy access lines (4xx/5xx) already live in the ring as structured `proxy` entries
    %% via pertisk_eproxy_access_log:log_proxy/8; skip mirroring lager:warning duplicates.
    case proxy_http_access_message(Message) of
        true ->
            {ok, St};
        false ->
            case lager_msg:severity(Message) of
                Sev when Sev =:= error; Sev =:= critical; Sev =:= alert; Sev =:= emergency ->
                    Msg = safe_message(Message),
                    _ = catch pertisk_eproxy_access_log:log_system(<<"error">>, <<"error">>, Msg);
                Sev when Sev =:= warning; Sev =:= notice ->
                    Msg = safe_message(Message),
                    _ = catch pertisk_eproxy_access_log:log_system(<<"warn">>, <<"system">>, Msg);
                _ ->
                    ok
            end,
            {ok, St}
    end;
handle_event(_Event, St) ->
    {ok, St}.

%% lager management calls — required so lager can get/set the effective level.
handle_call(get_loglevel, St) ->
    {ok, lager_util:config_to_mask(warning), St};
handle_call({set_loglevel, _Level}, St) ->
    {ok, ok, St};
handle_call(_Req, St) ->
    {ok, {error, unknown_request}, St}.

handle_info(_Info, St) ->
    {ok, St}.

terminate(_Reason, _St) ->
    ok.

code_change(_OldVsn, St, _Extra) ->
    {ok, St}.

%% ---------------------------------------------------------------------------
%% Internal

proxy_http_access_message(Message) ->
    case lager_msg:metadata(Message) of
        Meta when is_list(Meta) ->
            proplists:get_value(type, Meta) =:= http;
        _ ->
            false
    end.

safe_message(Message) ->
    try iolist_to_binary(lager_msg:message(Message))
    catch _:_ -> <<"(unformattable log message)">>
    end.
