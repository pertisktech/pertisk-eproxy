%% @doc Shared upstream Gun connection pool for proxy request paths.
%%
%% Maintains a small reusable pool per upstream target + request profile
%% (e.g. HTTP/1.1 vs gRPC/HTTP2) to avoid per-request connect/handshake cost.
%%
%% Idle eviction: connections not used for longer than `upstream_pool_idle_timeout_secs`
%% (default 240 s = 4 min) are proactively closed and removed.  This prevents the
%% 20-25 minute idle timeout symptom where firewalls/NAT tables silently close the
%% TCP socket while the Gun process remains alive — causing the next request to hang
%% until the full REQUEST_TIMEOUT expires.

-module(pertisk_eproxy_upstream_pool).
-behaviour(gen_server).

-export([start_link/0, checkout/5, invalidate/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(DEFAULT_POOL_SIZE, 16).
%% 4 minutes — safely below common firewall/NAT idle TCP timeouts (usually 5–30 min).
-define(DEFAULT_IDLE_TIMEOUT_MS, 240000).
%% Sweep interval: evict stale connections proactively every minute.
-define(SWEEP_INTERVAL_MS, 60000).

%% Connections are stored as {Pid, LastUsedMs} tuples so idle time can be measured.
-type conn_entry() :: {pid(), non_neg_integer()}.

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec checkout(string() | binary(), inet:port_number(), atom(), atom(), map()) ->
    {ok, pid()} | {error, term()}.
checkout(UpHost, UpPort, Transport, ReqKind, GunOpts) ->
    case erlang:whereis(?SERVER) of
        undefined ->
            open_connection(UpHost, UpPort, GunOpts);
        _Pid ->
            Timeout = maps:get(connect_timeout, GunOpts, 10000) + 1000,
            gen_server:call(?SERVER,
                {checkout, UpHost, UpPort, Transport, ReqKind, GunOpts},
                Timeout)
    end.

-spec invalidate(pid()) -> ok.
invalidate(Pid) when is_pid(Pid) ->
    case erlang:whereis(?SERVER) of
        undefined ->
            catch gun:close(Pid),
            ok;
        _ ->
            gen_server:cast(?SERVER, {invalidate, Pid})
    end;
invalidate(_) ->
    ok.

init([]) ->
    erlang:send_after(?SWEEP_INTERVAL_MS, self(), sweep_idle),
    {ok, #{pools => #{}}}.

handle_call({checkout, UpHost, UpPort, Transport, ReqKind, GunOpts}, _From,
            State = #{pools := Pools0}) ->
    Key = pool_key(UpHost, UpPort, Transport, ReqKind),
    Entry0 = maps:get(Key, Pools0, empty_entry()),
    Entry1 = refresh_entry(Entry0),
    case maps:get(conns, Entry1) of
        [] ->
            case open_connection(UpHost, UpPort, GunOpts) of
                {ok, ConnPid} ->
                    monitor(process, ConnPid),
                    Entry2 = Entry1#{conns => [{ConnPid, now_ms()}], rr => 1},
                    {Entry3, State2} = maybe_async_fill(
                        Key, Entry2, UpHost, UpPort, ReqKind, GunOpts,
                        State#{pools => Pools0#{Key => Entry2}}
                    ),
                    {reply, {ok, ConnPid}, put_pool(Key, Entry3, State2)};
                {error, Reason} ->
                    {reply, {error, Reason}, put_pool(Key, Entry1, State)}
            end;
        Conns ->
            {ConnPid, Entry2} = pick_rr(Conns, Entry1),
            {Entry3, State2} = maybe_async_fill(
                Key, Entry2, UpHost, UpPort, ReqKind, GunOpts,
                State#{pools => Pools0#{Key => Entry2}}
            ),
            {reply, {ok, ConnPid}, put_pool(Key, Entry3, State2)}
    end;

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({fill_one, Key, UpHost, UpPort, ReqKind, GunOpts},
            State = #{pools := Pools0}) ->
    case maps:find(Key, Pools0) of
        error ->
            {noreply, State};
        {ok, Entry0} ->
            Entry1 = refresh_entry(Entry0),
            Target = pool_target_size(),
            Conns = maps:get(conns, Entry1),
            case length(Conns) >= Target of
                true ->
                    Entry2 = Entry1#{filling => false},
                    {noreply, put_pool(Key, Entry2, State)};
                false ->
                    case open_connection(UpHost, UpPort, GunOpts) of
                        {ok, ConnPid} ->
                            monitor(process, ConnPid),
                            Entry2 = Entry1#{
                                conns => [{ConnPid, now_ms()} | Conns],
                                filling => false
                            },
                            maybe_fill_again(Key, UpHost, UpPort, ReqKind, GunOpts, Entry2),
                            {noreply, put_pool(Key, Entry2, State)};
                        {error, _Reason} ->
                            Entry2 = Entry1#{filling => false},
                            {noreply, put_pool(Key, Entry2, State)}
                    end
            end
    end;

handle_cast({invalidate, Pid}, State) ->
    catch gun:close(Pid),
    {noreply, remove_pid_from_pools(Pid, State)};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(sweep_idle, State = #{pools := Pools0}) ->
    erlang:send_after(?SWEEP_INTERVAL_MS, self(), sweep_idle),
    Pools1 = maps:map(
        fun(_Key, Entry) -> refresh_entry(Entry) end,
        Pools0
    ),
    {noreply, State#{pools => Pools1}};

handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    {noreply, remove_pid_from_pools(Pid, State)};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #{pools := Pools}) ->
    lists:foreach(
        fun(#{conns := Conns}) ->
            lists:foreach(
                fun({Pid, _}) -> catch gun:close(Pid) end,
                Conns
            )
        end,
        maps:values(Pools)
    ),
    ok;
terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

empty_entry() ->
    #{conns => [], rr => 0, filling => false}.

put_pool(Key, Entry, State = #{pools := Pools}) ->
    State#{pools => Pools#{Key => Entry}}.

%% Remove connections where the Gun process is dead OR the connection has been
%% idle for longer than idle_timeout_ms (TCP socket likely closed by firewall/NAT).
-spec refresh_entry(map()) -> map().
refresh_entry(Entry = #{conns := Conns}) ->
    IdleMs = idle_timeout_ms(),
    NowMs  = now_ms(),
    Alive  = lists:filter(
        fun({Pid, LastUsed}) ->
            is_process_alive(Pid) andalso (NowMs - LastUsed) < IdleMs
        end,
        Conns
    ),
    %% Close evicted connections so the Gun process exits cleanly.
    Evicted = [Pid || {Pid, _} <- Conns, not lists:keymember(Pid, 1, Alive)],
    lists:foreach(fun(P) -> catch gun:close(P) end, Evicted),
    Entry#{conns => Alive};
refresh_entry(Entry) ->
    Entry.

-spec pick_rr([conn_entry()], map()) -> {pid(), map()}.
pick_rr(Conns, Entry = #{rr := Rr0}) ->
    N = length(Conns),
    Idx = Rr0 rem N,
    {ConnPid, _} = lists:nth(Idx + 1, Conns),
    %% Refresh last_used timestamp so the connection is not evicted while in-flight.
    UpdatedConns = lists:map(
        fun({P, _}) when P =:= ConnPid -> {P, now_ms()};
            (Other) -> Other
        end,
        Conns
    ),
    {ConnPid, Entry#{rr => Rr0 + 1, conns => UpdatedConns}}.

pool_key(UpHost, UpPort, Transport, ReqKind) ->
    {normalize_host(UpHost), UpPort, Transport, req_profile(ReqKind)}.

normalize_host(H) when is_binary(H) ->
    H;
normalize_host(H) when is_list(H) ->
    unicode:characters_to_binary(H, utf8);
normalize_host(H) ->
    unicode:characters_to_binary(io_lib:format("~p", [H]), utf8).

req_profile(grpc) -> grpc;
req_profile(_) -> http.

maybe_async_fill(Key, Entry, UpHost, UpPort, ReqKind, GunOpts, State) ->
    Target = pool_target_size(),
    Conns = maps:get(conns, Entry),
    Filling = maps:get(filling, Entry, false),
    case (length(Conns) < Target) andalso (Filling =:= false) of
        true ->
            gen_server:cast(
                ?SERVER,
                {fill_one, Key, UpHost, UpPort, ReqKind, GunOpts}
            ),
            {Entry#{filling => true}, State};
        false ->
            {Entry, State}
    end.

maybe_fill_again(Key, UpHost, UpPort, ReqKind, GunOpts, Entry) ->
    Target = pool_target_size(),
    case length(maps:get(conns, Entry)) < Target of
        true ->
            gen_server:cast(
                ?SERVER,
                {fill_one, Key, UpHost, UpPort, ReqKind, GunOpts}
            );
        false ->
            ok
    end.

remove_pid_from_pools(Pid, State = #{pools := Pools0}) ->
    Pools1 = maps:map(
        fun(_Key, Entry0) ->
            Entry1 = refresh_entry(Entry0),
            Conns1 = [{P, T} || {P, T} <- maps:get(conns, Entry1, []), P =/= Pid],
            Entry1#{conns => Conns1}
        end,
        Pools0
    ),
    State#{pools => Pools1}.

pool_target_size() ->
    Config = pertisk_eproxy_config:get_config(),
    case maps:get(upstream_pool_size, Config, ?DEFAULT_POOL_SIZE) of
        N when is_integer(N), N > 0 -> N;
        _ -> ?DEFAULT_POOL_SIZE
    end.

idle_timeout_ms() ->
    Config = pertisk_eproxy_config:get_config(),
    case maps:get(upstream_pool_idle_timeout_secs, Config, undefined) of
        N when is_integer(N), N > 0 -> N * 1000;
        _ -> ?DEFAULT_IDLE_TIMEOUT_MS
    end.

now_ms() ->
    erlang:monotonic_time(millisecond).

open_connection(UpHost, UpPort, GunOpts) ->
    case gun:open(UpHost, UpPort, GunOpts) of
        {ok, ConnPid} ->
            Timeout = maps:get(connect_timeout, GunOpts, 10000),
            case gun:await_up(ConnPid, Timeout) of
                {ok, _Proto} ->
                    {ok, ConnPid};
                {error, Reason} ->
                    catch gun:close(ConnPid),
                    {error, {await_up, Reason}}
            end;
        {error, Reason} ->
            {error, {connect, Reason}}
    end.
