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
    with_db_lock/1,
    put_config_retry/1,
    put_config_retry/2
]).

-define(DB_LOCK_KEY, pertisk_db_lock_depth).

ensure_lager() ->
    application:ensure_all_started(lager).

ensure_metrics() ->
    application:ensure_all_started(prometheus),
    pertisk_eproxy_metrics:setup().

ensure_config() ->
    ensure_lager(),
    case whereis(pertisk_eproxy_config) of
        undefined -> {ok, _} = pertisk_eproxy_config:start_link();
        _ -> ok
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
    filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "pertisk_db_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".db"
    ]).

%% Serialize SQLite mutations across eunit modules (reentrant within one process).
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
