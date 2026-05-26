%% @doc DigitalOcean DNS v2 API for ACME DNS-01 TXT records.
-module(pertisk_eproxy_dns_digitalocean).

-export([
    resolve_domain/3,
    txt_record_name/2,
    create_txt/4,
    delete_txt/3
]).

-define(API, <<"https://api.digitalocean.com/v2">>).

-spec resolve_domain(binary(), binary() | undefined, binary()) -> {ok, binary()} | {error, term()}.
resolve_domain(ApiToken, Domain0, _Host) when is_binary(Domain0), byte_size(Domain0) > 0 ->
    Domain = string:lowercase(trim_space_binary(Domain0)),
    case get_domain(ApiToken, Domain) of
        {ok, _} ->
            {ok, Domain};
        {error, _} = Err ->
            {error, {domain_lookup_failed, Domain, Err}}
    end;
resolve_domain(ApiToken, _Domain0, Host) when is_binary(Host) ->
    Labels = binary:split(Host, <<".">>, [global]),
    Candidates = domain_candidates(Labels),
    try_domains(ApiToken, Candidates, undefined).

domain_candidates(Labels) when is_list(Labels), length(Labels) > 0 ->
    [join_labels(L) || L <- tails(Labels)].

%% Suffix label groups: e.g. [a,b,c] -> [[a,b,c],[b,c],[c]]
tails([H]) ->
    [[H]];
tails([H | T]) ->
    [[H | T] | tails(T)].

join_labels(Parts) ->
    iolist_to_binary(lists:join($., [binary_to_list(P) || P <- Parts])).

try_domains(_Token, [], undefined) ->
    {error, domain_not_found};
try_domains(_Token, [], {Domain, Err}) ->
    {error, {domain_lookup_failed, Domain, Err}};
try_domains(Token, [Domain | Rest], FirstFatalErr) ->
    case get_domain(Token, Domain) of
        {ok, _} ->
            {ok, Domain};
        {error, Err} ->
            case is_domain_not_found_error(Err) of
                true ->
                    try_domains(Token, Rest, FirstFatalErr);
                false ->
                    case FirstFatalErr of
                        undefined -> try_domains(Token, Rest, {Domain, Err});
                        _ -> try_domains(Token, Rest, FirstFatalErr)
                    end
            end
    end.

