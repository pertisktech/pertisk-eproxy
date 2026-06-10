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
