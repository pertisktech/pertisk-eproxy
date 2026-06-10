-module(pertisk_eproxy_couchdb_log_tests).

-include_lib("eunit/include/eunit.hrl").

%% ---------------------------------------------------------------------------
%% log/1 tests
%% ---------------------------------------------------------------------------

log_map_returns_ok_test() ->
    ?assertEqual(ok, pertisk_eproxy_couchdb_log:log(#{<<"test">> => <<"value">>})).

log_non_map_returns_ok_test() ->
    ?assertEqual(ok, pertisk_eproxy_couchdb_log:log(<<"not_a_map">>)).

log_empty_map_returns_ok_test() ->
    ?assertEqual(ok, pertisk_eproxy_couchdb_log:log(#{})).

%% ---------------------------------------------------------------------------
%% status/0 tests
%% ---------------------------------------------------------------------------

status_returns_map_test() ->
    Result = pertisk_eproxy_couchdb_log:status(),
    ?assert(is_map(Result)),
    ?assert(maps:is_key(alive, Result)).