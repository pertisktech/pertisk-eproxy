%% @doc Write listener TLS PEM material to stable data directory and return relative paths.
-module(pertisk_eproxy_tls_import).

-export([
    save_listener_pem/2,
    ensure_certificate_row_pem_files/1,
    tls_data_dir/0,
    pem_paths_to_quic_server_material/2
]).

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

%% @doc Write PEM material from a certificates-table row to stable paths for HTTPS SNI.
%% Row map uses atom keys as returned by {@link pertisk_eproxy_db:list_certificates/1}.
-spec ensure_certificate_row_pem_files(map()) -> {ok, {CertPath :: list(), KeyPath :: list()}} | undefined.
ensure_certificate_row_pem_files(Row) when is_map(Row) ->
    CertBin = pem_bin(maps:get(cert_pem, Row, undefined)),
    KeyBin = pem_bin(maps:get(key_pem, Row, undefined)),
    case validate(CertBin, KeyBin) of
        {error, _} ->
            undefined;
        ok ->
            Id = maps:get(id, Row),
            Dir = filename:join(tls_data_dir(), "sni"),
            case ensure_dir(Dir) of
                ok ->
                    CertPath = filename:join(Dir, lists:flatten(io_lib:format("cert-~s.pem", [id_for_filename(Id)]))),
                    KeyPath = filename:join(Dir, lists:flatten(io_lib:format("key-~s.key", [id_for_filename(Id)]))),
                    case {file:write_file(CertPath, CertBin), file:write_file(KeyPath, KeyBin)} of
                        {ok, ok} ->
                            _ = try file:change_mode(KeyPath, 8#600) catch _:_ -> ok end,
                            {ok, {CertPath, KeyPath}};
                        _ ->
                            undefined
                    end;
                {error, _} ->
                    undefined
            end
    end.

pem_bin(undefined) -> <<>>;
pem_bin(B) when is_binary(B) -> B;
pem_bin(L) when is_list(L) -> unicode:characters_to_binary(L, utf8);
pem_bin(_) -> <<>>.

id_for_filename(Id) when is_integer(Id) -> integer_to_list(Id);
id_for_filename(Id) when is_binary(Id) -> binary_to_list(Id);
id_for_filename(Id) when is_list(Id) -> Id;
id_for_filename(Id) -> lists:flatten(io_lib:format("~p", [Id])).

%% @doc Load PEM files as QUIC server material: first certificate DER, chain DERs, decoded private key.
-spec pem_paths_to_quic_server_material(
    file:filename_all(), file:filename_all()
) -> {ok, {LeafDer :: binary(), ChainDers :: [binary()], KeyTerm :: term()}} | undefined.
pem_paths_to_quic_server_material(CertPath, KeyPath) ->
    case {file:read_file(CertPath), file:read_file(KeyPath)} of
        {{ok, CertPem}, {ok, KeyPem}} ->
            Certs = cert_ders_from_pem(CertPem),
            case Certs of
                [] ->
                    undefined;
                [Leaf | Chain] ->
                    case decode_first_private_key_pem(KeyPem) of
                        {ok, KeyTerm} ->
                            {ok, {Leaf, Chain, KeyTerm}};
                        _ ->
                            undefined
                    end
            end;
        _ ->
            undefined
    end.

cert_ders_from_pem(Pem) ->
    [element(2, E) || E <- public_key:pem_decode(Pem), element(1, E) =:= 'Certificate'].

decode_first_private_key_pem(Pem) ->
    case public_key:pem_decode(Pem) of
        [Entry | _] ->
            try
                {ok, public_key:pem_entry_decode(Entry)}
            catch
                _:_ -> {error, decode}
            end;
        [] ->
            {error, empty}
    end.
