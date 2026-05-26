%% @doc Minimal ACME v2 (RFC 8555) client: DNS-01 (account, order, challenges, finalize, PEM chain).
-module(pertisk_eproxy_acme_client).

-export([obtain_certificate/1]).

-type dns_add_fun() :: fun((TxtFqdn :: binary(), Value :: binary()) -> {ok, term()} | {error, term()}).
-type dns_del_fun() :: fun((Opaque :: term()) -> ok | {error, term()}).

-type progress_fun() :: fun((Phase :: binary(), Message :: binary()) -> any()).

-type obtain_opts() :: #{
    directory_url := binary() | string(),
    account_jwk := term(),
    account_kid := undefined | binary(),
    contact_email := binary(),
    terms_agreed := boolean(),
    identifiers := [binary()],
    csr_der := binary(),
    dns_add := dns_add_fun(),
    dns_del := dns_del_fun(),
    %% Optional: sleep (ms) after publishing TXT before triggering challenges (DNS-01 propagation).
    dns_propagation_delay_ms => non_neg_integer(),
    %% Optional: UI / logging hook (phase and message are UTF-8 binaries).
    progress => progress_fun()
}.

-spec obtain_certificate(obtain_opts()) -> {ok, binary(), binary() | undefined} | {error, term()}.
obtain_certificate(Opts) ->
    try do_obtain(Opts) of
        {ok, Pem, Kid} -> {ok, Pem, Kid};
        {error, _} = E -> E
    catch
        throw:{acme, Reason} -> {error, Reason};
        C:R:S -> {error, {C, R, S}}
    end.

do_obtain(Opts) ->
    DirUrl = bin(maps:get(directory_url, Opts)),
    maybe_progress(Opts, <<"directory">>, <<"Contacted ACME directory">>),
    {ok, Dir} = http_get_json(DirUrl),
    NewNonce = bin(maps:get(<<"newNonce">>, Dir)),
    NewAccount = bin(maps:get(<<"newAccount">>, Dir)),
    NewOrder = bin(maps:get(<<"newOrder">>, Dir)),
    Jwk = pertisk_eproxy_acme_jwk:normalize_ec_key(maps:get(account_jwk, Opts)),
    Nonce0 = fetch_nonce(NewNonce),
    Kid0 = maps:get(account_kid, Opts, undefined),
    {Kid, Nonce1} = ensure_account(Jwk, Kid0, Nonce0, NewAccount, Opts),
    maybe_progress(Opts, <<"account">>, <<"ACME account ready">>),
    Idents = [#{<<"type">> => <<"dns">>, <<"value">> => I} || I <- maps:get(identifiers, Opts)],
    OrderBody = #{<<"identifiers">> => Idents},
    {ok, OrderUrl, AuthUrls, FinalizeUrl, Nonce2} = new_order(Jwk, Kid, Nonce1, NewOrder, OrderBody),
    maybe_progress(Opts, <<"order">>, <<"Certificate order created">>),
    {DnsTasks, Nonce3} = collect_dns_challenges(Jwk, Kid, Nonce2, AuthUrls, []),
    maybe_progress(Opts, <<"authorizations">>, <<"DNS-01 challenge tokens prepared">>),
    Opaques = present_dns_records(DnsTasks, maps:get(dns_add, Opts), []),
    maybe_progress(Opts, <<"dns_txt">>, <<"DNS TXT records published at provider">>),
    case maps:get(dns_propagation_delay_ms, Opts, 0) of
        Ms when is_integer(Ms), Ms > 0 ->
            maybe_progress(
                Opts,
                <<"dns_propagation">>,
                iolist_to_binary(io_lib:format("Waiting ~w ms for DNS propagation", [Ms]))
            ),
            timer:sleep(Ms);
        _ ->
            maybe_progress(Opts, <<"dns_propagation">>, <<"Skipping DNS propagation delay">>),
            ok
    end,
    try
        maybe_progress(Opts, <<"challenges">>, <<"Requesting CA to validate DNS-01">>),
        Nonce4 = trigger_challenges(Jwk, Kid, Nonce3, DnsTasks),
        maybe_progress(Opts, <<"validation">>, <<"CA is validating; waiting for order to become ready">>),
        ok = wait_order_ready(Jwk, Kid, Nonce4, OrderUrl, 120),
        CsrDer = maps:get(csr_der, Opts),
        maybe_progress(Opts, <<"finalize">>, <<"Finalizing certificate with CA">>),
        {ok, Nonce5} = post_finalize(Jwk, Kid, NewNonce, bin(FinalizeUrl), CsrDer),
        maybe_progress(Opts, <<"certificate">>, <<"Downloading issued certificate chain">>),
        {ok, Pem} = fetch_cert_chain(Jwk, Kid, Nonce5, OrderUrl, 45),
        maybe_progress(Opts, <<"chain">>, <<"Certificate chain received">>),
        {ok, Pem, Kid}
    after
        lists:foreach(fun(O) -> _ = (maps:get(dns_del, Opts))(O) end, Opaques)
    end.

%% ---------------------------------------------------------------------------
ensure_account(Jwk, undefined, Nonce, NewAccountUrl, Opts) ->
    Body = #{
        <<"termsOfServiceAgreed">> => maps:get(terms_agreed, Opts),
        <<"contact">> => [<<"mailto:", (maps:get(contact_email, Opts))/binary>>]
    },
    {ok, _St, Hdrs, _Resp, Nonce2} = post_jws(NewAccountUrl, Jwk, undefined, Nonce, NewAccountUrl, Body),
    Loc = header_location(Hdrs),
    case Loc of
        undefined -> throw({acme, no_account_location});
        _ -> {iolist_to_binary(Loc), Nonce2}
    end;
