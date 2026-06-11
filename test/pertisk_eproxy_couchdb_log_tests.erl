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

with_server(Fun) ->
    case whereis(pertisk_eproxy_couchdb_log) of
        undefined ->
            {ok, Pid} = pertisk_eproxy_couchdb_log:start_link(),
            try Fun(Pid) after catch gen_server:stop(Pid, normal, 5000) end;
        Pid ->
            Fun(Pid)
    end.

start_link_disabled_config_test() ->
    Old = application:get_env(pertisk_eproxy, couchdb_log),
    application:set_env(pertisk_eproxy, couchdb_log, #{enabled => false}),
    try
        with_server(fun(_Pid) ->
            ?assertMatch(#{alive := true, enabled := false}, pertisk_eproxy_couchdb_log:status())
        end)
    after
        case Old of
            {ok, V} -> application:set_env(pertisk_eproxy, couchdb_log, V);
            undefined -> application:unset_env(pertisk_eproxy, couchdb_log)
        end
    end.

log_cast_when_disabled_test() ->
    Old = application:get_env(pertisk_eproxy, couchdb_log),
    application:set_env(pertisk_eproxy, couchdb_log, #{enabled => false}),
    try
        with_server(fun(_Pid) ->
            ?assertEqual(ok, pertisk_eproxy_couchdb_log:log(#{<<"path">> => <<"/">>}))
        end)
    after
        case Old of
            {ok, V} -> application:set_env(pertisk_eproxy, couchdb_log, V);
            undefined -> application:unset_env(pertisk_eproxy, couchdb_log)
        end
    end.

handle_continue_connect_disabled_test() ->
    Old = application:get_env(pertisk_eproxy, couchdb_log),
    application:set_env(pertisk_eproxy, couchdb_log, #{enabled => false}),
    try
        {ok, St, _} = pertisk_eproxy_couchdb_log:init([]),
        ?assertMatch({noreply, _}, pertisk_eproxy_couchdb_log:handle_continue(connect, St))
    after
        case Old of
            {ok, V} -> application:set_env(pertisk_eproxy, couchdb_log, V);
            undefined -> application:unset_env(pertisk_eproxy, couchdb_log)
        end
    end.

gen_server_callbacks_test() ->
    {ok, St, _} = pertisk_eproxy_couchdb_log:init([]),
    ?assertMatch({reply, _, _}, pertisk_eproxy_couchdb_log:handle_call(status, self(), St)),
    ?assertMatch({reply, ok, _}, pertisk_eproxy_couchdb_log:handle_call(other, self(), St)),
    ?assertMatch({noreply, _}, pertisk_eproxy_couchdb_log:handle_cast(other, St)),
    ?assertMatch({noreply, _}, pertisk_eproxy_couchdb_log:handle_info(other, St)),
    ?assertEqual(ok, pertisk_eproxy_couchdb_log:terminate(normal, St)),
    ?assertMatch({ok, _}, pertisk_eproxy_couchdb_log:code_change(1, St, extra)).