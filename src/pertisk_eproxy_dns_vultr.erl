%% @doc Vultr DNS v2 API for ACME DNS-01 TXT records.
-module(pertisk_eproxy_dns_vultr).

-export([
    resolve_zone/3,
    txt_record_name/2,
    create_txt/4,
    delete_txt/3
]).

-define(API, <<"https://api.vultr.com/v2">>).

-spec resolve_zone(binary(), binary() | undefined, binary()) -> {ok, binary()} | {error, term()}.
resolve_zone(ApiToken, Zone0, _Host) when is_binary(Zone0), byte_size(Zone0) > 0 ->
    Zone = string:lowercase(trim_space_binary(Zone0)),
    case get_zone(ApiToken, Zone) of
        {ok, _} -> {ok, Zone};
        {error, _} = Err -> {error, {zone_lookup_failed, Zone, Err}}
    end;
resolve_zone(ApiToken, _Zone0, Host) when is_binary(Host) ->
    Labels = binary:split(Host, <<".">>, [global]),
    try_zones(ApiToken, zone_candidates(Labels), undefined).

zone_candidates(Labels) when is_list(Labels), length(Labels) > 0 ->
    [join_labels(L) || L <- tails(Labels)].

tails([H]) ->
    [[H]];
tails([H | T]) ->
    [[H | T] | tails(T)].

join_labels(Parts) ->
    iolist_to_binary(lists:join($., [binary_to_list(P) || P <- Parts])).

try_zones(_Token, [], undefined) ->
    {error, zone_not_found};
try_zones(_Token, [], {Zone, Err}) ->
    {error, {zone_lookup_failed, Zone, Err}};
try_zones(Token, [Zone | Rest], FirstFatalErr) ->
    case get_zone(Token, Zone) of
        {ok, _} ->
            {ok, Zone};
        {error, Err} ->
            case is_zone_not_found_error(Err) of
                true ->
                    try_zones(Token, Rest, FirstFatalErr);
                false ->
                    case FirstFatalErr of
                        undefined -> try_zones(Token, Rest, {Zone, Err});
                        _ -> try_zones(Token, Rest, FirstFatalErr)
                    end
            end
    end.

-spec get_zone(binary(), binary()) -> {ok, map()} | {error, term()}.
get_zone(ApiToken, Zone) ->
    Url = <<?API/binary, "/domains/", Zone/binary>>,
    case http_get(ApiToken, Url) of
        {ok, #{<<"domain">> := Dom}} when is_binary(Dom) ->
            {ok, #{zone => Dom}};
        {ok, #{<<"domain">> := DomMap}} when is_map(DomMap) ->
            {ok, DomMap};
        Other ->
            {error, {zone_lookup, Other}}
    end.

is_zone_not_found_error({zone_lookup, {error, {http, 404, _}}}) -> true;
is_zone_not_found_error({error, {http, 404, _}}) -> true;
is_zone_not_found_error({http, 404, _}) -> true;
is_zone_not_found_error(_) -> false.

-spec txt_record_name(binary(), binary()) -> binary().
%% @doc Vultr record name relative to zone, e.g. '_acme-challenge' or '_acme-challenge.app'.
txt_record_name(FullTxtFqdn, Zone) ->
    Suffix = <<$., Zone/binary>>,
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
create_txt(ApiToken, Zone, RecordName, TxtContent) ->
    Url = <<?API/binary, "/domains/", Zone/binary, "/records">>,
    %% Vultr TXT data should be quoted (lego provider behavior).
    Quoted = <<$", TxtContent/binary, $">>,
    Body = #{
        <<"name">> => RecordName,
        <<"type">> => <<"TXT">>,
        <<"data">> => Quoted,
        <<"ttl">> => 120
    },
    case http_post_json(ApiToken, Url, Body) of
        {ok, #{<<"record">> := Rec}} when is_map(Rec) ->
            case maps:find(<<"id">>, Rec) of
                {ok, Id} -> {ok, Id};
                error -> {error, {missing_record_id, Rec}}
            end;
        {error, _} = E ->
            E;
        Other ->
            {error, {unexpected, Other}}
    end.

-spec delete_txt(binary(), binary(), term()) -> ok | {error, term()}.
delete_txt(ApiToken, Zone, RecordId) ->
    RidBin = id_to_binary(RecordId),
    Url = <<?API/binary, "/domains/", Zone/binary, "/records/", RidBin/binary>>,
    case http_delete(ApiToken, Url) of
        {ok, _} -> ok;
        {error, _} = E -> E;
        Other -> {error, {unexpected, Other}}
    end.

id_to_binary(V) when is_binary(V) -> V;
id_to_binary(V) when is_integer(V) -> integer_to_binary(V);
id_to_binary(V) when is_list(V) -> unicode:characters_to_binary(V, utf8);
id_to_binary(V) -> unicode:characters_to_binary(io_lib:format("~p", [V]), utf8).

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
