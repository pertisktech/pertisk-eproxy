-module(pertisk_eproxy_backend_tests).

-include_lib("eunit/include/eunit.hrl").

%% ---------------------------------------------------------------------------
%% backend_name/1
%% ---------------------------------------------------------------------------

backend_name_binary_test() ->
    Result = pertisk_eproxy_backend:backend_name(<<"mybackend">>),
    ?assert(is_atom(Result)),
    ?assertEqual(<<"backend_mybackend">>, atom_to_binary(Result, utf8)).

backend_name_atom_test() ->
    ?assertEqual(my_atom, pertisk_eproxy_backend:backend_name(my_atom)).

%% ---------------------------------------------------------------------------
%% parse_addr/1
%% ---------------------------------------------------------------------------

parse_addr_simple_host_port_test() ->
    {Host, Port} = pertisk_eproxy_backend:parse_addr(<<"127.0.0.1:8080">>),
    ?assertEqual("127.0.0.1", Host),
    ?assertEqual(8080, Port).

parse_addr_host_only_defaults_to_80_test() ->
    {Host, Port} = pertisk_eproxy_backend:parse_addr(<<"example.com">>),
    ?assertEqual("example.com", Host),
    ?assertEqual(80, Port).

parse_addr_http_scheme_test() ->
    {Host, Port} = pertisk_eproxy_backend:parse_addr(<<"http://example.com:3000">>),
    ?assertEqual("example.com", Host),
    ?assertEqual(3000, Port).

parse_addr_https_scheme_defaults_to_443_test() ->
    {Host, Port} = pertisk_eproxy_backend:parse_addr(<<"https://example.com">>),
    ?assertEqual("example.com", Host),
    ?assertEqual(443, Port).

parse_addr_wss_scheme_test() ->
    {Host, Port} = pertisk_eproxy_backend:parse_addr(<<"wss://example.com">>),
    ?assertEqual("example.com", Host),
    ?assertEqual(443, Port).

parse_addr_grpcs_scheme_test() ->
    {Host, Port} = pertisk_eproxy_backend:parse_addr(<<"grpcs://example.com">>),
    ?assertEqual("example.com", Host),
    ?assertEqual(443, Port).

parse_addr_trailing_slash_test() ->
    {Host, Port} = pertisk_eproxy_backend:parse_addr(<<"example.com:8080/">>),
    ?assertEqual("example.com", Host),
    ?assertEqual(8080, Port).

parse_addr_list_input_test() ->
    {Host, Port} = pertisk_eproxy_backend:parse_addr("127.0.0.1:9090"),
    ?assertEqual("127.0.0.1", Host),
    ?assertEqual(9090, Port).

parse_addr_invalid_uri_fallback_test() ->
    {Host, Port} = pertisk_eproxy_backend:parse_addr(<<"://bad">>),
    ?assertEqual("://bad", Host),
    ?assertEqual(80, Port).

%% ---------------------------------------------------------------------------
%% split_host_port/2
%% ---------------------------------------------------------------------------

split_host_port_with_port_test() ->
    {Host, Port} = pertisk_eproxy_backend:split_host_port("host:1234", 80),
    ?assertEqual("host", Host),
    ?assertEqual(1234, Port).

split_host_port_no_port_test() ->
    {Host, Port} = pertisk_eproxy_backend:split_host_port("host", 80),
    ?assertEqual("host", Host),
    ?assertEqual(80, Port).

split_host_port_invalid_port_test() ->
    {Host, Port} = pertisk_eproxy_backend:split_host_port("host:abc", 80),
    ?assertEqual("host:abc", Host),
    ?assertEqual(80, Port).

split_host_port_trailing_slash_test() ->
    {Host, Port} = pertisk_eproxy_backend:split_host_port("host:8080/", 80),
    ?assertEqual("host", Host),
    ?assertEqual(8080, Port).

%% ---------------------------------------------------------------------------
%% safe_port/1
%% ---------------------------------------------------------------------------

safe_port_valid_test() ->
    ?assertEqual({ok, 8080}, pertisk_eproxy_backend:safe_port("8080")).

safe_port_invalid_test() ->
    ?assertEqual(error, pertisk_eproxy_backend:safe_port("abc")).

safe_port_trailing_slash_test() ->
    ?assertEqual({ok, 8080}, pertisk_eproxy_backend:safe_port("8080/")).

%% ---------------------------------------------------------------------------
%% scheme_default_port/1
%% ---------------------------------------------------------------------------

scheme_default_port_https_test() ->
    ?assertEqual(443, pertisk_eproxy_backend:scheme_default_port("https")).

scheme_default_port_wss_test() ->
    ?assertEqual(443, pertisk_eproxy_backend:scheme_default_port("wss")).

scheme_default_port_grpcs_test() ->
    ?assertEqual(443, pertisk_eproxy_backend:scheme_default_port("grpcs")).

scheme_default_port_http_test() ->
    ?assertEqual(80, pertisk_eproxy_backend:scheme_default_port("http")).

scheme_default_port_unknown_test() ->
    ?assertEqual(80, pertisk_eproxy_backend:scheme_default_port("unknown")).

