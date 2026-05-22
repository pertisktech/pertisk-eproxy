%% @doc Serve management admin UI + `/api/*` in-process over HTTP/3 (no gun hop to :9080).
-module(pertisk_eproxy_h3_local_admin).

-export([try_dispatch/7]).

-define(DISPATCH_TIMEOUT_MS, 60000).
-define(ADMIN_PRIV, "admin").

%% @doc Dispatch management traffic on HTTP/3.
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
    case h3_local_management_path(Path) of
        false ->
            {error, unsupported};
        true ->
            case serve_static_h3(Method, Host, Path) of
                {ok, Status, Headers, RespBody} ->
                    {ok, Status, Headers, RespBody};
                not_found ->
                    case serve_spa_h3(Method, Host, Path) of
                        {ok, Status, Headers, RespBody} ->
                            {ok, Status, Headers, RespBody};
                        not_found ->
                            dispatch_management(Method, Host, Path, Qs, H3Headers, Body, ClientIp)
                    end
            end
    end.

%% WebSocket realtime stays on the TCP management listener only.
h3_local_management_path(<<"/api/realtime", _/binary>>) ->
    false;
h3_local_management_path(_) ->
    true.

%% cowboy_static uses cowboy_rest; the stub only captures cowboy_req:reply/4.
serve_static_h3(Method, Host, Path) ->
    case normalize_method(Method) of
        <<"GET">> ->
            read_static_file(Host, Path, false);
        <<"HEAD">> ->
            read_static_file(Host, Path, true);
        _ ->
            not_found
    end.

read_static_file(Host, Path, HeadOnly) ->
    case static_disk_path(Path) of
        {ok, FilePath} ->
            case file:read_file(FilePath) of
                {ok, Content} ->
                    Body = case HeadOnly of
                        true -> <<>>;
                        false -> Content
                    end,
                    Headers = static_response_headers(Host, FilePath),
                    {ok, 200, Headers, Body};
                {error, enoent} ->
                    not_found;
                {error, Reason} ->
                    {error, {static_read, Reason}}
            end;
        not_found ->
            not_found
    end.

static_disk_path(<<"/favicon.svg">>) ->
    {ok, filename:join([admin_dir(), "favicon.svg"])};
static_disk_path(<<"/assets/", Rel/binary>>) ->
    case safe_asset_relative(Rel) of
        {ok, RelBin} ->
            {ok, filename:join([admin_dir(), "assets", RelBin])};
        error ->
            not_found
    end;
static_disk_path(_) ->
    not_found.

%% React client routes (/, /sites, …) — serve index.html without cowboy stub.
serve_spa_h3(Method, Host, Path) ->
    case Path of
        <<"/api/", _/binary>> ->
            not_found;
        _ ->
            case normalize_method(Method) of
                <<"GET">> ->
                    read_spa_index(Host, false);
                <<"HEAD">> ->
                    read_spa_index(Host, true);
                _ ->
                    not_found
            end
    end.

read_spa_index(Host, HeadOnly) ->
    IndexFile = filename:join([admin_dir(), "index.html"]),
    case file:read_file(IndexFile) of
        {ok, Html} ->
            Body = case HeadOnly of
                true -> <<>>;
                false -> Html
            end,
            Headers = spa_response_headers(Host),
            {ok, 200, Headers, Body};
        {error, enoent} ->
            not_found;
        {error, Reason} ->
            {error, {spa_read, Reason}}
    end.

spa_response_headers(Host) ->
    Base = pertisk_eproxy_response_headers:merge(#{
        <<"content-type">> => <<"text/html; charset=utf-8">>
    }),
    Base1 =
        case pertisk_eproxy_handler:site_advertise_http3(Host) of
            true -> Base#{<<"alt-svc">> => pertisk_eproxy_alt_svc:header_value()};
            false -> Base
        end,
    maps:to_list(Base1).

