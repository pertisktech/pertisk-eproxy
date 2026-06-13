-module(pertisk_eproxy_external_auth_tests).

-include_lib("eunit/include/eunit.hrl").

unload_mocks() ->
    pertisk_eproxy_test_helpers:unload_mocks([pertisk_eproxy_config, gun]).

authorize_no_auth_url_test() ->
    unload_mocks(),
    pertisk_eproxy_test_helpers:ensure_config(),
    meck:new(pertisk_eproxy_config, [unstick, passthrough]),
    meck:expect(pertisk_eproxy_config, site_auth_url, fun(_) -> undefined end),
    try
        ?assertEqual(
            ok,
            pertisk_eproxy_external_auth:authorize(
                <<"example.com">>, <<"GET">>, <<"/">>, <<>>, #{}, <<"127.0.0.1">>
            )
        )
    after
        unload_mocks()
    end.

authorize_success_test() ->
    unload_mocks(),
    pertisk_eproxy_test_helpers:ensure_config(),
    meck:new(pertisk_eproxy_config, [unstick, passthrough]),
    meck:new(gun, [unstick]),
    meck:expect(pertisk_eproxy_config, site_auth_url, fun(_) ->
        <<"http://127.0.0.1:9191/auth">>
    end),
    meck:expect(gun, open, fun(_Host, _Port, _Opts) -> {ok, conn} end),
    meck:expect(gun, await_up, fun(_Conn, _Timeout) -> {ok, http} end),
    meck:expect(gun, request, fun(_Conn, _Method, _Path, _Hdrs, _Body, _Opts) ->
        {ok, stream}
    end),
    meck:expect(gun, await, fun(_Conn, _Stream, _Timeout) ->
        {response, fin, 200, #{}}
    end),
    meck:expect(gun, close, fun(_) -> ok end),
    try
        Hdrs = #{
            <<"cookie">> => <<"sid=1">>,
            <<"authorization">> => <<"Bearer x">>,
            <<"x-forwarded-proto">> => <<"https">>,
            <<"host">> => <<"example.com">>
        },
        ?assertEqual(
            ok,
            pertisk_eproxy_external_auth:authorize(
                <<"example.com">>, <<"GET">>, <<"/api">>, <<"q=1">>, Hdrs, <<"10.0.0.1">>
            )
        )
    after
        unload_mocks()
    end.

