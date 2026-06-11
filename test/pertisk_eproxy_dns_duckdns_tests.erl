-module(pertisk_eproxy_dns_duckdns_tests).

-include_lib("eunit/include/eunit.hrl").

with_httpc_mock(Fun) ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {Url, _Hdrs}, _Opts, _HttpOpts) ->
        duckdns_http(Url)
    end),
    try Fun() after meck:unload(httpc) end.

duckdns_http(Url) ->
    case binary:match(list_to_binary(Url), <<"duckdns.org/update">>) of
        nomatch ->
            {error, bad_url};
        _ ->
            case binary:match(list_to_binary(Url), <<"clear=true">>) of
                nomatch ->
                    {ok, {{'HTTP/1.1', 200, 'OK'}, [], <<"OK">>}};
                _ ->
                    {ok, {{'HTTP/1.1', 200, 'OK'}, [], <<"OK">>}}
            end
    end.

create_txt_ok_test() ->
    with_httpc_mock(fun() ->
        ?assertMatch({ok, {duckdns, <<"sub">>, <<"tok">>}},
            pertisk_eproxy_dns_duckdns:create_txt(<<"sub">>, <<"tok">>, <<"txt-val">>))
    end).

create_txt_http_error_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(_, _, _, _) ->
        {ok, {{'HTTP/1.1', 500, 'Error'}, [], <<"fail">>}}
    end),
    try
        ?assertMatch({error, {http, 500, _}},
            pertisk_eproxy_dns_duckdns:create_txt(<<"sub">>, <<"tok">>, <<"txt">>))
    after
        meck:unload(httpc)
    end.

create_txt_unexpected_body_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(_, _, _, _) ->
        {ok, {{'HTTP/1.1', 200, 'OK'}, [], <<"KO">>}}
    end),
    try
        ?assertMatch({error, {unexpected_response, _}},
            pertisk_eproxy_dns_duckdns:create_txt(<<"sub">>, <<"tok">>, <<"txt">>))
    after
        meck:unload(httpc)
    end.

create_txt_network_error_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(_, _, _, _) -> {error, timeout} end),
    try
        ?assertEqual({error, timeout},
            pertisk_eproxy_dns_duckdns:create_txt(<<"sub">>, <<"tok">>, <<"txt">>))
    after
        meck:unload(httpc)
    end.

delete_txt_ok_test() ->
    with_httpc_mock(fun() ->
        ?assertEqual(ok, pertisk_eproxy_dns_duckdns:delete_txt(<<"sub">>, <<"tok">>))
    end).

delete_txt_error_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(_, _, _, _) ->
        {ok, {{'HTTP/1.1', 403, 'Forbidden'}, [], <<"nope">>}}
    end),
    try
        ?assertMatch({error, {http, 403, _}},
            pertisk_eproxy_dns_duckdns:delete_txt(<<"sub">>, <<"tok">>))
    after
        meck:unload(httpc)
    end.
