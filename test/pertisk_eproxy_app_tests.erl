-module(pertisk_eproxy_app_tests).

-include_lib("eunit/include/eunit.hrl").

%% ---------------------------------------------------------------------------
%% quic_noise_filter/2 tests
%% ---------------------------------------------------------------------------

quic_noise_filter_quic_shutdown_stops_test() ->
    Msg = {string, "Received unknown QUIC message ~p.", [{quic, shutdown, ref1, 0}]},
    ?assertEqual(stop, pertisk_eproxy_app:quic_noise_filter(#{msg => Msg}, #{})).

quic_noise_filter_no_msg_ignores_test() ->
    ?assertEqual(ignore, pertisk_eproxy_app:quic_noise_filter(#{}, #{})).

quic_noise_filter_other_string_ignores_test() ->
    Msg = {string, "Normal message ~p", [test]},
    ?assertEqual(ignore, pertisk_eproxy_app:quic_noise_filter(#{msg => Msg}, #{})).

quic_noise_filter_other_report_ignores_test() ->
    Msg = {report, #{some => data}},
    ?assertEqual(ignore, pertisk_eproxy_app:quic_noise_filter(#{msg => Msg}, #{})).

quic_noise_filter_quic_shutdown_report_stops_test() ->
    Msg = {report, #{format => "Received unknown QUIC message {quic,shutdown,ref1,0}"}},
    ?assertEqual(stop, pertisk_eproxy_app:quic_noise_filter(#{msg => Msg}, #{})).

quic_noise_filter_quic_shutdown_other_type_stops_test() ->
    Msg = "Received unknown QUIC message {quic,shutdown,ref,1}",
    ?assertEqual(stop, pertisk_eproxy_app:quic_noise_filter(#{msg => Msg}, #{})).