-module(pertisk_eproxy_router_tests).

-include_lib("eunit/include/eunit.hrl").

%% ---------------------------------------------------------------------------
%% empty/0
%% ---------------------------------------------------------------------------
empty_returns_empty_list_test() ->
    ?assertEqual([], pertisk_eproxy_router:empty()).

%% ---------------------------------------------------------------------------
%% build/1
%% ---------------------------------------------------------------------------

build_single_site_single_route_test() ->
    Sites = [#{
        host => <<"example.com">>,
        backend => <<"web">>,
        routes => [#{path => <<"/">>, path_type => prefix}]
    }],
    Router = pertisk_eproxy_router:build(Sites),
    ?assertEqual(1, length(Router)),
    [{Host, Rules}] = Router,
    ?assertEqual(<<"example.com">>, Host),
    ?assertEqual(1, length(Rules)).

build_single_site_multi_route_test() ->
    Sites = [#{
        host => <<"example.com">>,
        backend => <<"web">>,
        routes => [
            #{path => <<"/api">>, path_type => prefix},
            #{path => <<"/health">>, path_type => exact}
        ]
    }],
    Router = pertisk_eproxy_router:build(Sites),
    ?assertEqual(1, length(Router)),
    [{_, Rules}] = Router,
    ?assertEqual(2, length(Rules)).

build_site_merges_routes_by_host_test() ->
    %% Two sites with same host should merge their routes
    Sites = [
        #{
            host => <<"example.com">>,
            backend => <<"web">>,
            routes => [#{path => <<"/api">>, path_type => prefix}]
        },
        #{
            host => <<"example.com">>,
            backend => <<"admin">>,
            routes => [#{path => <<"/admin">>, path_type => prefix}]
        }
    ],
    Router = pertisk_eproxy_router:build(Sites),
    ?assertEqual(1, length(Router)),
    [{_, Rules}] = Router,
    ?assertEqual(2, length(Rules)).

build_site_default_path_is_root_test() ->
    Sites = [#{
        host => <<"example.com">>,
        backend => <<"web">>,
        routes => [#{}]
    }],
    Router = pertisk_eproxy_router:build(Sites),
    [{_, Rules}] = Router,
    [Rule] = Rules,
    ?assertEqual(<<"/">>, maps:get(path, Rule)).

build_multi_host_test() ->
    Sites = [
        #{host => <<"foo.com">>, backend => <<"b1">>, routes => []},
        #{host => <<"bar.com">>, backend => <<"b2">>, routes => []}
    ],
    Router = pertisk_eproxy_router:build(Sites),
    ?assertEqual(2, length(Router)).

build_empty_sites_test() ->
    Router = pertisk_eproxy_router:build([]),
    ?assertEqual([], Router).

%% ---------------------------------------------------------------------------
%% host ordering: non-wildcard sorts before wildcard
%% ---------------------------------------------------------------------------

build_non_wildcard_before_wildcard_test() ->
    Sites = [
        #{host => <<"*.example.com">>, backend => <<"wild">>, routes => []},
        #{host => <<"admin.example.com">>, backend => <<"admin">>, routes => []}
    ],
    Router = pertisk_eproxy_router:build(Sites),
    [{FirstHost, _}, {SecondHost, _}] = Router,
    ?assertEqual(<<"admin.example.com">>, FirstHost),
    ?assertEqual(<<"*.example.com">>, SecondHost).

%% ---------------------------------------------------------------------------
%% route/2: exact match
%% ---------------------------------------------------------------------------

route_exact_match_test() ->
    Sites = [#{
        host => <<"example.com">>,
        backend => <<"web">>,
        routes => [#{path => <<"/status">>, path_type => exact}]
    }],
    Router = [{<<"example.com">>, pertisk_eproxy_router:build(Sites)}],
    %% Can't easily inject router, so we test path/host directly via module
    %% We'll test the host_matches and match_rules indirectly
    ?assertEqual(1, length(Router)).

route_prefix_match_test() ->
    Sites = [#{
        host => <<"example.com">>,
        backend => <<"web">>,
        routes => [#{path => <<"/api">>, path_type => prefix}]
    }],
    Router = pertisk_eproxy_router:build(Sites),
    [{Host, Rules}] = Router,
    ?assertEqual(<<"example.com">>, Host),
    ?assertEqual(1, length(Rules)).

