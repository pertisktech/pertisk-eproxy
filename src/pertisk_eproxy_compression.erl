%% @doc Response compression negotiation for gzip, brotli (br) and zstd.
%%
%% `gzip` is always available via zlib. `br` and `zstd` are enabled when
%% compatible runtime modules are present.

-module(pertisk_eproxy_compression).

-export([maybe_compress_cowboy/4, maybe_compress_h3/4]).

-define(MIN_COMPRESS_BYTES, 1024).

maybe_compress_cowboy(Status, Req, Headers0, Body0) when is_map(Headers0) ->
    Body = iolist_to_binary(Body0),
    Accept = cowboy_req:header(<<"accept-encoding">>, Req, <<>>),
    maybe_compress(Status, Accept, header_map_get(Headers0, <<"content-type">>),
                   header_map_get(Headers0, <<"content-encoding">>),
                   header_map_get(Headers0, <<"cache-control">>),
                   header_map_get(Headers0, <<"vary">>),
                   Body,
                   fun(Headers, Encoding, Vary) ->
                       Headers1 = header_map_put(Headers, <<"content-encoding">>, Encoding),
                       Headers2 = header_map_put(Headers1, <<"vary">>, Vary),
                       header_map_remove(Headers2, [<<"content-length">>, <<"etag">>])
                   end,
                   Headers0).

maybe_compress_h3(Status, RequestHeaders, ResponseHeaders0, Body0) when is_list(ResponseHeaders0) ->
    Body = iolist_to_binary(Body0),
    Accept = list_get(RequestHeaders, <<"accept-encoding">>),
    maybe_compress(Status, Accept, list_get(ResponseHeaders0, <<"content-type">>),
                   list_get(ResponseHeaders0, <<"content-encoding">>),
                   list_get(ResponseHeaders0, <<"cache-control">>),
                   list_get(ResponseHeaders0, <<"vary">>),
                   Body,
                   fun(Headers, Encoding, Vary) ->
                       Headers1 = list_put(Headers, <<"content-encoding">>, Encoding),
                       Headers2 = list_put(Headers1, <<"vary">>, Vary),
                       list_remove(Headers2, [<<"content-length">>, <<"etag">>])
                   end,
                   ResponseHeaders0).

maybe_compress(Status, _Accept, _ContentType, _ContentEncoding, _CacheControl, _Vary, Body, _SetFn, Headers)
when Status < 200; Status =:= 204; Status =:= 304; Body =:= <<>> ->
    {Headers, Body};
maybe_compress(_Status, _Accept, _ContentType, _ContentEncoding, _CacheControl, _Vary, Body, _SetFn, Headers)
when byte_size(Body) < ?MIN_COMPRESS_BYTES ->
    {Headers, Body};
maybe_compress(_Status, Accept, ContentType, ContentEncoding, CacheControl, Vary0, Body, SetFn, Headers) ->
    case should_consider_compression(ContentType, ContentEncoding, CacheControl) of
        false ->
            {Headers, Body};
        true ->
            case choose_encoding(Accept) of
                undefined ->
                    {Headers, Body};
                Encoding ->
                    case compress(Encoding, Body) of
                        {ok, Compressed} when byte_size(Compressed) < byte_size(Body) ->
                            Vary = merge_vary_header(Vary0),
                            {SetFn(Headers, encoding_name(Encoding), Vary), Compressed};
                        _ ->
                            {Headers, Body}
                    end
            end
    end.

should_consider_compression(_ContentType, ContentEncoding, _CacheControl)
when is_binary(ContentEncoding), ContentEncoding =/= <<>>, ContentEncoding =/= <<"identity">> ->
    false;
should_consider_compression(ContentType, _ContentEncoding, CacheControl) ->
    case has_no_transform(CacheControl) of
        true -> false;
        false -> is_compressible_content_type(ContentType)
    end.

has_no_transform(undefined) ->
    false;
has_no_transform(CacheControl) when is_binary(CacheControl) ->
    Lower = string:lowercase(CacheControl),
    binary:match(Lower, <<"no-transform">>) =/= nomatch;
has_no_transform(_) ->
    false.

is_compressible_content_type(undefined) ->
    false;
is_compressible_content_type(ContentType) when is_binary(ContentType) ->
    Lower = string:lowercase(ContentType),
    has_prefix(Lower, <<"text/">>) orelse
    binary:match(Lower, <<"application/json">>) =/= nomatch orelse
    binary:match(Lower, <<"application/javascript">>) =/= nomatch orelse
    binary:match(Lower, <<"application/x-javascript">>) =/= nomatch orelse
    binary:match(Lower, <<"application/xml">>) =/= nomatch orelse
    binary:match(Lower, <<"application/xhtml+xml">>) =/= nomatch orelse
    binary:match(Lower, <<"image/svg+xml">>) =/= nomatch.

has_prefix(Bin, Prefix) ->
    PrefixSz = byte_size(Prefix),
    case Bin of
        <<Prefix:PrefixSz/binary, _/binary>> -> true;
        _ -> false
    end.

choose_encoding(Accept) ->
    ZstdQ = q_value(Accept, <<"zstd">>),
    BrQ = q_value(Accept, <<"br">>),
    GzipQ = q_value(Accept, <<"gzip">>),
    case {ZstdQ > 0, BrQ > 0, GzipQ > 0} of
        {true, _, _} ->
            case is_encoding_available(zstd) of
                true -> zstd;
                false -> choose_fallback(BrQ, GzipQ)
            end;
        {false, _, _} ->
            choose_fallback(BrQ, GzipQ)
    end.

