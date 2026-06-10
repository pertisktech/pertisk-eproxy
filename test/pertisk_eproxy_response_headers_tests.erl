-module(pertisk_eproxy_response_headers_tests).

-include_lib("eunit/include/eunit.hrl").

app_name_is_expected_constant_test() ->
    ?assertEqual(<<"pertisk-eproxy">>, pertisk_eproxy_response_headers:app_name()).

merge_adds_identity_headers_to_empty_map_test() ->
    Result = pertisk_eproxy_response_headers:merge(#{}),
    ?assert(is_map_key(<<"server">>, Result)),
    ?assert(is_map_key(<<"x-app-name">>, Result)),
    ?assert(is_map_key(<<"x-app-version">>, Result)).

merge_preserves_input_keys_test() ->
    Input = #{<<"x-custom">> => <<"custom-v">>, <<"x-other">> => <<"other-v">>},
    Result = pertisk_eproxy_response_headers:merge(Input),
    ?assertEqual(<<"custom-v">>, maps:get(<<"x-custom">>, Result)),
    ?assertEqual(<<"other-v">>, maps:get(<<"x-other">>, Result)).

merge_overwrites_existing_identity_keys_test() ->
    Input = #{<<"server">> => <<"old-srv">>, <<"x-app-name">> => <<"old-name">>},
    Result = pertisk_eproxy_response_headers:merge(Input),
    ?assertEqual(<<"pertisk-eproxy">>, maps:get(<<"x-app-name">>, Result)),
    ?assertNotEqual(<<"old-srv">>, maps:get(<<"server">>, Result)).

merge_h3_empty_list_returns_identity_only_test() ->
    Result = pertisk_eproxy_response_headers:merge_h3([]),
    ?assertEqual(3, length(Result)),
    Keys = [K || {K, _} <- Result],
    ?assert(lists:member(<<"server">>, Keys)),
    ?assert(lists:member(<<"x-app-name">>, Keys)),
    ?assert(lists:member(<<"x-app-version">>, Keys)).

merge_h3_strips_old_identity_keys_test() ->
    Input = [
        {<<"server">>, <<"old-srv">>},
        {<<"x-app-name">>, <<"old-name">>},
        {<<"x-app-version">>, <<"old-ver">>}
    ],
    Result = pertisk_eproxy_response_headers:merge_h3(Input),
    ?assertEqual(3, length(Result)).

merge_h3_preserves_non_identity_keys_test() ->
    Input = [{<<"x-custom">>, <<"custom-v">>}],
    Result = pertisk_eproxy_response_headers:merge_h3(Input),
    ?assertEqual(4, length(Result)),
    ?assertEqual(<<"custom-v">>, proplists:get_value(<<"x-custom">>, Result)).

merge_h3_strips_case_insensitive_test() ->
    Input = [{<<"Server">>, <<"old">>}],
    Result = pertisk_eproxy_response_headers:merge_h3(Input),
    ServerV = proplists:get_value(<<"server">>, Result),
    ?assertNotEqual(<<"old">>, ServerV).