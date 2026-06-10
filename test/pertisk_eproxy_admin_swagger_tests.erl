-module(pertisk_eproxy_admin_swagger_tests).

-include_lib("eunit/include/eunit.hrl").

management_dispatch_compiles_test() ->
    Dispatch = pertisk_eproxy_admin_swagger:management_dispatch(),
    ?assert(is_list(Dispatch)),
    ?assert(length(Dispatch) > 0).

management_dispatch_includes_health_route_test() ->
    Dispatch = pertisk_eproxy_admin_swagger:management_dispatch(),
    Routes = routes_from_dispatch(Dispatch),
    ?assert(lists:any(fun route_matches_health/1, Routes)).

routes_from_dispatch([{_Host, Routes} | _]) when is_list(Routes) ->
    Routes;
routes_from_dispatch([{_Host, _Constraints, Routes} | _]) when is_list(Routes) ->
    Routes;
routes_from_dispatch(_) ->
    [].

route_matches_health({Path, _, pertisk_eproxy_admin_handler, health}) ->
    path_has_health(Path);
route_matches_health({Path, _, _, _}) ->
    path_has_health(Path);
route_matches_health(_) ->
    false.

path_has_health([<<"api">>, <<"health">> | _]) ->
    true;
path_has_health(Path) when is_list(Path) ->
    case lists:all(fun is_binary/1, Path) of
        true ->
            lists:member(<<"health">>, Path) andalso lists:member(<<"api">>, Path);
        false ->
            try string:find(Path, "/api/health") =/= nomatch
            catch _:_ -> false
            end
    end;
path_has_health(Path) when is_binary(Path) ->
    binary:match(Path, <<"/api/health">>) =/= nomatch;
path_has_health(_) ->
    false.
