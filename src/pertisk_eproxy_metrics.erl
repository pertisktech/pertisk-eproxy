%% @doc Metrics collection for pertisk_eproxy using prometheus.erl.
%%
%% Exposes:
%%   pertisk_eproxy_requests_total{host, status}   — counter
%%   pertisk_eproxy_request_duration_ms{host}      — histogram
%%   pertisk_eproxy_upstream_connections{backend}  — gauge
%%   pertisk_eproxy_upstream_healthy{backend}      — gauge
%%
%% Metrics are available at GET /api/metrics (Prometheus text format).

-module(pertisk_eproxy_metrics).
-behaviour(gen_server).

-export([setup/0, start_link/0]).
-export([inc_request/2, observe_duration/2,
         set_upstream_conns/2, set_upstream_healthy/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

%% ---------------------------------------------------------------------------
%% Setup (called once before supervisor starts, so metrics are declared early)
%% ---------------------------------------------------------------------------

setup() ->
    prometheus_counter:declare([
        {name,   pertisk_eproxy_requests_total},
        {help,   "Total proxy requests"},
        {labels, [host, status]}
    ]),
    prometheus_histogram:declare([
        {name,    pertisk_eproxy_request_duration_ms},
        {help,    "Proxy request duration in milliseconds"},
        {labels,  [host]},
        {buckets, [5, 25, 100, 250, 500, 1000, 5000, 30000]}
    ]),
    prometheus_gauge:declare([
        {name,   pertisk_eproxy_upstream_connections},
        {help,   "Active upstream connections"},
        {labels, [backend, upstream]}
    ]),
    prometheus_gauge:declare([
        {name,   pertisk_eproxy_upstream_healthy},
        {help,   "Whether an upstream is healthy (1=healthy, 0=unhealthy)"},
        {labels, [backend, upstream]}
    ]),
    ok.

%% ---------------------------------------------------------------------------
%% Public API
%% ---------------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec inc_request(binary(), binary()) -> ok.
inc_request(Host, StatusCode) ->
    prometheus_counter:inc(pertisk_eproxy_requests_total, [Host, StatusCode]).

-spec observe_duration(binary(), non_neg_integer()) -> ok.
observe_duration(Host, DurationMs) ->
    prometheus_histogram:observe(pertisk_eproxy_request_duration_ms, [Host], DurationMs).

-spec set_upstream_conns(binary(), [{binary(), non_neg_integer()}]) -> ok.
set_upstream_conns(Backend, UpstreamConns) ->
    lists:foreach(fun({Addr, Count}) ->
        prometheus_gauge:set(pertisk_eproxy_upstream_connections, [Backend, Addr], Count)
    end, UpstreamConns).

-spec set_upstream_healthy(binary(), [{binary(), boolean()}]) -> ok.
set_upstream_healthy(Backend, UpstreamHealth) ->
    lists:foreach(fun({Addr, Healthy}) ->
        Value = case Healthy of true -> 1; false -> 0 end,
        prometheus_gauge:set(pertisk_eproxy_upstream_healthy, [Backend, Addr], Value)
    end, UpstreamHealth).

%% ---------------------------------------------------------------------------
%% gen_server callbacks
%% ---------------------------------------------------------------------------

init([]) ->
    %% Periodically update upstream metrics from backend statuses.
    erlang:send_after(10000, self(), update_upstream_metrics),
    {ok, #{}}.

handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(update_upstream_metrics, State) ->
    update_upstream_metrics(),
    erlang:send_after(10000, self(), update_upstream_metrics),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% ---------------------------------------------------------------------------
%% Internal
%% ---------------------------------------------------------------------------

update_upstream_metrics() ->
    Backends = pertisk_eproxy_config:get_backends(),
    lists:foreach(fun(#{name := Name}) ->
        try
            case pertisk_eproxy_backend:status(Name) of
                {ok, #{upstreams := Ups}} ->
                    Conns   = [{maps:get(addr, U), maps:get(conns,   U, 0)} || U <- Ups],
                    Healthy = [{maps:get(addr, U), maps:get(healthy, U, true)} || U <- Ups],
                    set_upstream_conns(Name, Conns),
                    set_upstream_healthy(Name, Healthy);
                _ -> ok
            end
        catch
            exit:{timeout, {gen_server, call, _}} ->
                %% Backend busy (e.g. slow health checks); skip this scrape — no need to spam logs.
                ok;
            Class:Reason ->
                lager:warning("Error updating metrics for backend ~s: ~w:~p", [Name, Class, Reason])
        end
    end, Backends).
