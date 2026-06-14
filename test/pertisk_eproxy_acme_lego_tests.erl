-module(pertisk_eproxy_acme_lego_tests).

-include_lib("eunit/include/eunit.hrl").

lego_work_root() ->
    filename:join([os:getenv("TMPDIR", "/tmp"), "pertisk-eproxy-lego-test"]).

provider_to_binary_atom_test() ->
    ?assertEqual(<<"route53">>, pertisk_eproxy_acme_lego:provider_to_binary(route53)).

provider_to_binary_binary_test() ->
    ?assertEqual(<<"cloudflare">>, pertisk_eproxy_acme_lego:provider_to_binary(<<"cloudflare">>)).

provider_to_binary_list_test() ->
    ?assertEqual(<<"ovh">>, pertisk_eproxy_acme_lego:provider_to_binary("ovh")).

find_lego_executable_returns_boolean_or_path_test() ->
    Result = pertisk_eproxy_acme_lego:find_lego_executable(),
    ?assert(Result =:= false orelse is_list(Result)).

validate_provider_missing_godaddy_creds_test() ->
    WorkRoot = lego_work_root(),
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found}, pertisk_eproxy_acme_lego:validate_provider(godaddy, #{}, WorkRoot));
        _Lego ->
            ?assertMatch({error, _}, pertisk_eproxy_acme_lego:validate_provider(godaddy, #{}, WorkRoot))
    end.

validate_provider_godaddy_creds_present_test() ->
    WorkRoot = lego_work_root(),
    Creds = #{
        <<"api_key">> => <<"key">>,
        <<"api_secret">> => <<"secret">>
    },
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found}, pertisk_eproxy_acme_lego:validate_provider(godaddy, Creds, WorkRoot));
        _Lego ->
            ?assertMatch({ok, #{env_var_count := 2}}, pertisk_eproxy_acme_lego:validate_provider(godaddy, Creds, WorkRoot))
    end.

validate_provider_route53_missing_keys_test() ->
    WorkRoot = lego_work_root(),
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found}, pertisk_eproxy_acme_lego:validate_provider(route53, #{}, WorkRoot));
        _Lego ->
            ?assertMatch({error, _}, pertisk_eproxy_acme_lego:validate_provider(route53, #{}, WorkRoot))
    end.

validate_provider_google_missing_project_test() ->
    WorkRoot = lego_work_root(),
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found}, pertisk_eproxy_acme_lego:validate_provider(googleclouddns, #{}, WorkRoot));
        _Lego ->
            ?assertMatch({error, missing_project_id},
                pertisk_eproxy_acme_lego:validate_provider(googleclouddns, #{}, WorkRoot))
    end.

validate_provider_customlego_missing_env_test() ->
    WorkRoot = lego_work_root(),
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found}, pertisk_eproxy_acme_lego:validate_provider(customlego, #{}, WorkRoot));
        _Lego ->
            ?assertMatch({error, missing_env_vars_json},
                pertisk_eproxy_acme_lego:validate_provider(customlego, #{}, WorkRoot))
    end.

validate_provider_customlego_env_json_test() ->
    WorkRoot = lego_work_root(),
    Creds = #{<<"env_vars_json">> => <<"{\"FOO\":\"bar\"}">>},
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found}, pertisk_eproxy_acme_lego:validate_provider(customlego, Creds, WorkRoot));
        _Lego ->
            ?assertMatch({ok, #{env_var_count := 1}},
                pertisk_eproxy_acme_lego:validate_provider(customlego, Creds, WorkRoot))
    end.

validate_provider_invalid_env_json_test() ->
    WorkRoot = lego_work_root(),
    Creds = #{<<"env_vars_json">> => <<"not-json">>},
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found}, pertisk_eproxy_acme_lego:validate_provider(customlego, Creds, WorkRoot));
        _Lego ->
            ?assertMatch({error, invalid_env_vars_json},
                pertisk_eproxy_acme_lego:validate_provider(customlego, Creds, WorkRoot))
    end.

validate_provider_generic_uppercase_env_test() ->
    WorkRoot = lego_work_root(),
    Creds = #{<<"CUSTOM_ENV">> => <<"value">>},
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found}, pertisk_eproxy_acme_lego:validate_provider(<<"fooprovider">>, Creds, WorkRoot));
        _Lego ->
            ?assertMatch({ok, #{env_var_count := 1}},
                pertisk_eproxy_acme_lego:validate_provider(<<"fooprovider">>, Creds, WorkRoot))
    end.

validate_provider_namecheap_missing_creds_test() ->
    WorkRoot = lego_work_root(),
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found}, pertisk_eproxy_acme_lego:validate_provider(namecheap, #{}, WorkRoot));
        _Lego ->
            ?assertMatch({error, _}, pertisk_eproxy_acme_lego:validate_provider(namecheap, #{}, WorkRoot))
    end.

validate_provider_ovh_creds_present_test() ->
    WorkRoot = lego_work_root(),
    Creds = #{
        <<"application_key">> => <<"k">>,
        <<"application_secret">> => <<"s">>,
        <<"consumer_key">> => <<"c">>
    },
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found}, pertisk_eproxy_acme_lego:validate_provider(ovh, Creds, WorkRoot));
        _Lego ->
            ?assertMatch({ok, #{env_var_count := 3}}, pertisk_eproxy_acme_lego:validate_provider(ovh, Creds, WorkRoot))
    end.

validate_provider_azure_missing_creds_test() ->
    WorkRoot = lego_work_root(),
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found}, pertisk_eproxy_acme_lego:validate_provider(azure, #{}, WorkRoot));
        _Lego ->
            ?assertMatch({error, _}, pertisk_eproxy_acme_lego:validate_provider(azure, #{}, WorkRoot))
    end.

validate_provider_rfc2136_creds_test() ->
    WorkRoot = lego_work_root(),
    Creds = #{
        <<"nameserver">> => <<"127.0.0.1">>,
        <<"tsig_key_name">> => <<"key">>,
        <<"tsig_secret">> => <<"secret">>
    },
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found}, pertisk_eproxy_acme_lego:validate_provider(rfc2136, Creds, WorkRoot));
        _Lego ->
            ?assertMatch({ok, #{env_var_count := 3}}, pertisk_eproxy_acme_lego:validate_provider(rfc2136, Creds, WorkRoot))
    end.

validate_provider_cloudns_creds_test() ->
    WorkRoot = lego_work_root(),
    Creds = #{<<"auth_id">> => <<"1">>, <<"auth_password">> => <<"pw">>},
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found}, pertisk_eproxy_acme_lego:validate_provider(cloudns, Creds, WorkRoot));
        _Lego ->
            ?assertMatch({ok, #{env_var_count := 2}}, pertisk_eproxy_acme_lego:validate_provider(cloudns, Creds, WorkRoot))
    end.

validate_provider_easydns_creds_test() ->
    WorkRoot = lego_work_root(),
    Creds = #{<<"token">> => <<"t">>, <<"key">> => <<"k">>},
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found}, pertisk_eproxy_acme_lego:validate_provider(easydns, Creds, WorkRoot));
        _Lego ->
            ?assertMatch({ok, #{env_var_count := 2}}, pertisk_eproxy_acme_lego:validate_provider(easydns, Creds, WorkRoot))
    end.

validate_provider_dnsmadeeasy_creds_test() ->
    WorkRoot = lego_work_root(),
    Creds = #{<<"api_key">> => <<"k">>, <<"secret_key">> => <<"s">>},
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found}, pertisk_eproxy_acme_lego:validate_provider(dnsmadeeasy, Creds, WorkRoot));
        _Lego ->
            ?assertMatch({ok, #{env_var_count := 2}}, pertisk_eproxy_acme_lego:validate_provider(dnsmadeeasy, Creds, WorkRoot))
    end.

validate_provider_dynu_creds_test() ->
    WorkRoot = lego_work_root(),
    Creds = #{<<"api_token">> => <<"tok">>},
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found}, pertisk_eproxy_acme_lego:validate_provider(dynu, Creds, WorkRoot));
        _Lego ->
            ?assertMatch({ok, #{env_var_count := 1}}, pertisk_eproxy_acme_lego:validate_provider(dynu, Creds, WorkRoot))
    end.

validate_provider_google_complete_test() ->
    WorkRoot = lego_work_root(),
    Creds = #{
        <<"project_id">> => <<"proj">>,
        <<"service_account_json">> => <<"{\"type\":\"service_account\"}">>
    },
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found}, pertisk_eproxy_acme_lego:validate_provider(googleclouddns, Creds, WorkRoot));
        _Lego ->
            ?assertMatch({ok, #{env_var_count := 2}}, pertisk_eproxy_acme_lego:validate_provider(googleclouddns, Creds, WorkRoot))
    end.

with_fake_lego(Fun) ->
    Dir = filename:join([os:getenv("TMPDIR", "/tmp"), "pertisk-lego-" ++ integer_to_list(erlang:unique_integer([positive]))]),
    ok = file:make_dir(Dir),
    DataDir = filename:join(Dir, "data"),
    ok = file:make_dir(DataDir),
    Bin = filename:join(Dir, "lego"),
    Script = [
        "#!/bin/sh\n",
        "while [ $# -gt 0 ]; do\n",
        "  case \"$1\" in\n",
        "    --path) LEGOPATH=\"$2\"; shift 2;;\n",
        "    run)\n",
        "      mkdir -p \"$LEGOPATH/certificates\"\n",
        "      echo '-----BEGIN CERTIFICATE-----' > \"$LEGOPATH/certificates/example.com.crt\"\n",
        "      echo '-----END CERTIFICATE-----' >> \"$LEGOPATH/certificates/example.com.crt\"\n",
        "      echo '-----BEGIN RSA PRIVATE KEY-----' > \"$LEGOPATH/certificates/example.com.key\"\n",
        "      echo '-----END RSA PRIVATE KEY-----' >> \"$LEGOPATH/certificates/example.com.key\"\n",
        "      exit 0;;\n",
        "    *) shift;;\n",
        "  esac\n",
        "done\n",
        "exit 0\n"
    ],
    ok = file:write_file(Bin, Script),
    ok = file:change_mode(Bin, 8#755),
    Old = os:getenv("PERTISK_LEGO_BIN"),
    os:putenv("PERTISK_LEGO_BIN", Bin),
    try Fun(DataDir) after
        case Old of
            false -> os:unsetenv("PERTISK_LEGO_BIN");
            V -> os:putenv("PERTISK_LEGO_BIN", V)
        end,
        _ = os:cmd("rm -rf " ++ Dir)
    end.

obtain_certificate_lego_failure_test() ->
    Dir = filename:join([os:getenv("TMPDIR", "/tmp"), "pertisk-lego-fail-" ++ integer_to_list(erlang:unique_integer([positive]))]),
    ok = file:make_dir(Dir),
    DataDir = filename:join(Dir, "data"),
    ok = file:make_dir(DataDir),
    Bin = filename:join(Dir, "lego"),
    ok = file:write_file(Bin, <<"#!/bin/sh\nexit 2\n">>),
    ok = file:change_mode(Bin, 8#755),
    Old = os:getenv("PERTISK_LEGO_BIN"),
    os:putenv("PERTISK_LEGO_BIN", Bin),
    try
        Creds = #{<<"api_key">> => <<"k">>, <<"api_secret">> => <<"s">>},
        ?assertMatch(
            {error, {lego_failed, _}},
            pertisk_eproxy_acme_lego:obtain_certificate(
                godaddy,
                Creds,
                [<<"example.com">>],
                <<"ops@example.com">>,
                <<"https://acme-staging-v02.api.letsencrypt.org/directory">>,
                DataDir,
                <<"example-com">>,
                fun(_, _) -> ok end
            )
        )
    after
        case Old of
            false -> os:unsetenv("PERTISK_LEGO_BIN");
            V -> os:putenv("PERTISK_LEGO_BIN", V)
        end,
        _ = os:cmd("rm -rf " ++ Dir)
    end.

validate_provider_route53_creds_test() ->
    WorkRoot = lego_work_root(),
    Creds = #{
        <<"access_key_id">> => <<"AKIA">>,
        <<"secret_access_key">> => <<"SECRET">>,
        <<"region">> => <<"us-east-1">>
    },
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found}, pertisk_eproxy_acme_lego:validate_provider(route53, Creds, WorkRoot));
        _Lego ->
            ?assertMatch({ok, #{env_var_count := 3}}, pertisk_eproxy_acme_lego:validate_provider(route53, Creds, WorkRoot))
    end.

obtain_certificate_with_fake_lego_test() ->
    with_fake_lego(fun(AcmeDir) ->
        Creds = #{
            <<"api_key">> => <<"k">>,
            <<"api_secret">> => <<"s">>
        },
        Result = pertisk_eproxy_acme_lego:obtain_certificate(
            godaddy,
            Creds,
            [<<"example.com">>],
            <<"ops@example.com">>,
            <<"https://acme-staging-v02.api.letsencrypt.org/directory">>,
            AcmeDir,
            <<"example-com">>,
            fun(_, _) -> ok end
        ),
        {ok, Pem, Key} = Result,
        ?assert(byte_size(Pem) > 0),
        ?assert(byte_size(Key) > 0)
    end).

provider_to_binary_other_type_test() ->
    ?assertEqual(<<"123">>, pertisk_eproxy_acme_lego:provider_to_binary(123)).

find_lego_executable_empty_env_test() ->
    Old = os:getenv("PERTISK_LEGO_BIN"),
    os:putenv("PERTISK_LEGO_BIN", ""),
    try
        Result = pertisk_eproxy_acme_lego:find_lego_executable(),
        ?assert(Result =:= false orelse is_list(Result))
    after
        case Old of
            false -> os:unsetenv("PERTISK_LEGO_BIN");
            V -> os:putenv("PERTISK_LEGO_BIN", V)
        end
    end.

validate_provider_namecheap_creds_test() ->
    WorkRoot = lego_work_root(),
    Creds = #{
        <<"api_user">> => <<"user">>,
        <<"api_key">> => <<"key">>,
        <<"username">> => <<"user">>,
        <<"client_ip">> => <<"127.0.0.1">>
    },
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found}, pertisk_eproxy_acme_lego:validate_provider(namecheap, Creds, WorkRoot));
        _Lego ->
            ?assertMatch({ok, #{env_var_count := 4}}, pertisk_eproxy_acme_lego:validate_provider(namecheap, Creds, WorkRoot))
    end.

validate_provider_azure_creds_test() ->
    WorkRoot = lego_work_root(),
    Creds = #{
        <<"tenant_id">> => <<"tenant">>,
        <<"client_id">> => <<"client">>,
        <<"client_secret">> => <<"secret">>,
        <<"subscription_id">> => <<"sub">>,
        <<"resource_group">> => <<"rg">>
    },
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found}, pertisk_eproxy_acme_lego:validate_provider(azure, Creds, WorkRoot));
        _Lego ->
            ?assertMatch({ok, #{env_var_count := 5}}, pertisk_eproxy_acme_lego:validate_provider(azure, Creds, WorkRoot))
    end.

validate_provider_google_missing_service_account_test() ->
    WorkRoot = lego_work_root(),
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found},
                pertisk_eproxy_acme_lego:validate_provider(googleclouddns, #{<<"project_id">> => <<"p">>}, WorkRoot));
        _Lego ->
            ?assertMatch({error, missing_service_account_json},
                pertisk_eproxy_acme_lego:validate_provider(googleclouddns, #{<<"project_id">> => <<"p">>}, WorkRoot))
    end.

obtain_certificate_no_cert_files_test() ->
    Dir = filename:join([os:getenv("TMPDIR", "/tmp"), "pertisk-lego-nocert-" ++ integer_to_list(erlang:unique_integer([positive]))]),
    ok = file:make_dir(Dir),
    DataDir = filename:join(Dir, "data"),
    ok = file:make_dir(DataDir),
    Bin = filename:join(Dir, "lego"),
    ok = file:write_file(Bin, <<"#!/bin/sh\nexit 0\n">>),
    ok = file:change_mode(Bin, 8#755),
    Old = os:getenv("PERTISK_LEGO_BIN"),
    os:putenv("PERTISK_LEGO_BIN", Bin),
    try
        Creds = #{<<"api_key">> => <<"k">>, <<"api_secret">> => <<"s">>},
        ?assertMatch(
            {error, {lego_no_certificate_files, _}},
            pertisk_eproxy_acme_lego:obtain_certificate(
                godaddy,
                Creds,
                [<<"example.com">>],
                <<"ops@example.com">>,
                <<"https://acme-staging-v02.api.letsencrypt.org/directory">>,
                DataDir,
                <<"example-com">>,
                fun(_, _) -> ok end
            )
        )
    after
        case Old of
            false -> os:unsetenv("PERTISK_LEGO_BIN");
            V -> os:putenv("PERTISK_LEGO_BIN", V)
        end,
        _ = os:cmd("rm -rf " ++ Dir)
    end.

obtain_certificate_calls_progress_callback_test() ->
    with_fake_lego(fun(AcmeDir) ->
        Ref = make_ref(),
        Progress = fun(Phase, Msg) ->
            self() ! {lego_progress, Phase, Msg},
            ok
        end,
        Creds = #{<<"api_key">> => <<"k">>, <<"api_secret">> => <<"s">>},
        ?assertMatch({ok, _, _},
            pertisk_eproxy_acme_lego:obtain_certificate(
                godaddy,
                Creds,
                [<<"example.com">>],
                <<"ops@example.com">>,
                <<"https://acme-staging-v02.api.letsencrypt.org/directory">>,
                AcmeDir,
                <<"example-com">>,
                Progress
            )),
        receive
            {lego_progress, <<"lego">>, _} -> ok
        after 1000 ->
            ?assert(false)
        end,
        ?assertEqual(Ref, Ref)
    end).

validate_provider_customlego_named_provider_test() ->
    WorkRoot = lego_work_root(),
    Creds = #{
        <<"lego_provider">> => <<"route53">>,
        <<"access_key_id">> => <<"AKIA">>,
        <<"secret_access_key">> => <<"SECRET">>
    },
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found}, pertisk_eproxy_acme_lego:validate_provider(customlego, Creds, WorkRoot));
        _Lego ->
            ?assertMatch({error, _}, pertisk_eproxy_acme_lego:validate_provider(customlego, Creds, WorkRoot))
    end.

obtain_certificate_lego_not_found_test() ->
    Old = os:getenv("PERTISK_LEGO_BIN"),
    os:putenv("PERTISK_LEGO_BIN", "/nonexistent/lego-missing"),
    try
        ?assertMatch(
            {error, lego_not_found},
            pertisk_eproxy_acme_lego:obtain_certificate(
                godaddy,
                #{<<"api_key">> => <<"k">>, <<"api_secret">> => <<"s">>},
                [<<"example.com">>],
                <<"ops@example.com">>,
                <<"https://acme-staging-v02.api.letsencrypt.org/directory">>,
                lego_work_root(),
                <<"example-com">>,
                fun(_, _) -> ok end
            )
        )
    after
        case Old of
            false -> os:unsetenv("PERTISK_LEGO_BIN");
            V -> os:putenv("PERTISK_LEGO_BIN", V)
        end
    end.

obtain_certificate_provider_env_error_test() ->
    with_fake_lego(fun(AcmeDir) ->
        ?assertMatch(
            {error, {missing_credential, _}},
            pertisk_eproxy_acme_lego:obtain_certificate(
                godaddy,
                #{},
                [<<"example.com">>],
                <<"ops@example.com">>,
                <<"https://acme-staging-v02.api.letsencrypt.org/directory">>,
                AcmeDir,
                <<"example-com">>,
                fun(_, _) -> ok end
            )
        )
    end).

find_lego_executable_custom_bin_path_test() ->
    with_fake_lego(fun(_DataDir) ->
        ?assertMatch([_ | _], pertisk_eproxy_acme_lego:find_lego_executable())
    end).

validate_provider_customlego_env_vars_json_camel_case_test() ->
    WorkRoot = lego_work_root(),
    Creds = #{<<"envVarsJson">> => <<"{\"FOO\":\"bar\"}">>},
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found},
                pertisk_eproxy_acme_lego:validate_provider(customlego, Creds, WorkRoot));
        _Lego ->
            ?assertMatch({ok, #{env_var_count := 1}},
                pertisk_eproxy_acme_lego:validate_provider(customlego, Creds, WorkRoot))
    end.

validate_provider_customlego_invalid_env_json_array_test() ->
    WorkRoot = lego_work_root(),
    Creds = #{<<"env_vars_json">> => <<"[]">>},
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found},
                pertisk_eproxy_acme_lego:validate_provider(customlego, Creds, WorkRoot));
        _Lego ->
            ?assertMatch({error, invalid_env_vars_json},
                pertisk_eproxy_acme_lego:validate_provider(customlego, Creds, WorkRoot))
    end.

