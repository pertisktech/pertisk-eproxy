-module(pertisk_eproxy_lager_ring_backend_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("lager/include/lager.hrl").

ensure_access_log() ->
    case whereis(pertisk_eproxy_access_log) of
        undefined -> {ok, _} = pertisk_eproxy_access_log:start_link();
        _ -> ok
    end.

msg(Severity, Message, Meta) ->
    lager_msg:new(Message, Severity, Meta, []).

st() ->
    {ok, St} = pertisk_eproxy_lager_ring_backend:init([]),
    St.

init_returns_state_test() ->
    ?assertMatch({ok, _}, pertisk_eproxy_lager_ring_backend:init([])).

handle_event_error_logs_system_test() ->
    ensure_access_log(),
    St = st(),
    M = msg(error, <<"disk full">>, []),
    ?assertMatch({ok, _}, pertisk_eproxy_lager_ring_backend:handle_event({log, M}, St)).

handle_event_warning_logs_system_test() ->
    ensure_access_log(),
    St = st(),
    M = msg(warning, <<"high memory">>, []),
    ?assertMatch({ok, _}, pertisk_eproxy_lager_ring_backend:handle_event({log, M}, St)).

handle_event_notice_logs_system_test() ->
    ensure_access_log(),
    St = st(),
    M = msg(notice, <<"notice">>, []),
    ?assertMatch({ok, _}, pertisk_eproxy_lager_ring_backend:handle_event({log, M}, St)).

handle_event_info_skips_test() ->
    ensure_access_log(),
    St = st(),
    M = msg(info, <<"info">>, []),
    ?assertMatch({ok, _}, pertisk_eproxy_lager_ring_backend:handle_event({log, M}, St)).

handle_event_proxy_http_skips_test() ->
    ensure_access_log(),
    St = st(),
    M = msg(warning, <<"proxy 502">>, [{type, http}]),
    ?assertMatch({ok, _}, pertisk_eproxy_lager_ring_backend:handle_event({log, M}, St)).

handle_event_other_ignored_test() ->
    St = st(),
    ?assertMatch({ok, _}, pertisk_eproxy_lager_ring_backend:handle_event(ignored, St)).

handle_call_get_loglevel_test() ->
    St = st(),
    ?assertMatch({ok, _, _}, pertisk_eproxy_lager_ring_backend:handle_call(get_loglevel, St)).

handle_call_set_loglevel_test() ->
    St = st(),
    ?assertMatch({ok, ok, _}, pertisk_eproxy_lager_ring_backend:handle_call({set_loglevel, debug}, St)).

handle_call_unknown_test() ->
    St = st(),
    ?assertMatch({ok, {error, unknown_request}, _},
        pertisk_eproxy_lager_ring_backend:handle_call(unknown, St)).

handle_info_ignored_test() ->
    St = st(),
    ?assertMatch({ok, _}, pertisk_eproxy_lager_ring_backend:handle_info(msg, St)).

terminate_ok_test() ->
    ?assertEqual(ok, pertisk_eproxy_lager_ring_backend:terminate(normal, st())).

code_change_ok_test() ->
    St = st(),
    ?assertMatch({ok, _}, pertisk_eproxy_lager_ring_backend:code_change(1, St, extra)).
