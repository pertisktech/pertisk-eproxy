%%%-------------------------------------------------------------------
%% @doc Compression support for Brotli and Zstd
%% @end
%%%-------------------------------------------------------------------

-module(pertisk_eproxy_compression).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([compress/2, decompress/2, get_supported_methods/0]).

-define(SERVER, ?MODULE).
-define(DEFAULT_COMPRESSION_LEVEL, 6).
-define(BROTLI_QUALITY, 11).
-define(ZSTD_COMPRESSION_LEVEL, 19).

-record(state, {
    compression_methods = [brotli, zstd, gzip],
    cache = #{}
}).

%%%===================================================================
%% API functions
%%%===================================================================

-spec start_link() -> {ok, Pid} | {error, Reason}
    when Pid :: pid(),
         Reason :: term().
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec compress(Method, Data) -> {ok, CompressedData} | {error, Reason}
    when Method :: atom(),
         Data :: binary(),
         CompressedData :: binary(),
         Reason :: term().
compress(Method, Data) ->
    gen_server:call(?SERVER, {compress, Method, Data}).

-spec decompress(Method, Data) -> {ok, DecompressedData} | {error, Reason}
    when Method :: atom(),
         Data :: binary(),
         DecompressedData :: binary(),
         Reason :: term().
decompress(Method, Data) ->
    gen_server:call(?SERVER, {decompress, Method, Data}).

-spec get_supported_methods() -> [atom()].
get_supported_methods() ->
    gen_server:call(?SERVER, get_supported_methods).

%%%===================================================================
%% gen_server callbacks
%%%===================================================================

-spec init(Args) -> {ok, State}
    when Args :: term(),
         State :: #state{}.
init([]) ->
    io:format("Initializing compression module~n"),
    CompressionMethods = application:get_env(pertisk_eproxy, compression_methods, [brotli, zstd]),
    io:format("Available compression methods: ~p~n", [CompressionMethods]),
    {ok, #state{compression_methods = CompressionMethods}}.

-spec handle_call(Request, From, State) -> {reply, Reply, State}
    when Request :: term(),
         From :: {pid(), reference()},
         State :: #state{},
         Reply :: term().
handle_call({compress, Method, Data}, _From, State) ->
    Reply = do_compress(Method, Data),
    {reply, Reply, State};

handle_call({decompress, Method, Data}, _From, State) ->
    Reply = do_decompress(Method, Data),
    {reply, Reply, State};

handle_call(get_supported_methods, _From, State) ->
    {reply, State#state.compression_methods, State};

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
    io:format("Compression module terminated~n"),
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

-spec do_compress(Method, Data) -> {ok, CompressedData} | {error, Reason}
    when Method :: atom(),
         Data :: binary(),
         CompressedData :: binary(),
         Reason :: term().
do_compress(brotli, Data) ->
    try
        % Using brotli library
        % {ok, brotli:encode(Data, [{quality, ?BROTLI_QUALITY}])}
        % Placeholder implementation
        io:format("Compressing with brotli~n"),
        {ok, Data}
    catch
        _:Error ->
            {error, Error}
    end;

do_compress(zstd, Data) ->
    try
        % Using zstd library
        % {ok, zstd:compress(Data, ?ZSTD_COMPRESSION_LEVEL)}
        % Placeholder implementation
        io:format("Compressing with zstd~n"),
        {ok, Data}
    catch
        _:Error ->
            {error, Error}
    end;

do_compress(gzip, Data) ->
    try
        {ok, zlib:gzip(Data)}
    catch
        _:Error ->
            {error, Error}
    end;

do_compress(_Method, _Data) ->
    {error, unsupported_method}.

-spec do_decompress(Method, Data) -> {ok, DecompressedData} | {error, Reason}
    when Method :: atom(),
         Data :: binary(),
         DecompressedData :: binary(),
         Reason :: term().
do_decompress(brotli, Data) ->
    try
        % Using brotli library
        % {ok, brotli:decode(Data)}
        % Placeholder implementation
        io:format("Decompressing with brotli~n"),
        {ok, Data}
    catch
        _:Error ->
            {error, Error}
    end;

do_decompress(zstd, Data) ->
    try
        % Using zstd library
        % {ok, zstd:decompress(Data)}
        % Placeholder implementation
        io:format("Decompressing with zstd~n"),
        {ok, Data}
    catch
        _:Error ->
            {error, Error}
    end;

do_decompress(gzip, Data) ->
    try
        {ok, zlib:gunzip(Data)}
    catch
        _:Error ->
            {error, Error}
    end;

do_decompress(_Method, _Data) ->
    {error, unsupported_method}.

-spec select_encoding(AcceptEncoding) -> atom()
    when AcceptEncoding :: string() | binary().
select_encoding(AcceptEncoding) ->
    % Parse Accept-Encoding header and select best available method
    case re:split(AcceptEncoding, ",", [{return, binary}]) of
        [<<"br", _/binary>> | _] -> brotli;
        [<<"zstd", _/binary>> | _] -> zstd;
        [<<"gzip", _/binary>> | _] -> gzip;
        _ -> identity
    end.
