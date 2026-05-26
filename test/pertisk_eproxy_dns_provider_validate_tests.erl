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