%% @doc Metrics collection for pertisk_eproxy using prometheus.erl.
%%
%% Exposes:
%%   pertisk_eproxy_requests_total{host, status, proto} — counter
%%     proto: http1 | tls_h1 | h2 | h3 | grpc
%%   pertisk_eproxy_site_requests_total{site, status, proto} — counter
%%   pertisk_eproxy_bytes_received_total{host} — client → proxy request body bytes
%%   pertisk_eproxy_bytes_sent_total{host}     — proxy → client response body bytes
%%   pertisk_eproxy_site_bytes_received_total{site} — client → proxy request body bytes
%%   pertisk_eproxy_site_bytes_sent_total{site}     — proxy → client response body bytes
%%   pertisk_eproxy_request_duration_ms{host}      — histogram
%%   pertisk_eproxy_upstream_connections{backend}  — gauge
%%   pertisk_eproxy_upstream_healthy{backend}      — gauge
%%
%% Metrics are available at GET /api/metrics (Prometheus text format).

-module(pertisk_eproxy_metrics).
-behaviour(gen_server).

-export([setup/0, start_link/0]).
-export([inc_request/3, inc_site_request/3,
         observe_duration/2, observe_duration/3,
         record_proxy_bytes/3, record_site_bytes/3,
         set_upstream_conn/3,
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
        {labels, [host, status, proto]}
    ]),
    prometheus_counter:declare([
        {name,   pertisk_eproxy_site_requests_total},
        {help,   "Total proxy requests grouped by site"},
        {labels, [site, status, proto]}
    ]),
    prometheus_counter:declare([
        {name,   pertisk_eproxy_bytes_received_total},
        {help,   "Bytes read from clients (proxy request bodies)"},
        {labels, [host]}
    ]),
    prometheus_counter:declare([
        {name,   pertisk_eproxy_bytes_sent_total},
        {help,   "Bytes written to clients (proxy response bodies)"},
        {labels, [host]}
    ]),
    prometheus_counter:declare([
        {name,   pertisk_eproxy_site_bytes_received_total},
        {help,   "Bytes read from clients grouped by site"},
        {labels, [site]}
    ]),
    prometheus_counter:declare([
        {name,   pertisk_eproxy_site_bytes_sent_total},
        {help,   "Bytes written to clients grouped by site"},
        {labels, [site]}
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

-spec inc_request(binary(), binary(), binary()) -> ok.
inc_request(Host, StatusCode, Proto) when is_binary(Proto) ->
    prometheus_counter:inc(pertisk_eproxy_requests_total, [Host, StatusCode, Proto]).

-spec inc_site_request(binary(), binary(), binary()) -> ok.
inc_site_request(Site, StatusCode, Proto) when is_binary(Proto) ->
    prometheus_counter:inc(pertisk_eproxy_site_requests_total, [Site, StatusCode, Proto]).

%% @doc Add proxied byte volumes for admin `/api/stats` throughput (per virtual host).
-spec record_proxy_bytes(binary(), non_neg_integer(), non_neg_integer()) -> ok.
record_proxy_bytes(Host, Recv, Sent) when is_binary(Host), is_integer(Recv), Recv >= 0, is_integer(Sent), Sent >= 0 ->
    case Recv of
        0 -> ok;
        _ -> prometheus_counter:inc(pertisk_eproxy_bytes_received_total, [Host], Recv)
    end,
    case Sent of
        0 -> ok;
        _ -> prometheus_counter:inc(pertisk_eproxy_bytes_sent_total, [Host], Sent)
    end,
    ok.

-spec record_site_bytes(binary(), non_neg_integer(), non_neg_integer()) -> ok.
record_site_bytes(Site, Recv, Sent)
when is_binary(Site), is_integer(Recv), Recv >= 0, is_integer(Sent), Sent >= 0 ->
    case Recv of
        0 -> ok;
        _ -> prometheus_counter:inc(pertisk_eproxy_site_bytes_received_total, [Site], Recv)
    end,
    case Sent of
        0 -> ok;
        _ -> prometheus_counter:inc(pertisk_eproxy_site_bytes_sent_total, [Site], Sent)
    end,
    ok.

observe_duration(Host, DurationMs) ->
    prometheus_histogram:observe(pertisk_eproxy_request_duration_ms, [Host], DurationMs).

observe_duration(Host, _Site, DurationMs) ->
    observe_duration(Host, DurationMs).

%% @doc Push one upstream's in-flight count immediately (pick/done path). Periodic
%% {@link set_upstream_conns/2} from the metrics gen_server still reconciles drift.
-spec set_upstream_conn(binary(), binary(), non_neg_integer()) -> ok.
set_upstream_conn(Backend, Addr, Count) when is_binary(Backend), is_binary(Addr),
                                               is_integer(Count), Count >= 0 ->
    prometheus_gauge:set(pertisk_eproxy_upstream_connections, [Backend, Addr], Count),
    ok.

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
