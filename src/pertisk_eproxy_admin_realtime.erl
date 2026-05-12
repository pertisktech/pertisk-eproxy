%% @doc In-memory ACME / SSL job status + WebSocket subscriber fan-out for the admin UI.
-module(pertisk_eproxy_admin_realtime).

-behaviour(gen_server).

-export([start_link/0]).
-export([subscribe/1, unsubscribe/1, ssl_job/1, clear_ssl_job/1, ssl_jobs_snapshot/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(TAB, pertisk_eproxy_ssl_jobs).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

subscribe(Pid) when is_pid(Pid) ->
    case whereis(?SERVER) of
        undefined -> ok;
        _ -> gen_server:cast(?SERVER, {subscribe, Pid})
    end.

unsubscribe(Pid) when is_pid(Pid) ->
    case whereis(?SERVER) of
        undefined -> ok;
        _ -> gen_server:cast(?SERVER, {unsubscribe, Pid})
    end.

-spec ssl_job(map()) -> ok.
ssl_job(#{host := Host} = M) ->
    case whereis(?SERVER) of
        undefined ->
            ok;
        _ ->
            Phase = bin(maps:get(phase, M, <<>>)),
            Msg = bin(maps:get(message, M, <<>>)),
            Err = maps:get(error, M, undefined),
            gen_server:cast(?SERVER, {ssl_job, Host, Phase, Msg, Err})
    end.

clear_ssl_job(Host) ->
    case whereis(?SERVER) of
        undefined ->
            ok;
        _ ->
            gen_server:cast(?SERVER, {clear_ssl_job, Host})
    end.

ssl_jobs_snapshot() ->
    case whereis(?SERVER) of
        undefined -> [];
        _ -> gen_server:call(?SERVER, list_ssl_jobs)
    end.

init([]) ->
    _ = ets:new(?TAB, [set, named_table, private]),
    {ok, #{subs => #{}}}.

handle_call(list_ssl_jobs, _From, St) ->
    Rows = ets:tab2list(?TAB),
    List = [row_json(R) || R <- Rows],
    {reply, List, St};
handle_call(_Req, _From, St) ->
    {reply, {error, unknown_call}, St}.

handle_cast({subscribe, Pid}, #{subs := Subs} = St) ->
    Next =
        case maps:is_key(Pid, Subs) of
            true ->
                Subs;
            false ->
                Ref = erlang:monitor(process, Pid),
                Subs#{Pid => Ref}
        end,
    {noreply, St#{subs => Next}};
handle_cast({unsubscribe, Pid}, St) ->
    {noreply, demonitor_sub(Pid, St)};
handle_cast({clear_ssl_job, Host0}, St) ->
    H = host_bin(Host0),
    true = ets:delete(?TAB, H),
    Ts = erlang:system_time(millisecond),
    Json = encode_push(H, <<"idle">>, <<>>, null, Ts),
    broadcast(St, Json),
    {noreply, St};
handle_cast({ssl_job, Host0, Phase, Msg, Err}, St) ->
    H = host_bin(Host0),
    Ts = erlang:system_time(millisecond),
    ErrJ = err_json(Err),
    Row = {H, Phase, Msg, ErrJ, Ts},
    true = ets:insert(?TAB, Row),
    Json = encode_push(H, Phase, Msg, ErrJ, Ts),
    broadcast(St, Json),
    {noreply, St};
handle_cast(_X, St) ->
    {noreply, St}.

handle_info({'DOWN', Ref, process, Pid, _Reason}, #{subs := Subs} = St) ->
    case maps:get(Pid, Subs, undefined) of
        Ref ->
            {noreply, St#{subs => maps:remove(Pid, Subs)}};
        _ ->
            {noreply, St}
    end;
handle_info(_I, St) ->
    {noreply, St}.

terminate(_Reason, #{subs := Subs}) ->
    maps:foreach(fun(_Pid, Ref) -> _ = erlang:demonitor(Ref, [flush]) end, Subs),
    ok.

code_change(_Old, St, _Extra) ->
    {ok, St}.

demonitor_sub(Pid, #{subs := Subs} = St) ->
    case maps:take(Pid, Subs) of
        {Ref, Subs2} ->
            true = erlang:demonitor(Ref, [flush]),
            St#{subs => Subs2};
        error ->
            St
    end.

broadcast(#{subs := Subs}, JsonBin) ->
    maps:foreach(fun(Pid, _Ref) -> Pid ! {admin_ws_push, JsonBin} end, Subs).

encode_push(Host, Phase, Msg, Err, Ts) ->
    thoas:encode(#{
        <<"type">> => <<"ssl_job">>,
        <<"host">> => Host,
        <<"phase">> => Phase,
        <<"message">> => Msg,
        <<"error">> => Err,
        <<"updated_at_ms">> => Ts
    }).

row_json({H, Phase, Msg, Err, Ts}) ->
    #{
        <<"host">> => H,
        <<"phase">> => Phase,
        <<"message">> => Msg,
        <<"error">> => Err,
        <<"updated_at_ms">> => Ts
    }.

host_bin(H) when is_binary(H) -> H;
host_bin(H) when is_list(H) -> unicode:characters_to_binary(H, utf8);
host_bin(H) -> iolist_to_binary(io_lib:format("~p", [H])).

bin(V) when is_binary(V) -> V;
bin(V) when is_list(V) -> unicode:characters_to_binary(V, utf8);
bin(V) -> iolist_to_binary(io_lib:format("~p", [V])).

err_json(undefined) -> null;
err_json(null) -> null;
err_json(E) when is_binary(E) -> E;
err_json(E) when is_list(E) -> unicode:characters_to_binary(E, utf8);
err_json(E) -> iolist_to_binary(io_lib:format("~p", [E])).
