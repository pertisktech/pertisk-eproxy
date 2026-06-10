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
    tmp_db/0
]).

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
    ensure_config(),
    pertisk_eproxy_config:sync_ingress(Sites, Backends).

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
