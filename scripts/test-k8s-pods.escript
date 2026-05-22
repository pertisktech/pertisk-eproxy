#!/usr/bin/env escript
%%! -noshell
main(_) ->
    _ = application:ensure_all_started([crypto, ssl, inets, jsx, hackney, lager]),
    Ns = <<"pertisk-eproxy">>,
    case pertisk_ingress_ekub:init() of
        {ok, Conn} ->
            dump_read("pod", ekub:read(pod, Ns, [], Conn)),
            dump_read("pods", ekub:read(pods, Ns, [], Conn)),
            case pertisk_eproxy_admin_kubernetes:pods(<<>>) of
                {ok, Rows} ->
                    io:format("admin pods: ~p rows~n", [length(Rows)]),
                    [io:format("  ~s~n", [maps:get(<<"name">>, R)]) || R <- Rows];
                E ->
                    io:format("admin pods error: ~p~n", [E])
            end,
            halt(0);
        E ->
            io:format("ekub init: ~p~n", [E]),
            halt(1)
    end.

dump_read(Label, {ok, List}) ->
    Items = items(List),
    io:format("~s: ~p items~n", [Label, length(Items)]),
    [io:format("  ~s~n", [name(P)]) || P <- lists:sublist(Items, 5)];
dump_read(Label, E) ->
    io:format("~s: ~p~n", [Label, E]).

items(#{<<"items">> := L}) when is_list(L) -> L;
items(L) when is_list(L) -> L;
items(O) when is_map(O) -> [O];
items(_) -> [].

name(#{<<"metadata">> := #{<<"name">> := N}}) -> N;
name(_) -> <<"?">>.
