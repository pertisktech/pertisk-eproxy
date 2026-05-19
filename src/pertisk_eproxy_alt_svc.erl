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
    %% RFC 7838: alternate authority is ":port" on the same host (e.g. h3=":443"), not "443".
        %% Advertise both h3 and h3-29 for broader client interop (matches pertisk-rproxy behavior).
        <<"h3=\":", PortBin/binary, "\"; ma=86400; persist=1, ",
            "h3-29=\":", PortBin/binary, "\"; ma=86400; persist=1">>.

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
    https_front_request(Req) andalso pertisk_eproxy_handler:site_advertise_http3(Host).

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

quic_udp_port() ->
    C = pertisk_eproxy_config:get_config(),
    case maps:get(quic_port, C, undefined) of
        P when is_integer(P), P > 0 ->
            P;
        _ ->
            case maps:get(https_port, C, undefined) of
                H when is_integer(H), H > 0 -> H;
                _ -> 443
            end
    end.
