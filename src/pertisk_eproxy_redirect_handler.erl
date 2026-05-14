%%%-------------------------------------------------------------------
%% @doc Redirect cleartext HTTP requests to HTTPS.
%% @end
%%%-------------------------------------------------------------------

-module(pertisk_eproxy_redirect_handler).

-export([init/2]).

-spec init(cowboy_req:req(), map()) -> {ok, cowboy_req:req(), map()}.
init(Req, #{https_port := HttpsPort} = State) ->
    Host = cowboy_req:host(Req),
    Path = cowboy_req:path(Req),
    QueryString = cowboy_req:qs(Req),
    PortSuffix = https_port_suffix(HttpsPort),
    QuerySuffix = query_suffix(QueryString),
    Location = <<"https://", Host/binary, PortSuffix/binary, Path/binary, QuerySuffix/binary>>,
    Resp = cowboy_req:reply(308, #{<<"location">> => Location}, Req),
    {ok, Resp, State}.

-spec https_port_suffix(integer()) -> binary().
https_port_suffix(443) ->
    <<>>;
https_port_suffix(Port) ->
    <<":", (integer_to_binary(Port))/binary>>.

-spec query_suffix(binary()) -> binary().
query_suffix(<<>>) ->
    <<>>;
query_suffix(QueryString) ->
    <<"?", QueryString/binary>>.