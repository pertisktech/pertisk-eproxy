%%%-------------------------------------------------------------------
%% @doc HTTP request handler for admin API
%% @end
%%%-------------------------------------------------------------------

-module(pertisk_eproxy_admin_handler).

-export([init/2]).

%%%===================================================================
%% Cowboy handler callbacks
%%%===================================================================

-spec init(Req, State) -> {ok, Req, State}
    when Req :: cowboy_req:req(),
         State :: term().
init(Req, State) ->
    case cowboy_req:method(Req) of
        <<"OPTIONS">> ->
            Resp = cowboy_req:reply(204, cors_headers(), <<>>, Req),
            {ok, Resp, State};
        _ ->
            handle_route(Req, State)
    end.

handle_route(Req, [status]) ->
    handle_status(Req);
handle_route(Req, [upstreams]) ->
    handle_upstreams(Req);
handle_route(Req, [upstream]) ->
    handle_upstream(Req);
handle_route(Req, [certs]) ->
    handle_certs(Req);
handle_route(Req, State) ->
    Resp = cowboy_req:reply(404, cors_headers(#{<<"content-type">> => <<"application/json">>}),
                             jiffy:encode(#{error => <<"Not Found">>}), Req),
    {ok, Resp, State}.

-spec cors_headers() -> map().
cors_headers() ->
    cors_headers(#{}).

-spec cors_headers(map()) -> map().
cors_headers(Extra) ->
    maps:merge(#{
        <<"access-control-allow-origin">>  => <<"*">>,
        <<"access-control-allow-methods">> => <<"GET, POST, PUT, DELETE, OPTIONS">>,
        <<"access-control-allow-headers">> => <<"content-type, authorization">>,
        <<"access-control-max-age">>       => <<"86400">>
    }, Extra).

%%%===================================================================
%% Handler functions
%%%===================================================================

-spec handle_status(Req) -> {ok, Req, term()}
    when Req :: cowboy_req:req().
handle_status(Req) ->
    Status = pertisk_eproxy_admin:get_status(),
    Body = jiffy:encode(Status),
    Resp = cowboy_req:reply(200, cors_headers(#{<<"content-type">> => <<"application/json">>}), Body, Req),
    {ok, Resp, status}.

-spec handle_upstreams(Req) -> {ok, Req, term()}
    when Req :: cowboy_req:req().
handle_upstreams(Req) ->
    Method = cowboy_req:method(Req),
    case Method of
        <<"GET">> ->
            Upstreams = pertisk_eproxy_admin:list_upstreams(),
            UpstreamsMap = [#{host => Host, config => Config} || {Host, Config} <- Upstreams],
            Body = jiffy:encode(#{upstreams => UpstreamsMap}),
            Resp = cowboy_req:reply(200, cors_headers(#{<<"content-type">> => <<"application/json">>}), Body, Req),
            {ok, Resp, upstreams};
        <<"POST">> ->
            {ok, Data, Req2} = cowboy_req:read_body(Req),
            Result = handle_add_upstream(Data, Req2),
            {ok, Result, upstreams};
        _ ->
            Body = jiffy:encode(#{error => <<"Method not allowed">>}),
            Resp = cowboy_req:reply(405, cors_headers(#{<<"content-type">> => <<"application/json">>}), Body, Req),
            {ok, Resp, upstreams}
    end.

-spec handle_add_upstream(Data, Req) -> Req
    when Data :: binary(),
         Req :: cowboy_req:req().
handle_add_upstream(Data, Req) ->
    case safe_decode_upstream(Data) of
        {ok, Host, Config} ->
            pertisk_eproxy_admin:add_upstream(Host, Config),
            SuccessBody = jiffy:encode(#{status => <<"ok">>, host => Host}),
            cowboy_req:reply(201, cors_headers(#{<<"content-type">> => <<"application/json">>}), SuccessBody, Req);
        {error, Error} ->
            ErrorMsg = iolist_to_binary(io_lib:format("~p", [Error])),
            ErrorBody = jiffy:encode(#{error => ErrorMsg}),
            cowboy_req:reply(400, cors_headers(#{<<"content-type">> => <<"application/json">>}), ErrorBody, Req)
    end.

-spec safe_decode_upstream(Data) -> {ok, binary(), map()} | {error, term()}
    when Data :: binary().
safe_decode_upstream(Data) ->
    try
        Decoded = jiffy:decode(Data, [return_maps]),
        Host = maps:get(<<"name">>, Decoded, <<>>),
        Config = maps:with([<<"target">>, <<"health_check">>, <<"weight">>], Decoded),
        {ok, Host, Config}
    catch
        _:Error ->
            {error, Error}
    end.

-spec handle_upstream(Req) -> {ok, Req, term()}
    when Req :: cowboy_req:req().
handle_upstream(Req) ->
    Method = cowboy_req:method(Req),
    Host = cowboy_req:binding(host, Req),
    case Method of
        <<"DELETE">> ->
            pertisk_eproxy_admin:remove_upstream(Host),
            Body = jiffy:encode(#{status => <<"removed">>, host => Host}),
            Resp = cowboy_req:reply(200, cors_headers(#{<<"content-type">> => <<"application/json">>}), Body, Req),
            {ok, Resp, upstream};
        _ ->
            Body = jiffy:encode(#{error => <<"Method not allowed">>}),
            Resp = cowboy_req:reply(405, cors_headers(#{<<"content-type">> => <<"application/json">>}), Body, Req),
            {ok, Resp, upstream}
    end.

-spec handle_certs(Req) -> {ok, Req, term()}
    when Req :: cowboy_req:req().
handle_certs(Req) ->
    % Placeholder for certificate management
    Certs = #{
        total => 0,
        expiring_soon => [],
        issued => []
    },
    Body = jiffy:encode(Certs),
    Resp = cowboy_req:reply(200, cors_headers(#{<<"content-type">> => <<"application/json">>}), Body, Req),
    {ok, Resp, certs}.
