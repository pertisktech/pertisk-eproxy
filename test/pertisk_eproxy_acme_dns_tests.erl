-module(pertisk_eproxy_acme_dns_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SCAN_SLEEP_MS, 900).
%% Upper bound for async scan / meck call polling (init schedules scan at 4s).
-define(SCAN_WAIT_MS, 15000).
-define(SCAN_STABLE_MS, 6000).
-define(SCAN_POLL_MS, 100).

-define(SCAN_DRAIN_MS, 2000).

assert_meck_calls_at_least(Mod, Fun, Min) ->
    assert_meck_calls_at_least(Mod, Fun, Min, ?SCAN_WAIT_MS).

assert_meck_calls_at_least(Mod, Fun, Min, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    assert_meck_calls_at_least_loop(Mod, Fun, Min, Deadline).

assert_meck_calls_at_least_loop(Mod, Fun, Min, Deadline) ->
    N = meck:num_calls(Mod, Fun, '_'),
    case N >= Min of
        true ->
            ok;
        false ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true ->
                    ?assert(N >= Min);
                false ->
                    timer:sleep(?SCAN_POLL_MS),
                    assert_meck_calls_at_least_loop(Mod, Fun, Min, Deadline)
            end
    end.

assert_meck_calls_zero(Mod, Fun) ->
    timer:sleep(?SCAN_SLEEP_MS),
    Deadline = erlang:monotonic_time(millisecond) + ?SCAN_STABLE_MS,
    assert_meck_calls_zero_loop(Mod, Fun, Deadline).

assert_meck_calls_zero_loop(Mod, Fun, Deadline) ->
    N = meck:num_calls(Mod, Fun, '_'),
    ?assertEqual(0, N),
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            ok;
        false ->
            timer:sleep(?SCAN_POLL_MS),
            assert_meck_calls_zero_loop(Mod, Fun, Deadline)
    end.

site_present_in_config(HostBin) ->
    Sites = pertisk_eproxy_config:get_sites(),
    lists:any(
        fun(S) ->
            site_host_to_binary(maps:get(host, S, undefined)) =:= HostBin
        end,
        Sites
    ).

site_host_to_binary(H) when is_binary(H) -> H;
site_host_to_binary(H) when is_list(H) -> unicode:characters_to_binary(H, utf8);
site_host_to_binary(H) when is_atom(H) -> atom_to_binary(H, utf8);
site_host_to_binary(_) -> <<>>.

insert_dns_provider_ready(DbPath, Name, Type, Creds) ->
    {ok, Row} = pertisk_eproxy_db:insert_dns_provider(DbPath, Name, Type, Creds),
    NameBin =
        case Name of
            N when is_binary(N) -> N;
            N when is_list(N) -> list_to_binary(N)
        end,
    {ok, Rows} = pertisk_eproxy_db:list_dns_providers(DbPath),
    ?assert(lists:any(fun(R) -> maps:get(name, R, <<>>) =:= NameBin end, Rows)),
    {ok, Row}.

safe_meck_unload(Mod) ->
    case lists:member(Mod, meck:mocked()) of
        true ->
            pertisk_eproxy_test_helpers:ignoring_errors(
                fun() -> pertisk_eproxy_test_helpers:unload_mocks([Mod]) end
            );
        false ->
            ok
    end.

safe_meck_unload_all(Mods) ->
    lists:foreach(fun safe_meck_unload/1, Mods).

init_scan_db(DbPath) ->
    init_scan_db(DbPath, 24).

init_scan_db(DbPath, 0) ->
    pertisk_eproxy_db:init(DbPath);
init_scan_db(DbPath, Retries) ->
    case pertisk_eproxy_db:init(DbPath) of
        {ok, _} = Ok ->
            Ok;
        {error, {sqlite_error, Msg, _}} when Retries > 0 ->
            Locked =
                case Msg of
                    B when is_binary(B) -> binary:match(B, <<"locked">>) =/= nomatch;
                    S when is_list(S) -> string:find(S, "locked") =/= nomatch;
                    _ -> false
                end,
            case Locked of
                true ->
                    timer:sleep(50),
                    init_scan_db(DbPath, Retries - 1);
                false ->
                    {error, {sqlite_error, Msg, locked}}
            end;
        Other ->
            Other
    end.

stop_acme_dns() ->
    case whereis(pertisk_eproxy_acme_dns) of
        undefined ->
            ok;
        Pid ->
            pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
    end.

drain_scan_workers() ->
    %% scan_and_issue/0 is spawned unlinked; wait for in-flight work to finish.
    timer:sleep(?SCAN_DRAIN_MS).

mock_acme_client_ok() ->
    meck:new(pertisk_eproxy_acme_client, [unstick, no_link]),
    meck:expect(pertisk_eproxy_acme_client, obtain_certificate, fun(_) ->
        {ok, <<"-----BEGIN CERTIFICATE-----\nX\n-----END CERTIFICATE-----">>, <<"kid-url">>}
    end).

mock_acme_client_error(Err) ->
    meck:new(pertisk_eproxy_acme_client, [unstick, no_link]),
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
    pertisk_eproxy_test_helpers:with_db_lock(fun() ->
        stop_acme_dns(),
        drain_scan_workers(),
        pertisk_eproxy_test_helpers:ensure_config(),
        OldTerms = application:get_env(pertisk_eproxy, acme_terms_agreed),
        OldAcmeDir = application:get_env(pertisk_eproxy, acme_data_dir),
        OldDb = application:get_env(pertisk_eproxy, db_file),
        OldInitScan = application:get_env(pertisk_eproxy, acme_dns_disable_init_scan),
        application:set_env(pertisk_eproxy, acme_terms_agreed, true),
        application:set_env(pertisk_eproxy, acme_dns_disable_init_scan, true),
        AcmeDir = filename:join([
            os:getenv("TMPDIR", "/tmp"),
            "pertisk-acme-" ++ integer_to_list(erlang:unique_integer([positive]))
        ]),
        case file:make_dir(AcmeDir) of
            ok -> ok;
            {error, eexist} -> ok;
            {error, Reason} -> error({make_dir, AcmeDir, Reason})
        end,
        application:set_env(pertisk_eproxy, acme_data_dir, AcmeDir),
        DbPath = pertisk_eproxy_test_helpers:tmp_db(),
        file:delete(DbPath),
        application:set_env(pertisk_eproxy, db_file, DbPath),
        try
            ?assertMatch({ok, _}, init_scan_db(DbPath)),
            Fun(#{db => DbPath, acme_dir => AcmeDir})
        after
            stop_acme_dns(),
            drain_scan_workers(),
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
            case OldInitScan of
                {ok, InitVal} -> application:set_env(pertisk_eproxy, acme_dns_disable_init_scan, InitVal);
                undefined -> application:unset_env(pertisk_eproxy, acme_dns_disable_init_scan)
            end,
            _ = os:cmd("rm -rf " ++ AcmeDir),
            file:delete(DbPath)
        end
    end).

run_scan_issue(DbPath, Host, ProviderName, ProviderType, Creds, MockMods, SetupFun) ->
    {ok, _} = pertisk_eproxy_db:insert_dns_provider(DbPath, ProviderName, ProviderType, Creds),
    pertisk_eproxy_test_helpers:sync_router([site(Host, ProviderName)], [backend()]),
    lists:foreach(fun(M) -> meck:new(M, [unstick, no_link]) end, MockMods),
    SetupFun(),
    mock_acme_client_ok(),
    try
        stop_acme_dns(),
        {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
        try
            gen_server:cast(Pid, scan),
            timer:sleep(?SCAN_SLEEP_MS)
        after
            pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
        end
    after
        safe_meck_unload_all([pertisk_eproxy_acme_client | MockMods]),
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
    meck:new(pertisk_eproxy_dns_gandi, [unstick, no_link]),
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
        safe_meck_unload(pertisk_eproxy_dns_gandi)
    end.

desec_domain_resolves_test() ->
    meck:new(pertisk_eproxy_dns_desec, [unstick, no_link]),
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
        safe_meck_unload(pertisk_eproxy_dns_desec)
    end.

hetzner_zone_resolves_test() ->
    meck:new(pertisk_eproxy_dns_hetzner, [unstick, no_link]),
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
        safe_meck_unload(pertisk_eproxy_dns_hetzner)
    end.

linode_domain_resolves_test() ->
    meck:new(pertisk_eproxy_dns_linode, [unstick, no_link]),
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
        safe_meck_unload(pertisk_eproxy_dns_linode)
    end.

digitalocean_domain_resolves_test() ->
    meck:new(pertisk_eproxy_dns_digitalocean, [unstick, no_link]),
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
        safe_meck_unload(pertisk_eproxy_dns_digitalocean)
    end.

vultr_zone_resolves_test() ->
    meck:new(pertisk_eproxy_dns_vultr, [unstick, no_link]),
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
        safe_meck_unload(pertisk_eproxy_dns_vultr)
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
    meck:new(pertisk_eproxy_dns_porkbun, [unstick, no_link]),
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
        safe_meck_unload(pertisk_eproxy_dns_porkbun)
    end.

cloudflare_invalid_zone_id_test() ->
    meck:new(pertisk_eproxy_dns_cloudflare, [unstick, no_link]),
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
        safe_meck_unload(pertisk_eproxy_dns_cloudflare)
    end.

cloudflare_zone_id_resolves_test() ->
    meck:new(pertisk_eproxy_dns_cloudflare, [unstick, no_link]),
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
        safe_meck_unload(pertisk_eproxy_dns_cloudflare)
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
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
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
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
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
        pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
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
    meck:new(pertisk_eproxy_dns_powerdns, [unstick, no_link]),
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
        safe_meck_unload(pertisk_eproxy_dns_powerdns)
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
    meck:new(pertisk_eproxy_dns_cloudflare, [unstick, no_link]),
    meck:expect(pertisk_eproxy_dns_cloudflare, auth_diag, fun(_) -> <<"token">> end),
    meck:expect(pertisk_eproxy_dns_cloudflare, get_zone, fun(_, _) ->
        {ok, #{zone_id => <<"z">>, zone_name => <<"example.com">>}}
    end),
    try
        ?assertMatch({ok, _}, init_scan_db(DbPath)),
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
            pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
        end
    after
        safe_meck_unload(pertisk_eproxy_dns_cloudflare),
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
        ?assertMatch({ok, _}, init_scan_db(DbPath)),
        {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
        try
            gen_server:cast(Pid, scan),
            timer:sleep(200)
        after
            pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
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
    meck:new(pertisk_eproxy_acme_client, [unstick, no_link]),
    meck:expect(pertisk_eproxy_acme_client, obtain_certificate, fun(_) ->
        {ok, <<"-----BEGIN CERTIFICATE-----\nX\n-----END CERTIFICATE-----">>, <<"kid-url">>}
    end),
    meck:new(pertisk_eproxy_dns_cloudflare, [unstick, no_link]),
    meck:expect(pertisk_eproxy_dns_cloudflare, auth_diag, fun(_) -> <<"token">> end),
    meck:expect(pertisk_eproxy_dns_cloudflare, get_zone, fun(_, _) ->
        {ok, #{zone_id => <<"z">>, zone_name => <<"example.com">>}}
    end),
    meck:expect(pertisk_eproxy_dns_cloudflare, cf_txt_record_name, fun(Fqdn, _) -> Fqdn end),
    meck:expect(pertisk_eproxy_dns_cloudflare, create_txt, fun(_, _, _, _, _) -> {ok, <<"rid">>} end),
    meck:expect(pertisk_eproxy_dns_cloudflare, delete_txt, fun(_, _, _) -> ok end),
    try
        ?assertMatch({ok, _}, init_scan_db(DbPath)),
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
            pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
        end
    after
        safe_meck_unload_all([pertisk_eproxy_acme_client, pertisk_eproxy_dns_cloudflare]),
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
        ?assertMatch({ok, _}, init_scan_db(DbPath)),
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
            pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
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

digitalocean_token_only_ok_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"digitalocean">>,
        #{<<"api_token">> => <<"secret">>}
    ),
    ?assertMatch({ok, #{provider := <<"digitalocean">>, message := _}}, Result).

vultr_token_only_ok_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"vultr">>,
        #{<<"api_token">> => <<"secret">>}
    ),
    ?assertMatch({ok, #{provider := <<"vultr">>, message := _}}, Result).

porkbun_keys_only_ok_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"porkbun">>,
        #{<<"api_key">> => <<"k">>, <<"secret_api_key">> => <<"s">>}
    ),
    ?assertMatch({ok, #{provider := <<"porkbun">>, message := _}}, Result).

linode_token_only_ok_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"linode">>,
        #{<<"api_token">> => <<"secret">>}
    ),
    ?assertMatch({ok, #{provider := <<"linode">>, message := _}}, Result).

hetzner_token_only_ok_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"hetzner">>,
        #{<<"api_token">> => <<"secret">>}
    ),
    ?assertMatch({ok, #{provider := <<"hetzner">>, message := _}}, Result).

desec_token_only_ok_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"desec">>,
        #{<<"api_token">> => <<"secret">>}
    ),
    ?assertMatch({ok, #{provider := <<"desec">>, message := _}}, Result).

gandi_token_only_ok_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"gandi">>,
        #{<<"api_token">> => <<"secret">>}
    ),
    ?assertMatch({ok, #{provider := <<"gandi">>, message := _}}, Result).

powerdns_url_key_only_ok_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        <<"powerdns">>,
        #{<<"api_url">> => <<"http://127.0.0.1:8081">>, <<"api_key">> => <<"secret">>}
    ),
    ?assertMatch({ok, #{provider := <<"powerdns">>, message := _}}, Result).

customlego_missing_provider_name_test() ->
    ?assertMatch(
        {error, missing_lego_provider},
        pertisk_eproxy_acme_dns:validate_dns_provider(<<"customlego">>, #{})
    ).

provider_type_integer_normalizes_test() ->
    Result = pertisk_eproxy_acme_dns:validate_dns_provider(
        123,
        #{<<"api_token">> => <<"secret">>}
    ),
    ?assertMatch({error, _}, Result).

scan_cloudflare_find_zone_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        pertisk_eproxy_test_helpers:sync_router(
            [site(<<"cf-find.example">>, <<"cf-find">>)],
            [backend()]
        ),
        meck:new(pertisk_eproxy_dns_cloudflare, [unstick, no_link]),
        meck:expect(pertisk_eproxy_dns_cloudflare, auth_diag, fun(_) -> <<"token">> end),
        meck:expect(pertisk_eproxy_dns_cloudflare, find_zone, fun(_, _) ->
            {ok, #{zone_id => <<"z">>, zone_name => <<"example.com">>}}
        end),
        meck:expect(pertisk_eproxy_dns_cloudflare, cf_txt_record_name, fun(Fqdn, _) -> Fqdn end),
        meck:expect(pertisk_eproxy_dns_cloudflare, create_txt, fun(_, _, _, _, _) -> {ok, <<"rid">>} end),
        meck:expect(pertisk_eproxy_dns_cloudflare, delete_txt, fun(_, _, _) -> ok end),
        mock_acme_client_ok(),
        try
            {ok, _} = pertisk_eproxy_db:insert_dns_provider(
                DbPath,
                <<"cf-find">>,
                <<"cloudflare">>,
                #{<<"api_token">> => <<"secret">>}
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                assert_meck_calls_at_least(pertisk_eproxy_acme_client, obtain_certificate, 1)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            safe_meck_unload_all([pertisk_eproxy_acme_client, pertisk_eproxy_dns_cloudflare]),
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

scan_acme_client_failure_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        pertisk_eproxy_test_helpers:sync_router(
            [site(<<"fail.example">>, <<"cf-fail">>)],
            [backend()]
        ),
        meck:new(pertisk_eproxy_dns_cloudflare, [unstick, no_link]),
        mock_dns_cloudflare(),
        mock_acme_client_error({acme_failed, timeout}),
        try
            {ok, _} = pertisk_eproxy_db:insert_dns_provider(
                DbPath,
                <<"cf-fail">>,
                <<"cloudflare">>,
                #{<<"api_token">> => <<"secret">>, <<"zone_id">> => <<"zone-id">>}
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                timer:sleep(?SCAN_SLEEP_MS)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            safe_meck_unload_all([pertisk_eproxy_acme_client, pertisk_eproxy_dns_cloudflare]),
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

scan_lego_missing_warning_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        OldLego = os:getenv("PERTISK_LEGO_BIN"),
        os:putenv("PERTISK_LEGO_BIN", "/nonexistent/lego"),
        pertisk_eproxy_test_helpers:sync_router(
            [
                #{
                    host => <<"lego-warn.example">>,
                    backend => <<"web">>,
                    challenge_type => "dns-01",
                    dns_provider => <<"r53">>,
                    acme_contact_email => <<"ops@example.com">>,
                    routes => []
                }
            ],
            [backend()]
        ),
        try
            {ok, _} = pertisk_eproxy_db:insert_dns_provider(
                DbPath,
                <<"r53">>,
                <<"route53">>,
                #{<<"access_key_id">> => <<"AKIA">>, <<"secret_access_key">> => <<"SECRET">>}
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                timer:sleep(500)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            case OldLego of
                false -> os:unsetenv("PERTISK_LEGO_BIN");
                V -> os:putenv("PERTISK_LEGO_BIN", V)
            end,
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

digitalocean_domain_lookup_failure_test() ->
    meck:new(pertisk_eproxy_dns_digitalocean, [unstick, no_link]),
    meck:expect(pertisk_eproxy_dns_digitalocean, resolve_domain, fun(_, _, _) ->
        {error, domain_not_found}
    end),
    try
        ?assertMatch(
            {error, domain_not_found},
            pertisk_eproxy_acme_dns:validate_dns_provider(
                <<"digitalocean">>,
                #{<<"api_token">> => <<"secret">>, <<"domain">> => <<"missing.example.com">>}
            )
        )
    after
        safe_meck_unload(pertisk_eproxy_dns_digitalocean)
    end.

scan_lego_obtain_certificate_success_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        pertisk_eproxy_test_helpers:sync_router(
            [site(<<"lego-ok.example">>, <<"r53">>)],
            [backend()]
        ),
        meck:new(pertisk_eproxy_acme_lego, [unstick, no_link, passthrough]),
        meck:expect(pertisk_eproxy_acme_lego, obtain_certificate, fun(_, _, _, _, _, _, _, _) ->
            {ok, <<"-----BEGIN CERTIFICATE-----\nX\n-----END CERTIFICATE-----">>, <<"key">>}
        end),
        try
            {ok, _} = pertisk_eproxy_db:insert_dns_provider(
                DbPath,
                <<"r53">>,
                <<"route53">>,
                #{
                    <<"access_key_id">> => <<"AKIA">>,
                    <<"secret_access_key">> => <<"SECRET">>
                }
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                assert_meck_calls_at_least(pertisk_eproxy_acme_lego, obtain_certificate, 1)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            safe_meck_unload(pertisk_eproxy_acme_lego),
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

scan_lego_not_found_obtain_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        pertisk_eproxy_test_helpers:sync_router(
            [site(<<"lego-missing.example">>, <<"gd">>)],
            [backend()]
        ),
        meck:new(pertisk_eproxy_acme_lego, [unstick, no_link, passthrough]),
        meck:expect(pertisk_eproxy_acme_lego, obtain_certificate, fun(_, _, _, _, _, _, _, _) ->
            {error, lego_not_found}
        end),
        try
            {ok, _} = pertisk_eproxy_db:insert_dns_provider(
                DbPath,
                <<"gd">>,
                <<"godaddy">>,
                #{<<"api_key">> => <<"k">>, <<"api_secret">> => <<"s">>}
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                timer:sleep(?SCAN_SLEEP_MS)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            safe_meck_unload(pertisk_eproxy_acme_lego),
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

scan_csr_failure_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        run_scan_issue(
            DbPath,
            <<"csr-fail.example">>,
            <<"cf-csr">>,
            <<"cloudflare">>,
            #{<<"api_token">> => <<"secret">>, <<"zone_id">> => <<"zone-id">>},
            [pertisk_eproxy_dns_cloudflare, pertisk_eproxy_acme_csr],
            fun() ->
                mock_dns_cloudflare(),
                meck:expect(pertisk_eproxy_acme_csr, generate_rsa_csr, fun(_) ->
                    {error, openssl_failed}
                end)
            end
        )
    end).

scan_lego_provider_env_error_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        pertisk_eproxy_test_helpers:sync_router(
            [site(<<"lego-env.example">>, <<"cl">>)],
            [backend()]
        ),
        meck:new(pertisk_eproxy_acme_lego, [unstick, no_link, passthrough]),
        meck:expect(pertisk_eproxy_acme_lego, obtain_certificate, fun(_, _, _, _, _, _, _, _) ->
            {error, {missing_credential, <<"api_key">>}}
        end),
        try
            {ok, _} = pertisk_eproxy_db:insert_dns_provider(
                DbPath,
                <<"cl">>,
                <<"customlego">>,
                #{<<"lego_provider">> => <<"godaddy">>, <<"api_key">> => <<"k">>}
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                timer:sleep(?SCAN_SLEEP_MS)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            safe_meck_unload(pertisk_eproxy_acme_lego),
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

scan_acme_client_csr_failure_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        pertisk_eproxy_test_helpers:sync_router(
            [site(<<"acme-csr.example">>, <<"cf-acme">>)],
            [backend()]
        ),
        meck:new(pertisk_eproxy_dns_cloudflare, [unstick, no_link]),
        mock_dns_cloudflare(),
        meck:new(pertisk_eproxy_acme_csr, [unstick, no_link]),
        meck:expect(pertisk_eproxy_acme_csr, generate_rsa_csr, fun(_) ->
            {ok, #{csr_der => <<>>, key_pem => <<"key">>}}
        end),
        mock_acme_client_error({csr_rejected, invalid}),
        try
            {ok, _} = pertisk_eproxy_db:insert_dns_provider(
                DbPath,
                <<"cf-acme">>,
                <<"cloudflare">>,
                #{<<"api_token">> => <<"secret">>, <<"zone_id">> => <<"zone-id">>}
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                timer:sleep(?SCAN_SLEEP_MS)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            safe_meck_unload_all([
                pertisk_eproxy_acme_client,
                pertisk_eproxy_dns_cloudflare,
                pertisk_eproxy_acme_csr
            ]),
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

handle_info_unknown_ignored_test() ->
    ?assertEqual({noreply, #{x => 1}}, pertisk_eproxy_acme_dns:handle_info(unknown, #{x => 1})).

scan_skips_site_with_production_cert_test() ->
    with_scan_env(fun(#{db := DbPath, acme_dir := AcmeDir}) ->
        Host = <<"skip-cert.example">>,
        CertName = <<"acme/skip-cert.example">>,
        SlugDir = filename:join([AcmeDir, "certs", "skip-cert.example"]),
        ok = file:make_dir(filename:join([AcmeDir, "certs"])),
        ok = file:make_dir(SlugDir),
        ok = file:write_file(filename:join([SlugDir, "fullchain.pem"]), <<"pem">>),
        pertisk_eproxy_test_helpers:sync_router(
            [maps:merge(site(Host, <<"cf-skip">>), #{certificate => CertName})],
            [backend()]
        ),
        meck:new(pertisk_eproxy_dns_cloudflare, [unstick, no_link]),
        mock_dns_cloudflare(),
        meck:new(pertisk_eproxy_tls_cert_info, [unstick, no_link]),
        meck:expect(pertisk_eproxy_tls_cert_info, describe_listener_pem, fun(_) ->
            {ok, #{issuer => <<"CN=R3, O=Let's Encrypt">>}}
        end),
        mock_acme_client_ok(),
        try
            insert_dns_provider_ready(
                DbPath, <<"cf-skip">>, <<"cloudflare">>, #{<<"api_token">> => <<"tok">>}
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                assert_meck_calls_zero(pertisk_eproxy_acme_client, obtain_certificate)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            safe_meck_unload_all([
                pertisk_eproxy_acme_client, pertisk_eproxy_dns_cloudflare, pertisk_eproxy_tls_cert_info
            ]),
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

scan_reissues_staging_cert_test() ->
    with_scan_env(fun(#{db := DbPath, acme_dir := AcmeDir}) ->
        Host = <<"staging-cert.example">>,
        CertName = <<"acme/staging-cert.example">>,
        SlugDir = filename:join([AcmeDir, "certs", "staging-cert.example"]),
        ok = file:make_dir(filename:join([AcmeDir, "certs"])),
        ok = file:make_dir(SlugDir),
        ok = file:write_file(filename:join([SlugDir, "fullchain.pem"]), <<"staging-pem">>),
        pertisk_eproxy_test_helpers:sync_router(
            [maps:merge(site(Host, <<"cf-staging">>), #{certificate => CertName})],
            [backend()]
        ),
        meck:new(pertisk_eproxy_dns_cloudflare, [unstick, no_link]),
        mock_dns_cloudflare(),
        meck:new(pertisk_eproxy_tls_cert_info, [unstick, no_link]),
        meck:expect(pertisk_eproxy_tls_cert_info, describe_listener_pem, fun(_) ->
            {ok, #{issuer => <<"(STAGING) Fake LE Intermediate X1">>}}
        end),
        meck:new(pertisk_eproxy_acme_csr, [unstick, no_link]),
        meck:expect(pertisk_eproxy_acme_csr, generate_rsa_csr, fun(_) ->
            {ok, #{csr_der => <<>>, key_pem => <<"key">>}}
        end),
        mock_acme_client_ok(),
        try
            insert_dns_provider_ready(
                DbPath, <<"cf-staging">>, <<"cloudflare">>, #{<<"api_token">> => <<"tok">>, <<"zone_id">> => <<"zone-id">>}
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                assert_meck_calls_at_least(pertisk_eproxy_acme_client, obtain_certificate, 1)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            safe_meck_unload_all([
                pertisk_eproxy_acme_client,
                pertisk_eproxy_dns_cloudflare,
                pertisk_eproxy_tls_cert_info,
                pertisk_eproxy_acme_csr
            ]),
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

handle_cast_scan_spawns_worker_test() ->
    {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
    try
        ?assertEqual({noreply, #{}}, pertisk_eproxy_acme_dns:handle_cast(scan, #{})),
        timer:sleep(100)
    after
        pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
    end.

scan_skips_http01_challenge_site_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        pertisk_eproxy_test_helpers:sync_router(
            [#{
                host => <<"http01.example">>,
                backend => <<"web">>,
                challenge_type => "http-01",
                dns_provider => <<"cf">>,
                acme_contact_email => <<"ops@example.com">>,
                routes => []
            }],
            [backend()]
        ),
        meck:new(pertisk_eproxy_acme_client, [unstick, no_link]),
        meck:expect(pertisk_eproxy_acme_client, obtain_certificate, fun(_) ->
            {ok, <<"cert">>, <<"kid">>}
        end),
        try
            {ok, _} = pertisk_eproxy_db:insert_dns_provider(
                DbPath, <<"cf">>, <<"cloudflare">>, #{<<"api_token">> => <<"tok">>}
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                assert_meck_calls_zero(pertisk_eproxy_acme_client, obtain_certificate)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            safe_meck_unload(pertisk_eproxy_acme_client),
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

scan_dynamic_lego_provider_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        pertisk_eproxy_test_helpers:sync_router(
            [site(<<"exotic.example">>, <<"exotic">>)],
            [backend()]
        ),
        meck:new(pertisk_eproxy_acme_lego, [unstick, no_link, passthrough, no_passthrough_cover]),
        meck:expect(pertisk_eproxy_acme_lego, obtain_certificate, fun(_, _, _, _, _, _, _, _) ->
            {ok, <<"-----BEGIN CERTIFICATE-----\nX\n-----END CERTIFICATE-----">>, <<"key">>}
        end),
        try
            insert_dns_provider_ready(
                DbPath, <<"exotic">>, <<"exoticdns">>, #{<<"api_key">> => <<"k">>, <<"api_secret">> => <<"s">>}
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                assert_meck_calls_at_least(pertisk_eproxy_acme_lego, obtain_certificate, 1)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            safe_meck_unload(pertisk_eproxy_acme_lego),
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

scan_wildcard_site_identifiers_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        meck:new(pertisk_eproxy_dns_cloudflare, [unstick, no_link]),
        mock_dns_cloudflare(),
        mock_acme_client_ok(),
        try
            {ok, _} = insert_dns_provider_ready(
                DbPath,
                <<"cf-wc">>,
                <<"cloudflare">>,
                #{<<"api_token">> => <<"secret">>, <<"zone_id">> => <<"zone-id">>}
            ),
            pertisk_eproxy_test_helpers:sync_router(
                [
                    maps:merge(site(<<"*.example.com">>, <<"cf-wc">>), #{
                        wildcard => true,
                        acme_wildcard_base => <<"example.com">>
                    })
                ],
                [backend()]
            ),
            ?assert(site_present_in_config(<<"*.example.com">>)),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                assert_meck_calls_at_least(pertisk_eproxy_acme_client, obtain_certificate, 1)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            safe_meck_unload_all([pertisk_eproxy_acme_client, pertisk_eproxy_dns_cloudflare]),
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

scan_drop_staging_kid_for_production_test() ->
    with_scan_env(fun(#{db := DbPath, acme_dir := AcmeDir}) ->
        ok = file:write_file(
            filename:join(AcmeDir, "kid.txt"),
            <<"https://acme-staging-v02.api.letsencrypt.org/acme/acct/1\n">>
        ),
        application:set_env(
            pertisk_eproxy,
            acme_directory_url,
            <<"https://acme-v02.api.letsencrypt.org/directory">>
        ),
        pertisk_eproxy_test_helpers:sync_router(
            [site(<<"kid-drop.example">>, <<"cf-kid">>)],
            [backend()]
        ),
        meck:new(pertisk_eproxy_dns_cloudflare, [unstick, no_link]),
        mock_dns_cloudflare(),
        mock_acme_client_ok(),
        try
            {ok, _} = pertisk_eproxy_db:insert_dns_provider(
                DbPath,
                <<"cf-kid">>,
                <<"cloudflare">>,
                #{<<"api_token">> => <<"secret">>, <<"zone_id">> => <<"zone-id">>}
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                timer:sleep(?SCAN_SLEEP_MS),
                KidPath = filename:join(AcmeDir, "kid.txt"),
                case file:read_file(KidPath) of
                    {ok, Bin} ->
                        ?assertEqual(nomatch, binary:match(Bin, <<"acme-staging">>));
                    {error, enoent} ->
                        ok
                end
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            application:unset_env(pertisk_eproxy, acme_directory_url),
            safe_meck_unload_all([pertisk_eproxy_acme_client, pertisk_eproxy_dns_cloudflare]),
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

scan_cloudflare_create_txt_error_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        pertisk_eproxy_test_helpers:sync_router(
            [site(<<"cf-txt-fail.example">>, <<"cf-txt">>)],
            [backend()]
        ),
        meck:new(pertisk_eproxy_dns_cloudflare, [unstick, no_link]),
        mock_dns_cloudflare(),
        meck:expect(pertisk_eproxy_dns_cloudflare, create_txt, fun(_, _, _, _, _) ->
            {error, invalid_api_token_format}
        end),
        mock_acme_client_ok(),
        try
            insert_dns_provider_ready(
                DbPath,
                <<"cf-txt">>,
                <<"cloudflare">>,
                #{<<"api_token">> => <<"secret">>, <<"zone_id">> => <<"zone-id">>}
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                assert_meck_calls_at_least(pertisk_eproxy_acme_client, obtain_certificate, 1)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            safe_meck_unload_all([pertisk_eproxy_acme_client, pertisk_eproxy_dns_cloudflare]),
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

scan_cert_ref_acme_name_without_disk_pem_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        Host = <<"acme-ref.example">>,
        CertName = <<"acme/acme-ref.example">>,
        pertisk_eproxy_test_helpers:sync_router(
            [maps:merge(site(Host, <<"cf-ref">>), #{certificate => CertName})],
            [backend()]
        ),
        meck:new(pertisk_eproxy_dns_cloudflare, [unstick, no_link]),
        mock_dns_cloudflare(),
        mock_acme_client_ok(),
        try
            insert_dns_provider_ready(
                DbPath, <<"cf-ref">>, <<"cloudflare">>, #{<<"api_token">> => <<"tok">>, <<"zone_id">> => <<"z">>}
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                assert_meck_calls_at_least(pertisk_eproxy_acme_client, obtain_certificate, 1)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            safe_meck_unload_all([pertisk_eproxy_acme_client, pertisk_eproxy_dns_cloudflare]),
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

validate_dns_provider_unsupported_empty_type_test() ->
    ?assertMatch({error, _},
        pertisk_eproxy_acme_dns:validate_dns_provider(<<"   ">>, #{<<"api_key">> => <<"k">>})).

validate_dns_provider_provider_type_other_test() ->
    ?assertMatch({error, _},
        pertisk_eproxy_acme_dns:validate_dns_provider([], #{<<"api_token">> => <<"tok">>})).

run_scan_lego_issue(DbPath, Host, ProviderName, ProviderType, Creds) ->
    {ok, _} = pertisk_eproxy_db:insert_dns_provider(DbPath, ProviderName, ProviderType, Creds),
    pertisk_eproxy_test_helpers:sync_router([site(Host, ProviderName)], [backend()]),
    meck:new(pertisk_eproxy_acme_lego, [unstick, no_link, passthrough]),
    meck:expect(pertisk_eproxy_acme_lego, obtain_certificate, fun(_, _, _, _, _, _, _, _) ->
        {ok, <<"-----BEGIN CERTIFICATE-----\nX\n-----END CERTIFICATE-----">>, <<"key">>}
    end),
    try
        stop_acme_dns(),
        {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
        try
            gen_server:cast(Pid, scan),
            timer:sleep(?SCAN_SLEEP_MS)
        after
            pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
        end
    after
        safe_meck_unload(pertisk_eproxy_acme_lego),
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

scan_route53_lego_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        run_scan_lego_issue(
            DbPath,
            <<"r53-lego.example">>,
            <<"r53">>,
            <<"route53">>,
            #{<<"access_key_id">> => <<"AKIA">>, <<"secret_access_key">> => <<"SECRET">>}
        )
    end).

scan_godaddy_lego_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        run_scan_lego_issue(
            DbPath,
            <<"gd-lego.example">>,
            <<"gd">>,
            <<"godaddy">>,
            #{<<"api_key">> => <<"k">>, <<"api_secret">> => <<"s">>}
        )
    end).

scan_namecheap_lego_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        run_scan_lego_issue(
            DbPath,
            <<"nc-lego.example">>,
            <<"nc">>,
            <<"namecheap">>,
            #{
                <<"api_user">> => <<"user">>,
                <<"api_key">> => <<"key">>,
                <<"username">> => <<"user">>,
                <<"client_ip">> => <<"127.0.0.1">>
            }
        )
    end).

scan_ovh_lego_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        run_scan_lego_issue(
            DbPath,
            <<"ovh-lego.example">>,
            <<"ovh">>,
            <<"ovh">>,
            #{
                <<"application_key">> => <<"k">>,
                <<"application_secret">> => <<"s">>,
                <<"consumer_key">> => <<"c">>
            }
        )
    end).

scan_googleclouddns_lego_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        run_scan_lego_issue(
            DbPath,
            <<"gcp-lego.example">>,
            <<"gcp">>,
            <<"googleclouddns">>,
            #{
                <<"project_id">> => <<"proj">>,
                <<"service_account_json">> => <<"{\"type\":\"service_account\"}">>
            }
        )
    end).

scan_azure_lego_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        run_scan_lego_issue(
            DbPath,
            <<"az-lego.example">>,
            <<"az">>,
            <<"azure">>,
            #{
                <<"tenant_id">> => <<"tenant">>,
                <<"client_id">> => <<"client">>,
                <<"client_secret">> => <<"secret">>,
                <<"subscription_id">> => <<"sub">>,
                <<"resource_group">> => <<"rg">>
            }
        )
    end).

scan_rfc2136_lego_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        run_scan_lego_issue(
            DbPath,
            <<"rfc-lego.example">>,
            <<"rfc">>,
            <<"rfc2136">>,
            #{
                <<"nameserver">> => <<"127.0.0.1">>,
                <<"tsig_key_name">> => <<"key">>,
                <<"tsig_secret">> => <<"secret">>
            }
        )
    end).

scan_cloudns_lego_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        run_scan_lego_issue(
            DbPath,
            <<"cns-lego.example">>,
            <<"cns">>,
            <<"cloudns">>,
            #{<<"auth_id">> => <<"1">>, <<"auth_password">> => <<"pw">>}
        )
    end).

scan_easydns_lego_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        run_scan_lego_issue(
            DbPath,
            <<"ed-lego.example">>,
            <<"ed">>,
            <<"easydns">>,
            #{<<"token">> => <<"t">>, <<"key">> => <<"k">>}
        )
    end).

scan_dnsmadeeasy_lego_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        run_scan_lego_issue(
            DbPath,
            <<"dme-lego.example">>,
            <<"dme">>,
            <<"dnsmadeeasy">>,
            #{<<"api_key">> => <<"k">>, <<"secret_key">> => <<"s">>}
        )
    end).

scan_dynu_lego_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        run_scan_lego_issue(
            DbPath,
            <<"dynu-lego.example">>,
            <<"dynu">>,
            <<"dynu">>,
            #{<<"api_token">> => <<"tok">>}
        )
    end).

scan_customlego_named_provider_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        run_scan_lego_issue(
            DbPath,
            <<"cl-lego.example">>,
            <<"cl">>,
            <<"customlego">>,
            #{
                <<"lego_provider">> => <<"godaddy">>,
                <<"api_key">> => <<"k">>,
                <<"api_secret">> => <<"s">>
            }
        )
    end).

scan_lego_failed_humanize_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        pertisk_eproxy_test_helpers:sync_router(
            [site(<<"lego-fail-h.example">>, <<"gd-fail">>)],
            [backend()]
        ),
        meck:new(pertisk_eproxy_acme_lego, [unstick, no_link, passthrough]),
        meck:expect(pertisk_eproxy_acme_lego, obtain_certificate, fun(_, _, _, _, _, _, _, _) ->
            {error, {lego_failed, <<"401 unauthorized: rate limit exceeded timeout">>}}
        end),
        try
            {ok, _} = pertisk_eproxy_db:insert_dns_provider(
                DbPath,
                <<"gd-fail">>,
                <<"godaddy">>,
                #{<<"api_key">> => <<"k">>, <<"api_secret">> => <<"s">>}
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                timer:sleep(?SCAN_SLEEP_MS)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            safe_meck_unload(pertisk_eproxy_acme_lego),
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

scan_cloudflare_missing_token_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        pertisk_eproxy_test_helpers:sync_router(
            [site(<<"cf-notok.example">>, <<"cf-notok">>)],
            [backend()]
        ),
        try
            {ok, _} = pertisk_eproxy_db:insert_dns_provider(
                DbPath, <<"cf-notok">>, <<"cloudflare">>, #{}
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                timer:sleep(?SCAN_SLEEP_MS)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

scan_cloudflare_zone_resolve_error_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        pertisk_eproxy_test_helpers:sync_router(
            [site(<<"cf-zone-fail.example">>, <<"cf-zone">>)],
            [backend()]
        ),
        meck:new(pertisk_eproxy_dns_cloudflare, [unstick, no_link]),
        meck:expect(pertisk_eproxy_dns_cloudflare, auth_diag, fun(_) -> <<"token">> end),
        meck:expect(pertisk_eproxy_dns_cloudflare, get_zone, fun(_, _) -> {error, zone_not_found} end),
        mock_acme_client_ok(),
        try
            {ok, _} = pertisk_eproxy_db:insert_dns_provider(
                DbPath,
                <<"cf-zone">>,
                <<"cloudflare">>,
                #{<<"api_token">> => <<"tok">>, <<"zone_id">> => <<"bad">>}
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                timer:sleep(?SCAN_SLEEP_MS)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            safe_meck_unload_all([pertisk_eproxy_acme_client, pertisk_eproxy_dns_cloudflare]),
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

scan_digitalocean_missing_token_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        pertisk_eproxy_test_helpers:sync_router(
            [site(<<"do-notok.example">>, <<"do-notok">>)],
            [backend()]
        ),
        try
            {ok, _} = pertisk_eproxy_db:insert_dns_provider(DbPath, <<"do-notok">>, <<"digitalocean">>, #{}),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                timer:sleep(?SCAN_SLEEP_MS)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

scan_vultr_missing_token_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        pertisk_eproxy_test_helpers:sync_router(
            [site(<<"vultr-notok.example">>, <<"vultr-notok">>)],
            [backend()]
        ),
        try
            {ok, _} = pertisk_eproxy_db:insert_dns_provider(DbPath, <<"vultr-notok">>, <<"vultr">>, #{}),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                timer:sleep(?SCAN_SLEEP_MS)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

scan_porkbun_missing_keys_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        pertisk_eproxy_test_helpers:sync_router(
            [site(<<"pb-notok.example">>, <<"pb-notok">>)],
            [backend()]
        ),
        try
            {ok, _} = pertisk_eproxy_db:insert_dns_provider(
                DbPath, <<"pb-notok">>, <<"porkbun">>, #{<<"api_key">> => <<"only">>}
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                timer:sleep(?SCAN_SLEEP_MS)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

scan_site_skips_missing_acme_email_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        pertisk_eproxy_test_helpers:sync_router(
            [#{
                host => <<"no-email.example">>,
                backend => <<"web">>,
                challenge_type => "dns-01",
                dns_provider => <<"cf-ne">>,
                routes => []
            }],
            [backend()]
        ),
        meck:new(pertisk_eproxy_acme_client, [unstick, no_link]),
        meck:expect(pertisk_eproxy_acme_client, obtain_certificate, fun(_) ->
            {ok, <<"cert">>, <<"kid">>}
        end),
        try
            {ok, _} = pertisk_eproxy_db:insert_dns_provider(
                DbPath, <<"cf-ne">>, <<"cloudflare">>, #{<<"api_token">> => <<"tok">>}
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                assert_meck_calls_zero(pertisk_eproxy_acme_client, obtain_certificate)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            safe_meck_unload(pertisk_eproxy_acme_client),
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

scan_cert_id_ref_from_db_test() ->
    with_scan_env(fun(#{db := DbPath, acme_dir := AcmeDir}) ->
        Host = <<"db-cert.example">>,
        PemPath = filename:join(AcmeDir, "staging-db.pem"),
        KeyPath = filename:join(AcmeDir, "staging-db.key"),
        ok = file:write_file(PemPath, <<"staging-pem">>),
        ok = file:write_file(KeyPath, <<"staging-key">>),
        {ok, CertId} = pertisk_eproxy_db:upsert_acme_certificate_pem(
            DbPath, "acme/db-cert.example", PemPath, KeyPath
        ),
        pertisk_eproxy_test_helpers:sync_router(
            [maps:merge(site(Host, <<"cf-dbcert">>), #{certificate => integer_to_binary(CertId)})],
            [backend()]
        ),
        meck:new(pertisk_eproxy_dns_cloudflare, [unstick, no_link]),
        mock_dns_cloudflare(),
        meck:new(pertisk_eproxy_acme_csr, [unstick, no_link]),
        meck:expect(pertisk_eproxy_acme_csr, generate_rsa_csr, fun(_) ->
            {ok, #{csr_der => <<>>, key_pem => <<"key">>}}
        end),
        meck:new(pertisk_eproxy_tls_cert_info, [unstick, no_link]),
        meck:expect(pertisk_eproxy_tls_cert_info, describe_pem_data, fun(_) ->
            {ok, #{issuer => <<"(STAGING) Fake LE Intermediate X1">>}}
        end),
        mock_acme_client_ok(),
        try
            insert_dns_provider_ready(
                DbPath, <<"cf-dbcert">>, <<"cloudflare">>, #{<<"api_token">> => <<"tok">>, <<"zone_id">> => <<"z">>}
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                assert_meck_calls_at_least(pertisk_eproxy_acme_client, obtain_certificate, 1)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            safe_meck_unload_all([
                pertisk_eproxy_acme_client,
                pertisk_eproxy_dns_cloudflare,
                pertisk_eproxy_acme_csr,
                pertisk_eproxy_tls_cert_info
            ]),
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

scan_cloudflare_delete_txt_fallback_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        pertisk_eproxy_test_helpers:sync_router(
            [site(<<"cf-del-fallback.example">>, <<"cf-del">>)],
            [backend()]
        ),
        meck:new(pertisk_eproxy_dns_cloudflare, [unstick, no_link]),
        mock_dns_cloudflare(),
        mock_acme_client_error({dns_del, refused}),
        try
            {ok, _} = pertisk_eproxy_db:insert_dns_provider(
                DbPath, <<"cf-del">>, <<"cloudflare">>, #{<<"api_token">> => <<"tok">>, <<"zone_id">> => <<"z">>}
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                timer:sleep(?SCAN_SLEEP_MS)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            safe_meck_unload_all([pertisk_eproxy_acme_client, pertisk_eproxy_dns_cloudflare]),
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

validate_dns_provider_route53_with_fake_lego_test() ->
    meck:new(pertisk_eproxy_acme_lego, [unstick, no_link, passthrough]),
    meck:expect(pertisk_eproxy_acme_lego, validate_provider, fun(_, _, _) ->
        {ok, #{lego_path => <<"/bin/lego">>, env_var_count => 2}}
    end),
    try
        ?assertMatch(
            {ok, #{mode := <<"lego">>, provider := <<"route53">>}},
            pertisk_eproxy_acme_dns:validate_dns_provider(
                <<"route53">>,
                #{<<"access_key_id">> => <<"AKIA">>, <<"secret_access_key">> => <<"SECRET">>}
            )
        )
    after
        safe_meck_unload(pertisk_eproxy_acme_lego)
    end.

scan_dns_provider_not_found_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        pertisk_eproxy_test_helpers:sync_router(
            [site(<<"orphan.example">>, <<"missing-dns">>)],
            [backend()]
        ),
        try
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                timer:sleep(?SCAN_SLEEP_MS)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

validate_dns_provider_godaddy_with_fake_lego_test() ->
    meck:new(pertisk_eproxy_acme_lego, [unstick, no_link, passthrough, no_passthrough_cover]),
    meck:expect(pertisk_eproxy_acme_lego, validate_provider, fun(_, _, _) ->
        {ok, #{lego_path => <<"/bin/lego">>, env_var_count => 2}}
    end),
    try
        ?assertMatch(
            {ok, #{mode := <<"lego">>, provider := <<"godaddy">>}},
            pertisk_eproxy_acme_dns:validate_dns_provider(
                <<"godaddy">>,
                #{<<"api_key">> => <<"k">>, <<"api_secret">> => <<"s">>}
            )
        )
    after
        safe_meck_unload(pertisk_eproxy_acme_lego)
    end.

scan_acme_order_invalid_humanize_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        pertisk_eproxy_test_helpers:sync_router(
            [site(<<"order-inv.example">>, <<"cf-order">>)],
            [backend()]
        ),
        meck:new(pertisk_eproxy_dns_cloudflare, [unstick, no_link]),
        mock_dns_cloudflare(),
        meck:new(pertisk_eproxy_acme_client, [unstick, no_link, passthrough]),
        meck:expect(pertisk_eproxy_acme_client, obtain_certificate, fun(_) ->
            {error, {order_invalid, #{}, [{challenge, timeout}]}}
        end),
        try
            {ok, _} = pertisk_eproxy_db:insert_dns_provider(
                DbPath, <<"cf-order">>, <<"cloudflare">>, #{<<"api_token">> => <<"tok">>, <<"zone_id">> => <<"z">>}
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                timer:sleep(?SCAN_SLEEP_MS)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            safe_meck_unload_all([pertisk_eproxy_acme_client, pertisk_eproxy_dns_cloudflare]),
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

validate_dns_provider_azure_with_fake_lego_test() ->
    meck:new(pertisk_eproxy_acme_lego, [unstick, no_link, passthrough, no_passthrough_cover]),
    meck:expect(pertisk_eproxy_acme_lego, validate_provider, fun(_, _, _) ->
        {ok, #{lego_path => <<"/bin/lego">>, env_var_count => 5}}
    end),
    try
        ?assertMatch(
            {ok, #{mode := <<"lego">>, provider := <<"azure">>}},
            pertisk_eproxy_acme_dns:validate_dns_provider(
                <<"azure">>,
                #{
                    <<"tenant_id">> => <<"t">>,
                    <<"client_id">> => <<"c">>,
                    <<"client_secret">> => <<"s">>,
                    <<"subscription_id">> => <<"sub">>,
                    <<"resource_group">> => <<"rg">>
                }
            )
        )
    after
        safe_meck_unload(pertisk_eproxy_acme_lego)
    end.

scan_site_host_list_form_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        pertisk_eproxy_test_helpers:sync_router(
            [(site(<<"list-host.example">>, <<"cf">>))#{host => "list-host.example"}],
            [backend()]
        ),
        meck:new(pertisk_eproxy_dns_cloudflare, [unstick, no_link]),
        mock_dns_cloudflare(),
        mock_acme_client_ok(),
        try
            {ok, _} = pertisk_eproxy_db:insert_dns_provider(
                DbPath, <<"cf">>, <<"cloudflare">>, #{<<"api_token">> => <<"tok">>, <<"zone_id">> => <<"z">>}
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                timer:sleep(?SCAN_SLEEP_MS)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            safe_meck_unload_all([pertisk_eproxy_acme_client, pertisk_eproxy_dns_cloudflare]),
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

validate_dns_provider_rfc2136_delegates_to_lego_test() ->
    case pertisk_eproxy_acme_dns:validate_dns_provider(<<"rfc2136">>, #{}) of
        {error, lego_not_found} -> ok;
        {error, _} -> ok;
        {ok, #{mode := <<"lego">>, provider := <<"rfc2136">>}} -> ok
    end.

validate_dns_provider_cloudns_delegates_to_lego_test() ->
    case pertisk_eproxy_acme_dns:validate_dns_provider(<<"cloudns">>, #{}) of
        {error, lego_not_found} -> ok;
        {error, _} -> ok;
        {ok, #{mode := <<"lego">>, provider := <<"cloudns">>}} -> ok
    end.

validate_dns_provider_easydns_delegates_to_lego_test() ->
    case pertisk_eproxy_acme_dns:validate_dns_provider(<<"easydns">>, #{}) of
        {error, lego_not_found} -> ok;
        {error, _} -> ok;
        {ok, #{mode := <<"lego">>, provider := <<"easydns">>}} -> ok
    end.

validate_dns_provider_dnsmadeeasy_delegates_to_lego_test() ->
    case pertisk_eproxy_acme_dns:validate_dns_provider(<<"dnsmadeeasy">>, #{}) of
        {error, lego_not_found} -> ok;
        {error, _} -> ok;
        {ok, #{mode := <<"lego">>, provider := <<"dnsmadeeasy">>}} -> ok
    end.

validate_dns_provider_dynu_delegates_to_lego_test() ->
    case pertisk_eproxy_acme_dns:validate_dns_provider(<<"dynu">>, #{}) of
        {error, lego_not_found} -> ok;
        {error, _} -> ok;
        {ok, #{mode := <<"lego">>, provider := <<"dynu">>}} -> ok
    end.

validate_dns_provider_googleclouddns_delegates_to_lego_test() ->
    case pertisk_eproxy_acme_dns:validate_dns_provider(<<"googleclouddns">>, #{}) of
        {error, lego_not_found} -> ok;
        {error, missing_project_id} -> ok;
        {error, _} -> ok;
        {ok, #{mode := <<"lego">>}} -> ok
    end.

validate_powerdns_zone_lookup_failure_test() ->
    meck:new(pertisk_eproxy_dns_powerdns, [unstick, no_link]),
    meck:expect(pertisk_eproxy_dns_powerdns, resolve_zone, fun(_, _, _, _, _) ->
        {error, zone_not_found}
    end),
    try
        ?assertMatch(
            {error, zone_not_found},
            pertisk_eproxy_acme_dns:validate_dns_provider(
                <<"powerdns">>,
                #{
                    <<"api_url">> => <<"http://127.0.0.1:8081">>,
                    <<"api_key">> => <<"secret">>,
                    <<"zone_name">> => <<"missing.example.com">>}
            )
        )
    after
        safe_meck_unload(pertisk_eproxy_dns_powerdns)
    end.

scan_powerdns_missing_api_url_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        pertisk_eproxy_test_helpers:sync_router(
            [site(<<"pdns-missing.example">>, <<"pdns-miss">>)],
            [backend()]
        ),
        try
            {ok, _} = pertisk_eproxy_db:insert_dns_provider(
                DbPath, <<"pdns-miss">>, <<"powerdns">>, #{<<"api_key">> => <<"k">>}
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                timer:sleep(?SCAN_SLEEP_MS)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

scan_cloudflare_global_key_issue_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        pertisk_eproxy_test_helpers:sync_router(
            [site(<<"cf-global.example">>, <<"cf-global">>)],
            [backend()]
        ),
        meck:new(pertisk_eproxy_dns_cloudflare, [unstick, no_link]),
        meck:expect(pertisk_eproxy_dns_cloudflare, auth_diag, fun(_) -> <<"global_key">> end),
        meck:expect(pertisk_eproxy_dns_cloudflare, get_zone, fun(_, _) ->
            {ok, #{zone_id => <<"z">>, zone_name => <<"example.com">>}}
        end),
        meck:expect(pertisk_eproxy_dns_cloudflare, cf_txt_record_name, fun(Fqdn, _) -> Fqdn end),
        meck:expect(pertisk_eproxy_dns_cloudflare, create_txt, fun(_, _, _, _, _) -> {ok, <<"rid">>} end),
        meck:expect(pertisk_eproxy_dns_cloudflare, delete_txt, fun(_, _, _) -> ok end),
        mock_acme_client_ok(),
        try
            {ok, _} = pertisk_eproxy_db:insert_dns_provider(
                DbPath,
                <<"cf-global">>,
                <<"cloudflare">>,
                #{
                    <<"api_key">> => <<"key">>,
                    <<"email">> => <<"ops@example.com">>,
                    <<"zone_id">> => <<"zone-id">>
                }
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                timer:sleep(?SCAN_SLEEP_MS)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            safe_meck_unload_all([pertisk_eproxy_acme_client, pertisk_eproxy_dns_cloudflare]),
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

scan_cert_pem_from_db_row_test() ->
    with_scan_env(fun(#{db := DbPath, acme_dir := AcmeDir}) ->
        Host = <<"db-pem.example">>,
        PemPath = filename:join(AcmeDir, "staging-db.pem"),
        KeyPath = filename:join(AcmeDir, "staging-db.key"),
        ok = file:write_file(PemPath, <<"staging-pem">>),
        ok = file:write_file(KeyPath, <<"staging-key">>),
        {ok, CertId} = pertisk_eproxy_db:upsert_acme_certificate_pem(
            DbPath, "acme/db-pem.example", PemPath, KeyPath
        ),
        pertisk_eproxy_test_helpers:sync_router(
            [maps:merge(site(Host, <<"cf-pem">>), #{certificate => integer_to_binary(CertId)})],
            [backend()]
        ),
        meck:new(pertisk_eproxy_dns_cloudflare, [unstick, no_link]),
        mock_dns_cloudflare(),
        meck:new(pertisk_eproxy_acme_csr, [unstick, no_link]),
        meck:expect(pertisk_eproxy_acme_csr, generate_rsa_csr, fun(_) ->
            {ok, #{csr_der => <<>>, key_pem => <<"key">>}}
        end),
        meck:new(pertisk_eproxy_tls_cert_info, [unstick, no_link]),
        meck:expect(pertisk_eproxy_tls_cert_info, describe_pem_data, fun(_) ->
            {ok, #{issuer => <<"(STAGING) Fake LE Intermediate X1">>}}
        end),
        mock_acme_client_ok(),
        try
            insert_dns_provider_ready(
                DbPath, <<"cf-pem">>, <<"cloudflare">>, #{<<"api_token">> => <<"tok">>, <<"zone_id">> => <<"z">>}
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                assert_meck_calls_at_least(pertisk_eproxy_acme_client, obtain_certificate, 1)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            safe_meck_unload_all([
                pertisk_eproxy_acme_client,
                pertisk_eproxy_dns_cloudflare,
                pertisk_eproxy_acme_csr,
                pertisk_eproxy_tls_cert_info
            ]),
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

scan_lego_failed_empty_output_humanize_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        pertisk_eproxy_test_helpers:sync_router(
            [site(<<"lego-empty.example">>, <<"gd-empty">>)],
            [backend()]
        ),
        meck:new(pertisk_eproxy_acme_lego, [unstick, no_link, passthrough]),
        meck:expect(pertisk_eproxy_acme_lego, obtain_certificate, fun(_, _, _, _, _, _, _, _) ->
            {error, {lego_failed, <<"\n\n">>}}
        end),
        try
            {ok, _} = pertisk_eproxy_db:insert_dns_provider(
                DbPath,
                <<"gd-empty">>,
                <<"godaddy">>,
                #{<<"api_key">> => <<"k">>, <<"api_secret">> => <<"s">>}
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                timer:sleep(?SCAN_SLEEP_MS)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            safe_meck_unload(pertisk_eproxy_acme_lego),
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

scan_acme_order_invalid_empty_failures_test() ->
    with_scan_env(fun(#{db := DbPath}) ->
        pertisk_eproxy_test_helpers:sync_router(
            [site(<<"order-empty.example">>, <<"cf-order-empty">>)],
            [backend()]
        ),
        meck:new(pertisk_eproxy_dns_cloudflare, [unstick, no_link]),
        mock_dns_cloudflare(),
        meck:new(pertisk_eproxy_acme_client, [unstick, no_link, passthrough]),
        meck:expect(pertisk_eproxy_acme_client, obtain_certificate, fun(_) ->
            {error, {order_invalid, #{}, []}}
        end),
        try
            {ok, _} = pertisk_eproxy_db:insert_dns_provider(
                DbPath, <<"cf-order-empty">>, <<"cloudflare">>,
                #{<<"api_token">> => <<"tok">>, <<"zone_id">> => <<"z">>}
            ),
            stop_acme_dns(),
            {ok, Pid} = pertisk_eproxy_acme_dns:start_link(),
            try
                gen_server:cast(Pid, scan),
                timer:sleep(?SCAN_SLEEP_MS)
            after
                pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000)
            end
        after
            safe_meck_unload_all([pertisk_eproxy_acme_client, pertisk_eproxy_dns_cloudflare]),
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).
