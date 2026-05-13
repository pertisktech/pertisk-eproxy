%% @doc Behaviour and facade for HTTP/3 edge transport.
%%
%% Default implementation is {@link pertisk_h3_transport_erlang_quic} (benoitc/erlang_quic).
%% {@link pertisk_h3_transport_quicer_stub} is a placeholder until msquic/Quicer exposes
%% an HTTP/3 server API compatible with this proxy.
-module(pertisk_h3_transport).

-export([active_module/0]).
-export([
    ensure_deps_started/0,
    start_server/3,
    stop_server/1,
    send_response/4,
    send_data/4,
    set_stream_handler/3,
    collect_request_body/4,
    collect_request_body/5,
    client_peer_ip/2
]).

-type h3_conn() :: term().
-type stream_id() :: term().

-callback ensure_deps_started() -> ok.

-callback start_server(Name :: atom(), Port :: inet:port_number(), Opts :: map()) ->
    {ok, pid()} | {error, term()}.

-callback stop_server(Name :: atom()) -> ok | {error, term()}.

-callback send_response(
    Conn :: h3_conn(),
    StreamId :: stream_id(),
    Status :: pos_integer(),
    Headers :: [{binary(), binary()}]
) -> ok | {error, term()}.

-callback send_data(
    Conn :: h3_conn(),
    StreamId :: stream_id(),
    Data :: iodata(),
    Fin :: boolean()
) -> ok | {error, term()}.

-callback set_stream_handler(Conn :: h3_conn(), StreamId :: stream_id(), HandlerPid :: pid()) ->
    ok | {ok, list()} | {error, term()}.

-callback collect_request_body(
    Conn :: h3_conn(),
    StreamId :: stream_id(),
    Acc :: binary(),
    TimeoutMs :: non_neg_integer()
) -> binary().

-callback collect_request_body(
    Conn :: h3_conn(),
    StreamId :: stream_id(),
    Acc :: binary(),
    TimeoutMs :: non_neg_integer(),
    ExpectCL :: undefined | non_neg_integer()
) -> binary().

-callback client_peer_ip(Conn :: h3_conn(), Headers :: [{binary(), binary()}]) -> binary().

%% @doc Resolve implementation module from `{@link application:get_env/2}` {@code pertisk_eproxy, h3_transport}.
%%
%% Values:
%% <ul>
%%   <li>{@code erlang_quic} — default, {@link pertisk_h3_transport_erlang_quic}</li>
%%   <li>{@code quicer} — {@link pertisk_h3_transport_quicer_stub} (not production-ready)</li>
%%   <li>{@code Module} — any module implementing this behaviour</li>
%% </ul>
-spec active_module() -> module().
active_module() ->
    case application:get_env(pertisk_eproxy, h3_transport) of
        {ok, quicer} ->
            pertisk_h3_transport_quicer_stub;
        {ok, erlang_quic} ->
            pertisk_h3_transport_erlang_quic;
        {ok, Mod} when is_atom(Mod) ->
            Mod;
        undefined ->
            pertisk_h3_transport_erlang_quic;
        _ ->
            pertisk_h3_transport_erlang_quic
    end.

-spec ensure_deps_started() -> ok.
ensure_deps_started() ->
    (active_module()):ensure_deps_started().

-spec start_server(atom(), inet:port_number(), map()) -> {ok, pid()} | {error, term()}.
start_server(Name, Port, Opts) ->
    (active_module()):start_server(Name, Port, Opts).

-spec stop_server(atom()) -> ok | {error, term()}.
stop_server(Name) ->
    (active_module()):stop_server(Name).

-spec send_response(h3_conn(), stream_id(), pos_integer(), [{binary(), binary()}]) ->
    ok | {error, term()}.
send_response(Conn, StreamId, Status, Headers) ->
    (active_module()):send_response(Conn, StreamId, Status, Headers).

-spec send_data(h3_conn(), stream_id(), iodata(), boolean()) -> ok | {error, term()}.
send_data(Conn, StreamId, Data, Fin) ->
    (active_module()):send_data(Conn, StreamId, Data, Fin).

-spec set_stream_handler(h3_conn(), stream_id(), pid()) -> ok | {ok, list()} | {error, term()}.
set_stream_handler(Conn, StreamId, HandlerPid) ->
    (active_module()):set_stream_handler(Conn, StreamId, HandlerPid).

-spec collect_request_body(h3_conn(), stream_id(), binary(), non_neg_integer()) -> binary().
collect_request_body(Conn, StreamId, Acc, TimeoutMs) ->
    (active_module()):collect_request_body(Conn, StreamId, Acc, TimeoutMs).

-spec collect_request_body(
    h3_conn(), stream_id(), binary(), non_neg_integer(), undefined | non_neg_integer()
) -> binary().
collect_request_body(Conn, StreamId, Acc, TimeoutMs, ExpectCL) ->
    (active_module()):collect_request_body(Conn, StreamId, Acc, TimeoutMs, ExpectCL).

-spec client_peer_ip(h3_conn(), [{binary(), binary()}]) -> binary().
client_peer_ip(Conn, Headers) ->
    (active_module()):client_peer_ip(Conn, Headers).