obtain_certificate_route53_with_fake_lego_test() ->
    with_fake_lego(fun(AcmeDir) ->
        Creds = #{
            <<"access_key_id">> => <<"AKIA">>,
            <<"secret_access_key">> => <<"SECRET">>
        },
        ?assertMatch({ok, _, _},
            pertisk_eproxy_acme_lego:obtain_certificate(
                route53,
                Creds,
                [<<"example.com">>],
                <<"ops@example.com">>,
                <<"https://acme-staging-v02.api.letsencrypt.org/directory">>,
                AcmeDir,
                <<"example-com">>,
                fun(_, _) -> ok end
            ))
    end).

obtain_certificate_azure_with_fake_lego_test() ->
    with_fake_lego(fun(AcmeDir) ->
        Creds = #{
            <<"tenant_id">> => <<"tenant">>,
            <<"client_id">> => <<"client">>,
            <<"client_secret">> => <<"secret">>,
            <<"subscription_id">> => <<"sub">>,
            <<"resource_group">> => <<"rg">>
        },
        ?assertMatch({ok, _, _},
            pertisk_eproxy_acme_lego:obtain_certificate(
                azure,
                Creds,
                [<<"example.com">>],
                <<"ops@example.com">>,
                <<"https://acme-staging-v02.api.letsencrypt.org/directory">>,
                AcmeDir,
                <<"example-com">>,
                fun(_, _) -> ok end
            ))
    end).

