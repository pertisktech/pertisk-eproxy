%%%-------------------------------------------------------------------
%% @doc QUIC reverse proxy handler for HTTP/2 and HTTP/3
%% @end
%%%-------------------------------------------------------------------

-module(pertisk_eproxy_proxy).
-behaviour(gen_server).

-export([start_link/0, get_upstream/1, h3_handler/5]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(DEFAULT_LISTEN_IP, "any").
-define(DEFAULT_LISTEN_PORT_HTTP, 80).
-define(DEFAULT_LISTEN_PORT_HTTPS, 443).
-define(DEFAULT_LISTEN_PORT_H3, 443).
-define(DEFAULT_TLS_CERTFILE, "tls/dev-cert.pem").
-define(DEFAULT_TLS_KEYFILE, "tls/dev-key.pem").
-define(DEFAULT_H3_TLS_CERTFILE, "tls/dev-cert.pem").
-define(DEFAULT_H3_TLS_KEYFILE, "tls/dev-key.pem").
-define(H3_SERVER_NAME_V4, pertisk_eproxy_h3_server_v4).
-define(H3_SERVER_NAME_V6, pertisk_eproxy_h3_server_v6).

-record(state, {
    h3_listeners = [],
    upstream_cache = #{}
}).

%%%===================================================================
%% API functions
%%%===================================================================

-spec start_link() -> {ok, Pid} | {error, Reason}
    when Pid :: pid(),
         Reason :: term().
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec get_upstream(binary()) -> {ok, map()} | {error, not_found}.
get_upstream(Host) ->
    gen_server:call(?SERVER, {get_upstream, Host}).

%%%===================================================================
%% gen_server callbacks
%%%===================================================================

-spec init(Args) -> {ok, State}
    when Args :: term(),
         State :: #state{}.
init([]) ->
    io:format("Initializing reverse proxy handler~n"),

    ListenIP = application:get_env(pertisk_eproxy, listen_addr, ?DEFAULT_LISTEN_IP),
    HttpPort = application:get_env(pertisk_eproxy, listen_port_http, ?DEFAULT_LISTEN_PORT_HTTP),
    HttpsPort = application:get_env(pertisk_eproxy, listen_port_https, ?DEFAULT_LISTEN_PORT_HTTPS),
    H3Port = application:get_env(pertisk_eproxy, listen_port_h3, ?DEFAULT_LISTEN_PORT_H3),

    case start_proxy_listeners(ListenIP, HttpPort, HttpsPort, H3Port) of
        {ok, Listeners} ->
            io:format("Started reverse proxy on ~s:~w/http, ~s:~w/https, ~s:~w/udp~n",
                      [ListenIP, HttpPort, ListenIP, HttpsPort, ListenIP, H3Port]),
            {ok, #state{h3_listeners = Listeners}};
        {error, Reason} ->
            io:format("Failed to start reverse proxy listeners: ~p~n", [Reason]),
            case Reason of
                {http_listener_failed, {http_ipv4_listener_failed, eaddrinuse}} ->
                    io:format("Port ~w already in use for HTTP IPv4. Use: lsof -nP -iTCP:~w and stop the owning process.~n",
                              [HttpPort, HttpPort]);
                {https_listener_failed, {https_ipv4_listener_failed, eaddrinuse}} ->
                    io:format("Port ~w already in use for HTTPS IPv4. Use: lsof -nP -iTCP:~w and stop the owning process.~n",
                              [HttpsPort, HttpsPort]);
                _ ->
                    ok
            end,
            {stop, {listener_start_failed, Reason}}
    end.

-spec handle_call(Request, From, State) -> {reply, Reply, State} | {noreply, State}
    when Request :: term(),
         From :: {pid(), reference()},
         State :: #state{},
         Reply :: term().
handle_call({get_upstream, Host}, _From, State) ->
    Upstreams = pertisk_eproxy_admin:list_upstreams(),
    Reply = case lists:keyfind(Host, 1, Upstreams) of
        {Host, Upstream} -> {ok, normalize_upstream(Upstream)};
        false -> {error, not_found}
    end,
    {reply, Reply, State};

handle_call({set_upstream, Host, Upstream}, _From, State) ->
    NewState = State#state{
        upstream_cache = maps:put(Host, Upstream, State#state.upstream_cache)
    },
    {reply, ok, NewState};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-spec handle_cast(Request, State) -> {noreply, State}
    when Request :: term(),
         State :: #state{}.
handle_cast(_Request, State) ->
    {noreply, State}.

-spec handle_info(Info, State) -> {noreply, State}
    when Info :: term(),
         State :: #state{}.
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(Reason, State) -> ok
    when Reason :: term(),
         State :: #state{}.
terminate(_Reason, _State) ->
    lists:foreach(fun stop_h3_listener/1, _State#state.h3_listeners),
    io:format("QUIC proxy handler terminated~n"),
    ok.

-spec code_change(OldVsn, State, Extra) -> {ok, NewState}
    when OldVsn :: term(),
         State :: #state{},
         Extra :: term(),
         NewState :: #state{}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%% Internal functions
%%%===================================================================

-spec start_proxy_listeners(IP, HttpPort, HttpsPort, H3Port) -> {ok, Listeners} | {error, Reason}
    when IP :: string(),
         HttpPort :: integer(),
         HttpsPort :: integer(),
         H3Port :: integer(),
         Listeners :: list(),
         Reason :: term().
start_proxy_listeners(IP, HttpPort, HttpsPort, H3Port) ->
    HttpDispatch = cowboy_router:compile([
        {'_', [
            {"/[...]", pertisk_eproxy_redirect_handler, #{https_port => HttpsPort}}
        ]}
    ]),
    HttpsDispatch = cowboy_router:compile([
        {'_', [
            {"/[...]", pertisk_eproxy_proxy_handler, []}
        ]}
    ]),
    ListenOptions = [
        {port, H3Port},
        {alpn, ["h3"]},
        {max_idle_timeout, 30000},
        {stream_recv_buffer_default, 2097152}  % 2MB default
    ],

    case ensure_tls_files() of
        ok ->
            case start_http_listener(IP, HttpPort, HttpDispatch) of
                ok ->
                    case start_https_listener(IP, HttpsPort, HttpsDispatch) of
                        ok ->
                            case open_h3_listeners(IP, H3Port) of
                                {ok, Sockets} ->
                                    io:format("Started HTTP/3 listener(s) on ~s:~w~n", [IP, H3Port]),
                                    io:format("Configure options: ~p~n", [ListenOptions]),
                                    {ok, Sockets};
                                {error, Reason} ->
                                    {error, {h3_listener_failed, Reason}}
                            end;
                        {error, Reason} ->
                            {error, {https_listener_failed, Reason}}
                    end;
                {error, Reason} ->
                    {error, {http_listener_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {tls_check_failed, Reason}}
    end.

-spec start_http_listener(string(), integer(), cowboy_router:dispatch_rules()) -> ok | {error, term()}.
start_http_listener("any", Port, Dispatch) ->
    start_http_listener_all_families(Port, Dispatch);
start_http_listener("*", Port, Dispatch) ->
    start_http_listener_all_families(Port, Dispatch);
start_http_listener(IP, Port, Dispatch) ->
    case inet:parse_address(IP) of
        {ok, ParsedIP} when tuple_size(ParsedIP) =:= 4 ->
            start_http_listener_named(proxy_http_listener_v4, [{ip, ParsedIP}, {port, Port}], Dispatch);
        {ok, ParsedIP} when tuple_size(ParsedIP) =:= 8 ->
            start_http_listener_named(proxy_http_listener_v6, [inet6, {ip, ParsedIP}, {port, Port}], Dispatch);
        {error, Reason} ->
            {error, Reason}
    end.

-spec start_http_listener_all_families(integer(), cowboy_router:dispatch_rules()) -> ok | {error, term()}.
start_http_listener_all_families(Port, Dispatch) ->
    case start_http_listener_named(proxy_http_listener_v4, [{ip, {0, 0, 0, 0}}, {port, Port}], Dispatch) of
        ok ->
            case start_http_listener_named(proxy_http_listener_v6, [inet6, {ip, {0, 0, 0, 0, 0, 0, 0, 0}}, {port, Port}], Dispatch) of
                ok -> ok;
                {error, Reason} -> {error, {http_ipv6_listener_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {http_ipv4_listener_failed, Reason}}
    end.

-spec start_http_listener_named(atom(), list(), cowboy_router:dispatch_rules()) -> ok | {error, term()}.
start_http_listener_named(Name, TransportOptions, Dispatch) ->
    case cowboy:start_clear(Name, TransportOptions, #{env => #{dispatch => Dispatch}}) of
        {ok, _Pid} -> ok;
        {error, Reason} -> {error, Reason}
    end.

-spec start_https_listener(string(), integer(), cowboy_router:dispatch_rules()) -> ok | {error, term()}.
start_https_listener("any", Port, Dispatch) ->
    start_https_listener_all_families(Port, Dispatch);
start_https_listener("*", Port, Dispatch) ->
    start_https_listener_all_families(Port, Dispatch);
start_https_listener(IP, Port, Dispatch) ->
    case inet:parse_address(IP) of
        {ok, ParsedIP} when tuple_size(ParsedIP) =:= 4 ->
            start_https_listener_named(proxy_https_listener_v4, [{ip, ParsedIP}, {port, Port}], Dispatch);
        {ok, ParsedIP} when tuple_size(ParsedIP) =:= 8 ->
            start_https_listener_named(proxy_https_listener_v6, [inet6, {ip, ParsedIP}, {port, Port}], Dispatch);
        {error, Reason} ->
            {error, Reason}
    end.

-spec start_https_listener_all_families(integer(), cowboy_router:dispatch_rules()) -> ok | {error, term()}.
start_https_listener_all_families(Port, Dispatch) ->
    case start_https_listener_named(proxy_https_listener_v4, [{ip, {0, 0, 0, 0}}, {port, Port}], Dispatch) of
        ok ->
            case start_https_listener_named(proxy_https_listener_v6, [inet6, {ip, {0, 0, 0, 0, 0, 0, 0, 0}}, {port, Port}], Dispatch) of
                ok -> ok;
                {error, Reason} -> {error, {https_ipv6_listener_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {https_ipv4_listener_failed, Reason}}
    end.

-spec start_https_listener_named(atom(), list(), cowboy_router:dispatch_rules()) -> ok | {error, term()}.
start_https_listener_named(Name, TransportOptions, Dispatch) ->
    CertFile = application:get_env(pertisk_eproxy, tls_certfile, ?DEFAULT_TLS_CERTFILE),
    KeyFile = application:get_env(pertisk_eproxy, tls_keyfile, ?DEFAULT_TLS_KEYFILE),
    case cowboy:start_tls(Name, TransportOptions ++ [
        {certfile, CertFile},
        {keyfile, KeyFile}
    ], #{env => #{dispatch => Dispatch}}) of
        {ok, _Pid} -> ok;
        {error, Reason} -> {error, Reason}
    end.

-spec open_h3_listeners(string(), integer()) -> {ok, [port()]} | {error, term()}.
open_h3_listeners("any", Port) ->
    case try_start_h3_server(Port) of
        {ok, ServerNames} ->
            {ok, ServerNames};
        {error, Reason} ->
            io:format("HTTP/3 server unavailable (~p), falling back to UDP reservation~n", [Reason]),
            open_h3_listeners_for_all_families(Port)
    end;
open_h3_listeners("*", Port) ->
    open_h3_listeners("any", Port);
open_h3_listeners(IP, Port) ->
    case try_start_h3_server(Port) of
        {ok, ServerNames} ->
            {ok, ServerNames};
        {error, Reason} ->
            io:format("HTTP/3 server unavailable (~p), falling back to UDP reservation~n", [Reason]),
            case inet:parse_address(IP) of
                {ok, ParsedIP} when tuple_size(ParsedIP) =:= 4 ->
                    open_udp_socket(Port, [{ip, ParsedIP}]);
                {ok, ParsedIP} when tuple_size(ParsedIP) =:= 8 ->
                    open_udp_socket(Port, [inet6, {ip, ParsedIP}]);
                {error, ParseReason} ->
                    {error, ParseReason}
            end
    end.

-spec try_start_h3_server(integer()) -> {ok, started} | {error, term()}.
try_start_h3_server(Port) ->
    case code:ensure_loaded(quic_h3) of
        {module, quic_h3} ->
            case application:ensure_all_started(quic) of
                {ok, _StartedApps} ->
                    CertFile = application:get_env(
                        pertisk_eproxy,
                        h3_tls_certfile,
                        ?DEFAULT_H3_TLS_CERTFILE
                    ),
                    KeyFile = application:get_env(
                        pertisk_eproxy,
                        h3_tls_keyfile,
                        ?DEFAULT_H3_TLS_KEYFILE
                    ),
                    case {file:read_file(CertFile), file:read_file(KeyFile)} of
                        {{ok, CertPem}, {ok, KeyPem}} ->
                            case decode_quic_credentials(CertPem, KeyPem) of
                                {ok, Cert, CertChain, Key} ->
                                    case start_h3_dual_listeners(Port, Cert, CertChain, Key) of
                                        {ok, StartedServers} ->
                                            {ok, StartedServers};
                                        {error, Reason} ->
                                            {error, Reason}
                                    end;
                                {error, DecodeReason} ->
                                    {error, {quic_tls_decode_failed, DecodeReason}}
                            end;
                        {CertResult, KeyResult} ->
                            {error, {tls_read_failed, CertResult, KeyResult}}
                    end;
                {error, Reason} ->
                    {error, {quic_start_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {quic_h3_not_available, Reason}}
    end.

-spec start_h3_dual_listeners(integer(), binary(), [binary()], term()) -> {ok, [atom()]} | {error, term()}.
start_h3_dual_listeners(Port, Cert, CertChain, Key) ->
    stop_h3_listener(?H3_SERVER_NAME_V4),
    stop_h3_listener(?H3_SERVER_NAME_V6),
    case start_h3_server_family(?H3_SERVER_NAME_V4, Port, inet, [], Cert, CertChain, Key) of
        {ok, _PidV4} ->
            case start_h3_server_family(
                ?H3_SERVER_NAME_V6, Port, inet6, [{ipv6_v6only, true}], Cert, CertChain, Key
            ) of
                {ok, _PidV6} ->
                    {ok, [?H3_SERVER_NAME_V4, ?H3_SERVER_NAME_V6]};
                {error, ReasonV6} ->
                    stop_h3_listener(?H3_SERVER_NAME_V4),
                    {error, {quic_h3_v6_start_failed, ReasonV6}}
            end;
        {error, ReasonV4} ->
            {error, {quic_h3_v4_start_failed, ReasonV4}}
    end.

-spec start_h3_server_family(atom(), integer(), inet | inet6, list(), binary(), [binary()], term()) ->
    {ok, pid()} | {error, term()}.
start_h3_server_family(ServerName, Port, Family, ExtraSocketOpts, Cert, CertChain, Key) ->
    quic_h3:start_server(ServerName, Port, #{
        cert => Cert,
        key => Key,
        alpn => [<<"h3">>],
        quic_opts => #{
            family => Family,
            cert_chain => CertChain,
            extra_socket_opts => ExtraSocketOpts
        },
        handler => fun ?MODULE:h3_handler/5
    }).

-spec stop_h3_listener(term()) -> ok.
stop_h3_listener(Listener) when is_atom(Listener) ->
    catch quic_h3:stop_server(Listener),
    ok;
stop_h3_listener(Listener) when is_port(Listener) ->
    catch gen_udp:close(Listener),
    ok;
stop_h3_listener(_) ->
    ok.

-spec decode_quic_credentials(binary(), binary()) -> {ok, binary(), [binary()], term()} | {error, term()}.
decode_quic_credentials(CertPem, KeyPem) ->
    try
        CertEntries = public_key:pem_decode(CertPem),
        Certs = [Der || {_Type, Der, _NotEncrypted} <- CertEntries],
        KeyEntries = public_key:pem_decode(KeyPem),
        case {Certs, KeyEntries} of
            {[LeafCert | CertChain], [KeyEntry | _]} ->
                Key = public_key:pem_entry_decode(KeyEntry),
                {ok, LeafCert, CertChain, Key};
            {[], _} ->
                {error, no_cert_entries};
            {_, []} ->
                {error, no_key_entries}
        end
    catch
        _:Reason ->
            {error, Reason}
    end.

-spec h3_handler(pid(), non_neg_integer(), binary(), binary(), list()) -> any().
h3_handler(Conn, StreamId, <<"GET">>, Path, _Headers) ->
    Body = <<"pertisk-eproxy http/3 ok path=", Path/binary>>,
    send_h3_response(Conn, StreamId, 200, Body);
h3_handler(Conn, StreamId, _Method, _Path, _Headers) ->
    send_h3_response(Conn, StreamId, 405, <<"method not allowed">>).

-spec send_h3_response(pid(), non_neg_integer(), non_neg_integer(), binary()) -> ok.
send_h3_response(Conn, StreamId, Status, Body) ->
    Headers = [
        {<<"content-type">>, <<"text/plain">>}
    ],
    case quic_h3:send_response(Conn, StreamId, Status, Headers) of
        ok ->
            case quic_h3:send_data(Conn, StreamId, Body, true) of
                ok -> ok;
                {error, Reason} ->
                    io:format("h3 send_data failed: ~p~n", [Reason]),
                    ok
            end;
        {error, Reason} ->
            io:format("h3 send_response failed: ~p~n", [Reason]),
            ok
    end.

-spec open_h3_listeners_for_all_families(integer()) -> {ok, [port()]} | {error, term()}.
open_h3_listeners_for_all_families(Port) ->
    case open_udp_socket(Port, [{ip, {0, 0, 0, 0}}]) of
        {ok, [SocketV4]} ->
            case open_udp_socket(Port, [inet6, {ip, {0, 0, 0, 0, 0, 0, 0, 0}}]) of
                {ok, [SocketV6]} ->
                    {ok, [SocketV4, SocketV6]};
                {error, Reason} ->
                    gen_udp:close(SocketV4),
                    {error, {ipv6_open_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {ipv4_open_failed, Reason}}
    end.

-spec open_udp_socket(integer(), list()) -> {ok, [port()]} | {error, term()}.
open_udp_socket(Port, ExtraOptions) ->
    BaseOptions = [binary, {active, false}, {reuseaddr, true}],
    case gen_udp:open(Port, BaseOptions ++ ExtraOptions) of
        {ok, Socket} ->
            {ok, [Socket]};
        {error, Reason} ->
            {error, Reason}
    end.

-spec ensure_tls_files() -> ok | {error, term()}.
ensure_tls_files() ->
    CertFile = application:get_env(pertisk_eproxy, tls_certfile, ?DEFAULT_TLS_CERTFILE),
    KeyFile = application:get_env(pertisk_eproxy, tls_keyfile, ?DEFAULT_TLS_KEYFILE),
    case filelib:is_regular(CertFile) andalso filelib:is_regular(KeyFile) of
        true -> ok;
        false -> {error, {missing_tls_files, #{certfile => CertFile, keyfile => KeyFile}}}
    end.

-spec normalize_upstream(map()) -> map().
normalize_upstream(Upstream) ->
    # {
        target => maps:get(<<"target">>, Upstream, maps:get(target, Upstream, <<>>)),
        health_check => maps:get(<<"health_check">>, Upstream, maps:get(health_check, Upstream, <<>>)),
        weight => maps:get(<<"weight">>, Upstream, maps:get(weight, Upstream, 1))
    }.