-spec get_domain(binary(), binary()) -> {ok, map()} | {error, term()}.
get_domain(ApiToken, Domain) when is_binary(Domain) ->
    Url = <<?API/binary, "/domains/", Domain/binary>>,
    case http_get(ApiToken, Url) of
        {ok, #{<<"domain">> := DomMap}} when is_map(DomMap) ->
            {ok, DomMap};
        Other ->
            {error, {domain_lookup, Other}}
    end.

is_domain_not_found_error({domain_lookup, {error, {http, 404, _}}}) -> true;
is_domain_not_found_error({error, {http, 404, _}}) -> true;
is_domain_not_found_error({http, 404, _}) -> true;
is_domain_not_found_error(_) -> false.

trim_space_binary(Bin) when is_binary(Bin) ->
    trim_space_right(trim_space_left(Bin)).

trim_space_left(<<C, Rest/binary>>) when C =:= 32; C =:= 9; C =:= 10; C =:= 13 ->
    trim_space_left(Rest);
trim_space_left(Bin) ->
    Bin.

trim_space_right(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    case binary:last(Bin) of
        C when C =:= 32; C =:= 9; C =:= 10; C =:= 13 ->
            trim_space_right(binary:part(Bin, 0, byte_size(Bin) - 1));
        _ ->
            Bin
    end;
trim_space_right(Bin) ->
    Bin.

-spec txt_record_name(binary(), binary()) -> binary().
%% @doc DigitalOcean `name` field (relative to domain), e.g. `_acme-challenge` or `_acme-challenge.www`.
txt_record_name(FullTxtFqdn, Domain) ->
    Suffix = <<$., Domain/binary>>,
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

-spec create_txt(binary(), binary(), binary(), binary()) -> {ok, integer()} | {error, term()}.
create_txt(ApiToken, Domain, RecordName, TxtContent) ->
    Url = <<?API/binary, "/domains/", Domain/binary, "/records">>,
    Body = #{
        <<"type">> => <<"TXT">>,
        <<"name">> => RecordName,
        <<"data">> => TxtContent,
        <<"ttl">> => 120
    },
    case http_post_json(ApiToken, Url, Body) of
        {ok, #{<<"domain_record">> := #{<<"id">> := Id}}} when is_integer(Id) ->
            {ok, Id};
        {ok, #{<<"id">> := Id}} when is_integer(Id) ->
            {ok, Id};
        {error, _} = E ->
            E;
        Other ->
            {error, {unexpected, Other}}
    end.

-spec delete_txt(binary(), binary(), integer()) -> ok | {error, term()}.
delete_txt(ApiToken, Domain, RecordId) when is_integer(RecordId) ->
    RecIdBin = integer_to_binary(RecordId),
    Url = <<?API/binary, "/domains/", Domain/binary, "/records/", RecIdBin/binary>>,
    case http_delete(ApiToken, Url) of
        {ok, _} ->
            ok;
        {error, _} = E ->
            E;
        Other ->
            {error, {unexpected, Other}}
    end.

%% ---------------------------------------------------------------------------
http_headers(Token) ->
    T = binary_to_list(Token),
    [
        {"authorization", "Bearer " ++ T},
        {"content-type", "application/json"},
        {"accept", "application/json"}
    ].

http_get(Token, Url) ->
    Req = {binary_to_list(Url), http_headers(Token)},
    case httpc:request(get, Req, http_opts(), []) of
        {ok, {{_, 200, _}, _RespH, RespB}} ->
            case thoas:decode(list_to_binary(RespB)) of
                {ok, Map} -> {ok, Map};
                {error, R} -> {error, {json, R}}
            end;
        {error, {failed_connect, _} = FC} ->
            maybe_retry_insecure(get, Req, FC);
        {ok, {{_, Status, _}, _, RespB}} ->
            {error, {http, Status, RespB}};
        {error, R} ->
            {error, R}
    end.

http_post_json(Token, Url, BodyMap) ->
    Enc = thoas:encode(BodyMap),
    Req = {binary_to_list(Url), http_headers(Token), "application/json", Enc},
    case httpc:request(post, Req, http_opts(), []) of
        {ok, {{_, 201, _}, _RespH, RespB}} ->
            case thoas:decode(list_to_binary(RespB)) of
                {ok, Map} -> {ok, Map};
                {error, R} -> {error, {json, R}}
            end;
        {ok, {{_, 200, _}, _RespH, RespB}} ->
            case thoas:decode(list_to_binary(RespB)) of
                {ok, Map} -> {ok, Map};
                {error, R} -> {error, {json, R}}
            end;
        {error, {failed_connect, _} = FC} ->
            maybe_retry_insecure(post, Req, FC);
        {ok, {{_, Status, _}, _, RespB}} ->
            {error, {http, Status, RespB}};
        {error, R} ->
            {error, R}
    end.

http_delete(Token, Url) ->
    Req = {binary_to_list(Url), http_headers(Token)},
    case httpc:request(delete, Req, http_opts(), []) of
        {ok, {{_, 204, _}, _RespH, _RespB}} ->
            {ok, #{}};
        {ok, {{_, 200, _}, _RespH, RespB}} ->
            case thoas:decode(list_to_binary(RespB)) of
                {ok, Map} -> {ok, Map};
                {error, _} -> {ok, #{}}
            end;
        {error, {failed_connect, _} = FC} ->
            case maybe_retry_insecure(delete, Req, FC) of
                {ok, _} -> {ok, #{}};
                Other -> Other
            end;
        {ok, {{_, Status, _}, _, RespB}} ->
            {error, {http, Status, RespB}};
        {error, R} ->
            {error, R}
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

http_opts_insecure() ->
    %% Compatibility fallback for older OTP TLS hostname checks that may reject
    %% wildcard SANs unexpectedly (e.g. *.digitalocean.com vs api.digitalocean.com).
    %% Used only when strict TLS connect fails with hostname_check_failed.
    [{ssl, [{verify, verify_none}]}, {timeout, 120000}].

maybe_retry_insecure(Method, Req, Fail) ->
    case is_hostname_check_failed(Fail) of
        true ->
            lager:warning(
                "DigitalOcean DNS API TLS hostname verification failed on this runtime; retrying request with verify_none compatibility fallback"
            ),
            case httpc:request(Method, Req, http_opts_insecure(), []) of
                {ok, {{_, 200, _}, _RespH, RespB}} ->
                    case thoas:decode(list_to_binary(RespB)) of
                        {ok, Map} -> {ok, Map};
                        {error, R} -> {error, {json, R}}
                    end;
                {ok, {{_, 201, _}, _RespH, RespB}} ->
                    case thoas:decode(list_to_binary(RespB)) of
                        {ok, Map} -> {ok, Map};
                        {error, R} -> {error, {json, R}}
                    end;
                {ok, {{_, 204, _}, _RespH, _RespB}} ->
                    {ok, #{}};
                {ok, {{_, Status, _}, _, RespB}} ->
                    {error, {http, Status, RespB}};
                {error, R2} ->
                    {error, R2}
            end;
        false ->
            {error, Fail}
    end.

is_hostname_check_failed({failed_connect, Reasons}) when is_list(Reasons) ->
    FailTxt = lists:flatten(io_lib:format("~p", [Reasons])),
    string:str(FailTxt, "hostname_check_failed") =/= 0;
is_hostname_check_failed(_) ->
    false.
