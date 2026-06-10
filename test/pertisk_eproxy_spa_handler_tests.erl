-module(pertisk_eproxy_spa_handler_tests).

-include_lib("eunit/include/eunit.hrl").

%% Only mock cowboy_req. Do not meck pertisk_eproxy_* or code — meck + cover leaves
%% *.coverdata in the repo root and mocking code can hang eunit.
unload_mocks(Mods) ->
    lists:foreach(
        fun(Mod) ->
            case lists:member(Mod, meck:mocked()) of
                true -> meck:unload(Mod);
                false -> ok
            end
        end,
        Mods
    ).

with_cowboy_req_mock(Fun) ->
    unload_mocks([cowboy_req]),
    application:ensure_all_started(lager),
    meck:new(cowboy_req, [unstick]),
    meck:expect(cowboy_req, host, fun(_) -> <<"admin.local">> end),
    meck:expect(cowboy_req, path, fun(_) -> <<"/">> end),
    meck:expect(cowboy_req, qs, fun(_) -> <<>> end),
    meck:expect(cowboy_req, headers, fun(_) -> #{} end),
    meck:expect(cowboy_req, scheme, fun(_) -> http end),
    meck:expect(cowboy_req, port, fun(_) -> 9080 end),
    meck:expect(cowboy_req, header, fun(_, _Req, Default) -> Default end),
    meck:expect(cowboy_req, reply, fun(_Code, _H, _B, Req) -> Req end),
    try
        Fun()
    after
        unload_mocks([cowboy_req])
    end.

admin_index_path() ->
    filename:join([code:priv_dir(pertisk_eproxy), "admin", "index.html"]).

init_serves_index_when_built_test() ->
    Index = admin_index_path(),
    Previous = read_index_or_undefined(Index),
    ok = filelib:ensure_dir(Index),
    ok = file:write_file(Index, <<"<html>spa</html>">>),
    try
        with_cowboy_req_mock(fun() ->
            Req = #{},
            {ok, Req2, spa} = pertisk_eproxy_spa_handler:init(Req, spa),
            ?assertEqual(Req, Req2)
        end)
    after
        restore_index(Index, Previous)
    end.

init_fallback_when_index_missing_test() ->
    Index = admin_index_path(),
    Previous = read_index_or_undefined(Index),
    _ = file:delete(Index),
    try
        with_cowboy_req_mock(fun() ->
            Req = #{},
            {ok, _Req2, spa} = pertisk_eproxy_spa_handler:init(Req, spa),
            ok
        end)
    after
        restore_index(Index, Previous)
    end.

read_index_or_undefined(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> {ok, Bin};
        {error, enoent} -> undefined;
        {error, _} -> undefined
    end.

restore_index(Path, undefined) ->
    _ = file:delete(Path),
    ok;
restore_index(Path, {ok, Bin}) ->
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Bin).