obtain_certificate_googleclouddns_with_fake_lego_test() ->
    with_fake_lego(fun(AcmeDir) ->
        Creds = #{
            <<"project_id">> => <<"proj">>,
            <<"service_account_json">> => <<"{\"type\":\"service_account\"}">>
        },
        ?assertMatch({ok, _, _},
            pertisk_eproxy_acme_lego:obtain_certificate(
                googleclouddns,
                Creds,
                [<<"example.com">>],
                <<"ops@example.com">>,
                <<"https://acme-staging-v02.api.letsencrypt.org/directory">>,
                AcmeDir,
                <<"example-com">>,
                fun(_, _) -> ok end
            ))
    end).

obtain_certificate_multiple_domains_with_fake_lego_test() ->
    with_fake_lego(fun(AcmeDir) ->
        Creds = #{<<"api_key">> => <<"k">>, <<"api_secret">> => <<"s">>},
        ?assertMatch({ok, _, _},
            pertisk_eproxy_acme_lego:obtain_certificate(
                godaddy,
                Creds,
                [<<"example.com">>, <<"www.example.com">>],
                <<"ops@example.com">>,
                <<"https://acme-staging-v02.api.letsencrypt.org/directory">>,
                AcmeDir,
                <<"example-com">>,
                fun(_, _) -> ok end
            ))
    end).

