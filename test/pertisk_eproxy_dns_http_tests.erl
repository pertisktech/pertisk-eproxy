-module(pertisk_eproxy_dns_http_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TOKEN, <<"test-token">>).
-define(ZONE, <<"example.com">>).
-define(RECORD, <<"_acme-challenge">>).
-define(TXT, <<"challenge-value">>).
-define(PORKBUN_KEY, <<"pk-test">>).
-define(PORKBUN_SECRET, <<"sk-test">>).
-define(PDNS_URL, <<"http://127.0.0.1:8081/api/v1">>).
-define(PDNS_KEY, <<"pdns-api-key">>).
-define(LINODE_DOMAIN_ID, 12345).
-define(LINODE_RECORD_ID, 999).

normalize_method(M) when is_atom(M) -> M;
normalize_method(M) when is_list(M) ->
    case string:lowercase(M) of
        "get" -> get;
        "post" -> post;
        "put" -> put;
        "patch" -> patch;
        "delete" -> delete;
        _ -> M
    end;
normalize_method(M) -> M.

with_httpc_mock(Fun) ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        dns_http(normalize_method(Method), Req, Opts, HttpOpts)
    end),
    try Fun() after pertisk_eproxy_test_helpers:unload_mocks([httpc]) end.

url(Method, Req) ->
    case {Method, Req} of
        {get, {U, _}} -> list_to_binary(U);
        {post, {U, _, _, _}} -> list_to_binary(U);
        {put, {U, _, _, _}} -> list_to_binary(U);
        {patch, {U, _, _, _}} -> list_to_binary(U);
        {delete, {U, _}} -> list_to_binary(U);
        _ -> <<>>
    end.

json_body(BodyMap) ->
    binary_to_list(thoas:encode(BodyMap)).

json_ok(BodyMap) ->
    {ok, {{'HTTP/1.1', 200, 'OK'}, [], json_body(BodyMap)}}.

json_201(BodyMap) ->
    {ok, {{'HTTP/1.1', 201, 'Created'}, [], json_body(BodyMap)}}.

json_204() ->
    {ok, {{'HTTP/1.1', 204, 'No Content'}, [], ""}}.

dns_http(get, Req, _Opts, _HttpOpts) ->
    U = url(get, Req),
    cloudflare_get(U);
dns_http(post, Req, _Opts, _HttpOpts) ->
    U = url(post, Req),
    cloudflare_post(U);
dns_http(delete, Req, _Opts, _HttpOpts) ->
    U = url(delete, Req),
    cloudflare_delete(U);
dns_http(patch, Req, _Opts, _HttpOpts) ->
    U = url(patch, Req),
    case binary:match(U, <<"/servers/">>) of
        {_, _} -> powerdns_patch(U);
        nomatch -> desec_patch(U)
    end;
dns_http(put, Req, _Opts, _HttpOpts) ->
    U = url(put, Req),
    gandi_put(U).

%% Cloudflare
cloudflare_get(U) ->
    case binary:match(U, <<"api.cloudflare.com/client/v4/zones">>) of
        nomatch ->
            {error, not_found};
        _ ->
            cloudflare_get_zones(U)
    end.

cloudflare_get_zones(U) ->
    case {binary:match(U, <<"zones/z1">>), binary:match(U, <<"zones?name=">>)} of
        {{_, _}, _} ->
            json_ok(#{
                <<"success">> => true,
                <<"result">> => #{<<"id">> => <<"z1">>, <<"name">> => ?ZONE}
            });
        {_, {_, _}} ->
            json_ok(#{
                <<"success">> => true,
                <<"result">> => [#{<<"id">> => <<"z1">>, <<"name">> => ?ZONE}]
            });
        _ ->
            json_ok(#{
                <<"success">> => true,
                <<"result">> => []
            })
    end.

cloudflare_post(<<"https://api.cloudflare.com/client/v4/zones/z1/dns_records">>) ->
    json_ok(#{
        <<"success">> => true,
        <<"result">> => #{<<"id">> => <<"rec1">>}
    });
cloudflare_post(_) ->
    {error, bad_post}.

