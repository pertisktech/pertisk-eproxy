-module(pertisk_eproxy_admin_sse_handler_tests).

-include_lib("eunit/include/eunit.hrl").

ensure_env() ->
    pertisk_eproxy_test_helpers:ensure_config(),
    case whereis(pertisk_eproxy_access_log) of
        undefined -> {ok, _} = pertisk_eproxy_access_log:start_link();
        _ -> ok
    end.

snapshot_json_has_core_sections_test() ->
    ensure_env(),
    {ok, Map} = thoas:decode(pertisk_eproxy_admin_sse_handler:snapshot_json()),
    ?assert(maps:is_key(<<"stats">>, Map)),
    ?assert(maps:is_key(<<"management">>, Map)),
    ?assert(maps:is_key(<<"logs">>, Map)),
    ?assert(maps:is_key(<<"certificates">>, Map)),
    ?assert(maps:is_key(<<"ssl_jobs">>, Map)).

snapshot_json_certificates_is_list_test() ->
    ensure_env(),
    {ok, Map} = thoas:decode(pertisk_eproxy_admin_sse_handler:snapshot_json()),
    ?assert(is_list(maps:get(<<"certificates">>, Map))).

snapshot_json_with_certificate_row_test() ->
    DbPath = pertisk_eproxy_test_helpers:tmp_db(),
    file:delete(DbPath),
    OldDb = application:get_env(pertisk_eproxy, db_file),
    application:set_env(pertisk_eproxy, db_file, DbPath),
    ensure_env(),
    try
        ?assertMatch({ok, _}, pertisk_eproxy_db:init(DbPath)),
        {ok, Id} = pertisk_eproxy_db:insert_certificate(DbPath, <<"sse-cert">>),
        ?assert(is_integer(Id)),
        {ok, Map} = thoas:decode(pertisk_eproxy_admin_sse_handler:snapshot_json()),
        Certs = maps:get(<<"certificates">>, Map),
        ?assert(length(Certs) >= 1)
    after
        case OldDb of
            {ok, V} -> application:set_env(pertisk_eproxy, db_file, V);
            undefined -> application:unset_env(pertisk_eproxy, db_file)
        end,
        file:delete(DbPath)
    end.

init_unauthorized_when_auth_required_test() ->
    ensure_env(),
    Old = application:get_env(pertisk_eproxy, admin_auth),
    application:set_env(pertisk_eproxy, admin_auth, local),
    try
        with_mock_req(#{qs_vals => []}, fun(Req) ->
            ?assertMatch({ok, #{reply := unauthorized}, _}, pertisk_eproxy_admin_sse_handler:init(Req, #{}))
        end)
    after
        restore_auth_mode(Old)
    end.

restore_auth_mode(Old) ->
    case Old of
        {ok, V} -> application:set_env(pertisk_eproxy, admin_auth, V);
        undefined -> application:unset_env(pertisk_eproxy, admin_auth)
    end.

with_mock_req(Opts, Fun) ->
    meck:new(cowboy_req, [unstick]),
    meck:new(pertisk_eproxy_response_headers, [unstick]),
    meck:new(pertisk_eproxy_alt_svc, [unstick]),
    meck:expect(pertisk_eproxy_response_headers, merge, fun(H) -> H end),
    meck:expect(pertisk_eproxy_alt_svc, merge_response_headers, fun(_Req, _Host, H) -> H end),
    meck:expect(cowboy_req, host, fun(_) -> maps:get(host, Opts, <<"localhost">>) end),
    meck:expect(cowboy_req, parse_qs, fun(_) -> maps:get(qs_vals, Opts, []) end),
    meck:expect(cowboy_req, reply, fun(_Status, _Hdrs, _Body, Req) ->
        Req#{reply => unauthorized}
    end),
    meck:expect(cowboy_req, stream_reply, fun(_Status, _Hdrs, Req) -> Req#{stream => started} end),
    meck:expect(cowboy_req, stream_body, fun(_Payload, _Fin, Req) -> Req end),
    try Fun(#{}) after
        meck:unload([cowboy_req, pertisk_eproxy_response_headers, pertisk_eproxy_alt_svc])
    end.
