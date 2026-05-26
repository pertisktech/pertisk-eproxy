%% @doc Gandi LiveDNS API v5 for ACME DNS-01 TXT records.
-module(pertisk_eproxy_dns_gandi).

-export([
    resolve_domain/3,
    txt_record_name/2,
    create_txt/4,
    delete_txt/3
]).

-define(API, <<"https://api.gandi.net/v5/livedns">>).

-spec resolve_domain(binary(), binary() | undefined, binary()) -> {ok, binary()} | {error, term()}.
resolve_domain(ApiToken, Domain0, _Host) when is_binary(Domain0), byte_size(Domain0) > 0 ->
    Domain = string:lowercase(trim_space_binary(Domain0)),
    case get_domain(ApiToken, Domain) of
        {ok, _} -> {ok, Domain};
        {error, _} = E -> {error, {domain_lookup_failed, Domain, E}}
    end;
resolve_domain(ApiToken, _Domain0, Host) when is_binary(Host) ->
    Labels = binary:split(Host, <<".">>, [global]),
    try_domains(ApiToken, domain_candidates(Labels), undefined).

domain_candidates(Labels) when is_list(Labels), length(Labels) > 0 ->
    [join_labels(L) || L <- tails(Labels)].

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
                true -> try_domains(Token, Rest, FirstFatalErr);
                false ->
                    case FirstFatalErr of
                        undefined -> try_domains(Token, Rest, {Domain, Err});
                        _ -> try_domains(Token, Rest, FirstFatalErr)
                    end
            end
    end.

get_domain(ApiToken, Domain) ->
    Url = <<?API/binary, "/domains/", Domain/binary>>,
    case http_get(ApiToken, Url) of
        {ok, _} = Ok -> Ok;
        {error, _} = E -> E
    end.

is_domain_not_found_error({http, 404, _}) -> true;
is_domain_not_found_error(_) -> false.

-spec txt_record_name(binary(), binary()) -> binary().
txt_record_name(FullTxtFqdn, Domain) ->
    Suffix = <<$., Domain/binary>>,
    case binary_suffix(FullTxtFqdn, Suffix) of
        nomatch -> FullTxtFqdn;
        {ok, Prefix} -> Prefix
    end.

binary_suffix(Bin, Suffix) ->
    S = byte_size(Suffix),
    B = byte_size(Bin),
    case B >= S of
        false -> nomatch;
        true ->
            P = B - S,
            case Bin of
                <<Prefix:P/binary, Suffix/binary>> -> {ok, Prefix};
                _ -> nomatch
            end
    end.

-spec create_txt(binary(), binary(), binary(), binary()) -> {ok, term()} | {error, term()}.
create_txt(ApiToken, Domain, RecordName, TxtContent) ->
    Url = <<?API/binary, "/domains/", Domain/binary, "/records/", RecordName/binary, "/TXT">>,
    Quoted = <<$", TxtContent/binary, $">>,
    Body = #{
        <<"rrset_ttl">> => 120,
        <<"rrset_values">> => [Quoted]
    },
    case http_put_json(ApiToken, Url, Body) of
        {ok, _} -> {ok, {gandi, ApiToken, Domain, RecordName}};
        {error, _} = E -> E
    end.

-spec delete_txt(binary(), binary(), binary()) -> ok | {error, term()}.
delete_txt(ApiToken, Domain, RecordName) ->
    Url = <<?API/binary, "/domains/", Domain/binary, "/records/", RecordName/binary, "/TXT">>,
    Body = #{
        <<"rrset_values">> => []
    },
    case http_put_json(ApiToken, Url, Body) of
        {ok, _} -> ok;
        {error, _} = E -> E
    end.

http_headers(Token) ->
    T = binary_to_list(Token),
    [
        {"authorization", "Apikey " ++ T},
        {"content-type", "application/json"},
        {"accept", "application/json"}
    ].

http_get(Token, Url) ->
    Req = {binary_to_list(Url), http_headers(Token)},
    case httpc:request(get, Req, http_opts(), []) of
        {ok, {{_, 200, _}, _RespH, RespB}} -> decode_json_or_empty(RespB);
        {ok, {{_, Status, _}, _RespH, RespB}} -> {error, {http, Status, RespB}};
        {error, R} -> {error, R}
    end.

http_put_json(Token, Url, BodyMap) ->
    Enc = thoas:encode(BodyMap),
    Req = {binary_to_list(Url), http_headers(Token), "application/json", Enc},
    case httpc:request(put, Req, http_opts(), []) of
        {ok, {{_, 200, _}, _RespH, RespB}} -> decode_json_or_empty(RespB);
        {ok, {{_, 201, _}, _RespH, RespB}} -> decode_json_or_empty(RespB);
        {ok, {{_, 204, _}, _RespH, _RespB}} -> {ok, #{}};
        {ok, {{_, Status, _}, _RespH, RespB}} -> {error, {http, Status, RespB}};
        {error, R} -> {error, R}
    end.

decode_json_or_empty(RespB) ->
    case thoas:decode(list_to_binary(RespB)) of
        {ok, Map} -> {ok, Map};
        {error, _} -> {ok, #{}}
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