obtain_certificate_undefined_progress_test() ->
    with_fake_lego(fun(AcmeDir) ->
        Creds = #{<<"api_key">> => <<"k">>, <<"api_secret">> => <<"s">>},
        ?assertMatch({ok, _, _},
            pertisk_eproxy_acme_lego:obtain_certificate(
                godaddy,
                Creds,
                [<<"example.com">>],
                <<"ops@example.com">>,
                <<"https://acme-staging-v02.api.letsencrypt.org/directory">>,
                AcmeDir,
                <<"example-com">>,
                undefined
            ))
    end).

obtain_certificate_skips_issuer_crt_test() ->
    Dir = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "pertisk-lego-issuer-" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = file:make_dir(Dir),
    DataDir = filename:join(Dir, "data"),
    ok = file:make_dir(DataDir),
    Bin = filename:join(Dir, "lego"),
    Script = [
        "#!/bin/sh\n",
        "while [ $# -gt 0 ]; do\n",
        "  case \"$1\" in\n",
        "    --path) LEGOPATH=\"$2\"; shift 2;;\n",
        "    run)\n",
        "      mkdir -p \"$LEGOPATH/certificates\"\n",
        "      echo 'issuer-only' > \"$LEGOPATH/certificates/example.com.issuer.crt\"\n",
        "      echo '-----BEGIN CERTIFICATE-----' > \"$LEGOPATH/certificates/example.com.crt\"\n",
        "      echo '-----END CERTIFICATE-----' >> \"$LEGOPATH/certificates/example.com.crt\"\n",
        "      echo '-----BEGIN RSA PRIVATE KEY-----' > \"$LEGOPATH/certificates/example.com.key\"\n",
        "      echo '-----END RSA PRIVATE KEY-----' >> \"$LEGOPATH/certificates/example.com.key\"\n",
        "      exit 0;;\n",
        "    *) shift;;\n",
        "  esac\n",
        "done\n",
        "exit 0\n"
    ],
    ok = file:write_file(Bin, Script),
    ok = file:change_mode(Bin, 8#755),
    Old = os:getenv("PERTISK_LEGO_BIN"),
    os:putenv("PERTISK_LEGO_BIN", Bin),
    try
        Creds = #{<<"api_key">> => <<"k">>, <<"api_secret">> => <<"s">>},
        {ok, Pem, Key} = pertisk_eproxy_acme_lego:obtain_certificate(
            godaddy,
            Creds,
            [<<"example.com">>],
            <<"ops@example.com">>,
            <<"https://acme-staging-v02.api.letsencrypt.org/directory">>,
            DataDir,
            <<"example-com">>,
            fun(_, _) -> ok end
        ),
        ?assert(byte_size(Pem) > 0),
        ?assert(byte_size(Key) > 0),
        ?assertNotEqual(<<"issuer-only">>, Pem)
    after
        case Old of
            false -> os:unsetenv("PERTISK_LEGO_BIN");
            V -> os:putenv("PERTISK_LEGO_BIN", V)
        end,
        _ = os:cmd("rm -rf " ++ Dir)
    end.

obtain_certificate_read_key_missing_test() ->
    Dir = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "pertisk-lego-nokey-" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = file:make_dir(Dir),
    DataDir = filename:join(Dir, "data"),
    ok = file:make_dir(DataDir),
    Bin = filename:join(Dir, "lego"),
    Script = [
        "#!/bin/sh\n",
        "while [ $# -gt 0 ]; do\n",
        "  case \"$1\" in\n",
        "    --path) LEGOPATH=\"$2\"; shift 2;;\n",
        "    run)\n",
        "      mkdir -p \"$LEGOPATH/certificates\"\n",
        "      echo '-----BEGIN CERTIFICATE-----' > \"$LEGOPATH/certificates/example.com.crt\"\n",
        "      echo '-----END CERTIFICATE-----' >> \"$LEGOPATH/certificates/example.com.crt\"\n",
        "      exit 0;;\n",
        "    *) shift;;\n",
        "  esac\n",
        "done\n",
        "exit 0\n"
    ],
    ok = file:write_file(Bin, Script),
    ok = file:change_mode(Bin, 8#755),
    Old = os:getenv("PERTISK_LEGO_BIN"),
    os:putenv("PERTISK_LEGO_BIN", Bin),
    try
        Creds = #{<<"api_key">> => <<"k">>, <<"api_secret">> => <<"s">>},
        ?assertMatch(
            {error, {lego_read_failed, _, _, _, _}},
            pertisk_eproxy_acme_lego:obtain_certificate(
                godaddy,
                Creds,
                [<<"example.com">>],
                <<"ops@example.com">>,
                <<"https://acme-staging-v02.api.letsencrypt.org/directory">>,
                DataDir,
                <<"example-com">>,
                fun(_, _) -> ok end
            )
        )
    after
        case Old of
            false -> os:unsetenv("PERTISK_LEGO_BIN");
            V -> os:putenv("PERTISK_LEGO_BIN", V)
        end,
        _ = os:cmd("rm -rf " ++ Dir)
    end.

find_lego_executable_whitespace_env_test() ->
    Old = os:getenv("PERTISK_LEGO_BIN"),
    os:putenv("PERTISK_LEGO_BIN", "   "),
    try
        Result = pertisk_eproxy_acme_lego:find_lego_executable(),
        ?assert(Result =:= false orelse is_list(Result))
    after
        case Old of
            false -> os:unsetenv("PERTISK_LEGO_BIN");
            V -> os:putenv("PERTISK_LEGO_BIN", V)
        end
    end.

find_lego_executable_missing_file_env_test() ->
    Old = os:getenv("PERTISK_LEGO_BIN"),
    os:putenv("PERTISK_LEGO_BIN", "/nonexistent/lego-path"),
    try
        Result = pertisk_eproxy_acme_lego:find_lego_executable(),
        ?assert(Result =:= false orelse is_list(Result))
    after
        case Old of
            false -> os:unsetenv("PERTISK_LEGO_BIN");
            V -> os:putenv("PERTISK_LEGO_BIN", V)
        end
    end.

validate_provider_route53_camel_case_keys_test() ->
    WorkRoot = lego_work_root(),
    Creds = #{
        <<"accessKeyId">> => <<"AKIA">>,
        <<"secretAccessKey">> => <<"SECRET">>,
        <<"sessionToken">> => <<"tok">>,
        <<"region">> => <<"us-east-1">>,
        <<"zoneId">> => <<"Z123">>
    },
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found},
                pertisk_eproxy_acme_lego:validate_provider(route53, Creds, WorkRoot));
        _Lego ->
            ?assertMatch({ok, #{env_var_count := 5}},
                pertisk_eproxy_acme_lego:validate_provider(route53, Creds, WorkRoot))
    end.

validate_provider_rfc2136_optional_algorithm_test() ->
    WorkRoot = lego_work_root(),
    Creds = #{
        <<"nameserver">> => <<"127.0.0.1">>,
        <<"tsig_key_name">> => <<"key">>,
        <<"tsig_secret">> => <<"secret">>,
        <<"tsig_algorithm">> => <<"hmac-sha256">>
    },
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found},
                pertisk_eproxy_acme_lego:validate_provider(rfc2136, Creds, WorkRoot));
        _Lego ->
            ?assertMatch({ok, #{env_var_count := 4}},
                pertisk_eproxy_acme_lego:validate_provider(rfc2136, Creds, WorkRoot))
    end.

validate_provider_azure_zone_name_test() ->
    WorkRoot = lego_work_root(),
    Creds = #{
        <<"tenant_id">> => <<"tenant">>,
        <<"client_id">> => <<"client">>,
        <<"client_secret">> => <<"secret">>,
        <<"subscription_id">> => <<"sub">>,
        <<"resource_group">> => <<"rg">>,
        <<"zone_name">> => <<"example.com">>
    },
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found},
                pertisk_eproxy_acme_lego:validate_provider(azure, Creds, WorkRoot));
        _Lego ->
            ?assertMatch({ok, #{env_var_count := 6}},
                pertisk_eproxy_acme_lego:validate_provider(azure, Creds, WorkRoot))
    end.

validate_provider_customlego_list_credential_key_test() ->
    WorkRoot = lego_work_root(),
    Creds = #{<<"CUSTOM_ENV">> => "list-value"},
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found},
                pertisk_eproxy_acme_lego:validate_provider(<<"custom">>, Creds, WorkRoot));
        _Lego ->
            ?assertMatch({ok, #{env_var_count := 1}},
                pertisk_eproxy_acme_lego:validate_provider(<<"custom">>, Creds, WorkRoot))
    end.

validate_provider_customlego_env_json_number_test() ->
    WorkRoot = lego_work_root(),
    Creds = #{<<"env_vars_json">> => <<"{\"PORT\":8080,\"RATIO\":1.5}">>},
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            ?assertMatch({error, lego_not_found},
                pertisk_eproxy_acme_lego:validate_provider(customlego, Creds, WorkRoot));
        _Lego ->
            ?assertMatch({ok, #{env_var_count := 2}},
                pertisk_eproxy_acme_lego:validate_provider(customlego, Creds, WorkRoot))
    end.

obtain_certificate_namecheap_with_fake_lego_test() ->
    with_fake_lego(fun(AcmeDir) ->
        Creds = #{
            <<"api_user">> => <<"user">>,
            <<"api_key">> => <<"key">>,
            <<"username">> => <<"user">>,
            <<"client_ip">> => <<"127.0.0.1">>
        },
        ?assertMatch({ok, _, _},
            pertisk_eproxy_acme_lego:obtain_certificate(
                namecheap, Creds, [<<"example.com">>], <<"ops@example.com">>,
                <<"https://acme-staging-v02.api.letsencrypt.org/directory">>,
                AcmeDir, <<"example-com">>, fun(_, _) -> ok end))
    end).

obtain_certificate_ovh_with_fake_lego_test() ->
    with_fake_lego(fun(AcmeDir) ->
        Creds = #{
            <<"application_key">> => <<"k">>,
            <<"application_secret">> => <<"s">>,
            <<"consumer_key">> => <<"c">>
        },
        ?assertMatch({ok, _, _},
            pertisk_eproxy_acme_lego:obtain_certificate(
                ovh, Creds, [<<"example.com">>], <<"ops@example.com">>,
                <<"https://acme-staging-v02.api.letsencrypt.org/directory">>,
                AcmeDir, <<"example-com">>, fun(_, _) -> ok end))
    end).

