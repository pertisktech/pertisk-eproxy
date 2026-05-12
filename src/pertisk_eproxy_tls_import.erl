%% @doc Write listener TLS PEM material to stable data directory and return relative paths.
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
            Dir = tls_data_dir(),
            case ensure_dir(Dir) of
                ok ->
                    CertPath0 = filename:join(Dir, "listener.pem"),
                    KeyPath0 = filename:join(Dir, "listener.key"),
                    case {file:write_file(CertPath0, CertBin), file:write_file(KeyPath0, KeyBin)} of
                        {ok, ok} ->
                            _ = try file:change_mode(KeyPath0, 8#600) catch _:_ -> ok end,
                            {ok, {iolist_to_binary(CertPath0), iolist_to_binary(KeyPath0)}};
                        _ ->
                            {error, <<"failed to write PEM files">>}
                    end;
                {error, Reason} ->
                    {error, iolist_to_binary(io_lib:format("cannot create tls directory: ~p", [Reason]))}
            end
    end.

tls_data_dir() ->
    case application:get_env(pertisk_eproxy, tls_data_dir) of
        {ok, D} when is_list(D), D =/= [] -> D;
        {ok, D} when is_binary(D), byte_size(D) > 0 -> binary_to_list(D);
        _ -> filename:join("data", "tls")
    end.

ensure_dir(Dir) ->
    case filelib:ensure_dir(filename:join(Dir, "x")) of
        ok ->
            ok;
        {error, R} ->
            {error, R}
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
