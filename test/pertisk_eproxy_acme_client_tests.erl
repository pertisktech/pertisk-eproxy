-module(pertisk_eproxy_acme_client_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ACME_BASE, <<"http://acme.test">>).

base_opts(Extra) ->
    Jwk = jose_jwk:generate_key({ec, <<"P-256">>}),
    {ok, #{csr_der := CsrDer}} = pertisk_eproxy_acme_csr:generate_rsa_csr([<<"example.com">>]),
    maps:merge(
        #{
            directory_url => <<(?ACME_BASE)/binary, "/directory">>,
            account_jwk => Jwk,
            account_kid => undefined,
            contact_email => <<"ops@example.com">>,
            terms_agreed => true,
            identifiers => [<<"example.com">>],
            csr_der => CsrDer,
            dns_add => fun(_, _) -> {ok, opaque} end,
            dns_del => fun(_) -> ok end
        },
        Extra
    ).

http_ok(Nonce, Body) ->
    {ok, {{'HTTP/1.1', 200, 'OK'}, [{"replay-nonce", Nonce}], Body}}.

with_httpc_mock(Fun) ->
    put(acme_finalized, false),
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        acme_http(Method, Req, Opts, HttpOpts)
    end),
    try Fun() after pertisk_eproxy_test_helpers:unload_mocks([httpc]) end.

acme_url(Suffix) when is_binary(Suffix) ->
    <<(?ACME_BASE)/binary, Suffix/binary>>.

acme_path_suffix(UrlB) ->
    Base = ?ACME_BASE,
    BaseSize = byte_size(Base),
    case UrlB of
        <<Base:BaseSize/binary, Rest/binary>> -> Rest;
        _ -> nomatch
    end.

acme_http(head, {Url, Hdrs}, Opts, HttpOpts) ->
    case url_is_acme(Url) of
        false -> meck:passthrough([httpc, request, [head, {Url, Hdrs}, Opts, HttpOpts]]);
        true -> http_ok("nonce-1", <<>>)
    end;
acme_http(get, {Url, Hdrs}, Opts, HttpOpts) ->
    UrlB = list_to_binary(Url),
    case acme_path_suffix(UrlB) of
        <<"/directory">> ->
            Dir = #{
                <<"newNonce">> => <<(?ACME_BASE)/binary, "/nonce">>,
                <<"newAccount">> => <<(?ACME_BASE)/binary, "/account">>,
                <<"newOrder">> => <<(?ACME_BASE)/binary, "/order">>
            },
            http_ok("nonce-0", thoas:encode(Dir));
        _ ->
            meck:passthrough([httpc, request, [get, {Url, Hdrs}, Opts, HttpOpts]])
    end;