ensure_account(_Jwk, Kid, Nonce, _NewAccount, _Opts) when is_binary(Kid) ->
    {Kid, Nonce}.

new_order(Jwk, Kid, Nonce, NewOrderUrl, Body) ->
    {ok, _St, Hdrs, Resp, Nonce2} = post_jws(NewOrderUrl, Jwk, Kid, Nonce, NewOrderUrl, Body),
    Loc = header_location(Hdrs),
    case Loc of
        undefined -> throw({acme, no_order_location});
        _ ->
            OrderUrl = iolist_to_binary(Loc),
            Auths = maps:get(<<"authorizations">>, Resp),
            Fin = maps:get(<<"finalize">>, Resp),
            {ok, OrderUrl, Auths, Fin, Nonce2}
    end.

collect_dns_challenges(_Jwk, _Kid, Nonce, [], Acc) ->
    {lists:reverse(Acc), Nonce};
collect_dns_challenges(Jwk, Kid, Nonce, [AuthUrl | Rest], Acc) ->
    AuthUrlB = bin(AuthUrl),
    {ok, Auth, Nonce2} = post_as_get_json(Jwk, Kid, Nonce, AuthUrlB, AuthUrlB),
    Chs = maps:get(<<"challenges">>, Auth),
    Ident = maps:get(<<"identifier">>, Auth),
    DnsName = maps:get(<<"value">>, Ident),
    case lists:search(fun(C) -> maps:get(<<"type">>, C) =:= <<"dns-01">> end, Chs) of
        false ->
            throw({acme, {no_dns01, DnsName}});
        {value, Ch} ->
            Token = maps:get(<<"token">>, Ch),
            ChUrl = maps:get(<<"url">>, Ch),
            Thumb = jose_jwk:thumbprint(Jwk),
            KeyAuth = <<Token/binary, $., Thumb/binary>>,
            Digest = jose_jwa_base64url:encode(crypto:hash(sha256, KeyAuth)),
            TxtFqdn = dns_txt_name(DnsName),
            collect_dns_challenges(Jwk, Kid, Nonce2, Rest, [{TxtFqdn, Digest, ChUrl} | Acc])
    end.