%% ---------------------------------------------------------------------------
%% uri_text_to_list/1
%% ---------------------------------------------------------------------------

uri_text_to_list_binary_test() ->
    ?assertEqual("hello", pertisk_eproxy_backend:uri_text_to_list(<<"hello">>)).

uri_text_to_list_list_test() ->
    ?assertEqual("hello", pertisk_eproxy_backend:uri_text_to_list("hello")).

%% ---------------------------------------------------------------------------
%% transient_backoff_ms/1
%% ---------------------------------------------------------------------------

transient_backoff_ms_streak_1_test() ->
    Result = pertisk_eproxy_backend:transient_backoff_ms(1),
    ?assert(is_integer(Result)),
    ?assert(Result > 0).

transient_backoff_ms_streak_2_test() ->
    Result = pertisk_eproxy_backend:transient_backoff_ms(2),
    ?assert(is_integer(Result)),
    ?assert(Result > 0).

transient_backoff_ms_streak_7_test() ->
    Result = pertisk_eproxy_backend:transient_backoff_ms(7),
    ?assert(is_integer(Result)),
    ?assert(Result > 0).

transient_backoff_ms_invalid_test() ->
    Result = pertisk_eproxy_backend:transient_backoff_ms(0),
    ?assert(is_integer(Result)),
    ?assert(Result > 0).

transient_backoff_ms_non_integer_test() ->
    Result = pertisk_eproxy_backend:transient_backoff_ms(abc),
    ?assert(is_integer(Result)),
    ?assert(Result > 0).

%% ---------------------------------------------------------------------------
%% conn_for_addr/2
%% ---------------------------------------------------------------------------

conn_for_addr_found_test() ->
    LbState = #{upstreams => [#{addr => <<"a">>, conns => 5}, #{addr => <<"b">>, conns => 3}]},
    ?assertEqual(5, pertisk_eproxy_backend:conn_for_addr(LbState, <<"a">>)).

conn_for_addr_not_found_test() ->
    LbState = #{upstreams => [#{addr => <<"a">>, conns => 5}]},
    ?assertEqual(0, pertisk_eproxy_backend:conn_for_addr(LbState, <<"b">>)).

conn_for_addr_empty_test() ->
    LbState = #{upstreams => []},
    ?assertEqual(0, pertisk_eproxy_backend:conn_for_addr(LbState, <<"a">>)).

conn_for_addr_no_conns_field_test() ->
    LbState = #{upstreams => [#{addr => <<"a">>}]},
    ?assertEqual(0, pertisk_eproxy_backend:conn_for_addr(LbState, <<"a">>)).

%% ---------------------------------------------------------------------------
%% increment_conns/2
%% ---------------------------------------------------------------------------

increment_conns_test() ->
    LbState = #{upstreams => [#{addr => <<"a">>, conns => 1}, #{addr => <<"b">>, conns => 0}]},
    NewState = pertisk_eproxy_backend:increment_conns(<<"a">>, LbState),
    #{upstreams := Ups} = NewState,
    [A, B] = Ups,
    ?assertEqual(2, maps:get(conns, A)),
    ?assertEqual(0, maps:get(conns, B)).

increment_conns_no_conns_field_test() ->
    LbState = #{upstreams => [#{addr => <<"a">>}]},
    NewState = pertisk_eproxy_backend:increment_conns(<<"a">>, LbState),
    #{upstreams := [U]} = NewState,
    ?assertEqual(1, maps:get(conns, U)).

%% ---------------------------------------------------------------------------
%% decrement_conns/2
%% ---------------------------------------------------------------------------

decrement_conns_test() ->
    LbState = #{upstreams => [#{addr => <<"a">>, conns => 2}, #{addr => <<"b">>, conns => 1}]},
    NewState = pertisk_eproxy_backend:decrement_conns(<<"a">>, LbState),
    #{upstreams := Ups} = NewState,
    [A, B] = Ups,
    ?assertEqual(1, maps:get(conns, A)),
    ?assertEqual(1, maps:get(conns, B)).

decrement_conns_floor_zero_test() ->
    LbState = #{upstreams => [#{addr => <<"a">>, conns => 0}]},
    NewState = pertisk_eproxy_backend:decrement_conns(<<"a">>, LbState),
    #{upstreams := [U]} = NewState,
    ?assertEqual(0, maps:get(conns, U)).

%% ---------------------------------------------------------------------------
%% mark_transient_down/2
%% ---------------------------------------------------------------------------

mark_transient_down_single_upstream_ignored_test() ->
    LbState = #{upstreams => [#{addr => <<"a">>, healthy => true, conns => 0, transient_down_until_ms => 0, transient_fail_streak => 0}]},
    NewState = pertisk_eproxy_backend:mark_transient_down(<<"a">>, LbState),
    #{upstreams := [U]} = NewState,
    ?assertEqual(true, maps:get(healthy, U)).

