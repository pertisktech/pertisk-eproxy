-module(pertisk_eproxy_cowboy_logger_tests).

-include_lib("eunit/include/eunit.hrl").

%% ---------------------------------------------------------------------------
%% Logging wrapper functions
%% ---------------------------------------------------------------------------

emergency_returns_ok_test() ->
    ?assertEqual(ok, pertisk_eproxy_cowboy_logger:emergency("test ~p", [1])).

alert_returns_ok_test() ->
    ?assertEqual(ok, pertisk_eproxy_cowboy_logger:alert("test ~p", [1])).

critical_returns_ok_test() ->
    ?assertEqual(ok, pertisk_eproxy_cowboy_logger:critical("test ~p", [1])).

error_returns_ok_test() ->
    ?assertEqual(ok, pertisk_eproxy_cowboy_logger:error("test ~p", [1])).

warning_normal_test() ->
    ?assertEqual(ok, pertisk_eproxy_cowboy_logger:warning("normal warning ~p", [1])).

warning_quic_shutdown_suppressed_test() ->
    %% The function suppresses "Received unknown QUIC message" for shutdown.
    ?assertEqual(ok, pertisk_eproxy_cowboy_logger:warning(
        "Received unknown QUIC message ~p.", [{quic, shutdown, ref, 0}])).

notice_returns_ok_test() ->
    ?assertEqual(ok, pertisk_eproxy_cowboy_logger:notice("test ~p", [1])).

info_returns_ok_test() ->
    ?assertEqual(ok, pertisk_eproxy_cowboy_logger:info("test ~p", [1])).

debug_returns_ok_test() ->
    ?assertEqual(ok, pertisk_eproxy_cowboy_logger:debug("test ~p", [1])).