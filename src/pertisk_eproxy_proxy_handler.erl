%%%-------------------------------------------------------------------
%% @doc Reverse proxy request handler for HTTP and HTTPS traffic.
%% @end
%%%-------------------------------------------------------------------

-module(pertisk_eproxy_proxy_handler).

-export([init/2, h1_upstream/6, with_alt_svc/1]).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req, State) ->
    Host = strip_port(cowboy_req:host(Req)),
    case pertisk_eproxy_proxy:get_upstream(Host) of
        {ok, Upstream} ->
            proxy_request(Req, State, Upstream);
        {error, not_found} ->
            Body = jiffy:encode(#{error => <<"No upstream configured for host">>, host => Host}),
            Resp = cowboy_req:reply(404, #{<<"content-type">> => <<"application/json">>}, Body, Req),
            {ok, Resp, State}
    end.

-spec proxy_request(cowboy_req:req(), term(), map()) -> {ok, cowboy_req:req(), term()}.
proxy_request(Req, State, Upstream) ->
    Method = method_atom(cowboy_req:method(Req)),
    Path = cowboy_req:path(Req),
    QueryString = cowboy_req:qs(Req),
    {ok, Body, Req1} = cowboy_req:read_body(Req),
    case h1_upstream(Method, Path, QueryString, cowboy_req:headers(Req1), Body, Upstream) of
        {ok, StatusCode, ResponseHeaders, ResponseBody} ->
            RespHeaders0 = maps:from_list([{list_to_binary(K), list_to_binary(V)} || {K, V} <- ResponseHeaders]),
            RespHeaders = with_alt_svc(RespHeaders0),
            Resp = cowboy_req:reply(StatusCode, RespHeaders, ResponseBody, Req1),
            {ok, Resp, State};
        {error, Reason} ->
            ErrorBody = jiffy:encode(#{error => iolist_to_binary(io_lib:format("~p", [Reason]))}),
            Resp = cowboy_req:reply(502, #{<<"content-type">> => <<"application/json">>}, ErrorBody, Req1),
            {ok, Resp, State}
    end.

%% @doc Shared HTTP/1.1 upstream call (Cowboy and HTTP/3 handler).
-spec h1_upstream(
    head | get | post | put | patch | delete | options,
    binary(),
    binary(),
    cowboy:http_headers(),
    binary(),
    map()
) ->
    {ok, pos_integer(), [{string(), string()}], binary()} | {error, term()}.
h1_upstream(Method, Path, QueryString, HeadersMap, Body, Upstream) ->
    Target = normalize_target(maps:get(target, Upstream)),
    URL = build_target_url(Target, Path, QueryString),
    HdrList = build_outgoing_headers(HeadersMap, Target),
    Request = request_spec(Method, binary_to_list(URL), HdrList, Body),
    case httpc:request(Method, Request, [], [{body_format, binary}]) of
        {ok, {{_Version, StatusCode, _ReasonPhrase}, ResponseHeaders, ResponseBody}} ->
            {ok, StatusCode, ResponseHeaders, ResponseBody};
        {error, Reason} ->
            {error, Reason}
    end.

-spec with_alt_svc(cowboy:http_headers()) -> cowboy:http_headers().
with_alt_svc(Headers) ->
    H3Port = application:get_env(pertisk_eproxy, listen_port_h3, 443),
    %% Advertise HTTP/3 on the QUIC UDP port (same host; clients probe UDP).
    AltSvc = iolist_to_binary(io_lib:format("h3=\":~w\"; ma=86400", [H3Port])),
    maps:put(<<"alt-svc">>, AltSvc, maps:remove(<<"alt-svc">>, Headers)).

-spec strip_port(binary()) -> binary().
strip_port(Host) ->
    hd(binary:split(Host, <<":">>, [global])).

-spec normalize_target(binary() | list()) -> binary().
normalize_target(Target) when is_list(Target) ->
    normalize_target(list_to_binary(Target));
normalize_target(<<"http://", Rest/binary>>) ->
    Rest;
normalize_target(<<"https://", Rest/binary>>) ->
    Rest;
normalize_target(Target) ->
    Target.

-spec build_target_url(binary(), binary(), binary()) -> binary().
build_target_url(Target, Path, <<>>) ->
    <<"http://", Target/binary, Path/binary>>;
build_target_url(Target, Path, QueryString) ->
    <<"http://", Target/binary, Path/binary, "?", QueryString/binary>>.

-spec build_outgoing_headers(map(), binary()) -> [{string(), string()}].
build_outgoing_headers(Headers, Target) ->
    Filtered = maps:remove(<<"host">>, maps:remove(<<"content-length">>, Headers)),
    [{binary_to_list(K), binary_to_list(V)} || {K, V} <- maps:to_list(Filtered)] ++
        [{"host", binary_to_list(Target)}].
-spec method_atom(binary()) -> head | get | post | put | patch | delete | options.
method_atom(<<"HEAD">>) ->
    head;
method_atom(<<"GET">>) ->
    get;
method_atom(<<"POST">>) ->
    post;
method_atom(<<"PUT">>) ->
    put;
method_atom(<<"PATCH">>) ->
    patch;
method_atom(<<"DELETE">>) ->
    delete;
method_atom(_) ->
    options.

-spec request_spec(head | get | post | put | patch | delete | options, string(), [{string(), string()}], binary()) -> tuple().
request_spec(head, URL, Headers, _Body) ->
    {URL, Headers};
request_spec(get, URL, Headers, _Body) ->
    {URL, Headers};
request_spec(delete, URL, Headers, _Body) ->
    {URL, Headers};
request_spec(options, URL, Headers, _Body) ->
    {URL, Headers};
request_spec(Method, URL, Headers, Body) when Method =:= post; Method =:= put; Method =:= patch ->
    {URL, Headers, "application/octet-stream", Body}.