%%%-------------------------------------------------------------------
%% @doc Unit tests for admin module
%% @end
%%%-------------------------------------------------------------------

-module(pertisk_eproxy_admin_tests).
-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%% Test fixtures
%%%===================================================================

setup() ->
    {ok, _} = pertisk_eproxy_admin:start_link(),
    pertisk_eproxy_admin.

cleanup(_) ->
    ok.

%%%===================================================================
%% Test cases
%%%===================================================================

admin_get_status_test() ->
    Status = pertisk_eproxy_admin:get_status(),
    ?assertMatch(#{upstreams_count := _, admin_port := _}, Status).

admin_add_upstream_test() ->
    Config = #{target => "localhost:3000", weight => 1},
    ok = pertisk_eproxy_admin:add_upstream(<<"api.example.com">>, Config),
    Upstreams = pertisk_eproxy_admin:list_upstreams(),
    ?assertEqual(1, length(Upstreams)).

admin_remove_upstream_test() ->
    Config = #{target => "localhost:3000", weight => 1},
    ok = pertisk_eproxy_admin:add_upstream(<<"api.example.com">>, Config),
    ok = pertisk_eproxy_admin:remove_upstream(<<"api.example.com">>),
    Upstreams = pertisk_eproxy_admin:list_upstreams(),
    ?assertEqual(0, length(Upstreams)).

%%%===================================================================
%% Common Test suites (if using ct instead of eunit)
%%%===================================================================

% For ct_run:
% all() -> [admin_get_status_test, admin_add_upstream_test].
% 
% init_per_suite(Config) ->
%     {ok, _} = application:ensure_all_started(pertisk_eproxy),
%     Config.
% 
% end_per_suite(_Config) ->
%     application:stop(pertisk_eproxy).
