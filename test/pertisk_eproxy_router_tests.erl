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
%% route/2: rewrite in build
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

%% ---------------------------------------------------------------------------
%% route/2 (uses config ETS router via sync_ingress)
%% ---------------------------------------------------------------------------

ensure_config_started() ->
    application:ensure_all_started(lager),
    case whereis(pertisk_eproxy_config) of
        undefined ->
            {ok, _} = pertisk_eproxy_config:start_link();
        _ ->
            ok
    end.

load_router_sites(Sites) ->
    ensure_config_started(),
    ok = pertisk_eproxy_config:sync_ingress(Sites, []).

route_exact_match_test() ->
    load_router_sites([#{
        host => <<"example.com">>,
        backend => <<"web">>,
        routes => [#{path => <<"/status">>, path_type => exact}]
    }]),
    {ok, Match} = pertisk_eproxy_router:route(<<"example.com">>, <<"/status">>),
    ?assertEqual(<<"web">>, maps:get(backend, Match)),
    ?assertEqual(<<"/status">>, maps:get(upstream_path, Match)).

route_exact_no_match_test() ->
    load_router_sites([#{
        host => <<"example.com">>,
        backend => <<"web">>,
        routes => [#{path => <<"/status">>, path_type => exact}]
    }]),
    ?assertEqual({error, no_route}, pertisk_eproxy_router:route(<<"example.com">>, <<"/other">>)).

route_prefix_match_test() ->
    load_router_sites([#{
        host => <<"example.com">>,
        backend => <<"api">>,
        routes => [#{path => <<"/api">>, path_type => prefix}]
    }]),
    {ok, Match} = pertisk_eproxy_router:route(<<"example.com">>, <<"/api/v1/users">>),
    ?assertEqual(<<"api">>, maps:get(backend, Match)),
    ?assertEqual(<<"/api/v1/users">>, maps:get(upstream_path, Match)).

route_longest_prefix_wins_test() ->
    load_router_sites([
        #{
            host => <<"example.com">>,
            backend => <<"short">>,
            routes => [#{path => <<"/api">>, path_type => prefix}]
        },
        #{
            host => <<"example.com">>,
            backend => <<"long">>,
            routes => [#{path => <<"/api/v2">>, path_type => prefix}]
        }
    ]),
    {ok, Match} = pertisk_eproxy_router:route(<<"example.com">>, <<"/api/v2/items">>),
    ?assertEqual(<<"long">>, maps:get(backend, Match)).

route_rewrite_test() ->
    load_router_sites([#{
        host => <<"example.com">>,
        backend => <<"web">>,
        routes => [#{path => <<"/old">>, path_type => prefix, rewrite => <<"/new">>}]
    }]),
    {ok, Match} = pertisk_eproxy_router:route(<<"example.com">>, <<"/old/extra">>),
    ?assertEqual(<<"/new//extra">>, maps:get(upstream_path, Match)).

route_rewrite_trailing_slash_test() ->
    load_router_sites([#{
        host => <<"example.com">>,
        backend => <<"web">>,
        routes => [#{path => <<"/old">>, path_type => prefix, rewrite => <<"/new/">>}]
    }]),
    {ok, Match} = pertisk_eproxy_router:route(<<"example.com">>, <<"/old">>),
    ?assertEqual(<<"/new/">>, maps:get(upstream_path, Match)).

route_wildcard_host_test() ->
    load_router_sites([#{
        host => <<"*.example.com">>,
        backend => <<"wild">>,
        routes => [#{path => <<"/">>, path_type => prefix}]
    }]),
    {ok, Match} = pertisk_eproxy_router:route(<<"app.example.com">>, <<"/">>),
    ?assertEqual(<<"wild">>, maps:get(backend, Match)),
    ?assertEqual(<<"*.example.com">>, maps:get(site_host, Match)).

route_wildcard_no_match_root_domain_test() ->
    load_router_sites([#{
        host => <<"*.example.com">>,
        backend => <<"wild">>,
        routes => [#{path => <<"/">>, path_type => prefix}]
    }]),
    ?assertEqual({error, no_route}, pertisk_eproxy_router:route(<<"example.com">>, <<"/">>)).

route_exact_host_beats_wildcard_test() ->
    load_router_sites([
        #{
            host => <<"*.example.com">>,
            backend => <<"wild">>,
            routes => [#{path => <<"/">>, path_type => prefix}]
        },
        #{
            host => <<"admin.example.com">>,
            backend => <<"admin">>,
            routes => [#{path => <<"/">>, path_type => prefix}]
        }
    ]),
    {ok, Match} = pertisk_eproxy_router:route(<<"admin.example.com">>, <<"/">>),
    ?assertEqual(<<"admin">>, maps:get(backend, Match)).

route_empty_path_normalized_test() ->
    load_router_sites([#{
        host => <<"example.com">>,
        backend => <<"web">>,
        routes => [#{path => <<"/">>, path_type => prefix}]
    }]),
    {ok, Match} = pertisk_eproxy_router:route(<<"example.com">>, <<>>),
    ?assertEqual(<<"/">>, maps:get(upstream_path, Match)).

