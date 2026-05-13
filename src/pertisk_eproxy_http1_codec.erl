%% @doc Minimal HTTP/1.1 request reader / response writer for Ranch sockets.
-module(pertisk_eproxy_http1_codec).

-export([read_request/3, read_request/4, write_http_response/5, write_raw/3, peer/2, close/2, setopts/3]).

-define(MAX_LINE, 65536).
-define(MAX_HEADERS, 64).
-define(MAX_HEADER_BLOCK, 262144).
-define(DEFAULT_MAX_BODY, 16777216).

peer(ranch_tcp, Sock) -> inet:peername(Sock);
peer(ranch_ssl, Sock) -> ssl:peername(Sock).

close(ranch_tcp, Sock) -> gen_tcp:close(Sock);
close(ranch_ssl, Sock) -> ssl:close(Sock).

setopts(ranch_tcp, Sock, Opts) -> inet:setopts(Sock, Opts);
setopts(ranch_ssl, Sock, Opts) -> ssl:setopts(Sock, Opts).

read_request(Transport, Sock, Opts) ->
    read_request(Transport, Sock, Opts, <<>>).

read_request(Transport, Sock, Opts, InitialBuf) ->
    MaxBody = maps:get(max_body, Opts, ?DEFAULT_MAX_BODY),
    case take_line(InitialBuf, Transport, Sock, ?MAX_LINE) of
        {ok, Line, Buf1} ->
            case parse_request_line(Line) of
                {ok, Method, Path, Qs, RawPath, Ver} ->
                    case take_headers(Buf1, Transport, Sock, 0, 0, #{}) of
                        {ok, Headers0, Buf2} ->
                            Headers = lower_header_map(Headers0),
                            Host = maps:get(<<"host">>, Headers, <<>>),
                            TE = string:lowercase(maps:get(<<"transfer-encoding">>, Headers, <<>>)),
                            HasChunked = binary:match(TE, <<"chunked">>) =/= nomatch,
                            case resolve_content_length(Headers, HasChunked) of
                                {error, _} = ErrLen ->
                                    ErrLen;
                                {ok, CL} when CL > MaxBody ->
                                    {error, body_too_large};
                                {ok, CL} ->
                                    case take_exact_body(Buf2, Transport, Sock, CL) of
                                        {ok, Body, Buf3} ->
                                            {ok, #{
                                                method => Method,
                                                path => Path,
                                                raw_path => RawPath,
                                                qs => Qs,
                                                host => Host,
                                                http_version => Ver,
                                                headers => Headers,
                                                body => Body
                                            }, Buf3};
                                        Err ->
                                            Err
                                    end
                            end;
                        Err ->
                            Err
                    end;
                Err ->
                    Err
            end;
        Err ->
            Err
    end.

take_exact_body(Buf, _Transport, _Sock, 0) ->
    {ok, <<>>, Buf};
take_exact_body(Buf, Transport, Sock, Need) when Need > 0 ->
    Bsz = byte_size(Buf),
    if
        Bsz >= Need ->
            <<Body:Need/binary, Rest/binary>> = Buf,
            {ok, Body, Rest};
        true ->
            case recv(Transport, Sock, 0, 60000) of
                {ok, More} ->
                    take_exact_body(<<Buf/binary, More/binary>>, Transport, Sock, Need);
                {error, _} = E ->
                    E
            end
    end.

take_line(Buf, _Transport, _Sock, MaxTotal) when byte_size(Buf) > MaxTotal ->
    {error, line_too_long};
take_line(Buf, Transport, Sock, MaxTotal) ->
    case binary:split(Buf, <<"\r\n">>) of
        [Line, Rest] ->
            {ok, Line, Rest};
        [_] ->
            case recv(Transport, Sock, 0, 60000) of
                {ok, <<>>} ->
                    {error, closed};
                {ok, More} ->
                    take_line(<<Buf/binary, More/binary>>, Transport, Sock, MaxTotal);
                {error, _} = E ->
                    E
            end
    end.

