%% @doc Linode DNS API v4 for ACME DNS-01 TXT records.
-module(pertisk_eproxy_dns_linode).

-export([
    resolve_domain/3,
    txt_record_name/2,
    create_txt/4,
    delete_txt/3
]).

-define(API, <<"https://api.linode.com/v4">>).

-spec resolve_domain(binary(), binary() | undefined, binary()) -> {ok, map()} | {error, term()}.
resolve_domain(ApiToken, Domain0, _Host) when is_binary(Domain0), byte_size(Domain0) > 0 ->
    Want = string:lowercase(trim_space_binary(Domain0)),
    case find_domain(ApiToken, Want) of
        {ok, Dom} -> {ok, Dom};
        {error, _} = E -> {error, {domain_lookup_failed, Want, E}}
    end;
resolve_domain(ApiToken, _Domain0, Host) when is_binary(Host) ->
    Labels = binary:split(Host, <<".">>, [global]),
    Candidates = domain_candidates(Labels),
    try_domains(ApiToken, Candidates, undefined).

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
    case find_domain(Token, Domain) of
        {ok, Dom} ->
            {ok, Dom};
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

-spec find_domain(binary(), binary()) -> {ok, map()} | {error, term()}.
find_domain(ApiToken, WantDomain) ->
    case list_domains(ApiToken) of
        {ok, Domains} ->
            case lists:search(
                fun(#{domain := D}) ->
                    string:lowercase(D) =:= WantDomain
                end,
                Domains
            ) of
                {value, Dom} -> {ok, Dom};
                false -> {error, domain_not_found}
            end;
        {error, _} = E ->
            E
    end.

-spec list_domains(binary()) -> {ok, [map()]} | {error, term()}.
list_domains(ApiToken) ->
    Url = <<?API/binary, "/domains?page=1&page_size=500">>,
    case http_get(ApiToken, Url) of
        {ok, #{<<"data">> := Rows}} when is_list(Rows) ->
            {ok, [normalize_domain_row(R) || R <- Rows, is_map(R)]};
        {ok, Other} ->
            {error, {unexpected_domains_response, Other}};
        {error, _} = E ->
            E
    end.

normalize_domain_row(#{<<"id">> := Id, <<"domain">> := Domain, <<"type">> := Type}) ->
    #{id => Id, domain => lower_bin(Domain), type => Type};
normalize_domain_row(#{<<"id">> := Id, <<"domain">> := Domain}) ->
    #{id => Id, domain => lower_bin(Domain)};
normalize_domain_row(Row) ->
    Row.

is_domain_not_found_error(domain_not_found) -> true;
is_domain_not_found_error({http, 404, _}) -> true;
is_domain_not_found_error(_) -> false.

-spec txt_record_name(binary(), binary()) -> binary().
%% @doc Linode record name relative to domain, e.g. `_acme-challenge` or `_acme-challenge.app`.
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

-spec create_txt(binary(), term(), binary(), binary()) -> {ok, term()} | {error, term()}.
create_txt(ApiToken, DomainId, RecordName, TxtContent) ->
    Did = id_to_binary(DomainId),
    Url = <<?API/binary, "/domains/", Did/binary, "/records">>,
    Body = #{
        <<"type">> => <<"TXT">>,
        <<"name">> => RecordName,
        <<"target">> => TxtContent,
        <<"ttl_sec">> => 120
    },
    case http_post_json(ApiToken, Url, Body) of
        {ok, #{<<"id">> := Rid}} ->
            {ok, Rid};
        {ok, Other} ->
            {error, {missing_record_id, Other}};
        {error, _} = E ->
            E
    end.

-spec delete_txt(binary(), term(), term()) -> ok | {error, term()}.
delete_txt(ApiToken, DomainId, RecordId) ->
    Did = id_to_binary(DomainId),
    Rid = id_to_binary(RecordId),
    Url = <<?API/binary, "/domains/", Did/binary, "/records/", Rid/binary>>,
    case http_delete(ApiToken, Url) of
        {ok, _} -> ok;
        {error, _} = E -> E;
        Other -> {error, {unexpected, Other}}
    end.

id_to_binary(V) when is_binary(V) -> V;
id_to_binary(V) when is_integer(V) -> integer_to_binary(V);
id_to_binary(V) when is_list(V) -> unicode:characters_to_binary(V, utf8);
id_to_binary(V) -> unicode:characters_to_binary(io_lib:format("~p", [V]), utf8).

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
        {ok, {{_, Status, _}, _RespH, RespB}} ->
            {error, {http, Status, RespB}};
        {error, R} ->
            {error, R}
    end.

http_post_json(Token, Url, BodyMap) ->
    Enc = thoas:encode(BodyMap),
    Req = {binary_to_list(Url), http_headers(Token), "application/json", Enc},
    case httpc:request(post, Req, http_opts(), []) of
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
        {ok, {{_, Status, _}, _RespH, RespB}} ->
            {error, {http, Status, RespB}};
        {error, R} ->
            {error, R}
    end.

http_delete(Token, Url) ->
    Req = {binary_to_list(Url), http_headers(Token)},
    case httpc:request(delete, Req, http_opts(), []) of
        {ok, {{_, 200, _}, _RespH, RespB}} ->
            case thoas:decode(list_to_binary(RespB)) of
                {ok, Map} -> {ok, Map};
                {error, _} -> {ok, #{}}
            end;
        {ok, {{_, 204, _}, _RespH, _RespB}} ->
            {ok, #{}};
        {ok, {{_, Status, _}, _RespH, RespB}} ->
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

lower_bin(B) when is_binary(B) -> string:lowercase(B);
lower_bin(L) when is_list(L) -> string:lowercase(unicode:characters_to_binary(L, utf8));
lower_bin(Term) -> string:lowercase(unicode:characters_to_binary(io_lib:format("~p", [Term]), utf8)).
