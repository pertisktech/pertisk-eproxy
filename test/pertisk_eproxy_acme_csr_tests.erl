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
