%% @doc Simple per-client-IP token bucket rate limiter (optional, config-driven).
-module(pertisk_eproxy_rate_limit).

-export([check/2, check/3]).

-define(TAB, pertisk_eproxy_rate_limit_tab).

-spec check(binary(), binary()) -> allow | deny.
check(ClientIp, Host) ->
    check(ClientIp, Host, undefined).

-spec check(binary(), binary(), binary() | undefined) -> allow | deny.
check(ClientIp, Host, SiteHost) ->
    case effective_limits(SiteHost) of
        disabled ->
            allow;
        {Rps, Burst} ->
            ensure_table(),
            Key = {ClientIp, Host, SiteHost},
            NowMs = erlang:monotonic_time(millisecond),
            WindowMs = 1000,
            case ets:lookup(?TAB, Key) of
                [{Key, Tokens, LastMs}] ->
                    Elapsed = max(0, NowMs - LastMs),
                    Refill = (Elapsed * Rps) div WindowMs,
                    NewTokens = min(Burst, Tokens + Refill),
                    case NewTokens >= 1 of
                        true ->
                            true = ets:insert(?TAB, {Key, NewTokens - 1, NowMs}),
                            allow;
                        false ->
                            true = ets:insert(?TAB, {Key, NewTokens, NowMs}),
                            pertisk_eproxy_metrics:inc_rate_limit_denied(Host, SiteHost),
                            deny
                    end;
                [] ->
                    true = ets:insert(?TAB, {Key, Burst - 1, NowMs}),
                    allow
            end
    end.

effective_limits(undefined) ->
    global_limits();
effective_limits(SiteHost) when is_binary(SiteHost) ->
    case pertisk_eproxy_config:site_rate_limit(SiteHost) of
        {ok, Rps, Burst} -> {Rps, Burst};
        error -> global_limits()
    end;
effective_limits(_) ->
    global_limits().

global_limits() ->
    Config = pertisk_eproxy_config:get_config(),
    Enabled = maps:get(rate_limit_enabled, Config, false),
    Rps = maps:get(rate_limit_rps, Config, 0),
    Burst = maps:get(rate_limit_burst, Config, 0),
    case Enabled andalso Rps > 0 andalso Burst > 0 of
        true -> {Rps, Burst};
        false -> disabled
    end.

ensure_table() ->
    case ets:info(?TAB) of
        undefined ->
            ets:new(?TAB, [named_table, public, set, {read_concurrency, true}]);
        _ ->
            ?TAB
    end.
