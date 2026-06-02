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
    case alt_svc_action(Req, Host, Headers) of
        true ->
            AltSvc = header_value(),
            lager:debug("Alt-Svc attached host=~s value=~s", [Host, AltSvc]),
            Base#{<<"alt-svc">> => AltSvc};
        clear ->
            lager:info("Alt-Svc cleared host=~s (console page)", [Host]),
            Base#{<<"alt-svc">> => <<"clear">>};
        false -> Base
    end.

alt_svc_action(Req, Host, RespHeaders) ->
    Path = cowboy_req:path(Req),
    case console_page_request(Path, cowboy_req:qs(Req)) of
        true -> clear;
        false ->
            case is_registry_path(Path) of
                true ->
                    %% Docker registry protocol (OCI Distribution Spec /v2/ paths) must not
                    %% receive Alt-Svc. Docker BuildKit's registry client (unlike the Docker
                    %% daemon) honours Alt-Svc and upgrades to HTTP/3; the buildx imagetools
                    %% client then fails to parse the manifest response ("unexpected end of
                    %% JSON input") when fetching via H3.
                    false;
                false ->
                    case is_grpc_req(Req) orelse is_grpc_resp(RespHeaders) of
                        true ->
                            %% gRPC over H3 is disabled; do not advertise Alt-Svc to gRPC clients
                            %% (checked on both request and response content-type) or they will
                            %% upgrade to H3 and receive a 421 redirect loop.
                            false;
                        false ->
                            case https_front_request(Req) of
                                true ->
                                    case pertisk_eproxy_handler:site_advertise_http3(Host) of
                                        true -> true;
                                        false -> clear
                                    end;
                                false -> false
                            end
                    end
            end
    end.

%% Docker OCI Distribution Spec paths all begin with /v2/.
%% Suppressing Alt-Svc on these prevents BuildKit's Go registry client from
%% upgrading to HTTP/3 and hitting H3-specific response parsing failures.
is_registry_path(<<"/v2/", _/binary>>) -> true;
is_registry_path(<<"/v2">>) -> true;
is_registry_path(_) -> false.

%% Detect gRPC / Connect-protocol by REQUEST content-type.
%% Mirror the checks in pertisk_eproxy_handler:is_grpc_request/1.
is_grpc_req(Req) ->
    Ct = string:lowercase(cowboy_req:header(<<"content-type">>, Req, <<>>)),
    is_grpc_content_type(Ct).

%% Detect gRPC / Connect-protocol by RESPONSE content-type.
%% The Connect protocol always echoes a matching content-type in the response,
%% so this catches cases where the request content-type is not available
%% (e.g. H2 pseudo-headers stripped before our check runs).
is_grpc_resp(RespHeaders) when is_map(RespHeaders) ->
    Ct = string:lowercase(maps:get(<<"content-type">>, RespHeaders, <<>>)),
    is_grpc_content_type(Ct);
is_grpc_resp(_) -> false.

is_grpc_content_type(Ct) ->
    case Ct of
        <<"application/grpc", _/binary>>     -> true;
        <<"application/grpc-web", _/binary>> -> true;
        <<"application/connect+", _/binary>> -> true;
        _ -> false
    end.

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