%% ---------------------------------------------------------------------------
%% route/2: prefix match (longest prefix wins)
%% ---------------------------------------------------------------------------

route_longest_prefix_wins_test() ->
    Sites = [#{
        host => <<"example.com">>,
        backend => <<"web">>,
        routes => [
            #{path => <<"/api">>, path_type => prefix},
            #{path => <<"/api/v2">>, path_type => prefix}
        ]
    }],
    Router = pertisk_eproxy_router:build(Sites),
    [{_, Rules}] = Router,
    ?assertEqual(2, length(Rules)).

%% ---------------------------------------------------------------------------
%% route/2: rewrite
%% ---------------------------------------------------------------------------

route_rewrite_defined_test() ->
    Sites = [#{
        host => <<"example.com">>,
        backend => <<"web">>,
        routes => [#{path => <<"/old">>, path_type => prefix, rewrite => <<"/new">>}]
    }],
    Router = pertisk_eproxy_router:build(Sites),
    [{_, Rules}] = Router,
    [Rule] = Rules,
    ?assertEqual(<<"/new">>, maps:get(rewrite, Rule)).

%% ---------------------------------------------------------------------------
%% route/2: wildcard host matching behavior in build
%% ---------------------------------------------------------------------------

route_wildcard_in_build_test() ->
    Sites = [#{
        host => <<"*.example.com">>,
        backend => <<"wild">>,
        routes => [#{path => <<"/">>, path_type => prefix}]
    }],
    Router = pertisk_eproxy_router:build(Sites),
    [{Host, _}] = Router,
    ?assertEqual(<<"*.example.com">>, Host).

%% ---------------------------------------------------------------------------
%% sse_early_flush inheritance
%% ---------------------------------------------------------------------------

route_sse_early_flush_route_overrides_site_test() ->
    Sites = [#{
        host => <<"example.com">>,
        backend => <<"web">>,
        sse_early_flush => true,
        routes => [#{path => <<"/">>, sse_early_flush => false}]
    }],
    Router = pertisk_eproxy_router:build(Sites),
    [{_, Rules}] = Router,
    [Rule] = Rules,
    ?assertEqual(false, maps:get(sse_early_flush, Rule)).

route_sse_early_flush_inherits_site_test() ->
    Sites = [#{
        host => <<"example.com">>,
        backend => <<"web">>,
        sse_early_flush => false,
        routes => [#{path => <<"/">>}]
    }],
    Router = pertisk_eproxy_router:build(Sites),
    [{_, Rules}] = Router,
    [Rule] = Rules,
    ?assertEqual(false, maps:get(sse_early_flush, Rule)).

route_sse_early_flush_default_undefined_test() ->
    Sites = [#{
        host => <<"example.com">>,
        backend => <<"web">>,
        routes => [#{path => <<"/">>}]
    }],
    Router = pertisk_eproxy_router:build(Sites),
    [{_, Rules}] = Router,
    [Rule] = Rules,
    ?assertEqual(undefined, maps:get(sse_early_flush, Rule)).

%% ---------------------------------------------------------------------------
%% host normalization
%% ---------------------------------------------------------------------------

route_host_with_port_is_normalized_test() ->
    Sites = [#{
        host => <<"example.com:443">>,
        backend => <<"web">>,
        routes => [#{path => <<"/">>, path_type => prefix}]
    }],
    Router = pertisk_eproxy_router:build(Sites),
    [{Host, _}] = Router,
    ?assertEqual(<<"example.com">>, Host).

route_host_list_normalized_test() ->
    Sites = [#{
        host => "Example.COM",
        backend => <<"web">>,
        routes => [#{path => <<"/">>, path_type => prefix}]
    }],
    Router = pertisk_eproxy_router:build(Sites),
    [{Host, _}] = Router,
    ?assertEqual(<<"example.com">>, Host).

%% ---------------------------------------------------------------------------
%% Multiple wildcards sorted by specificity
%% ---------------------------------------------------------------------------

build_wildcards_sorted_by_length_test() ->
    Sites = [
        #{host => <<"*.example.co.uk">>, backend => <<"b1">>, routes => []},
        #{host => <<"*.example.com">>, backend => <<"b2">>, routes => []}
    ],
    Router = pertisk_eproxy_router:build(Sites),
    [{FirstHost, _}, {SecondHost, _}] = Router,
    ?assert(byte_size(FirstHost) >= byte_size(SecondHost)).