route_host_port_stripped_test() ->
    load_router_sites([#{
        host => <<"example.com">>,
        backend => <<"web">>,
        routes => [#{path => <<"/">>, path_type => prefix}]
    }]),
    {ok, Match} = pertisk_eproxy_router:route(<<"Example.COM:443">>, <<"/">>),
    ?assertEqual(<<"web">>, maps:get(backend, Match)).

route_no_router_returns_error_test() ->
    ensure_config_started(),
    ok = pertisk_eproxy_config:sync_ingress([], []),
    ?assertEqual({error, no_route}, pertisk_eproxy_router:route(<<"missing.com">>, <<"/">>)).

build_sorts_exact_before_wildcard_test() ->
    Sites = [
        #{host => <<"*.example.com">>, backend => <<"wild">>, routes => []},
        #{host => <<"api.example.com">>, backend => <<"api">>, routes => []},
        #{host => <<"z.example.com">>, backend => <<"z">>, routes => []}
    ],
    Router = pertisk_eproxy_router:build(Sites),
    Hosts = [H || {H, _} <- Router],
    WildIdx = [I || {I, H} <- lists:zip(lists:seq(1, length(Hosts)), Hosts), binary:match(H, <<"*.">>) =/= nomatch],
    ExactIdx = [I || {I, H} <- lists:zip(lists:seq(1, length(Hosts)), Hosts), binary:match(H, <<"*.">>) =:= nomatch],
    ?assert(lists:max(ExactIdx) < lists:min(WildIdx)).

build_host_entry_less_exact_before_wildcard_test() ->
    Sites = [
        #{host => <<"a.example.com">>, backend => <<"a">>, routes => []},
        #{host => <<"*.example.com">>, backend => <<"w">>, routes => []}
    ],
    Router = pertisk_eproxy_router:build(Sites),
    [FirstHost, SecondHost] = [H || {H, _} <- Router],
    ?assertEqual(<<"a.example.com">>, FirstHost),
    ?assertEqual(<<"*.example.com">>, SecondHost).

build_three_hosts_sorts_exact_before_wildcard_test() ->
    %% lists:sort/2 on two hosts may only compare wildcard-first (L81); three hosts
    %% forces host_entry_less/2 with {false, true} (exact before wildcard).
    Sites = [
        #{host => <<"*.example.com">>, backend => <<"w">>, routes => []},
        #{host => <<"mid.example.com">>, backend => <<"m">>, routes => []},
        #{host => <<"z.example.com">>, backend => <<"z">>, routes => []}
    ],
    Router = pertisk_eproxy_router:build(Sites),
    Hosts = [H || {H, _} <- Router],
    WildIdx = [I || {I, H} <- lists:zip(lists:seq(1, length(Hosts)), Hosts),
                    binary:match(H, <<"*.">>) =/= nomatch],
    ExactIdx = [I || {I, H} <- lists:zip(lists:seq(1, length(Hosts)), Hosts),
                    binary:match(H, <<"*.">>) =:= nomatch],
    ?assert(lists:max(ExactIdx) < lists:min(WildIdx)).

route_equal_prefix_length_keeps_first_test() ->
    load_router_sites([
        #{
            host => <<"example.com">>,
            backend => <<"first">>,
            routes => [#{path => <<"/api">>, path_type => prefix}]
        },
        #{
            host => <<"example.com">>,
            backend => <<"second">>,
            routes => [#{path => <<"/api">>, path_type => prefix}]
        }
    ]),
    {ok, Match} = pertisk_eproxy_router:route(<<"example.com">>, <<"/api/x">>),
    ?assertEqual(<<"first">>, maps:get(backend, Match)).

route_rewrite_with_trailing_slash_and_suffix_test() ->
    load_router_sites([#{
        host => <<"example.com">>,
        backend => <<"web">>,
        routes => [#{path => <<"/old">>, path_type => prefix, rewrite => <<"/new/">>}]
    }]),
    {ok, Match} = pertisk_eproxy_router:route(<<"example.com">>, <<"/old/extra">>),
    ?assertEqual(<<"/new//extra">>, maps:get(upstream_path, Match)).

route_rewrite_empty_target_test() ->
    load_router_sites([#{
        host => <<"example.com">>,
        backend => <<"web">>,
        routes => [#{path => <<"/old">>, path_type => prefix, rewrite => <<>>}]
    }]),
    {ok, Match} = pertisk_eproxy_router:route(<<"example.com">>, <<"/old/extra">>),
    ?assertEqual(<<"//extra">>, maps:get(upstream_path, Match)).

route_rewrite_list_target_test() ->
    load_router_sites([#{
        host => <<"example.com">>,
        backend => <<"web">>,
        routes => [#{path => <<"/old">>, path_type => prefix, rewrite => "/new"}]
    }]),
    {ok, Match} = pertisk_eproxy_router:route(<<"example.com">>, <<"/old/extra">>),
    ?assertEqual(<<"/new//extra">>, maps:get(upstream_path, Match)).

route_wildcard_rejects_host_without_dot_test() ->
    load_router_sites([#{
        host => <<"*.example.com">>,
        backend => <<"wild">>,
        routes => [#{path => <<"/">>, path_type => prefix}]
    }]),
    ?assertEqual({error, no_route}, pertisk_eproxy_router:route(<<"localhost">>, <<"/">>)).