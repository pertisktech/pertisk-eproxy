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

listener_cert_rows_missing_paths_test() ->
    StartedHere = ensure_config_started(),
    BaseConfig = pertisk_eproxy_config:get_config(),
    Config = maps:without([tls_cert_file, tls_key_file], BaseConfig),
    try
        ok = pertisk_eproxy_config:put_config(Config),
        ?assertEqual([], pertisk_eproxy_tls_cert_info:listener_cert_rows())
    after
        ok = pertisk_eproxy_config:put_config(BaseConfig),
        maybe_stop_config(StartedHere)
    end.

listener_cert_rows_unreadable_pem_test() ->
    StartedHere = ensure_config_started(),
    BaseConfig = pertisk_eproxy_config:get_config(),
    Tmp = tmp_garbage_pem(),
    Config = BaseConfig#{
        tls_cert_file => Tmp,
        tls_key_file => Tmp
    },
    try
        ok = pertisk_eproxy_config:put_config(Config),
        ?assertEqual([], pertisk_eproxy_tls_cert_info:listener_cert_rows())
    after
        ok = pertisk_eproxy_config:put_config(BaseConfig),
        file:delete(Tmp),
        maybe_stop_config(StartedHere)
    end.

listener_cert_rows_site_cert_list_id_test() ->
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
        certificate => "listener-tls",
        routes => [#{path => <<"/">>, path_type => prefix}]
    }],
    try
        ok = pertisk_eproxy_config:put_config(Config),
        ok = pertisk_eproxy_config:sync_ingress(Sites, []),
        [Row] = pertisk_eproxy_tls_cert_info:listener_cert_rows(),
        ?assertEqual([SiteHost], maps:get(<<"sites">>, Row))
    after
        ok = pertisk_eproxy_config:put_config(BaseConfig),
        ok = pertisk_eproxy_config:sync_ingress(BaseSites, []),
        maybe_stop_config(StartedHere)
    end.

listener_cert_rows_empty_cert_paths_test() ->
    StartedHere = ensure_config_started(),
    BaseConfig = pertisk_eproxy_config:get_config(),
    Config = BaseConfig#{tls_cert_file => <<>>, tls_key_file => <<>>},
    try
        ok = pertisk_eproxy_config:put_config(Config),
        ?assertEqual([], pertisk_eproxy_tls_cert_info:listener_cert_rows())
    after
        ok = pertisk_eproxy_config:put_config(BaseConfig),
        maybe_stop_config(StartedHere)
    end.

listener_cert_rows_empty_list_paths_test() ->
    StartedHere = ensure_config_started(),
    BaseConfig = pertisk_eproxy_config:get_config(),
    Config = BaseConfig#{tls_cert_file => [], tls_key_file => []},
    try
        ok = pertisk_eproxy_config:put_config(Config),
        ?assertEqual([], pertisk_eproxy_tls_cert_info:listener_cert_rows())
    after
        ok = pertisk_eproxy_config:put_config(BaseConfig),
        maybe_stop_config(StartedHere)
    end.

listener_cert_rows_ignores_null_certificate_site_test() ->
    StartedHere = ensure_config_started(),
    BaseConfig = pertisk_eproxy_config:get_config(),
    BaseSites = pertisk_eproxy_config:get_sites(),
    CertPath = listener_pem_path(),
    KeyPath = listener_key_path(),
    Config = BaseConfig#{
        tls_cert_file => CertPath,
        tls_key_file => KeyPath
    },
    Sites = [
        #{host => <<"orphan.example">>, backend => <<"web">>, certificate => null, routes => []}
    ],
    try
        ok = pertisk_eproxy_config:put_config(Config),
        ok = pertisk_eproxy_config:sync_ingress(Sites, []),
        [Row] = pertisk_eproxy_tls_cert_info:listener_cert_rows(),
        ?assertEqual([], maps:get(<<"sites">>, Row))
    after
        ok = pertisk_eproxy_config:put_config(BaseConfig),
        ok = pertisk_eproxy_config:sync_ingress(BaseSites, []),
        maybe_stop_config(StartedHere)
    end.

describe_pem_data_placeholder_hosts_test() ->
    Pem = placeholder_cert_pem(),
    {ok, Info} = pertisk_eproxy_tls_cert_info:describe_pem_data(Pem),
    ?assertEqual([<<"TLS listener">>], maps:get(hosts, Info)).

describe_pem_data_prefers_real_host_over_placeholder_test() ->
    Placeholder = placeholder_cert_pem(),
    {ok, Listener} = file:read_file(listener_pem_path()),
    Chain = <<Placeholder/binary, "\n", Listener/binary>>,
    {ok, Info} = pertisk_eproxy_tls_cert_info:describe_pem_data(Chain),
    Hosts = maps:get(hosts, Info),
    ?assertNotEqual([<<"TLS listener">>], Hosts),
    ?assert(length(Hosts) > 0).

describe_pem_data_san_dns_names_test() ->
    Pem = san_cert_pem(),
    {ok, Info} = pertisk_eproxy_tls_cert_info:describe_pem_data(Pem),
    Hosts = maps:get(hosts, Info),
    ?assert(lists:member(<<"san.example">>, Hosts)),
    ?assert(lists:member(<<"primary.example">>, Hosts)).

