-module(pertisk_eproxy_acme_dns_tests).

-include_lib("eunit/include/eunit.hrl").

%% ---------------------------------------------------------------------------
%% gen_server lifecycle (exported callbacks)
%% ---------------------------------------------------------------------------

init_returns_empty_state_test() ->
    ?assertMatch({ok, #{}}, pertisk_eproxy_acme_dns:init([])).

schedule_scan_without_server_is_ok_test() ->
    case whereis(pertisk_eproxy_acme_dns) of
        undefined -> ok;
        Pid -> unlink(Pid), exit(Pid, shutdown)
    end,
    ?assertEqual(ok, pertisk_eproxy_acme_dns:schedule_scan()).

%% ---------------------------------------------------------------------------
%% validate_dns_provider/2 — provider type normalization
%% ---------------------------------------------------------------------------

provider_type_atom_test() ->
    ?assertMatch(
        {error, missing_api_token},
        pertisk_eproxy_acme_dns:validate_dns_provider(cloudflare, #{})
    ).

provider_type_list_test() ->
    ?assertMatch(
        {error, missing_api_token},
        pertisk_eproxy_acme_dns:validate_dns_provider("digitalocean", #{})
    ).

digitalocean_do_alias_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"do">>,
        #{<<"api_token">> => <<"secret">>}
    ),
    ?assertMatch({ok, #{provider := <<"digitalocean">>}}, Result).

customlego_lego_alias_test() ->
    ?assertMatch(
        {error, missing_lego_provider},
        pertisk_eproxy_acme_dns:validate_dns_provider(<<"lego">>, #{})
    ).

provider_type_trims_whitespace_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"  cloudflare  ">>,
        #{<<"api_token">> => <<"tok">>}
    ),
    ?assertMatch({ok, #{provider := <<"cloudflare">>}}, Result).

provider_type_normalizes_dashes_underscores_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"cloud_flare">>,
        #{<<"api_token">> => <<"tok">>}
    ),
    ?assertMatch({ok, #{provider := <<"cloudflare">>}}, Result).

gcloud_alias_delegates_to_lego_test() ->
    case pertisk_eproxy_acme_dns:validate_dns_provider(<<"gcloud">>, #{}) of
        {error, lego_not_found} -> ok;
        {error, missing_project_id} -> ok;
        {error, _} -> ok;
        {ok, #{mode := <<"lego">>}} -> ok
    end.

%% ---------------------------------------------------------------------------
%% validate_dns_provider/2 — credential normalization helpers
%% ---------------------------------------------------------------------------

camel_case_credential_keys_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"digitalocean">>,
        #{<<"apiToken">> => <<"secret">>}
    ),
    ?assertMatch({ok, #{provider := <<"digitalocean">>}}, Result).

redacted_placeholder_treated_as_missing_test() ->
    ?assertMatch(
        {error, missing_api_token},
        pertisk_eproxy_acme_dns:validate_dns_provider(
            <<"cloudflare">>,
            #{<<"api_token">> => <<"[redacted]">>}
        )
    ).

empty_string_credential_treated_as_missing_test() ->
    ?assertMatch(
        {error, missing_api_token},
        pertisk_eproxy_acme_dns:validate_dns_provider(
            <<"vultr">>,
            #{<<"api_token">> => <<>>}
        )
    ).

cloudflare_token_only_ok_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"cloudflare">>,
        #{<<"api_token">> => <<"cf-token">>}
    ),
    ?assertMatch({ok, #{provider := <<"cloudflare">>}}, Result).

cloudflare_global_key_requires_email_test() ->
    ?assertMatch(
        {error, missing_api_email},
        pertisk_eproxy_acme_dns:validate_dns_provider(
            <<"cloudflare">>,
            #{<<"api_key">> => <<"key-only">>}
        )
    ).

cloudflare_global_key_with_email_ok_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"cloudflare">>,
        #{<<"api_key">> => <<"key">>, <<"email">> => <<"a@b.com">>}
    ),
    ?assertMatch({ok, #{provider := <<"cloudflare">>}}, Result).

customlego_with_provider_name_test() ->
    case pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"customlego">>,
        #{<<"lego_provider">> => <<"route53">>}
    ) of
        {error, lego_not_found} -> ok;
        {error, _} -> ok;
        {ok, #{mode := <<"lego">>}} -> ok
    end.

duckdns_missing_domain_test() ->
    ?assertMatch(
        {error, missing_domain},
        pertisk_eproxy_acme_dns:validate_dns_provider(<<"duckdns">>, #{<<"token">> => <<"t">>})
    ).

duckdns_missing_token_test() ->
    ?assertMatch(
        {error, missing_token},
        pertisk_eproxy_acme_dns:validate_dns_provider(<<"duckdns">>, #{<<"domain">> => <<"sub">>})
    ).

porkbun_missing_secret_key_test() ->
    ?assertMatch(
        {error, missing_secret_api_key},
        pertisk_eproxy_acme_dns:validate_dns_provider(
            <<"porkbun">>,
            #{<<"api_key">> => <<"only-key">>}
        )
    ).

powerdns_missing_api_key_test() ->
    ?assertMatch(
        {error, missing_api_key},
        pertisk_eproxy_acme_dns:validate_dns_provider(
            <<"powerdns">>,
            #{<<"api_url">> => <<"http://127.0.0.1:8081">>}
        )
    ).

vultr_accepts_api_key_alias_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"vultr">>,
        #{<<"api_key">> => <<"secret">>}
    ),
    ?assertMatch({ok, #{provider := <<"vultr">>}}, Result).

linode_requires_token_test() ->
    ?assertMatch(
        {error, missing_api_token},
        pertisk_eproxy_acme_dns:validate_dns_provider(<<"linode">>, #{})
    ).

hetzner_requires_token_test() ->
    ?assertMatch(
        {error, missing_api_token},
        pertisk_eproxy_acme_dns:validate_dns_provider(<<"hetzner">>, #{})
    ).

desec_requires_token_test() ->
    ?assertMatch(
        {error, missing_api_token},
        pertisk_eproxy_acme_dns:validate_dns_provider(<<"desec">>, #{})
    ).

gandi_requires_token_test() ->
    ?assertMatch(
        {error, missing_api_token},
        pertisk_eproxy_acme_dns:validate_dns_provider(<<"gandi">>, #{})
    ).

godaddy_delegates_to_lego_test() ->
    case pertisk_eproxy_acme_dns:validate_dns_provider(<<"godaddy">>, #{}) of
        {error, lego_not_found} -> ok;
        {error, _} -> ok;
        {ok, #{mode := <<"lego">>, provider := <<"godaddy">>}} -> ok
    end.

handle_call_unknown_returns_error_test() ->
    case whereis(pertisk_eproxy_acme_dns) of
        undefined ->
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                ?assertMatch({error, unknown_call}, gen_server:call(Pid, foo, 1000))
            after
                catch gen_server:stop(Pid, normal, 5000)
            end;
        Pid ->
            ?assertMatch({error, unknown_call}, gen_server:call(Pid, foo, 1000))
    end.
