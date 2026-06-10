-module(pertisk_eproxy_tls_cert_info_tests).

-include_lib("eunit/include/eunit.hrl").

describe_pem_data_listener_pem_fixture_test() ->
    {ok, Pem} = file:read_file(listener_pem_path()),
    {ok, Info} = pertisk_eproxy_tls_cert_info:describe_pem_data(Pem),
    Hosts = maps:get(hosts, Info),
    ?assert(is_list(Hosts)),
    ?assert(length(Hosts) > 0),
    ?assert(is_binary(maps:get(not_before, Info))),
    ?assert(is_binary(maps:get(not_after, Info))),
    ?assert(is_binary(maps:get(issuer, Info))).

describe_pem_data_accepts_iolist_test() ->
    {ok, Pem} = file:read_file(listener_pem_path()),
    {ok, Info} = pertisk_eproxy_tls_cert_info:describe_pem_data([Pem]),
    ?assert(is_map(Info)).

describe_pem_data_empty_returns_error_test() ->
    ?assertEqual(error, pertisk_eproxy_tls_cert_info:describe_pem_data(<<>>)).

describe_pem_data_invalid_returns_error_test() ->
    ?assertEqual(error, pertisk_eproxy_tls_cert_info:describe_pem_data(<<"not a pem">>)).

describe_listener_pem_nonexistent_returns_error_test() ->
    ?assertEqual(error, pertisk_eproxy_tls_cert_info:describe_listener_pem("/nonexistent/path/to/cert.pem")).

describe_listener_pem_binary_path_test() ->
    {ok, Info} = pertisk_eproxy_tls_cert_info:describe_listener_pem(list_to_binary(listener_pem_path())),
    ?assert(is_map(Info)).

listener_cert_rows_returns_list_test() ->
    Result = pertisk_eproxy_tls_cert_info:listener_cert_rows(),
    ?assert(is_list(Result)).

listener_cert_rows_with_listener_fixture_test() ->
    StartedHere = ensure_config_started(),
    BaseConfig = pertisk_eproxy_config:get_config(),
    BaseSites = pertisk_eproxy_config:get_sites(),
    CertPath = listener_pem_path(),
    KeyPath = listener_key_path(),
    {ok, Info} = pertisk_eproxy_tls_cert_info:describe_listener_pem(CertPath),
    [SiteHost | _] = maps:get(hosts, Info),
    Config = BaseConfig#{
        tls_cert_file => CertPath,
        tls_key_file => KeyPath
    },
    Sites = [#{
        host => SiteHost,
        backend => <<"web">>,
        certificate => <<"listener-tls">>,
        routes => [#{path => <<"/">>, path_type => prefix}]
    }],
    try
        ok = pertisk_eproxy_config:put_config(Config),
        ok = pertisk_eproxy_config:sync_ingress(Sites, []),
        [Row] = pertisk_eproxy_tls_cert_info:listener_cert_rows(),
        ?assertEqual(<<"listener-tls">>, maps:get(<<"id">>, Row)),
        ?assertEqual([SiteHost], maps:get(<<"sites">>, Row)),
        ?assert(is_list(maps:get(<<"hosts">>, Row))),
        ?assert(is_binary(maps:get(<<"issuer">>, Row)))
    after
        ok = pertisk_eproxy_config:put_config(BaseConfig),
        ok = pertisk_eproxy_config:sync_ingress(BaseSites, []),
        maybe_stop_config(StartedHere)
    end.

ensure_config_started() ->
    application:ensure_all_started(lager),
    case whereis(pertisk_eproxy_config) of
        undefined ->
            {ok, _} = pertisk_eproxy_config:start_link(),
            true;
        _ ->
            false
    end.

maybe_stop_config(true) ->
    case whereis(pertisk_eproxy_config) of
        undefined -> ok;
        Pid ->
            unlink(Pid),
            exit(Pid, shutdown),
            ok
    end;
maybe_stop_config(false) ->
    ok.

listener_pem_path() ->
    filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]).

listener_key_path() ->
    filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]).