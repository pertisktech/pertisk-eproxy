-module(pertisk_eproxy_app_tests).

-include_lib("eunit/include/eunit.hrl").

quic_noise_filter_stops_shutdown_message_test() ->
    Msg = #{msg => {string, "Received unknown QUIC message ~p.", [{quic, shutdown, ref, 0}]}},
    ?assertEqual(stop, pertisk_eproxy_app:quic_noise_filter(Msg, #{})).

quic_noise_filter_ignores_other_messages_test() ->
    ?assertEqual(ignore, pertisk_eproxy_app:quic_noise_filter(#{msg => {string, "hello", []}}, #{})),
    ?assertEqual(ignore, pertisk_eproxy_app:quic_noise_filter(#{other => true}, #{})).
