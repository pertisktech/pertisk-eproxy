#!/usr/bin/env escript
%% @doc HTTP/3 proof against localhost:443 using the same quic_h3 stack as pertisk_eproxy.
%%
%% Prerequisites:
%%   - Another terminal: `sudo make run-web` (must stay running).
%%   - Run this **without** sudo: `make h3-poc-erlang-client` (so _build stays yours).
%%   - In run-web output you need: "HTTP/3 QUIC is active" (not "*** WARNING ... gen_udp").
-mode(compile).

-define(CONNECT_MS, 4000).

main(_) ->
    ok = add_dep_paths(),
    ok = start_quic(),
    ok = probe_tcp_or_exit(),
    Opts = #{
        sync => true,
        verify => false,
        connect_timeout => ?CONNECT_MS,
        quic_opts => #{server_name => <<"admin.arm.thaidevops.co">>}
    },
    Hosts = [
        {"127.0.0.1", "IPv4 loopback"},
        {"::1", "IPv6 loopback"}
    ],
    case try_quic_hosts(Hosts, Opts) of
        {ok, Conn, Host, Label} ->
            io:format(
                "h3_local_client: quic_h3 connected via ~s (~s). Server QUIC is OK.~n",
                [Host, Label]
            ),
            ok = quic_h3:close(Conn),
            halt(0);
        {error, Last} ->
            io:format(
                "h3_local_client: QUIC failed on all loopback addresses. Last error: ~p~n"
                "~n"
                "Checklist:~n"
                "  1) `sudo make run-web` is running in another terminal and stayed up.~n"
                "  2) Log line contains: pertisk_eproxy: HTTP/3 QUIC is active~n"
                "     (if you see *** WARNING gen_udp, QUIC is NOT running — only a raw UDP bind).~n"
                "  3) Do not run this escript with sudo unless you must; use: make h3-poc-erlang-client~n",
                [Last]
            ),
            halt(1)
    end.

try_quic_hosts(Hosts, Opts) ->
    try_quic_hosts(Hosts, Opts, undefined).

try_quic_hosts([], _Opts, LastErr) ->
    {error, LastErr};
try_quic_hosts([{Host, Label} | Rest], Opts, _Last) ->
    io:format("h3_local_client: QUIC connect ~s (~s), timeout=~w ms...~n", [Host, Label, ?CONNECT_MS]),
    case quic_h3:connect(Host, 443, Opts) of
        {ok, Conn} ->
            {ok, Conn, Host, Label};
        {error, Reason} ->
            io:format("h3_local_client:   -> ~p~n", [Reason]),
            try_quic_hosts(Rest, Opts, Reason)
    end.

probe_tcp_or_exit() ->
    case gen_tcp:connect({127, 0, 0, 1}, 443, [binary, {active, false}, {packet, raw}], 2000) of
        {ok, S} ->
            gen_tcp:close(S),
            io:format("h3_local_client: TCP 127.0.0.1:443 accepts (Cowboy TLS is up).~n"),
            ok;
        {error, Reason} ->
            io:format(
                "h3_local_client: TCP connect 127.0.0.1:443 failed (~p).~n"
                "Start the proxy first in another terminal: sudo make run-web~n",
                [Reason]
            ),
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
