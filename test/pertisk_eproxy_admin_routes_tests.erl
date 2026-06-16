-module(pertisk_eproxy_admin_routes_tests).

-include_lib("eunit/include/eunit.hrl").

api_routes_includes_health_test() ->
    Routes = pertisk_eproxy_admin_routes:api_routes(),
    ?assert(lists:any(fun({Path, _, _}) -> Path =:= "/api/health" end, Routes)).

api_routes_includes_config_test() ->
    Routes = pertisk_eproxy_admin_routes:api_routes(),
    ?assert(lists:any(fun({Path, _, _}) -> Path =:= "/api/config" end, Routes)).

dispatch_compiles_test() ->
    Dispatch = pertisk_eproxy_admin_routes:dispatch(),
    ?assert(is_list(Dispatch)).

management_ui_routes_include_spa_test() ->
    Routes = pertisk_eproxy_admin_routes:management_ui_routes(),
    ?assert(lists:any(fun({Path, Mod, _}) -> Path =:= "/" andalso Mod =:= pertisk_eproxy_spa_handler end, Routes)).

management_dispatch_compiles_test() ->
    Dispatch = pertisk_eproxy_admin_routes:management_dispatch(),
    ?assert(is_list(Dispatch)).

api_routes_all_use_admin_handler_or_ws_test() ->
    Routes = pertisk_eproxy_admin_routes:api_routes(),
    Allowed = [
        pertisk_eproxy_admin_handler,
        pertisk_eproxy_admin_ws_handler,
        pertisk_eproxy_admin_sse_handler
    ],
    lists:foreach(
        fun({_Path, Mod, _}) ->
            ?assert(lists:member(Mod, Allowed))
        end,
        Routes
    ).
