%% @doc Load balancing algorithms for pertisk_eproxy.
%%
%% Supported algorithms (matching the reference Rust project):
%%   - round_robin       : distribute requests evenly in order
%%   - least_connections : prefer upstream with fewest active connections
%%   - ip_hash           : consistent hashing by client IP (sticky sessions)
%%
%% This module is a pure library — state (counters, connection counts) is
%% owned by pertisk_eproxy_backend gen_servers.

-module(pertisk_eproxy_lb).

-export([next/3, ip_hash_index/2]).

-export_type([algorithm/0, upstream/0, lb_state/0]).

-type algorithm() :: round_robin | least_connections | ip_hash.

-type upstream() :: #{
    addr    := binary(),
    weight  := pos_integer(),
    healthy := boolean(),
    conns   := non_neg_integer()   %% active connection count (for least_connections)
}.

-type lb_state() :: #{
    algorithm := algorithm(),
    upstreams := [upstream()],
    rr_index  := non_neg_integer()   %% current round-robin cursor
}.

%% ---------------------------------------------------------------------------
%% API
%% ---------------------------------------------------------------------------

%% Select the next upstream given the current LB state and optional client IP.
%% Returns {ok, upstream(), NewState} | {error, no_healthy_upstream}.
-spec next(lb_state(), algorithm(), binary() | undefined) ->
    {ok, upstream(), lb_state()} | {error, no_healthy_upstream}.
next(State = #{upstreams := Upstreams, algorithm := Algo, rr_index := Idx},
     _AlgoOverride, ClientIp) ->
    Healthy = [U || U = #{healthy := true} <- Upstreams],
    case Healthy of
        [] -> {error, no_healthy_upstream};
        _  ->
            {Selected, NewState} = pick(Algo, Healthy, Upstreams, Idx, ClientIp),
            {ok, Selected, NewState#{upstreams => Upstreams}}
    end.

%% ---------------------------------------------------------------------------
%% Internal
%% ---------------------------------------------------------------------------

pick(round_robin, Healthy, _All, Idx, _Ip) ->
    N      = length(Healthy),
    Cursor = Idx rem N,
    Selected = lists:nth(Cursor + 1, Healthy),
    {Selected, #{rr_index => Cursor + 1}};

pick(least_connections, Healthy, _All, Idx, _Ip) ->
    Selected = lists:foldl(fun
        (U, undefined) -> U;
        (U = #{conns := C}, Best = #{conns := BC}) when C < BC -> U;
        (_, Best) -> Best
    end, undefined, Healthy),
    {Selected, #{rr_index => Idx}};

pick(ip_hash, Healthy, _All, Idx, ClientIp) ->
    N = length(Healthy),
    HashIdx = ip_hash_index(ClientIp, N),
    Selected = lists:nth(HashIdx + 1, Healthy),
    {Selected, #{rr_index => Idx}}.

%% Compute a stable index [0, N) for the given IP.
-spec ip_hash_index(binary() | undefined, pos_integer()) -> non_neg_integer().
ip_hash_index(undefined, N) ->
    erlang:phash2(make_ref(), N);
ip_hash_index(Ip, N) ->
    erlang:phash2(Ip, N).
