%% @doc Ensure HTTP/3 QUIC uses the same PEM material as the Cowboy HTTPS listener.
-module(pertisk_eproxy_tls_chain).

-export([verify_listener_parity/3]).

%% @doc Compare decoded QUIC cert material with 'listener.pem' (TCP TLS certfile).
-spec verify_listener_parity(string(), binary(), [binary()]) -> ok.
verify_listener_parity(CertPath, LeafDer, ChainDers) ->
    case file:read_file(CertPath) of
        {ok, Pem} ->
            PemDers = [
                D
             || {'Certificate', D, not_encrypted} <- public_key:pem_decode(Pem)
            ],
            case PemDers of
                [] ->
                    lager:warning(
                        "HTTP/3 TLS parity: no certificates in ~s (QUIC may not match TCP)",
                        [CertPath]
                    ),
                    ok;
                [PemLeaf | PemChain] ->
                    LeafOk = (PemLeaf =:= LeafDer),
                    ChainOk = (PemChain =:= ChainDers),
                    case {LeafOk, ChainOk} of
                        {true, true} ->
                            lager:info(
                                "HTTP/3 TLS chain matches ~s (~p cert(s) including leaf)",
                                [CertPath, length(PemDers)]
                            );
                        {false, _} ->
                            lager:error(
                                "HTTP/3 TLS leaf DER differs from ~s — Chrome may reject QUIC while TCP works",
                                [CertPath]
                            );
                        {_, false} ->
                            lager:warning(
                                "HTTP/3 TLS intermediate chain differs from ~s "
                                "(QUIC ~p vs PEM ~p intermediate(s))",
                                [CertPath, length(ChainDers), length(PemChain)]
                            )
                    end,
                    ok
            end;
        {error, Reason} ->
            lager:warning("HTTP/3 TLS parity: could not read ~s: ~p", [CertPath, Reason]),
            ok
    end.
