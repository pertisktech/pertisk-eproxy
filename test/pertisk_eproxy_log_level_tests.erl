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
    ?assertEqual(info, pertisk_eproxy_log_level:configured()).
