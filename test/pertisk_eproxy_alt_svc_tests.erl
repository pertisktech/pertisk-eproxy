-module(pertisk_eproxy_alt_svc_tests).

-include_lib("eunit/include/eunit.hrl").

ensure_config() ->
    application:ensure_all_started(lager),
    case whereis(pertisk_eproxy_config) of
        undefined -> {ok, _} = pertisk_eproxy_config:start_link();
        _ -> ok
    end.

header_value_contains_h3_port_test() ->
    ensure_config(),
    Val = pertisk_eproxy_alt_svc:header_value(),
    ?assertNotEqual(nomatch, binary:match(Val, <<"h3=\"">>)).

merge_skips_grpc_response_test() ->
    ensure_config(),
    Req = #{
        headers => #{<<"content-type">> => <<"application/grpc">>},
        scheme => https,
        path => <<"/">>,
        qs => <<>>
    },
    H = #{<<"content-type">> => <<"application/grpc">>},
    Result = pertisk_eproxy_alt_svc:merge_response_headers(Req, <<"example.com">>, H),
    ?assertNot(maps:is_key(<<"alt-svc">>, Result)).

merge_clears_console_page_test() ->
    ensure_config(),
    Req = #{headers => #{}, scheme => https, path => <<"/shell">>, qs => <<>>},
    Result = pertisk_eproxy_alt_svc:merge_response_headers(Req, <<"example.com">>, #{}),
    ?assertEqual(<<"clear">>, maps:get(<<"alt-svc">>, Result)).
