#!/usr/bin/env escript
%%! -noshell
main([File]) ->
    Data = read_coverdata(File),
    io:format("~p~n", [data_summary(Data)]),
    halt();
main(_) ->
    io:format(standard_error, "usage: inspect-cover.escript FILE~n", []),
    halt(2).

data_summary(Data) when is_list(Data) ->
    [{Mod, cover_entry_summary(Entry)} || {Mod, Entry} <- Data, is_atom(Mod)];
data_summary(Data) ->
    {unknown, Data}.

cover_entry_summary(Entry) ->
    case Entry of
        {M, Cov} when is_atom(M) ->
            {module, M, cover_entry_summary(Cov)};
        List when is_list(List) ->
            {lines, length(List)};
        Map when is_map(Map) ->
            {map, maps:size(Map)};
        Tuple when is_tuple(Tuple) ->
            {tuple, size(Tuple)};
        Other ->
            Other
    end.

read_coverdata(File) ->
    {ok, Bin} = file:read_file(File),
    Payload =
        case Bin of
            <<131, 80, _Size:32, Rest/binary>> ->
                Rest;
            <<_, 131, 80, _Size:32, Rest/binary>> ->
                Rest;
            _ ->
                Bin
        end,
    binary_to_term(zlib:unzip(Payload)).