choose_fallback(BrQ, GzipQ) when BrQ > 0 ->
    case is_encoding_available(br) of
        true -> br;
        false -> choose_gzip(GzipQ)
    end;
choose_fallback(_BrQ, GzipQ) ->
    choose_gzip(GzipQ).

choose_gzip(GzipQ) when GzipQ > 0 -> gzip;
choose_gzip(_GzipQ) -> undefined.

q_value(undefined, _Encoding) ->
    0.0;
q_value(<<>>, _Encoding) ->
    0.0;
q_value(Accept, Encoding) when is_binary(Accept) ->
    Tokens = binary:split(string:lowercase(Accept), <<",">>, [global]),
    Parsed = [parse_token(T) || T <- Tokens],
    case lists:keyfind(Encoding, 1, Parsed) of
        {_, Q} when is_float(Q) -> Q;
        false ->
            case lists:keyfind(<<"*">>, 1, Parsed) of
                {_, Q2} when is_float(Q2) -> Q2;
                _ -> 0.0
            end
    end.

parse_token(Token0) ->
    Token = trim_bin(Token0),
    case binary:split(Token, <<";">>, [global]) of
        [] ->
            {<<>>, 0.0};
        [Enc] ->
            {trim_bin(Enc), 1.0};
        [Enc | Params] ->
            {trim_bin(Enc), param_q(Params, 1.0)}
    end.

param_q([], Default) ->
    Default;
param_q([P | Rest], Default) ->
    P1 = trim_bin(P),
    case P1 of
        <<"q=", V/binary>> ->
            case catch binary_to_float(trim_bin(V)) of
                Q when is_float(Q), Q >= 0.0 -> Q;
                _ -> Default
            end;
        _ ->
            param_q(Rest, Default)
    end.

encoding_name(gzip) -> <<"gzip">>;
encoding_name(br) -> <<"br">>;
encoding_name(zstd) -> <<"zstd">>.

compress(gzip, Body) ->
    {ok, zlib:gzip(Body)};
compress(br, Body) ->
    case ensure_exported(brotli, encode, 1) of
        true -> {ok, iolist_to_binary(call_optional(brotli, encode, [Body]))};
        false ->
            case ensure_exported(brotli, compress, 1) of
                true -> {ok, iolist_to_binary(call_optional(brotli, compress, [Body]))};
                false -> {error, unavailable}
            end
    end;
compress(zstd, Body) ->
    case ensure_exported(ezstd, compress, 1) of
        true -> {ok, iolist_to_binary(call_optional(ezstd, compress, [Body]))};
        false ->
            case ensure_exported(zstd, compress, 1) of
                true -> {ok, iolist_to_binary(call_optional(zstd, compress, [Body]))};
                false -> {error, unavailable}
            end
    end.

is_encoding_available(gzip) ->
    true;
is_encoding_available(br) ->
    ensure_exported(brotli, encode, 1) orelse ensure_exported(brotli, compress, 1);
is_encoding_available(zstd) ->
    ensure_exported(ezstd, compress, 1) orelse ensure_exported(zstd, compress, 1).

ensure_exported(Module, Func, Arity) ->
    case code:ensure_loaded(Module) of
        {module, Module} -> erlang:function_exported(Module, Func, Arity);
        _ -> false
    end.

call_optional(Module, Func, Args) ->
    erlang:apply(Module, Func, Args).

merge_vary_header(undefined) ->
    <<"accept-encoding">>;
merge_vary_header(Vary0) when is_binary(Vary0) ->
    Lower = string:lowercase(Vary0),
    case binary:match(Lower, <<"accept-encoding">>) of
        nomatch when Lower =:= <<>> -> <<"accept-encoding">>;
        nomatch -> <<Vary0/binary, ", accept-encoding">>;
        _ -> Vary0
    end.

trim_bin(B) when is_binary(B) ->
    list_to_binary(string:trim(binary_to_list(B))).

normalize_key(K) when is_binary(K) ->
    string:lowercase(K).

header_map_get(Map, Key) ->
    maps:get(normalize_key(Key), normalize_map(Map), undefined).

header_map_put(Map, Key, Value) ->
    (normalize_map(Map))#{normalize_key(Key) => Value}.

header_map_remove(Map, Keys) ->
    maps:without([normalize_key(K) || K <- Keys], normalize_map(Map)).

normalize_map(Map) ->
    maps:from_list([{normalize_key(K), V} || {K, V} <- maps:to_list(Map)]).

list_get(Headers, Key) ->
    N = normalize_key(Key),
    case lists:dropwhile(fun({K, _}) -> normalize_key(K) =/= N end, Headers) of
        [{_, V} | _] -> V;
        [] -> undefined
    end.

list_put(Headers, Key, Value) ->
    N = normalize_key(Key),
    [{N, Value} | [{K, V} || {K, V} <- Headers, normalize_key(K) =/= N]].

list_remove(Headers, Keys) ->
    KeySet = [normalize_key(K) || K <- Keys],
    [{K, V} || {K, V} <- Headers, not lists:member(normalize_key(K), KeySet)].