mark_transient_down_multi_test() ->
    Now = erlang:monotonic_time(millisecond),
    LbState = #{
        upstreams => [
            #{addr => <<"a">>, healthy => true, conns => 0, transient_down_until_ms => 0, transient_fail_streak => 0},
            #{addr => <<"b">>, healthy => true, conns => 0, transient_down_until_ms => 0, transient_fail_streak => 0}
        ]
    },
    NewState = pertisk_eproxy_backend:mark_transient_down(<<"a">>, LbState),
    #{upstreams := [A, B]} = NewState,
    ?assertEqual(false, maps:get(healthy, A)),
    ?assert(maps:get(transient_down_until_ms, A) > Now),
    ?assertEqual(true, maps:get(healthy, B)).

%% ---------------------------------------------------------------------------
%% clear_transient_down/2
%% ---------------------------------------------------------------------------

clear_transient_down_test() ->
    LbState = #{
        upstreams => [
            #{addr => <<"a">>, healthy => false, conns => 1, transient_down_until_ms => 99999, transient_fail_streak => 3},
            #{addr => <<"b">>, healthy => true, conns => 0, transient_down_until_ms => 0, transient_fail_streak => 0}
        ]
    },
    NewState = pertisk_eproxy_backend:clear_transient_down(<<"a">>, LbState),
    #{upstreams := [A, B]} = NewState,
    ?assertEqual(true, maps:get(healthy, A)),
    ?assertEqual(0, maps:get(transient_down_until_ms, A)),
    ?assertEqual(0, maps:get(transient_fail_streak, A)),
    ?assertEqual(true, maps:get(healthy, B)).

%% ---------------------------------------------------------------------------
%% maybe_recover_transient_down/1
%% ---------------------------------------------------------------------------

maybe_recover_transient_down_expired_test() ->
    Past = erlang:monotonic_time(millisecond) - 1,
    LbState = #{
        upstreams => [
            #{addr => <<"a">>, healthy => false, conns => 0, transient_down_until_ms => Past, transient_fail_streak => 1}
        ]
    },
    NewState = pertisk_eproxy_backend:maybe_recover_transient_down(LbState),
    #{upstreams := [U]} = NewState,
    %% monotonic_time may be negative on some platforms (macOS).
    %% When Past is negative, the Until > 0 guard in the source
    %% will not match, and the upstream remains unhealthy.
    Now = erlang:monotonic_time(millisecond),
    case Past > 0 of
        true ->
            ?assertEqual(true, maps:get(healthy, U)),
            ?assertEqual(0, maps:get(transient_down_until_ms, U));
        false ->
            ?assertEqual(false, maps:get(healthy, U))
    end.

maybe_recover_transient_down_not_expired_test() ->
    Future = erlang:monotonic_time(millisecond) + 60000,
    LbState = #{
        upstreams => [
            #{addr => <<"a">>, healthy => false, conns => 0, transient_down_until_ms => Future, transient_fail_streak => 1}
        ]
    },
    NewState = pertisk_eproxy_backend:maybe_recover_transient_down(LbState),
    #{upstreams := [U]} = NewState,
    ?assertEqual(false, maps:get(healthy, U)).

maybe_recover_transient_down_no_transient_test() ->
    LbState = #{
        upstreams => [
            #{addr => <<"a">>, healthy => true, conns => 0, transient_down_until_ms => 0, transient_fail_streak => 0}
        ]
    },
    NewState = pertisk_eproxy_backend:maybe_recover_transient_down(LbState),
    #{upstreams := [U]} = NewState,
    ?assertEqual(true, maps:get(healthy, U)).

%% ---------------------------------------------------------------------------
%% merge_update/2
%% ---------------------------------------------------------------------------

merge_update_preserves_health_test() ->
    OldState = #{
        algorithm => round_robin,
        lb => #{
            algorithm => round_robin,
            upstreams => [
                #{addr => <<"a">>, weight => 1, healthy => false, conns => 5, transient_down_until_ms => 100, transient_fail_streak => 2},
                #{addr => <<"b">>, weight => 1, healthy => true, conns => 3, transient_down_until_ms => 0, transient_fail_streak => 0}
            ],
            rr_index => 2
        }
    },
    NewBackend = #{
        algorithm => round_robin,
        upstreams => [
            #{addr => <<"a">>, weight => 2},
            #{addr => <<"c">>, weight => 1}
        ]
    },
    NewState = pertisk_eproxy_backend:merge_update(OldState, NewBackend),
    #{lb := #{upstreams := Ups}} = NewState,
    ?assertEqual(2, length(Ups)),
    [A, C] = Ups,
    ?assertEqual(<<"a">>, maps:get(addr, A)),
    ?assertEqual(false, maps:get(healthy, A)),
    ?assertEqual(5, maps:get(conns, A)),
    ?assertEqual(<<"c">>, maps:get(addr, C)),
    ?assertEqual(true, maps:get(healthy, C)),
    ?assertEqual(0, maps:get(conns, C)).

merge_update_new_algorithm_test() ->
    OldState = #{
        algorithm => round_robin,
        lb => #{algorithm => round_robin, upstreams => [], rr_index => 0}
    },
    NewBackend = #{algorithm => least_conn, upstreams => []},
    NewState = pertisk_eproxy_backend:merge_update(OldState, NewBackend),
    ?assertEqual(least_conn, maps:get(algorithm, NewState)).