obtain_certificate_rfc2136_with_fake_lego_test() ->
    with_fake_lego(fun(AcmeDir) ->
        Creds = #{
            <<"nameserver">> => <<"127.0.0.1">>,
            <<"tsig_key_name">> => <<"key">>,
            <<"tsig_secret">> => <<"secret">>
        },
        ?assertMatch({ok, _, _},
            pertisk_eproxy_acme_lego:obtain_certificate(
                rfc2136, Creds, [<<"example.com">>], <<"ops@example.com">>,
                <<"https://acme-staging-v02.api.letsencrypt.org/directory">>,
                AcmeDir, <<"example-com">>, fun(_, _) -> ok end))
    end).

obtain_certificate_cloudns_with_fake_lego_test() ->
    with_fake_lego(fun(AcmeDir) ->
        Creds = #{<<"auth_id">> => <<"1">>, <<"auth_password">> => <<"pw">>},
        ?assertMatch({ok, _, _},
            pertisk_eproxy_acme_lego:obtain_certificate(
                cloudns, Creds, [<<"example.com">>], <<"ops@example.com">>,
                <<"https://acme-staging-v02.api.letsencrypt.org/directory">>,
                AcmeDir, <<"example-com">>, fun(_, _) -> ok end))
    end).

obtain_certificate_easydns_with_fake_lego_test() ->
    with_fake_lego(fun(AcmeDir) ->
        Creds = #{<<"token">> => <<"t">>, <<"key">> => <<"k">>},
        ?assertMatch({ok, _, _},
            pertisk_eproxy_acme_lego:obtain_certificate(
                easydns, Creds, [<<"example.com">>], <<"ops@example.com">>,
                <<"https://acme-staging-v02.api.letsencrypt.org/directory">>,
                AcmeDir, <<"example-com">>, fun(_, _) -> ok end))
    end).