dns_txt_name(<<$*, $., Rest/binary>>) ->
    <<"_acme-challenge.", Rest/binary>>;
dns_txt_name(Ident) ->
    <<"_acme-challenge.", Ident/binary>>.

present_dns_records([], _Add, Opq) ->
    lists:reverse(Opq);
present_dns_records([{TxtFqdn, Digest, _ChUrl} | T], Add, Opq) ->
    case Add(TxtFqdn, Digest) of
        {ok, O} -> present_dns_records(T, Add, [O | Opq]);
        {error, R} -> throw({acme, {dns_add, R}})
    end.

trigger_challenges(Jwk, Kid, Nonce, Tasks) ->
    lists:foldl(
        fun({_Fqdn, _Dig, ChUrl}, N0) ->
            ChUrlB = bin(ChUrl),
            {ok, _, _, _, N1} = post_jws(ChUrlB, Jwk, Kid, N0, ChUrlB, #{}),
            N1
        end,
        Nonce,
        Tasks
    ).

wait_order_ready(Jwk, Kid, Nonce0, OrderUrl, MaxI) ->
    wait_order_ready(Jwk, Kid, Nonce0, OrderUrl, MaxI, 0).

wait_order_ready(Jwk, Kid, Nonce0, OrderUrl, Max, I) when I < Max ->
    {ok, Ord, Nonce1} = post_as_get_json(Jwk, Kid, Nonce0, OrderUrl, OrderUrl),
    case maps:get(<<"status">>, Ord) of
        <<"ready">> ->
            ok;
        <<"valid">> ->
            ok;
        <<"invalid">> ->
            AuthUrls = maps:get(<<"authorizations">>, Ord, []),
            log_authz_dns01_failures(Jwk, Kid, Nonce1, AuthUrls),
            Failures = collect_authz_dns01_failures(Jwk, Kid, Nonce1, AuthUrls),
            throw({acme, {order_invalid, Ord, Failures}});
        _ ->
            timer:sleep(2000),
            wait_order_ready(Jwk, Kid, Nonce1, OrderUrl, Max, I + 1)
    end;
wait_order_ready(_, _, _, _, _, _) ->
    throw({acme, order_timeout}).

post_finalize(Jwk, Kid, NewNonceUrl, FinalizeUrl, CsrDer) ->
    Nonce = fetch_nonce(NewNonceUrl),
    CsrB64 = jose_jwa_base64url:encode(CsrDer),
    Body = #{<<"csr">> => CsrB64},
    {ok, _St, _Hdrs, Ord, Nonce2} = post_jws(FinalizeUrl, Jwk, Kid, Nonce, FinalizeUrl, Body),
    case maps:get(<<"status">>, Ord) of
        <<"invalid">> -> throw({acme, {finalize_invalid, Ord}});
        _ -> {ok, Nonce2}
    end.

%% ---------------------------------------------------------------------------
fetch_cert_chain(Jwk, Kid, Nonce0, OrderUrl, Max) ->
    fetch_cert_chain(Jwk, Kid, Nonce0, OrderUrl, Max, 0).

fetch_cert_chain(Jwk, Kid, Nonce0, OrderUrl, Max, I) when I < Max ->
    {ok, Ord, Nonce1} = post_as_get_json(Jwk, Kid, Nonce0, OrderUrl, OrderUrl),
    case maps:get(<<"certificate">>, Ord, undefined) of
        undefined ->
            timer:sleep(2000),
            fetch_cert_chain(Jwk, Kid, Nonce1, OrderUrl, Max, I + 1);
        CertUrl ->
            {ok, Pem, _Nonce2} = post_as_get_pem(Jwk, Kid, Nonce1, bin(CertUrl), bin(CertUrl)),
            {ok, Pem}
    end;
fetch_cert_chain(_, _, _, _, _, _) ->
    throw({acme, cert_timeout}).

%% ---------------------------------------------------------------------------
post_as_get_json(Jwk, Kid, Nonce, Url, UrlForJws) ->
    {ok, St, Hdrs, BodyMap, Nonce2} = post_jws_raw(Url, Jwk, Kid, Nonce, UrlForJws, post_as_get),
    case St of
        200 -> {ok, BodyMap, nonce_from_headers(Hdrs, Nonce2)};
        _ -> throw({acme, {post_as_get, St, BodyMap}})
    end.

post_as_get_pem(Jwk, Kid, Nonce, Url, UrlForJws) ->
    BodyIo = sign_jws_body(Jwk, Kid, Nonce, UrlForJws, post_as_get),
    Enc = thoas:encode(BodyIo),
    {ok, St, Hdrs, Body} = http_post(Url, Enc),
    N2 = nonce_from_headers(Hdrs),
    case St of
        200 -> {ok, iolist_to_binary(Body), N2};
        _ -> throw({acme, {cert_pem, St, Body}})
    end.

post_jws(Url, Jwk, Kid, Nonce, UrlForJws, PayloadMap) when is_map(PayloadMap) ->
    {ok, St, Hdrs, BodyMap, Nonce2} = post_jws_raw(Url, Jwk, Kid, Nonce, UrlForJws, PayloadMap),
    {ok, St, Hdrs, BodyMap, nonce_from_headers(Hdrs, Nonce2)}.

post_jws_raw(Url, Jwk, Kid, Nonce, UrlForJws, Payload) ->
    post_jws_raw(Url, Jwk, Kid, Nonce, UrlForJws, Payload, 1).

post_jws_raw(Url, Jwk, Kid, Nonce, UrlForJws, Payload, RetriesLeft) ->
    BodyIo = sign_jws_body(Jwk, Kid, Nonce, UrlForJws, Payload),
    Enc = thoas:encode(BodyIo),
    {ok, St, Hdrs, BodyBin} = http_post(Url, Enc),
    Nonce2 = nonce_from_headers(Hdrs),
    case St of
        200 ->
            case thoas:decode(iolist_to_binary(BodyBin)) of
                {ok, Map} -> {ok, St, Hdrs, Map, Nonce2};
                {error, R} -> throw({acme, {bad_json, R, BodyBin}})
            end;
        201 ->
            case thoas:decode(iolist_to_binary(BodyBin)) of
                {ok, Map} -> {ok, St, Hdrs, Map, Nonce2};
                {error, R} -> throw({acme, {bad_json, R, BodyBin}})
            end;
        400 when RetriesLeft > 0 ->
            case is_bad_nonce_response(BodyBin) of
                true ->
                    %% Boulder may reject an old replay nonce. Retry once with
                    %% the fresh replay-nonce returned in response headers.
                    RetryNonce = nonce_from_headers(Hdrs, Nonce2),
                    post_jws_raw(Url, Jwk, Kid, RetryNonce, UrlForJws, Payload, RetriesLeft - 1);
                false ->
                    throw({acme, {http, St, BodyBin}})
            end;
        _ ->
            throw({acme, {http, St, BodyBin}})
    end.

is_bad_nonce_response(BodyBin0) ->
    BodyBin = iolist_to_binary(BodyBin0),
    Lower = string:lowercase(BodyBin),
    binary:match(Lower, <<"badnonce">>) =/= nomatch.

sign_jws_body(Jwk, Kid, Nonce, Url, post_as_get) ->
    PayloadBin = <<>>,
    sign_jws_body(Jwk, Kid, Nonce, Url, PayloadBin);
sign_jws_body(Jwk, Kid, Nonce, Url, PayloadMap) when is_map(PayloadMap) ->
    PayloadBin = thoas:encode(PayloadMap),
    sign_jws_body(Jwk, Kid, Nonce, Url, PayloadBin);
sign_jws_body(Jwk, Kid, Nonce, Url, PayloadBin) when is_binary(PayloadBin) ->
    %% RFC 8555 §6.2: alg, (jwk OR kid), nonce, url MUST appear in the *protected* header.
    %% jose_jws:sign/4 puts a non-empty Header map in the unprotected "header" field (RFC7515 §7.2.2),
    %% which Boulder rejects ("Parse error reading JWS"). Build flattened JWS by hand.
    {_, PubMap} = jose_jwk:to_public_map(jose_jwk:to_public(Jwk)),
    Protected0 = #{
        <<"alg">> => <<"ES256">>,
        <<"nonce">> => Nonce,
        <<"url">> => Url
    },
    Protected = case Kid of
        undefined -> Protected0#{<<"jwk">> => PubMap};
        _ when is_binary(Kid) -> Protected0#{<<"kid">> => Kid}
    end,
    EncProtected = jose_jwa_base64url:encode(thoas:encode(Protected)),
    EncPayload = jose_jwa_base64url:encode(PayloadBin),
    SigningInput = <<EncProtected/binary, $., EncPayload/binary>>,
    SigBin = jose_jws_alg_ecdsa:sign(Jwk, SigningInput, 'ES256'),
    EncSig = jose_jwa_base64url:encode(SigBin),
    #{
        <<"protected">> => EncProtected,
        <<"payload">> => EncPayload,
        <<"signature">> => EncSig
    }.

