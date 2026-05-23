%% @doc Shared upstream Gun connection pool for proxy request paths.
%%
%% Maintains a small reusable pool per upstream target + request profile
%% (e.g. HTTP/1.1 vs gRPC/HTTP2) to avoid per-request connect/handshake cost.

-module(pertisk_eproxy_upstream_pool).
-behaviour(gen_server).

-export([start_link/0, checkout/5, invalidate/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(DEFAULT_POOL_SIZE, 16).

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
                    Entry2 = Entry1#{conns => [ConnPid], rr => 1},
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
                                conns => [ConnPid | Conns],
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

handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    {noreply, remove_pid_from_pools(Pid, State)};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #{pools := Pools}) ->
    lists:foreach(
        fun(#{conns := Conns}) ->
            lists:foreach(fun(Pid) -> catch gun:close(Pid) end, Conns)
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

refresh_entry(Entry = #{conns := Conns}) ->
    Alive = [Pid || Pid <- Conns, is_process_alive(Pid)],
    Entry#{conns => Alive};
refresh_entry(Entry) ->
    Entry.

pick_rr(Conns, Entry = #{rr := Rr0}) ->
    N = length(Conns),
    Idx = Rr0 rem N,
    ConnPid = lists:nth(Idx + 1, Conns),
    {ConnPid, Entry#{rr => Rr0 + 1}}.

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
            Conns1 = [C || C <- maps:get(conns, Entry1, []), C =/= Pid],
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