obtain_certificate_dnsmadeeasy_with_fake_lego_test() ->
    with_fake_lego(fun(AcmeDir) ->
        Creds = #{<<"api_key">> => <<"k">>, <<"secret_key">> => <<"s">>},
        ?assertMatch({ok, _, _},
            pertisk_eproxy_acme_lego:obtain_certificate(
                dnsmadeeasy, Creds, [<<"example.com">>], <<"ops@example.com">>,
                <<"https://acme-staging-v02.api.letsencrypt.org/directory">>,
                AcmeDir, <<"example-com">>, fun(_, _) -> ok end))
    end).

obtain_certificate_dynu_with_fake_lego_test() ->
    with_fake_lego(fun(AcmeDir) ->
        Creds = #{<<"api_token">> => <<"tok">>},
        ?assertMatch({ok, _, _},
            pertisk_eproxy_acme_lego:obtain_certificate(
                dynu, Creds, [<<"example.com">>], <<"ops@example.com">>,
                <<"https://acme-staging-v02.api.letsencrypt.org/directory">>,
                AcmeDir, <<"example-com">>, fun(_, _) -> ok end))
    end).

obtain_certificate_binary_provider_with_fake_lego_test() ->
    with_fake_lego(fun(AcmeDir) ->
        Creds = #{<<"MY_DNS_API_KEY">> => <<"secret">>},
        ?assertMatch({ok, _, _},
            pertisk_eproxy_acme_lego:obtain_certificate(
                <<"myprovider">>, Creds, [<<"example.com">>], <<"ops@example.com">>,
                <<"https://acme-staging-v02.api.letsencrypt.org/directory">>,
                AcmeDir, <<"example-com">>, fun(_, _) -> ok end))
    end).