admin_dir() ->
    filename:join([code:priv_dir(pertisk_eproxy), ?ADMIN_PRIV]).

%% Reject path traversal (same rules as cowboy_static validate_reserved).
safe_asset_relative(Rel) ->
    Parts = binary:split(Rel, <<"/">>, [global]),
    case lists:any(fun bad_path_segment/1, Parts) of
        true ->
            error;
        false ->
            {ok, filename:join([binary_to_list(P) || P <- Parts, P =/= <<>>])}
    end.

bad_path_segment(<<>>) ->
    false;
bad_path_segment(<<".">>) ->
    true;
bad_path_segment(<<"..">>) ->
    true;
bad_path_segment(Seg) ->
    reserved_in_segment(Seg).

reserved_in_segment(<<>>) ->
    false;
reserved_in_segment(<<C, Rest/binary>>) ->
    case C of
        $/ -> true;
        $\\ -> true;
        $\0 -> true;
        _ -> reserved_in_segment(Rest)
    end.

static_response_headers(Host, FilePath) ->
    CT = static_content_type(FilePath),
    Base = pertisk_eproxy_response_headers:merge(#{
        <<"content-type">> => CT,
        <<"cache-control">> => <<"public, max-age=31536000, immutable">>
    }),
    Base1 =
        case pertisk_eproxy_handler:site_advertise_http3(Host) of
            true -> Base#{<<"alt-svc">> => pertisk_eproxy_alt_svc:header_value()};
            false -> Base
        end,
    maps:to_list(Base1).

static_content_type(FilePath) ->
    case filename:extension(FilePath) of
        ".js" -> <<"application/javascript">>;
        ".mjs" -> <<"application/javascript">>;
        ".css" -> <<"text/css; charset=utf-8">>;
        ".svg" -> <<"image/svg+xml">>;
        ".png" -> <<"image/png">>;
        ".jpg" -> <<"image/jpeg">>;
        ".jpeg" -> <<"image/jpeg">>;
        ".webp" -> <<"image/webp">>;
        ".woff2" -> <<"font/woff2">>;
        ".woff" -> <<"font/woff">>;
        ".json" -> <<"application/json">>;
        ".map" -> <<"application/json">>;
        _ -> <<"application/octet-stream">>
    end.

dispatch_management(Method, Host, Path, Qs, H3Headers, Body, ClientIp) ->
    Parent = self(),
    Stub = pertisk_eproxy_cowboy_stub_conn:start(Parent, Body),
    Req0 = build_req(Method, Host, Path, Qs, H3Headers, Body, ClientIp, Stub),
    Env = #{dispatch => pertisk_eproxy_admin_routes:management_dispatch()},
    try
        case cowboy_router:execute(Req0, Env) of
            {ok, Req1, #{handler := Handler, handler_opts := Opts}} ->
                case Handler of
                    cowboy_static ->
                        %% Should not match: /assets/* served above.
                        {error, unsupported};
                    _ ->
                        run_handler_init(Handler, Req1, Opts),
                        await_response()
                end;
            {stop, _ReqStop} ->
                await_response();
            {ok, _Req1, _Env} ->
                {error, unsupported}
        end
    catch
        Class:Reason:Stack ->
            lager:warning(
                "h3 local management dispatch failed: ~p:~p path=~s stack=~p",
                [Class, Reason, Path, Stack]
            ),
            {error, {Class, Reason}}
    after
        unlink(Stub),
        exit(Stub, kill)
    end.

run_handler_init(pertisk_eproxy_admin_handler, Req, Opts) ->
    _ = pertisk_eproxy_admin_handler:init(Req, Opts);
run_handler_init(pertisk_eproxy_spa_handler, Req, Opts) ->
    _ = pertisk_eproxy_spa_handler:init(Req, Opts);
run_handler_init(Handler, Req, Opts) ->
    lager:warning("h3 local management: unsupported handler ~p", [Handler]),
    _ = Handler:init(Req, Opts).

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
