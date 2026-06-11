-module(pertisk_eproxy_acme_dns_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SCAN_SLEEP_MS, 900).

stop_acme_dns() ->
    case whereis(pertisk_eproxy_acme_dns) of
        undefined -> ok;
        Pid -> catch gen_server:stop(Pid, normal, 5000)
    end.

mock_acme_client_ok() ->
    meck:new(pertisk_eproxy_acme_client, [unstick]),
    meck:expect(pertisk_eproxy_acme_client, obtain_certificate, fun(_) ->
        {ok, <<"-----BEGIN CERTIFICATE-----\nX\n-----END CERTIFICATE-----">>, <<"kid-url">>}
    end).

mock_acme_client_error(Err) ->
    meck:new(pertisk_eproxy_acme_client, [unstick]),
    meck:expect(pertisk_eproxy_acme_client, obtain_certificate, fun(_) -> {error, Err} end).

site(Host, Provider) ->
    #{
        host => Host,
        backend => <<"web">>,
        challenge_type => "dns-01",
        dns_provider => Provider,
        acme_contact_email => <<"ops@example.com">>,
        routes => []
    }.

backend() ->
    #{
        name => <<"web">>,
        algorithm => round_robin,
        upstreams => [#{addr => <<"127.0.0.1:9">>, weight => 1}]
    }.