%% ---------------------------------------------------------------------------
fetch_nonce(NewNonceUrl) ->
    {ok, Hdrs} = http_head(NewNonceUrl),
    nonce_from_headers(norm_headers(Hdrs)).

http_head(Url) ->
    Req = {binary_to_list(Url), http_headers_acme()},
    case httpc:request(head, Req, http_opts(60000), []) of
        {ok, {{_, 200, _}, Hdrs, _}} -> {ok, Hdrs};
        {ok, {{_, St, _}, _, Body}} -> throw({acme, {head_nonce, St, Body}});
        {error, R} -> throw({acme, {head_nonce, R}})
    end.

http_get_json(Url) ->
    Req = {binary_to_list(Url), http_headers_acme()},
    case httpc:request(get, Req, http_opts(120000), []) of
        {ok, {{_, 200, _}, _Hdrs, Body}} ->
            case thoas:decode(iolist_to_binary(Body)) of
                {ok, Map} -> {ok, Map};
                {error, R} -> {error, {json, R}}
            end;
        {ok, {{_, St, _}, _, Body}} -> {error, {http, St, Body}};
        {error, R} -> {error, R}
    end.

http_post(Url, Body) ->
    Hdrs = [{"content-type", "application/jose+json"} | http_headers_acme()],
    Req = {binary_to_list(Url), Hdrs, "application/jose+json", Body},
    case httpc:request(post, Req, http_opts(180000), []) of
        {ok, {{_, Status, _}, RespHdrs, RespBody}} ->
            {ok, Status, norm_headers(RespHdrs), RespBody};
        {error, R} ->
            throw({acme, {http_post, R}})
    end.

