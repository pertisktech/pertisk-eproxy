-module(pertisk_eproxy_cowboy_logger_tests).

-include_lib("eunit/include/eunit.hrl").

with_lager(Fun) ->
    pertisk_eproxy_test_helpers:ensure_lager(),
    Fun().

%% ---------------------------------------------------------------------------
%% Logging wrapper functions
%% ---------------------------------------------------------------------------

emergency_returns_ok_test() ->
    with_lager(fun() ->
        ?assertEqual(ok, pertisk_eproxy_cowboy_logger:emergency("test ~p", [1]))
    end).

alert_returns_ok_test() ->
    with_lager(fun() ->
        ?assertEqual(ok, pertisk_eproxy_cowboy_logger:alert("test ~p", [1]))
    end).

critical_returns_ok_test() ->
    with_lager(fun() ->
        ?assertEqual(ok, pertisk_eproxy_cowboy_logger:critical("test ~p", [1]))
    end).

error_returns_ok_test() ->
    with_lager(fun() ->
        ?assertEqual(ok, pertisk_eproxy_cowboy_logger:error("test ~p", [1]))
    end).

warning_normal_test() ->
    with_lager(fun() ->
        ?assertEqual(ok, pertisk_eproxy_cowboy_logger:warning("normal warning ~p", [1]))
    end).

warning_quic_shutdown_suppressed_test() ->
  with_lager(fun() ->
    %% The function suppresses "Received unknown QUIC message" for shutdown.
    ?assertEqual(ok, pertisk_eproxy_cowboy_logger:warning(
        "Received unknown QUIC message ~p.", [{quic, shutdown, ref, 0}]))
  end).

notice_returns_ok_test() ->
    with_lager(fun() ->
        ?assertEqual(ok, pertisk_eproxy_cowboy_logger:notice("test ~p", [1]))
    end).

info_returns_ok_test() ->
    with_lager(fun() ->
        ?assertEqual(ok, pertisk_eproxy_cowboy_logger:info("test ~p", [1]))
    end).

debug_returns_ok_test() ->
    with_lager(fun() ->
        ?assertEqual(ok, pertisk_eproxy_cowboy_logger:debug("test ~p", [1]))
    end).