describe_pem_data_corrupt_der_test() ->
    Pem = <<"-----BEGIN CERTIFICATE-----\nQUJD\n-----END CERTIFICATE-----">>,
    ?assertEqual(error, pertisk_eproxy_tls_cert_info:describe_pem_data(Pem)).

describe_pem_data_all_placeholder_chain_test() ->
    P1 = placeholder_cert_pem(),
    P2 = placeholder_cert_pem(),
    Chain = <<P1/binary, "\n", P2/binary>>,
    {ok, Info} = pertisk_eproxy_tls_cert_info:describe_pem_data(Chain),
    ?assertEqual([<<"TLS listener">>], maps:get(hosts, Info)).

describe_pem_data_full_dn_cert_test() ->
    Pem = full_dn_cert_pem(),
    {ok, Info} = pertisk_eproxy_tls_cert_info:describe_pem_data(Pem),
    Issuer = maps:get(issuer, Info),
    ?assert(byte_size(Issuer) > 0),
    ?assertNotEqual(nomatch, binary:match(Issuer, <<"CN=">>)).

describe_pem_data_skips_invalid_trailing_cert_test() ->
    {ok, Listener} = file:read_file(listener_pem_path()),
    Bad = <<"-----BEGIN CERTIFICATE-----\nQUJD\n-----END CERTIFICATE-----">>,
    Chain = <<Listener/binary, "\n", Bad/binary>>,
    {ok, Info} = pertisk_eproxy_tls_cert_info:describe_pem_data(Chain),
    ?assert(length(maps:get(hosts, Info)) > 0).

describe_pem_data_long_validity_general_time_test() ->
    Pem = long_validity_cert_pem(),
    {ok, Info} = pertisk_eproxy_tls_cert_info:describe_pem_data(Pem),
    ?assert(is_binary(maps:get(not_after, Info))),
    ?assert(byte_size(maps:get(not_after, Info)) > 0).

listener_cert_rows_site_list_host_test() ->
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
        host => binary_to_list(SiteHost),
        backend => <<"web">>,
        certificate => <<"listener-tls">>,
        routes => []
    }],
    try
        ok = pertisk_eproxy_config:put_config(Config),
        ok = pertisk_eproxy_config:sync_ingress(Sites, []),
        [Row] = pertisk_eproxy_tls_cert_info:listener_cert_rows(),
        ?assertEqual([SiteHost], maps:get(<<"sites">>, Row))
    after
        ok = pertisk_eproxy_config:put_config(BaseConfig),
        ok = pertisk_eproxy_config:sync_ingress(BaseSites, []),
        maybe_stop_config(StartedHere)
    end.

tmp_garbage_pem() ->
    Path = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "bad_cert_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".pem"
    ]),
    ok = file:write_file(Path, <<"not-a-valid-pem">>),
    Path.

long_validity_cert_pem() ->
    Base = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "long_valid_" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    CertPath = Base ++ ".pem",
    KeyPath = Base ++ ".key",
    Cmd = "openssl req -x509 -newkey rsa:2048 -nodes -days 36500 "
        "-subj '/CN=long.example' "
        "-keyout " ++ KeyPath ++ " -out " ++ CertPath ++ " 2>/dev/null",
    os:cmd(Cmd),
    {ok, Pem} = file:read_file(CertPath),
    _ = file:delete(CertPath),
    _ = file:delete(KeyPath),
    Pem.

full_dn_cert_pem() ->
    Base = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "full_dn_" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    CertPath = Base ++ ".pem",
    KeyPath = Base ++ ".key",
    Cmd = "openssl req -x509 -newkey rsa:2048 -nodes -days 1 "
        "-subj '/C=US/O=Test Org/OU=Engineering/CN=dn.example' "
        "-keyout " ++ KeyPath ++ " -out " ++ CertPath ++ " 2>/dev/null",
    os:cmd(Cmd),
    {ok, Pem} = file:read_file(CertPath),
    _ = file:delete(CertPath),
    _ = file:delete(KeyPath),
    Pem.

san_cert_pem() ->
    Base = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "san_cert_" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    CertPath = Base ++ ".pem",
    KeyPath = Base ++ ".key",
    Cmd = "openssl req -x509 -newkey rsa:2048 -nodes -days 1 "
        "-subj '/CN=primary.example' "
        "-addext 'subjectAltName=DNS:san.example' "
        "-keyout " ++ KeyPath ++ " -out " ++ CertPath ++ " 2>/dev/null",
    os:cmd(Cmd),
    {ok, Pem} = file:read_file(CertPath),
    _ = file:delete(CertPath),
    _ = file:delete(KeyPath),
    Pem.

placeholder_cert_pem() ->
    Base = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "placeholder_cert_" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    CertPath = Base ++ ".pem",
    KeyPath = Base ++ ".key",
    Cmd = "openssl req -x509 -newkey rsa:2048 -nodes -days 1 "
        "-subj '/O=Placeholder Org' "
        "-keyout " ++ KeyPath ++ " -out " ++ CertPath ++ " 2>/dev/null",
    os:cmd(Cmd),
    {ok, Pem} = file:read_file(CertPath),
    _ = file:delete(CertPath),
    _ = file:delete(KeyPath),
    Pem.