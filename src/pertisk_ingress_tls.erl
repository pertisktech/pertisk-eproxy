%% @doc In-memory TLS material synced from Kubernetes Secrets (SNI for proxy/H3).
-module(pertisk_ingress_tls).
-behaviour(gen_server).

-export([
    start_link/0,
    set_hosts/2,
    remove_hosts/1,
    clear/0,
    lookup/1,
    all_hosts/0,
    cert_ref/2,
    paths_for_host/1,
    decode_entry/1,
    write_pem_files/4
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, pertisk_ingress_tls_tab).
-define(SERVER, ?MODULE).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

set_hosts(Hosts, {CertPem, KeyPem}) when is_list(Hosts), is_binary(CertPem), is_binary(KeyPem) ->
    set_hosts(Hosts, CertPem, KeyPem, undefined, undefined).

set_hosts(Hosts, CertPem, KeyPem, CertPath, KeyPath)
    when is_list(Hosts), is_binary(CertPem), is_binary(KeyPem) ->
    gen_server:call(?SERVER, {set_hosts, Hosts, CertPem, KeyPem, CertPath, KeyPath}).

remove_hosts(Hosts) when is_list(Hosts) ->
    gen_server:call(?SERVER, {remove_hosts, Hosts}).

clear() ->
    gen_server:call(?SERVER, clear).

lookup(Host) ->
    case host_key(Host) of
        undefined -> error;
        Key ->
            case ets:lookup(?TAB, Key) of
                [{Key, Entry}] -> {ok, Entry};
                [] -> error
            end
    end.

paths_for_host(Host) ->
    case lookup(Host) of
        {ok, #{cert_path := CP, key_path := KP}} when CP =/= undefined, KP =/= undefined ->
            {ok, {CP, KP}};
        _ ->
            error
    end.

write_pem_files(Ns, Secret, CertPem, KeyPem) ->
    Dir = filename:join([
        pertisk_ingress_env:k8s_tls_dir(),
        binary_to_list(Ns),
        binary_to_list(Secret)
    ]),
    CertPath = filename:join(Dir, "tls.crt"),
    KeyPath = filename:join(Dir, "tls.key"),
    ok = filelib:ensure_dir(CertPath),
    ok = file:write_file(CertPath, CertPem),
    ok = file:write_file(KeyPath, KeyPem),
    _ = try file:change_mode(KeyPath, 8#600) catch _:_ -> ok end,
    {ok, {CertPath, KeyPath}}.

all_hosts() ->
    [H || {H, _} <- ets:tab2list(?TAB)].

%% Certificate reference stored on sites (for debugging / admin UI).
cert_ref(Namespace, SecretName) ->
    iolist_to_binary(["k8s/", Namespace, "/", SecretName]).

decode_entry(#{cert_pem := CertPem, key_pem := KeyPem}) ->
    decode_pem_pair(CertPem, KeyPem);
decode_entry(_) ->
    {error, invalid_entry}.

%% ---------------------------------------------------------------------------
%% gen_server
%% ---------------------------------------------------------------------------

init([]) ->
    _ = ets:new(?TAB, [named_table, protected, set, {read_concurrency, true}]),
    {ok, #{}}.

handle_call({set_hosts, Hosts, CertPem, KeyPem, CertPath, KeyPath}, _From, State) ->
    Entry = #{
        cert_pem => CertPem,
        key_pem => KeyPem,
        cert_path => CertPath,
        key_path => KeyPath
    },
    lists:foreach(
        fun(H) ->
            case host_key(H) of
                undefined -> ok;
                Key -> ets:insert(?TAB, {Key, Entry})
            end
        end,
        Hosts
    ),
    {reply, ok, State};

handle_call({remove_hosts, Hosts}, _From, State) ->
    lists:foreach(
        fun(H) ->
            case host_key(H) of
                undefined -> ok;
                Key -> ets:delete(?TAB, Key)
            end
        end,
        Hosts
    ),
    {reply, ok, State};

handle_call(clear, _From, State) ->
    ets:delete_all_objects(?TAB),
    {reply, ok, State};

handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

%% ---------------------------------------------------------------------------

host_key(undefined) -> undefined;
host_key(null) -> undefined;
host_key(H) when is_binary(H) ->
    Trim = re:replace(H, <<"^\\s+|\\s+$">>, <<>>, [{return, binary}, global]),
    case Trim of
        <<>> -> undefined;
        <<"*">> -> undefined;
        Other -> string:lowercase(binary_to_list(Other))
    end;
host_key(H) when is_list(H) ->
    host_key(list_to_binary(H));
host_key(_) ->
    undefined.

decode_pem_pair(CertPem, KeyPem) ->
    try
        CertDers = [
            D
         || {'Certificate', D, not_encrypted} <- public_key:pem_decode(CertPem)
        ],
        case CertDers of
            [] ->
                {error, invalid_cert_pem};
            [Leaf | Chain] ->
                [KeyEntry | _] = public_key:pem_decode(KeyPem),
                {ok, #{
                    cert => Leaf,
                    cert_chain => Chain,
                    private_key => public_key:pem_entry_decode(KeyEntry)
                }}
        end
    catch
        _:_ -> {error, invalid_tls_material}
    end.
