%% @doc In-memory ring buffer of recent proxy access events for the admin UI.

-module(pertisk_eproxy_access_log).
-behaviour(gen_server).

-export([start_link/0]).
-export([log_proxy/6, log_proxy/7, list/2, count/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(MAX, 1000).

-include_lib("lager/include/lager.hrl").

-record(st, {entries = [] :: [map()]}).

%% ---------------------------------------------------------------------------
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec log_proxy(binary(), binary(), binary(), integer(), non_neg_integer(), term()) -> ok.
log_proxy(Host, Method, Path, Status, DurationMs, ClientProto) ->
    log_proxy(Host, Method, Path, Status, DurationMs, ClientProto, <<>>).

-spec log_proxy(binary(), binary(), binary(), integer(), non_neg_integer(), term(), binary()) -> ok.
log_proxy(Host, Method, Path, Status, DurationMs, ClientProto, Upstream) ->
    gen_server:cast(?SERVER, {log, Host, Method, Path, Status, DurationMs, ClientProto, Upstream}).

-spec list(binary() | undefined, binary() | undefined) -> [map()].
list(Type, HostFilter) ->
    gen_server:call(?SERVER, {list, Type, HostFilter}).

-spec count() -> non_neg_integer().
count() ->
    gen_server:call(?SERVER, count).

%% ---------------------------------------------------------------------------
init([]) ->
    {ok, #st{}}.

handle_call({list, Type, HostFilter}, _From, #st{entries = Es} = St) ->
    Filtered = lists:filter(
        fun(E) ->
            T = maps:get(<<"type">>, E, <<"proxy">>),
            H = maps:get(<<"host">>, E, <<>>),
            TypeOk = case Type of
                undefined -> true;
                <<>> -> true;
                <<"all">> -> true;
                <<"proxy">> -> T =:= <<"proxy">> orelse T =:= <<"request">> orelse T =:= <<"response">>;
                <<"system">> -> T =:= <<"system">> orelse T =:= <<"error">>;
                _ -> true
            end,
            HostOk = case HostFilter of
                undefined -> true;
                <<>> -> true;
                HF -> binary:match(H, HF) =/= nomatch orelse H =:= HF
            end,
            TypeOk andalso HostOk
        end,
        Es
    ),
    {reply, lists:reverse(Filtered), St};

handle_call(count, _From, #st{entries = Es} = St) ->
    {reply, length(Es), St};

handle_call(_Req, _From, St) ->
    {reply, {error, unknown}, St}.

handle_cast({log, Host, Method, Path, Status, DurationMs, ClientProto, Upstream}, #st{entries = Es}) ->
    Ts = iolist_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second), [{offset, "Z"}])),
    Level = case Status of
        S when S >= 500 -> <<"error">>;
        S when S >= 400 -> <<"warn">>;
        _ -> <<"info">>
    end,
    ProtoShort = protocol_short(ClientProto),
    Msg = iolist_to_binary(io_lib:format("~s ~s ~w ~wms", [Method, Path, Status, DurationMs])),
    pertisk_eproxy_log:http(Level, ProtoShort, Host, Method, Path, Status, DurationMs),
    Base = #{
        <<"timestamp">> => Ts,
        <<"level">> => Level,
        <<"type">> => <<"proxy">>,
        <<"host">> => Host,
        <<"path">> => Path,
        <<"method">> => Method,
        <<"status">> => Status,
        <<"duration_ms">> => DurationMs,
        <<"message">> => Msg,
        <<"protocol">> => ProtoShort
    },
    Entry =
        case Upstream of
            U when is_binary(U), byte_size(U) > 0 -> Base#{<<"upstream">> => U};
            _ -> Base
        end,
    _ = catch pertisk_eproxy_couchdb_log:log(Entry),
    Es2 = trim([Entry | Es], ?MAX),
    {noreply, #st{entries = Es2}};

handle_cast(_Msg, St) ->
    {noreply, St}.

handle_info(_Info, St) ->
    {noreply, St}.

terminate(_Reason, _St) -> ok.
code_change(_OldVsn, St, _Extra) -> {ok, St}.

trim(L, Max) when length(L) =< Max -> L;
trim(L, Max) ->
    lists:sublist(L, Max).

protocol_short('HTTP/3') -> <<"3">>;
protocol_short('HTTP/2') -> <<"2">>;
protocol_short('HTTP/1.1') -> <<"1.1">>;
protocol_short('HTTP/1.0') -> <<"1.0">>;
protocol_short(_) -> <<"1.1">>.

