%% @doc Per-backend gen_server for pertisk_eproxy.
%%
%% Each backend config entry (from proxy.json `backends` list) has one
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

-export([start_link/1]).
-export([whereis/1, pick_upstream/2, done_upstream/3, update/2, status/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(HEALTH_DEFAULT_SECS, 30).

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
-spec status(binary()) -> {ok, map()} | {error, not_found}.
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

handle_call({pick, ClientIp}, _From, State = #{lb := LbState, algorithm := Algo}) ->
    case pertisk_eproxy_lb:next(LbState, Algo, ClientIp) of
        {ok, #{addr := Addr}, NewLb} ->
            %% Increment active connection count
            NewLb2 = increment_conns(Addr, NewLb),
            {reply, {ok, Addr}, State#{lb => NewLb2}};
        {error, _} = Err ->
            {reply, Err, State}
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

handle_cast({done, Addr, _Result}, State = #{lb := LbState}) ->
    NewLb = decrement_conns(Addr, LbState),
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
                   conns   => 0}
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
    State;
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
        U#{healthy => Healthy}
    end, Upstreams),
    State#{lb => LbState#{upstreams => NewUpstreams}}.

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
    case string:split(Addr, ":", trailing) of
        [Host, PortStr] ->
            Port = list_to_integer(PortStr),
            {Host, Port};
        [Host] ->
            {Host, 80}
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
                                  conns   => maps:get(conns,   Old, 0)};
                  error     -> U#{healthy => true, conns => 0}
              end
              || U <- [#{addr    => maps:get(addr, U),
                         weight  => maps:get(weight, U, 1),
                         healthy => true, conns => 0}
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
