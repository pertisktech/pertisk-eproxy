-module(pertisk_eproxy_auth_tests).

-include_lib("eunit/include/eunit.hrl").

%% ---------------------------------------------------------------------------
%% auth_mode/0 tests
%% ---------------------------------------------------------------------------

auth_mode_returns_valid_value_test() ->
    Mode = pertisk_eproxy_auth:auth_mode(),
    ?assert(lists:member(Mode, [disabled, local, sso, both])).

%% ---------------------------------------------------------------------------
%% auth_config_map/0 tests
%% ---------------------------------------------------------------------------

auth_config_map_returns_map_test() ->
    Map = pertisk_eproxy_auth:auth_config_map(),
    ?assert(is_map(Map)),
    ?assert(maps:is_key(<<"mode">>, Map)),
    ?assert(maps:is_key(<<"supports_local">>, Map)),
    ?assert(maps:is_key(<<"supports_sso">>, Map)),
    ?assert(maps:is_key(<<"guest_mode">>, Map)),
    ?assert(maps:is_key(<<"deployment_mode">>, Map)).

%% ---------------------------------------------------------------------------
%% login/2 tests
%% ---------------------------------------------------------------------------

login_returns_error_when_disabled_test() ->
    Result = pertisk_eproxy_auth:login(<<"user">>, <<"pass">>),
    ?assertMatch({error, _}, Result).

%% ---------------------------------------------------------------------------
%% bearer_from_request/1 - stubbed tests
%% ---------------------------------------------------------------------------

bearer_from_request_with_authorization_test() ->
    Result = pertisk_eproxy_auth:bearer_from_request(#{
        headers => #{<<"authorization">> => <<"Bearer token123">>}
    }),
    ?assertMatch({ok, <<"token123">>}, Result).

%% ---------------------------------------------------------------------------
%% verify_token/1 tests
%% ---------------------------------------------------------------------------

verify_token_non_binary_returns_error_test() ->
    ?assertEqual({error, unauthorized}, pertisk_eproxy_auth:verify_token(123)).

verify_token_empty_binary_test() ->
    Result = pertisk_eproxy_auth:verify_token(<<>>),
    ?assertMatch({error, unauthorized}, Result).

verify_token_random_string_test() ->
    Result = pertisk_eproxy_auth:verify_token(<<"random_invalid_token">>),
    ?assertMatch({error, _}, Result).

%% ---------------------------------------------------------------------------
%% deployment_mode_bin tests (private, tested via auth_config_map)
%% ---------------------------------------------------------------------------

deployment_mode_is_binary_test() ->
    Map = pertisk_eproxy_auth:auth_config_map(),
    Mode = maps:get(<<"deployment_mode">>, Map),
    ?assert(is_binary(Mode)),
    ?assert(lists:member(Mode, [<<"proxy">>, <<"ingress">>])).

%% ---------------------------------------------------------------------------
%% gen_server lifecycle
%% ---------------------------------------------------------------------------

with_auth_server(Fun) ->
    case whereis(pertisk_eproxy_auth) of
        undefined ->
            {ok, Pid} = pertisk_eproxy_auth:start_link(),
            try Fun() after catch gen_server:stop(Pid, normal, 5000) end;
        Pid ->
            Fun(),
            catch gen_server:stop(Pid, normal, 5000)
    end.

