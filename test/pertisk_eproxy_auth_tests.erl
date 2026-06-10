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