acme_http(post, {Url, Hdrs, Ct, Body}, Opts, HttpOpts) ->
    UrlB = list_to_binary(Url),
    case acme_path_suffix(UrlB) of
        <<"/account">> ->
            Loc = binary_to_list(<<(?ACME_BASE)/binary, "/account/1">>),
            {ok, {{'HTTP/1.1', 201, 'Created'}, [{"location", Loc}, {"replay-nonce", "nonce-2"}], <<"{}" >>}};
        <<"/order">> ->
            Resp = #{
                <<"authorizations">> => [<<(?ACME_BASE)/binary, "/authz/1">>],
                <<"finalize">> => <<(?ACME_BASE)/binary, "/finalize">>,
                <<"status">> => <<"pending">>
            },
            Loc = binary_to_list(<<(?ACME_BASE)/binary, "/order/1">>),
            {ok, {{'HTTP/1.1', 201, 'Created'}, [{"location", Loc}, {"replay-nonce", "nonce-3"}], thoas:encode(Resp)}};
        <<"/authz/1">> ->
            Auth = #{
                <<"identifier">> => #{<<"type">> => <<"dns">>, <<"value">> => <<"example.com">>},
                <<"challenges">> => [
                    #{
                        <<"type">> => <<"dns-01">>,
                        <<"token">> => <<"tok">>,
                        <<"url">> => <<(?ACME_BASE)/binary, "/challenge/1">>
                    }
                ]
            },
            http_ok("nonce-4", thoas:encode(Auth));
        <<"/challenge/1">> ->
            http_ok("nonce-5", <<"{}" >>);
        <<"/order/1">> ->
            case get(acme_finalized) of
                true ->
                    Resp = #{
                        <<"status">> => <<"valid">>,
                        <<"certificate">> => <<(?ACME_BASE)/binary, "/cert/1">>
                    },
                    http_ok("nonce-8", thoas:encode(Resp));
                _ ->
                    http_ok("nonce-6", thoas:encode(#{<<"status">> => <<"ready">>}))
            end;
        <<"/finalize">> ->
            put(acme_finalized, true),
            http_ok("nonce-9", thoas:encode(#{<<"status">> => <<"processing">>}));
        <<"/cert/1">> ->
            Pem = <<"-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----">>,
            http_ok("nonce-10", Pem);
        _ ->
            {ok, {{'HTTP/1.1', 400, 'Bad Request'}, [], <<"{\"type\":\"urn:ietf:params:acme:error:badNonce\"}">>}}
    end;
acme_http(Method, Req, Opts, HttpOpts) ->
    meck:passthrough([httpc, request, [Method, Req, Opts, HttpOpts]]).

url_is_acme(Url) ->
    binary:match(list_to_binary(Url), <<"acme.test">>) =/= nomatch.

obtain_certificate_invalid_directory_test() ->
    Opts = base_opts(#{directory_url => <<"http://127.0.0.1:1/directory">>}),
    ?assertMatch({error, _}, pertisk_eproxy_acme_client:obtain_certificate(Opts)).

obtain_certificate_dns_add_failure_test() ->
    Opts = base_opts(#{
        dns_add => fun(_, _) -> {error, denied} end,
        dns_propagation_delay_ms => 0
    }),
    with_httpc_mock(fun() ->
        ?assertMatch({error, {dns_add, denied}}, pertisk_eproxy_acme_client:obtain_certificate(Opts))
    end).

obtain_certificate_happy_path_test() ->
    Opts = base_opts(#{
        account_kid => <<"https://acme.test/account/existing">>,
        dns_propagation_delay_ms => 1,
        progress => fun(Phase, Msg) ->
            self() ! {acme_progress, Phase, Msg}
        end
    }),
    with_httpc_mock(fun() ->
        {ok, Pem, Kid} = pertisk_eproxy_acme_client:obtain_certificate(Opts),
        ?assert(is_binary(Pem)),
        ?assert(byte_size(Pem) > 0),
        ?assertEqual(<<"https://acme.test/account/existing">>, Kid),
        receive
            {acme_progress, <<"directory">>, _} -> ok
        after 1000 ->
            ?assert(false)
        end
    end).

obtain_certificate_new_account_happy_path_test() ->
    Opts = base_opts(#{dns_propagation_delay_ms => 0}),
    with_httpc_mock(fun() ->
        {ok, _Pem, Kid} = pertisk_eproxy_acme_client:obtain_certificate(Opts),
        ?assert(is_binary(Kid))
    end).

obtain_certificate_order_invalid_test() ->
    Opts = base_opts(#{dns_propagation_delay_ms => 0, account_kid => <<"https://acme.test/account/existing">>}),
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts2, HttpOpts) ->
        case Method of
            post ->
                UrlB = list_to_binary(element(1, Req)),
                case acme_path_suffix(UrlB) of
                    <<"/order/1">> ->
                        Resp = #{
                            <<"status">> => <<"invalid">>,
                            <<"authorizations">> => [<<(?ACME_BASE)/binary, "/authz/1">>]
                        },
                        http_ok("nonce-x", thoas:encode(Resp));
                    _ ->
                        acme_http(Method, Req, Opts2, HttpOpts)
                end;
            _ ->
                acme_http(Method, Req, Opts2, HttpOpts)
        end
    end),
    try
        put(acme_finalized, false),
        ?assertMatch({error, {order_invalid, _, _}}, pertisk_eproxy_acme_client:obtain_certificate(Opts))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

obtain_certificate_bad_nonce_retry_test() ->
    meck:new(httpc, [unstick, passthrough]),
    Calls = counters:new(1, []),
    meck:expect(httpc, request, fun
        (head, {Url, Hdrs}, O, H) ->
            acme_http(head, {Url, Hdrs}, O, H);
        (get, {Url, Hdrs}, O, H) ->
            acme_http(get, {Url, Hdrs}, O, H);
        (post, {Url, Hdrs, Ct, Body}, O, H) ->
            UrlB = list_to_binary(Url),
            case binary:match(UrlB, <<"/account">>) of
                nomatch ->
                    acme_http(post, {Url, Hdrs, Ct, Body}, O, H);
                _ ->
                    N = counters:get(Calls, 1),
                    counters:add(Calls, 1, 1),
                    case N of
                        0 ->
                            {ok, {{'HTTP/1.1', 400, 'Bad Request'}, [{"replay-nonce", "nonce-retry"}], <<"{\"type\":\"badNonce\"}">>}};
                        _ ->
                            acme_http(post, {Url, Hdrs, Ct, Body}, O, H)
                    end
            end
    end),
    try
        put(acme_finalized, false),
        Opts = base_opts(#{dns_propagation_delay_ms => 0}),
        ?assertMatch({ok, _, _}, pertisk_eproxy_acme_client:obtain_certificate(Opts))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.
