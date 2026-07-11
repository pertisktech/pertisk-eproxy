-module(pertisk_eproxy_bench).
-moduledoc """
Latency/throughput benchmark harness for pertisk-eproxy.

Drives keep-alive load through the reverse proxy to a local reference
upstream (`bench_upstream_h`), over HTTP/1.1, HTTP/2 (TLS), or HTTP/3,
and reports request count, throughput, and p50/p90/p99/max latency.
`compare/2` implements a >10% p99 regression gate.

Run interactively (not via `halt/0`, so listeners tear down cleanly):

```
rebar3 as bench shell
1> pertisk_eproxy_bench:run().                          %% H1, defaults
2> pertisk_eproxy_bench:run(#{protocol => h3}).
3> pertisk_eproxy_bench:run_all(#{connections => 100, duration_ms => 5000}).
```

`run/0,1` returns a metrics map; `run_all/0,1` returns `[{Protocol, Metrics}]`.
Persist a metrics map as a baseline and pass it to `compare/2` to gate future runs.
""".

-export([run/0, run/1, run_all/0, run_all/1, compare/2, report/1]).
-export([serve/2, sweep/3]).

-define(BENCH_HOST, <<"bench.local">>).
-define(ECHO_BODY, <<"{\"name\":\"ada\",\"tags\":[\"one\",\"two\"],\"n\":42,\"ok\":true}">>).

%% @doc Run H1 with defaults: 50 connections for 3 seconds.
run() ->
    run(#{}).

%% @doc Run the benchmark for one protocol.
%%
%% Options: `protocol` (`h1` | `h2` | `h3`, default `h1`), `workload`
%% (`tiny` | `bytes1k` | `bytes10k` | `bytes100k` | `echo`, default `tiny`),
%% `connections`, `duration_ms`, `warmup_ms`, `port` (0 = ephemeral).
run(Opts) ->
    Protocol = maps:get(protocol, Opts, h1),
    H3Impl = maps:get(h3_impl, Opts, gateway),
    Workload = maps:get(workload, Opts, tiny),
    Conns = maps:get(connections, Opts, 50),
    Duration = maps:get(duration_ms, Opts, 3000),
    Warmup = maps:get(warmup_ms, Opts, 500),
    Port = maps:get(port, Opts, 0),
    {ok, Stack} = start_stack(Protocol, Port, H3Impl),
    try
        ProxyPort = maps:get(proxy_port, Stack),
        _ = drive(Protocol, ProxyPort, Conns, Warmup, Workload),
        {Lats, Count, Reconns} = drive(Protocol, ProxyPort, Conns, Duration, Workload),
        Metrics0 = metrics(Protocol, Workload, Lats, Count, Reconns, Duration, Conns),
        Metrics = Metrics0#{stack => Stack},
        report(Metrics),
        maps:remove(stack, Metrics)
    after
        stop_stack(Stack)
    end.

%% @doc Concurrency sweep: run `Protocol' at each connection count and return
%% `[{Conns, ThroughputRps, P50Us, P99Us}]'.
sweep(Protocol, ConnsList, DurationMs) ->
    [
        begin
            M = run(#{
                protocol => Protocol,
                connections => C,
                duration_ms => DurationMs,
                warmup_ms => 300
            }),
            {C, round(maps:get(throughput_rps, M)), maps:get(p50_us, M), maps:get(p99_us, M)}
        end
        || C <- ConnsList
    ].

