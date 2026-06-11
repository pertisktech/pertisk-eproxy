-module(pertisk_eproxy_h3_local_admin_tests).

-include_lib("eunit/include/eunit.hrl").

dispatch(Args) ->
    apply(pertisk_eproxy_h3_local_admin, try_dispatch, Args).

ensure_env() ->
    pertisk_eproxy_test_helpers:ensure_h3_env().

%% Fast API paths (no Cowboy stub)
ingress_live_get_test() ->
    ensure_env(),
    {ok, 200, Hdrs, Body} =
        dispatch([<<"GET">>, <<"localhost">>, <<"/api/ingress/live">>, <<>>, [], <<>>, <<"127.0.0.1">>]),
    ?assertEqual(<<"application/json">>, proplists:get_value(<<"content-type">>, Hdrs)),
    ?assertEqual(<<"{\"status\":\"ok\"}">>, Body).

ingress_live_head_test() ->
    ensure_env(),
    {ok, 200, _, <<>>} =
        dispatch([<<"HEAD">>, <<"localhost">>, <<"/api/ingress/live">>, <<>>, [], <<>>, <<"127.0.0.1">>]).

health_get_test() ->
    ensure_env(),
    {ok, 200, Hdrs, Body} =
        dispatch([<<"GET">>, <<"localhost">>, <<"/api/health">>, <<>>, [], <<>>, <<"127.0.0.1">>]),
    ?assertEqual(<<"application/json">>, proplists:get_value(<<"content-type">>, Hdrs)),
    ?assert(byte_size(Body) > 0).

health_head_test() ->
    ensure_env(),
    {ok, 200, _, <<>>} =
        dispatch([<<"HEAD">>, <<"localhost">>, <<"/api/health">>, <<>>, [], <<>>, <<"127.0.0.1">>]).

realtime_sse_unsupported_test() ->
    ensure_env(),
    ?assertEqual(
        {error, unsupported},
        dispatch([<<"GET">>, <<"localhost">>, <<"/api/realtime-sse">>, <<>>, [], <<>>, <<"127.0.0.1">>])
    ).

favicon_svg_test() ->
    ensure_env(),
    {ok, 200, Hdrs, Body} =
        dispatch([<<"GET">>, <<"example.com">>, <<"/favicon.svg">>, <<>>, [], <<>>, <<"127.0.0.1">>]),
    ?assertEqual(<<"image/svg+xml">>, proplists:get_value(<<"content-type">>, Hdrs)),
    ?assert(byte_size(Body) > 0).

spa_index_test() ->
    ensure_env(),
    {ok, 200, Hdrs, Body} =
        dispatch([<<"GET">>, <<"example.com">>, <<"/">>, <<>>, [], <<>>, <<"127.0.0.1">>]),
    ?assertEqual(<<"text/html; charset=utf-8">>, proplists:get_value(<<"content-type">>, Hdrs)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"<html">>)).

spa_head_test() ->
    ensure_env(),
    {ok, 200, Hdrs, <<>>} =
        dispatch([<<"HEAD">>, <<"example.com">>, <<"/sites">>, <<>>, [], <<>>, <<"127.0.0.1">>]),
    ?assertEqual(<<"text/html; charset=utf-8">>, proplists:get_value(<<"content-type">>, Hdrs)).

static_asset_test() ->
    ensure_env(),
  case filelib:wildcard(filename:join([code:priv_dir(pertisk_eproxy), "admin", "assets", "*.js"])) of
        [Js | _] ->
            Base = filename:basename(Js),
            Path = <<"/assets/", (list_to_binary(Base))/binary>>,
            {ok, 200, Hdrs, Body} =
                dispatch([<<"GET">>, <<"example.com">>, Path, <<>>, [], <<>>, <<"127.0.0.1">>]),
            ?assertEqual(<<"application/javascript">>, proplists:get_value(<<"content-type">>, Hdrs)),
            ?assert(byte_size(Body) > 0);
        [] ->
            ok
    end.

dot_segment_asset_falls_back_to_spa_test() ->
    ensure_env(),
    with_spa_index(fun() ->
        {ok, 200, Hdrs, _} =
            dispatch([<<"GET">>, <<"example.com">>, <<"/assets/.">>, <<>>, [], <<>>, <<"127.0.0.1">>]),
        ?assertEqual(<<"text/html; charset=utf-8">>, proplists:get_value(<<"content-type">>, Hdrs))
    end).

api_version_get_test() ->
    ensure_env(),
    {ok, 200, Hdrs, Body} =
        dispatch([<<"GET">>, <<"localhost">>, <<"/api/version">>, <<>>, [], <<>>, <<"127.0.0.1">>]),
    ?assertEqual(<<"application/json">>, proplists:get_value(<<"content-type">>, Hdrs)),
    ?assert(byte_size(Body) > 0).

