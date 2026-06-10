-module(pertisk_ingress_tls_tests).

-include_lib("eunit/include/eunit.hrl").

ensure_tls() ->
    catch meck:unload(pertisk_ingress_tls),
    case whereis(pertisk_ingress_tls) of
        undefined -> {ok, _} = pertisk_ingress_tls:start_link();
        _ -> ok
    end.

listener_pems() ->
    CertPath = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
    KeyPath = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
    {ok, CertPem} = file:read_file(CertPath),
    {ok, KeyPem} = file:read_file(KeyPath),
    {CertPem, KeyPem}.

with_env(Key, Val, Fun) ->
    Old = os:getenv(Key),
    case Val of
        unset -> os:unsetenv(Key);
        {set, NewVal} -> os:putenv(Key, NewVal)
    end,
    try Fun() after
        case Old of
            false -> os:unsetenv(Key);
            OldVal -> os:putenv(Key, OldVal)
        end
    end.

with_tls(Fun) ->
    ensure_tls(),
    pertisk_ingress_tls:clear(),
    try Fun() after pertisk_ingress_tls:clear() end.

cert_ref_test() ->
    ?assertEqual(<<"k8s/default/my-secret">>, pertisk_ingress_tls:cert_ref(<<"default">>, <<"my-secret">>)).

set_hosts_lookup_remove_test() ->
    with_tls(fun() ->
        {CertPem, KeyPem} = listener_pems(),
        ok = pertisk_ingress_tls:set_hosts([<<"Host.Example">>], {CertPem, KeyPem}),
        ?assert(lists:member("host.example", pertisk_ingress_tls:all_hosts())),
        ?assertMatch({ok, #{cert_pem := CertPem}}, pertisk_ingress_tls:lookup(<<"host.example">>)),
        ok = pertisk_ingress_tls:remove_hosts([<<"host.example">>]),
        ?assertEqual(error, pertisk_ingress_tls:lookup(<<"host.example">>))
    end).

set_hosts_with_paths_test() ->
    with_tls(fun() ->
        {CertPem, KeyPem} = listener_pems(),
        CertPath = "/tmp/tls.crt",
        KeyPath = "/tmp/tls.key",
        ok = pertisk_ingress_tls:set_hosts(
            [<<"paths.example">>], CertPem, KeyPem, CertPath, KeyPath
        ),
        ?assertEqual({ok, {CertPath, KeyPath}}, pertisk_ingress_tls:paths_for_host(<<"paths.example">>))
    end).

wildcard_lookup_test() ->
    with_tls(fun() ->
        {CertPem, KeyPem} = listener_pems(),
        ok = pertisk_ingress_tls:set_hosts([<<"*.wildcard.example">>], {CertPem, KeyPem}),
        ?assertMatch({ok, _}, pertisk_ingress_tls:lookup(<<"sub.wildcard.example">>))
    end).

lookup_skips_invalid_hosts_test() ->
    with_tls(fun() ->
        {CertPem, KeyPem} = listener_pems(),
        ok = pertisk_ingress_tls:set_hosts([<<"*">>, <<"">>, null], {CertPem, KeyPem}),
        ?assertEqual([], pertisk_ingress_tls:all_hosts())
    end).

decode_entry_ok_test() ->
    {CertPem, KeyPem} = listener_pems(),
    ?assertMatch({ok, #{cert := _, private_key := _}},
        pertisk_ingress_tls:decode_entry(#{cert_pem => CertPem, key_pem => KeyPem})).

decode_entry_invalid_test() ->
    ?assertEqual({error, invalid_entry}, pertisk_ingress_tls:decode_entry(#{})),
    ?assertEqual({error, invalid_cert_pem},
        pertisk_ingress_tls:decode_entry(#{cert_pem => <<"bad">>, key_pem => <<"bad">>})).

write_pem_files_test() ->
    TmpDir = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "pertisk_tls_write_" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    _ = file:del_dir_r(TmpDir),
    with_env("PERTISK_K8S_TLS_DIR", {set, TmpDir}, fun() ->
        {CertPem, KeyPem} = listener_pems(),
        {ok, {CertPath, KeyPath}} =
            pertisk_ingress_tls:write_pem_files(<<"ns">>, <<"sec">>, CertPem, KeyPem),
        ?assert(filelib:is_regular(CertPath)),
        ?assert(filelib:is_regular(KeyPath)),
        ?assertEqual(CertPem, element(2, file:read_file(CertPath)))
    end),
    _ = file:del_dir_r(TmpDir).

restore_from_disk_sites_test() ->
    TmpDir = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "pertisk_tls_restore_" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    _ = file:del_dir_r(TmpDir),
    Host = "restore-disk.test",
    CertPath = filename:join([TmpDir, "default", "disk", "tls.crt"]),
    KeyPath = filename:join([TmpDir, "default", "disk", "tls.key"]),
    ok = filelib:ensure_dir(CertPath),
    Cmd = io_lib:format(
        "openssl req -x509 -newkey rsa:2048 -keyout ~s -out ~s -days 1 -nodes "
        "-subj \"/CN=~s\" -addext \"subjectAltName=DNS:~s\" 2>/dev/null",
        [KeyPath, CertPath, Host, Host]
    ),
    _ = os:cmd(lists:flatten(Cmd)),
    with_tls(fun() ->
        with_env("PERTISK_K8S_TLS_DIR", {set, TmpDir}, fun() ->
            Site = #{
                host => list_to_binary(Host),
                backend => <<"web">>,
                ingress_namespace => <<"default">>
            },
            ok = pertisk_ingress_tls:restore_from_disk_sites([Site]),
            ?assert(lists:member(Host, pertisk_ingress_tls:all_hosts()))
        end)
    end),
    _ = file:del_dir_r(TmpDir).

unknown_call_test() ->
    with_tls(fun() ->
        ?assertEqual({error, unknown}, gen_server:call(pertisk_ingress_tls, bogus))
    end).
