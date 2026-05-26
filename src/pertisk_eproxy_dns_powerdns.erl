%% @doc PowerDNS Authoritative API for ACME DNS-01 TXT records.
-module(pertisk_eproxy_dns_powerdns).

-export([
    resolve_zone/5,
    txt_record_name/2,
    create_txt/6,
    delete_txt/5
]).

-spec resolve_zone(binary(), binary(), binary() | undefined, binary() | undefined, binary()) ->
    {ok, map()} | {error, term()}.
resolve_zone(ApiUrl, ApiKey, ServerId0, Zone0, _Host) when is_binary(Zone0), byte_size(Zone0) > 0 ->
    ServerId = default_server_id(ServerId0),
    Zone = string:lowercase(trim_space_binary(Zone0)),
    case get_zone(ApiUrl, ApiKey, ServerId, Zone) of
        {ok, _} -> {ok, #{server_id => ServerId, zone_name => Zone}};
        {error, _} = E -> {error, {zone_lookup_failed, Zone, E}}
    end;
resolve_zone(ApiUrl, ApiKey, ServerId0, _Zone0, Host) when is_binary(Host) ->
    ServerId = default_server_id(ServerId0),
    Labels = binary:split(Host, <<".">>, [global]),
    try_zones(ApiUrl, ApiKey, ServerId, zone_candidates(Labels), undefined).

default_server_id(undefined) -> <<"localhost">>;
default_server_id(Sid) when is_binary(Sid), byte_size(Sid) > 0 -> Sid;
default_server_id(Sid) when is_list(Sid), length(Sid) > 0 -> unicode:characters_to_binary(Sid, utf8);
default_server_id(_) -> <<"localhost">>.

zone_candidates(Labels) when is_list(Labels), length(Labels) > 0 ->
    [join_labels(L) || L <- tails(Labels)].

tails([H]) ->
    [[H]];
tails([H | T]) ->
    [[H | T] | tails(T)].

join_labels(Parts) ->
    iolist_to_binary(lists:join($., [binary_to_list(P) || P <- Parts])).

try_zones(_ApiUrl, _ApiKey, _ServerId, [], undefined) ->
    {error, zone_not_found};
try_zones(_ApiUrl, _ApiKey, _ServerId, [], {Zone, Err}) ->
    {error, {zone_lookup_failed, Zone, Err}};
try_zones(ApiUrl, ApiKey, ServerId, [Zone | Rest], FirstFatalErr) ->
    case get_zone(ApiUrl, ApiKey, ServerId, Zone) of
        {ok, _} -> {ok, #{server_id => ServerId, zone_name => Zone}};
        {error, Err} ->
            case is_zone_not_found_error(Err) of
                true -> try_zones(ApiUrl, ApiKey, ServerId, Rest, FirstFatalErr);
                false ->
                    case FirstFatalErr of
                        undefined -> try_zones(ApiUrl, ApiKey, ServerId, Rest, {Zone, Err});
                        _ -> try_zones(ApiUrl, ApiKey, ServerId, Rest, FirstFatalErr)
                    end
            end
    end.

get_zone(ApiUrl, ApiKey, ServerId, ZoneName) ->
    Z = ensure_dot_suffix(ZoneName),
    Url = <<(trim_slash(ApiUrl))/binary, "/servers/", ServerId/binary, "/zones/", Z/binary>>,
    case http_get(ApiKey, Url) of
        {ok, _} = Ok -> Ok;
        {error, _} = E -> E
    end.

is_zone_not_found_error({http, 404, _}) -> true;
is_zone_not_found_error(_) -> false.

-spec txt_record_name(binary(), binary()) -> binary().
txt_record_name(FullTxtFqdn, ZoneName) ->
    ZoneNoDot = trim_dot_suffix(ZoneName),
    Suffix = <<$., ZoneNoDot/binary>>,
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

-spec create_txt(binary(), binary(), binary(), binary(), binary(), binary()) -> {ok, term()} | {error, term()}.
create_txt(ApiUrl, ApiKey, ServerId, ZoneName, RecordName, TxtContent) ->
    Url = <<(trim_slash(ApiUrl))/binary, "/servers/", ServerId/binary, "/zones/", (ensure_dot_suffix(ZoneName))/binary>>,
    Fqdn = ensure_dot_suffix(<<RecordName/binary, $., (trim_dot_suffix(ZoneName))/binary>>),
    Quoted = <<$", TxtContent/binary, $">>,
    Body = #{
        <<"rrsets">> => [
            #{
                <<"name">> => Fqdn,
                <<"type">> => <<"TXT">>,
                <<"ttl">> => 120,
                <<"changetype">> => <<"REPLACE">>,
                <<"records">> => [#{<<"content">> => Quoted, <<"disabled">> => false}]
            }
        ]
    },
    case http_patch_json(ApiKey, Url, Body) of
        {ok, _} -> {ok, {powerdns, ApiUrl, ApiKey, ServerId, ZoneName, RecordName}};
        {error, _} = E -> E
    end.

-spec delete_txt(binary(), binary(), binary(), binary(), binary()) -> ok | {error, term()}.
delete_txt(ApiUrl, ApiKey, ServerId, ZoneName, RecordName) ->
    Url = <<(trim_slash(ApiUrl))/binary, "/servers/", ServerId/binary, "/zones/", (ensure_dot_suffix(ZoneName))/binary>>,
    Fqdn = ensure_dot_suffix(<<RecordName/binary, $., (trim_dot_suffix(ZoneName))/binary>>),
    Body = #{
        <<"rrsets">> => [
            #{
                <<"name">> => Fqdn,
                <<"type">> => <<"TXT">>,
                <<"changetype">> => <<"DELETE">>
            }
        ]
    },
    case http_patch_json(ApiKey, Url, Body) of
        {ok, _} -> ok;
        {error, _} = E -> E
    end.

http_headers(ApiKey) ->
    K = binary_to_list(ApiKey),
    [
        {"x-api-key", K},
        {"content-type", "application/json"},
        {"accept", "application/json"}
    ].

http_get(ApiKey, Url) ->
    Req = {binary_to_list(Url), http_headers(ApiKey)},
    case httpc:request(get, Req, http_opts(), []) of
        {ok, {{_, 200, _}, _RespH, RespB}} -> decode_json_or_empty(RespB);
        {ok, {{_, 204, _}, _RespH, _RespB}} -> {ok, #{}};
        {ok, {{_, Status, _}, _RespH, RespB}} -> {error, {http, Status, RespB}};
        {error, R} -> {error, R}
    end.

http_patch_json(ApiKey, Url, BodyMap) ->
    Enc = thoas:encode(BodyMap),
    Req = {binary_to_list(Url), http_headers(ApiKey), "application/json", Enc},
    case httpc:request("PATCH", Req, http_opts(), []) of
        {ok, {{_, 200, _}, _RespH, RespB}} -> decode_json_or_empty(RespB);
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

trim_slash(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    case binary:last(Bin) of
        $/ -> binary:part(Bin, 0, byte_size(Bin) - 1);
        _ -> Bin
    end;
trim_slash(Bin) -> Bin.

ensure_dot_suffix(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    case binary:last(Bin) of
        $. -> Bin;
        _ -> <<Bin/binary, $.>>
    end;
ensure_dot_suffix(Bin) -> Bin.

trim_dot_suffix(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    case binary:last(Bin) of
        $. -> binary:part(Bin, 0, byte_size(Bin) - 1);
        _ -> Bin
    end;
trim_dot_suffix(Bin) -> Bin.

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