authorize_denied_test() ->
    unload_mocks(),
    pertisk_eproxy_test_helpers:ensure_config(),
    meck:new(pertisk_eproxy_config, [unstick, passthrough]),
    meck:new(gun, [unstick]),
    meck:expect(pertisk_eproxy_config, site_auth_url, fun(_) ->
        <<"http://127.0.0.1:9191/auth">>
    end),
    meck:expect(gun, open, fun(_Host, _Port, _Opts) -> {ok, conn} end),
    meck:expect(gun, await_up, fun(_Conn, _Timeout) -> {ok, http} end),
    meck:expect(gun, request, fun(_, _, _, _, _, _) -> {ok, stream} end),
    meck:expect(gun, await, fun(_, _, _) -> {response, fin, 403, #{}} end),
    meck:expect(gun, close, fun(_) -> ok end),
    try
        ?assertEqual(
            {error, {auth_denied, 403}},
            pertisk_eproxy_external_auth:authorize(
                <<"example.com">>, <<"GET">>, <<"/">>, <<>>, #{}, <<"127.0.0.1">>
            )
        )
    after
        unload_mocks()
    end.

authorize_nofin_success_test() ->
    unload_mocks(),
    pertisk_eproxy_test_helpers:ensure_config(),
    meck:new(pertisk_eproxy_config, [unstick, passthrough]),
    meck:new(gun, [unstick]),
    meck:expect(pertisk_eproxy_config, site_auth_url, fun(_) ->
        <<"http://127.0.0.1:9191/auth">>
    end),
    meck:expect(gun, open, fun(_, _, _) -> {ok, conn} end),
    meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
    meck:expect(gun, request, fun(_, _, _, _, _, _) -> {ok, stream} end),
    meck:expect(gun, await, fun(_, _, _) -> {response, nofin, 204, #{}} end),
    meck:expect(gun, await_body, fun(_, _, _) -> {ok, <<>>} end),
    meck:expect(gun, close, fun(_) -> ok end),
    try
        ?assertEqual(
            ok,
            pertisk_eproxy_external_auth:authorize(
                <<"example.com">>, <<"GET">>, <<"/">>, <<>>, #{}, <<"127.0.0.1">>
            )
        )
    after
        unload_mocks()
    end.

authorize_nofin_denied_test() ->
    unload_mocks(),
    pertisk_eproxy_test_helpers:ensure_config(),
    meck:new(pertisk_eproxy_config, [unstick, passthrough]),
    meck:new(gun, [unstick]),
    meck:expect(pertisk_eproxy_config, site_auth_url, fun(_) ->
        <<"http://127.0.0.1:9191/auth">>
    end),
    meck:expect(gun, open, fun(_, _, _) -> {ok, conn} end),
    meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
    meck:expect(gun, request, fun(_, _, _, _, _, _) -> {ok, stream} end),
    meck:expect(gun, await, fun(_, _, _) -> {response, nofin, 401, #{}} end),
    meck:expect(gun, await_body, fun(_, _, _) -> {ok, <<>>} end),
    meck:expect(gun, close, fun(_) -> ok end),
    try
        ?assertEqual(
            {error, {auth_denied, 401}},
            pertisk_eproxy_external_auth:authorize(
                <<"example.com">>, <<"GET">>, <<"/">>, <<>>, #{}, <<"127.0.0.1">>
            )
        )
    after
        unload_mocks()
    end.

authorize_unreachable_open_failure_test() ->
    unload_mocks(),
    pertisk_eproxy_test_helpers:ensure_config(),
    meck:new(pertisk_eproxy_config, [unstick, passthrough]),
    meck:new(gun, [unstick]),
    meck:expect(pertisk_eproxy_config, site_auth_url, fun(_) ->
        <<"http://127.0.0.1:9191/auth">>
    end),
    meck:expect(gun, open, fun(_, _, _) -> {error, econnrefused} end),
    try
        ?assertEqual(
            {error, auth_unreachable},
            pertisk_eproxy_external_auth:authorize(
                <<"example.com">>, <<"GET">>, <<"/">>, <<>>, #{}, <<"127.0.0.1">>
            )
        )
    after
        unload_mocks()
    end.

authorize_invalid_url_test() ->
    unload_mocks(),
    pertisk_eproxy_test_helpers:ensure_config(),
    meck:new(pertisk_eproxy_config, [unstick, passthrough]),
    meck:expect(pertisk_eproxy_config, site_auth_url, fun(_) -> <<"not-a-url">> end),
    try
        ?assertEqual(
            {error, auth_unreachable},
            pertisk_eproxy_external_auth:authorize(
                <<"example.com">>, <<"GET">>, <<"/">>, <<>>, #{}, <<"127.0.0.1">>
            )
        )
    after
        unload_mocks()
    end.

authorize_https_transport_test() ->
    unload_mocks(),
    pertisk_eproxy_test_helpers:ensure_config(),
    meck:new(pertisk_eproxy_config, [unstick, passthrough]),
    meck:new(gun, [unstick]),
    meck:expect(pertisk_eproxy_config, site_auth_url, fun(_) ->
        <<"https://auth.example.com:443/verify">>
    end),
    meck:expect(gun, open, fun(Host, Port, Opts) ->
        ?assertEqual(<<"auth.example.com">>, Host),
        ?assertEqual(443, Port),
        ?assertEqual(tls, maps:get(transport, Opts)),
        {ok, conn}
    end),
    meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
    meck:expect(gun, request, fun(_, _, _, _, _, _) -> {ok, stream} end),
    meck:expect(gun, await, fun(_, _, _) -> {response, fin, 200, #{}} end),
    meck:expect(gun, close, fun(_) -> ok end),
    try
        ?assertEqual(
            ok,
            pertisk_eproxy_external_auth:authorize(
                <<"example.com">>, <<"GET">>, <<"/">>, <<>>, #{}, <<"127.0.0.1">>
            )
        )
    after
        unload_mocks()
    end.

authorize_await_unexpected_test() ->
    unload_mocks(),
    pertisk_eproxy_test_helpers:ensure_config(),
    meck:new(pertisk_eproxy_config, [unstick, passthrough]),
    meck:new(gun, [unstick]),
    meck:expect(pertisk_eproxy_config, site_auth_url, fun(_) ->
        <<"http://127.0.0.1:9191/auth">>
    end),
    meck:expect(gun, open, fun(_, _, _) -> {ok, conn} end),
    meck:expect(gun, await_up, fun(_, _) -> {error, timeout} end),
    try
        ?assertEqual(
            {error, auth_unreachable},
            pertisk_eproxy_external_auth:authorize(
                <<"example.com">>, <<"GET">>, <<"/">>, <<>>, #{}, <<"127.0.0.1">>
            )
        )
    after
        unload_mocks()
    end.
