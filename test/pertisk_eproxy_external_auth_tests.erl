-module(pertisk_eproxy_external_auth_tests).

-include_lib("eunit/include/eunit.hrl").

unload_mocks() ->
    pertisk_eproxy_test_helpers:unload_mocks([pertisk_eproxy_config, gun]).

with_auth_url(AuthUrl, Fun) ->
    unload_mocks(),
    meck:new(pertisk_eproxy_config, [unstick, no_link]),
    meck:expect(pertisk_eproxy_config, site_auth_url, fun(_) -> AuthUrl end),
    try
        Fun()
    after
        unload_mocks()
    end.

with_auth_and_gun(AuthUrl, GunSetup, Fun) ->
    unload_mocks(),
    meck:new(pertisk_eproxy_config, [unstick, no_link]),
    meck:expect(pertisk_eproxy_config, site_auth_url, fun(_) -> AuthUrl end),
    meck:new(gun, [unstick, no_link]),
    GunSetup(),
    try
        Fun()
    after
        unload_mocks()
    end.

mock_gun_success() ->
    fun() ->
        meck:expect(gun, open, fun(_Host, _Port, _Opts) -> {ok, conn} end),
        meck:expect(gun, await_up, fun(_Conn, _Timeout) -> {ok, http} end),
        meck:expect(gun, request, fun(_Conn, _Method, _Path, _Hdrs, _Body, _Opts) ->
            stream
        end),
        meck:expect(gun, await, fun(_Conn, _Stream, _Timeout) ->
            {response, fin, 200, #{}}
        end),
        meck:expect(gun, close, fun(_) -> ok end)
    end.

authorize_no_auth_url_test() ->
    with_auth_url(undefined, fun() ->
        ?assertEqual(
            ok,
            pertisk_eproxy_external_auth:authorize(
                <<"example.com">>, <<"GET">>, <<"/">>, <<>>, #{}, <<"127.0.0.1">>
            )
        )
    end).

authorize_success_test() ->
    with_auth_and_gun(
        <<"http://127.0.0.1:9191/auth">>,
        mock_gun_success(),
        fun() ->
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
        end
    ).

authorize_denied_test() ->
    with_auth_and_gun(
        <<"http://127.0.0.1:9191/auth">>,
        fun() ->
            meck:expect(gun, open, fun(_Host, _Port, _Opts) -> {ok, conn} end),
            meck:expect(gun, await_up, fun(_Conn, _Timeout) -> {ok, http} end),
            meck:expect(gun, request, fun(_, _, _, _, _, _) -> stream end),
            meck:expect(gun, await, fun(_, _, _) -> {response, fin, 403, #{}} end),
            meck:expect(gun, close, fun(_) -> ok end)
        end,
        fun() ->
            ?assertEqual(
                {error, {auth_denied, 403}},
                pertisk_eproxy_external_auth:authorize(
                    <<"example.com">>, <<"GET">>, <<"/">>, <<>>, #{}, <<"127.0.0.1">>
                )
            )
        end
    ).

authorize_nofin_success_test() ->
    with_auth_and_gun(
        <<"http://127.0.0.1:9191/auth">>,
        fun() ->
            meck:expect(gun, open, fun(_, _, _) -> {ok, conn} end),
            meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
            meck:expect(gun, request, fun(_, _, _, _, _, _) -> stream end),
            meck:expect(gun, await, fun(_, _, _) -> {response, nofin, 204, #{}} end),
            meck:expect(gun, await_body, fun(_, _, _) -> {ok, <<>>} end),
            meck:expect(gun, close, fun(_) -> ok end)
        end,
        fun() ->
            ?assertEqual(
                ok,
                pertisk_eproxy_external_auth:authorize(
                    <<"example.com">>, <<"GET">>, <<"/">>, <<>>, #{}, <<"127.0.0.1">>
                )
            )
        end
    ).

authorize_nofin_denied_test() ->
    with_auth_and_gun(
        <<"http://127.0.0.1:9191/auth">>,
        fun() ->
            meck:expect(gun, open, fun(_, _, _) -> {ok, conn} end),
            meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
            meck:expect(gun, request, fun(_, _, _, _, _, _) -> stream end),
            meck:expect(gun, await, fun(_, _, _) -> {response, nofin, 401, #{}} end),
            meck:expect(gun, await_body, fun(_, _, _) -> {ok, <<>>} end),
            meck:expect(gun, close, fun(_) -> ok end)
        end,
        fun() ->
            ?assertEqual(
                {error, {auth_denied, 401}},
                pertisk_eproxy_external_auth:authorize(
                    <<"example.com">>, <<"GET">>, <<"/">>, <<>>, #{}, <<"127.0.0.1">>
                )
            )
        end
    ).

authorize_unreachable_open_failure_test() ->
    with_auth_and_gun(
        <<"http://127.0.0.1:9191/auth">>,
        fun() ->
            meck:expect(gun, open, fun(_, _, _) -> {error, econnrefused} end)
        end,
        fun() ->
            ?assertEqual(
                {error, auth_unreachable},
                pertisk_eproxy_external_auth:authorize(
                    <<"example.com">>, <<"GET">>, <<"/">>, <<>>, #{}, <<"127.0.0.1">>
                )
            )
        end
    ).

authorize_invalid_url_test() ->
    with_auth_url(<<"not-a-url">>, fun() ->
        ?assertEqual(
            {error, auth_unreachable},
            pertisk_eproxy_external_auth:authorize(
                <<"example.com">>, <<"GET">>, <<"/">>, <<>>, #{}, <<"127.0.0.1">>
            )
        )
    end).

authorize_https_transport_test() ->
    with_auth_and_gun(
        <<"https://auth.example.com:443/verify">>,
        fun() ->
            meck:expect(gun, open, fun(Host, Port, Opts) ->
                ?assertEqual(<<"auth.example.com">>, Host),
                ?assertEqual(443, Port),
                ?assertEqual(tls, maps:get(transport, Opts)),
                {ok, conn}
            end),
            meck:expect(gun, await_up, fun(_Conn, _Timeout) -> {ok, http} end),
            meck:expect(gun, request, fun(_Conn, _Method, _Path, _Hdrs, _Body, _Opts) ->
                stream
            end),
            meck:expect(gun, await, fun(_Conn, _Stream, _Timeout) ->
                {response, fin, 200, #{}}
            end),
            meck:expect(gun, close, fun(_) -> ok end)
        end,
        fun() ->
            ?assertEqual(
                ok,
                pertisk_eproxy_external_auth:authorize(
                    <<"example.com">>, <<"GET">>, <<"/">>, <<>>, #{}, <<"127.0.0.1">>
                )
            )
        end
    ).

authorize_await_unexpected_test() ->
    with_auth_and_gun(
        <<"http://127.0.0.1:9191/auth">>,
        fun() ->
            meck:expect(gun, open, fun(_, _, _) -> {ok, conn} end),
            meck:expect(gun, await_up, fun(_, _) -> {error, timeout} end)
        end,
        fun() ->
            ?assertEqual(
                {error, auth_unreachable},
                pertisk_eproxy_external_auth:authorize(
                    <<"example.com">>, <<"GET">>, <<"/">>, <<>>, #{}, <<"127.0.0.1">>
                )
            )
        end
    ).
