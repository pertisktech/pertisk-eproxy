%% @doc Porkbun DNS API v3 for ACME DNS-01 TXT records.
-module(pertisk_eproxy_dns_porkbun).

-export([
    resolve_domain/4,
    txt_record_name/2,
    create_txt/5,
    delete_txt/4
]).

-define(API, <<"https://api.porkbun.com/api/json/v3">>).

-spec resolve_domain(binary(), binary(), binary() | undefined, binary()) -> {ok, binary()} | {error, term()}.
resolve_domain(ApiKey, SecretApiKey, Domain0, _Host) when is_binary(Domain0), byte_size(Domain0) > 0 ->
    Domain = string:lowercase(trim_space_binary(Domain0)),
    case get_records(ApiKey, SecretApiKey, Domain) of
        {ok, _} ->
            {ok, Domain};
        {error, _} = Err ->
            {error, {domain_lookup_failed, Domain, Err}}
    end;
resolve_domain(ApiKey, SecretApiKey, _Domain0, Host) when is_binary(Host) ->
    Labels = binary:split(Host, <<".">>, [global]),
    Candidates = domain_candidates(Labels),
    try_domains(ApiKey, SecretApiKey, Candidates, undefined).

domain_candidates(Labels) when is_list(Labels), length(Labels) > 0 ->
    [join_labels(L) || L <- tails(Labels)].

tails([H]) ->
    [[H]];
tails([H | T]) ->
    [[H | T] | tails(T)].

join_labels(Parts) ->
    iolist_to_binary(lists:join($., [binary_to_list(P) || P <- Parts])).

try_domains(_ApiKey, _SecretApiKey, [], undefined) ->
    {error, domain_not_found};
try_domains(_ApiKey, _SecretApiKey, [], {Domain, Err}) ->
    {error, {domain_lookup_failed, Domain, Err}};
try_domains(ApiKey, SecretApiKey, [Domain | Rest], FirstFatalErr) ->
    case get_records(ApiKey, SecretApiKey, Domain) of
        {ok, _} ->
            {ok, Domain};
        {error, Err} ->
            case is_domain_not_found_error(Err) of
                true ->
                    try_domains(ApiKey, SecretApiKey, Rest, FirstFatalErr);
                false ->
                    case FirstFatalErr of
                        undefined -> try_domains(ApiKey, SecretApiKey, Rest, {Domain, Err});
                        _ -> try_domains(ApiKey, SecretApiKey, Rest, FirstFatalErr)
                    end
            end
    end.

-spec get_records(binary(), binary(), binary()) -> {ok, map()} | {error, term()}.
get_records(ApiKey, SecretApiKey, Domain) ->
    Url = <<?API/binary, "/dns/retrieve/", Domain/binary>>,
    case http_post_json(ApiKey, SecretApiKey, Url, #{}) of
        {ok, Resp} when is_map(Resp) ->
            {ok, Resp};
        {error, _} = E ->
            E;
        Other ->
            {error, {unexpected, Other}}
    end.

is_domain_not_found_error({api_error, Msg}) when is_binary(Msg) ->
    S = string:lowercase(Msg),
    contains(S, <<"domain not found">>) orelse contains(S, <<"invalid domain">>);
is_domain_not_found_error({http, 404, _}) -> true;
is_domain_not_found_error({http, 400, Body}) ->
    Txt = lower_bin(Body),
    contains(Txt, <<"domain not found">>) orelse contains(Txt, <<"invalid domain">>);
is_domain_not_found_error(_) -> false.

-spec txt_record_name(binary(), binary()) -> binary().
%% @doc Porkbun record name relative to domain, e.g. `_acme-challenge` or `_acme-challenge.app`.
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

-spec create_txt(binary(), binary(), binary(), binary(), binary()) -> {ok, term()} | {error, term()}.
create_txt(ApiKey, SecretApiKey, Domain, RecordName, TxtContent) ->
    Url = <<?API/binary, "/dns/create/", Domain/binary>>,
    Body = #{
        <<"type">> => <<"TXT">>,
        <<"name">> => RecordName,
        <<"content">> => TxtContent,
        <<"ttl">> => 120
    },
    case http_post_json(ApiKey, SecretApiKey, Url, Body) of
        {ok, Resp} when is_map(Resp) ->
            case extract_record_id(Resp) of
                {ok, Id} -> {ok, Id};
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E;
        Other ->
            {error, {unexpected, Other}}
    end.

