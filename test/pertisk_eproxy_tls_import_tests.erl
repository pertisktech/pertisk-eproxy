-module(pertisk_eproxy_tls_import_tests).

-include_lib("eunit/include/eunit.hrl").

validate_rejects_short_pem_test() ->
    ?assertEqual({error, <<"cert_pem and key_pem are required">>},
                 pertisk_eproxy_tls_import:save_listener_pem(<<"x">>, <<"y">>)).

validate_rejects_missing_certificate_marker_test() ->
    Cert = <<"-----BEGIN RSA PRIVATE KEY-----\n">>,
    Key = <<"-----BEGIN RSA PRIVATE KEY-----\n">>,
    ?assertMatch({error, _}, pertisk_eproxy_tls_import:save_listener_pem(Cert, Key)).

save_listener_pem_writes_files_test() ->
    TmpDir = filename:join([os:getenv("TMPDIR", "/tmp"),
        "pertisk_tls_import_" ++ integer_to_list(erlang:unique_integer([positive]))]),
    _ = file:del_dir_r(TmpDir),
    ok = file:make_dir(TmpDir),
    application:set_env(pertisk_eproxy, tls_data_dir, TmpDir),
    Cert = read_priv_pem("listener.pem"),
    Key = read_priv_pem("listener.key"),
    try
        ?assertMatch({ok, {_, _}}, pertisk_eproxy_tls_import:save_listener_pem(Cert, Key)),
        ?assert(filelib:is_file(filename:join(TmpDir, "listener.pem"))),
        ?assert(filelib:is_file(filename:join(TmpDir, "listener.key")))
    after
        application:unset_env(pertisk_eproxy, tls_data_dir),
        _ = file:del_dir_r(TmpDir)
    end.

read_priv_pem(Name) ->
    Path = filename:join([code:priv_dir(pertisk_eproxy), "tls", Name]),
    {ok, Bin} = file:read_file(Path),
    Bin.

validate_rejects_missing_key_marker_test() ->
    Cert = read_priv_pem("listener.pem"),
    Key = <<"this is not a pem private key at all">>,
    ?assertEqual(
        {error, <<"key_pem must contain a PEM private key (BEGIN … KEY)">>},
        pertisk_eproxy_tls_import:save_listener_pem(Cert, Key)
    ).

save_listener_pem_binary_tls_data_dir_test() ->
    TmpDir = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "pertisk_tls_import_bin_" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    _ = file:del_dir_r(TmpDir),
    ok = file:make_dir(TmpDir),
    application:set_env(pertisk_eproxy, tls_data_dir, list_to_binary(TmpDir)),
    Cert = read_priv_pem("listener.pem"),
    Key = read_priv_pem("listener.key"),
    try
        ?assertMatch({ok, {_, _}}, pertisk_eproxy_tls_import:save_listener_pem(Cert, Key))
    after
        application:unset_env(pertisk_eproxy, tls_data_dir),
        _ = file:del_dir_r(TmpDir)
    end.

save_listener_pem_cannot_create_dir_test() ->
    TmpBase = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "pertisk_tls_block_" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    Blocker = TmpBase ++ ".file",
    ok = file:write_file(Blocker, <<>>),
    BadDir = Blocker ++ "/nested",
    application:set_env(pertisk_eproxy, tls_data_dir, BadDir),
    Cert = read_priv_pem("listener.pem"),
    Key = read_priv_pem("listener.key"),
    try
        ?assertMatch({error, _}, pertisk_eproxy_tls_import:save_listener_pem(Cert, Key))
    after
        application:unset_env(pertisk_eproxy, tls_data_dir),
        _ = file:delete(Blocker)
    end.