with_scan_env(Fun) ->
    pertisk_eproxy_test_helpers:ensure_config(),
    OldTerms = application:get_env(pertisk_eproxy, acme_terms_agreed),
    OldAcmeDir = application:get_env(pertisk_eproxy, acme_data_dir),
    OldDb = application:get_env(pertisk_eproxy, db_file),
    application:set_env(pertisk_eproxy, acme_terms_agreed, true),
    AcmeDir = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "pertisk-acme-" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = file:make_dir(AcmeDir),
    application:set_env(pertisk_eproxy, acme_data_dir, AcmeDir),
    DbPath = pertisk_eproxy_test_helpers:tmp_db(),
    file:delete(DbPath),
    application:set_env(pertisk_eproxy, db_file, DbPath),
    try
        ?assertMatch({ok, _}, pertisk_eproxy_db:init(DbPath)),
        Fun(#{db => DbPath, acme_dir => AcmeDir})
    after
        stop_acme_dns(),
        case OldDb of
            {ok, DbVal} -> application:set_env(pertisk_eproxy, db_file, DbVal);
            undefined -> application:unset_env(pertisk_eproxy, db_file)
        end,
        case OldTerms of
            {ok, TermsVal} -> application:set_env(pertisk_eproxy, acme_terms_agreed, TermsVal);
            undefined -> application:unset_env(pertisk_eproxy, acme_terms_agreed)
        end,
        case OldAcmeDir of
            {ok, DirVal} -> application:set_env(pertisk_eproxy, acme_data_dir, DirVal);
            undefined -> application:unset_env(pertisk_eproxy, acme_data_dir)
        end,
        _ = os:cmd("rm -rf " ++ AcmeDir),
        file:delete(DbPath)
    end.

run_scan_issue(DbPath, Host, ProviderName, ProviderType, Creds, MockMods, SetupFun) ->
    pertisk_eproxy_test_helpers:sync_router([site(Host, ProviderName)], [backend()]),
    lists:foreach(fun(M) -> meck:new(M, [unstick]) end, MockMods),
    SetupFun(),
    mock_acme_client_ok(),
    try
        {ok, _} = pertisk_eproxy_db:insert_dns_provider(DbPath, ProviderName, ProviderType, Creds),
        stop_acme_dns(),
        {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
        try
            gen_server:cast(Pid, scan),
            timer:sleep(?SCAN_SLEEP_MS)
        after
            catch gen_server:stop(Pid, normal, 5000)
        end
    after
        meck:unload([pertisk_eproxy_acme_client | MockMods]),
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

mock_dns_cloudflare() ->
    meck:expect(pertisk_eproxy_dns_cloudflare, auth_diag, fun(_) -> <<"token">> end),
    meck:expect(pertisk_eproxy_dns_cloudflare, get_zone, fun(_, _) ->
        {ok, #{zone_id => <<"z">>, zone_name => <<"example.com">>}}
    end),
    meck:expect(pertisk_eproxy_dns_cloudflare, cf_txt_record_name, fun(Fqdn, _) -> Fqdn end),
    meck:expect(pertisk_eproxy_dns_cloudflare, create_txt, fun(_, _, _, _, _) -> {ok, <<"rid">>} end),
    meck:expect(pertisk_eproxy_dns_cloudflare, delete_txt, fun(_, _, _) -> ok end).

mock_dns_digitalocean() ->
    meck:expect(pertisk_eproxy_dns_digitalocean, resolve_domain, fun(_, _, _) ->
        {ok, <<"example.com">>}
    end),
    meck:expect(pertisk_eproxy_dns_digitalocean, txt_record_name, fun(Fqdn, _) -> Fqdn end),
    meck:expect(pertisk_eproxy_dns_digitalocean, create_txt, fun(_, _, _, _) -> {ok, 1} end),
    meck:expect(pertisk_eproxy_dns_digitalocean, delete_txt, fun(_, _, _) -> ok end).

mock_dns_vultr() ->
    meck:expect(pertisk_eproxy_dns_vultr, resolve_zone, fun(_, _, _) ->
        {ok, <<"example.com">>}
    end),
    meck:expect(pertisk_eproxy_dns_vultr, txt_record_name, fun(Fqdn, _) -> Fqdn end),
    meck:expect(pertisk_eproxy_dns_vultr, create_txt, fun(_, _, _, _) -> {ok, <<"rid">>} end),
    meck:expect(pertisk_eproxy_dns_vultr, delete_txt, fun(_, _, _) -> ok end).

mock_dns_porkbun() ->
    meck:expect(pertisk_eproxy_dns_porkbun, resolve_domain, fun(_, _, _, _) ->
        {ok, <<"example.com">>}
    end),
    meck:expect(pertisk_eproxy_dns_porkbun, txt_record_name, fun(Fqdn, _) -> Fqdn end),
    meck:expect(pertisk_eproxy_dns_porkbun, create_txt, fun(_, _, _, _, _) -> {ok, <<"rid">>} end),
    meck:expect(pertisk_eproxy_dns_porkbun, delete_txt, fun(_, _, _, _) -> ok end).

mock_dns_linode() ->
    meck:expect(pertisk_eproxy_dns_linode, resolve_domain, fun(_, _, _) ->
        {ok, #{id => 1, domain => <<"example.com">>}}
    end),
    meck:expect(pertisk_eproxy_dns_linode, txt_record_name, fun(Fqdn, _) -> Fqdn end),
    meck:expect(pertisk_eproxy_dns_linode, create_txt, fun(_, _, _, _) -> {ok, <<"rid">>} end),
    meck:expect(pertisk_eproxy_dns_linode, delete_txt, fun(_, _, _) -> ok end).

mock_dns_hetzner() ->
    meck:expect(pertisk_eproxy_dns_hetzner, resolve_zone, fun(_, _, _) ->
        {ok, #{zone_id => <<"z">>, zone_name => <<"example.com">>}}
    end),
    meck:expect(pertisk_eproxy_dns_hetzner, txt_record_name, fun(Fqdn, _) -> Fqdn end),
    meck:expect(pertisk_eproxy_dns_hetzner, create_txt, fun(_, _, _, _) -> {ok, <<"rid">>} end),
    meck:expect(pertisk_eproxy_dns_hetzner, delete_txt, fun(_, _, _) -> ok end).

mock_dns_desec() ->
    meck:expect(pertisk_eproxy_dns_desec, resolve_domain, fun(_, _, _) ->
        {ok, <<"example.com">>}
    end),
    meck:expect(pertisk_eproxy_dns_desec, txt_record_name, fun(Fqdn, _) -> Fqdn end),
    meck:expect(pertisk_eproxy_dns_desec, create_txt, fun(_, _, _, _) ->
        {ok, {desec, <<"tok">>, <<"example.com">>, <<"_acme-challenge">>}}
    end),
    meck:expect(pertisk_eproxy_dns_desec, delete_txt, fun(_, _, _) -> ok end).

mock_dns_gandi() ->
    meck:expect(pertisk_eproxy_dns_gandi, resolve_domain, fun(_, _, _) ->
        {ok, <<"example.com">>}
    end),
    meck:expect(pertisk_eproxy_dns_gandi, txt_record_name, fun(Fqdn, _) -> Fqdn end),
    meck:expect(pertisk_eproxy_dns_gandi, create_txt, fun(_, _, _, _) ->
        {ok, {gandi, <<"tok">>, <<"example.com">>, <<"_acme-challenge">>}}
    end),
    meck:expect(pertisk_eproxy_dns_gandi, delete_txt, fun(_, _, _) -> ok end).

mock_dns_powerdns() ->
    meck:expect(pertisk_eproxy_dns_powerdns, resolve_zone, fun(_, _, _, _, _) ->
        {ok, #{server_id => <<"localhost">>, zone_name => <<"example.com">>}}
    end),
    meck:expect(pertisk_eproxy_dns_powerdns, txt_record_name, fun(Fqdn, _) -> Fqdn end),
    meck:expect(pertisk_eproxy_dns_powerdns, create_txt, fun(_, _, _, _, _, _) ->
        {ok, {powerdns, <<"http://127.0.0.1:8081">>, <<"k">>, <<"localhost">>, <<"example.com">>, <<"_acme-challenge">>}}
    end),
    meck:expect(pertisk_eproxy_dns_powerdns, delete_txt, fun(_, _, _, _, _) -> ok end).

mock_dns_duckdns() ->
    meck:expect(pertisk_eproxy_dns_duckdns, create_txt, fun(_, _, _) ->
        {ok, {duckdns, <<"sub">>, <<"t">>}}
    end),
    meck:expect(pertisk_eproxy_dns_duckdns, delete_txt, fun(_, _) -> ok end).

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

gandi_domain_resolves_test() ->
    meck:new(pertisk_eproxy_dns_gandi, [unstick]),
    meck:expect(pertisk_eproxy_dns_gandi, resolve_domain, fun(_, _, _) ->
        {ok, <<"example.com">>}
    end),
    try
        Result = pertisk_eproxy_acme_dns:validate_dns_provider(
            <<"gandi">>,
            #{<<"api_token">> => <<"secret">>, <<"domain">> => <<"example.com">>}
        ),
        ?assertMatch({ok, #{provider := <<"gandi">>, domain := <<"example.com">>}}, Result)
    after
        meck:unload(pertisk_eproxy_dns_gandi)
    end.

desec_domain_resolves_test() ->
    meck:new(pertisk_eproxy_dns_desec, [unstick]),
    meck:expect(pertisk_eproxy_dns_desec, resolve_domain, fun(_, _, _) ->
        {ok, <<"example.com">>}
    end),
    try
        Result = pertisk_eproxy_acme_dns:validate_dns_provider(
            <<"desec">>,
            #{<<"api_token">> => <<"secret">>, <<"zone_name">> => <<"example.com">>}
        ),
        ?assertMatch({ok, #{provider := <<"desec">>, domain := <<"example.com">>}}, Result)
    after
        meck:unload(pertisk_eproxy_dns_desec)
    end.

hetzner_zone_resolves_test() ->
    meck:new(pertisk_eproxy_dns_hetzner, [unstick]),
    meck:expect(pertisk_eproxy_dns_hetzner, resolve_zone, fun(_, _, _) ->
        {ok, #{zone_name => <<"example.com">>}}
    end),
    try
        Result = pertisk_eproxy_acme_dns:validate_dns_provider(
            <<"hetzner">>,
            #{<<"api_token">> => <<"secret">>, <<"zone_name">> => <<"example.com">>}
        ),
        ?assertMatch({ok, #{provider := <<"hetzner">>, zone := <<"example.com">>}}, Result)
    after
        meck:unload(pertisk_eproxy_dns_hetzner)
    end.

linode_domain_resolves_test() ->
    meck:new(pertisk_eproxy_dns_linode, [unstick]),
    meck:expect(pertisk_eproxy_dns_linode, resolve_domain, fun(_, _, _) ->
        {ok, #{domain => <<"example.com">>}}
    end),
    try
        Result = pertisk_eproxy_acme_dns:validate_dns_provider(
            <<"linode">>,
            #{<<"api_token">> => <<"secret">>, <<"domain">> => <<"example.com">>}
        ),
        ?assertMatch({ok, #{provider := <<"linode">>, domain := <<"example.com">>}}, Result)
    after
        meck:unload(pertisk_eproxy_dns_linode)
    end.

digitalocean_domain_resolves_test() ->
    meck:new(pertisk_eproxy_dns_digitalocean, [unstick]),
    meck:expect(pertisk_eproxy_dns_digitalocean, resolve_domain, fun(_, _, _) ->
        {ok, <<"example.com">>}
    end),
    try
        Result = pertisk_eproxy_acme_dns:validate_dns_provider(
            <<"digitalocean">>,
            #{<<"api_token">> => <<"secret">>, <<"domain">> => <<"example.com">>}
        ),
        ?assertMatch({ok, #{provider := <<"digitalocean">>, domain := <<"example.com">>}}, Result)
    after
        meck:unload(pertisk_eproxy_dns_digitalocean)
    end.

vultr_zone_resolves_test() ->
    meck:new(pertisk_eproxy_dns_vultr, [unstick]),
    meck:expect(pertisk_eproxy_dns_vultr, resolve_zone, fun(_, _, _) ->
        {ok, <<"example.com">>}
    end),
    try
        Result = pertisk_eproxy_acme_dns:validate_dns_provider(
            <<"vultr">>,
            #{<<"api_token">> => <<"secret">>, <<"zone">> => <<"example.com">>}
        ),
        ?assertMatch({ok, #{provider := <<"vultr">>, zone := <<"example.com">>}}, Result)
    after
        meck:unload(pertisk_eproxy_dns_vultr)
    end.

vultr_api_key_alias_redacted_test() ->
    ?assertMatch(
        {error, missing_api_token},
        pertisk_eproxy_acme_dns:validate_dns_provider(
            <<"vultr">>,
            #{<<"api_key">> => <<"[redacted]">>}
        )
    ).

porkbun_only_secret_key_test() ->
    ?assertMatch(
        {error, missing_api_key},
        pertisk_eproxy_acme_dns:validate_dns_provider(
            <<"porkbun">>,
            #{<<"secret_api_key">> => <<"secret-only">>}
        )
    ).

porkbun_domain_resolves_test() ->
    meck:new(pertisk_eproxy_dns_porkbun, [unstick]),
    meck:expect(pertisk_eproxy_dns_porkbun, resolve_domain, fun(_, _, _, _) ->
        {ok, <<"example.com">>}
    end),
    try
        Result = pertisk_eproxy_acme_dns:validate_dns_provider(
            <<"porkbun">>,
            #{
                <<"api_key">> => <<"k">>,
                <<"secretApiKey">> => <<"s">>,
                <<"domain">> => <<"example.com">>}
        ),
        ?assertMatch({ok, #{provider := <<"porkbun">>, domain := <<"example.com">>}}, Result)
    after
        meck:unload(pertisk_eproxy_dns_porkbun)
    end.

cloudflare_invalid_zone_id_test() ->
    meck:new(pertisk_eproxy_dns_cloudflare, [unstick]),
    meck:expect(pertisk_eproxy_dns_cloudflare, get_zone, fun(_, _) ->
        {error, not_found}
    end),
    try
        ?assertMatch(
            {error, invalid_zone_id},
            pertisk_eproxy_acme_dns:validate_dns_provider(
                <<"cloudflare">>,
                #{<<"api_token">> => <<"tok">>, <<"zone_id">> => <<"bad-zone">>}
            )
        )
    after
        meck:unload(pertisk_eproxy_dns_cloudflare)
    end.

cloudflare_zone_id_resolves_test() ->
    meck:new(pertisk_eproxy_dns_cloudflare, [unstick]),
    meck:expect(pertisk_eproxy_dns_cloudflare, get_zone, fun(_, _) ->
        {ok, #{zone_name => <<"example.com">>}}
    end),
    try
        Result = pertisk_eproxy_acme_dns:validate_dns_provider(
            <<"cloudflare">>,
            #{<<"api_token">> => <<"tok">>, <<"zoneId">> => <<"zone-id">>}
        ),
        ?assertMatch({ok, #{provider := <<"cloudflare">>, zone_name := <<"example.com">>}}, Result)
    after
        meck:unload(pertisk_eproxy_dns_cloudflare)
    end.

provider_type_uppercase_normalizes_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"HETZNER">>,
        #{<<"api_token">> => <<"secret">>}
    ),
    ?assertMatch({ok, #{provider := <<"hetzner">>}}, Result).

ovh_delegates_to_lego_test() ->
    case pertisk_eproxy_acme_dns:validate_dns_provider(<<"ovh">>, #{}) of
        {error, lego_not_found} -> ok;
        {error, _} -> ok;
        {ok, #{mode := <<"lego">>, provider := <<"ovh">>}} -> ok
    end.

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

schedule_scan_with_running_server_test() ->
    case whereis(pertisk_eproxy_acme_dns) of
        undefined ->
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                ?assertEqual(ok, pertisk_eproxy_acme_dns:schedule_scan()),
                timer:sleep(50)
            after
                catch gen_server:stop(Pid, normal, 5000)
            end;
        _ ->
            ?assertEqual(ok, pertisk_eproxy_acme_dns:schedule_scan())
    end.

handle_info_scan_casts_scan_test() ->
    {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
    try
        ?assertEqual({noreply, #{}}, pertisk_eproxy_acme_dns:handle_info(scan, #{})),
        timer:sleep(50)
    after
        catch gen_server:stop(Pid, normal, 5000)
    end.

terminate_and_code_change_test() ->
    ?assertEqual(ok, pertisk_eproxy_acme_dns:terminate(normal, #{})),
    ?assertMatch({ok, #{}}, pertisk_eproxy_acme_dns:code_change(1, #{x => 1}, extra)).

route53_delegates_to_lego_test() ->
    case pertisk_eproxy_acme_dns:validate_dns_provider(<<"route53">>, #{}) of
        {error, lego_not_found} -> ok;
        {error, _} -> ok;
        {ok, #{mode := <<"lego">>, provider := <<"route53">>}} -> ok
    end.

namecheap_delegates_to_lego_test() ->
    case pertisk_eproxy_acme_dns:validate_dns_provider(<<"namecheap">>, #{}) of
        {error, lego_not_found} -> ok;
        {error, _} -> ok;
        {ok, #{mode := <<"lego">>}} -> ok
    end.

azure_delegates_to_lego_test() ->
    case pertisk_eproxy_acme_dns:validate_dns_provider(<<"azure">>, #{}) of
        {error, lego_not_found} -> ok;
        {error, _} -> ok;
        {ok, #{mode := <<"lego">>, provider := <<"azure">>}} -> ok
    end.

unsupported_provider_falls_back_to_lego_test() ->
    case pertisk_eproxy_acme_dns:validate_dns_provider(<<"exoticdns">>, #{}) of
        {error, lego_not_found} -> ok;
        {error, _} -> ok;
        {ok, #{mode := <<"lego">>}} -> ok
    end.

cloudflare_token_with_email_ok_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"cloudflare">>,
        #{<<"api_token">> => <<"tok">>, <<"email">> => <<"a@b.com">>}
    ),
    ?assertMatch({ok, #{provider := <<"cloudflare">>}}, Result).

powerdns_missing_api_url_test() ->
    ?assertMatch(
        {error, missing_api_url},
        pertisk_eproxy_acme_dns:validate_dns_provider(<<"powerdns">>, #{<<"api_key">> => <<"k">>})
    ).

powerdns_api_url_camel_case_ok_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"powerdns">>,
        #{<<"apiUrl">> => <<"http://127.0.0.1:8081">>, <<"apiKey">> => <<"secret">>}
    ),
    ?assertMatch({ok, #{provider := <<"powerdns">>}}, Result).

powerdns_zone_resolves_test() ->
    meck:new(pertisk_eproxy_dns_powerdns, [unstick]),
    meck:expect(pertisk_eproxy_dns_powerdns, resolve_zone, fun(_, _, _, _, _) ->
        {ok, #{zone_name => <<"example.com">>}}
    end),
    try
        Result = pertisk_eproxy_acme_dns:validate_dns_provider(
            <<"powerdns">>,
            #{
                <<"api_url">> => <<"http://127.0.0.1:8081">>,
                <<"api_key">> => <<"secret">>,
                <<"zone_name">> => <<"example.com">>}
        ),
        ?assertMatch({ok, #{provider := <<"powerdns">>, zone := <<"example.com">>}}, Result)
    after
        meck:unload(pertisk_eproxy_dns_powerdns)
    end.

duckdns_ok_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"duckdns">>,
        #{<<"domain">> => <<"sub">>, <<"token">> => <<"t">>}
    ),
    ?assertMatch({ok, #{provider := <<"duckdns">>}}, Result).

scan_terms_not_agreed_test() ->
    pertisk_eproxy_test_helpers:ensure_config(),
    OldTerms = application:get_env(pertisk_eproxy, acme_terms_agreed),
    application:set_env(pertisk_eproxy, acme_terms_agreed, false),
    Sites = [
        #{
            host => <<"terms.example">>,
            backend => <<"web">>,
            challenge_type => "dns-01",
            dns_provider => <<"cf">>,
            acme_contact_email => <<"ops@example.com">>,
            routes => []
        }
    ],
    Backends = [
        #{
            name => <<"web">>,
            algorithm => round_robin,
            upstreams => [#{addr => <<"127.0.0.1:9">>, weight => 1}]
        }
    ],
    pertisk_eproxy_test_helpers:sync_router(Sites, Backends),
    DbPath = pertisk_eproxy_test_helpers:tmp_db(),
    file:delete(DbPath),
    OldDb = application:get_env(pertisk_eproxy, db_file),
    application:set_env(pertisk_eproxy, db_file, DbPath),
    meck:new(pertisk_eproxy_dns_cloudflare, [unstick]),
    meck:expect(pertisk_eproxy_dns_cloudflare, auth_diag, fun(_) -> <<"token">> end),
    meck:expect(pertisk_eproxy_dns_cloudflare, get_zone, fun(_, _) ->
        {ok, #{zone_id => <<"z">>, zone_name => <<"example.com">>}}
    end),
    try
        ?assertMatch({ok, _}, pertisk_eproxy_db:init(DbPath)),
        {ok, _} = pertisk_eproxy_db:insert_dns_provider(
            DbPath,
            <<"cf">>,
            <<"cloudflare">>,
            #{<<"api_token">> => <<"secret">>, <<"zone_id">> => <<"zone-id">>}
        ),
        {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
        try
            gen_server:cast(Pid, scan),
            timer:sleep(500)
        after
            catch gen_server:stop(Pid, normal, 5000)
        end
    after
        meck:unload(pertisk_eproxy_dns_cloudflare),
        pertisk_eproxy_test_helpers:sync_router([], []),
        case OldDb of
            {ok, V} -> application:set_env(pertisk_eproxy, db_file, V);
            undefined -> application:unset_env(pertisk_eproxy, db_file)
        end,
        case OldTerms of
            {ok, TermsVal} -> application:set_env(pertisk_eproxy, acme_terms_agreed, TermsVal);
            undefined -> application:unset_env(pertisk_eproxy, acme_terms_agreed)
        end,
        file:delete(DbPath)
    end.

scan_missing_dns_provider_test() ->
    pertisk_eproxy_test_helpers:ensure_config(),
    Sites = [
        #{
            host => <<"missing-provider.example">>,
            backend => <<"web">>,
            challenge_type => "dns-01",
            dns_provider => <<"missing">>,
            acme_contact_email => <<"ops@example.com">>,
            routes => []
        }
    ],
    pertisk_eproxy_test_helpers:sync_router(Sites, []),
    DbPath = pertisk_eproxy_test_helpers:tmp_db(),
    file:delete(DbPath),
    OldDb = application:get_env(pertisk_eproxy, db_file),
    application:set_env(pertisk_eproxy, db_file, DbPath),
    try
        ?assertMatch({ok, _}, pertisk_eproxy_db:init(DbPath)),
        {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
        try
            gen_server:cast(Pid, scan),
            timer:sleep(200)
        after
            catch gen_server:stop(Pid, normal, 5000)
        end
    after
        pertisk_eproxy_test_helpers:sync_router([], []),
        case OldDb of
            {ok, V} -> application:set_env(pertisk_eproxy, db_file, V);
            undefined -> application:unset_env(pertisk_eproxy, db_file)
        end,
        file:delete(DbPath)
    end.

scan_mocked_successful_issue_test() ->
    pertisk_eproxy_test_helpers:ensure_config(),
    OldTerms = application:get_env(pertisk_eproxy, acme_terms_agreed),
    OldAcmeDir = application:get_env(pertisk_eproxy, acme_data_dir),
    application:set_env(pertisk_eproxy, acme_terms_agreed, true),
    AcmeDir = filename:join([os:getenv("TMPDIR", "/tmp"), "pertisk-acme-" ++ integer_to_list(erlang:unique_integer([positive]))]),
    ok = file:make_dir(AcmeDir),
    application:set_env(pertisk_eproxy, acme_data_dir, AcmeDir),
    Sites = [
        #{
            host => <<"issued.example">>,
            backend => <<"web">>,
            challenge_type => "dns-01",
            dns_provider => <<"cf">>,
            acme_contact_email => <<"ops@example.com">>,
            routes => []
        }
    ],
    Backends = [
        #{
            name => <<"web">>,
            algorithm => round_robin,
            upstreams => [#{addr => <<"127.0.0.1:9">>, weight => 1}]
        }
    ],
    pertisk_eproxy_test_helpers:sync_router(Sites, Backends),
    DbPath = pertisk_eproxy_test_helpers:tmp_db(),
    file:delete(DbPath),
    OldDb = application:get_env(pertisk_eproxy, db_file),
    application:set_env(pertisk_eproxy, db_file, DbPath),
    meck:new(pertisk_eproxy_acme_client, [unstick]),
    meck:expect(pertisk_eproxy_acme_client, obtain_certificate, fun(_) ->
        {ok, <<"-----BEGIN CERTIFICATE-----\nX\n-----END CERTIFICATE-----">>, <<"kid-url">>}
    end),
    meck:new(pertisk_eproxy_dns_cloudflare, [unstick]),
    meck:expect(pertisk_eproxy_dns_cloudflare, auth_diag, fun(_) -> <<"token">> end),
    meck:expect(pertisk_eproxy_dns_cloudflare, get_zone, fun(_, _) ->
        {ok, #{zone_id => <<"z">>, zone_name => <<"example.com">>}}
    end),
    meck:expect(pertisk_eproxy_dns_cloudflare, cf_txt_record_name, fun(Fqdn, _) -> Fqdn end),
    meck:expect(pertisk_eproxy_dns_cloudflare, create_txt, fun(_, _, _, _, _) -> {ok, <<"rid">>} end),
    meck:expect(pertisk_eproxy_dns_cloudflare, delete_txt, fun(_, _, _) -> ok end),
    try
        ?assertMatch({ok, _}, pertisk_eproxy_db:init(DbPath)),
        {ok, _} = pertisk_eproxy_db:insert_dns_provider(
            DbPath,
            <<"cf">>,
            <<"cloudflare">>,
            #{<<"api_token">> => <<"secret">>, <<"zone_id">> => <<"zone-id">>}
        ),
        {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
        try
            gen_server:cast(Pid, scan),
            timer:sleep(800)
        after
            catch gen_server:stop(Pid, normal, 5000)
        end
    after
        meck:unload([pertisk_eproxy_acme_client, pertisk_eproxy_dns_cloudflare]),
        pertisk_eproxy_test_helpers:sync_router([], []),
        case OldDb of
            {ok, DbVal} -> application:set_env(pertisk_eproxy, db_file, DbVal);
            undefined -> application:unset_env(pertisk_eproxy, db_file)
        end,
        case OldTerms of
            {ok, TermsVal} -> application:set_env(pertisk_eproxy, acme_terms_agreed, TermsVal);
            undefined -> application:unset_env(pertisk_eproxy, acme_terms_agreed)
        end,
        case OldAcmeDir of
            {ok, DirVal} -> application:set_env(pertisk_eproxy, acme_data_dir, DirVal);
            undefined -> application:unset_env(pertisk_eproxy, acme_data_dir)
        end,
        _ = os:cmd("rm -rf " ++ AcmeDir),
        file:delete(DbPath)
    end.

scan_triggers_with_configured_site_test() ->
    pertisk_eproxy_test_helpers:ensure_config(),
    Sites = [
        #{
            host => <<"acme-scan.example">>,
            backend => <<"web">>,
            challenge_type => "dns-01",
            dns_provider => <<"cf">>,
            acme_contact_email => <<"ops@example.com">>,
            routes => []
        }
    ],
    Backends = [
        #{
            name => <<"web">>,
            algorithm => round_robin,
            upstreams => [#{addr => <<"127.0.0.1:9">>, weight => 1}]
        }
    ],
    pertisk_eproxy_test_helpers:sync_router(Sites, Backends),
    DbPath = pertisk_eproxy_test_helpers:tmp_db(),
    file:delete(DbPath),
    OldDb = application:get_env(pertisk_eproxy, db_file),
    application:set_env(pertisk_eproxy, db_file, DbPath),
    try
        ?assertMatch({ok, _}, pertisk_eproxy_db:init(DbPath)),
        {ok, _} = pertisk_eproxy_db:insert_dns_provider(
            DbPath,
            <<"cf">>,
            <<"cloudflare">>,
            #{<<"api_token">> => <<"secret">>}
        ),
        {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
        try
            gen_server:cast(Pid, scan),
            timer:sleep(200)
        after
            catch gen_server:stop(Pid, normal, 5000)
        end
    after
        pertisk_eproxy_test_helpers:sync_router([], []),
        case OldDb of
            {ok, V} -> application:set_env(pertisk_eproxy, db_file, V);
            undefined -> application:unset_env(pertisk_eproxy, db_file)
        end,
        file:delete(DbPath)
    end.

%% ---------------------------------------------------------------------------
%% scan_and_issue/0 — mocked DNS provider issuance paths
%% ---------------------------------------------------------------------------

scan_cloudflare_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        run_scan_issue(
            DbPath,
            <<"cf-scan.example">>,
            <<"cf">>,
            <<"cloudflare">>,
            #{<<"api_token">> => <<"secret">>, <<"zone_id">> => <<"zone-id">>},
            [pertisk_eproxy_dns_cloudflare],
            fun mock_dns_cloudflare/0
        )
    end).

scan_digitalocean_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        run_scan_issue(
            DbPath,
            <<"do-scan.example">>,
            <<"do">>,
            <<"digitalocean">>,
            #{<<"api_token">> => <<"secret">>},
            [pertisk_eproxy_dns_digitalocean],
            fun mock_dns_digitalocean/0
        )
    end).

scan_vultr_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        run_scan_issue(
            DbPath,
            <<"vultr-scan.example">>,
            <<"vultr">>,
            <<"vultr">>,
            #{<<"api_token">> => <<"secret">>},
            [pertisk_eproxy_dns_vultr],
            fun mock_dns_vultr/0
        )
    end).

scan_porkbun_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        run_scan_issue(
            DbPath,
            <<"pb-scan.example">>,
            <<"pb">>,
            <<"porkbun">>,
            #{<<"api_key">> => <<"k">>, <<"secret_api_key">> => <<"s">>},
            [pertisk_eproxy_dns_porkbun],
            fun mock_dns_porkbun/0
        )
    end).

scan_linode_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        run_scan_issue(
            DbPath,
            <<"linode-scan.example">>,
            <<"lin">>,
            <<"linode">>,
            #{<<"api_token">> => <<"secret">>},
            [pertisk_eproxy_dns_linode],
            fun mock_dns_linode/0
        )
    end).

scan_hetzner_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        run_scan_issue(
            DbPath,
            <<"hetzner-scan.example">>,
            <<"hz">>,
            <<"hetzner">>,
            #{<<"api_token">> => <<"secret">>},
            [pertisk_eproxy_dns_hetzner],
            fun mock_dns_hetzner/0
        )
    end).

scan_desec_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        run_scan_issue(
            DbPath,
            <<"desec-scan.example">>,
            <<"ds">>,
            <<"desec">>,
            #{<<"api_token">> => <<"secret">>},
            [pertisk_eproxy_dns_desec],
            fun mock_dns_desec/0
        )
    end).

scan_gandi_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        run_scan_issue(
            DbPath,
            <<"gandi-scan.example">>,
            <<"gn">>,
            <<"gandi">>,
            #{<<"api_token">> => <<"secret">>},
            [pertisk_eproxy_dns_gandi],
            fun mock_dns_gandi/0
        )
    end).

scan_powerdns_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        run_scan_issue(
            DbPath,
            <<"pdns-scan.example">>,
            <<"pdns">>,
            <<"powerdns">>,
            #{<<"api_url">> => <<"http://127.0.0.1:8081">>, <<"api_key">> => <<"secret">>},
            [pertisk_eproxy_dns_powerdns],
            fun mock_dns_powerdns/0
        )
    end).

scan_duckdns_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        run_scan_issue(
            DbPath,
            <<"sub.duckdns.org">>,
            <<"dd">>,
            <<"duckdns">>,
            #{<<"domain">> => <<"sub">>, <<"token">> => <<"t">>},
            [pertisk_eproxy_dns_duckdns],
            fun mock_dns_duckdns/0
        )
    end).
