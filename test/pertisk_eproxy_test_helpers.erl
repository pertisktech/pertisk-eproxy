%% Shared fixtures for eunit (config, metrics, router, backends).
-module(pertisk_eproxy_test_helpers).

-export([
    ensure_lager/0,
    ensure_metrics/0,
    ensure_config/0,
    ensure_h3_deps/0,
    ensure_h3_env/0,
    sync_router/2,
    sync_mgmt_site/1,
    start_backend/2,
    stop_backend/1,
    tmp_db/0,
    init_tmp_db/1,
    init_tmp_db/2,
    with_db_lock/1,
    with_h3_udp_bind/2,
    gateway_test_port/0,
    put_config_retry/1,
    put_config_retry/2,
    unload_mocks/1,
    unload_mocks/2,
    unload_mock/2,
    safe_gen_server_stop/1,
    safe_gen_server_stop/3,
    safe_exit/2,
    ignoring_errors/1
]).

-define(DB_LOCK_KEY, pertisk_db_lock_depth).
-define(MECK_UNLOAD_TIMEOUT_MS, 250).

ensure_lager() ->
    application:ensure_all_started(lager).

ensure_metrics() ->
    application:ensure_all_started(prometheus),
    pertisk_eproxy_metrics:setup().

-define(TEST_CONFIG_DB, {pertisk_eproxy, test_config_db}).

ensure_config() ->
    ensure_lager(),
    case whereis(pertisk_eproxy_config) of
        undefined ->
            os:putenv("PERTISK_MODE", "proxy"),
            application:unset_env(pertisk_eproxy, mode),
            DbPath =
                case persistent_term:get(?TEST_CONFIG_DB, undefined) of
                    undefined ->
                        P = tmp_db(),
                        persistent_term:put(?TEST_CONFIG_DB, P),
                        P;
                    P ->
                        P
                end,
            application:set_env(pertisk_eproxy, db_file, DbPath),
            {ok, _} = pertisk_eproxy_config:start_link();
        _ ->
            ok
    end.

ensure_h3_deps() ->
    application:ensure_all_started(quic),
    application:ensure_all_started(gun),
    ok.

ensure_h3_env() ->
    ensure_metrics(),
    ensure_config(),
    ensure_h3_deps().

sync_router(Sites, Backends) ->
    with_db_lock(fun() ->
        ensure_config(),
        pertisk_eproxy_config:sync_ingress(Sites, Backends)
    end).

%% Site on the in-process management backend (HTTP/3 local admin path).
sync_mgmt_site(Host) when is_binary(Host) ->
    Mgmt = pertisk_eproxy_config:management_loopback_upstream_bin(),
    Backend = #{
        name => <<"mgmt">>,
        algorithm => round_robin,
        upstreams => [#{addr => Mgmt, weight => 1}]
    },
    Site = #{host => Host, backend => <<"mgmt">>, routes => []},
    sync_router([Site], [Backend]).

start_backend(Name, Upstreams) ->
    Backend = #{
        name => Name,
        algorithm => round_robin,
        upstreams => Upstreams
    },
    pertisk_eproxy_backend:start_link(Backend).

stop_backend(Name) ->
    case pertisk_eproxy_backend:whereis(Name) of
        undefined -> ok;
        Pid -> exit(Pid, shutdown), ok
    end.

tmp_db() ->
    Pid =
        case os:getpid() of
            P when is_list(P) -> P;
            P when is_integer(P) -> integer_to_list(P);
            P -> lists:flatten(io_lib:format("~p", [P]))
        end,
    filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "pertisk_db_"
            ++ integer_to_list(erlang:unique_integer([positive, monotonic]))
            ++ "_"
            ++ Pid
            ++ ".db"
    ]).

%% Stable per-VM UDP/TCP port for H3 gateway tests (avoids parallel eaddrinuse).
gateway_test_port() ->
    16000 + (erlang:phash2({os:getpid(), node()}, 8000) rem 8000).

init_tmp_db(DbPath) ->
    init_tmp_db(DbPath, 24).

init_tmp_db(DbPath, Retries) ->
    init_tmp_db_unlocked(DbPath, Retries).

init_tmp_db_unlocked(DbPath, 0) ->
    pertisk_eproxy_db:init(DbPath);
init_tmp_db_unlocked(DbPath, Retries) ->
    case pertisk_eproxy_db:init(DbPath) of
        {ok, _} = Ok ->
            Ok;
        {error, Reason} when Retries > 0 ->
            case config_locked_error(Reason) of
                true ->
                    timer:sleep(50 + (24 - Retries) * 25),
                    init_tmp_db_unlocked(DbPath, Retries - 1);
                false ->
                    {error, Reason}
            end;
        Other ->
            Other
    end.

with_h3_udp_bind(BindMode, Fun) when BindMode =:= split; BindMode =:= dual_stack ->
    ensure_h3_env(),
    with_db_lock(fun() ->
        Config0 = pertisk_eproxy_config:get_config(),
        Config1 = Config0#{h3_udp_bind => BindMode},
        ok = put_config_retry(Config1),
        try Fun()
        after put_config_retry(Config0)
        end
    end).

