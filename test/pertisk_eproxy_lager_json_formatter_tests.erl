-module(pertisk_eproxy_lager_json_formatter_tests).

-include_lib("eunit/include/eunit.hrl").

format_returns_json_line_test() ->
    Msg = lager_msg:new(<<"hello">>, info, [], []),
    Line = pertisk_eproxy_lager_json_formatter:format(Msg, []),
    Bin = iolist_to_binary(Line),
    ?assertEqual($\n, binary:last(Bin)),
    {ok, Map} = thoas:decode(Bin),
    ?assertEqual(<<"hello">>, maps:get(<<"message">>, Map)),
    ?assertEqual(<<"info">>, maps:get(<<"level">>, Map)),
    ?assertEqual(<<"pertisk-eproxy">>, maps:get(<<"app">>, Map)).

format_three_arg_matches_two_arg_test() ->
    Msg = lager_msg:new(<<"warn msg">>, warning, [{site, <<"example.com">>}], []),
    Line2 = pertisk_eproxy_lager_json_formatter:format(Msg, []),
    Line3 = pertisk_eproxy_lager_json_formatter:format(Msg, [], []),
    ?assertEqual(Line2, Line3).

format_includes_metadata_test() ->
    Msg = lager_msg:new(<<"boom">>, error, [{request_id, <<"abc">>}], []),
    Bin = iolist_to_binary(pertisk_eproxy_lager_json_formatter:format(Msg, [])),
    {ok, Map} = thoas:decode(Bin),
    ?assertEqual(<<"abc">>, maps:get(<<"request_id">>, Map)).

format_escapes_newlines_in_message_test() ->
    Msg = lager_msg:new(<<"line\nbreak">>, info, [], []),
    Bin = iolist_to_binary(pertisk_eproxy_lager_json_formatter:format(Msg, [])),
    ?assertNotEqual(nomatch, binary:match(Bin, <<"\\n">>)).