api_version_head_test() ->
    ensure_env(),
    {ok, 200, Hdrs, <<>>} =
        dispatch([<<"HEAD">>, <<"localhost">>, <<"/api/version">>, <<>>, [], <<>>, <<"127.0.0.1">>]),
    ?assertEqual(<<"application/json">>, proplists:get_value(<<"content-type">>, Hdrs)).

api_proto_get_test() ->
    ensure_env(),
    {ok, 200, _, Body} =
        dispatch([<<"GET">>, <<"localhost">>, <<"/api/proto">>, <<>>, [], <<>>, <<"127.0.0.1">>]),
    ?assert(byte_size(Body) > 0).

api_auth_config_get_test() ->
    ensure_env(),
    {ok, 200, _, Body} =
        dispatch([<<"GET">>, <<"localhost">>, <<"/api/auth/config">>, <<>>, [], <<>>, <<"127.0.0.1">>]),
    {ok, Map} = thoas:decode(Body),
    ?assert(maps:is_key(<<"mode">>, Map)).

api_auth_check_get_test() ->
    ensure_env(),
    {ok, 200, _, Body} =
        dispatch([<<"GET">>, <<"localhost">>, <<"/api/auth/check">>, <<>>, [], <<>>, <<"127.0.0.1">>]),
    {ok, _} = thoas:decode(Body).

api_ingress_ready_get_test() ->
    ensure_env(),
    {ok, 200, _, _} =
        dispatch([<<"GET">>, <<"localhost">>, <<"/api/ingress/ready">>, <<>>, [], <<>>, <<"127.0.0.1">>]).

api_metrics_get_test() ->
    ensure_env(),
    {ok, 200, _, _} =
        dispatch([<<"GET">>, <<"localhost">>, <<"/api/metrics">>, <<>>, [], <<>>, <<"127.0.0.1">>]).

auth_logout_post_test() ->
    ensure_env(),
    {ok, _, _, _} =
        dispatch([<<"POST">>, <<"localhost">>, <<"/api/auth/logout">>, <<>>, [], <<>>, <<"127.0.0.1">>]).

static_css_head_test() ->
    ensure_env(),
    case filelib:wildcard(filename:join([code:priv_dir(pertisk_eproxy), "admin", "assets", "*.css"])) of
        [Css | _] ->
            Base = filename:basename(Css),
            Path = <<"/assets/", (list_to_binary(Base))/binary>>,
            {ok, 200, Hdrs, <<>>} =
                dispatch([<<"HEAD">>, <<"example.com">>, Path, <<>>, [], <<>>, <<"127.0.0.1">>]),
            ?assertEqual(<<"text/css; charset=utf-8">>, proplists:get_value(<<"content-type">>, Hdrs));
        [] ->
            ok
    end.

spa_index_path() ->
    filename:join([code:priv_dir(pertisk_eproxy), "admin", "index.html"]).

with_spa_index(Fun) ->
    Path = spa_index_path(),
    Previous =
        case file:read_file(Path) of
            {ok, Bin} -> {ok, Bin};
            {error, enoent} -> undefined;
            {error, _} -> undefined
        end,
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, <<"<html><body>spa</body></html>">>),
    try
        Fun()
    after
        case Previous of
            undefined -> _ = file:delete(Path);
            {ok, Saved} -> ok = file:write_file(Path, Saved)
        end
    end.

api_sites_get_dispatch_test() ->
    ensure_env(),
    {ok, 200, Hdrs, Body} =
        dispatch([<<"GET">>, <<"localhost">>, <<"/api/sites">>, <<>>, [], <<>>, <<"127.0.0.1">>]),
    ?assertEqual(<<"application/json">>, proplists:get_value(<<"content-type">>, Hdrs)),
    {ok, _} = thoas:decode(Body).

api_sites_get_with_x_forwarded_for_test() ->
    ensure_env(),
    Hdrs = [{<<"x-forwarded-for">>, <<"10.0.0.1">>}],
    {ok, 200, _, Body} =
        dispatch([<<"GET">>, <<"localhost">>, <<"/api/sites">>, <<>>, Hdrs, <<>>, <<"203.0.113.5">>]),
    {ok, _} = thoas:decode(Body).

api_backends_get_dispatch_test() ->
    ensure_env(),
    {ok, 200, Hdrs, Body} =
        dispatch([<<"GET">>, <<"localhost">>, <<"/api/backends">>, <<>>, [], <<>>, <<"127.0.0.1">>]),
    ?assertEqual(<<"application/json">>, proplists:get_value(<<"content-type">>, Hdrs)),
    {ok, _} = thoas:decode(Body).

h3_static_post_not_served_test() ->
    ensure_env(),
    Result = dispatch([<<"POST">>, <<"localhost">>, <<"/favicon.svg">>, <<>>, [], <<>>, <<"127.0.0.1">>]),
    ?assertMatch({ok, Status, _, _} when Status >= 400, Result).

h3_client_ipv6_peer_test() ->
    ensure_env(),
    {ok, 200, _, _} =
        dispatch([<<"GET">>, <<"localhost">>, <<"/api/version">>, <<>>, [], <<>>, <<"::1">>]).
