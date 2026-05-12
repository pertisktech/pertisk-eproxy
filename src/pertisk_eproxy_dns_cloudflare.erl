%% @doc Cloudflare DNS v4 API for ACME DNS-01 TXT records.
-module(pertisk_eproxy_dns_cloudflare).

-export([find_zone/2, get_zone/2, cf_txt_record_name/2, create_txt/5, delete_txt/3]).

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
    Labels = binary:split(Host, <<".">>, [global]),
    try_zones(ApiToken, zone_candidates(Labels)).

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

try_zones(_Token, []) ->
    {error, zone_not_found};
try_zones(Token, [Name | Rest]) ->
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
        _ ->
            try_zones(Token, Rest)
    end.

-spec cf_txt_record_name(binary(), binary()) -> binary().
%% @doc Cloudflare `name` field (relative to zone), e.g. `_acme-challenge` or `_acme-challenge.www`.
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
            {error, {cloudflare, Errs}};
        {error, _} = E ->
            E;
        Other ->
            {error, {unexpected, Other}}
    end.

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
        {ok, {{_, Status, _}, _, RespB}} ->
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
        {ok, {{_, Status, _}, _, RespB}} ->
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
                {error, R} -> {error, {json, R}}
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
