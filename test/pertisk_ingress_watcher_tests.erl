-module(pertisk_ingress_watcher_tests).

-include_lib("eunit/include/eunit.hrl").

wait_down(_Pid, 0) ->
    ok;
wait_down(Pid, N) ->
    case is_process_alive(Pid) of
        false -> ok;
        true -> timer:sleep(50), wait_down(Pid, N - 1)
    end.

ensure_mocks_clean() ->
    pertisk_eproxy_test_helpers:unload_mocks([
        ekub, pertisk_ingress_ekub, ekub_api, ekub_core, pertisk_ingress_env,
        pertisk_ingress_watcher
    ]).

stop_watcher() ->
    case whereis(pertisk_ingress_watcher) of
        undefined -> ok;
        Pid ->
            pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000),
            wait_down(Pid, 20)
    end,
    ensure_mocks_clean().

with_watcher_env(Expects, Fun) ->
    pertisk_eproxy_test_helpers:ensure_metrics(),
    meck:new(pertisk_ingress_env, [unstick, passthrough]),
    maps:fold(
        fun(K, V, _) -> meck:expect(pertisk_ingress_env, K, fun() -> V end) end,
        ok,
        maps:merge(#{
            namespace => <<"default">>,
            reconcile_interval_ms => 999999,
            watch_backoff_ms => 10
        }, Expects)
    ),
    try Fun() after
        stop_watcher(),
        pertisk_eproxy_test_helpers:unload_mocks([pertisk_ingress_env])
    end.

ensure_tls() ->
    case whereis(pertisk_ingress_tls) of
        undefined -> {ok, _} = pertisk_ingress_tls:start_link();
        _ -> ok
    end.

sample_ingress() ->
    #{
        <<"metadata">> => #{<<"name">> => <<"w">>, <<"namespace">> => <<"default">>},
        <<"spec">> => #{
            <<"ingressClassName">> => <<"pertisk-eproxy">>,
            <<"rules">> => []
        }
    }.

tls_secret() ->
    CertPath = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
    KeyPath = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
    {ok, CertPem} = file:read_file(CertPath),
    {ok, KeyPem} = file:read_file(KeyPath),
    #{
        <<"type">> => <<"kubernetes.io/tls">>,
        <<"metadata">> => #{<<"name">> => <<"tls">>, <<"namespace">> => <<"default">>},
        <<"data">> => #{
            <<"tls.crt">> => base64:encode(CertPem),
            <<"tls.key">> => base64:encode(KeyPem)
        }
    }.

reconcile_now_when_not_running_test() ->
    stop_watcher(),
    ?assertEqual(ok, pertisk_ingress_watcher:reconcile_now()).

watcher_init_ekub_failure_test() ->
    stop_watcher(),
    ensure_mocks_clean(),
    ensure_tls(),
    ok = pertisk_ingress_status:init(),
    with_watcher_env(#{}, fun() ->
        meck:new(pertisk_ingress_ekub, [unstick]),
        meck:expect(pertisk_ingress_ekub, init, fun() -> {error, denied} end),
        {ok, Pid} = pertisk_ingress_watcher:start_link(),
        timer:sleep(20),
        ?assertEqual(<<"error">>, maps:get(<<"watcher">>, pertisk_ingress_status:snapshot())),
        ok = gen_server:stop(Pid),
        wait_down(Pid, 20)
    end).

