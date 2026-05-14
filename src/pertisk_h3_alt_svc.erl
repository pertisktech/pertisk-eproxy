%% @doc Shared HTTP/3 discovery via {@code Alt-Svc} on TCP (HTTPS) responses.
%%
%% Browsers negotiate HTTP/2 first, then migrate to QUIC using this header.
%% {@link https://datatracker.ietf.org/doc/html/rfc9114#name-alternative-service-adverti RFC 9114}
-module(pertisk_h3_alt_svc).

-export([advertised_port/2, header_value/1]).

-define(ALT_SVC_MA_SEC, 2592000).

%% @doc Port clients should use for QUIC on this origin.
%%
%% Precedence: {@code alt_svc_port} (public/LB), then {@code https_port}, then
%% {@code quic_port} (bind port when TLS port is unset), then {@code ReqPortFallback}
%% (Cowboy / Ranch observed port).
-spec advertised_port(map(), undefined | inet:port_number()) -> undefined | inet:port_number().
advertised_port(Cfg, ReqPortFallback) ->
    case maps:get(alt_svc_port, Cfg, undefined) of
        P when is_integer(P), P > 0 ->
            P;
        _ ->
            case maps:get(https_port, Cfg, undefined) of
                P2 when is_integer(P2), P2 > 0 ->
                    P2;
                _ ->
                    case maps:get(quic_port, Cfg, undefined) of
                        P3 when is_integer(P3), P3 > 0 ->
                            P3;
                        _ ->
                            case ReqPortFallback of
                                P4 when is_integer(P4), P4 > 0 -> P4;
                                _ -> undefined
                            end
                    end
            end
    end.

%% @doc Single {@code Alt-Svc} field-value for HTTP/3 on {@code Port}.
%%
%% {@code ma} is long-lived so clients retain the hint across restarts; {@code persist=1}
%% encourages reuse of the alternative service (RFC 7838).
%%
%% Include {@code h3-29} alongside RFC {@code h3}: some Chromium builds favour or
%% probe the draft ALPN first; advertising both improves discovery parity with
%% common reverse proxies.
-spec header_value(inet:port_number()) -> binary().
header_value(P) when is_integer(P), P > 0 ->
    iolist_to_binary(
        io_lib:format(
            "h3=\":~w\"; ma=~w; persist=1, h3-29=\":~w\"; ma=~w; persist=1",
            [P, ?ALT_SVC_MA_SEC, P, ?ALT_SVC_MA_SEC]
        )
    ).
