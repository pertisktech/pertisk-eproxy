%% @doc Prometheus scrape handler for the dedicated metrics listener (:9090).
-module(pertisk_eproxy_metrics_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req, metrics) ->
    Body = prometheus_text_format:format(),
    Req2 = cowboy_req:reply(
        200,
        #{<<"content-type">> => <<"text/plain; version=0.0.4">>},
        Body,
        Req
    ),
    {ok, Req2, undefined};
init(Req, health) ->
    Req2 = cowboy_req:reply(200, #{}, <<"OK">>, Req),
    {ok, Req2, undefined}.
