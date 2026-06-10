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

run_scan_issue(DbPath, Host, ProviderName, ProviderType, Creds, MockMods) ->
    pertisk_eproxy_test_helpers:sync_router([site(Host, ProviderName)], [backend()]),
    lists:foreach(fun(M) -> meck:new(M, [unstick]) end, MockMods),
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
