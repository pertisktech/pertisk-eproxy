%% @doc Cloudflare DNS v4 API for ACME DNS-01 TXT records.
-module(pertisk_eproxy_dns_cloudflare).

-export([find_zone/2, get_zone/2, cf_txt_record_name/2, create_txt/5, delete_txt/3, auth_diag/1]).

-define(API, <<"https://api.cloudflare.com/client/v4">>).

-spec get_zone(binary(), binary()) -> {ok, #{zone_id := binary(), zone_name := binary()}} | {error, term()}.
get_zone(ApiToken, ZoneId) ->
    Url = <<?API/binary, "/zones/", ZoneId/binary>>,
    case http_get(ApiToken, Url) of
        {ok, #{<<"success">> := true, <<"result">> := #{<<"id">> := Id, <<"name">> := Nm}}} ->
            {ok, #{zone_id => Id, zone_name => Nm}};
        Other ->
            {error, {zone_lookup, Other}}
    end.

-spec find_zone(binary(), binary()) -> {ok, #{zone_id := binary(), zone_name := binary()}} | {error, term()}.
find_zone(ApiToken, Host) when is_binary(Host) ->
    NormalizedHost = normalize_host_for_zone_lookup(Host),
    Labels = [L || L <- binary:split(NormalizedHost, <<".">>, [global]), L =/= <<>>],
    try_zones(ApiToken, zone_candidates(Labels), {zone_not_found, NormalizedHost}).

zone_candidates(Labels) when is_list(Labels), length(Labels) > 0 ->
    [join_labels(L) || L <- tails(Labels)].

%% Suffix label groups: e.g. [a,b,c] -> [[a,b,c],[b,c],[c]] for zone?name=… lookups.
tails([H]) ->
    [[H]];
tails([H | T]) ->
    [[H | T] | tails(T)].

join_labels(Parts) ->
    iolist_to_binary(lists:join($., [binary_to_list(P) || P <- Parts])).

percent_encode_zone_query(Name) when is_binary(Name) ->
    %% Zone names are DNS labels; pass through for query (no spaces).
    binary_to_list(Name).

try_zones(_Token, [], {zone_not_found, Host}) ->
    {error, {zone_not_found, Host}};
try_zones(_Token, [], {error, _} = LastError) ->
    LastError;
try_zones(Token, [Name | Rest], LastError) ->
    Q = percent_encode_zone_query(Name),
    Url = lists:flatten(
        io_lib:format("https://api.cloudflare.com/client/v4/zones?name=~s", [Q])
    ),
    case http_get(Token, list_to_binary(Url)) of
        {ok, #{<<"success">> := true, <<"result">> := Results}} when is_list(Results), Results =/= [] ->
            [First | _] = Results,
            Id = maps:get(<<"id">>, First),
            Zn = maps:get(<<"name">>, First),
            {ok, #{zone_id => Id, zone_name => Zn}};
        {ok, #{<<"success">> := true, <<"result">> := []}} ->
            try_zones(Token, Rest, LastError);
        {ok, #{<<"success">> := false, <<"errors">> := Errs}} ->
            {error, {zone_lookup, {cloudflare, Errs}}};
        {error, {http, 404, _}} ->
            try_zones(Token, Rest, LastError);
        {error, _} = E ->
            {error, {zone_lookup, E}};
        Other ->
            {error, {zone_lookup, Other}}
    end.

normalize_host_for_zone_lookup(Host0) when is_binary(Host0) ->
    Host1 = trim_trailing_dot(Host0),
    case Host1 of
        <<$*, $., Rest/binary>> -> Rest;
        _ -> Host1
    end.

trim_trailing_dot(Host) when is_binary(Host), byte_size(Host) > 0 ->
    case Host of
        <<Prefix:(byte_size(Host) - 1)/binary, $.>> -> Prefix;
        _ -> Host
    end;
trim_trailing_dot(Host) ->
    Host.

-spec cf_txt_record_name(binary(), binary()) -> binary().
%% @doc Cloudflare 'name' field (relative to zone), e.g. '_acme-challenge' or '_acme-challenge.www'.
cf_txt_record_name(FullTxtFqdn, ZoneName) ->
    Suffix = <<$., ZoneName/binary>>,
    case binary_suffix(FullTxtFqdn, Suffix) of
        nomatch ->
            FullTxtFqdn;
        {ok, Prefix} ->
            Prefix
    end.

binary_suffix(Bin, Suffix) ->
    S = byte_size(Suffix),
    B = byte_size(Bin),
    case B >= S of
        false ->
            nomatch;
        true ->
            P = B - S,
            case Bin of
                <<Prefix:P/binary, Suffix/binary>> ->
                    {ok, Prefix};
                _ ->
                    nomatch
            end
    end.

-spec create_txt(binary(), binary(), binary(), binary(), binary()) ->
    {ok, binary()} | {error, term()}.
create_txt(ApiToken, ZoneId, RecordName, TxtContent, Comment) ->
    Url = <<?API/binary, "/zones/", ZoneId/binary, "/dns_records">>,
    Body = #{
        <<"type">> => <<"TXT">>,
        <<"name">> => RecordName,
        <<"content">> => TxtContent,
        <<"ttl">> => 120,
        <<"comment">> => Comment
    },
    case http_post_json(ApiToken, Url, Body) of
        {ok, #{<<"success">> := true, <<"result">> := #{<<"id">> := Id}}} ->
            {ok, Id};
        {ok, #{<<"success">> := false, <<"errors">> := Errs}} ->
            case has_identical_record_error(Errs) of
                true ->
                    case find_existing_txt_record_id(ApiToken, ZoneId, RecordName, TxtContent) of
                        {ok, ExistingId} ->
                            lager:warning(
                                "Cloudflare TXT already exists (81058), reusing record id=~s for name=~s",
                                [ExistingId, RecordName]
                            ),
                            {ok, ExistingId};
                        {error, _} ->
                            {error, {cloudflare, Errs}}
                    end;
                false ->
                    {error, {cloudflare, Errs}}
            end;
        {error, _} = E ->
            E;
        Other ->
            {error, {unexpected, Other}}
    end.

find_existing_txt_record_id(ApiToken, ZoneId, RecordName, TxtContent) ->
    EncName = uri_string:quote(RecordName),
    Url = <<
        ?API/binary,
        "/zones/",
        ZoneId/binary,
        "/dns_records?type=TXT&name=",
        EncName/binary
    >>,
    case http_get(ApiToken, Url) of
        {ok, #{<<"success">> := true, <<"result">> := Results}} when is_list(Results) ->
            case lists:search(
                fun(R) ->
                    maps:get(<<"type">>, R, <<>>) =:= <<"TXT">> andalso
                        maps:get(<<"name">>, R, <<>>) =:= RecordName andalso
                        maps:get(<<"content">>, R, <<>>) =:= TxtContent andalso
                        maps:is_key(<<"id">>, R)
                end,
                Results
            ) of
                {value, Row} -> {ok, maps:get(<<"id">>, Row)};
                false -> {error, not_found}
            end;
        _ ->
            {error, lookup_failed}
    end.

has_identical_record_error(Errs) when is_list(Errs) ->
    lists:any(
        fun(E) when is_map(E) ->
            maps:get(<<"code">>, E, undefined) =:= 81058;
           (_) ->
            false
        end,
        Errs
    );
has_identical_record_error(_) ->
    false.

-spec delete_txt(binary(), binary(), binary()) -> ok | {error, term()}.
delete_txt(ApiToken, ZoneId, RecordId) ->
    Url = <<?API/binary, "/zones/", ZoneId/binary, "/dns_records/", RecordId/binary>>,
    case http_delete(ApiToken, Url) of
        {ok, #{<<"success">> := true}} ->
            ok;
        {ok, #{<<"success">> := false, <<"errors">> := Errs}} ->
            {error, {cloudflare, Errs}};
        {error, _} = E ->
            E;
        Other ->
            {error, {unexpected, Other}}
    end.

%% ---------------------------------------------------------------------------
http_headers({global_key, ApiKey0, Email0}) ->
    ApiKey = normalize_api_key(ApiKey0),
    Email = normalize_email(Email0),
    case {ApiKey, Email} of
        {<<>>, _} ->
            {error, invalid_api_token_format};
        {_, <<>>} ->
            {error, missing_api_email};
        _ ->
            {ok,
                [
                    {"X-Auth-Key", binary_to_list(ApiKey)},
                    {"X-Auth-Email", binary_to_list(Email)},
                    {"Content-Type", "application/json"},
                    {"Accept", "application/json"}
                ]}
    end;
http_headers({token_or_key, Token0, _Email}) ->
    %% Prefer API token bearer auth when provided.
    http_headers(Token0);
http_headers(Token) when is_binary(Token) ->
    case is_redacted_placeholder_token(Token) of
        true ->
            {error, redacted_api_token_placeholder};
        false ->
    NormToken = normalize_api_token(Token),
    case NormToken of
        <<>> ->
            safe_log_token_shape(Token),
            {error, invalid_api_token_format};
        _ ->
            T = binary_to_list(NormToken),
            {ok,
                [
                    {"Authorization", "Bearer " ++ T},
                    {"Content-Type", "application/json"},
                    {"Accept", "application/json"}
                ]}
            end
    end.

safe_log_token_shape(Token) when is_binary(Token) ->
    RawLen = byte_size(Token),
    Trimmed = trim_space_binary(Token),
    TrimmedLen = byte_size(Trimmed),
    Lower = ascii_lower(Trimmed),
    HasAuthPrefix = has_prefix(Lower, <<"authorization:">>),
    HasBearerPrefix = has_prefix(Lower, <<"bearer">>),
    lager:warning(
        "Cloudflare API token rejected: invalid format (raw_len=~p, trimmed_len=~p, has_authorization_prefix=~p, has_bearer_prefix=~p)",
        [RawLen, TrimmedLen, HasAuthPrefix, HasBearerPrefix]
    ).

has_prefix(Bin, Prefix) when is_binary(Bin), is_binary(Prefix) ->
    PrefixSz = byte_size(Prefix),
    BinSz = byte_size(Bin),
    case BinSz >= PrefixSz of
        true ->
            case Bin of
                <<Prefix:PrefixSz/binary, _/binary>> -> true;
                _ -> false
            end;
        false ->
            false
    end.

normalize_api_token(Token0) when is_binary(Token0) ->
    Token1 = trim_space_binary(Token0),
    Token2 = strip_authorization_prefix(Token1),
    Token3 = strip_bearer_prefix(Token2),
    Token4 = strip_wrapping_quotes(trim_space_binary(Token3)),
    sanitize_token(Token4).

normalize_api_key(Key0) when is_binary(Key0) ->
    Key1 = trim_space_binary(Key0),
    Key2 = strip_authorization_prefix(Key1),
    Key3 = strip_wrapping_quotes(trim_space_binary(Key2)),
    sanitize_token(Key3).

normalize_email(Email0) when is_binary(Email0) ->
    Email1 = trim_space_binary(Email0),
    Email2 = strip_wrapping_quotes(Email1),
    trim_space_binary(Email2).

trim_space_binary(Bin) when is_binary(Bin) ->
    trim_space_binary_right(trim_space_binary_left(Bin)).

trim_space_binary_left(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t; C =:= $\r; C =:= $\n ->
    trim_space_binary_left(Rest);
trim_space_binary_left(Bin) ->
    Bin.

trim_space_binary_right(Bin) when is_binary(Bin) ->
    trim_space_binary_right_rev(reverse_binary(Bin)).

trim_space_binary_right_rev(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t; C =:= $\r; C =:= $\n ->
    trim_space_binary_right_rev(Rest);
trim_space_binary_right_rev(RevBin) ->
    reverse_binary(RevBin).

reverse_binary(Bin) when is_binary(Bin) ->
    list_to_binary(lists:reverse(binary_to_list(Bin))).

strip_authorization_prefix(Token) when is_binary(Token) ->
    Lower = ascii_lower(Token),
    Prefix = <<"authorization:">>,
    PrefixSz = byte_size(Prefix),
    case Lower of
        <<Prefix:PrefixSz/binary, _/binary>> ->
            <<_Skip:PrefixSz/binary, OrigRest/binary>> = Token,
            trim_space_binary(OrigRest);
        _ ->
            Token
    end.

strip_bearer_prefix(Token) when is_binary(Token) ->
    Lower = ascii_lower(Token),
    Prefix = <<"bearer">>,
    PrefixSz = byte_size(Prefix),
    case Lower of
        <<Prefix:PrefixSz/binary, Rest/binary>> ->
            Sz = byte_size(Rest),
            <<_Skip:(byte_size(Token) - Sz)/binary, OrigRest/binary>> = Token,
            trim_space_binary(strip_leading_token_separators(OrigRest));
        _ ->
            Token
    end.

strip_wrapping_quotes(<<$", Rest/binary>>) ->
    strip_wrapping_quotes_right(Rest, $");
strip_wrapping_quotes(<<$', Rest/binary>>) ->
    strip_wrapping_quotes_right(Rest, $');
strip_wrapping_quotes(Bin) ->
    Bin.

strip_wrapping_quotes_right(Bin, Quote) when is_binary(Bin) ->
    case byte_size(Bin) of
        0 -> Bin;
        N ->
            case Bin of
                <<Inner:(N - 1)/binary, Quote>> -> Inner;
                _ -> Bin
            end
    end.

sanitize_token(Bin) when is_binary(Bin) ->
    list_to_binary([
        C
     || C <- binary_to_list(Bin),
        is_bearer_char(C)
    ]).

is_bearer_char(C) when C >= $a, C =< $z -> true;
is_bearer_char(C) when C >= $A, C =< $Z -> true;
is_bearer_char(C) when C >= $0, C =< $9 -> true;
is_bearer_char($-) -> true;
is_bearer_char($_) -> true;
is_bearer_char($.) -> true;
is_bearer_char($~) -> true;
is_bearer_char($+) -> true;
is_bearer_char($/) -> true;
is_bearer_char($=) -> true;
is_bearer_char(_) -> false.

strip_leading_token_separators(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t; C =:= $\r; C =:= $\n; C =:= $:; C =:= $= ->
    strip_leading_token_separators(Rest);
strip_leading_token_separators(Bin) ->
    Bin.

ascii_lower(Bin) when is_binary(Bin) ->
    list_to_binary([
        case C of
            X when X >= $A, X =< $Z -> X + 32;
            _ -> C
        end
     || C <- binary_to_list(Bin)
    ]).

http_get(Token, Url) ->
    maybe_retry_with_global_key(Token, fun(Auth) -> do_http_get(Auth, Url) end).

do_http_get(Token, Url) ->
    case http_headers(Token) of
        {error, _} = E ->
            E;
        {ok, Headers} ->
            Req = {binary_to_list(Url), Headers},
            case httpc:request(get, Req, http_opts(), []) of
                {ok, {{_, 200, _}, _RespH, RespB}} ->
                    case thoas:decode(list_to_binary(RespB)) of
                        {ok, Map} -> {ok, Map};
                        {error, R} -> {error, {json, R}}
                    end;
                {ok, {{_, Status, _}, _, RespB}} ->
                    {error, {http, Status, RespB}};
                {error, R} ->
                    {error, R}
            end
    end.

http_post_json(Token, Url, BodyMap) ->
    Enc = thoas:encode(BodyMap),
    maybe_retry_with_global_key(Token, fun(Auth) -> do_http_post_json(Auth, Url, Enc) end).

do_http_post_json(Token, Url, Enc) ->
    case http_headers(Token) of
        {error, _} = E ->
            E;
        {ok, Headers} ->
            Req = {binary_to_list(Url), Headers, "application/json", Enc},
            case httpc:request(post, Req, http_opts(), []) of
                {ok, {{_, 200, _}, _RespH, RespB}} ->
                    case thoas:decode(list_to_binary(RespB)) of
                        {ok, Map} -> {ok, Map};
                        {error, R} -> {error, {json, R}}
                    end;
                {ok, {{_, Status, _}, _, RespB}} ->
                    {error, {http, Status, RespB}};
                {error, R} ->
                    {error, R}
            end
    end.

http_delete(Token, Url) ->
    maybe_retry_with_global_key(Token, fun(Auth) -> do_http_delete(Auth, Url) end).

do_http_delete(Token, Url) ->
    case http_headers(Token) of
        {error, _} = E ->
            E;
        {ok, Headers} ->
            Req = {binary_to_list(Url), Headers},
            case httpc:request(delete, Req, http_opts(), []) of
                {ok, {{_, 200, _}, _RespH, RespB}} ->
                    case thoas:decode(list_to_binary(RespB)) of
                        {ok, Map} -> {ok, Map};
                        {error, R} -> {error, {json, R}}
                    end;
                {ok, {{_, Status, _}, _, RespB}} ->
                    {error, {http, Status, RespB}};
                {error, R} ->
                    {error, R}
            end
    end.

maybe_retry_with_global_key({token_or_key, Token, Email} = Auth, ReqFun) ->
    case ReqFun(Auth) of
        {error, {http, 400, Body}} = E ->
            case has_invalid_auth_header_6111(Body) of
                true ->
                    lager:warning("Cloudflare bearer auth rejected with 6111; retrying with X-Auth-Key mode"),
                    case ReqFun({global_key, Token, Email}) of
                        {error, {http, 400, Body2}} = E2 ->
                            case has_invalid_auth_header_6111(Body2) of
                                true -> {error, invalid_cloudflare_auth_header};
                                false -> E2
                            end;
                        Other2 -> Other2
                    end;
                false -> E
            end;
        Other ->
            Other
    end;
maybe_retry_with_global_key(Auth, ReqFun) ->
    case ReqFun(Auth) of
        {error, {http, 400, Body}} = E ->
            case has_invalid_auth_header_6111(Body) of
                true -> {error, invalid_cloudflare_auth_header};
                false -> E
            end;
        Other -> Other
    end.

auth_diag({token_or_key, Token, Email}) ->
    Base = token_diag(Token),
    Base#{mode => token_or_key, email_present => (normalize_email(Email) =/= <<>>)};
auth_diag({global_key, ApiKey, Email}) ->
    Base = token_diag(ApiKey),
    Base#{mode => global_key, email_present => (normalize_email(Email) =/= <<>>)};
auth_diag(Token) when is_binary(Token) ->
    Base = token_diag(Token),
    Base#{mode => bearer_token}.

token_diag(Token0) when is_binary(Token0) ->
    Norm = normalize_api_token(Token0),
    RawLen = byte_size(Token0),
    NormLen = byte_size(Norm),
    Fp = short_fingerprint(Norm),
    #{raw_len => RawLen, normalized_len => NormLen, fp8 => Fp}.

short_fingerprint(Bin) when is_binary(Bin) ->
    Hash = crypto:hash(sha256, Bin),
    Hex = iolist_to_binary([io_lib:format("~2.16.0b", [X]) || <<X:8>> <= Hash]),
    case byte_size(Hex) >= 8 of
        true -> binary:part(Hex, 0, 8);
        false -> Hex
    end.

has_invalid_auth_header_6111(Body) ->
    Bin = iolist_to_binary(Body),
    case binary:match(Bin, <<"\"code\":6111">>) of
        nomatch -> false;
        _ -> true
    end.

is_redacted_placeholder_token(Token) when is_binary(Token) ->
    Lower = ascii_lower(trim_space_binary(Token)),
    case Lower of
        <<"[redacted]">> -> true;
        <<"redacted">> -> true;
        _ -> false
    end.

http_opts() ->
    Ssl =
        case erlang:function_exported(public_key, cacerts_get, 0) of
            true ->
                [{verify, verify_peer}, {cacerts, public_key:cacerts_get()}, {depth, 99}];
            false ->
                [{verify, verify_peer}]
        end,
    [{ssl, Ssl}, {timeout, 120000}].