%% @doc Run the benchmark across H1, H2, and H3.
run_all() ->
    run_all(#{}).

run_all(Opts) ->
    [{P, run(Opts#{protocol => P})} || P <- [h1, h2, h3]].

%% @doc Compare a current run against a baseline. Fails when p99 regresses by more than 10%.
compare(Baseline, Current) ->
    B = maps:get(p99_us, Baseline),
    C = maps:get(p99_us, Current),
    Threshold = B * 1.10,
    case C =< Threshold of
        true ->
            {ok, #{baseline_p99_us => B, current_p99_us => C}};
        false ->
            {regressed, #{
                baseline_p99_us => B,
                current_p99_us => C,
                threshold_us => round(Threshold)
            }}
    end.

%% @doc Print a metrics map.
report(M) ->
    io:format(
        "~n=== pertisk_eproxy_bench (~p / ~p) ===~n"
        "connections : ~p~n"
        "duration    : ~p ms~n"
        "requests    : ~p (~p reconnects)~n"
        "throughput  : ~.1f req/s~n"
        "latency p50 : ~.3f ms~n"
        "latency p90 : ~.3f ms~n"
        "latency p99 : ~.3f ms~n"
        "latency max : ~.3f ms~n~n",
        [
            maps:get(protocol, M),
            maps:get(workload, M, tiny),
            maps:get(connections, M),
            maps:get(duration_ms, M),
            maps:get(requests, M),
            maps:get(reconnects, M),
            maps:get(throughput_rps, M),
            maps:get(p50_us, M) / 1000,
            maps:get(p90_us, M) / 1000,
            maps:get(p99_us, M) / 1000,
            maps:get(max_us, M) / 1000
        ]
    ).

%% @doc Start proxy + upstream on a fixed port and block forever for external load tools.
%% Launch under its own BEAM and kill that process to stop. Used by `bench/compare.sh`.
%% Signals readiness via stderr and, when `PERTISK_BENCH_READY_FILE' is set, that path.
serve(Protocol, Port) ->
    case start_stack(Protocol, Port, gateway) of
        {ok, Stack} ->
            ProxyPort = maps:get(proxy_port, Stack),
            notify_ready(Protocol, ProxyPort),
            receive
                stop -> ok
            after
                infinity -> ok
            end;
        {error, Reason} ->
            notify_failed(Protocol, Port, Reason),
            halt(1)
    end.

notify_ready(Protocol, ProxyPort) ->
    case os:getenv("PERTISK_BENCH_READY_FILE") of
        false ->
            io:format("READY eproxy ~p ~p~n", [Protocol, ProxyPort]);
        Path when is_list(Path) ->
            ok = file:write_file(Path, io_lib:format("READY eproxy ~p ~p~n", [Protocol, ProxyPort]))
    end.

notify_failed(Protocol, Port, Reason) ->
    case os:getenv("PERTISK_BENCH_READY_FILE") of
        false ->
            io:format(standard_error, "SERVE_FAILED ~p ~p: ~p~n", [Protocol, Port, Reason]);
        Path when is_list(Path) ->
            ok = file:write_file(Path, io_lib:format("SERVE_FAILED ~p ~p: ~p~n", [Protocol, Port, Reason]))
    end.

%%====================================================================
%% Stack lifecycle
%%====================================================================

start_stack(Protocol, Port, H3Impl) ->
    ok = ensure_bench_env(),
    {UpstreamPort, ProxyPort0} = bench_ports(Port),
    case start_upstream(UpstreamPort) of
        {ok, UpRef} ->
            start_stack_with_upstream(Protocol, ProxyPort0, UpRef, H3Impl);
        {error, Reason} ->
            {error, Reason}
    end.

start_stack_with_upstream(Protocol, ProxyPort0, UpRef, H3Impl) ->
    UpPort = ranch:get_port(UpRef),
    ok = setup_bench_routing(UpPort),
    {CertFile, KeyFile} = ensure_bench_certs(),
    case start_proxy_listener(Protocol, ProxyPort0, CertFile, KeyFile, H3Impl) of
        {ok, ProxyPort, ProxyRef} ->
            {ok, #{
                protocol => Protocol,
                h3_impl => H3Impl,
                upstream_ref => UpRef,
                upstream_port => UpPort,
                proxy_ref => ProxyRef,
                proxy_port => ProxyPort,
                cert_file => CertFile,
                key_file => KeyFile
            }};
        {error, Reason} ->
            stop_upstream(UpRef),
            {error, Reason}
    end.

stop_stack(#{upstream_ref := UpRef, proxy_ref := ProxyRef, protocol := Protocol}) ->
    stop_proxy_listener(Protocol, ProxyRef),
    stop_upstream(UpRef),
    ok.

ensure_bench_env() ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(prometheus),
    _ = application:ensure_all_started(lager),
    _ = application:ensure_all_started(cowboy),
    _ = application:ensure_all_started(gun),
    _ = application:ensure_all_started(ssl),
    _ = application:ensure_all_started(quic),
    ok = pertisk_eproxy_metrics:setup(),
    ensure_config_process(),
    patch_bench_config(#{
        proxy_access_log => false,
        health_access_log => false,
        metrics_enabled => false,
        upstream_pool_size => 256,
        upstream_pool_idle_timeout_secs => 90,
        %% Bench upstream is loopback; pool keep-alive matches real remote backends.
        upstream_loopback_pool_enabled => true,
        rate_limit_enabled => false,
        otel_enabled => false,
        h3_max_streams => 4096,
        h3_stream_receive_window => 16777216,
        h3_conn_receive_window => 134217728
    }),
    ensure_child(pertisk_eproxy_backend_sup),
    ensure_child(pertisk_eproxy_upstream_pool),
    ok.

ensure_child(Mod) ->
    case whereis(Mod) of
        undefined ->
            {ok, _} = Mod:start_link();
        _ ->
            ok
    end.

ensure_config_process() ->
    os:putenv("PERTISK_MODE", "proxy"),
    application:unset_env(pertisk_eproxy, mode),
    DbPath = bench_db_path(),
    application:set_env(pertisk_eproxy, db_file, DbPath),
    case whereis(pertisk_eproxy_config) of
        undefined ->
            _ = file:delete(DbPath),
            {ok, _} = pertisk_eproxy_db:init(DbPath),
            {ok, _} = pertisk_eproxy_config:start_link();
        _ ->
            ok
    end.

bench_db_path() ->
    filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "pertisk_bench_db_"
            ++ integer_to_list(erlang:unique_integer([positive, monotonic]))
            ++ ".db"
    ]).

patch_bench_config(Updates) ->
    C = pertisk_eproxy_config:get_config(),
    pertisk_eproxy_config:put_config(maps:merge(C, Updates)).

setup_bench_routing(UpstreamPort) ->
    Addr = iolist_to_binary(["127.0.0.1:", integer_to_list(UpstreamPort)]),
    Backend = #{
        name => <<"bench">>,
        algorithm => round_robin,
        upstreams => [#{addr => Addr, weight => 1}]
    },
    Site = #{
        host => ?BENCH_HOST,
        backend => <<"bench">>,
        routes => [#{path => <<"/">>, path_type => prefix}]
    },
    pertisk_eproxy_config:sync_ingress([Site], [Backend]).

bench_ports(0) ->
    {0, 0};
bench_ports(P) when is_integer(P), P > 0 ->
    %% Upstream on an ephemeral port; only the proxy port is fixed (compare.sh).
    {0, P}.

bench_ref(Kind) ->
    list_to_atom(
        "pertisk_eproxy_bench_"
            ++ atom_to_list(Kind)
            ++ "_"
            ++ integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

-define(BENCH_TRANSPORT_OPTS(Port), #{
    num_acceptors => 32,
    max_connections => 8192,
    socket_opts => [{port, Port}]
}).

-define(BENCH_PROTO_OPTS, #{
    idle_timeout => 60000,
    request_timeout => 60000,
    dynamic_buffer => {1024, 131072}
}).

start_upstream(Port) ->
    Ref = bench_ref(upstream),
    Dispatch = cowboy_router:compile([{'_', [{"/[...]", bench_upstream_h, []}]}]),
    case cowboy:start_clear(
        Ref,
        ?BENCH_TRANSPORT_OPTS(Port),
        maps:merge(?BENCH_PROTO_OPTS, #{env => #{dispatch => Dispatch}})
    ) of
        {ok, _} -> {ok, Ref};
        {error, Reason} -> {error, Reason}
    end.

stop_upstream(Ref) ->
    catch cowboy:stop_listener(Ref),
    ok.

proxy_routes() ->
    [
        {"/[...]", pertisk_eproxy_handler, []}
    ].

start_proxy_listener(h1, Port, _Cert, _Key, _H3Impl) ->
    Dispatch = cowboy_router:compile([{'_', proxy_routes()}]),
    Ref = bench_ref(h1),
    case cowboy:start_clear(
        Ref,
        ?BENCH_TRANSPORT_OPTS(Port),
        maps:merge(?BENCH_PROTO_OPTS, #{
            env => #{dispatch => Dispatch},
            protocols => [http]
        })
    ) of
        {ok, _} -> {ok, ranch:get_port(Ref), Ref};
        {error, Reason} -> {error, Reason}
    end;
start_proxy_listener(h2, Port, CertFile, KeyFile, _H3Impl) ->
    Dispatch = cowboy_router:compile([{'_', proxy_routes()}]),
    Ref = bench_ref(h2),
    case cowboy:start_tls(
        Ref,
        (?BENCH_TRANSPORT_OPTS(Port))#{
            socket_opts => [{port, Port}, {certfile, CertFile}, {keyfile, KeyFile}]
        },
        maps:merge(?BENCH_PROTO_OPTS, #{
            env => #{dispatch => Dispatch},
            protocols => [http2]
        })
    ) of
        {ok, _} -> {ok, ranch:get_port(Ref), Ref};
        {error, Reason} -> {error, Reason}
    end;
start_proxy_listener(h3, Port, CertFile, KeyFile, gateway) ->
    ProxyPort =
        case Port of
            0 -> free_udp_port();
            P -> P
        end,
    GatewayConfig =
        (pertisk_eproxy_config:get_config())#{
            https_port => ProxyPort,
            quic_port => ProxyPort,
            tls_cert_file => CertFile,
            tls_key_file => KeyFile,
            h3_api_gateway_enabled => true,
            quic_enabled => false,
            h3_probe_enabled => false
        },
    _ = pertisk_eproxy_h3_api_gateway:stop(),
    case pertisk_eproxy_h3_api_gateway:start(GatewayConfig) of
        ok -> {ok, ProxyPort, h3_gateway};
        {ok, _} -> {ok, ProxyPort, h3_gateway};
        {error, Reason} -> {error, Reason}
    end;
start_proxy_listener(h3, Port, CertFile, KeyFile, cowboy_quic) ->
    ProxyPort =
        case Port of
            0 -> free_udp_port();
            P -> P
        end,
    Dispatch = cowboy_router:compile([{'_', proxy_routes()}]),
    Ref = bench_ref(h3_cowboy_quic),
    StartQuic = quic_start_quic_fun(),
    case erlang:function_exported(cowboy, StartQuic, 3) of
        false ->
            {error, cowboy_quic_not_available};
        true ->
            case catch erlang:apply(cowboy, StartQuic, [
                Ref,
                (?BENCH_TRANSPORT_OPTS(ProxyPort))#{
                    socket_opts => [
                        {port, ProxyPort},
                        {certfile, CertFile},
                        {keyfile, KeyFile}
                    ]
                },
                maps:merge(?BENCH_PROTO_OPTS, #{
                    env => #{dispatch => Dispatch},
                    enable_connect_protocol => true,
                    h3_datagram => true,
                    enable_webtransport => true,
                    wt_max_sessions => 16
                })
            ]) of
                {ok, _} -> {ok, ProxyPort, Ref};
                {error, Reason} -> {error, Reason};
                {'EXIT', Reason} -> {error, Reason};
                Other -> {error, Other}
            end
    end.

stop_proxy_listener(h3, h3_gateway) ->
    pertisk_eproxy_h3_api_gateway:stop();
stop_proxy_listener(_, Ref) ->
    catch cowboy:stop_listener(Ref),
    ok.

quic_start_quic_fun() ->
    binary_to_atom(<<"start_quic">>, utf8).

ensure_bench_certs() ->
    case persistent_term:get(pertisk_eproxy_bench_certs, undefined) of
        {Cert, Key} when is_list(Cert), is_list(Key) ->
            case {filelib:is_file(Cert), filelib:is_file(Key)} of
                {true, true} -> {Cert, Key};
                _ -> generate_bench_certs()
            end;
        _ ->
            generate_bench_certs()
    end.

generate_bench_certs() ->
    Dir = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "pertisk_bench_tls_"
            ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = filelib:ensure_dir(filename:join(Dir, "cert.pem")),
    Cert = filename:join(Dir, "cert.pem"),
    Key = filename:join(Dir, "key.pem"),
    Cmd =
        "openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 365 "
        "-subj '/CN=bench.local' "
        "-addext 'subjectAltName=DNS:bench.local' "
        "-keyout "
        ++ Key
        ++ " -out "
        ++ Cert
        ++ " 2>/dev/null",
    _ = os:cmd(Cmd),
    persistent_term:put(pertisk_eproxy_bench_certs, {Cert, Key}),
    {Cert, Key}.

free_udp_port() ->
  17000 + (erlang:phash2({os:getpid(), node()}, 8000) rem 8000).

%%====================================================================
%% Load driver
%%====================================================================

drive(Protocol, Port, Conns, Duration, Workload) ->
    Parent = self(),
    Deadline = erlang:monotonic_time(millisecond) + Duration,
    Pids = [
        spawn_link(fun() -> worker(Parent, Protocol, Port, Deadline, Workload) end)
        || _ <- lists:seq(1, Conns)
    ],
    collect(Pids, [], 0, 0).

collect([], Lats, Count, Reconns) ->
    {Lats, Count, Reconns};
collect([Pid | Rest], Lats, Count, Reconns) ->
    receive
        {done, Pid, Acc} ->
            collect(
                Rest,
                maps:get(lats, Acc) ++ Lats,
                Count + maps:get(count, Acc),
                Reconns + maps:get(reconns, Acc)
            )
    end.

worker(Parent, Protocol, Port, Deadline, Workload) ->
    case connect(Protocol, Port) of
        {ok, Handle} ->
            Acc = loop(Protocol, Port, Handle, Deadline, Workload, #{
                lats => [], count => 0, reconns => 0
            }),
            Parent ! {done, self(), Acc};
        {error, _} ->
            Parent ! {done, self(), #{lats => [], count => 0, reconns => 1}}
    end.

loop(Protocol, Port, Handle, Deadline, Workload, Acc) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            close(Protocol, Handle),
            Acc;
        false ->
            Start = erlang:monotonic_time(microsecond),
            case do_request(Protocol, Handle, Workload) of
                ok ->
                    Lat = erlang:monotonic_time(microsecond) - Start,
                    loop(Protocol, Port, Handle, Deadline, Workload, Acc#{
                        lats := [Lat | maps:get(lats, Acc)],
                        count := maps:get(count, Acc) + 1
                    });
                {error, _} ->
                    close(Protocol, Handle),
                    Acc1 = Acc#{reconns := maps:get(reconns, Acc) + 1},
                    case connect(Protocol, Port) of
                        {ok, Handle2} ->
                            loop(Protocol, Port, Handle2, Deadline, Workload, Acc1);
                        {error, _} ->
                            Acc1
                    end
            end
    end.

%%====================================================================
%% Per-protocol client
%%====================================================================

connect(h1, Port) ->
    gen_tcp:connect(
        "127.0.0.1",
        Port,
        [binary, {active, false}, {packet, raw}, {nodelay, true}],
        5000
    );
connect(h2, Port) ->
    Opts = #{
        transport => tls,
        protocols => [http2],
        tls_opts => [{verify, verify_none}, {server_name_indication, disable}]
    },
    case gun:open("127.0.0.1", Port, Opts) of
        {ok, Conn} ->
            case gun:await_up(Conn, 5000) of
                {ok, http2} ->
                    {ok, Conn};
                Other ->
                    catch gun:close(Conn),
                    {error, Other}
            end;
        Error ->
            Error
    end;
connect(h3, Port) ->
    quic_h3:connect("127.0.0.1", Port, #{verify => verify_none, sync => true}).

close(h1, Sock) ->
    gen_tcp:close(Sock);
close(h2, Conn) ->
    catch gun:close(Conn),
    ok;
close(h3, Conn) ->
    catch quic_h3:close(Conn),
    ok.

do_request(h1, Sock, Workload) ->
    case gen_tcp:send(Sock, raw_request(Workload)) of
        ok -> read_response(Sock, <<>>);
        Error -> Error
    end;
do_request(h2, Conn, Workload) ->
    {Method, Path, Body, Headers} = workload_parts(Workload),
    ReqHeaders = maps:to_list(Headers#{<<"host">> => ?BENCH_HOST}),
    StreamRef = gun:request(Conn, Method, Path, ReqHeaders, Body),
    await_gun(Conn, StreamRef);
do_request(h3, Conn, Workload) ->
    {Method, Path, Body, _} = workload_parts(Workload),
    Headers = [
        {<<":method">>, Method},
        {<<":path">>, Path},
        {<<":scheme">>, <<"https">>},
        {<<":authority">>, ?BENCH_HOST}
    ],
    Opts =
        case Body of
            <<>> -> #{end_stream => true};
            _ -> #{end_stream => false}
        end,
    case quic_h3:request(Conn, Headers, Opts) of
        {ok, StreamId} ->
            case Body of
                <<>> ->
                    await_h3(Conn, StreamId);
                _ ->
                    case quic_h3:send_data(Conn, StreamId, Body, true) of
                        ok -> await_h3(Conn, StreamId);
                        Error -> Error
                    end
            end;
        Error ->
            Error
    end.

raw_request(tiny) ->
    <<"GET / HTTP/1.1\r\nHost: bench.local\r\nConnection: keep-alive\r\n\r\n">>;
raw_request(bytes1k) ->
    <<"GET /bytes/1024 HTTP/1.1\r\nHost: bench.local\r\nConnection: keep-alive\r\n\r\n">>;
raw_request(bytes10k) ->
    <<"GET /bytes/10240 HTTP/1.1\r\nHost: bench.local\r\nConnection: keep-alive\r\n\r\n">>;
raw_request(bytes100k) ->
    <<"GET /bytes/102400 HTTP/1.1\r\nHost: bench.local\r\nConnection: keep-alive\r\n\r\n">>;
raw_request(echo) ->
    Body = ?ECHO_BODY,
    Len = integer_to_binary(byte_size(Body)),
    <<
        "POST /echo HTTP/1.1\r\n"
        "Host: bench.local\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: ",
        Len/binary,
        "\r\nConnection: keep-alive\r\n\r\n",
        Body/binary
    >>.

workload_parts(tiny) ->
    {<<"GET">>, <<"/">>, <<>>, #{}};
workload_parts(bytes1k) ->
    {<<"GET">>, <<"/bytes/1024">>, <<>>, #{}};
workload_parts(bytes10k) ->
    {<<"GET">>, <<"/bytes/10240">>, <<>>, #{}};
workload_parts(bytes100k) ->
    {<<"GET">>, <<"/bytes/102400">>, <<>>, #{}};
workload_parts(echo) ->
    {<<"POST">>, <<"/echo">>, ?ECHO_BODY, #{<<"content-type">> => <<"application/json">>}}.

await_gun(Conn, StreamRef) ->
    case gun:await(Conn, StreamRef, 5000) of
        {response, fin, _Status, _Headers} ->
            ok;
        {response, nofin, _Status, _Headers} ->
            await_gun_body(Conn, StreamRef);
        {error, Reason} ->
            {error, Reason};
        Other ->
            Other
    end.

await_gun_body(Conn, StreamRef) ->
    case gun:await(Conn, StreamRef, 5000) of
        {data, fin, _Data} ->
            ok;
        {data, nofin, _Data} ->
            await_gun_body(Conn, StreamRef);
        {response, fin, _, _} ->
            ok;
        {error, Reason} ->
            {error, Reason};
        Other ->
            Other
    end.

await_h3(Conn, StreamId) ->
    receive
        {quic_h3, Conn, {data, StreamId, _, true}} -> ok;
        {quic_h3, Conn, {stream_end, StreamId}} -> ok;
        {quic_h3, Conn, {trailers, StreamId, _}} -> ok;
        {quic_h3, Conn, {data, StreamId, _, false}} -> await_h3(Conn, StreamId);
        {quic_h3, Conn, {response, StreamId, _, _}} -> await_h3(Conn, StreamId);
        {quic_h3, Conn, _Other} -> await_h3(Conn, StreamId)
    after 5000 ->
        {error, timeout}
    end.

read_response(Sock, Buf) ->
    case binary:split(Buf, <<"\r\n\r\n">>) of
        [Headers, Rest] ->
            case is_chunked(Headers) of
                true -> read_chunked(Sock, Rest);
                false -> read_body(Sock, Rest, content_length(Headers))
            end;
        [_] ->
            case gen_tcp:recv(Sock, 0, 5000) of
                {ok, Data} -> read_response(Sock, <<Buf/binary, Data/binary>>);
                {error, _} = E -> E
            end
    end.

read_body(_Sock, Body, Len) when byte_size(Body) >= Len ->
    ok;
read_body(Sock, Body, Len) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> read_body(Sock, <<Body/binary, Data/binary>>, Len);
        {error, _} = E -> E
    end.

read_chunked(Sock, Buf) ->
    case binary:match(Buf, <<"0\r\n\r\n">>) of
        nomatch ->
            case gen_tcp:recv(Sock, 0, 5000) of
                {ok, Data} -> read_chunked(Sock, <<Buf/binary, Data/binary>>);
                {error, _} = E -> E
            end;
        _ ->
            ok
    end.

is_chunked(Headers) ->
    binary:match(string:lowercase(Headers), <<"transfer-encoding: chunked">>) =/= nomatch.

content_length(Headers) ->
    Lower = string:lowercase(Headers),
    case binary:match(Lower, <<"content-length:">>) of
        nomatch ->
            0;
        {Start, MLen} ->
            Tail = binary:part(
                Lower,
                Start + MLen,
                byte_size(Lower) - Start - MLen
            ),
            [Val | _] = binary:split(Tail, <<"\r\n">>),
            binary_to_integer(string:trim(Val))
    end.

%%====================================================================
%% Metrics
%%====================================================================

metrics(Protocol, Workload, Lats, Count, Reconns, Duration, Conns) ->
    Sorted = lists:sort(Lats),
    #{
        protocol => Protocol,
        workload => Workload,
        connections => Conns,
        duration_ms => Duration,
        requests => Count,
        reconnects => Reconns,
        throughput_rps => Count * 1000 / Duration,
        p50_us => percentile(Sorted, 50),
        p90_us => percentile(Sorted, 90),
        p99_us => percentile(Sorted, 99),
        max_us =>
            case Sorted of
                [] -> 0;
                _ -> lists:last(Sorted)
            end
    }.

percentile([], _P) ->
    0;
percentile(Sorted, P) ->
    N = length(Sorted),
    Idx = max(1, min(N, round(P / 100 * N))),
    lists:nth(Idx, Sorted).
