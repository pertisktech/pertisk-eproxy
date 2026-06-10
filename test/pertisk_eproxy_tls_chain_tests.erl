-module(pertisk_eproxy_tls_chain_tests).

-include_lib("eunit/include/eunit.hrl").

verify_listener_parity_matching_pem_test() ->
    application:ensure_all_started(lager),
    CertPath = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
    {ok, Pem} = file:read_file(CertPath),
    [Leaf | Chain] = [D || {'Certificate', D, not_encrypted} <- public_key:pem_decode(Pem)],
    ?assertEqual(ok, pertisk_eproxy_tls_chain:verify_listener_parity(CertPath, Leaf, Chain)).

verify_listener_parity_empty_pem_test() ->
    application:ensure_all_started(lager),
    Tmp = tmp_pem(<<"not a cert">>),
    try
        ?assertEqual(ok, pertisk_eproxy_tls_chain:verify_listener_parity(Tmp, <<>>, []))
    after
        file:delete(Tmp)
    end.

tmp_pem(Bin) ->
    Path = filename:join([os:getenv("TMPDIR", "/tmp"),
        "tls_chain_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".pem"]),
    ok = file:write_file(Path, Bin),
    Path.
