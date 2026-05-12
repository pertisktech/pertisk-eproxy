%% @doc Normalize EC account keys for jose on OTP 28+ (PEM decode uses #'ECPrivateKey'{version = ecPrivkeyVer1}).
-module(pertisk_eproxy_acme_jwk).

-export([normalize_ec_key/1]).

-include_lib("public_key/include/public_key.hrl").
-include_lib("jose/include/jose_jwk.hrl").

-spec normalize_ec_key(term()) -> term().
normalize_ec_key([J | _]) ->
    normalize_ec_key(J);
normalize_ec_key(#jose_jwk{kty = {jose_jwk_kty_ec, #'ECPrivateKey'{} = Ec}} = Jwk) ->
    case Ec#'ECPrivateKey'.version of
        1 -> Jwk;
        _ -> Jwk#jose_jwk{kty = {jose_jwk_kty_ec, Ec#'ECPrivateKey'{version = 1}}}
    end;
normalize_ec_key(Jwk) ->
    Jwk.
