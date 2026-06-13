#!/usr/bin/env escript
%% -*- erlang -*-
%%! -noshell
-mode(compile).

main([File]) ->
    Terms = read_all_terms(File),
    io:format("terms ~p~n", [length(Terms)]),
    lists:foreach(fun(T) -> io:format("  ~p~n", [term_tag(T)]) end, lists:sublist(Terms, 10)),
    halt(0).

read_all_terms(File) ->
    {ok, Bin} = file:read_file(File),
    read_all_terms(Bin, []).

read_all_terms(<<>>, Acc) ->
    lists:reverse(Acc);
read_all_terms(Bin, Acc) ->
    case binary:match(Bin, <<131, 80>>) of
        {Pos, _} ->
            Rest0 = binary:part(Bin, Pos, byte_size(Bin) - Pos),
            case safe_term(Rest0) of
                {ok, Term, Rest1} ->
                    read_all_terms(Rest1, [Term | Acc]);
                error ->
                    <<_, Tail/binary>> = Rest0,
                    read_all_terms(Tail, Acc)
            end;
        nomatch ->
            lists:reverse(Acc)
    end.

safe_term(Bin) ->
    try
        {Term, Rest} = binary_to_term(Bin),
        {ok, Term, Rest}
    catch _:_ ->
        error
    end.

term_tag({file, Mod, _}) -> {file, Mod};
term_tag({Mod, _}) when is_atom(Mod) -> {module, Mod};
term_tag(T) -> {other, T}.