obtain_certificate_progress_callback_raises_test() ->
    with_fake_lego(fun(AcmeDir) ->
        Creds = #{<<"api_key">> => <<"k">>, <<"api_secret">> => <<"s">>},
        Progress = fun(_, _) -> error(progress_boom) end,
        ?assertMatch({ok, _, _},
            pertisk_eproxy_acme_lego:obtain_certificate(
                godaddy, Creds, [<<"example.com">>], <<"ops@example.com">>,
                <<"https://acme-staging-v02.api.letsencrypt.org/directory">>,
                AcmeDir, <<"example-com">>, Progress))
    end).

validate_provider_with_fake_lego_test() ->
    with_fake_lego(fun(_DataDir) ->
        Creds = #{<<"api_key">> => <<"k">>, <<"api_secret">> => <<"s">>},
        ?assertMatch({ok, #{env_var_count := 2, lego_path := _}},
            pertisk_eproxy_acme_lego:validate_provider(godaddy, Creds, lego_work_root()))
    end).

obtain_certificate_google_missing_project_on_obtain_test() ->
    with_fake_lego(fun(AcmeDir) ->
        ?assertMatch(
            {error, missing_project_id},
            pertisk_eproxy_acme_lego:obtain_certificate(
                googleclouddns,
                #{<<"service_account_json">> => <<"{\"type\":\"service_account\"}">>},
                [<<"example.com">>],
                <<"ops@example.com">>,
                <<"https://acme-staging-v02.api.letsencrypt.org/directory">>,
                AcmeDir,
                <<"example-com">>,
                fun(_, _) -> ok end
            )
        )
    end).

obtain_certificate_google_missing_service_account_on_obtain_test() ->
    with_fake_lego(fun(AcmeDir) ->
        ?assertMatch(
            {error, missing_service_account_json},
            pertisk_eproxy_acme_lego:obtain_certificate(
                googleclouddns,
                #{<<"project_id">> => <<"proj">>},
                [<<"example.com">>],
                <<"ops@example.com">>,
                <<"https://acme-staging-v02.api.letsencrypt.org/directory">>,
                AcmeDir,
                <<"example-com">>,
                fun(_, _) -> ok end
            )
        )
    end).

obtain_certificate_customlego_env_json_test() ->
    with_fake_lego(fun(AcmeDir) ->
        Creds = #{<<"env_vars_json">> => <<"{\"MY_DNS_KEY\":\"secret\"}">>},
        ?assertMatch({ok, _, _},
            pertisk_eproxy_acme_lego:obtain_certificate(
                customlego,
                Creds,
                [<<"example.com">>],
                <<"ops@example.com">>,
                <<"https://acme-staging-v02.api.letsencrypt.org/directory">>,
                AcmeDir,
                <<"example-com">>,
                fun(_, _) -> ok end
            ))
    end).

validate_provider_customlego_generic_numeric_env_test() ->
    WorkRoot = lego_work_root(),
    Creds = #{<<"PORT">> => 8080, <<"RATIO">> => 1.5},
    with_fake_lego(fun(_DataDir) ->
        ?assertMatch({ok, #{env_var_count := 2}},
            pertisk_eproxy_acme_lego:validate_provider(customlego, Creds, WorkRoot))
    end).

validate_provider_customlego_env_json_non_object_with_fake_lego_test() ->
    WorkRoot = lego_work_root(),
    with_fake_lego(fun(_DataDir) ->
        ?assertMatch({error, invalid_env_vars_json},
            pertisk_eproxy_acme_lego:validate_provider(
                customlego, #{<<"env_vars_json">> => <<"[1,2]">>}, WorkRoot))
    end).

obtain_certificate_unknown_atom_provider_test() ->
    with_fake_lego(fun(AcmeDir) ->
        Creds = #{<<"MY_DNS_API_KEY">> => <<"secret">>},
        ?assertMatch({ok, _, _},
            pertisk_eproxy_acme_lego:obtain_certificate(
                someprovider,
                Creds,
                [<<"example.com">>],
                <<"ops@example.com">>,
                <<"https://acme-staging-v02.api.letsencrypt.org/directory">>,
                AcmeDir,
                <<"example-com">>,
                fun(_, _) -> ok end
            ))
    end).

validate_provider_route53_optional_with_fake_lego_test() ->
    WorkRoot = lego_work_root(),
    Creds = #{
        <<"access_key_id">> => <<"AKIA">>,
        <<"secret_access_key">> => <<"SECRET">>,
        <<"session_token">> => <<"tok">>,
        <<"region">> => <<"us-east-1">>,
        <<"zone_id">> => <<"Z123">>
    },
    with_fake_lego(fun(_DataDir) ->
        ?assertMatch({ok, #{env_var_count := 5}},
            pertisk_eproxy_acme_lego:validate_provider(route53, Creds, WorkRoot))
    end).

validate_provider_camel_case_single_segment_test() ->
    WorkRoot = lego_work_root(),
    Creds = #{
        <<"accessKeyId">> => <<"AKIA">>,
        <<"secretAccessKey">> => <<"SECRET">>
    },
    with_fake_lego(fun(_DataDir) ->
        ?assertMatch({ok, #{env_var_count := 2}},
            pertisk_eproxy_acme_lego:validate_provider(route53, Creds, WorkRoot))
    end).

validate_provider_list_cred_value_with_fake_lego_test() ->
    WorkRoot = lego_work_root(),
    Creds = #{<<"CUSTOM_ENV">> => "list-value"},
    with_fake_lego(fun(_DataDir) ->
        ?assertMatch({ok, #{env_var_count := 1}},
            pertisk_eproxy_acme_lego:validate_provider(<<"mydns">>, Creds, WorkRoot))
    end).

validate_provider_env_json_empty_key_skipped_test() ->
    WorkRoot = lego_work_root(),
    Creds = #{<<"env_vars_json">> => <<"{\"\":\"x\",\"GOOD\":\"y\"}">>},
    with_fake_lego(fun(_DataDir) ->
        ?assertMatch({ok, #{env_var_count := 1}},
            pertisk_eproxy_acme_lego:validate_provider(customlego, Creds, WorkRoot))
    end).

obtain_certificate_read_cert_unreadable_test() ->
    Dir = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "pertisk-lego-badcrt-" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = file:make_dir(Dir),
    DataDir = filename:join(Dir, "data"),
    ok = file:make_dir(DataDir),
    Bin = filename:join(Dir, "lego"),
    Script = [
        "#!/bin/sh\n",
        "while [ $# -gt 0 ]; do\n",
        "  case \"$1\" in\n",
        "    --path) LEGOPATH=\"$2\"; shift 2;;\n",
        "    run)\n",
        "      mkdir -p \"$LEGOPATH/certificates\"\n",
        "      echo '-----BEGIN CERTIFICATE-----' > \"$LEGOPATH/certificates/example.com.crt\"\n",
        "      echo '-----END CERTIFICATE-----' >> \"$LEGOPATH/certificates/example.com.crt\"\n",
        "      echo '-----BEGIN RSA PRIVATE KEY-----' > \"$LEGOPATH/certificates/example.com.key\"\n",
        "      echo '-----END RSA PRIVATE KEY-----' >> \"$LEGOPATH/certificates/example.com.key\"\n",
        "      rm -f \"$LEGOPATH/certificates/example.com.crt\"\n",
        "      mkdir \"$LEGOPATH/certificates/example.com.crt\"\n",
        "      exit 0;;\n",
        "    *) shift;;\n",
        "  esac\n",
        "done\n",
        "exit 0\n"
    ],
    ok = file:write_file(Bin, Script),
    ok = file:change_mode(Bin, 8#755),
    Old = os:getenv("PERTISK_LEGO_BIN"),
    os:putenv("PERTISK_LEGO_BIN", Bin),
    try
        Creds = #{<<"api_key">> => <<"k">>, <<"api_secret">> => <<"s">>},
        ?assertMatch(
            {error, {lego_read_failed, _, _, _, _}},
            pertisk_eproxy_acme_lego:obtain_certificate(
                godaddy,
                Creds,
                [<<"example.com">>],
                <<"ops@example.com">>,
                <<"https://acme-staging-v02.api.letsencrypt.org/directory">>,
                DataDir,
                <<"example-com">>,
                fun(_, _) -> ok end
            )
        )
    after
        case Old of
            false -> os:unsetenv("PERTISK_LEGO_BIN");
            V -> os:putenv("PERTISK_LEGO_BIN", V)
        end,
        _ = os:cmd("rm -rf " ++ Dir)
    end.

find_lego_executable_no_system_binary_test() ->
    Old = os:getenv("PERTISK_LEGO_BIN"),
    os:putenv("PERTISK_LEGO_BIN", "/nonexistent/lego-missing-xyz"),
    try
        Result = pertisk_eproxy_acme_lego:find_lego_executable(),
        ?assert(Result =:= false orelse is_list(Result))
    after
        case Old of
            false -> os:unsetenv("PERTISK_LEGO_BIN");
            V -> os:putenv("PERTISK_LEGO_BIN", V)
        end
    end.