start_link_and_callbacks_test() ->
    with_auth_server(fun() ->
        ?assert(is_pid(whereis(pertisk_eproxy_auth))),
        ?assertMatch({reply, ok, _}, pertisk_eproxy_auth:handle_call(ping, self(), #{})),
        ?assertMatch({noreply, _}, pertisk_eproxy_auth:handle_cast(msg, #{})),
        ?assertMatch({noreply, _}, pertisk_eproxy_auth:handle_info(msg, #{})),
        ?assertEqual(ok, pertisk_eproxy_auth:terminate(normal, #{})),
        ?assertMatch({ok, #{}}, pertisk_eproxy_auth:code_change(1, #{}, extra))
    end).

%% ---------------------------------------------------------------------------
%% login / verify / logout / refresh with local auth
%% ---------------------------------------------------------------------------

with_local_auth(Fun) ->
    Old = application:get_env(pertisk_eproxy, admin_auth),
    application:set_env(pertisk_eproxy, admin_auth, local),
    with_auth_server(fun() ->
        try Fun() after
            case Old of
                {ok, V} -> application:set_env(pertisk_eproxy, admin_auth, V);
                undefined -> application:unset_env(pertisk_eproxy, admin_auth)
            end
        end
    end).

login_disabled_when_not_local_test() ->
    Old = application:get_env(pertisk_eproxy, admin_auth),
    application:set_env(pertisk_eproxy, admin_auth, disabled),
    try
        ?assertEqual({error, login_disabled}, pertisk_eproxy_auth:login(<<"u">>, <<"p">>))
    after
        case Old of
            {ok, V} -> application:set_env(pertisk_eproxy, admin_auth, V);
            undefined -> application:unset_env(pertisk_eproxy, admin_auth)
        end
    end.

verify_request_disabled_test() ->
    Old = application:get_env(pertisk_eproxy, admin_auth),
    application:set_env(pertisk_eproxy, admin_auth, disabled),
    try
        ?assertEqual(ok, pertisk_eproxy_auth:verify_request(#{headers => #{}}))
    after
        case Old of
            {ok, V} -> application:set_env(pertisk_eproxy, admin_auth, V);
            undefined -> application:unset_env(pertisk_eproxy, admin_auth)
        end
    end.

verify_request_unauthorized_test() ->
    with_local_auth(fun() ->
        ?assertEqual({error, unauthorized}, pertisk_eproxy_auth:verify_request(#{headers => #{}}))
    end).

verify_request_ok_test() ->
    with_local_auth(fun() ->
        DbPath = pertisk_eproxy_test_helpers:tmp_db(),
        file:delete(DbPath),
        OldDb = application:get_env(pertisk_eproxy, db_file),
        application:set_env(pertisk_eproxy, db_file, DbPath),
        pertisk_eproxy_test_helpers:ensure_config(),
        try
            ?assertMatch({ok, _}, pertisk_eproxy_db:init(DbPath)),
            {ok, #{token := Token}} = pertisk_eproxy_auth:login(<<"admin">>, <<"admin">>),
            Req = #{headers => #{<<"authorization">> => <<"Bearer ", Token/binary>>}},
            ?assertEqual(ok, pertisk_eproxy_auth:verify_request(Req))
        after
            case OldDb of
                {ok, V} -> application:set_env(pertisk_eproxy, db_file, V);
                undefined -> application:unset_env(pertisk_eproxy, db_file)
            end,
            file:delete(DbPath)
        end
    end).

logout_and_refresh_session_test() ->
    with_local_auth(fun() ->
        DbPath = pertisk_eproxy_test_helpers:tmp_db(),
        file:delete(DbPath),
        OldDb = application:get_env(pertisk_eproxy, db_file),
        application:set_env(pertisk_eproxy, db_file, DbPath),
        pertisk_eproxy_test_helpers:ensure_config(),
        try
            ?assertMatch({ok, _}, pertisk_eproxy_db:init(DbPath)),
            {ok, #{token := Token}} = pertisk_eproxy_auth:login(<<"admin">>, <<"admin">>),
            ?assertMatch({ok, <<"admin">>}, pertisk_eproxy_auth:verify_token(Token)),
            ?assertEqual(ok, pertisk_eproxy_auth:logout(Token)),
            ?assertMatch({error, unauthorized}, pertisk_eproxy_auth:verify_token(Token)),
            {ok, #{token := Token2}} = pertisk_eproxy_auth:login(<<"admin">>, <<"admin">>),
            ?assertMatch({ok, #{token := Token2, expires_in := _}},
                pertisk_eproxy_auth:refresh(Token2))
        after
            case OldDb of
                {ok, V} -> application:set_env(pertisk_eproxy, db_file, V);
                undefined -> application:unset_env(pertisk_eproxy, db_file)
            end,
            file:delete(DbPath)
        end
    end).

bearer_from_x_eproxy_header_test() ->
    Req = #{headers => #{<<"x-eproxy-bearer">> => <<"Bearer mytoken">>}},
    ?assertMatch({ok, <<"mytoken">>}, pertisk_eproxy_auth:bearer_from_request(Req)).

logout_non_binary_ok_test() ->
    ?assertEqual(ok, pertisk_eproxy_auth:logout(123)).

refresh_non_binary_error_test() ->
    ?assertMatch({error, unauthorized}, pertisk_eproxy_auth:refresh(123)).