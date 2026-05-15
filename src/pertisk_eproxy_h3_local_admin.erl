%% @doc Run {@link pertisk_eproxy_admin_handler} in-process for HTTP/3 (no gun hop to :9080).
-module(pertisk_eproxy_h3_local_admin).

-export([try_dispatch/7]).

-define(DISPATCH_TIMEOUT_MS, 60000).

%% @doc Dispatch a management `/api/*` request via Cowboy admin handlers.
%% Returns `{ok, Status, Headers, Body}` or `{error, unsupported}` / `{error, Reason}`.
-spec try_dispatch(
    Method :: binary(),
    Host :: binary(),
    Path :: binary(),
    Qs :: binary(),
    H3Headers :: [{binary(), binary()}],
    Body :: binary(),
    ClientIp :: binary()
) ->
    {ok, non_neg_integer(), [{binary(), binary()}], binary()}
    | {error, unsupported}
    | {error, term()}.
try_dispatch(Method, Host, Path, Qs, H3Headers, Body, ClientIp) ->
    case h3_local_admin_path(Path) of
        false ->
            {error, unsupported};
        true ->
            dispatch_admin(Method, Host, Path, Qs, H3Headers, Body, ClientIp)
    end.

h3_local_admin_path(<<"/api/realtime", _/binary>>) ->
    false;
h3_local_admin_path(<<"/api/realtime-sse", _/binary>>) ->
    false;
h3_local_admin_path(<<"/api/", _/binary>>) ->
    true;
h3_local_admin_path(_) ->
    false.

dispatch_admin(Method, Host, Path, Qs, H3Headers, Body, ClientIp) ->
    Parent = self(),
    Stub = pertisk_eproxy_cowboy_stub_conn:start(Parent, Body),
    Req0 = build_req(Method, Host, Path, Qs, H3Headers, Body, ClientIp, Stub),
    Env = #{dispatch => pertisk_eproxy_admin_routes:dispatch()},
    try
        case cowboy_router:execute(Req0, Env) of
            {ok, Req1, #{handler := pertisk_eproxy_admin_handler, handler_opts := Resource}} ->
                _ = pertisk_eproxy_admin_handler:init(Req1, Resource),
                await_response();
            {stop, _ReqStop} ->
                await_response();
            {ok, _Req1, #{handler := _Other}} ->
                {error, unsupported};
            {ok, _Req1, _Env} ->
                {error, unsupported}
        end
    catch
        Class:Reason:Stack ->
            lager:warning(
                "h3 local admin dispatch failed: ~p:~p path=~s stack=~p",
                [Class, Reason, Path, Stack]
            ),
            {error, {Class, Reason}}
    after
        unlink(Stub),
        exit(Stub, kill)
    end.

await_response() ->
    receive
        {h3_admin_response, Status, Headers, RespBody}
        when is_integer(Status), Status >= 100, Status < 600 ->
            {ok, Status, headers_to_list(Headers), safe_binary(RespBody)}
    after ?DISPATCH_TIMEOUT_MS ->
        {error, timeout}
    end.

build_req(Method, Host, Path, Qs, H3Headers, Body, ClientIp, Stub) ->
    HasBody = Body =/= <<>>,
    Headers = h3_headers_to_cowboy(H3Headers, Host, ClientIp),
    Peer = peer_from_client_ip(ClientIp),
    #{
        method => normalize_method(Method),
        version => 'HTTP/1.1',
        scheme => <<"https">>,
        host => Host,
        port => 443,
        path => Path,
        qs => Qs,
        headers => Headers,
        peer => Peer,
        sock => Peer,
        cert => undefined,
        ref => stub,
        pid => Stub,
        streamid => 1,
        has_body => HasBody,
        body_length =>
            case HasBody of
                true -> byte_size(Body);
                false -> undefined
            end
    }.

h3_headers_to_cowboy(H3Headers, Host, ClientIp) ->
    Map0 = maps:from_list([
        {string:lowercase(K), V}
     || {K, V} <- H3Headers,
        is_binary(K),
        is_binary(V),
        byte_size(K) > 0,
        binary:at(K, 0) =/= $:
    ]),
    Map1 = maps:merge(Map0, #{<<"host">> => Host}),
    Xff =
        case maps:get(<<"x-forwarded-for">>, Map1, undefined) of
            undefined -> ClientIp;
            Existing -> <<Existing/binary, ", ", ClientIp/binary>>
        end,
    maps:merge(Map1, #{
        <<"x-forwarded-for">> => Xff,
        <<"x-forwarded-proto">> => <<"https">>,
        <<"x-forwarded-proto-version">> => <<"HTTP/3">>
    }).

peer_from_client_ip(ClientIp) when is_binary(ClientIp) ->
    IpStr = unicode:characters_to_list(ClientIp),
    case inet:parse_address(IpStr) of
        {ok, Ip} -> {Ip, 0};
        _ -> {{127, 0, 0, 1}, 0}
    end.

normalize_method(M) when is_binary(M) ->
    string:uppercase(M);
normalize_method(M) when is_list(M) ->
    normalize_method(list_to_binary(M));
normalize_method(M) when is_atom(M) ->
    atom_to_binary(M, utf8).

headers_to_list(Headers) when is_map(Headers) ->
    [{K, V} || {K, V} <- maps:to_list(Headers)];
headers_to_list(Headers) when is_list(Headers) ->
    Headers.

safe_binary(B) when is_binary(B) ->
    B;
safe_binary(B) ->
    iolist_to_binary(B).