http_headers_acme() ->
    [{"accept", "application/json, application/pem-certificate-chain"}].

http_opts(TimeoutMs) when is_integer(TimeoutMs), TimeoutMs > 0 ->
    Ssl =
        case erlang:function_exported(public_key, cacerts_get, 0) of
            true ->
                [{verify, verify_peer}, {cacerts, public_key:cacerts_get()}, {depth, 99}];
            false ->
                [{verify, verify_peer}]
        end,
    [{ssl, Ssl}, {timeout, TimeoutMs}].

norm_headers(H) ->
    [{norm_k(K), V} || {K, V} <- H].

norm_k(K) when is_atom(K) -> atom_to_list(K);
norm_k(K) when is_binary(K) -> string:lowercase(binary_to_list(K));
norm_k(K) when is_list(K) -> string:lowercase(K).

header_location(Hdrs) ->
    case lists:keyfind("location", 1, Hdrs) of
        false -> undefined;
        {_, Loc} when is_list(Loc) -> Loc;
        {_, Loc} when is_binary(Loc) -> binary_to_list(Loc)
    end.

nonce_from_headers(Hdrs) ->
    nonce_from_headers(Hdrs, undefined).

nonce_from_headers(Hdrs, Fallback) ->
    case lists:keyfind("replay-nonce", 1, Hdrs) of
        {_, N} when is_list(N) -> list_to_binary(N);
        {_, N} when is_binary(N) -> N;
        _ -> case Fallback of undefined -> throw({acme, no_nonce}); _ -> Fallback end
    end.

