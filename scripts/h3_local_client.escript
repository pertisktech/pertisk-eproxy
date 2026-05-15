#!/usr/bin/env escript
%% @doc Prove HTTP/3 end-to-end using the same quic_h3 stack as pertisk_eproxy.
%%
%% Local (needs `sudo make run-web` on this machine, maps host to 127.0.0.1 via /etc/hosts or curl --resolve):
%%   make h3-poc-erlang-client
%%   escript scripts/h3_local_client.escript
%%
%% Remote (real DNS + UDP 443 to the deployment; no sudo):
%%   make build
%%   escript scripts/h3_local_client.escript admin.arm.thaidevops.co
%%   escript scripts/h3_local_client.escript admin.arm.thaidevops.co /api/health
%%
%% Optional: H3_INSECURE_TLS=1 disables certificate verification (protocol-only smoke test).
-mode(compile).

-define(CONNECT_MS, 8000).
-define(REQUEST_MS, 15000).

main(Args) ->
    ok = add_dep_paths(),
    ok = start_quic(),
    case parse_args(Args) of
        {loopback, Authority} ->
            ok = probe_tcp_or_exit({127, 0, 0, 1}, 443),
            run_h3_proof(
                [
                    {{127, 0, 0, 1}, "IPv4 loopback"},
                    {"::1", "IPv6 loopback"}
                ],
                443,
                Authority,
                <<"/">>,
                loopback_opts(Authority)
            );
        {remote, Host, Path} ->
            ok = probe_tcp_or_exit(Host, 443),
            Authority = list_to_binary(Host),
            run_h3_proof(
                [{Host, "DNS"}],
                443,
                Authority,
                Path,
                remote_opts(Host, Authority)
            )
    end.

parse_args([]) ->
    {loopback, <<"admin.arm.thaidevops.co">>};
parse_args([Host]) ->
    {remote, Host, <<"/">>};
parse_args([Host, Path0]) ->
    Path1 =
        case Path0 of
            "/" ++ _ -> Path0;
            P -> "/" ++ P
        end,
    {remote, Host, list_to_binary(Path1)};
parse_args(_) ->
    io:format(
        "usage:~n"
        "  escript scripts/h3_local_client.escript                    # loopback 127.0.0.1 / ::1~n"
        "  escript scripts/h3_local_client.escript HOST [PATH]        # remote HTTP/3 GET~n",
        []
    ),
    halt(2).

loopback_opts(Authority) ->
    #{
        sync => true,
        verify => verify_none,
        connect_timeout => ?CONNECT_MS,
        quic_opts => #{server_name => Authority}
    }.

remote_opts(_Host, Authority) ->
    Base = #{
        sync => true,
        connect_timeout => ?CONNECT_MS,
        quic_opts => #{server_name => Authority}
    },
    case os:getenv("H3_INSECURE_TLS") of
        "1" ->
            Base#{verify => verify_none};
        _ ->
            case tls_verify_opts() of
                {ok, Tls} ->
                    maps:merge(Base, Tls);
                {error, no_cacerts} ->
                    io:format(
                        "h3_local_client: no OS CA bundle for verify_peer; "
                        "using verify_none (set H3_INSECURE_TLS=1 to silence). "
                        "Install ca-certificates / use OTP with public_key:cacerts_get/0 for strict TLS.~n",
                        []
                    ),
                    Base#{verify => verify_none}
            end
    end.

