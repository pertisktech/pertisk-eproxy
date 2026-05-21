%% @doc Kubernetes Lease-based leader election (coordination.k8s.io/v1).
-module(pertisk_ingress_leader).
-behaviour(gen_server).

-export([start_link/0, is_leader/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(DEFAULT_LEASE_DURATION, 15).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

is_leader() ->
    case erlang:whereis(?SERVER) of
        undefined -> true;
        _ -> gen_server:call(?SERVER, is_leader, 5000)
    end.

init([]) ->
    case pertisk_ingress_env:leader_election_enabled() of
        false ->
            pertisk_ingress_status:set_leader(true),
            {ok, #{enabled => false, leader => true}};
        true ->
            case pertisk_ingress_ekub:init() of
                {ok, Conn} ->
                    Ns = pertisk_ingress_env:leader_namespace(),
                    Name = pertisk_ingress_env:leader_lease_name(),
                    Holder = pertisk_ingress_env:holder_id(),
                    Dur = pertisk_ingress_env:lease_duration_seconds(),
                    RenewMs = pertisk_ingress_env:renew_interval_seconds() * 1000,
                    lager:info(
                        "Leader election: lease ~s/~s holder ~s",
                        [Ns, Name, Holder]
                    ),
                    erlang:send_after(RenewMs, self(), renew),
                    {ok, #{
                        enabled => true,
                        conn => Conn,
                        namespace => Ns,
                        lease_name => Name,
                        holder_id => Holder,
                        lease_duration => Dur,
                        renew_ms => RenewMs,
                        leader => false
                    }};
                {error, Reason} ->
                    lager:warning("Leader election disabled: ekub init failed: ~p", [Reason]),
                    pertisk_ingress_status:set_leader(true),
                    {ok, #{enabled => false, leader => true, error => Reason}}
            end
    end.

handle_call(is_leader, _From, #{leader := L} = State) ->
    {reply, L, State};

handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(renew, #{enabled := false, leader := L} = State) ->
    pertisk_ingress_status:set_leader(L),
    {noreply, State};

handle_info(renew, State = #{renew_ms := RenewMs}) ->
    NewState = do_renew(State),
    erlang:send_after(RenewMs, self(), renew),
    {noreply, NewState};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

do_renew(#{conn := Conn, namespace := Ns, lease_name := Name,
           holder_id := Holder, lease_duration := Dur} = State) ->
    Leader = case try_acquire_or_renew(Conn, Ns, Name, Holder, Dur) of
        true -> true;
        false -> false;
        {error, Err} ->
            lager:warning("Leader election error: ~p", [Err]),
            maps:get(leader, State, false)
    end,
    pertisk_ingress_status:set_leader(Leader),
    State#{leader => Leader}.

try_acquire_or_renew(Conn, Ns, Name, Holder, Dur) ->
    case ekub:read(lease, Ns, Name, Conn) of
        {ok, Lease} when is_map(Lease) ->
            renew_existing(Conn, Ns, Name, Holder, Dur, Lease);
        {error, #{<<"code">> := 404}} ->
            create_lease(Conn, Ns, Name, Holder, Dur);
        {error, #{<<"reason">> := <<"NotFound">>}} ->
            create_lease(Conn, Ns, Name, Holder, Dur);
        {error, _} ->
            %% List path when get by name unsupported
            case ekub:read(lease, [{field_selector, field_selector(Name)}], Conn) of
                {ok, #{<<"items">> := [Lease | _]}} ->
                    renew_existing(Conn, Ns, Name, Holder, Dur, Lease);
                {ok, #{<<"items">> := []}} ->
                    create_lease(Conn, Ns, Name, Holder, Dur);
                {ok, Lease} when is_map(Lease), not is_map_key(<<"items">>, Lease) ->
                    renew_existing(Conn, Ns, Name, Holder, Dur, Lease);
                _ ->
                    create_lease(Conn, Ns, Name, Holder, Dur)
            end
    end.

field_selector(Name) ->
    "metadata.name=" ++ binary_to_list(Name).

create_lease(Conn, Ns, Name, Holder, Dur) ->
    Now = iso8601_now(),
    Lease = #{
        <<"apiVersion">> => <<"coordination.k8s.io/v1">>,
        <<"kind">> => <<"Lease">>,
        <<"metadata">> => #{
            <<"name">> => Name,
            <<"namespace">> => Ns
        },
        <<"spec">> => #{
            <<"holderIdentity">> => Holder,
            <<"leaseDurationSeconds">> => Dur,
            <<"acquireTime">> => Now,
            <<"renewTime">> => Now
        }
    },
    case ekub:create(Lease, Ns, Conn) of
        {ok, _} -> true;
        {error, #{<<"code">> := 409}} -> false;
        {error, _} -> false
    end.

renew_existing(Conn, Ns, _Name, Holder, Dur, Lease) ->
    Spec0 = maps:get(<<"spec">>, Lease, #{}),
    CurHolder = maps:get(<<"holderIdentity">>, Spec0, undefined),
    RenewTime = maps:get(<<"renewTime">>, Spec0, undefined),
    Expired = lease_expired(RenewTime, maps:get(<<"leaseDurationSeconds">>, Spec0, ?DEFAULT_LEASE_DURATION)),
    IsOwner = (CurHolder =:= Holder),
    case {Expired, IsOwner} of
        {false, false} ->
            false;
        _ ->
            Now = iso8601_now(),
            Spec1 = Spec0#{
                <<"holderIdentity">> => Holder,
                <<"leaseDurationSeconds">> => Dur,
                <<"renewTime">> => Now,
                <<"acquireTime">> => case IsOwner of
                    true -> maps:get(<<"acquireTime">>, Spec0, Now);
                    false -> Now
                end
            },
            Updated = Lease#{<<"spec">> => Spec1},
            case ekub:replace(Updated, Ns, Conn) of
                {ok, _} -> true;
                {error, #{<<"code">> := 409}} -> false;
                {error, _} -> false
            end
    end.

lease_expired(undefined, _Dur) ->
    true;
lease_expired(RenewBin, Dur) when is_binary(RenewBin) ->
    %% Conservative: treat parse failure as expired.
    case parse_rfc3339(RenewBin) of
        {ok, RenewSec} ->
            NowSec = erlang:system_time(second),
            NowSec >= RenewSec + Dur;
        _ ->
            true
    end;
lease_expired(_, _) ->
    true.

parse_rfc3339(Bin) ->
    try
        {ok, calendar:rfc3339_to_system_time(binary_to_list(Bin), [{unit, second}])}
    catch
        _:_ -> error
    end.

iso8601_now() ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:universal_time(),
    list_to_binary(
        io_lib:format("~4..0w-~2..0w-~2..0wT~2..0w:~2..0w:~2..0wZ", [Y, Mo, D, H, Mi, S])
    ).
