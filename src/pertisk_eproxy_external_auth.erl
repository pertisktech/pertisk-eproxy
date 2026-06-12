%% @doc External authorization subrequest (nginx auth_request / Traefik forwardAuth style).
-module(pertisk_eproxy_external_auth).

-export([authorize/6]).

-define(TIMEOUT_MS, 5000).

%% @doc Returns `ok` or `{error, {auth_denied, Status}}` or `{error, auth_unreachable}`.
-spec authorize(
    binary(),
    binary(),
    binary(),
    binary(),
    map(),
    binary()
) -> ok | {error, {auth_denied, non_neg_integer()} | auth_unreachable}.
authorize(SiteHost, Method, Path, Qs, InHeaders, ClientIp) ->
    case pertisk_eproxy_config:site_auth_url(SiteHost) of
        undefined ->
            ok;
        AuthUrl ->
            do_auth(AuthUrl, Method, Path, Qs, InHeaders, ClientIp)
    end.

do_auth(AuthUrl, _Method, Path, Qs, InHeaders, ClientIp) ->
    FullPath = case Qs of
        <<>> -> Path;
        _ -> <<Path/binary, "?", Qs/binary>>
    end,
    Headers = auth_forward_headers(InHeaders, ClientIp, FullPath),
    case gun_open(AuthUrl) of
        {ok, Conn, _Host, _Port, _Transport, AuthPath} ->
            try
                StreamRef = gun:request(
                    Conn,
                    <<"GET">>,
                    AuthPath,
                    headers_list(Headers),
                    <<>>,
                    #{timeout => ?TIMEOUT_MS}
                ),
                case gun:await(Conn, StreamRef, ?TIMEOUT_MS) of
                    {response, fin, Status, _RespHeaders} when Status >= 200, Status =< 299 ->
                        ok;
                    {response, fin, Status, _RespHeaders} ->
                        {error, {auth_denied, Status}};
                    {response, nofin, Status, _RespHeaders} when Status >= 200, Status =< 299 ->
                        _ = gun:await_body(Conn, StreamRef, ?TIMEOUT_MS),
                        ok;
                    {response, nofin, Status, _RespHeaders} ->
                        _ = gun:await_body(Conn, StreamRef, ?TIMEOUT_MS),
                        {error, {auth_denied, Status}};
                    _ ->
                        {error, auth_unreachable}
                end
            after
                gun:close(Conn)
            end;
        {error, _} ->
            {error, auth_unreachable}
    end.

auth_forward_headers(InHeaders, ClientIp, FullPath) ->
    Base = maps:with(
        [<<"cookie">>, <<"authorization">>, <<"x-forwarded-proto">>, <<"host">>],
        InHeaders
    ),
    Base#{
        <<"x-forwarded-uri">> => FullPath,
        <<"x-forwarded-for">> => ClientIp,
        <<"x-original-url">> => FullPath
    }.

headers_list(Map) ->
    [{K, V} || {K, V} <- maps:to_list(Map), is_binary(K), is_binary(V)].

gun_open(Url) ->
    case parse_url(Url) of
        {ok, #{scheme := Scheme, host := Host, port := Port, path := PathPrefix}} ->
            Transport = case Scheme of
                <<"https">> -> tls;
                _ -> tcp
            end,
            Opts = #{
                protocols => [http],
                transport => Transport,
                tls_opts => [{verify, verify_none}],
                retry => 0
            },
            case gun:open(Host, Port, Opts) of
                {ok, Conn} ->
                    case gun:await_up(Conn, ?TIMEOUT_MS) of
                        {ok, _} -> {ok, Conn, Host, Port, Transport, PathPrefix};
                        _ -> {error, connect_failed}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        error ->
            {error, invalid_url}
    end.

parse_url(Url) when is_binary(Url) ->
    parse_url(binary_to_list(Url));
parse_url(Url) when is_list(Url) ->
    case uri_string:parse(Url) of
        #{scheme := Scheme, host := Host} = U ->
            Port = maps:get(port, U, default_port(Scheme)),
            Path = maps:get(path, U, <<"/">>),
            PathBin =
                case Path of
                    P when is_binary(P) -> P;
                    P when is_list(P) -> list_to_binary(P);
                    _ -> <<"/">>
                end,
            {ok, #{
                scheme => list_to_binary(Scheme),
                host => list_to_binary(Host),
                port => Port,
                path => PathBin
            }};
        _ ->
            error
    end.

default_port(<<"https">>) -> 443;
default_port(_) -> 80.
