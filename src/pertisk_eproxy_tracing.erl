%% @doc W3C Trace Context propagation for upstream requests (OpenTelemetry foundation).
-module(pertisk_eproxy_tracing).

-export([request_context/1, inject_headers/1, inject_headers/2]).

-type ctx() :: #{
    trace_id := binary(),
    span_id := binary(),
    sampled := boolean()
}.

%% @doc Build or continue trace context from incoming headers map.
-spec request_context(map()) -> ctx().
request_context(InHeaders) when is_map(InHeaders) ->
    case maps:get(<<"traceparent">>, InHeaders, undefined) of
        TP when is_binary(TP) ->
            case parse_traceparent(TP) of
                {ok, Ctx} -> Ctx;
                error ->
                    case otel_enabled() of
                        true -> new_context();
                        false -> undefined
                    end
            end;
        _ ->
            case otel_enabled() of
                true -> new_context();
                false -> undefined
            end
    end;
request_context(_) ->
    case otel_enabled() of
        true -> new_context();
        false -> undefined
    end.

%% @doc Inject traceparent into a header map when tracing is active.
-spec inject_headers(map()) -> map().
inject_headers(Headers) ->
    inject_headers(Headers, request_context(Headers)).

-spec inject_headers(map(), ctx() | undefined) -> map().
inject_headers(Headers, undefined) ->
    Headers;
inject_headers(Headers, Ctx) when is_map(Ctx) ->
    Headers#{<<"traceparent">> => format_traceparent(Ctx)}.

parse_traceparent(<<"00-", Rest/binary>>) ->
    case binary:split(Rest, <<"-">>, [global]) of
        [TraceId, ParentId, Flags] when byte_size(TraceId) =:= 32, byte_size(ParentId) =:= 16 ->
            Sampled = Flags =:= <<"01">>,
            {ok, #{trace_id => TraceId, span_id => new_span_id(), sampled => Sampled}};
        _ ->
            error
    end;
parse_traceparent(_) ->
    error.

new_context() ->
    #{
        trace_id => new_trace_id(),
        span_id => new_span_id(),
        sampled => true
    }.

new_trace_id() ->
    binary:encode_hex(crypto:strong_rand_bytes(16), lowercase).

new_span_id() ->
    binary:encode_hex(crypto:strong_rand_bytes(8), lowercase).

format_traceparent(#{trace_id := TraceId, span_id := SpanId, sampled := Sampled}) ->
    Flag = case Sampled of true -> <<"01">>; false -> <<"00">> end,
    <<"00-", TraceId/binary, "-", SpanId/binary, "-", Flag/binary>>.

otel_enabled() ->
    Config = pertisk_eproxy_config:get_config(),
    maps:get(otel_enabled, Config, false) =:= true.