tls_verify_opts() ->
    case erlang:function_exported(public_key, cacerts_get, 0) of
        true ->
            try public_key:cacerts_get() of
                [_ | _] = Certs ->
                    {ok, #{verify => verify_peer, cacerts => Certs}};
                _ ->
                    {error, no_cacerts}
            catch
                _:_ ->
                    {error, no_cacerts}
            end;
        false ->
            {error, no_cacerts}
    end.

run_h3_proof(Hosts, Port, Authority, Path, Opts) ->
    case try_quic_hosts(Hosts, Port, Authority, Path, Opts) of
        {ok, Conn, Host, Label, Status, Body} ->
            io:format(
                "h3_local_client: HTTP/3 proof OK via ~s (~s): HTTP ~w, ~w byte body.~n",
                [Host, Label, Status, byte_size(Body)]
            ),
            PreviewLen = min(240, byte_size(Body)),
            case PreviewLen of
                0 ->
                    ok;
                _ ->
                    io:format("h3_local_client: body preview (~w bytes):~n~s~n", [
                        PreviewLen,
                        binary:part(Body, 0, PreviewLen)
                    ])
            end,
            ok = quic_h3:close(Conn),
            halt(0);
        {error, Last} ->
            io:format(
                "h3_local_client: HTTP/3 failed on all targets. Last error: ~p~n"
                "~n"
                "Loopback checklist:~n"
                "  1) `sudo make run-web` running; log: pertisk_eproxy: HTTP/3 QUIC is active~n"
                "  2) Not *** WARNING plain gen_udp~n"
                "~n"
                "Remote checklist:~n"
                "  1) UDP/443 allowed from this network~n"
                "  2) Same quic_h3/erlang_quic as server (this escript)~n",
                [Last]
            ),
            halt(1)
    end.

try_quic_hosts(Hosts, Port, Authority, Path, Opts) ->
    try_quic_hosts(Hosts, Port, Authority, Path, Opts, undefined).

try_quic_hosts([], _Port, _Authority, _Path, _Opts, LastErr) ->
    {error, LastErr};
try_quic_hosts([{Host, Label} | Rest], Port, Authority, Path, Opts, _Last) ->
    io:format("h3_local_client: QUIC+HTTP/3 ~s:~w (~s), connect_timeout=~w ms...~n", [
        fmt_host(Host), Port, Label, ?CONNECT_MS
    ]),
    case quic_h3:connect(Host, Port, Opts) of
        {ok, Conn} ->
            case h3_get(Conn, Authority, Path, ?REQUEST_MS) of
                {ok, Status, Body} ->
                    {ok, Conn, fmt_host(Host), Label, Status, Body};
                {error, Reason} ->
                    io:format("h3_local_client:   -> request failed: ~p~n", [Reason]),
                    catch quic_h3:close(Conn),
                    try_quic_hosts(Rest, Port, Authority, Path, Opts, Reason)
            end;
        {error, Reason} ->
            io:format("h3_local_client:   -> connect: ~p~n", [Reason]),
            try_quic_hosts(Rest, Port, Authority, Path, Opts, Reason)
    end.

fmt_host({A, B, C, D}) ->
    lists:flatten(io_lib:format("~w.~w.~w.~w", [A, B, C, D]));
fmt_host({A, B, C, D, E, F, G, H}) ->
    lists:flatten(io_lib:format("~w:~w:~w:~w:~w:~w:~w:~w", [A, B, C, D, E, F, G, H]));
fmt_host(H) when is_list(H) ->
    H;
fmt_host(H) when is_binary(H) ->
    binary_to_list(H).

h3_get(Conn, Authority, Path, TimeoutMs) ->
    Headers = [
        {<<":method">>, <<"GET">>},
        {<<":scheme">>, <<"https">>},
        {<<":path">>, Path},
        {<<":authority">>, Authority}
    ],
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    case quic_h3:request(Conn, Headers) of
        {ok, StreamId} ->
            recv_h3_response(Conn, StreamId, Deadline, undefined, <<>>);
        {error, _} = E ->
            E
    end.

recv_h3_response(Conn, StreamId, Deadline, Status, Body) ->
    Timeout = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {quic_h3, Conn, {response, StreamId, S, _RespHeaders}} when S >= 100, S < 200 ->
            recv_h3_response(Conn, StreamId, Deadline, Status, Body);
        {quic_h3, Conn, {response, StreamId, S, _RespHeaders}} when S >= 200 ->
            recv_h3_response(Conn, StreamId, Deadline, S, Body);
        {quic_h3, Conn, {data, StreamId, Chunk, Fin}} ->
            NewBody = <<Body/binary, Chunk/binary>>,
            case Fin of
                true ->
                    case Status of
                        undefined ->
                            {error, {no_final_status, NewBody}};
                        _ when is_integer(Status) ->
                            {ok, Status, NewBody}
                    end;
                false ->
                    recv_h3_response(Conn, StreamId, Deadline, Status, NewBody)
            end;
        {quic_h3, Conn, closed} ->
            {error, h3_connection_closed};
        {quic_h3, Conn, {error, Code, Reason}} ->
            {error, {h3_error, Code, Reason}};
        {quic_h3, Conn, {stream_reset, StreamId, Code}} ->
            {error, {stream_reset, Code}}
    after Timeout ->
        {error, response_timeout}
    end.

probe_tcp_or_exit(Host, Port) ->
    case gen_tcp:connect(Host, Port, [binary, {active, false}, {packet, raw}], 3000) of
        {ok, S} ->
            gen_tcp:close(S),
            io:format("h3_local_client: TCP ~s:~w accepts (TLS listener up).~n", [fmt_host(Host), Port]),
            ok;
        {error, Reason} ->
            io:format(
                "h3_local_client: TCP connect ~s:~w failed (~p).~n",
                [fmt_host(Host), Port, Reason]
            ),
            io:format("For loopback: start `sudo make run-web` first.~n", []),
            halt(4)
    end.

add_dep_paths() ->
    Wild = filelib:wildcard("_build/default/lib/*/ebin"),
    case Wild of
        [] ->
            io:format("h3_local_client: no _build/default/lib/*/ebin — run `make build` from repo root first.~n"),
            halt(2);
        _ ->
            ok = lists:foreach(fun code:add_pathz/1, Wild),
            ok
    end.

start_quic() ->
    case application:ensure_all_started(quic) of
        {ok, _} ->
            ok;
        {error, E} ->
            io:format("h3_local_client: application:ensure_all_started(quic) failed: ~p~n", [E]),
            halt(3)
    end.
