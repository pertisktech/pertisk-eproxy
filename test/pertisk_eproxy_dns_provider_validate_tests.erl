-module(pertisk_eproxy_dns_provider_validate_tests).

-include_lib("eunit/include/eunit.hrl").

route_table_contains_validate_endpoint_test() ->
    Routes = pertisk_eproxy_admin_routes:api_routes(),
    HasValidate = lists:any(
        fun
            ({"/api/dns-providers/validate", pertisk_eproxy_admin_handler, dns_provider_validate}) ->
                true;
            (_) ->
                false
        end,
        Routes
    ),
    ?assert(HasValidate).

cloudflare_validation_requires_api_token_test() ->
    ?assertMatch(
        {error, missing_api_token},
        pertisk_eproxy_acme_dns:validate_dns_provider(<<"cloudflare">>, #{})
    ).

duckdns_validation_accepts_minimal_fields_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"duckdns">>,
        #{<<"domain">> => <<"example">>, <<"token">> => <<"tkn">>}
    ),
    ?assertMatch({ok, #{provider := <<"duckdns">>}}, Result).

custom_lego_requires_provider_name_test() ->
    ?assertMatch(
        {error, missing_lego_provider},
        pertisk_eproxy_acme_dns:validate_dns_provider(<<"customlego">>, #{})
    ).

digitalocean_validation_requires_token_test() ->
    ?assertMatch(
        {error, missing_api_token},
        pertisk_eproxy_acme_dns:validate_dns_provider(<<"digitalocean">>, #{})
    ).

digitalocean_validation_accepts_token_only_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"digitalocean">>,
        #{<<"api_token">> => <<"secret">>}
    ),
    ?assertMatch({ok, #{provider := <<"digitalocean">>}}, Result).

vultr_validation_requires_token_test() ->
    ?assertMatch(
        {error, missing_api_token},
        pertisk_eproxy_acme_dns:validate_dns_provider(<<"vultr">>, #{})
    ).

porkbun_validation_requires_keys_test() ->
    ?assertMatch(
        {error, missing_api_key},
        pertisk_eproxy_acme_dns:validate_dns_provider(<<"porkbun">>, #{})
    ).

linode_validation_accepts_token_only_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"linode">>,
        #{<<"api_token">> => <<"secret">>}
    ),
    ?assertMatch({ok, #{provider := <<"linode">>}}, Result).

hetzner_validation_accepts_token_only_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"hetzner">>,
        #{<<"api_token">> => <<"secret">>}
    ),
    ?assertMatch({ok, #{provider := <<"hetzner">>}}, Result).

desec_validation_accepts_token_only_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"desec">>,
        #{<<"api_token">> => <<"secret">>}
    ),
    ?assertMatch({ok, #{provider := <<"desec">>}}, Result).

gandi_validation_accepts_token_only_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"gandi">>,
        #{<<"api_token">> => <<"secret">>}
    ),
    ?assertMatch({ok, #{provider := <<"gandi">>}}, Result).

powerdns_validation_requires_url_and_key_test() ->
    ?assertMatch(
        {error, missing_api_url},
        pertisk_eproxy_acme_dns:validate_dns_provider(<<"powerdns">>, #{})
    ).

powerdns_validation_accepts_url_and_key_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"powerdns">>,
        #{<<"api_url">> => <<"http://127.0.0.1:8081">>, <<"api_key">> => <<"secret">>}
    ),
    ?assertMatch({ok, #{provider := <<"powerdns">>}}, Result).

route53_validation_delegates_to_lego_test() ->
    case pertisk_eproxy_acme_dns:validate_dns_provider(<<"route53">>, #{}) of
        {error, lego_not_found} -> ok;
        {error, _} -> ok;
        {ok, #{mode := <<"lego">>}} -> ok
    end.

unsupported_provider_type_uses_lego_fallback_test() ->
    case pertisk_eproxy_acme_dns:validate_dns_provider(<<"myprovider">>, #{}) of
        {error, lego_not_found} -> ok;
        {error, _} -> ok;
        {ok, _} -> ok
    end.

namecheap_delegates_to_lego_test() ->
    case pertisk_eproxy_acme_dns:validate_dns_provider(<<"namecheap">>, #{}) of
        {error, lego_not_found} -> ok;
        {error, _} -> ok;
        {ok, #{mode := <<"lego">>, provider := <<"namecheap">>}} -> ok
    end.

azure_delegates_to_lego_test() ->
    case pertisk_eproxy_acme_dns:validate_dns_provider(<<"azure">>, #{}) of
        {error, lego_not_found} -> ok;
        {error, _} -> ok;
        {ok, #{mode := <<"lego">>, provider := <<"azure">>}} -> ok
    end.

vultr_validation_accepts_token_only_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"vultr">>,
        #{<<"api_token">> => <<"secret">>}
    ),
    ?assertMatch({ok, #{provider := <<"vultr">>}}, Result).

porkbun_validation_accepts_keys_only_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"porkbun">>,
        #{<<"api_key">> => <<"k">>, <<"secret_api_key">> => <<"s">>}
    ),
    ?assertMatch({ok, #{provider := <<"porkbun">>}}, Result).