%% @doc Cached '/api/health' JSON refreshed in the background.
%%
%% Avoids rebuilding TLS cert rows + backend status on every request under load
%% (k6 '/api/health' benchmarks and admin dashboard polling).
-module(pertisk_eproxy_health_cache).
-behaviour(gen_server).

-export([start_link/0, get/0, invalidate/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(TAB, pertisk_eproxy_health_cache_tab).
-define(DEFAULT_REFRESH_MS, 3000).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec get() -> {ok, binary()} | {error, term()}.
get() ->
    case ets:lookup(?TAB, body) of
        [{body, Body}] when is_binary(Body) ->
            {ok, Body};
        _ ->
            gen_server:call(?SERVER, refresh_now, 30000)
    end.

invalidate() ->
    case erlang:whereis(?SERVER) of
        undefined -> ok;
        Pid -> gen_server:cast(Pid, invalidate)
    end.

init([]) ->
    _ = ets:new(?TAB, [named_table, protected, set, {read_concurrency, true}]),
    _ = schedule_refresh(0),
    {ok, #{}}.

handle_call(refresh_now, _From, State) ->
    Reply = refresh_body(),
    {reply, Reply, State};

handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(invalidate, State) ->
    _ = ets:delete(?TAB, body),
    _ = schedule_refresh(0),
    {noreply, State}.

handle_info(refresh, State) ->
    _ = refresh_body(),
    _ = schedule_refresh(refresh_ms()),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

refresh_body() ->
    try
        Body = pertisk_eproxy_admin_handler:build_health_json(),
        true = ets:insert(?TAB, {body, Body}),
        {ok, Body}
    catch
        Class:Reason ->
            {error, {Class, Reason}}
    end.

schedule_refresh(DelayMs) when is_integer(DelayMs), DelayMs >= 0 ->
    erlang:send_after(DelayMs, self(), refresh).

refresh_ms() ->
    Config = pertisk_eproxy_config:get_config(),
    case maps:get(health_cache_refresh_ms, Config, ?DEFAULT_REFRESH_MS) of
        N when is_integer(N), N >= 500 -> N;
        _ -> ?DEFAULT_REFRESH_MS
    end.
