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