watcher_all_namespaces_test() ->
    stop_watcher(),
    ensure_mocks_clean(),
    ensure_tls(),
    ok = pertisk_ingress_status:init(),
    pertisk_eproxy_test_helpers:ensure_config(),
    Conn = {mock_api, #{}},
    with_watcher_env(#{namespace => all_namespaces}, fun() ->
        meck:new(pertisk_ingress_ekub, [unstick]),
        meck:expect(pertisk_ingress_ekub, init, fun() -> {ok, Conn} end),
        meck:new(ekub_api, [unstick]),
        meck:expect(ekub_api, endpoint, fun(_, _, _, _, _, _) -> <<"/api/ingresses">> end),
        meck:new(ekub_core, [unstick]),
        meck:expect(ekub_core, http_request, fun(_, _, _) ->
            {ok, #{<<"items">> => [sample_ingress()]}}
        end),
        meck:new(ekub, [unstick]),
        meck:expect(ekub, watch, fun(_, _, _) -> {error, refused} end),
        meck:expect(ekub, patch, fun(_, _, _, _, _) -> {ok, #{}} end),
        {ok, Pid} = pertisk_ingress_watcher:start_link(),
        ?assertEqual(ok, pertisk_ingress_watcher:reconcile_now()),
        ok = gen_server:stop(Pid),
        wait_down(Pid, 20)
    end).

watcher_lifecycle_test() ->
    stop_watcher(),
    ensure_mocks_clean(),
    ensure_tls(),
    ok = pertisk_ingress_status:init(),
    pertisk_eproxy_test_helpers:ensure_config(),
    Ingress = sample_ingress(),
    WatchRef = make_ref(),
    with_watcher_env(#{}, fun() ->
        Conn = {mock_api, mock_access},
        meck:new(pertisk_ingress_ekub, [unstick]),
        meck:expect(pertisk_ingress_ekub, init, fun() -> {ok, Conn} end),
        meck:new(ekub, [unstick]),
        meck:expect(ekub, read, fun
            (ingress, _, _) -> {ok, #{<<"items">> => [Ingress]}};
            (secret, _, _) -> {ok, #{<<"items">> => [tls_secret(), #{<<"type">> => <<"Opaque">>}]}};
            (_, _, _) -> {error, denied}
        end),
        meck:expect(ekub, watch, fun(_, _, _) -> {ok, WatchRef} end),
        meck:expect(ekub, watch, fun
            (Ref) when Ref =:= WatchRef ->
                {ok, [#{<<"type">> => <<"MODIFIED">>, <<"object">> => Ingress}]}
        end),
        meck:expect(ekub, watch_close, fun(_) -> ok end),
        meck:expect(ekub, patch, fun(_, _, _, _, _) -> {ok, #{}} end),
        {ok, Pid} = pertisk_ingress_watcher:start_link(),
        ?assertEqual(ok, pertisk_ingress_watcher:reconcile_now()),
        pertisk_ingress_watcher:trigger_reconcile(),
        Pid ! start_watch,
        timer:sleep(30),
        Pid ! watch_poll,
        timer:sleep(30),
        meck:expect(ekub, watch, fun(Ref) when Ref =:= WatchRef -> {ok, []} end),
        Pid ! watch_poll,
        timer:sleep(20),
        meck:expect(ekub, watch, fun(Ref) when Ref =:= WatchRef -> {error, timeout} end),
        Pid ! watch_poll,
        timer:sleep(20),
        meck:expect(ekub, watch, fun(Ref) when Ref =:= WatchRef -> {error, req_not_found} end),
        Pid ! watch_poll,
        timer:sleep(30),
        Pid ! start_watch,
        timer:sleep(20),
        meck:expect(ekub, watch, fun(_, _, _) -> {ok, WatchRef} end),
        meck:expect(ekub, watch, fun(Ref) when Ref =:= WatchRef -> {error, closed} end),
        Pid ! watch_poll,
        timer:sleep(30),
        Pid ! start_watch,
        timer:sleep(20),
        meck:expect(ekub, watch, fun(_, _, _) -> {ok, WatchRef} end),
        meck:expect(ekub, watch, fun(Ref) when Ref =:= WatchRef -> {ok, done} end),
        Pid ! watch_poll,
        timer:sleep(30),
        Pid ! periodic_reconcile,
        timer:sleep(30),
        State = sys:get_state(Pid),
        sys:replace_state(Pid, fun(_) -> State#{conn => undefined} end),
        Pid ! reconcile_now,
        timer:sleep(50),
        ?assertEqual({error, unknown}, gen_server:call(Pid, unknown, 1000)),
        ok = gen_server:stop(Pid),
        wait_down(Pid, 20)
    end).

watcher_unknown_callbacks_test() ->
    State = #{conn => mock_conn},
    ?assertEqual({noreply, State}, pertisk_ingress_watcher:handle_cast(unknown, State)),
    ?assertEqual({noreply, State}, pertisk_ingress_watcher:handle_info(unknown, State)),
    ?assertEqual(ok, pertisk_ingress_watcher:terminate(normal, State)).

watcher_start_watch_failure_backoff_test() ->
    stop_watcher(),
    ensure_mocks_clean(),
    ensure_tls(),
    ok = pertisk_ingress_status:init(),
    with_watcher_env(#{watch_backoff_ms => 5}, fun() ->
        meck:new(pertisk_ingress_ekub, [unstick]),
        meck:expect(pertisk_ingress_ekub, init, fun() -> {ok, mock_conn} end),
        meck:new(ekub, [unstick]),
        meck:expect(ekub, read, fun
            (ingress, _, _) -> {ok, #{<<"items">> => []}};
            (secret, _, _) -> {ok, #{<<"items">> => []}};
            (_, _, _) -> {error, denied}
        end),
        meck:expect(ekub, watch, fun(ingress, _, _) -> {error, refused} end),
        meck:expect(ekub, patch, fun(_, _, _, _, _) -> {ok, #{}} end),
        {ok, Pid} = pertisk_ingress_watcher:start_link(),
        timer:sleep(30),
        ?assertEqual(<<"error">>, maps:get(<<"watcher">>, pertisk_ingress_status:snapshot())),
        ok = gen_server:stop(Pid),
        wait_down(Pid, 20)
    end).

watcher_gateway_api_merge_success_test() ->
    stop_watcher(),
    ensure_mocks_clean(),
    ensure_tls(),
    ok = pertisk_ingress_status:init(),
    pertisk_eproxy_test_helpers:ensure_config(),
    Ingress = sample_ingress(),
    with_watcher_env(#{gateway_api_enabled => true}, fun() ->
        Conn = {mock_api, mock_access},
        meck:new(pertisk_ingress_ekub, [unstick]),
        meck:expect(pertisk_ingress_ekub, init, fun() -> {ok, Conn} end),
        meck:new(ekub, [unstick]),
        meck:expect(ekub, read, fun
            (ingress, _, _) -> {ok, #{<<"items">> => [Ingress]}};
            (secret, _, _) -> {ok, #{<<"items">> => [tls_secret()]}};
            (_, _, _) -> {error, denied}
        end),
        meck:expect(ekub, patch, fun(_, _, _, _, _) -> {ok, #{}} end),
        meck:expect(ekub, watch, fun(_, _, _) -> {error, refused} end),
        meck:new(ekub_api, [unstick]),
        meck:expect(ekub_api, endpoint, fun
            (<<"gateway.networking.k8s.io">>, <<"v1">>, <<"httproutes">>, <<>>, <<>>, <<>>) ->
                <<"/apis/gateway.networking.k8s.io/v1/httproutes">>;
            (<<"gateway.networking.k8s.io">>, <<"v1">>, <<"gateways">>, <<>>, <<>>, <<>>) ->
                <<"/apis/gateway.networking.k8s.io/v1/gateways">>;
            (_, _, _, _, _, _) ->
                <<>>
        end),
        meck:new(ekub_core, [unstick]),
        meck:expect(ekub_core, http_request, fun
            (<<"/apis/gateway.networking.k8s.io/v1/httproutes">>, _, _) ->
                {ok, #{<<"items">> => []}};
            (<<"/apis/gateway.networking.k8s.io/v1/gateways">>, _, _) ->
                {ok, #{<<"items">> => []}};
            (_, _, _) ->
                {error, not_used}
        end),
        meck:new(pertisk_gateway_reconciler, [unstick]),
        meck:expect(pertisk_gateway_reconciler, reconcile, fun(_, _, _) ->
            {ok, #{sites => [], backends => [], tls => []}}
        end),
        meck:expect(pertisk_gateway_reconciler, merge_results, fun(IngressResult, GatewayResult) ->
            maps:merge(IngressResult, GatewayResult)
        end),
        meck:new(pertisk_gateway_class_status, [unstick, no_link]),
        meck:expect(pertisk_gateway_class_status, maybe_update, fun(_) -> ok end),
        meck:new(pertisk_gateway_status, [unstick, no_link]),
        meck:expect(pertisk_gateway_status, maybe_update, fun(_) -> ok end),
        meck:new(pertisk_ingress_status_patcher, [unstick, no_link]),
        meck:expect(pertisk_ingress_status_patcher, maybe_update, fun(_, _) -> ok end),
        try
            {ok, Pid} = pertisk_ingress_watcher:start_link(),
            timer:sleep(50),
            ?assertEqual(ok, pertisk_ingress_watcher:reconcile_now()),
            ?assert(meck:num_calls(pertisk_gateway_reconciler, merge_results, '_') >= 1),
            ok = gen_server:stop(Pid),
            wait_down(Pid, 20)
        after
            stop_watcher(),
            pertisk_eproxy_test_helpers:unload_mocks([
                pertisk_gateway_reconciler,
                pertisk_gateway_class_status,
                pertisk_gateway_status,
                pertisk_ingress_status_patcher
            ])
        end
    end).

watcher_apply_reconcile_failure_test() ->
    stop_watcher(),
    ensure_mocks_clean(),
    ensure_tls(),
    ok = pertisk_ingress_status:init(),
    pertisk_eproxy_test_helpers:ensure_config(),
    with_watcher_env(#{}, fun() ->
        Conn = {mock_api, mock_access},
        meck:new(pertisk_ingress_ekub, [unstick]),
        meck:expect(pertisk_ingress_ekub, init, fun() -> {ok, Conn} end),
        meck:new(ekub, [unstick]),
        meck:expect(ekub, read, fun
            (ingress, _, _) -> {ok, #{<<"items">> => [sample_ingress()]}};
            (secret, _, _) -> {ok, #{<<"items">> => [tls_secret()]}};
            (_, _, _) -> {error, denied}
        end),
        meck:expect(ekub, patch, fun(_, _, _, _, _) -> {ok, #{}} end),
        meck:expect(ekub, watch, fun(_, _, _) -> {error, refused} end),
        meck:new(pertisk_ingress_config_sync, [unstick]),
        meck:expect(pertisk_ingress_config_sync, apply_reconcile_result, fun(_) ->
            {error, apply_failed}
        end),
        meck:new(pertisk_ingress_reconciler, [unstick]),
        meck:expect(pertisk_ingress_reconciler, reconcile, fun(_, _) ->
            {ok, #{sites => [], backends => [], tls => []}}
        end),
        Tab = ets:new(watcher_reconcile_tab, [public]),
        meck:new(pertisk_ingress_metrics, [unstick, no_link]),
        meck:expect(pertisk_ingress_metrics, record_reconcile, fun(Err, _) ->
            ets:insert(Tab, {err, Err}),
            ok
        end),
        try
            {ok, Pid} = pertisk_ingress_watcher:start_link(),
            timer:sleep(50),
            ?assertEqual(ok, pertisk_ingress_watcher:reconcile_now()),
            ?assertEqual({error, apply_failed}, ets:lookup_element(Tab, err, 2)),
            ok = gen_server:stop(Pid),
            wait_down(Pid, 20)
        after
            catch ets:delete(Tab),
            stop_watcher(),
            pertisk_eproxy_test_helpers:unload_mocks([
                pertisk_ingress_config_sync, pertisk_ingress_metrics, pertisk_ingress_reconciler
            ])
        end
    end).

watcher_list_ingress_failure_test() ->
    stop_watcher(),
    ensure_mocks_clean(),
    ensure_tls(),
    ok = pertisk_ingress_status:init(),
    pertisk_eproxy_test_helpers:ensure_config(),
    with_watcher_env(#{}, fun() ->
        Conn = {mock_api, mock_access},
        meck:new(pertisk_ingress_ekub, [unstick]),
        meck:expect(pertisk_ingress_ekub, init, fun() -> {ok, Conn} end),
        meck:new(ekub, [unstick]),
        meck:expect(ekub, read, fun
            (ingress, _, _) -> {error, #{<<"code">> => 503}};
            (_, _, _) -> {error, denied}
        end),
        meck:expect(ekub, watch, fun(_, _, _) -> {error, refused} end),
        try
            {ok, Pid} = pertisk_ingress_watcher:start_link(),
            timer:sleep(50),
            ?assertEqual(ok, pertisk_ingress_watcher:reconcile_now()),
            ?assert(meck:num_calls(ekub, read, '_') >= 1),
            ok = gen_server:stop(Pid),
            wait_down(Pid, 20)
        after
            stop_watcher(),
            pertisk_eproxy_test_helpers:unload_mocks([])
        end
    end).

reconcile_recorded_error(Mod, Reason) ->
    lists:any(
        fun(Entry) ->
            case Entry of
                {call, _, Mod, record_reconcile, [{error, Reason}, _]} -> true;
                {call, _, Mod, record_reconcile, [{error, Reason}, _], _} -> true;
                _ -> false
            end
        end,
        meck:history(Mod)
    ).

reconcile_recorded_list_ingress_error(Mod) ->
    lists:any(
        fun(Entry) ->
            case Entry of
                {call, _, Mod, record_reconcile, [{error, {list_ingress, _}}, _]} -> true;
                {call, _, Mod, record_reconcile, [{error, {list_ingress, _}}, _], _} -> true;
                _ -> false
            end
        end,
        meck:history(Mod)
    ).
