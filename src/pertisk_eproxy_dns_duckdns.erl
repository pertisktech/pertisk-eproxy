%% @doc DuckDNS update API for ACME DNS-01 TXT records.
-module(pertisk_eproxy_dns_duckdns).

-export([
    create_txt/3,
    delete_txt/2
]).

-spec create_txt(binary(), binary(), binary()) -> {ok, term()} | {error, term()}.
create_txt(Domain, Token, TxtContent) ->
    Url = duckdns_url(Domain, Token, TxtContent, false),
    case http_get_ok(Url) of
        ok -> {ok, {duckdns, Domain, Token}};
        {error, _} = E -> E
    end.

-spec delete_txt(binary(), binary()) -> ok | {error, term()}.
delete_txt(Domain, Token) ->
    Url = duckdns_url(Domain, Token, <<>>, true),
    case http_get_ok(Url) of
        ok -> ok;
        {error, _} = E -> E
    end.

duckdns_url(Domain, Token, TxtValue, Clear) ->
    D = uri_string:quote(binary_to_list(Domain)),
    T = uri_string:quote(binary_to_list(Token)),
    Txt = uri_string:quote(binary_to_list(TxtValue)),
    C = case Clear of true -> "true"; false -> "false" end,
    list_to_binary(
        "https://www.duckdns.org/update?domains=" ++
            D ++
            "&token=" ++
            T ++
            "&txt=" ++
            Txt ++
            "&clear=" ++ C
    ).

http_get_ok(Url) ->
    Req = {binary_to_list(Url), [{"accept", "text/plain"}]},
    case httpc:request(get, Req, http_opts(), []) of
        {ok, {{_, 200, _}, _RespH, RespB}} ->
            B = string:lowercase(iolist_to_binary(RespB)),
            case binary:match(B, <<"ok">>) of
                nomatch -> {error, {unexpected_response, RespB}};
                _ -> ok
            end;
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
