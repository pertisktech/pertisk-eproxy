%% @doc Write listener TLS PEM material to disk and return absolute paths.
-module(pertisk_eproxy_tls_import).

-export([save_listener_pem/2]).

-spec save_listener_pem(binary() | iolist(), binary() | iolist()) ->
    {ok, {CertPath :: binary(), KeyPath :: binary()}} | {error, binary()}.
save_listener_pem(CertIn, KeyIn) ->
    CertBin = iolist_to_binary(CertIn),
    KeyBin = iolist_to_binary(KeyIn),
    case validate(CertBin, KeyBin) of
        {error, Msg} ->
            {error, Msg};
        ok ->
            Priv = code:priv_dir(pertisk_eproxy),
            Dir = filename:join(Priv, "tls"),
            case ensure_dir(Dir) of
                ok ->
                    CertPath0 = filename:join(Dir, "listener.pem"),
                    KeyPath0 = filename:join(Dir, "listener.key"),
                    case {file:write_file(CertPath0, CertBin), file:write_file(KeyPath0, KeyBin)} of
                        {ok, ok} ->
                            CertAbs = iolist_to_binary(filename:absname(CertPath0)),
                            KeyAbs = iolist_to_binary(filename:absname(KeyPath0)),
                            _ = try file:change_mode(KeyPath0, 8#600) catch _:_ -> ok end,
                            {ok, {CertAbs, KeyAbs}};
                        _ ->
                            {error, <<"failed to write PEM files">>}
                    end;
                {error, Reason} ->
                    {error, iolist_to_binary(io_lib:format("cannot create tls directory: ~p", [Reason]))}
            end
    end.

ensure_dir(Dir) ->
    case filelib:is_dir(Dir) of
        true ->
            ok;
        false ->
            case file:make_dir(Dir) of
                ok -> ok;
                {error, eexist} -> ok;
                {error, R} -> {error, R}
            end
    end.

validate(Cert, Key) when byte_size(Cert) < 32; byte_size(Key) < 32 ->
    {error, <<"cert_pem and key_pem are required">>};
validate(Cert, Key) ->
    case {binary:match(Cert, <<"BEGIN CERTIFICATE">>), binary:match(Key, <<"BEGIN">>)} of
        {nomatch, _} ->
            {error, <<"cert_pem must contain a PEM certificate (BEGIN CERTIFICATE)">>};
        {_, nomatch} ->
            {error, <<"key_pem must contain a PEM private key (BEGIN … KEY)">>};
        _ ->
            ok
    end.
