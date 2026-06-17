%% @doc Per-backend gen_server for pertisk_eproxy.
%%
%% Each backend config entry (from proxy.json 'backends' list) has one
%% corresponding process that:
%%   - tracks LB state (round-robin cursor, connection counts)
%%   - manages health-check timers and upstream availability
%%   - exposes pick_upstream/2 and done_upstream/2 for the proxy handler
%%
%% Naming: registered as {via, gproc, {n, l, {backend, Name}}} so the
%% backend supervisor can hold on to processes without storing PIDs.
%% Falls back to a local ets-name approach if gproc is unavailable.

-module(pertisk_eproxy_backend).
-behaviour(gen_server).
-compile({no_auto_import,[whereis/1]}).

-export([start_link/1]).
-export([whereis/1, pick_upstream/2, done_upstream/3, update/2, status/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-ifdef(TEST).
-export([backend_name/1, parse_addr/1, split_host_port/2, safe_port/1,
         scheme_default_port/1, uri_text_to_list/1, transient_backoff_ms/1,
         conn_for_addr/2, increment_conns/2, decrement_conns/2,
         mark_transient_down/2, clear_transient_down/2,
         maybe_recover_transient_down/1, merge_update/2]).
-endif.

-define(HEALTH_DEFAULT_SECS, 30).
-define(TRANSIENT_DOWN_DEFAULT_MS, 5000).
-define(TRANSIENT_DOWN_MAX_MS, 60000).

%% ---------------------------------------------------------------------------
%% Public API
%% ---------------------------------------------------------------------------

start_link(Backend = #{name := Name}) ->
    gen_server:start_link({local, backend_name(Name)}, ?MODULE, Backend, []).

%% Find the PID for a backend by name (returns undefined if not running).
-spec whereis(binary()) -> pid() | undefined.
whereis(Name) ->
    erlang:whereis(backend_name(Name)).

%% Pick an upstream for a request. ClientIp may be undefined.
-spec pick_upstream(binary(), binary() | undefined) ->
    {ok, binary()} | {error, no_healthy_upstream}.
pick_upstream(Name, ClientIp) ->
    case ?MODULE:whereis(Name) of
        undefined -> {error, no_healthy_upstream};
        Pid       -> gen_server:call(Pid, {pick, ClientIp})
    end.

%% Notify the backend that a request to Addr finished (decrements conn count).
-spec done_upstream(binary(), binary(), ok | error) -> ok.
done_upstream(Name, Addr, Result) ->
    case ?MODULE:whereis(Name) of
        undefined -> ok;
        Pid       -> gen_server:cast(Pid, {done, Addr, Result})
    end.

%% Hot-reload: update backend config while preserving health state.
-spec update(binary(), map()) -> ok.
update(Name, Backend) ->
    case ?MODULE:whereis(Name) of
        undefined -> ok;
        Pid       -> gen_server:cast(Pid, {update, Backend})
    end.

%% Return a status map with upstream health and connection counts.
-spec status(binary() | list()) -> {ok, map()} | {error, not_found}.
status(Name) when is_list(Name) ->
    status(iolist_to_binary(Name));
status(Name) ->
    case ?MODULE:whereis(Name) of
        undefined -> {error, not_found};
        Pid       -> gen_server:call(Pid, status)
    end.

%% ---------------------------------------------------------------------------
%% gen_server callbacks
%% ---------------------------------------------------------------------------

init(Backend = #{name := Name}) ->
    lager:info("Backend ~s started", [Name]),
    State = init_state(Backend),
    State2 = schedule_health_check(State),
    {ok, State2}.

handle_call({pick, ClientIp}, _From, State = #{lb := LbState, algorithm := Algo, name := Name}) ->
    LbState1 = maybe_recover_transient_down(LbState),
    Healthy = [U || U = #{healthy := true} <- maps:get(upstreams, LbState1, [])],
    case Healthy of
        [#{addr := Addr}] ->
            {reply, {ok, Addr}, State#{lb => LbState1}};
        _ ->
            case pertisk_eproxy_lb:next(LbState1, Algo, ClientIp) of
                {ok, #{addr := Addr}, NewLb} ->
                    NewState =
                        case track_connections(Algo) of
                            true ->
                                NewLb2 = increment_conns(Addr, NewLb),
                                ok = pertisk_eproxy_metrics:set_upstream_conn(
                                    Name, Addr, conn_for_addr(NewLb2, Addr)
                                ),
                                State#{lb => NewLb2};
                            false ->
                                State#{lb => NewLb}
                        end,
                    {reply, {ok, Addr}, NewState};
                {error, _} = Err ->
                    {reply, Err, State#{lb => LbState1}}
            end
    end;

handle_call(status, _From, State = #{lb := #{upstreams := Ups}, name := Name}) ->
    Report = #{
        name      => Name,
        algorithm => maps:get(algorithm, State),
        upstreams => Ups
    },
    {reply, {ok, Report}, State};

handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({done, Addr, Result}, State = #{lb := LbState, algorithm := Algo, name := Name}) ->
    NewLb0 =
        case track_connections(Algo) of
            true -> decrement_conns(Addr, LbState);
            false -> LbState
        end,
    NewLb =
        case Result of
            ok -> clear_transient_down(Addr, NewLb0);
            error -> mark_transient_down(Addr, NewLb0);
            _ -> NewLb0
        end,
    case track_connections(Algo) of
        true ->
            ok = pertisk_eproxy_metrics:set_upstream_conn(Name, Addr, conn_for_addr(NewLb, Addr));
        false ->
            ok
    end,
    {noreply, State#{lb => NewLb}};

handle_cast({update, NewBackend}, State) ->
    %% Merge new config, preserving existing health/conn info for known upstreams.
    NewState = merge_update(State, NewBackend),
    NewState2 = reschedule_health_check(NewState),
    {noreply, NewState2};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(health_check, State) ->
    NewState = run_health_checks(State),
    NewState2 = schedule_health_check(NewState),
    {noreply, NewState2};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ---------------------------------------------------------------------------
%% Internal helpers
%% ---------------------------------------------------------------------------

backend_name(Name) when is_binary(Name) ->
    binary_to_atom(<<"backend_", Name/binary>>, utf8);
backend_name(Name) when is_atom(Name) ->
    Name.

init_state(Backend = #{name := Name}) ->
    Upstreams = [#{addr    => maps:get(addr, U),
                   weight  => maps:get(weight, U, 1),
                   healthy => true,
                                     conns   => 0,
                                     transient_down_until_ms => 0,
                                     transient_fail_streak => 0}
                 || U <- maps:get(upstreams, Backend, [])],
    #{
        name        => Name,
        algorithm   => maps:get(algorithm, Backend, round_robin),
        health_path => maps:get(health_path, Backend, undefined),
        health_secs => maps:get(health_interval_secs, Backend, ?HEALTH_DEFAULT_SECS),
        health_tref => undefined,
        lb          => #{
            algorithm => maps:get(algorithm, Backend, round_robin),
            upstreams => Upstreams,
            rr_index  => 0
        }
    }.

schedule_health_check(State = #{health_secs := Secs, health_path := Path})
    when Path =/= undefined, Secs > 0 ->
    Ref = erlang:send_after(Secs * 1000, self(), health_check),
    State#{health_tref => Ref};
schedule_health_check(State) ->
    State.

reschedule_health_check(State = #{health_tref := Ref}) when Ref =/= undefined ->
    erlang:cancel_timer(Ref),
    schedule_health_check(State#{health_tref => undefined});
reschedule_health_check(State) ->
    schedule_health_check(State).

run_health_checks(State = #{health_path := undefined}) ->
    %% Even without active HTTP health probes, allow transiently-down upstreams
    %% to re-enter rotation after their cooldown expires.
    State#{lb => maybe_recover_transient_down(maps:get(lb, State))};
run_health_checks(State = #{lb := LbState = #{upstreams := Upstreams}, health_path := Path}) ->
    NewUpstreams = lists:map(fun(U = #{addr := Addr}) ->
        Healthy = do_health_check(Addr, Path),
        OldHealthy = maps:get(healthy, U),
        case Healthy =/= OldHealthy of
            true ->
                lager:info("Backend upstream ~s health changed: ~p -> ~p",
                           [Addr, OldHealthy, Healthy]);
            false -> ok
        end,
        U#{healthy => Healthy, transient_down_until_ms => 0}
    end, Upstreams),
    State#{lb => LbState#{upstreams => NewUpstreams}}.

transient_down_ms() ->
    Config = pertisk_eproxy_config:get_config(),
    case maps:get(upstream_transient_down_ms, Config, ?TRANSIENT_DOWN_DEFAULT_MS) of
        N when is_integer(N), N > 0 -> N;
        _ -> ?TRANSIENT_DOWN_DEFAULT_MS
    end.

mark_transient_down(Addr, LbState = #{upstreams := Upstreams}) ->
    %% Never quarantine the only upstream in a backend. Doing so turns transient
    %% transport errors into guaranteed "no healthy upstream" responses.
    case length(Upstreams) =< 1 of
        true ->
            lager:warning("Backend upstream ~s error ignored for transient-down because backend has a single upstream",
                          [Addr]),
            LbState;
        false ->
            mark_transient_down_multi(Addr, LbState)
    end.

mark_transient_down_multi(Addr, LbState = #{upstreams := Upstreams}) ->
    Now = erlang:monotonic_time(millisecond),
    NewUps = lists:map(
        fun
            (U = #{addr := A}) when A =:= Addr ->
                Streak = maps:get(transient_fail_streak, U, 0) + 1,
                CooldownMs = transient_backoff_ms(Streak),
                Until = Now + CooldownMs,
                lager:warning("Backend upstream ~s transient-down streak=~p cooldown_ms=~p",
                              [Addr, Streak, CooldownMs]),
                U#{healthy => false,
                   transient_down_until_ms => Until,
                   transient_fail_streak => Streak};
            (U) -> U
        end,
        Upstreams
    ),
    LbState#{upstreams => NewUps}.

clear_transient_down(Addr, LbState = #{upstreams := Upstreams}) ->
    NewUps = lists:map(
        fun
            (U = #{addr := A}) when A =:= Addr ->
                U#{healthy => true,
                   transient_down_until_ms => 0,
                   transient_fail_streak => 0};
            (U) -> U
        end,
        Upstreams
    ),
    LbState#{upstreams => NewUps}.

transient_backoff_ms(Streak) when is_integer(Streak), Streak > 0 ->
    Base = transient_down_ms(),
    %% Exponential backoff: 1x,2x,4x,8x,... capped to protect against
    %% persistent flapping upstreams that repeatedly fail right after recovery.
    Pow = 1 bsl min(6, Streak - 1),
    min(?TRANSIENT_DOWN_MAX_MS, Base * Pow);
transient_backoff_ms(_) ->
    transient_down_ms().

maybe_recover_transient_down(LbState = #{upstreams := Upstreams}) ->
    Now = erlang:monotonic_time(millisecond),
    NewUps = lists:map(
        fun(U) ->
            case maps:get(transient_down_until_ms, U, 0) of
                Until when is_integer(Until), Until > 0, Until =< Now ->
                    U#{healthy => true, transient_down_until_ms => 0};
                _ ->
                    U
            end
        end,
        Upstreams
    ),
    LbState#{upstreams => NewUps}.

do_health_check(Addr, Path) ->
    %% Parse host:port
    {Host, Port} = parse_addr(Addr),
    Opts = #{transport => tcp, protocols => [http]},
    Timeout = 5000,
    case gun:open(Host, Port, Opts) of
        {ok, ConnPid} ->
            case gun:await_up(ConnPid, Timeout) of
                {ok, _Protocol} ->
                    StreamRef = gun:get(ConnPid, Path, [{<<"connection">>, <<"close">>}]),
                    Result = case gun:await(ConnPid, StreamRef, Timeout) of
                        {response, fin, Status, _Headers} when Status < 500 -> true;
                        {response, nofin, Status, _Headers} when Status < 500 ->
                            gun:cancel(ConnPid, StreamRef),
                            true;
                        _ -> false
                    end,
                    gun:close(ConnPid),
                    Result;
                {error, _} ->
                    gun:close(ConnPid),
                    false
            end;
        {error, _} ->
            false
    end.

parse_addr(Addr) when is_binary(Addr) ->
    parse_addr(binary_to_list(Addr));
parse_addr(Addr) ->
    Addr1 = string:trim(Addr),
    Addr2 = string:trim(Addr1, trailing, "/"),
    case string:find(Addr2, "://") of
        nomatch ->
            split_host_port(Addr2, 80);
        _ ->
            parse_addr_uri(Addr2)
    end.

parse_addr_uri(Addr) ->
    try uri_string:parse(Addr) of
        #{scheme := Scheme0} = Uri ->
            Scheme = string:lowercase(uri_text_to_list(Scheme0)),
            DefaultPort = scheme_default_port(Scheme),
            Host = uri_text_to_list(maps:get(host, Uri, <<"localhost">>)),
            Port = maps:get(port, Uri, DefaultPort),
            {Host, Port};
        _ ->
            split_host_port(Addr, 80)
    catch
        _:_ ->
            split_host_port(Addr, 80)
    end.

scheme_default_port("https") -> 443;
scheme_default_port("wss") -> 443;
scheme_default_port("grpcs") -> 443;
scheme_default_port(_) -> 80.

uri_text_to_list(V) when is_binary(V) -> binary_to_list(V);
uri_text_to_list(V) when is_list(V) -> V;
uri_text_to_list(V) -> lists:flatten(io_lib:format("~p", [V])).

split_host_port(Addr, DefaultPort) ->
    case string:split(Addr, ":", trailing) of
        [Host, PortStr] ->
            case safe_port(PortStr) of
                {ok, Port} -> {Host, Port};
                error -> {Addr, DefaultPort}
            end;
        [Host] ->
            {Host, DefaultPort}
    end.

safe_port(PortStr0) ->
    PortStr = string:trim(PortStr0, trailing, "/"),
    try
        {ok, list_to_integer(PortStr)}
    catch
        _:_ ->
            error
    end.

conn_for_addr(#{upstreams := Upstreams}, Addr) ->
    conn_for_addr_scan(Upstreams, Addr).

conn_for_addr_scan([], _Addr) -> 0;
conn_for_addr_scan([U | Rest], Addr) ->
    case U of
        #{addr := A, conns := C} when A =:= Addr -> C;
        #{addr := A} when A =:= Addr -> maps:get(conns, U, 0);
        _ -> conn_for_addr_scan(Rest, Addr)
    end.

increment_conns(Addr, LbState = #{upstreams := Upstreams}) ->
    NewUps = lists:map(fun
        (U = #{addr := A}) when A =:= Addr -> U#{conns => maps:get(conns, U, 0) + 1};
        (U) -> U
    end, Upstreams),
    LbState#{upstreams => NewUps}.

decrement_conns(Addr, LbState = #{upstreams := Upstreams}) ->
    NewUps = lists:map(fun
        (U = #{addr := A}) when A =:= Addr ->
            C = max(0, maps:get(conns, U, 0) - 1),
            U#{conns => C};
        (U) -> U
    end, Upstreams),
    LbState#{upstreams => NewUps}.

merge_update(OldState = #{lb := #{upstreams := OldUps}},
             NewBackend = #{upstreams := NewUpsList}) ->
    %% Preserve health/conn state for upstreams that still exist.
    OldMap = maps:from_list([{maps:get(addr, U), U} || U <- OldUps]),
    NewUps = [case maps:find(maps:get(addr, U), OldMap) of
                                    {ok, Old} -> U#{healthy => maps:get(healthy, Old, true),
                                                                        conns   => maps:get(conns,   Old, 0),
                                                                        transient_down_until_ms => maps:get(transient_down_until_ms, Old, 0),
                                                                        transient_fail_streak => maps:get(transient_fail_streak, Old, 0)};
                                    error     -> U#{healthy => true,
                                                                     conns => 0,
                                                                     transient_down_until_ms => 0,
                                                                     transient_fail_streak => 0}
              end
              || U <- [#{addr    => maps:get(addr, U),
                         weight  => maps:get(weight, U, 1),
                                                 healthy => true,
                                                 conns => 0,
                                                 transient_down_until_ms => 0,
                                                 transient_fail_streak => 0}
                       || U <- NewUpsList]],
    NewAlgo = maps:get(algorithm, NewBackend, maps:get(algorithm, OldState)),
    OldState#{
        algorithm   => NewAlgo,
        health_path => maps:get(health_path, NewBackend, undefined),
        health_secs => maps:get(health_interval_secs, NewBackend, ?HEALTH_DEFAULT_SECS),
        lb          => #{
            algorithm => NewAlgo,
            upstreams => NewUps,
            rr_index  => maps:get(rr_index, maps:get(lb, OldState), 0)
        }
    }.

track_connections(least_connections) ->
    true;
track_connections(_) ->
    false.
