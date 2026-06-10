-module(pertisk_eproxy_metrics_routes_tests).

-include_lib("eunit/include/eunit.hrl").

dispatch_includes_metrics_and_health_test() ->
    Dispatch = pertisk_eproxy_metrics_routes:dispatch(),
    Paths = collect_paths(Dispatch),
    ?assert(lists:member(<<"metrics">>, Paths)),
    ?assert(lists:member(<<"health">>, Paths)).

dispatch_handlers_are_metrics_handler_test() ->
    Dispatch = pertisk_eproxy_metrics_routes:dispatch(),
    Handlers = collect_handlers(Dispatch),
    lists:foreach(fun(Mod) -> ?assertEqual(pertisk_eproxy_metrics_handler, Mod) end, Handlers).

collect_paths(Routes) ->
    lists:flatmap(
        fun
            ({Path, _, _, _}) when is_list(Path) -> Path;
            ({'_', _, Inner}) when is_list(Inner) -> collect_paths(Inner);
            ({[Path], _, _, _}) -> [Path];
            (_) -> []
        end,
        Routes
    ).

collect_handlers(Routes) ->
    lists:flatmap(
        fun
            ({_, _, Mod, _}) when is_atom(Mod) -> [Mod];
            ({'_', _, Inner}) when is_list(Inner) -> collect_handlers(Inner);
            (_) -> []
        end,
        Routes
    ).