-spec delete_txt(binary(), binary(), binary(), term()) -> ok | {error, term()}.
delete_txt(ApiKey, SecretApiKey, Domain, RecordId) ->
    RidBin = id_to_binary(RecordId),
    Url = <<?API/binary, "/dns/delete/", Domain/binary, "/", RidBin/binary>>,
    case http_post_json(ApiKey, SecretApiKey, Url, #{}) of
        {ok, _Resp} ->
            ok;
        {error, _} = E ->
            E;
        Other ->
            {error, {unexpected, Other}}
    end.

extract_record_id(#{<<"id">> := Id}) when is_binary(Id); is_integer(Id); is_list(Id) ->
    {ok, Id};
extract_record_id(#{<<"records">> := [Rec | _]}) when is_map(Rec) ->
    case maps:find(<<"id">>, Rec) of
        {ok, Id} -> {ok, Id};
        error -> {error, {missing_record_id, Rec}}
    end;
extract_record_id(Resp) ->
    {error, {missing_record_id, Resp}}.

id_to_binary(V) when is_binary(V) -> V;
id_to_binary(V) when is_integer(V) -> integer_to_binary(V);
id_to_binary(V) when is_list(V) -> unicode:characters_to_binary(V, utf8);
id_to_binary(V) -> unicode:characters_to_binary(io_lib:format("~p", [V]), utf8).

http_post_json(ApiKey, SecretApiKey, Url, BodyMap) ->
    AuthBody =
        maps:merge(
            #{
                <<"apikey">> => ApiKey,
                <<"secretapikey">> => SecretApiKey
            },
            BodyMap
        ),
    Enc = thoas:encode(AuthBody),
    Req = {binary_to_list(Url), http_headers(), "application/json", Enc},
    case httpc:request(post, Req, http_opts(), []) of
        {ok, {{_, 200, _}, _RespH, RespB}} ->
            parse_api_response(RespB);
        {ok, {{_, Status, _}, _RespH, RespB}} ->
            {error, {http, Status, RespB}};
        {error, R} ->
            {error, R}
    end.

parse_api_response(RespB) ->
    case thoas:decode(list_to_binary(RespB)) of
        {ok, Map} when is_map(Map) ->
            case api_is_success(Map) of
                true -> {ok, Map};
                false ->
                    case maps:get(<<"message">>, Map, maps:get(<<"status">>, Map, <<"api_error">>)) of
                        Msg when is_binary(Msg) -> {error, {api_error, Msg}};
                        Msg -> {error, {api_error, Msg}}
                    end
            end;
        {error, R} ->
            {error, {json, R}}
    end.

api_is_success(#{<<"status">> := <<"SUCCESS">>}) -> true;
api_is_success(#{<<"status">> := <<"success">>}) -> true;
api_is_success(#{<<"status">> := <<"ERROR">>}) -> false;
api_is_success(#{<<"status">> := <<"error">>}) -> false;
api_is_success(#{<<"success">> := true}) -> true;
api_is_success(#{<<"status">> := V}) when is_binary(V) ->
    lower_bin(V) =:= <<"success">>;
api_is_success(_) -> false.

http_headers() ->
    [
        {"content-type", "application/json"},
        {"accept", "application/json"}
    ].

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

contains(Bin, Needle) when is_binary(Bin), is_binary(Needle) ->
    binary:match(Bin, Needle) =/= nomatch.

lower_bin(B) when is_binary(B) ->
    string:lowercase(B);
lower_bin(L) when is_list(L) ->
    string:lowercase(unicode:characters_to_binary(L, utf8));
lower_bin(Term) ->
    string:lowercase(unicode:characters_to_binary(io_lib:format("~p", [Term]), utf8)).
