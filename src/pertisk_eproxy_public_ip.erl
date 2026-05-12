%% @doc Best-effort public IPv4/IPv6 lookup (cached) for the admin dashboard.
-module(pertisk_eproxy_public_ip).

-behaviour(gen_server).

-export([start_link/0, snapshot/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(REFRESH_MS, 300000).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec snapshot() -> map().
snapshot() ->
    case erlang:whereis(?SERVER) of
        undefined ->
            empty_snapshot();
        Pid ->
            try gen_server:call(Pid, get, 5000) of
                M when is_map(M) -> M
            catch
                _:_ -> empty_snapshot()
            end
    end.

empty_snapshot() ->
    #{
        <<"public_ipv4">> => null,
        <<"public_ipv6">> => null,
        <<"public_ip_fetched_at_ms">> => null,
        <<"public_ip_error">> => null
    }.

init([]) ->
    self() ! refresh,
    {ok, #{v4 => null, v6 => null, err => null, ts => null}}.

handle_call(get, _From, St) ->
    {reply, to_json(St), St};
handle_call(_Req, _From, St) ->
    {reply, {error, unknown}, St}.

handle_cast(_C, St) ->
    {noreply, St}.

handle_info(refresh, _St) ->
    {V4, V6, Err} = fetch_both(),
    Ts = erlang:system_time(millisecond),
    Next = #{
        v4 => norm_ip(V4),
        v6 => norm_ip(V6),
        err => Err,
        ts => Ts
    },
    _ = erlang:send_after(?REFRESH_MS, self(), refresh),
    {noreply, Next};
handle_info(_I, St) ->
    {noreply, St}.

terminate(_Reason, _St) ->
    ok.

code_change(_Old, St, _Extra) ->
    {ok, St}.

to_json(St) ->
    #{
        <<"public_ipv4">> => maps:get(v4, St, null),
        <<"public_ipv6">> => maps:get(v6, St, null),
        <<"public_ip_fetched_at_ms">> => maps:get(ts, St, null),
        <<"public_ip_error">> => maps:get(err, St, null)
    }.

norm_ip(undefined) -> null;
norm_ip(null) -> null;
norm_ip(B) when is_binary(B) -> B.

fetch_both() ->
    V4 = fetch_url("http://api4.ipify.org"),
    V6 = fetch_url("http://api6.ipify.org"),
    Err =
        case {V4, V6} of
            {undefined, undefined} ->
                <<"could not reach ipify (no outbound HTTP or dual-stack unavailable)">>;
            _ ->
                null
        end,
    {V4, V6, Err}.

fetch_url(Url) ->
    Req = {Url, []},
    HttpOpts = [{timeout, 4000}, {connect_timeout, 3000}],
    Opts = [{body_format, binary}],
    try
        case httpc:request(get, Req, HttpOpts, Opts) of
            {ok, {{_, 200, _}, _, Body}} when is_binary(Body) ->
                trim_ip(Body);
            {ok, {{_, 200, _}, _, Body}} when is_list(Body) ->
                trim_ip(iolist_to_binary(Body));
            _ ->
                undefined
        end
    catch
        _:_ ->
            undefined
    end.

trim_ip(Bin) ->
    S0 = unicode:characters_to_list(Bin, utf8),
    S = string:trim(S0, both, [$\s, $\r, $\n, $\t]),
    case S of
        "" -> undefined;
        _ -> unicode:characters_to_binary(S, utf8)
    end.
