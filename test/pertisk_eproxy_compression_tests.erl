%%%-------------------------------------------------------------------
%% @doc Unit tests for compression module
%% @end
%%%-------------------------------------------------------------------

-module(pertisk_eproxy_compression_tests).
-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%% Test cases
%%%===================================================================

get_supported_methods_test() ->
    {ok, _} = pertisk_eproxy_compression:start_link(),
    Methods = pertisk_eproxy_compression:get_supported_methods(),
    ?assert(is_list(Methods)),
    ?assert(length(Methods) > 0).

compress_with_gzip_test() ->
    {ok, _} = pertisk_eproxy_compression:start_link(),
    Data = <<"Hello, World!">>,
    {ok, Compressed} = pertisk_eproxy_compression:compress(gzip, Data),
    ?assert(is_binary(Compressed)).

decompress_with_gzip_test() ->
    {ok, _} = pertisk_eproxy_compression:start_link(),
    Data = <<"Hello, World!">>,
    {ok, Compressed} = pertisk_eproxy_compression:compress(gzip, Data),
    {ok, Decompressed} = pertisk_eproxy_compression:decompress(gzip, Compressed),
    ?assertEqual(Data, Decompressed).

unsupported_compression_test() ->
    {ok, _} = pertisk_eproxy_compression:start_link(),
    Data = <<"test">>,
    {error, unsupported_method} = pertisk_eproxy_compression:compress(unsupported, Data).