bin(V) when is_binary(V) -> V;
bin(V) when is_list(V) -> list_to_binary(V).

maybe_progress(Opts, PhaseBin, MsgBin) ->
    case maps:get(progress, Opts, undefined) of
        F when is_function(F, 2) ->
            catch F(PhaseBin, MsgBin);
        _ ->
            ok
    end.

%% Log dns-01 challenge rows when an order is invalid (helps diagnose TXT / propagation issues).
log_authz_dns01_failures(Jwk, Kid, Nonce, AuthUrls) when is_list(AuthUrls) ->
    lists:foldl(
        fun(Url, N0) ->
            UrlB = bin(Url),
            case post_as_get_json(Jwk, Kid, N0, UrlB, UrlB) of
                {ok, Auth, N1} ->
                    IdVal = maps:get(<<"value">>, maps:get(<<"identifier">>, Auth, #{}), <<"(unknown)">>),
                    AuthSt = maps:get(<<"status">>, Auth, <<"?">>),
                    lager:warning("ACME authorization ~s status=~s", [IdVal, AuthSt]),
                    lists:foreach(
                        fun(C) ->
                            case maps:get(<<"type">>, C, undefined) of
                                <<"dns-01">> ->
                                    Cs = maps:get(<<"status">>, C, <<"?">>),
                                    case maps:find(<<"error">>, C) of
                                        {ok, Err} ->
                                            lager:warning(
                                                "ACME dns-01 ~s challenge status=~s error=~p",
                                                [IdVal, Cs, Err]
                                            );
                                        error ->
                                            lager:warning("ACME dns-01 ~s challenge status=~s", [IdVal, Cs])
                                    end;
                                _ ->
                                    ok
                            end
                        end,
                        maps:get(<<"challenges">>, Auth, [])
                    ),
                    N1;
                _ ->
                    N0
            end
        end,
        Nonce,
        AuthUrls
    );
log_authz_dns01_failures(_, _, _, _) ->
    ok.

collect_authz_dns01_failures(Jwk, Kid, Nonce, AuthUrls) when is_list(AuthUrls) ->
    {RowsRev, _} = lists:foldl(
        fun(Url, {Acc, N0}) ->
            UrlB = bin(Url),
            case post_as_get_json(Jwk, Kid, N0, UrlB, UrlB) of
                {ok, Auth, N1} ->
                    IdVal = maps:get(<<"value">>, maps:get(<<"identifier">>, Auth, #{}), <<"(unknown)">>),
                    AuthSt = maps:get(<<"status">>, Auth, <<"?">>),
                    DnsRows = [
                        begin
                            Cs = maps:get(<<"status">>, C, <<"?">>),
                            Base = #{
                                <<"identifier">> => IdVal,
                                <<"auth_status">> => AuthSt,
                                <<"challenge_status">> => Cs
                            },
                            case maps:find(<<"error">>, C) of
                                {ok, Err} -> Base#{<<"error">> => Err};
                                error -> Base
                            end
                        end
                        || C <- maps:get(<<"challenges">>, Auth, []),
                           maps:get(<<"type">>, C, undefined) =:= <<"dns-01">>
                    ],
                    {DnsRows ++ Acc, N1};
                _ ->
                    {Acc, N0}
            end
        end,
        {[], Nonce},
        AuthUrls
    ),
    lists:reverse(RowsRev);
collect_authz_dns01_failures(_, _, _, _) ->
    [].