take_headers(Buf, Transport, Sock, Count, BlockSize, HMap) when Count < ?MAX_HEADERS, BlockSize < ?MAX_HEADER_BLOCK ->
    case take_line(Buf, Transport, Sock, ?MAX_LINE) of
        {ok, <<>>, Rest} ->
            {ok, HMap, Rest};
        {ok, Line, Rest} ->
            case parse_header_line(Line) of
                {ok, K, V} ->
                    take_headers(Rest, Transport, Sock, Count + 1, BlockSize + byte_size(Line), HMap#{K => V});
                skip ->
                    take_headers(Rest, Transport, Sock, Count + 1, BlockSize + byte_size(Line), HMap);
                {error, _} = E ->
                    E
            end;
        Err ->
            Err
    end;
take_headers(_, _, _, _, _, _) ->
    {error, too_many_headers}.

parse_request_line(Line) ->
    case binary:split(Line, <<" ">>, [global]) of
        [Method, Target, Ver] ->
            case binary:split(Target, <<"?">>) of
                [P] ->
                    {ok, Method, P, <<>>, Target, Ver};
                [P, Q] ->
                    {ok, Method, P, Q, Target, Ver}
            end;
        _ ->
            {error, bad_request_line}
    end.

parse_header_line(<<>>) ->
    skip;
parse_header_line(Line) ->
    case binary:split(Line, <<":">>) of
        [K, V0] ->
            V = trim_lead_ws(V0),
            {ok, string:lowercase(K), V};
        _ ->
            skip
    end.

trim_lead_ws(<<$\s, R/binary>>) -> trim_lead_ws(R);
trim_lead_ws(<<$\t, R/binary>>) -> trim_lead_ws(R);
trim_lead_ws(R) -> R.

lower_header_map(M) ->
    maps:fold(
        fun(K, V, Acc) ->
            Acc#{string:lowercase(K) => V}
        end,
        #{},
        M
    ).

resolve_content_length(_Headers, true) ->
    {error, chunked_not_supported};
resolve_content_length(Headers, false) ->
    case maps:get(<<"content-length">>, Headers, undefined) of
        undefined ->
            {ok, 0};
        Raw ->
            case catch binary_to_integer(trim_ws(Raw)) of
                N when is_integer(N), N >= 0 ->
                    {ok, N};
                _ ->
                    {error, bad_content_length}
            end
    end.

trim_ws(B) when is_binary(B) ->
    list_to_binary(string:trim(binary_to_list(B))).

write_http_response(Transport, Sock, Status, HeadersMap, Body) when is_binary(Body) ->
    H2 = HeadersMap#{<<"content-length">> => integer_to_binary(byte_size(Body))},
    StatusLine = iolist_to_binary(io_lib:format("HTTP/1.1 ~w ", [Status])),
    %% format_headers/1 returns a nested iolist — must not use <<H/binary>> unless H is a binary.
    Resp = iolist_to_binary([StatusLine, <<"\r\n">>, format_headers(H2), <<"\r\n">>, Body]),
    write_raw(Transport, Sock, Resp).

write_raw(Transport, Sock, IoData) ->
    Bin = iolist_to_binary(IoData),
    send(Transport, Sock, Bin).

format_headers(HMap) ->
    maps:fold(
        fun(K, V, Acc) ->
            Line = [K, <<": ">>, V, <<"\r\n">>],
            [Line | Acc]
        end,
        [],
        HMap
    ).

recv(ranch_tcp, Sock, Len, Timeout) ->
    gen_tcp:recv(Sock, Len, Timeout);
recv(ranch_ssl, Sock, Len, Timeout) ->
    ssl:recv(Sock, Len, Timeout).

send(ranch_tcp, Sock, Data) -> gen_tcp:send(Sock, Data);
send(ranch_ssl, Sock, Data) -> ssl:send(Sock, Data).
