-module(pertisk_eproxy_admin_realtime_tests).

-include_lib("eunit/include/eunit.hrl").

with_server(Fun) ->
    case whereis(pertisk_eproxy_admin_realtime) of
        undefined ->
            {ok, Pid} = pertisk_eproxy_admin_realtime:start_link(),
            try Fun(Pid) after pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000) end;
        Pid ->
            Fun(Pid)
    end.

ssl_job_without_server_is_ok_test() ->
    case whereis(pertisk_eproxy_admin_realtime) of
        undefined -> ok;
        Pid -> pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
    end,
    ?assertEqual(ok, pertisk_eproxy_admin_realtime:ssl_job(#{
        host => <<"example.com">>,
        phase => <<"starting">>,
        message => <<"test">>
    })),
    ?assertEqual([], pertisk_eproxy_admin_realtime:ssl_jobs_snapshot()).

subscribe_without_server_is_ok_test() ->
    case whereis(pertisk_eproxy_admin_realtime) of
        undefined -> ok;
        Pid -> pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
    end,
    ?assertEqual(ok, pertisk_eproxy_admin_realtime:subscribe(self())),
    ?assertEqual(ok, pertisk_eproxy_admin_realtime:unsubscribe(self())).

ssl_job_snapshot_and_clear_test() ->
    with_server(fun(_Pid) ->
        Host = <<"ssl-job.example">>,
        ?assertEqual(ok, pertisk_eproxy_admin_realtime:ssl_job(#{
            host => Host,
            phase => <<"dns_txt">>,
            message => <<"Published TXT">>,
            error => undefined
        })),
        [Row] = pertisk_eproxy_admin_realtime:ssl_jobs_snapshot(),
        ?assertEqual(Host, maps:get(<<"host">>, Row)),
        ?assertEqual(<<"dns_txt">>, maps:get(<<"phase">>, Row)),
        ?assertEqual(<<"Published TXT">>, maps:get(<<"message">>, Row)),
        ?assertEqual(ok, pertisk_eproxy_admin_realtime:clear_ssl_job(Host)),
        ?assertEqual([], pertisk_eproxy_admin_realtime:ssl_jobs_snapshot())
    end).

subscriber_receives_push_test() ->
    with_server(fun(Pid) ->
        ?assertEqual(ok, pertisk_eproxy_admin_realtime:subscribe(self())),
        ?assertEqual(ok, pertisk_eproxy_admin_realtime:ssl_job(#{
            host => <<"push.example">>,
            phase => <<"validation">>,
            message => <<"waiting">>
        })),
        receive
            {admin_ws_push, Json} ->
                {ok, Map} = thoas:decode(Json),
                ?assertEqual(<<"ssl_job">>, maps:get(<<"type">>, Map)),
                ?assertEqual(<<"push.example">>, maps:get(<<"host">>, Map))
        after 1000 ->
            ?assert(false)
        end,
        ?assertEqual(ok, pertisk_eproxy_admin_realtime:unsubscribe(self())),
        ?assertMatch({error, unknown_call}, gen_server:call(Pid, unknown, 1000))
    end).

ssl_job_with_error_field_test() ->
    with_server(fun(_Pid) ->
        ?assertEqual(ok, pertisk_eproxy_admin_realtime:ssl_job(#{
            host => <<"err.example">>,
            phase => <<"error">>,
            message => <<"failed">>,
            error => <<"dns timeout">>
        })),
        [Row] = pertisk_eproxy_admin_realtime:ssl_jobs_snapshot(),
        ?assertEqual(<<"dns timeout">>, maps:get(<<"error">>, Row))
    end).

gen_server_callbacks_test() ->
    ?assertEqual(ok, pertisk_eproxy_admin_realtime:terminate(normal, #{subs => #{}})),
    ?assertMatch({ok, #{x := 1}}, pertisk_eproxy_admin_realtime:code_change(1, #{x => 1}, extra)).

clear_ssl_job_without_server_test() ->
    case whereis(pertisk_eproxy_admin_realtime) of
        undefined -> ok;
        Pid -> pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
    end,
    ?assertEqual(ok, pertisk_eproxy_admin_realtime:clear_ssl_job(<<"gone.example">>)).

host_normalization_list_test() ->
    with_server(fun(_Pid) ->
        ?assertEqual(ok, pertisk_eproxy_admin_realtime:ssl_job(#{
            host => "list-host.example",
            phase => <<"complete">>,
            message => <<"done">>
        })),
        ?assertMatch(
            [#{<<"host">> := <<"list-host.example">>}],
            pertisk_eproxy_admin_realtime:ssl_jobs_snapshot()
        )
    end).