cloudflare_delete(<<"https://api.cloudflare.com/client/v4/zones/z1/dns_records/rec1">>) ->
    json_ok(#{<<"success">> => true});
cloudflare_delete(_) ->
    {error, bad_delete}.

cloudflare_find_zone_test() ->
    with_httpc_mock(fun() ->
        ?assertMatch({ok, #{zone_id := <<"z1">>, zone_name := ?ZONE}},
            pertisk_eproxy_dns_cloudflare:find_zone(?TOKEN, <<"www.", ?ZONE/binary>>))
    end).

cloudflare_get_zone_test() ->
    with_httpc_mock(fun() ->
        ?assertMatch({ok, #{zone_id := <<"z1">>}},
            pertisk_eproxy_dns_cloudflare:get_zone(?TOKEN, <<"z1">>))
    end).

cloudflare_create_txt_test() ->
    with_httpc_mock(fun() ->
        ?assertMatch({ok, <<"rec1">>},
            pertisk_eproxy_dns_cloudflare:create_txt(?TOKEN, <<"z1">>, ?RECORD, ?TXT, <<"acme">>))
    end).

cloudflare_delete_txt_test() ->
    with_httpc_mock(fun() ->
        ?assertEqual(ok, pertisk_eproxy_dns_cloudflare:delete_txt(?TOKEN, <<"z1">>, <<"rec1">>))
    end).

cloudflare_auth_diag_test() ->
    D = pertisk_eproxy_dns_cloudflare:auth_diag(?TOKEN),
    ?assert(is_map(D)),
    ?assert(maps:is_key(raw_len, D)).

cloudflare_cf_txt_record_name_test() ->
    Fqdn = <<"_acme-challenge.www.", ?ZONE/binary>>,
    ?assertEqual(<<"_acme-challenge.www">>, pertisk_eproxy_dns_cloudflare:cf_txt_record_name(Fqdn, ?ZONE)).

cloudflare_cf_txt_record_name_no_suffix_test() ->
    ?assertEqual(<<"other">>, pertisk_eproxy_dns_cloudflare:cf_txt_record_name(<<"other">>, ?ZONE)).

cloudflare_find_zone_wildcard_host_test() ->
    with_httpc_mock(fun() ->
        ?assertMatch({ok, #{zone_id := <<"z1">>}},
            pertisk_eproxy_dns_cloudflare:find_zone(?TOKEN, <<"*.", ?ZONE/binary>>))
    end).

cloudflare_find_zone_trailing_dot_test() ->
    with_httpc_mock(fun() ->
        ?assertMatch({ok, #{zone_id := <<"z1">>}},
            pertisk_eproxy_dns_cloudflare:find_zone(?TOKEN, <<"www.", ?ZONE/binary, ".">>))
    end).

cloudflare_find_zone_not_found_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, _}, _Opts, _HttpOpts) ->
        case binary:match(list_to_binary(U), <<"api.cloudflare.com/client/v4/zones">>) of
            nomatch -> {error, not_found};
            _ -> json_ok(#{<<"success">> => true, <<"result">> => []})
        end
    end),
    try
        ?assertMatch({error, {zone_not_found, _}},
            pertisk_eproxy_dns_cloudflare:find_zone(?TOKEN, <<"missing.example.com">>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

cloudflare_get_zone_error_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, _}, _Opts, _HttpOpts) ->
        case binary:match(list_to_binary(U), <<"zones/z1">>) of
            nomatch -> {error, not_found};
            _ -> json_ok(#{<<"success">> => false, <<"errors">> => [#{<<"code">> => 1003}]})
        end
    end),
    try
        ?assertMatch({error, {zone_lookup, _}},
            pertisk_eproxy_dns_cloudflare:get_zone(?TOKEN, <<"z1">>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

cloudflare_duplicate_post(<<"https://api.cloudflare.com/client/v4/zones/z1/dns_records">>) ->
    json_ok(#{
        <<"success">> => false,
        <<"errors">> => [#{<<"code">> => 81058}]
    });
cloudflare_duplicate_post(_) ->
    {error, bad_post}.

cloudflare_duplicate_get(U) ->
    case binary:match(U, <<"dns_records?type=TXT">>) of
        nomatch ->
            cloudflare_get(U);
        _ ->
            json_ok(#{
                <<"success">> => true,
                <<"result">> => [
                    #{
                        <<"type">> => <<"TXT">>,
                        <<"name">> => ?RECORD,
                        <<"content">> => ?TXT,
                        <<"id">> => <<"dup-rec">>
                    }
                ]
            })
    end.

cloudflare_create_txt_duplicate_reuses_id_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        M = normalize_method(Method),
        U = url(M, Req),
        case M of
            post -> cloudflare_duplicate_post(U);
            get -> cloudflare_duplicate_get(U);
            _ -> dns_http(M, Req, Opts, HttpOpts)
        end
    end),
    try
        ?assertEqual({ok, <<"dup-rec">>},
            pertisk_eproxy_dns_cloudflare:create_txt(?TOKEN, <<"z1">>, ?RECORD, ?TXT, <<"acme">>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

cloudflare_delete_txt_error_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(delete, {U, _}, _Opts, _HttpOpts) ->
        case U of
            "https://api.cloudflare.com/client/v4/zones/z1/dns_records/bad" ->
                json_ok(#{<<"success">> => false, <<"errors">> => [#{<<"code">> => 1001}]});
            _ ->
                cloudflare_delete(list_to_binary(U))
        end
    end),
    try
        ?assertMatch({error, {cloudflare, _}},
            pertisk_eproxy_dns_cloudflare:delete_txt(?TOKEN, <<"z1">>, <<"bad">>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

%% deSEC
desec_patch(<<"https://desec.io/api/v1/domains/", _/binary>>) ->
    json_ok(#{});
desec_patch(_) ->
    {error, bad_patch}.

desec_get_override(Method, Req, Opts, HttpOpts) ->
    M = normalize_method(Method),
    U = url(M, Req),
    case binary:match(U, <<"desec.io/api/v1/domains/">>) of
        {_, _} -> json_ok(#{<<"name">> => ?ZONE});
        nomatch -> dns_http(M, Req, Opts, HttpOpts)
    end.

desec_resolve_domain_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        desec_get_override(Method, Req, Opts, HttpOpts)
    end),
    try
        ?assertMatch({ok, ?ZONE},
            pertisk_eproxy_dns_desec:resolve_domain(?TOKEN, ?ZONE, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

desec_create_txt_test() ->
    with_httpc_mock(fun() ->
        ?assertMatch({ok, {desec, ?TOKEN, ?ZONE, ?RECORD}},
            pertisk_eproxy_dns_desec:create_txt(?TOKEN, ?ZONE, ?RECORD, ?TXT))
    end).

desec_delete_txt_test() ->
    with_httpc_mock(fun() ->
        ?assertEqual(ok, pertisk_eproxy_dns_desec:delete_txt(?TOKEN, ?ZONE, ?RECORD))
    end).

%% Hetzner
hetzner_http(Method, Req, Opts, HttpOpts) ->
    M = normalize_method(Method),
    U = url(M, Req),
    case {M, U} of
        {get, <<"https://dns.hetzner.com/api/v1/zones?name=", _/binary>>} ->
            json_ok(#{
                <<"zones">> => [#{<<"id">> => <<"hz1">>, <<"name">> => ?ZONE}]
            });
        {post, <<"https://dns.hetzner.com/api/v1/records">>} ->
            json_201(#{<<"record">> => #{<<"id">> => <<"hz-rec">>}});
        {delete, <<"https://dns.hetzner.com/api/v1/records/hz-rec">>} ->
            json_204();
        _ ->
            dns_http(M, Req, Opts, HttpOpts)
    end.

hetzner_resolve_zone_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        hetzner_http(Method, Req, Opts, HttpOpts)
    end),
    try
        ?assertMatch({ok, #{zone_id := <<"hz1">>}},
            pertisk_eproxy_dns_hetzner:resolve_zone(?TOKEN, ?ZONE, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

hetzner_create_txt_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        hetzner_http(Method, Req, Opts, HttpOpts)
    end),
    try
        ?assertMatch({ok, <<"hz-rec">>},
            pertisk_eproxy_dns_hetzner:create_txt(?TOKEN, <<"hz1">>, ?RECORD, ?TXT))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

hetzner_delete_txt_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        hetzner_http(Method, Req, Opts, HttpOpts)
    end),
    try
        ?assertEqual(ok, pertisk_eproxy_dns_hetzner:delete_txt(?TOKEN, <<"hz1">>, <<"hz-rec">>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

%% Vultr
vultr_http(Method, Req, Opts, HttpOpts) ->
    M = normalize_method(Method),
    U = url(M, Req),
    case {M, binary:match(U, <<"api.vultr.com/v2/domains/">>), binary:match(U, <<"/records">>)}
    of
        {get, {_, _}, nomatch} ->
            json_ok(#{<<"domain">> => ?ZONE});
        {post, {_, _}, {_, _}} ->
            json_201(#{<<"record">> => #{<<"id">> => <<"v1">>}});
        {delete, {_, _}, {_, _}} ->
            json_204();
        _ ->
            dns_http(M, Req, Opts, HttpOpts)
    end.

vultr_resolve_zone_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        vultr_http(Method, Req, Opts, HttpOpts)
    end),
    try
        ?assertMatch({ok, ?ZONE},
            pertisk_eproxy_dns_vultr:resolve_zone(?TOKEN, ?ZONE, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

vultr_create_txt_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        vultr_http(Method, Req, Opts, HttpOpts)
    end),
    try
        ?assertMatch({ok, <<"v1">>},
            pertisk_eproxy_dns_vultr:create_txt(?TOKEN, ?ZONE, ?RECORD, ?TXT))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

vultr_delete_txt_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        vultr_http(Method, Req, Opts, HttpOpts)
    end),
    try
        ?assertEqual(ok, pertisk_eproxy_dns_vultr:delete_txt(?TOKEN, ?ZONE, <<"v1">>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

%% Gandi
gandi_put(<<"https://api.gandi.net/v5/livedns/domains/", _/binary>>) ->
    json_ok(#{});
gandi_put(_) ->
    {error, bad_put}.

gandi_get_override(Method, Req, Opts, HttpOpts) ->
    M = normalize_method(Method),
    U = url(M, Req),
    case binary:match(U, <<"api.gandi.net/v5/livedns/domains/">>) of
        {_, _} -> json_ok(#{<<"fqdn">> => ?ZONE});
        nomatch -> dns_http(M, Req, Opts, HttpOpts)
    end.

gandi_resolve_domain_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        gandi_get_override(Method, Req, Opts, HttpOpts)
    end),
    try
        ?assertMatch({ok, ?ZONE},
            pertisk_eproxy_dns_gandi:resolve_domain(?TOKEN, ?ZONE, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

gandi_create_txt_test() ->
    with_httpc_mock(fun() ->
        ?assertMatch({ok, {gandi, ?TOKEN, ?ZONE, ?RECORD}},
            pertisk_eproxy_dns_gandi:create_txt(?TOKEN, ?ZONE, ?RECORD, ?TXT))
    end).

gandi_delete_txt_test() ->
    with_httpc_mock(fun() ->
        ?assertEqual(ok, pertisk_eproxy_dns_gandi:delete_txt(?TOKEN, ?ZONE, ?RECORD))
    end).

%% DigitalOcean
do_http(Method, Req, Opts, HttpOpts) ->
    M = normalize_method(Method),
    U = url(M, Req),
    case {M, binary:match(U, <<"api.digitalocean.com/v2/domains/">>), binary:match(U, <<"/records">>)}
    of
        {get, {_, _}, nomatch} ->
            json_ok(#{<<"domain">> => #{<<"name">> => ?ZONE}});
        {post, {_, _}, {_, _}} ->
            json_201(#{<<"domain_record">> => #{<<"id">> => 42}});
        {delete, {_, _}, {_, _}} ->
            json_204();
        _ ->
            dns_http(M, Req, Opts, HttpOpts)
    end.

digitalocean_resolve_domain_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        do_http(Method, Req, Opts, HttpOpts)
    end),
    try
        ?assertMatch({ok, ?ZONE},
            pertisk_eproxy_dns_digitalocean:resolve_domain(?TOKEN, ?ZONE, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

digitalocean_create_txt_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        do_http(Method, Req, Opts, HttpOpts)
    end),
    try
        ?assertMatch({ok, 42},
            pertisk_eproxy_dns_digitalocean:create_txt(?TOKEN, ?ZONE, ?RECORD, ?TXT))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

digitalocean_delete_txt_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        do_http(Method, Req, Opts, HttpOpts)
    end),
    try
        ?assertEqual(ok, pertisk_eproxy_dns_digitalocean:delete_txt(?TOKEN, ?ZONE, 42))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

%% Linode
linode_http(Method, Req, Opts, HttpOpts) ->
    M = normalize_method(Method),
    U = url(M, Req),
    case {M, binary:match(U, <<"api.linode.com/v4/domains">>), binary:match(U, <<"/records">>)}
    of
        {get, {_, _}, nomatch} ->
            json_ok(#{
                <<"data">> => [
                    #{
                        <<"id">> => ?LINODE_DOMAIN_ID,
                        <<"domain">> => ?ZONE,
                        <<"type">> => <<"master">>
                    }
                ]
            });
        {post, {_, _}, {_, _}} ->
            json_ok(#{<<"id">> => ?LINODE_RECORD_ID});
        {delete, {_, _}, {_, _}} ->
            json_204();
        _ ->
            dns_http(M, Req, Opts, HttpOpts)
    end.

linode_resolve_domain_explicit_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        linode_http(Method, Req, Opts, HttpOpts)
    end),
    try
        ?assertMatch(
            {ok, #{id := ?LINODE_DOMAIN_ID, domain := ?ZONE}},
            pertisk_eproxy_dns_linode:resolve_domain(?TOKEN, ?ZONE, <<"www.", ?ZONE/binary>>)
        )
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

linode_resolve_domain_from_host_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        linode_http(Method, Req, Opts, HttpOpts)
    end),
    try
        ?assertMatch(
            {ok, #{id := ?LINODE_DOMAIN_ID}},
            pertisk_eproxy_dns_linode:resolve_domain(?TOKEN, undefined, <<"www.", ?ZONE/binary>>)
        )
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

linode_txt_record_name_test() ->
    Fqdn = <<"_acme-challenge.www.", ?ZONE/binary>>,
    ?assertEqual(<<"_acme-challenge.www">>, pertisk_eproxy_dns_linode:txt_record_name(Fqdn, ?ZONE)).

linode_create_txt_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        linode_http(Method, Req, Opts, HttpOpts)
    end),
    try
        ?assertMatch(
            {ok, ?LINODE_RECORD_ID},
            pertisk_eproxy_dns_linode:create_txt(
                ?TOKEN, ?LINODE_DOMAIN_ID, ?RECORD, ?TXT
            )
        )
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

linode_delete_txt_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        linode_http(Method, Req, Opts, HttpOpts)
    end),
    try
        ?assertEqual(
            ok,
            pertisk_eproxy_dns_linode:delete_txt(?TOKEN, ?LINODE_DOMAIN_ID, ?LINODE_RECORD_ID)
        )
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

%% Porkbun
porkbun_http(Method, Req, Opts, HttpOpts) ->
    M = normalize_method(Method),
    U = url(M, Req),
    case {M, binary:match(U, <<"api.porkbun.com/api/json/v3/dns/">>)} of
        {post, {_, _}} ->
            porkbun_post(U);
        _ ->
            dns_http(M, Req, Opts, HttpOpts)
    end.

porkbun_post(U) ->
    case U of
        <<"https://api.porkbun.com/api/json/v3/dns/retrieve/", _/binary>> ->
            json_ok(#{
                <<"status">> => <<"SUCCESS">>,
                <<"records">> => [#{<<"type">> => <<"TXT">>, <<"id">> => <<"pb1">>}]
            });
        <<"https://api.porkbun.com/api/json/v3/dns/create/", _/binary>> ->
            json_ok(#{<<"status">> => <<"SUCCESS">>, <<"id">> => <<"pb-rec">>});
        <<"https://api.porkbun.com/api/json/v3/dns/delete/", _/binary>> ->
            json_ok(#{<<"status">> => <<"SUCCESS">>});
        _ ->
            {error, bad_porkbun_post}
    end.

porkbun_resolve_domain_explicit_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        porkbun_http(Method, Req, Opts, HttpOpts)
    end),
    try
        ?assertMatch(
            {ok, ?ZONE},
            pertisk_eproxy_dns_porkbun:resolve_domain(
                ?PORKBUN_KEY, ?PORKBUN_SECRET, ?ZONE, <<"www.", ?ZONE/binary>>
            )
        )
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

porkbun_resolve_domain_from_host_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        porkbun_http(Method, Req, Opts, HttpOpts)
    end),
    try
        Host = <<"www.", ?ZONE/binary>>,
        ?assertEqual({ok, Host},
            pertisk_eproxy_dns_porkbun:resolve_domain(
                ?PORKBUN_KEY, ?PORKBUN_SECRET, undefined, Host
            ))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

porkbun_txt_record_name_test() ->
    Fqdn = <<"_acme-challenge.app.", ?ZONE/binary>>,
    ?assertEqual(<<"_acme-challenge.app">>, pertisk_eproxy_dns_porkbun:txt_record_name(Fqdn, ?ZONE)).

porkbun_create_txt_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        porkbun_http(Method, Req, Opts, HttpOpts)
    end),
    try
        ?assertMatch(
            {ok, <<"pb-rec">>},
            pertisk_eproxy_dns_porkbun:create_txt(
                ?PORKBUN_KEY, ?PORKBUN_SECRET, ?ZONE, ?RECORD, ?TXT
            )
        )
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

porkbun_delete_txt_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        porkbun_http(Method, Req, Opts, HttpOpts)
    end),
    try
        ?assertEqual(
            ok,
            pertisk_eproxy_dns_porkbun:delete_txt(
                ?PORKBUN_KEY, ?PORKBUN_SECRET, ?ZONE, <<"pb-rec">>
            )
        )
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

%% PowerDNS
powerdns_http(Method, Req, Opts, HttpOpts) ->
    M = normalize_method(Method),
    U = url(M, Req),
    case {M, binary:match(U, <<"/servers/">>), binary:match(U, <<"/zones/">>)} of
        {get, {_, _}, {_, _}} ->
            json_ok(#{<<"name">> => <<?ZONE/binary, ".">>});
        {patch, {_, _}, {_, _}} ->
            json_ok(#{});
        _ ->
            dns_http(M, Req, Opts, HttpOpts)
    end.

powerdns_patch(<<"http://127.0.0.1:8081/api/v1/servers/", _/binary>>) ->
    json_ok(#{});
powerdns_patch(_) ->
    {error, bad_powerdns_patch}.

powerdns_resolve_zone_explicit_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        powerdns_http(Method, Req, Opts, HttpOpts)
    end),
    try
        ?assertMatch(
            {ok, #{server_id := <<"localhost">>, zone_name := ?ZONE}},
            pertisk_eproxy_dns_powerdns:resolve_zone(
                ?PDNS_URL, ?PDNS_KEY, undefined, ?ZONE, <<"www.", ?ZONE/binary>>
            )
        )
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

powerdns_resolve_zone_from_host_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        powerdns_http(Method, Req, Opts, HttpOpts)
    end),
    try
        Host = <<"www.", ?ZONE/binary>>,
        ?assertMatch(
            {ok, #{server_id := <<"pdns">>, zone_name := Host}},
            pertisk_eproxy_dns_powerdns:resolve_zone(
                ?PDNS_URL, ?PDNS_KEY, <<"pdns">>, undefined, Host
            )
        )
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

powerdns_txt_record_name_test() ->
    Fqdn = <<"_acme-challenge.", ?ZONE/binary>>,
    ?assertEqual(<<"_acme-challenge">>, pertisk_eproxy_dns_powerdns:txt_record_name(Fqdn, ?ZONE)).

powerdns_create_txt_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        powerdns_http(Method, Req, Opts, HttpOpts)
    end),
    try
        ?assertMatch(
            {ok, {powerdns, ?PDNS_URL, ?PDNS_KEY, <<"localhost">>, ?ZONE, ?RECORD}},
            pertisk_eproxy_dns_powerdns:create_txt(
                ?PDNS_URL, ?PDNS_KEY, <<"localhost">>, ?ZONE, ?RECORD, ?TXT
            )
        )
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

powerdns_delete_txt_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        powerdns_http(Method, Req, Opts, HttpOpts)
    end),
    try
        ?assertEqual(
            ok,
            pertisk_eproxy_dns_powerdns:delete_txt(
                ?PDNS_URL, ?PDNS_KEY, <<"localhost">>, ?ZONE, ?RECORD
            )
        )
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

%% ---------------------------------------------------------------------------
%% httpc error branches and edge paths (coverage)
%% ---------------------------------------------------------------------------

with_httpc_transport_error(Fun) ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(_, _, _, _) -> {error, timeout} end),
    try Fun() after pertisk_eproxy_test_helpers:unload_mocks([httpc]) end.

with_httpc_status_error(Method, Status, Fun) ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(M, Req, Opts, HttpOpts) ->
        case normalize_method(M) of
            Method ->
                {ok, {{'HTTP/1.1', Status, 'Error'}, [], <<"error">>}};
            _ ->
                dns_http(normalize_method(M), Req, Opts, HttpOpts)
        end
    end),
    try Fun() after pertisk_eproxy_test_helpers:unload_mocks([httpc]) end.

%% Cloudflare
cloudflare_find_zone_http_404_retries_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"api.cloudflare.com/client/v4/zones">>) of
            nomatch -> {error, not_found};
            _ -> {ok, {{'HTTP/1.1', 404, 'Not Found'}, [], ""}}
        end
    end),
    try
        ?assertMatch({error, {zone_not_found, _}},
            pertisk_eproxy_dns_cloudflare:find_zone(?TOKEN, <<"missing.example.com">>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

cloudflare_find_zone_httpc_error_test() ->
    with_httpc_transport_error(fun() ->
        ?assertMatch({error, {zone_lookup, {error, timeout}}},
            pertisk_eproxy_dns_cloudflare:find_zone(?TOKEN, <<"www.", ?ZONE/binary>>))
    end).

cloudflare_find_zone_api_error_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"api.cloudflare.com/client/v4/zones">>) of
            nomatch -> {error, not_found};
            _ -> json_ok(#{<<"success">> => false, <<"errors">> => [#{<<"code">> => 1001}]})
        end
    end),
    try
        ?assertMatch({error, {zone_lookup, {cloudflare, _}}},
            pertisk_eproxy_dns_cloudflare:find_zone(?TOKEN, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

cloudflare_create_txt_httpc_error_test() ->
    with_httpc_transport_error(fun() ->
        ?assertMatch({error, timeout},
            pertisk_eproxy_dns_cloudflare:create_txt(?TOKEN, <<"z1">>, ?RECORD, ?TXT, <<"acme">>))
    end).

cloudflare_create_txt_duplicate_lookup_fails_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        M = normalize_method(Method),
        U = url(M, Req),
        case M of
            post -> cloudflare_duplicate_post(U);
            get ->
                case binary:match(U, <<"dns_records?type=TXT">>) of
                    nomatch -> cloudflare_get(U);
                    _ -> json_ok(#{<<"success">> => true, <<"result">> => []})
                end;
            _ -> dns_http(M, Req, Opts, HttpOpts)
        end
    end),
    try
        ?assertMatch({error, {cloudflare, _}},
            pertisk_eproxy_dns_cloudflare:create_txt(?TOKEN, <<"z1">>, ?RECORD, ?TXT, <<"acme">>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

cloudflare_create_txt_unexpected_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(post, _, _, _) ->
        json_ok(#{<<"success">> => true, <<"result">> => #{}})
    end),
    try
        ?assertMatch({error, {unexpected, _}},
            pertisk_eproxy_dns_cloudflare:create_txt(?TOKEN, <<"z1">>, ?RECORD, ?TXT, <<"acme">>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

cloudflare_delete_txt_httpc_error_test() ->
    with_httpc_transport_error(fun() ->
        ?assertMatch({error, timeout},
            pertisk_eproxy_dns_cloudflare:delete_txt(?TOKEN, <<"z1">>, <<"rec1">>))
    end).

cloudflare_invalid_token_test() ->
    ?assertMatch({error, {zone_lookup, {error, invalid_api_token_format}}},
        pertisk_eproxy_dns_cloudflare:find_zone(<<"">>, <<"example.com">>)).

cloudflare_redacted_token_test() ->
    ?assertMatch({error, {zone_lookup, {error, redacted_api_token_placeholder}}},
        pertisk_eproxy_dns_cloudflare:find_zone(<<"[redacted]">>, <<"example.com">>)).

cloudflare_auth_diag_modes_test() ->
    ?assertMatch(#{mode := token_or_key, email_present := true},
        pertisk_eproxy_dns_cloudflare:auth_diag({token_or_key, ?TOKEN, <<"a@b.com">>})),
    ?assertMatch(#{mode := global_key},
        pertisk_eproxy_dns_cloudflare:auth_diag({global_key, ?TOKEN, <<"a@b.com">>})),
    ?assertMatch(#{mode := bearer_token},
        pertisk_eproxy_dns_cloudflare:auth_diag(?TOKEN)).

cloudflare_auth_6111_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(_, _, _, _) ->
        {ok, {{'HTTP/1.1', 400, 'Bad Request'}, [], <<"{\"code\":6111}">>}}
    end),
    try
        ?assertMatch({error, {zone_lookup, {error, invalid_cloudflare_auth_header}}},
            pertisk_eproxy_dns_cloudflare:find_zone(?TOKEN, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

%% deSEC
desec_txt_record_name_test() ->
    Fqdn = <<"_acme-challenge.www.", ?ZONE/binary>>,
    ?assertEqual(<<"_acme-challenge.www">>, pertisk_eproxy_dns_desec:txt_record_name(Fqdn, ?ZONE)).

desec_txt_record_name_no_suffix_test() ->
    ?assertEqual(<<"other">>, pertisk_eproxy_dns_desec:txt_record_name(<<"other">>, ?ZONE)).

desec_resolve_domain_from_host_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        desec_get_override(Method, Req, Opts, HttpOpts)
    end),
    try
        Host = <<"www.", ?ZONE/binary>>,
        ?assertMatch({ok, Host},
            pertisk_eproxy_dns_desec:resolve_domain(?TOKEN, undefined, Host))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

desec_resolve_domain_not_found_test() ->
    with_httpc_status_error(get, 404, fun() ->
        ?assertMatch({error, domain_not_found},
            pertisk_eproxy_dns_desec:resolve_domain(?TOKEN, undefined, <<"missing.example.com">>))
    end).

desec_create_txt_httpc_error_test() ->
    with_httpc_transport_error(fun() ->
        ?assertMatch({error, timeout},
            pertisk_eproxy_dns_desec:create_txt(?TOKEN, ?ZONE, ?RECORD, ?TXT))
    end).

desec_delete_txt_httpc_error_test() ->
    with_httpc_transport_error(fun() ->
        ?assertMatch({error, timeout},
            pertisk_eproxy_dns_desec:delete_txt(?TOKEN, ?ZONE, ?RECORD))
    end).

%% Hetzner
hetzner_txt_record_name_test() ->
    Fqdn = <<"_acme-challenge.www.", ?ZONE/binary>>,
    ?assertEqual(<<"_acme-challenge.www">>, pertisk_eproxy_dns_hetzner:txt_record_name(Fqdn, ?ZONE)).

hetzner_resolve_zone_from_host_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        hetzner_http(Method, Req, Opts, HttpOpts)
    end),
    try
        ?assertMatch({ok, #{zone_id := <<"hz1">>}},
            pertisk_eproxy_dns_hetzner:resolve_zone(?TOKEN, undefined, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

hetzner_resolve_zone_not_found_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"dns.hetzner.com">>) of
            nomatch -> {error, not_found};
            _ -> json_ok(#{<<"zones">> => []})
        end
    end),
    try
        ?assertMatch({error, zone_not_found},
            pertisk_eproxy_dns_hetzner:resolve_zone(?TOKEN, undefined, <<"missing.example.com">>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

hetzner_create_txt_httpc_error_test() ->
    with_httpc_transport_error(fun() ->
        ?assertMatch({error, timeout},
            pertisk_eproxy_dns_hetzner:create_txt(?TOKEN, <<"hz1">>, ?RECORD, ?TXT))
    end).

hetzner_create_txt_missing_record_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(post, _, _, _) ->
        json_201(#{<<"record">> => #{<<"name">> => ?RECORD}})
    end),
    try
        ?assertMatch({error, {missing_record_id, _}},
            pertisk_eproxy_dns_hetzner:create_txt(?TOKEN, <<"hz1">>, ?RECORD, ?TXT))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

hetzner_delete_txt_httpc_error_test() ->
    with_httpc_transport_error(fun() ->
        ?assertMatch({error, timeout},
            pertisk_eproxy_dns_hetzner:delete_txt(?TOKEN, <<"hz1">>, <<"hz-rec">>))
    end).

%% Vultr
vultr_txt_record_name_test() ->
    Fqdn = <<"_acme-challenge.app.", ?ZONE/binary>>,
    ?assertEqual(<<"_acme-challenge.app">>, pertisk_eproxy_dns_vultr:txt_record_name(Fqdn, ?ZONE)).

vultr_resolve_zone_from_host_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        vultr_http(Method, Req, Opts, HttpOpts)
    end),
    try
        Host = <<"www.", ?ZONE/binary>>,
        ?assertMatch({ok, Host},
            pertisk_eproxy_dns_vultr:resolve_zone(?TOKEN, undefined, Host))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

vultr_resolve_zone_not_found_test() ->
    with_httpc_status_error(get, 404, fun() ->
        ?assertMatch({error, zone_not_found},
            pertisk_eproxy_dns_vultr:resolve_zone(?TOKEN, undefined, <<"missing.example.com">>))
    end).

vultr_create_txt_httpc_error_test() ->
    with_httpc_transport_error(fun() ->
        ?assertMatch({error, timeout},
            pertisk_eproxy_dns_vultr:create_txt(?TOKEN, ?ZONE, ?RECORD, ?TXT))
    end).

vultr_create_txt_missing_id_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(post, _, _, _) ->
        json_201(#{<<"record">> => #{<<"name">> => ?RECORD}})
    end),
    try
        ?assertMatch({error, {missing_record_id, _}},
            pertisk_eproxy_dns_vultr:create_txt(?TOKEN, ?ZONE, ?RECORD, ?TXT))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

vultr_delete_txt_httpc_error_test() ->
    with_httpc_transport_error(fun() ->
        ?assertMatch({error, timeout},
            pertisk_eproxy_dns_vultr:delete_txt(?TOKEN, ?ZONE, <<"v1">>))
    end).

%% Gandi
gandi_txt_record_name_test() ->
    Fqdn = <<"_acme-challenge.www.", ?ZONE/binary>>,
    ?assertEqual(<<"_acme-challenge.www">>, pertisk_eproxy_dns_gandi:txt_record_name(Fqdn, ?ZONE)).

gandi_resolve_domain_from_host_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        gandi_get_override(Method, Req, Opts, HttpOpts)
    end),
    try
        Host = <<"www.", ?ZONE/binary>>,
        ?assertMatch({ok, Host},
            pertisk_eproxy_dns_gandi:resolve_domain(?TOKEN, undefined, Host))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

gandi_resolve_domain_not_found_test() ->
    with_httpc_status_error(get, 404, fun() ->
        ?assertMatch({error, domain_not_found},
            pertisk_eproxy_dns_gandi:resolve_domain(?TOKEN, undefined, <<"missing.example.com">>))
    end).

gandi_create_txt_httpc_error_test() ->
    with_httpc_transport_error(fun() ->
        ?assertMatch({error, timeout},
            pertisk_eproxy_dns_gandi:create_txt(?TOKEN, ?ZONE, ?RECORD, ?TXT))
    end).

gandi_delete_txt_httpc_error_test() ->
    with_httpc_transport_error(fun() ->
        ?assertMatch({error, timeout},
            pertisk_eproxy_dns_gandi:delete_txt(?TOKEN, ?ZONE, ?RECORD))
    end).

%% DigitalOcean
digitalocean_txt_record_name_test() ->
    Fqdn = <<"_acme-challenge.www.", ?ZONE/binary>>,
    ?assertEqual(<<"_acme-challenge.www">>, pertisk_eproxy_dns_digitalocean:txt_record_name(Fqdn, ?ZONE)).

digitalocean_resolve_domain_from_host_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        do_http(Method, Req, Opts, HttpOpts)
    end),
    try
        Host = <<"www.", ?ZONE/binary>>,
        ?assertMatch({ok, Host},
            pertisk_eproxy_dns_digitalocean:resolve_domain(?TOKEN, undefined, Host))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

digitalocean_resolve_domain_not_found_test() ->
    with_httpc_status_error(get, 404, fun() ->
        ?assertMatch({error, domain_not_found},
            pertisk_eproxy_dns_digitalocean:resolve_domain(?TOKEN, undefined, <<"missing.example.com">>))
    end).

digitalocean_create_txt_httpc_error_test() ->
    with_httpc_transport_error(fun() ->
        ?assertMatch({error, timeout},
            pertisk_eproxy_dns_digitalocean:create_txt(?TOKEN, ?ZONE, ?RECORD, ?TXT))
    end).

digitalocean_delete_txt_httpc_error_test() ->
    with_httpc_transport_error(fun() ->
        ?assertMatch({error, timeout},
            pertisk_eproxy_dns_digitalocean:delete_txt(?TOKEN, ?ZONE, 42))
    end).

%% Linode
linode_txt_record_name_no_suffix_test() ->
    ?assertEqual(<<"other">>, pertisk_eproxy_dns_linode:txt_record_name(<<"other">>, ?ZONE)).

linode_resolve_domain_not_found_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"api.linode.com/v4/domains">>) of
            nomatch -> {error, not_found};
            _ -> json_ok(#{<<"data">> => []})
        end
    end),
    try
        ?assertMatch({error, domain_not_found},
            pertisk_eproxy_dns_linode:resolve_domain(?TOKEN, undefined, <<"missing.example.com">>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

linode_create_txt_httpc_error_test() ->
    with_httpc_transport_error(fun() ->
        ?assertMatch({error, timeout},
            pertisk_eproxy_dns_linode:create_txt(?TOKEN, ?LINODE_DOMAIN_ID, ?RECORD, ?TXT))
    end).

linode_create_txt_missing_id_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(post, _, _, _) ->
        json_ok(#{<<"type">> => <<"TXT">>})
    end),
    try
        ?assertMatch({error, {missing_record_id, _}},
            pertisk_eproxy_dns_linode:create_txt(?TOKEN, ?LINODE_DOMAIN_ID, ?RECORD, ?TXT))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

linode_delete_txt_httpc_error_test() ->
    with_httpc_transport_error(fun() ->
        ?assertMatch({error, timeout},
            pertisk_eproxy_dns_linode:delete_txt(?TOKEN, ?LINODE_DOMAIN_ID, ?LINODE_RECORD_ID))
    end).

%% Porkbun
porkbun_txt_record_name_no_suffix_test() ->
    ?assertEqual(<<"other">>, pertisk_eproxy_dns_porkbun:txt_record_name(<<"other">>, ?ZONE)).

porkbun_resolve_domain_not_found_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(post, {U, _, _, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"api.porkbun.com">>) of
            nomatch -> {error, not_found};
            _ -> json_ok(#{<<"status">> => <<"ERROR">>, <<"message">> => <<"Domain not found">>})
        end
    end),
    try
        ?assertMatch({error, domain_not_found},
            pertisk_eproxy_dns_porkbun:resolve_domain(
                ?PORKBUN_KEY, ?PORKBUN_SECRET, undefined, <<"missing.example.com">>
            ))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

porkbun_create_txt_httpc_error_test() ->
    with_httpc_transport_error(fun() ->
        ?assertMatch({error, timeout},
            pertisk_eproxy_dns_porkbun:create_txt(
                ?PORKBUN_KEY, ?PORKBUN_SECRET, ?ZONE, ?RECORD, ?TXT
            ))
    end).

porkbun_create_txt_missing_id_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(post, _, _, _) ->
        json_ok(#{<<"status">> => <<"SUCCESS">>})
    end),
    try
        ?assertMatch({error, {missing_record_id, _}},
            pertisk_eproxy_dns_porkbun:create_txt(
                ?PORKBUN_KEY, ?PORKBUN_SECRET, ?ZONE, ?RECORD, ?TXT
            ))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

porkbun_delete_txt_httpc_error_test() ->
    with_httpc_transport_error(fun() ->
        ?assertMatch({error, timeout},
            pertisk_eproxy_dns_porkbun:delete_txt(
                ?PORKBUN_KEY, ?PORKBUN_SECRET, ?ZONE, <<"pb-rec">>
            ))
    end).

%% PowerDNS
powerdns_txt_record_name_no_suffix_test() ->
    ?assertEqual(<<"other">>, pertisk_eproxy_dns_powerdns:txt_record_name(<<"other">>, ?ZONE)).

powerdns_resolve_zone_not_found_test() ->
    with_httpc_status_error(get, 404, fun() ->
        ?assertMatch({error, zone_not_found},
            pertisk_eproxy_dns_powerdns:resolve_zone(
                ?PDNS_URL, ?PDNS_KEY, undefined, undefined, <<"missing.example.com">>
            ))
    end).

powerdns_create_txt_httpc_error_test() ->
    with_httpc_transport_error(fun() ->
        ?assertMatch({error, timeout},
            pertisk_eproxy_dns_powerdns:create_txt(
                ?PDNS_URL, ?PDNS_KEY, <<"localhost">>, ?ZONE, ?RECORD, ?TXT
            ))
    end).

powerdns_delete_txt_httpc_error_test() ->
    with_httpc_transport_error(fun() ->
        ?assertMatch({error, timeout},
            pertisk_eproxy_dns_powerdns:delete_txt(
                ?PDNS_URL, ?PDNS_KEY, <<"localhost">>, ?ZONE, ?RECORD
            ))
    end).

powerdns_resolve_zone_trailing_slash_url_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        powerdns_http(Method, Req, Opts, HttpOpts)
    end),
    try
        ?assertMatch({ok, #{zone_name := ?ZONE}},
            pertisk_eproxy_dns_powerdns:resolve_zone(
                <<?PDNS_URL/binary, "/">>, ?PDNS_KEY, undefined, ?ZONE, <<"www.", ?ZONE/binary>>
            ))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

%% ---------------------------------------------------------------------------
%% Additional edge/error paths for 80%+ coverage
%% ---------------------------------------------------------------------------

gandi_resolve_domain_explicit_failure_test() ->
    with_httpc_status_error(get, 500, fun() ->
        ?assertMatch({error, {domain_lookup_failed, ?ZONE, _}},
            pertisk_eproxy_dns_gandi:resolve_domain(?TOKEN, ?ZONE, <<"www.", ?ZONE/binary>>))
    end).

gandi_resolve_domain_fatal_error_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"api.gandi.net">>) of
            nomatch -> {error, not_found};
            _ -> {ok, {{'HTTP/1.1', 500, 'Error'}, [], <<"server error">>}}
        end
    end),
    try
        ?assertMatch({error, {domain_lookup_failed, _, {http, 500, _}}},
            pertisk_eproxy_dns_gandi:resolve_domain(?TOKEN, undefined, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

gandi_create_txt_http_status_error_test() ->
    with_httpc_status_error(put, 403, fun() ->
        ?assertMatch({error, {http, 403, _}},
            pertisk_eproxy_dns_gandi:create_txt(?TOKEN, ?ZONE, ?RECORD, ?TXT))
    end).

gandi_create_txt_201_response_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(put, _, _, _) ->
        {ok, {{'HTTP/1.1', 201, 'Created'}, [], "{}"}}
    end),
    try
        ?assertMatch({ok, {gandi, ?TOKEN, ?ZONE, ?RECORD}},
            pertisk_eproxy_dns_gandi:create_txt(?TOKEN, ?ZONE, ?RECORD, ?TXT))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

gandi_create_txt_invalid_json_body_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(put, _, _, _) ->
        {ok, {{'HTTP/1.1', 200, 'OK'}, [], "not-json"}}
    end),
    try
        ?assertMatch({ok, {gandi, ?TOKEN, ?ZONE, ?RECORD}},
            pertisk_eproxy_dns_gandi:create_txt(?TOKEN, ?ZONE, ?RECORD, ?TXT))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

gandi_resolve_domain_trim_spaces_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"/domains/example.com">>) of
            nomatch -> {error, not_found};
            _ -> json_ok(#{<<"fqdn">> => ?ZONE})
        end
    end),
    try
        ?assertMatch({ok, ?ZONE},
            pertisk_eproxy_dns_gandi:resolve_domain(?TOKEN, <<"  ", ?ZONE/binary, "  ">>, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

hetzner_resolve_zone_explicit_failure_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"dns.hetzner.com">>) of
            nomatch -> {error, not_found};
            _ -> json_ok(#{<<"zones">> => []})
        end
    end),
    try
        ?assertMatch({error, {zone_lookup_failed, ?ZONE, {error, zone_not_found}}},
            pertisk_eproxy_dns_hetzner:resolve_zone(?TOKEN, ?ZONE, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

hetzner_resolve_zone_fatal_error_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"dns.hetzner.com">>) of
            nomatch -> {error, not_found};
            _ -> {ok, {{'HTTP/1.1', 500, 'Error'}, [], <<"fail">>}}
        end
    end),
    try
        ?assertMatch({error, {zone_lookup_failed, _, {http, 500, _}}},
            pertisk_eproxy_dns_hetzner:resolve_zone(?TOKEN, undefined, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

hetzner_resolve_zone_bad_zone_map_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"dns.hetzner.com">>) of
            nomatch -> {error, not_found};
            _ -> json_ok(#{<<"zones">> => [#{<<"name">> => ?ZONE}]})
        end
    end),
    try
        ?assertMatch({error, {zone_lookup_failed, ?ZONE, {error, {zone_lookup, _}}}},
            pertisk_eproxy_dns_hetzner:resolve_zone(?TOKEN, ?ZONE, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

hetzner_create_txt_unexpected_response_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(post, _, _, _) ->
        json_ok(#{<<"unexpected">> => true})
    end),
    try
        ?assertMatch({error, {missing_record, _}},
            pertisk_eproxy_dns_hetzner:create_txt(?TOKEN, <<"hz1">>, ?RECORD, ?TXT))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

hetzner_delete_txt_http_status_error_test() ->
    with_httpc_status_error(delete, 403, fun() ->
        ?assertMatch({error, {http, 403, _}},
            pertisk_eproxy_dns_hetzner:delete_txt(?TOKEN, <<"hz1">>, <<"hz-rec">>))
    end).

hetzner_delete_txt_integer_id_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(delete, {U, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"/records/42">>) of
            nomatch -> {error, not_found};
            _ -> json_204()
        end
    end),
    try
        ?assertEqual(ok, pertisk_eproxy_dns_hetzner:delete_txt(?TOKEN, <<"hz1">>, 42))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

linode_resolve_domain_explicit_failure_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"api.linode.com">>) of
            nomatch -> {error, not_found};
            _ -> json_ok(#{<<"data">> => []})
        end
    end),
    try
        ?assertMatch({error, {domain_lookup_failed, ?ZONE, {error, domain_not_found}}},
            pertisk_eproxy_dns_linode:resolve_domain(?TOKEN, ?ZONE, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

linode_resolve_domain_fatal_error_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"api.linode.com">>) of
            nomatch -> {error, not_found};
            _ -> {ok, {{'HTTP/1.1', 500, 'Error'}, [], <<"fail">>}}
        end
    end),
    try
        ?assertMatch({error, {domain_lookup_failed, _, {http, 500, _}}},
            pertisk_eproxy_dns_linode:resolve_domain(?TOKEN, undefined, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

linode_list_domains_unexpected_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"api.linode.com">>) of
            nomatch -> {error, not_found};
            _ -> json_ok(#{<<"unexpected">> => true})
        end
    end),
    try
        ?assertMatch({error, {domain_lookup_failed, _, {unexpected_domains_response, _}}},
            pertisk_eproxy_dns_linode:resolve_domain(?TOKEN, undefined, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

linode_create_txt_integer_domain_id_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(post, {U, _, _, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"/domains/12345/records">>) of
            nomatch -> {error, not_found};
            _ -> json_ok(#{<<"id">> => ?LINODE_RECORD_ID})
        end
    end),
    try
        ?assertMatch({ok, ?LINODE_RECORD_ID},
            pertisk_eproxy_dns_linode:create_txt(?TOKEN, ?LINODE_DOMAIN_ID, ?RECORD, ?TXT))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

linode_delete_txt_http_status_error_test() ->
    with_httpc_status_error(delete, 403, fun() ->
        ?assertMatch({error, {http, 403, _}},
            pertisk_eproxy_dns_linode:delete_txt(?TOKEN, ?LINODE_DOMAIN_ID, ?LINODE_RECORD_ID))
    end).

porkbun_resolve_domain_explicit_failure_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(post, {U, _, _, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"api.porkbun.com">>) of
            nomatch -> {error, not_found};
            _ -> json_ok(#{<<"status">> => <<"ERROR">>, <<"message">> => <<"Domain not found">>})
        end
    end),
    try
        ?assertMatch({error, {domain_lookup_failed, ?ZONE, {error, {api_error, _}}}},
            pertisk_eproxy_dns_porkbun:resolve_domain(
                ?PORKBUN_KEY, ?PORKBUN_SECRET, ?ZONE, <<"www.", ?ZONE/binary>>
            ))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

porkbun_resolve_domain_fatal_error_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(post, {U, _, _, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"api.porkbun.com">>) of
            nomatch -> {error, not_found};
            _ -> {ok, {{'HTTP/1.1', 500, 'Error'}, [], <<"fail">>}}
        end
    end),
    try
        ?assertMatch({error, {domain_lookup_failed, _, {http, 500, _}}},
            pertisk_eproxy_dns_porkbun:resolve_domain(
                ?PORKBUN_KEY, ?PORKBUN_SECRET, undefined, <<"www.", ?ZONE/binary>>
            ))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

porkbun_create_txt_from_records_array_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(post, {U, _, _, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"/dns/create/">>) of
            nomatch ->
                {error, bad_post};
            _ ->
                json_ok(#{<<"status">> => <<"SUCCESS">>, <<"records">> => [#{<<"id">> => <<"from-rec">>}]})
        end
    end),
    try
        ?assertEqual({ok, <<"from-rec">>},
            pertisk_eproxy_dns_porkbun:create_txt(
                ?PORKBUN_KEY, ?PORKBUN_SECRET, ?ZONE, ?RECORD, ?TXT
            ))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

porkbun_create_txt_http_status_error_test() ->
    with_httpc_status_error(post, 403, fun() ->
        ?assertMatch({error, {http, 403, _}},
            pertisk_eproxy_dns_porkbun:create_txt(
                ?PORKBUN_KEY, ?PORKBUN_SECRET, ?ZONE, ?RECORD, ?TXT
            ))
    end).

porkbun_invalid_domain_400_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(post, {U, _, _, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"api.porkbun.com">>) of
            nomatch -> {error, not_found};
            _ -> {ok, {{'HTTP/1.1', 400, 'Bad Request'}, [], <<"invalid domain">>}}
        end
    end),
    try
        ?assertMatch({error, domain_not_found},
            pertisk_eproxy_dns_porkbun:resolve_domain(
                ?PORKBUN_KEY, ?PORKBUN_SECRET, undefined, <<"bad.example.com">>
            ))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

vultr_resolve_zone_explicit_failure_test() ->
    with_httpc_status_error(get, 404, fun() ->
        ?assertMatch({error, {zone_lookup_failed, ?ZONE, {error, {zone_lookup, {error, {http, 404, _}}}}}},
            pertisk_eproxy_dns_vultr:resolve_zone(?TOKEN, ?ZONE, <<"www.", ?ZONE/binary>>))
    end).

vultr_resolve_zone_fatal_error_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"api.vultr.com">>) of
            nomatch -> {error, not_found};
            _ -> {ok, {{'HTTP/1.1', 500, 'Error'}, [], <<"fail">>}}
        end
    end),
    try
        ?assertMatch({error, {zone_lookup_failed, _, {zone_lookup, {error, {http, 500, _}}}}},
            pertisk_eproxy_dns_vultr:resolve_zone(?TOKEN, undefined, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

vultr_get_zone_domain_map_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"api.vultr.com">>) of
            nomatch -> {error, not_found};
            _ -> json_ok(#{<<"domain">> => #{<<"name">> => ?ZONE}})
        end
    end),
    try
        ?assertEqual({ok, ?ZONE},
            pertisk_eproxy_dns_vultr:resolve_zone(?TOKEN, ?ZONE, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

vultr_create_txt_200_response_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(post, _, _, _) ->
        json_ok(#{<<"record">> => #{<<"id">> => <<"v200">>}})
    end),
    try
        ?assertEqual({ok, <<"v200">>},
            pertisk_eproxy_dns_vultr:create_txt(?TOKEN, ?ZONE, ?RECORD, ?TXT))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

vultr_delete_txt_http_status_error_test() ->
    with_httpc_status_error(delete, 403, fun() ->
        ?assertMatch({error, {http, 403, _}},
            pertisk_eproxy_dns_vultr:delete_txt(?TOKEN, ?ZONE, <<"v1">>))
    end).

vultr_delete_txt_200_body_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(delete, _, _, _) ->
        {ok, {{'HTTP/1.1', 200, 'OK'}, [], "{}"}}
    end),
    try
        ?assertEqual(ok, pertisk_eproxy_dns_vultr:delete_txt(?TOKEN, ?ZONE, <<"v1">>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

powerdns_resolve_zone_explicit_failure_test() ->
    with_httpc_status_error(get, 404, fun() ->
        ?assertMatch({error, {zone_lookup_failed, ?ZONE, {error, {http, 404, _}}}},
            pertisk_eproxy_dns_powerdns:resolve_zone(
                ?PDNS_URL, ?PDNS_KEY, undefined, ?ZONE, <<"www.", ?ZONE/binary>>
            ))
    end).

powerdns_resolve_zone_fatal_error_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"/servers/">>) of
            nomatch -> {error, not_found};
            _ -> {ok, {{'HTTP/1.1', 500, 'Error'}, [], <<"fail">>}}
        end
    end),
    try
        ?assertMatch({error, {zone_lookup_failed, _, {http, 500, _}}},
            pertisk_eproxy_dns_powerdns:resolve_zone(
                ?PDNS_URL, ?PDNS_KEY, undefined, undefined, <<"www.", ?ZONE/binary>>
            ))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

powerdns_default_server_id_list_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        powerdns_http(Method, Req, Opts, HttpOpts)
    end),
    try
        ?assertMatch({ok, #{server_id := <<"localhost">>}},
            pertisk_eproxy_dns_powerdns:resolve_zone(
                ?PDNS_URL, ?PDNS_KEY, undefined, ?ZONE, <<"www.", ?ZONE/binary>>
            ))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

powerdns_create_txt_http_status_error_test() ->
    with_httpc_status_error(patch, 403, fun() ->
        ?assertMatch({error, {http, 403, _}},
            pertisk_eproxy_dns_powerdns:create_txt(
                ?PDNS_URL, ?PDNS_KEY, <<"localhost">>, ?ZONE, ?RECORD, ?TXT
            ))
    end).

powerdns_get_zone_204_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"/zones/">>) of
            nomatch -> {error, not_found};
            _ -> json_204()
        end
    end),
    try
        ?assertMatch({ok, #{zone_name := ?ZONE}},
            pertisk_eproxy_dns_powerdns:resolve_zone(
                ?PDNS_URL, ?PDNS_KEY, undefined, ?ZONE, <<"www.", ?ZONE/binary>>
            ))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

powerdns_txt_record_name_trailing_dot_zone_test() ->
    Fqdn = <<"_acme-challenge.", ?ZONE/binary>>,
    ?assertEqual(<<"_acme-challenge">>, pertisk_eproxy_dns_powerdns:txt_record_name(Fqdn, <<?ZONE/binary, ".">>)).

hetzner_get_zone_unexpected_response_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"dns.hetzner.com">>) of
            nomatch -> {error, not_found};
            _ -> json_ok(#{<<"unexpected">> => true})
        end
    end),
    try
        ?assertMatch({error, {zone_lookup_failed, ?ZONE, {error, {zone_lookup, _}}}},
            pertisk_eproxy_dns_hetzner:resolve_zone(?TOKEN, ?ZONE, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

hetzner_txt_record_name_short_fqdn_test() ->
    ?assertEqual(<<"x">>, pertisk_eproxy_dns_hetzner:txt_record_name(<<"x">>, ?ZONE)).

hetzner_create_txt_json_error_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(post, _, _, _) ->
        {ok, {{'HTTP/1.1', 200, 'OK'}, [], "not-json"}}
    end),
    try
        ?assertMatch({error, {json, _}},
            pertisk_eproxy_dns_hetzner:create_txt(?TOKEN, <<"hz1">>, ?RECORD, ?TXT))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

linode_normalize_domain_without_type_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"api.linode.com">>) of
            nomatch -> {error, not_found};
            _ ->
                json_ok(#{
                    <<"data">> => [#{<<"id">> => 99, <<"domain">> => ?ZONE}]
                })
        end
    end),
    try
        ?assertMatch({ok, #{id := 99, domain := ?ZONE}},
            pertisk_eproxy_dns_linode:resolve_domain(?TOKEN, undefined, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

linode_txt_record_name_short_fqdn_test() ->
    ?assertEqual(<<"short">>, pertisk_eproxy_dns_linode:txt_record_name(<<"short">>, ?ZONE)).

linode_delete_txt_200_invalid_json_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(delete, _, _, _) ->
        {ok, {{'HTTP/1.1', 200, 'OK'}, [], "not-json"}}
    end),
    try
        ?assertEqual(ok,
            pertisk_eproxy_dns_linode:delete_txt(?TOKEN, ?LINODE_DOMAIN_ID, ?LINODE_RECORD_ID))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

porkbun_get_records_json_error_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(post, _, _, _) ->
        {ok, {{'HTTP/1.1', 200, 'OK'}, [], "not-json"}}
    end),
    try
        ?assertMatch({error, {domain_lookup_failed, ?ZONE, {error, {json, _}}}},
            pertisk_eproxy_dns_porkbun:resolve_domain(
                ?PORKBUN_KEY, ?PORKBUN_SECRET, ?ZONE, <<"www.", ?ZONE/binary>>
            ))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

porkbun_create_txt_lowercase_success_status_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(post, {U, _, _, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"/dns/create/">>) of
            nomatch -> {error, bad_post};
            _ -> json_ok(#{<<"status">> => <<"success">>, <<"id">> => <<"pb-low">>})
        end
    end),
    try
        ?assertEqual({ok, <<"pb-low">>},
            pertisk_eproxy_dns_porkbun:create_txt(
                ?PORKBUN_KEY, ?PORKBUN_SECRET, ?ZONE, ?RECORD, ?TXT
            ))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

vultr_create_txt_unexpected_response_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(post, _, _, _) ->
        json_ok(#{<<"unexpected">> => true})
    end),
    try
        ?assertMatch({error, {unexpected, _}},
            pertisk_eproxy_dns_vultr:create_txt(?TOKEN, ?ZONE, ?RECORD, ?TXT))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

vultr_txt_record_name_short_fqdn_test() ->
    ?assertEqual(<<"x">>, pertisk_eproxy_dns_vultr:txt_record_name(<<"x">>, ?ZONE)).

%% ---------------------------------------------------------------------------
%% Cloudflare / deSEC / DigitalOcean coverage (80%+)
%% ---------------------------------------------------------------------------

cloudflare_global_key_auth_success_test() ->
    Auth = {global_key, ?TOKEN, <<"a@b.com">>},
    with_httpc_mock(fun() ->
        ?assertMatch({ok, #{zone_id := <<"z1">>}},
            pertisk_eproxy_dns_cloudflare:find_zone(Auth, <<"www.", ?ZONE/binary>>))
    end).

cloudflare_bearer_prefix_normalization_test() ->
    Token = <<"Bearer ", ?TOKEN/binary>>,
    with_httpc_mock(fun() ->
        ?assertMatch({ok, #{zone_id := <<"z1">>}},
            pertisk_eproxy_dns_cloudflare:find_zone(Token, <<"www.", ?ZONE/binary>>))
    end).

cloudflare_find_zone_unexpected_shape_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"api.cloudflare.com/client/v4/zones">>) of
            nomatch -> {error, not_found};
            _ -> json_ok(#{<<"success">> => true, <<"result">> => #{<<"unexpected">> => true}})
        end
    end),
    try
        ?assertMatch({error, {zone_lookup, _}},
            pertisk_eproxy_dns_cloudflare:find_zone(?TOKEN, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

cloudflare_get_json_decode_error_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"zones/z1">>) of
            nomatch -> {error, not_found};
            _ -> {ok, {{'HTTP/1.1', 200, 'OK'}, [], "not-json"}}
        end
    end),
    try
        ?assertMatch({error, {zone_lookup, {error, {json, _}}}},
            pertisk_eproxy_dns_cloudflare:get_zone(?TOKEN, <<"z1">>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

cloudflare_create_txt_non_81058_error_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(post, _, _, _) ->
        json_ok(#{
            <<"success">> => false,
            <<"errors">> => [#{<<"code">> => 1001}]
        })
    end),
    try
        ?assertMatch({error, {cloudflare, _}},
            pertisk_eproxy_dns_cloudflare:create_txt(?TOKEN, <<"z1">>, ?RECORD, ?TXT, <<"acme">>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

cloudflare_auth_diag_empty_email_test() ->
    ?assertMatch(#{mode := global_key, email_present := false},
        pertisk_eproxy_dns_cloudflare:auth_diag({global_key, ?TOKEN, <<>>})).

desec_resolve_domain_explicit_failure_test() ->
    with_httpc_status_error(get, 404, fun() ->
        ?assertMatch({error, {domain_lookup_failed, ?ZONE, _}},
            pertisk_eproxy_dns_desec:resolve_domain(?TOKEN, ?ZONE, <<"www.", ?ZONE/binary>>))
    end).

desec_resolve_domain_fatal_error_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"desec.io">>) of
            nomatch -> {error, not_found};
            _ -> {ok, {{'HTTP/1.1', 500, 'Error'}, [], <<"fail">>}}
        end
    end),
    try
        ?assertMatch({error, {domain_lookup_failed, _, {http, 500, _}}},
            pertisk_eproxy_dns_desec:resolve_domain(?TOKEN, undefined, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

desec_create_txt_patch_204_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun("PATCH", _, _, _) -> json_204() end),
    try
        ?assertMatch({ok, {desec, ?TOKEN, ?ZONE, ?RECORD}},
            pertisk_eproxy_dns_desec:create_txt(?TOKEN, ?ZONE, ?RECORD, ?TXT))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

desec_get_json_decode_error_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"desec.io">>) of
            nomatch -> {error, not_found};
            _ -> {ok, {{'HTTP/1.1', 200, 'OK'}, [], "not-json"}}
        end
    end),
    try
        ?assertMatch({error, {domain_lookup_failed, ?ZONE, {error, {json, _}}}},
            pertisk_eproxy_dns_desec:resolve_domain(?TOKEN, ?ZONE, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

desec_resolve_domain_trim_spaces_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"/domains/example.com/">>) of
            nomatch -> {error, not_found};
            _ -> json_ok(#{<<"name">> => ?ZONE})
        end
    end),
    try
        ?assertMatch({ok, ?ZONE},
            pertisk_eproxy_dns_desec:resolve_domain(?TOKEN, <<"  ", ?ZONE/binary, "  ">>, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

desec_txt_record_name_short_fqdn_test() ->
    ?assertEqual(<<"x">>, pertisk_eproxy_dns_desec:txt_record_name(<<"x">>, ?ZONE)).

digitalocean_resolve_domain_explicit_failure_test() ->
    with_httpc_status_error(get, 404, fun() ->
        ?assertMatch({error, {domain_lookup_failed, ?ZONE, _}},
            pertisk_eproxy_dns_digitalocean:resolve_domain(?TOKEN, ?ZONE, <<"www.", ?ZONE/binary>>))
    end).

digitalocean_resolve_domain_fatal_error_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"api.digitalocean.com">>) of
            nomatch -> {error, not_found};
            _ -> {ok, {{'HTTP/1.1', 500, 'Error'}, [], <<"fail">>}}
        end
    end),
    try
        ?assertMatch({error, {domain_lookup_failed, _, {domain_lookup, {error, {http, 500, _}}}}},
            pertisk_eproxy_dns_digitalocean:resolve_domain(?TOKEN, undefined, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

digitalocean_create_txt_top_level_id_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(post, _, _, _) ->
        json_201(#{<<"id">> => 77})
    end),
    try
        ?assertEqual({ok, 77},
            pertisk_eproxy_dns_digitalocean:create_txt(?TOKEN, ?ZONE, ?RECORD, ?TXT))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

digitalocean_create_txt_200_response_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(post, _, _, _) ->
        json_ok(#{<<"domain_record">> => #{<<"id">> => 88}})
    end),
    try
        ?assertEqual({ok, 88},
            pertisk_eproxy_dns_digitalocean:create_txt(?TOKEN, ?ZONE, ?RECORD, ?TXT))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

digitalocean_create_txt_unexpected_response_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(post, _, _, _) ->
        json_ok(#{<<"unexpected">> => true})
    end),
    try
        ?assertMatch({error, {unexpected, _}},
            pertisk_eproxy_dns_digitalocean:create_txt(?TOKEN, ?ZONE, ?RECORD, ?TXT))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

digitalocean_delete_txt_200_invalid_json_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(delete, _, _, _) ->
        {ok, {{'HTTP/1.1', 200, 'OK'}, [], "not-json"}}
    end),
    try
        ?assertEqual(ok, pertisk_eproxy_dns_digitalocean:delete_txt(?TOKEN, ?ZONE, 42))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

digitalocean_txt_record_name_no_suffix_test() ->
    ?assertEqual(<<"other">>, pertisk_eproxy_dns_digitalocean:txt_record_name(<<"other">>, ?ZONE)).

do_hostname_check_failed_error() ->
    {error, {failed_connect, [{ssl, {alert, hostname_check_failed}}]}}.

with_do_tls_hostname_retry(Fun) ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        case get(do_tls_retry_n) of
            undefined ->
                put(do_tls_retry_n, 1),
                do_hostname_check_failed_error();
            _ ->
                do_http(normalize_method(Method), Req, Opts, HttpOpts)
        end
    end),
    try Fun() after
        erase(do_tls_retry_n),
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

digitalocean_resolve_domain_trim_domain_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        do_http(Method, Req, Opts, HttpOpts)
    end),
    try
        ?assertMatch({ok, ?ZONE},
            pertisk_eproxy_dns_digitalocean:resolve_domain(
                ?TOKEN, <<"  ", ?ZONE/binary, "  ">>, <<"www.", ?ZONE/binary>>
            ))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

digitalocean_txt_record_suffix_mismatch_test() ->
    ?assertEqual(<<"x">>, pertisk_eproxy_dns_digitalocean:txt_record_name(<<"x">>, ?ZONE)).

digitalocean_resolve_domain_hostname_retry_test() ->
    with_do_tls_hostname_retry(fun() ->
        ?assertMatch({ok, ?ZONE},
            pertisk_eproxy_dns_digitalocean:resolve_domain(?TOKEN, ?ZONE, <<"www.", ?ZONE/binary>>))
    end).

digitalocean_create_txt_hostname_retry_test() ->
    with_do_tls_hostname_retry(fun() ->
        ?assertMatch({ok, 42},
            pertisk_eproxy_dns_digitalocean:create_txt(?TOKEN, ?ZONE, ?RECORD, ?TXT))
    end).

digitalocean_delete_txt_hostname_retry_test() ->
    with_do_tls_hostname_retry(fun() ->
        ?assertEqual(ok, pertisk_eproxy_dns_digitalocean:delete_txt(?TOKEN, ?ZONE, 42))
    end).

digitalocean_get_connect_error_without_retry_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, _, _, _) ->
        {error, {failed_connect, [{reason, econnrefused}]}}
    end),
    try
        ?assertMatch({error, {domain_lookup_failed, _, _}},
            pertisk_eproxy_dns_digitalocean:resolve_domain(?TOKEN, undefined, <<"missing.example.com">>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

digitalocean_get_json_decode_error_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, _, _, _) ->
        {ok, {{'HTTP/1.1', 200, 'OK'}, [], "not-json"}}
    end),
    try
        ?assertMatch({error, {domain_lookup_failed, ?ZONE, {error, {domain_lookup, {error, {json, _}}}}}},
            pertisk_eproxy_dns_digitalocean:resolve_domain(?TOKEN, ?ZONE, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

digitalocean_post_json_decode_error_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(post, _, _, _) ->
        {ok, {{'HTTP/1.1', 201, 'Created'}, [], "not-json"}}
    end),
    try
        ?assertMatch({error, {json, _}},
            pertisk_eproxy_dns_digitalocean:create_txt(?TOKEN, ?ZONE, ?RECORD, ?TXT))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

digitalocean_post_http_status_error_test() ->
    with_httpc_status_error(post, 403, fun() ->
        ?assertMatch({error, {http, 403, _}},
            pertisk_eproxy_dns_digitalocean:create_txt(?TOKEN, ?ZONE, ?RECORD, ?TXT))
    end).

digitalocean_delete_http_status_error_test() ->
    with_httpc_status_error(delete, 403, fun() ->
        ?assertMatch({error, {http, 403, _}},
            pertisk_eproxy_dns_digitalocean:delete_txt(?TOKEN, ?ZONE, 42))
    end).

digitalocean_resolve_domain_not_found_alt_error_shape_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, _, _, _) ->
        {error, {http, 404, <<"missing">>}}
    end),
    try
        ?assertMatch({error, domain_not_found},
            pertisk_eproxy_dns_digitalocean:resolve_domain(?TOKEN, undefined, <<"missing.example.com">>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

cloudflare_global_key_missing_email_test() ->
    ?assertMatch({error, {zone_lookup, {error, missing_api_email}}},
        pertisk_eproxy_dns_cloudflare:find_zone({global_key, ?TOKEN, <<>>}, ?ZONE)).

cloudflare_global_key_empty_api_key_test() ->
    ?assertMatch({error, {zone_lookup, {error, invalid_api_token_format}}},
        pertisk_eproxy_dns_cloudflare:find_zone({global_key, <<>>, <<"a@b.com">>}, ?ZONE)).

cloudflare_token_or_key_auth_test() ->
    Auth = {token_or_key, ?TOKEN, <<"a@b.com">>},
    with_httpc_mock(fun() ->
        ?assertMatch({ok, #{zone_id := <<"z1">>}},
            pertisk_eproxy_dns_cloudflare:find_zone(Auth, <<"www.", ?ZONE/binary>>))
    end).

cloudflare_redacted_plain_token_test() ->
    ?assertMatch({error, {zone_lookup, {error, redacted_api_token_placeholder}}},
        pertisk_eproxy_dns_cloudflare:find_zone(<<"redacted">>, ?ZONE)).

cloudflare_authorization_prefix_token_test() ->
    Token = <<"Authorization: Bearer ", ?TOKEN/binary>>,
    with_httpc_mock(fun() ->
        ?assertMatch({ok, #{zone_id := <<"z1">>}},
            pertisk_eproxy_dns_cloudflare:find_zone(Token, <<"www.", ?ZONE/binary>>))
    end).

cloudflare_quoted_bearer_token_test() ->
    Token = <<$", ?TOKEN/binary, $">>,
    with_httpc_mock(fun() ->
        ?assertMatch({ok, #{zone_id := <<"z1">>}},
            pertisk_eproxy_dns_cloudflare:find_zone(Token, <<"www.", ?ZONE/binary>>))
    end).

cloudflare_cf_txt_record_suffix_mismatch_test() ->
    ?assertEqual(<<"other.example">>,
        pertisk_eproxy_dns_cloudflare:cf_txt_record_name(<<"other.example">>, ?ZONE)).

cloudflare_token_or_key_6111_retry_success_test() ->
    Auth = {token_or_key, ?TOKEN, <<"a@b.com">>},
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, Hdr}, _, _) ->
        case lists:keymember("X-Auth-Key", 1, Hdr) of
            true ->
                cloudflare_get(list_to_binary(U));
            false ->
                {ok, {{'HTTP/1.1', 400, 'Bad Request'}, [], <<"{\"code\":6111}">>}}
        end
    end),
    try
        ?assertMatch({ok, #{zone_id := <<"z1">>}},
            pertisk_eproxy_dns_cloudflare:find_zone(Auth, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

cloudflare_token_or_key_6111_retry_also_fails_test() ->
    Auth = {token_or_key, ?TOKEN, <<"a@b.com">>},
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(_, _, _, _) ->
        {ok, {{'HTTP/1.1', 400, 'Bad Request'}, [], <<"{\"code\":6111}">>}}
    end),
    try
        ?assertMatch({error, {zone_lookup, {error, invalid_cloudflare_auth_header}}},
            pertisk_eproxy_dns_cloudflare:find_zone(Auth, <<"www.", ?ZONE/binary>>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

cloudflare_find_zone_http_error_last_candidate_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(get, {U, _}, _, _) ->
        case binary:match(list_to_binary(U), <<"api.cloudflare.com/client/v4/zones">>) of
            nomatch -> {error, not_found};
            _ -> {error, timeout}
        end
    end),
    try
        ?assertMatch({error, {zone_lookup, {error, timeout}}},
            pertisk_eproxy_dns_cloudflare:find_zone(?TOKEN, <<"missing.example.com">>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

cloudflare_delete_unexpected_response_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(delete, _, _, _) ->
        json_ok(#{<<"result">> => true})
    end),
    try
        ?assertMatch({error, {unexpected, _}},
            pertisk_eproxy_dns_cloudflare:delete_txt(?TOKEN, <<"z1">>, <<"rec1">>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

cloudflare_create_txt_json_decode_error_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(post, _, _, _) ->
        {ok, {{'HTTP/1.1', 200, 'OK'}, [], "not-json"}}
    end),
    try
        ?assertMatch({error, {json, _}},
            pertisk_eproxy_dns_cloudflare:create_txt(?TOKEN, <<"z1">>, ?RECORD, ?TXT, <<"acme">>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

cloudflare_find_existing_txt_lookup_failed_test() ->
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun(Method, Req, Opts, HttpOpts) ->
        M = normalize_method(Method),
        U = url(M, Req),
        case M of
            post -> cloudflare_duplicate_post(U);
            get ->
                case binary:match(U, <<"dns_records?type=TXT">>) of
                    nomatch -> cloudflare_get(U);
                    _ -> {error, timeout}
                end;
            _ -> dns_http(M, Req, Opts, HttpOpts)
        end
    end),
    try
        ?assertMatch({error, {cloudflare, _}},
            pertisk_eproxy_dns_cloudflare:create_txt(?TOKEN, <<"z1">>, ?RECORD, ?TXT, <<"acme">>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([httpc])
    end.

cloudflare_invalid_token_logs_shape_test() ->
    ?assertMatch({error, {zone_lookup, {error, invalid_api_token_format}}},
        pertisk_eproxy_dns_cloudflare:find_zone(<<"Bearer ">>, <<"example.com">>)).
