-module(pertisk_eproxy_lager_json_formatter_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("lager/include/lager.hrl").

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
