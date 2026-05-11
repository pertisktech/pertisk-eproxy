-module(tls_pem_smoke).
-export([run/1]).

run(Path) ->
    {ok, Pem} = file:read_file(Path),
    Ders = [D || {'Certificate', D, not_encrypted} <- public_key:pem_decode(Pem)],
    io:format("PEM certs: ~w~n", [length(Ders)]),
    lists:foreach(
        fun(Der) ->
            Cert = public_key:pkix_decode_cert(Der, otp),
            Tbs = element(2, Cert),
            io:format(
                "outer ~p inner ~p tbs_size ~w~n",
                [element(1, Cert), element(1, Tbs), tuple_size(Tbs)]
            )
        end,
        Ders
    ),
    io:format("describe_listener_pem: ~p~n", [pertisk_eproxy_tls_cert_info:describe_listener_pem(Path)]),
    halt(0).