%% Serialize SQLite mutations within one eunit VM (reentrant).
with_db_lock(Fun) ->
    case get(?DB_LOCK_KEY) of
        undefined ->
            global:trans(
                {pertisk_eproxy_test, db},
                fun() ->
                    put(?DB_LOCK_KEY, 1),
                    try Fun() after erase(?DB_LOCK_KEY) end
                end,
                [node()],
                infinity
            );
        N when is_integer(N) ->
            put(?DB_LOCK_KEY, N + 1),
            try Fun() after put(?DB_LOCK_KEY, N) end
    end.

put_config_retry(Config) ->
    with_db_lock(fun() -> put_config_retry_unlocked(Config, 12) end).

put_config_retry(Config, Retries) ->
    with_db_lock(fun() -> put_config_retry_unlocked(Config, Retries) end).

put_config_retry_unlocked(Config, 0) ->
    pertisk_eproxy_config:put_config(Config);
put_config_retry_unlocked(Config, Retries) ->
    case pertisk_eproxy_config:put_config(Config) of
        ok ->
            ok;
        {error, Reason} when Retries > 0 ->
            case config_locked_error(Reason) of
                true ->
                    timer:sleep(75),
                    put_config_retry_unlocked(Config, Retries - 1);
                false ->
                    {error, Reason}
            end;
        Other ->
            Other
    end.

config_locked_error({persist_runtime_config, Inner}) ->
    config_locked_error(Inner);
config_locked_error({persist_dns_providers, Inner}) ->
    config_locked_error(Inner);
config_locked_error({tls_validation_cert_store_unavailable, Inner}) ->
    config_locked_error(Inner);
config_locked_error({sqlite_error, Msg, _}) ->
    sqlite_locked_msg(Msg);
config_locked_error({sqlite_error, Msg}) when is_list(Msg) ->
    string:find(Msg, "locked") =/= nomatch;
config_locked_error({sqlite3_cli, Msg}) when is_list(Msg) ->
    string:find(Msg, "locked") =/= nomatch;
config_locked_error({sqlite3_cli, Msg}) when is_binary(Msg) ->
    sqlite_locked_msg(Msg);
config_locked_error(Msg) when is_binary(Msg) ->
    sqlite_locked_msg(Msg);
config_locked_error(Msg) when is_list(Msg) ->
    string:find(Msg, "locked") =/= nomatch;
config_locked_error(_) ->
    false.

sqlite_locked_msg(Msg) when is_binary(Msg) ->
    binary:match(Msg, <<"locked">>) =/= nomatch;
sqlite_locked_msg(Msg) when is_list(Msg) ->
    string:find(Msg, "locked") =/= nomatch;
sqlite_locked_msg(_) ->
    false.

unload_mocks(Mods) ->
    unload_mocks(Mods, ?MECK_UNLOAD_TIMEOUT_MS).

unload_mocks(Mods, TimeoutMs) when is_integer(TimeoutMs), TimeoutMs > 0 ->
    lists:foreach(fun(Mod) -> unload_mock(Mod, TimeoutMs) end, Mods).

unload_mock(Mod, TimeoutMs) ->
    case lists:member(Mod, meck:mocked()) of
        false ->
            ok;
        true ->
            case try meck:unload(Mod) catch _:_ -> {'EXIT', error} end of
                ok ->
                    ok;
                {'EXIT', _} ->
                    force_stop_meck(Mod),
                    ok;
                _ ->
                    Parent = self(),
                    Worker = spawn(fun() ->
                        Result =
                            try meck:unload(Mod)
                            catch _:_ -> error
                            end,
                        Parent ! {meck_unload_done, Mod, Result}
                    end),
                    receive
                        {meck_unload_done, Mod, ok} ->
                            ok;
                        {meck_unload_done, Mod, _} ->
                            force_stop_meck(Mod),
                            ok
                    after TimeoutMs ->
                        exit(Worker, kill),
                        force_stop_meck(Mod),
                        ok
                    end
            end
    end.

safe_gen_server_stop(Pid) ->
    safe_gen_server_stop(Pid, normal, 5000).

safe_gen_server_stop(Pid, Reason, Timeout) ->
    try gen_server:stop(Pid, Reason, Timeout)
    catch _:_ -> ok
    end.

safe_exit(Pid, Signal) ->
    try exit(Pid, Signal)
    catch _:_ -> ok
    end.

ignoring_errors(Fun) when is_function(Fun, 0) ->
    try Fun()
    catch _:_ -> ok
    end.

force_stop_meck(Mod) ->
    Name = meck_proc_name(Mod),
    case whereis(Name) of
        undefined ->
            ok;
        Pid when is_pid(Pid) ->
            safe_exit(Pid, kill),
            ok
    end.

meck_proc_name(Mod) ->
    list_to_atom(atom_to_list(Mod) ++ "_meck").
