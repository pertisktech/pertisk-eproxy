%% @doc Alt-Svc header for advertising HTTP/3 (QUIC) on HTTPS responses.
%%
%% Browsers only discover HTTP/3 after seeing `Alt-Svc` on an HTTPS (TCP) response.
%% `curl --http3-only` talks QUIC directly and ignores this header.
-module(pertisk_eproxy_alt_svc).

-export([header_value/0, merge_response_headers/3]).

%% @doc Alt-Svc value for the configured QUIC UDP port.
-spec header_value() -> binary().
header_value() ->
    Port = quic_udp_port(),
    PortBin = integer_to_binary(Port),
    MaBin = integer_to_binary(alt_svc_ma_secs()),
    Persist = alt_svc_persist(),
    %% RFC 7838: alternate authority is ":port" on the same host (e.g. h3=":443"), not "443".
    %% Keep Alt-Svc non-sticky by default so clients recover from transient QUIC failures faster.
    case Persist of
        true ->
                        <<"h3=\":", PortBin/binary, "\"; ma=", MaBin/binary, "; persist=1">>;
        false ->
                        <<"h3=\":", PortBin/binary, "\"; ma=", MaBin/binary>>
    end.

%% @doc Add or replace Alt-Svc on a client-facing response map when appropriate.
-spec merge_response_headers(cowboy_req:req(), binary() | string(), map()) -> map().
merge_response_headers(Req, Host, Headers) when is_map(Headers) ->
    Base = maps:without([<<"alt-svc">>], Headers),
    case should_advertise(Req, Host) of
        true ->
            AltSvc = header_value(),
            lager:debug("Alt-Svc attached host=~s value=~s", [Host, AltSvc]),
            Base#{<<"alt-svc">> => AltSvc};
        false -> Base
    end.

should_advertise(Req, Host) ->
    https_front_request(Req) andalso
        not console_page_request(cowboy_req:path(Req), cowboy_req:qs(Req)) andalso
        pertisk_eproxy_handler:site_advertise_http3(Host).

https_front_request(Req) ->
    case cowboy_req:scheme(Req) of
        https ->
            true;
        <<"https">> ->
            true;
        _ ->
            case cowboy_req:header(<<"x-forwarded-proto">>, Req, <<>>) of
                <<"https">> ->
                    true;
                <<"HTTPS">> ->
                    true;
                _ ->
                    cowboy_req:port(Req) =:= 443
            end
    end.

    console_page_request(Path, Qs) when is_binary(Path), is_binary(Qs) ->
        IsConsoleQuery = binary:match(Qs, <<"console=">>) =/= nomatch,
        IsShellPath = binary:match(Path, <<"/shell">>) =/= nomatch,
        IsNoVncPath = binary:match(Path, <<"/novnc">>) =/= nomatch,
        IsConsoleQuery orelse IsShellPath orelse IsNoVncPath;
    console_page_request(Path, Qs) when is_list(Path), is_list(Qs) ->
        console_page_request(list_to_binary(Path), list_to_binary(Qs));
    console_page_request(_, _) ->
        false.

quic_udp_port() ->
    C = pertisk_eproxy_config:get_config(),
    %% Public port clients use (e.g. K8s Service :443). Differs from container bind port (8443).
    case maps:get(alt_svc_port, C, undefined) of
        P when is_integer(P), P > 0 ->
            P;
        _ ->
            case maps:get(quic_port, C, undefined) of
                Q when is_integer(Q), Q > 0 ->
                    Q;
                _ ->
                    case maps:get(https_port, C, undefined) of
                        H when is_integer(H), H > 0 -> H;
                        _ -> 443
                    end
            end
    end.

alt_svc_ma_secs() ->
    C = pertisk_eproxy_config:get_config(),
    case maps:get(alt_svc_ma_secs, C, 300) of
        S when is_integer(S), S >= 30 -> S;
        _ -> 300
    end.

alt_svc_persist() ->
    C = pertisk_eproxy_config:get_config(),
    maps:get(alt_svc_persist, C, false) =:= true.
