-module(pertisk_eproxy_alt_svc_tests).

-include_lib("eunit/include/eunit.hrl").

ensure_config() ->
    pertisk_eproxy_test_helpers:ensure_config().

https_req(Extra) ->
    maps:merge(
        #{headers => #{}, scheme => https, path => <<"/">>, qs => <<>>, port => 443},
        Extra
    ).

header_value_contains_h3_port_test() ->
    ensure_config(),
    Val = pertisk_eproxy_alt_svc:header_value(),
    ?assertNotEqual(nomatch, binary:match(Val, <<"; ma=">>)).

header_value_custom_port_test() ->
    ensure_config(),
    Base = pertisk_eproxy_config:get_config(),
    ok = pertisk_eproxy_config:put_config(Base#{alt_svc_port => 8443}),
    Val = pertisk_eproxy_alt_svc:header_value(),
    ?assertNotEqual(nomatch, binary:match(Val, <<"8443">>)).

merge_skips_grpc_request_test() ->
    ensure_config(),
    Req = https_req(#{
        headers => #{<<"content-type">> => <<"application/grpc">>},
        path => <<"/">>
    }),
    Result = pertisk_eproxy_alt_svc:merge_response_headers(Req, <<"example.com">>, #{}),
    ?assertNot(maps:is_key(<<"alt-svc">>, Result)).

merge_skips_grpc_response_test() ->
    ensure_config(),
    Req = https_req(#{headers => #{}}),
    H = #{<<"content-type">> => <<"application/grpc">>},
    Result = pertisk_eproxy_alt_svc:merge_response_headers(Req, <<"example.com">>, H),
    ?assertNot(maps:is_key(<<"alt-svc">>, Result)).

merge_skips_grpc_web_test() ->
    ensure_config(),
    Req = https_req(#{
        headers => #{<<"content-type">> => <<"application/grpc-web+proto">>}
    }),
    ?assertNot(
        maps:is_key(
            <<"alt-svc">>,
            pertisk_eproxy_alt_svc:merge_response_headers(Req, <<"example.com">>, #{})
        )
    ).

merge_skips_connect_protocol_test() ->
    ensure_config(),
    Req = https_req(#{
        headers => #{<<"content-type">> => <<"application/connect+json">>}
    }),
    ?assertNot(
        maps:is_key(
            <<"alt-svc">>,
            pertisk_eproxy_alt_svc:merge_response_headers(Req, <<"example.com">>, #{})
        )
    ).

merge_skips_grpc_metadata_headers_test() ->
    ensure_config(),
    Req = https_req(#{
        headers => #{<<"grpc-metadata-foo">> => <<"bar">>}
    }),
    ?assertNot(
        maps:is_key(
            <<"alt-svc">>,
            pertisk_eproxy_alt_svc:merge_response_headers(Req, <<"example.com">>, #{})
        )
    ).

merge_skips_connect_rpc_headers_test() ->
    ensure_config(),
    Req = https_req(#{
        headers => #{<<"connect-protocol-version">> => <<"1">>}
    }),
    ?assertNot(
        maps:is_key(
            <<"alt-svc">>,
            pertisk_eproxy_alt_svc:merge_response_headers(Req, <<"example.com">>, #{})
        )
    ).

merge_skips_registry_traffic_test() ->
    ensure_config(),
    Req = https_req(#{
        headers => #{<<"accept">> => <<"application/vnd.docker.distribution.manifest.v2+json">>}
    }),
    ?assertNot(
        maps:is_key(
            <<"alt-svc">>,
            pertisk_eproxy_alt_svc:merge_response_headers(Req, <<"example.com">>, #{})
        )
    ).

merge_clears_console_page_test() ->
    ensure_config(),
    Req = https_req(#{path => <<"/shell">>}),
    Result = pertisk_eproxy_alt_svc:merge_response_headers(Req, <<"example.com">>, #{}),
    ?assertEqual(<<"clear">>, maps:get(<<"alt-svc">>, Result)).

merge_clears_console_query_test() ->
    ensure_config(),
    Req = https_req(#{qs => <<"console=1">>}),
    Result = pertisk_eproxy_alt_svc:merge_response_headers(Req, <<"example.com">>, #{}),
    ?assertEqual(<<"clear">>, maps:get(<<"alt-svc">>, Result)).

merge_https_via_forwarded_proto_test() ->
    ensure_config(),
    Req = #{
        headers => #{<<"x-forwarded-proto">> => <<"https">>},
        scheme => http,
        path => <<"/">>,
        qs => <<>>,
        port => 80
    },
    pertisk_eproxy_test_helpers:sync_router(
        [#{host => <<"example.com">>, backend => <<"b">>, routes => []}],
        []
    ),
    Result = pertisk_eproxy_alt_svc:merge_response_headers(Req, <<"example.com">>, #{}),
    ?assert(maps:is_key(<<"alt-svc">>, Result) orelse maps:get(<<"alt-svc">>, Result, undefined) =:= <<"clear">>).

header_value_persist_test() ->
    ensure_config(),
    Base = pertisk_eproxy_config:get_config(),
    try
        ok = pertisk_eproxy_config:put_config(Base#{alt_svc_persist => true}),
        Val = pertisk_eproxy_alt_svc:header_value(),
        ?assertNotEqual(nomatch, binary:match(Val, <<"persist=1">>))
    after
        _ = catch pertisk_eproxy_config:put_config(Base)
    end.

header_value_quic_port_fallback_test() ->
    ensure_config(),
    Base = pertisk_eproxy_config:get_config(),
    try
        ok =
            pertisk_eproxy_config:put_config(
                Base#{alt_svc_port => undefined, quic_port => 9443, https_port => 443}
            ),
        Val = pertisk_eproxy_alt_svc:header_value(),
        ?assertNotEqual(nomatch, binary:match(Val, <<"9443">>))
    after
        _ = catch pertisk_eproxy_config:put_config(Base)
    end.

merge_clears_novnc_path_test() ->
    ensure_config(),
    Req = https_req(#{path => <<"/novnc/vnc.html">>}),
    ?assertEqual(<<"clear">>, maps:get(<<"alt-svc">>, pertisk_eproxy_alt_svc:merge_response_headers(Req, <<"example.com">>, #{}))).

merge_skips_oci_response_content_type_test() ->
    ensure_config(),
    Req = https_req(#{headers => #{}}),
    Resp = #{<<"content-type">> => <<"application/vnd.oci.image.manifest.v1+json">>},
    ?assertNot(maps:is_key(<<"alt-svc">>, pertisk_eproxy_alt_svc:merge_response_headers(Req, <<"example.com">>, Resp))).

merge_skips_grpc_timeout_header_test() ->
    ensure_config(),
    Req = https_req(#{headers => #{<<"grpc-timeout">> => <<"1S">>}}),
    ?assertNot(maps:is_key(<<"alt-svc">>, pertisk_eproxy_alt_svc:merge_response_headers(Req, <<"example.com">>, #{}))).

merge_clears_when_http3_disabled_test() ->
    ensure_config(),
    Host = <<"noh3-alt.example">>,
    pertisk_eproxy_test_helpers:sync_router(
        [
            #{
                host => Host,
                backend => <<"b">>,
                routes => [],
                advertise_http3 => false
            }
        ],
        []
    ),
    Req = https_req(#{scheme => https, port => 443}),
    ?assertEqual(<<"clear">>, maps:get(<<"alt-svc">>, pertisk_eproxy_alt_svc:merge_response_headers(Req, Host, #{}))).

merge_http_not_https_test() ->
    ensure_config(),
    Req = #{
        headers => #{},
        scheme => http,
        path => <<"/">>,
        qs => <<>>,
        port => 8080
    },
    ?assertNot(maps:is_key(<<"alt-svc">>, pertisk_eproxy_alt_svc:merge_response_headers(Req, <<"example.com">>, #{}))).
