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
            try Fun(Pid) after pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000) end;
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

with_couchdb_env(Config, Fun) ->
    Old = application:get_env(pertisk_eproxy, couchdb_log),
    application:set_env(pertisk_eproxy, couchdb_log, Config),
    try Fun() after
        case Old of
            {ok, V} -> application:set_env(pertisk_eproxy, couchdb_log, V);
            undefined -> application:unset_env(pertisk_eproxy, couchdb_log)
        end
    end.

connect_enabled_with_url_test() ->
    MockDb = connected_db,
    with_couchdb_env(#{enabled => true, url => <<"http://couchdb:5984">>, db => <<"access-logs">>}, fun() ->
        meck:new(couchbeam, [unstick]),
        meck:expect(couchbeam, server_connection, fun(Url, _Opts) -> {server, Url} end),
        meck:expect(couchbeam, open_or_create_db, fun({server, Url}, DbName) ->
            ?assertEqual(<<"http://couchdb:5984">>, Url),
            ?assertEqual(<<"access-logs">>, DbName),
            {ok, MockDb}
        end),
        try
            {ok, St, _} = pertisk_eproxy_couchdb_log:init([]),
            {noreply, St2} = pertisk_eproxy_couchdb_log:handle_continue(connect, St),
            ?assertEqual(MockDb, element(8, St2))
        after
            pertisk_eproxy_test_helpers:unload_mocks([couchbeam])
        end
    end).

connect_enabled_url_undefined_test() ->
    with_couchdb_env(#{enabled => true}, fun() ->
        {ok, St, _} = pertisk_eproxy_couchdb_log:init([]),
        {noreply, St2} = pertisk_eproxy_couchdb_log:handle_continue(connect, St),
        ?assertEqual(undefined, element(3, St2)),
        ?assertEqual(undefined, element(8, St2))
    end).

handle_cast_log_with_db_test() ->
    MockDb = connected_db,
    with_couchdb_env(#{enabled => true, url => <<"http://couchdb:5984">>}, fun() ->
        meck:new(couchbeam, [unstick]),
        meck:expect(couchbeam, server_connection, fun(_, _) -> server end),
        meck:expect(couchbeam, open_or_create_db, fun(_, _) -> {ok, MockDb} end),
        meck:expect(couchbeam, save_doc, fun(Db, Doc) ->
            ?assertEqual(MockDb, Db),
            ?assertEqual(<<"pertisk-eproxy">>, maps:get(<<"source">>, Doc)),
            {ok, #{<<"ok">> => true}}
        end),
        try
            {ok, St, _} = pertisk_eproxy_couchdb_log:init([]),
            {noreply, St1} = pertisk_eproxy_couchdb_log:handle_continue(connect, St),
            ?assertMatch({noreply, _},
                pertisk_eproxy_couchdb_log:handle_cast({log, #{<<"path">> => <<"/api">>}}, St1)),
            ?assertEqual(1, meck:num_calls(couchbeam, save_doc, '_'))
        after
            pertisk_eproxy_test_helpers:unload_mocks([couchbeam])
        end
    end).

handle_cast_save_failure_schedules_retry_test() ->
    MockDb = connected_db,
    with_couchdb_env(#{enabled => true, url => <<"http://couchdb:5984">>}, fun() ->
        meck:new(couchbeam, [unstick]),
        meck:expect(couchbeam, server_connection, fun(_, _) -> server end),
        meck:expect(couchbeam, open_or_create_db, fun(_, _) -> {ok, MockDb} end),
        meck:expect(couchbeam, save_doc, fun(_, _) -> {error, timeout} end),
        try
            {ok, St, _} = pertisk_eproxy_couchdb_log:init([]),
            {noreply, St1} = pertisk_eproxy_couchdb_log:handle_continue(connect, St),
            {noreply, St2} = pertisk_eproxy_couchdb_log:handle_cast({log, #{<<"path">> => <<"/">>}}, St1),
            ?assertEqual(undefined, element(8, St2)),
            ?assert(is_reference(element(9, St2)))
        after
            pertisk_eproxy_test_helpers:unload_mocks([couchbeam])
        end
    end).

retry_connect_info_test() ->
    with_couchdb_env(#{enabled => true, url => <<"http://couchdb:5984">>}, fun() ->
        meck:new(couchbeam, [unstick]),
        meck:expect(couchbeam, server_connection, fun(_, _) -> server end),
        meck:expect(couchbeam, open_or_create_db, fun(_, _) -> {error, econnrefused} end),
        try
            {ok, St, _} = pertisk_eproxy_couchdb_log:init([]),
            {noreply, St1} = pertisk_eproxy_couchdb_log:handle_continue(connect, St),
            RetryRef = element(9, St1),
            ?assert(is_reference(RetryRef)),
            ?assertMatch({noreply, _},
                pertisk_eproxy_couchdb_log:handle_info({retry_connect, RetryRef}, St1)),
            ?assertMatch({noreply, _},
                pertisk_eproxy_couchdb_log:handle_info({retry_connect, make_ref()}, St1))
        after
            pertisk_eproxy_test_helpers:unload_mocks([couchbeam])
        end
    end).