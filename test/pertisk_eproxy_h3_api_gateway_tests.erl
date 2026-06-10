-module(pertisk_eproxy_h3_api_gateway_tests).

-include_lib("eunit/include/eunit.hrl").

ensure_config() ->
    application:ensure_all_started(lager),
    case whereis(pertisk_eproxy_config) of
        undefined -> {ok, _} = pertisk_eproxy_config:start_link();
        _ -> ok
    end.

management_listener_bind_stack_test() ->
    ensure_config(),
    {Bind, Stack} = pertisk_eproxy_h3_api_gateway:management_listener_bind_stack(),
    ?assert(is_binary(Bind)),
    ?assert(is_binary(Stack)),
    ?assert(byte_size(Bind) > 0),
    ?assert(byte_size(Stack) > 0).
