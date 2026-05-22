%% @doc RSA key + CSR for ACME finalize (DER), using openssl CLI and a temp .cnf.
-module(pertisk_eproxy_acme_csr).

-export([generate_rsa_csr/1]).

-spec generate_rsa_csr([binary()]) ->
    {ok, #{key_pem := binary(), csr_der := binary()}} | {error, term()}.
generate_rsa_csr([]) ->
    {error, empty_identities};
generate_rsa_csr(Ids) when is_list(Ids) ->
    case pertisk_eproxy_shell:openssl_executable() of
        {error, openssl_not_found} ->
            {error, openssl_not_found};
        {ok, Openssl} ->
            do_openssl(Openssl, Ids)
    end.

do_openssl(Openssl, Ids) ->
    Tmp = mktemp_dir(),
    KeyPath = filename:join(Tmp, "key.pem"),
    CsrPath = filename:join(Tmp, "csr.pem"),
    DerPath = filename:join(Tmp, "csr.der"),
    CnfPath = filename:join(Tmp, "openssl.cnf"),
    try
        [Primary | Rest] = Ids,
        ok = file:write_file(CnfPath, openssl_cnf(Primary, Rest)),
        ReqCmd = lists:flatten(
            io_lib:format("~s req -new -newkey rsa:2048 -nodes -keyout ~s -out ~s -config ~s 2>&1",
                [Openssl, KeyPath, CsrPath, CnfPath])
        ),
        Log = pertisk_eproxy_shell:os_cmd(ReqCmd),
        Res = case {file:read_file(KeyPath), file:read_file(CsrPath)} of
            {{ok, KeyPem}, {ok, _CsrPem}} ->
                DerCmd = lists:flatten(
                    io_lib:format("~s req -in ~s -outform DER -out ~s 2>&1",
                        [Openssl, CsrPath, DerPath])
                ),
                _ = pertisk_eproxy_shell:os_cmd(DerCmd),
                case file:read_file(DerPath) of
                    {ok, Der} when byte_size(Der) > 32 ->
                        {ok, #{key_pem => KeyPem, csr_der => Der}};
                    _ ->
                        {error, {csr_der_failed, Log}}
                end;
            _ ->
                {error, {openssl_csr_failed, Log}}
        end,
        Res
    catch
        C:R:S ->
            {error, {C, R, S}}
    after
        _ = file:del_dir_r(Tmp)
    end.

mktemp_dir() ->
    Base = filename:join(
        os:getenv("TMPDIR", "/tmp"),
        "pertisk_acme_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = file:make_dir(Base),
    Base.

openssl_cnf(Primary, Rest) ->
    DnsLines = dns_lines(Rest, 2),
    [
        "[ req ]\n",
        "default_bits = 2048\n",
        "distinguished_name = req_dn\n",
        "prompt = no\n",
        "req_extensions = v3_req\n\n",
        "[ req_dn ]\n",
        "CN = ", cn_value(Primary), "\n\n",
        "[ v3_req ]\n",
        "subjectAltName = @alt_names\n\n",
        "[ alt_names ]\n",
        "DNS.1 = ", cn_value(Primary), "\n",
        DnsLines
    ].

cn_value(B) when is_binary(B) ->
    binary_to_list(B).

dns_lines([], _N) ->
    [];
dns_lines([H | T], N) ->
    ["DNS.", integer_to_list(N), " = ", cn_value(H), "\n" | dns_lines(T, N + 1)].