encode_value_handles_map_metadata_test() ->
    Msg = lager_msg:new(<<"ok">>, notice, [{extra, #{<<"k">> => <<"v">>}}], []),
    Bin = iolist_to_binary(pertisk_eproxy_lager_json_formatter:format(Msg, [])),
    {ok, Map} = thoas:decode(Bin),
    Extra = maps:get(<<"extra">>, Map),
    ?assertEqual(#{<<"k">> => <<"v">>}, Extra).

format_encodes_numeric_and_bool_metadata_test() ->
    Msg = lager_msg:new(<<"n">>, info, [{count, 7}, {ok, true}, {ratio, 1.5}], []),
    Bin = iolist_to_binary(pertisk_eproxy_lager_json_formatter:format(Msg, [])),
    {ok, Map} = thoas:decode(Bin),
    ?assertEqual(7, maps:get(<<"count">>, Map)),
    ?assertEqual(true, maps:get(<<"ok">>, Map)),
    ?assertEqual(1.5, maps:get(<<"ratio">>, Map)).

format_encodes_pid_and_reference_metadata_test() ->
    Ref = make_ref(),
    Msg = lager_msg:new(<<"p">>, debug, [{worker, self()}, {ref, Ref}], []),
    Bin = iolist_to_binary(pertisk_eproxy_lager_json_formatter:format(Msg, [])),
    {ok, Map} = thoas:decode(Bin),
    ?assert(is_binary(maps:get(<<"worker">>, Map))),
    ?assert(is_binary(maps:get(<<"ref">>, Map))).

format_skips_internal_metadata_keys_test() ->
    Msg = lager_msg:new(<<"m">>, info, [{severity, emergency}, {function_arity, 2}, {site, <<"x">>}], []),
    Bin = iolist_to_binary(pertisk_eproxy_lager_json_formatter:format(Msg, [])),
    {ok, Map} = thoas:decode(Bin),
    ?assertEqual(false, maps:is_key(<<"severity">>, Map)),
    ?assertEqual(false, maps:is_key(<<"function_arity">>, Map)),
    ?assertEqual(<<"x">>, maps:get(<<"site">>, Map)).

format_custom_app_name_test() ->
    Old = application:get_env(pertisk_eproxy, log_app_name),
    application:set_env(pertisk_eproxy, log_app_name, <<"custom-app">>),
    try
        Msg = lager_msg:new(<<"app">>, info, [], []),
        Bin = iolist_to_binary(pertisk_eproxy_lager_json_formatter:format(Msg, [])),
        {ok, Map} = thoas:decode(Bin),
        ?assertEqual(<<"custom-app">>, maps:get(<<"app">>, Map))
    after
        case Old of
            {ok, V} -> application:set_env(pertisk_eproxy, log_app_name, V);
            undefined -> application:unset_env(pertisk_eproxy, log_app_name)
        end
    end.

format_escapes_quotes_in_message_test() ->
    Msg = lager_msg:new(<<"say \"hi\"">>, info, [], []),
    Bin = iolist_to_binary(pertisk_eproxy_lager_json_formatter:format(Msg, [])),
    ?assertNotEqual(nomatch, binary:match(Bin, <<"\\\"">>)).

format_binary_metadata_key_test() ->
    Msg = lager_msg:new(<<"k">>, info, [{<<"custom_key">>, <<"v">>}], []),
    Bin = iolist_to_binary(pertisk_eproxy_lager_json_formatter:format(Msg, [])),
    {ok, Map} = thoas:decode(Bin),
    ?assertEqual(<<"v">>, maps:get(<<"custom_key">>, Map)).

format_tuple_metadata_uses_printed_form_test() ->
    Msg = lager_msg:new(<<"tuple">>, info, [{ctx, {a, 1}}], []),
    Bin = iolist_to_binary(pertisk_eproxy_lager_json_formatter:format(Msg, [])),
    {ok, Map} = thoas:decode(Bin),
    ?assertEqual(<<"{a,1}">>, maps:get(<<"ctx">>, Map)).

format_integer_meta_key_test() ->
    Msg = lager_msg:new(<<"k">>, info, [{42, <<"v">>}], []),
    Bin = iolist_to_binary(pertisk_eproxy_lager_json_formatter:format(Msg, [])),
    {ok, Map} = thoas:decode(Bin),
    ?assertEqual(<<"v">>, maps:get(<<"42">>, Map)).

format_control_char_message_test() ->
    Msg = lager_msg:new(<<"tab\there">>, info, [], []),
    Bin = iolist_to_binary(pertisk_eproxy_lager_json_formatter:format(Msg, [])),
    {ok, Map} = thoas:decode(Bin),
    ?assertEqual(<<"tab\there">>, maps:get(<<"message">>, Map)).

format_nested_map_metadata_test() ->
    Msg = lager_msg:new(<<"nested">>, info, [{ctx, #{inner => #{flag => true}}}], []),
    Bin = iolist_to_binary(pertisk_eproxy_lager_json_formatter:format(Msg, [])),
    {ok, Map} = thoas:decode(Bin),
    ?assertEqual(#{<<"inner">> => #{<<"flag">> => true}}, maps:get(<<"ctx">>, Map)).

format_skips_sev_metadata_key_test() ->
    Msg = lager_msg:new(<<"m">>, info, [{sev, critical}, {site, <<"y">>}], []),
    Bin = iolist_to_binary(pertisk_eproxy_lager_json_formatter:format(Msg, [])),
    {ok, Map} = thoas:decode(Bin),
    ?assertEqual(false, maps:is_key(<<"sev">>, Map)),
    ?assertEqual(<<"y">>, maps:get(<<"site">>, Map)).

format_escapes_backslash_and_cr_test() ->
    Msg = lager_msg:new(<<"a\\b\rc">>, info, [], []),
    Bin = iolist_to_binary(pertisk_eproxy_lager_json_formatter:format(Msg, [])),
    ?assertNotEqual(nomatch, binary:match(Bin, <<"\\\\">>)),
    ?assertNotEqual(nomatch, binary:match(Bin, <<"\\r">>)).

format_list_message_metadata_test() ->
    Msg = lager_msg:new([<<"list">>, <<"msg">>], info, [], []),
    Bin = iolist_to_binary(pertisk_eproxy_lager_json_formatter:format(Msg, [])),
    {ok, Map} = thoas:decode(Bin),
    ?assertEqual(<<"listmsg">>, maps:get(<<"message">>, Map)).

format_atom_metadata_value_test() ->
    Msg = lager_msg:new(<<"a">>, info, [{mode, ready}], []),
    Bin = iolist_to_binary(pertisk_eproxy_lager_json_formatter:format(Msg, [])),
    {ok, Map} = thoas:decode(Bin),
    ?assertEqual(<<"ready">>, maps:get(<<"mode">>, Map)).

format_app_name_list_env_test() ->
    Old = application:get_env(pertisk_eproxy, log_app_name),
    persistent_term:erase({pertisk_eproxy_lager_json_formatter, app_name}),
    application:set_env(pertisk_eproxy, log_app_name, "list-app"),
    try
        Msg = lager_msg:new(<<"app">>, info, [], []),
        Bin = iolist_to_binary(pertisk_eproxy_lager_json_formatter:format(Msg, [])),
        {ok, Map} = thoas:decode(Bin),
        ?assertEqual(<<"list-app">>, maps:get(<<"app">>, Map))
    after
        persistent_term:erase({pertisk_eproxy_lager_json_formatter, app_name}),
        case Old of
            {ok, V} -> application:set_env(pertisk_eproxy, log_app_name, V);
            undefined -> application:unset_env(pertisk_eproxy, log_app_name)
        end
    end.

format_includes_timestamp_test() ->
    Msg = lager_msg:new(<<"ts">>, info, [], []),
    Bin = iolist_to_binary(pertisk_eproxy_lager_json_formatter:format(Msg, [])),
    {ok, Map} = thoas:decode(Bin),
    ?assert(is_binary(maps:get(<<"timestamp">>, Map))),
    ?assertNotEqual(nomatch, binary:match(maps:get(<<"timestamp">>, Map), <<"T">>)).

format_list_metadata_value_test() ->
    Msg = lager_msg:new(<<"m">>, info, [{labels, [<<"a">>, <<"b">>]}], []),
    Bin = iolist_to_binary(pertisk_eproxy_lager_json_formatter:format(Msg, [])),
    {ok, Map} = thoas:decode(Bin),
    ?assertEqual(<<"ab">>, maps:get(<<"labels">>, Map)).

format_non_atom_level_test() ->
    meck:new(lager_msg, [unstick, passthrough]),
    meck:expect(lager_msg, severity, fun(_) -> 42 end),
    try
        Msg = lager_msg:new(<<"lvl">>, info, [], []),
        Bin = iolist_to_binary(pertisk_eproxy_lager_json_formatter:format(Msg, [])),
        {ok, Map} = thoas:decode(Bin),
        ?assertEqual(42, maps:get(<<"level">>, Map))
    after
        pertisk_eproxy_test_helpers:unload_mocks([lager_msg])
    end.

format_timestamp_microseconds_test() ->
    meck:new(lager_msg, [unstick, passthrough]),
    meck:expect(lager_msg, timestamp, fun(_) -> {0, 1000, 123456} end),
    try
        Msg = lager_msg:new(<<"ts">>, info, [], []),
        Bin = iolist_to_binary(pertisk_eproxy_lager_json_formatter:format(Msg, [])),
        {ok, Map} = thoas:decode(Bin),
        Ts = maps:get(<<"timestamp">>, Map),
        ?assertNotEqual(nomatch, binary:match(Ts, <<".123456Z">>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([lager_msg])
    end.

format_float_meta_key_test() ->
    Msg = lager_msg:new(<<"k">>, info, [{1.5, <<"v">>}], []),
    Bin = iolist_to_binary(pertisk_eproxy_lager_json_formatter:format(Msg, [])),
    {ok, Map} = thoas:decode(Bin),
    ?assertEqual(<<"v">>, maps:get(<<"1.5">>, Map)).

format_function_metadata_value_test() ->
    Msg = lager_msg:new(<<"fn">>, info, [{callback, fun() -> ok end}], []),
    Bin = iolist_to_binary(pertisk_eproxy_lager_json_formatter:format(Msg, [])),
    {ok, Map} = thoas:decode(Bin),
    ?assert(is_binary(maps:get(<<"callback">>, Map))).

format_escape_low_control_char_test() ->
    Msg = lager_msg:new(<<16#01/utf8, "ctrl">>, info, [], []),
    Bin = iolist_to_binary(pertisk_eproxy_lager_json_formatter:format(Msg, [])),
    {ok, Map} = thoas:decode(Bin),
    ?assertEqual(<<16#01/utf8, "ctrl">>, maps:get(<<"message">>, Map)).

format_invalid_unicode_list_metadata_test() ->
    BadList = [16#D800],
    Msg = lager_msg:new(<<"bad">>, info, [{raw, BadList}], []),
    Bin = iolist_to_binary(pertisk_eproxy_lager_json_formatter:format(Msg, [])),
    {ok, Map} = thoas:decode(Bin),
    ?assert(is_binary(maps:get(<<"raw">>, Map))).

format_thoas_encode_throw_fallback_test() ->
    pertisk_eproxy_test_helpers:unload_mocks([lager_msg, thoas]),
    meck:new(thoas, [unstick, passthrough]),
    meck:expect(thoas, encode, fun
        (#{<<"timestamp">> := _} = Map) when is_map(Map) ->
            erlang:error(encode_failed);
        (Other) ->
            meck:passthrough([thoas, encode, [Other]])
    end),
    try
        Msg = lager_msg:new("ok", error, [], []),
        Bin = iolist_to_binary(pertisk_eproxy_lager_json_formatter:format(Msg, [])),
        ?assertEqual($\n, binary:last(Bin)),
        ?assertNotEqual(nomatch, binary:match(Bin, <<"log_format_error">>)),
        ?assertNotEqual(nomatch, binary:match(Bin, <<"\"message\":\"ok\"">>)),
        ?assertNotEqual(nomatch, binary:match(Bin, <<"\"level\":\"error\"">>))
    after
        pertisk_eproxy_test_helpers:unload_mocks([thoas])
    end.
