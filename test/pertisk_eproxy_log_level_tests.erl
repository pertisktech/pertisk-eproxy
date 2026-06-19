-module(pertisk_eproxy_log_level_tests).

-include_lib("eunit/include/eunit.hrl").

parse_debug_test() ->
    ?assertEqual({ok, debug}, pertisk_eproxy_log_level:parse(<<"debug">>)).

parse_info_test() ->
    ?assertEqual({ok, info}, pertisk_eproxy_log_level:parse("INFO")).

parse_warn_aliases_test() ->
    ?assertEqual({ok, warn}, pertisk_eproxy_log_level:parse(<<"warning">>)),
    ?assertEqual({ok, warn}, pertisk_eproxy_log_level:parse(warning)).

parse_error_test() ->
    ?assertEqual({ok, error}, pertisk_eproxy_log_level:parse(<<" error ">>)).

parse_notice_critical_alert_emergency_test() ->
    ?assertEqual({ok, notice}, pertisk_eproxy_log_level:parse(notice)),
    ?assertEqual({ok, critical}, pertisk_eproxy_log_level:parse(<<"critical">>)),
    ?assertEqual({ok, alert}, pertisk_eproxy_log_level:parse(alert)),
    ?assertEqual({ok, emergency}, pertisk_eproxy_log_level:parse(<<"emergency">>)).

parse_invalid_test() ->
    ?assertEqual(error, pertisk_eproxy_log_level:parse(<<"verbose">>)),
    ?assertEqual(error, pertisk_eproxy_log_level:parse(123)).

label_maps_warning_to_warn_test() ->
    ?assertEqual("warn", pertisk_eproxy_log_level:label(warning)),
    ?assertEqual("warn", pertisk_eproxy_log_level:label(warn)),
    ?assertEqual("info", pertisk_eproxy_log_level:label(info)).

apply_returns_ok_test() ->
    application:ensure_all_started(lager),
    ?assertEqual(ok, pertisk_eproxy_log_level:apply()).

configured_reads_env_override_test() ->
    os:putenv("PERTISK_LOG_LEVEL", "debug"),
    ?assertEqual(debug, pertisk_eproxy_log_level:configured()),
    os:unsetenv("PERTISK_LOG_LEVEL").

configured_invalid_env_falls_back_test() ->
    os:putenv("PERTISK_LOG_LEVEL", "not-a-level"),
    Level = pertisk_eproxy_log_level:configured(),
    os:unsetenv("PERTISK_LOG_LEVEL"),
    ?assert(is_atom(Level)).

configured_defaults_when_unset_test() ->
    os:unsetenv("PERTISK_LOG_LEVEL"),
    with_mocked_config(#{http_port => 80}, fun() ->
        ?assertEqual(info, pertisk_eproxy_log_level:configured())
    end).

parse_atom_levels_test() ->
    ?assertEqual({ok, debug}, pertisk_eproxy_log_level:parse(debug)),
    ?assertEqual({ok, info}, pertisk_eproxy_log_level:parse(info)),
    ?assertEqual({ok, warn}, pertisk_eproxy_log_level:parse(warn)),
    ?assertEqual({ok, error}, pertisk_eproxy_log_level:parse(error)),
    ?assertEqual({ok, critical}, pertisk_eproxy_log_level:parse(critical)),
    ?assertEqual({ok, emergency}, pertisk_eproxy_log_level:parse(emergency)).

parse_unknown_atom_test() ->
    ?assertEqual(error, pertisk_eproxy_log_level:parse(not_a_level)).

parse_notice_and_alert_strings_test() ->
    ?assertEqual({ok, notice}, pertisk_eproxy_log_level:parse(<<"notice">>)),
    ?assertEqual({ok, warn}, pertisk_eproxy_log_level:parse(<<"warn">>)),
    ?assertEqual({ok, alert}, pertisk_eproxy_log_level:parse(<<"alert">>)).

apply_warn_level_test() ->
    application:ensure_all_started(lager),
    os:putenv("PERTISK_LOG_LEVEL", "warn"),
    ?assertEqual(ok, pertisk_eproxy_log_level:apply()),
    os:unsetenv("PERTISK_LOG_LEVEL").

apply_without_console_backend_test() ->
    application:ensure_all_started(lager),
    pertisk_eproxy_test_helpers:ignoring_errors(fun() -> lager:stop_backend(lager_console_backend) end),
    os:putenv("PERTISK_LOG_LEVEL", "info"),
    ?assertEqual(ok, pertisk_eproxy_log_level:apply()),
    application:ensure_all_started(lager),
    os:unsetenv("PERTISK_LOG_LEVEL").

apply_empty_handlers_covers_backend_error_paths_test() ->
    %% Stops/restarts lager globally; unsafe under parallel eunit (other jobs need lager).
    case os:getenv("PERTISK_EUNIT_PARALLEL") of
        "1" -> apply_empty_handlers_covers_backend_error_paths_test_body();
        false -> apply_empty_handlers_covers_backend_error_paths_test_body();
        _ -> ok
    end.

apply_empty_handlers_covers_backend_error_paths_test_body() ->
    application:load(lager),
    application:set_env(lager, handlers, []),
    application:stop(lager),
    {ok, _} = application:ensure_all_started(lager),
    os:putenv("PERTISK_LOG_LEVEL", "info"),
    try
        ?assertEqual(ok, pertisk_eproxy_log_level:apply())
    after
        os:unsetenv("PERTISK_LOG_LEVEL"),
        application:set_env(lager, handlers, [{lager_console_backend, [{level, info}]}]),
        application:stop(lager),
        application:ensure_all_started(lager)
    end.

configured_from_config_log_level_test() ->
    os:unsetenv("PERTISK_LOG_LEVEL"),
    with_mocked_config(#{log_level => notice}, fun() ->
        ?assertEqual(notice, pertisk_eproxy_log_level:configured())
    end).

with_mocked_config(Config, Fun) ->
    meck:new(pertisk_eproxy_config, [passthrough, unstick]),
    try
        meck:expect(pertisk_eproxy_config, get_config, fun() -> Config end),
        Fun()
    after
        pertisk_eproxy_test_helpers:unload_mocks([pertisk_eproxy_config])
    end.

apply_file_backend_ok_path_test() ->
    case os:getenv("PERTISK_EUNIT_PARALLEL") of
        "1" -> apply_file_backend_ok_path_test_body();
        false -> apply_file_backend_ok_path_test_body();
        _ -> ok
    end.

apply_file_backend_ok_path_test_body() ->
    application:load(lager),
    LogFile = lists:flatten(io_lib:format("/tmp/pertisk_eproxy_cover_~p.log", [erlang:unique_integer([positive])])),
    application:set_env(lager, handlers, [
        {lager_console_backend, [{level, info}]},
        {lager_file_backend, [{file, LogFile}, {level, info}]}
    ]),
    application:stop(lager),
    {ok, _} = application:ensure_all_started(lager),
    os:putenv("PERTISK_LOG_LEVEL", "info"),
    ?assertEqual(ok, pertisk_eproxy_log_level:apply()),
    os:unsetenv("PERTISK_LOG_LEVEL").
