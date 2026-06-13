#!/usr/bin/env escript
%% -*- erlang -*-
%%! -noshell
-mode(compile).

main([File]) ->
    [T | _] = [Term || {_, Term} <- read_all_terms(File)],
    dump(T, 0),
    halt(0).

dump(T, Depth) when Depth > 4 ->
    io:format("~*s...~n", [Depth * 2, ""]);
dump(T, Depth) when is_tuple(T) ->
    Indent = Depth * 2,
    io:format("~*s~p / ~p~n", [Indent, element(1, T), size(T)]),
    lists:foreach(fun(I) -> dump(element(I, T), Depth + 1) end, lists:seq(2, size(T)));
dump(T, Depth) when is_list(T) ->
    io:format("~*slist ~p~n", [Depth * 2, length(T)]),
    lists:foreach(fun(E) -> dump(E, Depth + 1) end, lists:sublist(T, 3));
dump(T, Depth) when is_atom(T) ->
    io:format("~*s~p~n", [Depth * 2, T]);
dump(T, Depth) when is_integer(T) ->
    io:format("~*s~p~n", [Depth * 2, T]);
dump(T, Depth) when is_binary(T) ->
    io:format("~*sbinary ~p~n", [Depth * 2, byte_size(T)]);
dump(_, Depth) ->
    io:format("~*sother~n", [Depth * 2]).

read_all_terms(File) ->
    {ok, Bin} = file:read_file(File),
    read_all_terms(Bin, []).

read_all_terms(Bin, Acc) ->
    case binary:match(Bin, <<131, 80>>) of
        {Pos, _} ->
            Prefix = binary:part(Bin, 0, Pos),
            Payload = binary:part(Bin, Pos, byte_size(Bin) - Pos),
            case safe_term(Payload) of
                {ok, Term, Rest1} when is_binary(Rest1), byte_size(Rest1) > 0 ->
                    read_all_terms(Rest1, [{Prefix, Term} | Acc]);
                {ok, Term, _} ->
                    lists:reverse([{Prefix, Term} | Acc]);
                error ->
                    nomatch
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
