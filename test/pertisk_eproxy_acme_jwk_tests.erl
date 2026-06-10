-module(pertisk_eproxy_acme_jwk_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").
-include_lib("jose/include/jose_jwk.hrl").

passthrough_non_jwk_test() ->
    ?assertEqual(42, pertisk_eproxy_acme_jwk:normalize_ec_key(42)).

list_wraps_first_element_test() ->
    Inner = #jose_jwk{kty = {jose_jwk_kty_ec, #'ECPrivateKey'{version = 1}}},
    ?assertEqual(Inner, pertisk_eproxy_acme_jwk:normalize_ec_key([Inner, other])).

ec_version_one_unchanged_test() ->
    Ec = #'ECPrivateKey'{version = 1, parameters = secp256r1},
    Jwk = #jose_jwk{kty = {jose_jwk_kty_ec, Ec}},
    ?assertEqual(Jwk, pertisk_eproxy_acme_jwk:normalize_ec_key(Jwk)).

ec_version_normalized_test() ->
    Ec = #'ECPrivateKey'{version = ecPrivkeyVer1, parameters = secp256r1},
    Jwk = #jose_jwk{kty = {jose_jwk_kty_ec, Ec}},
    Normalized = pertisk_eproxy_acme_jwk:normalize_ec_key(Jwk),
    {jose_jwk_kty_ec, #'ECPrivateKey'{version = 1}} = Normalized#jose_jwk.kty.

non_ec_jwk_passthrough_test() ->
    Jwk = #jose_jwk{kty = {jose_jwk_kty_rsa, #'RSAPrivateKey'{}}},
    ?assertEqual(Jwk, pertisk_eproxy_acme_jwk:normalize_ec_key(Jwk)).
