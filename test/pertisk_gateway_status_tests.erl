-module(pertisk_gateway_status_tests).

-include_lib("eunit/include/eunit.hrl").

gateway_address_from_ip_test() ->
    Addrs = pertisk_gateway_status:row_to_address(#{<<"ip">> => <<"10.1.1.83">>}),
    ?assertEqual([#{<<"type">> => <<"IPAddress">>, <<"value">> => <<"10.1.1.83">>}], Addrs).

gateway_address_from_hostname_test() ->
    Addrs = pertisk_gateway_status:row_to_address(#{<<"hostname">> => <<"lb.example.com">>}),
    ?assertEqual([#{<<"type">> => <<"Hostname">>, <<"value">> => <<"lb.example.com">>}], Addrs).

gateway_address_skips_empty_test() ->
    ?assertEqual([], pertisk_gateway_status:row_to_address(#{<<"ip">> => <<>>})).
