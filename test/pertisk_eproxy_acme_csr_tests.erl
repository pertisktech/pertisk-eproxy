-module(pertisk_eproxy_acme_csr_tests).

-include_lib("eunit/include/eunit.hrl").

empty_identities_test() ->
    ?assertEqual({error, empty_identities}, pertisk_eproxy_acme_csr:generate_rsa_csr([])).

generate_rsa_csr_with_openssl_test() ->
    case pertisk_eproxy_shell:openssl_executable() of
        {error, openssl_not_found} ->
            ok;
        {ok, _} ->
            {ok, #{key_pem := Key, csr_der := Csr}} =
                pertisk_eproxy_acme_csr:generate_rsa_csr([<<"example.com">>]),
            ?assert(byte_size(Key) > 0),
            ?assert(byte_size(Csr) > 0)
    end.

generate_rsa_csr_openssl_not_found_test() ->
    meck:new(pertisk_eproxy_shell, [unstick, no_link, passthrough]),
    meck:expect(pertisk_eproxy_shell, openssl_executable, fun() -> {error, openssl_not_found} end),
    try
        ?assertEqual(
            {error, openssl_not_found},
            pertisk_eproxy_acme_csr:generate_rsa_csr([<<"example.com">>])
        )
    after
        pertisk_eproxy_test_helpers:unload_mocks([pertisk_eproxy_shell])
    end.

generate_rsa_csr_der_export_failure_test() ->
    case pertisk_eproxy_shell:openssl_executable() of
        {error, openssl_not_found} ->
            ok;
        {ok, _} ->
            meck:new(pertisk_eproxy_shell, [unstick, no_link, passthrough]),
            meck:expect(pertisk_eproxy_shell, openssl_executable, fun() -> {ok, "openssl"} end),
            meck:expect(pertisk_eproxy_shell, os_cmd, fun(Cmd) ->
                case binary:match(list_to_binary(Cmd), <<" -outform DER ">>) of
                    nomatch ->
                        os:cmd(Cmd);
                    _ ->
                        <<>>
                end
            end),
            try
                ?assertMatch(
                    {error, {csr_der_failed, _}},
                    pertisk_eproxy_acme_csr:generate_rsa_csr([<<"example.com">>])
                )
            after
                pertisk_eproxy_test_helpers:unload_mocks([pertisk_eproxy_shell])
            end
    end.
