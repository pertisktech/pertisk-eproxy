#!/usr/bin/env escript
%% -*- erlang -*-
%%! -noshell
-mode(compile).

main([ChunkFile, "inspect"]) ->
    Data = read_coverdata(ChunkFile),
    io:format("~p~n", [inspect_entry(Data)]),
    halt(0);
main([ChunkFile, OutFile]) ->
    Ebin = ebin_dir(),
    ok = filelib:ensure_dir(OutFile),
    cover:compile_beam_directory(Ebin),
    cover:import(ChunkFile),
    {result, Modules, _} = cover:analyse(coverage, module),
    Active = [M || {M, {C, _}} <- Modules, C > 0],
    Data = read_coverdata(ChunkFile),
    Filtered = filter_cover_entries(Data, Active),
    write_coverdata(OutFile, Filtered),
    io:format("filtered ~s -> ~s (~p active modules)~n",
              [ChunkFile, OutFile, length(Active)]),
    halt(0);
main([ChunkDir, OutFile, "merge"]) ->
    Ebin = ebin_dir(),
    ChunkFiles = lists:sort(filelib:wildcard(filename:join(ChunkDir, "*.coverdata"))),
    case ChunkFiles of
        [] ->
            io:format(standard_error, "no chunk files in ~s~n", [ChunkDir]),
            halt(1);
        _ ->
            ok = filelib:ensure_dir(OutFile),
            cover:compile_beam_directory(Ebin),
            lists:foreach(fun(F) -> cover:import(F) end, ChunkFiles),
            ok = cover:export(OutFile),
            io:format("merged ~p chunks -> ~s~n", [length(ChunkFiles), OutFile]),
            halt(0)
    end;
main(_) ->
    io:format(standard_error,
              "usage:~n"
              "  filter-cover.escript CHUNK inspect~n"
              "  filter-cover.escript CHUNK OUT~n"
              "  filter-cover.escript CHUNK_DIR OUT merge~n", []),
    halt(2).

ebin_dir() ->
    filename:join([os:getenv("ROOT_DIR", "."), "_build/test/lib/pertisk_eproxy/ebin"]).

inspect_entry(Data) ->
    {tag, entry_tag(Data), size_term(Data)}.

size_term(Data) when is_tuple(Data) -> {tuple, size(Data)};
size_term(Data) when is_list(Data) -> {list, length(Data)};
size_term(Data) when is_map(Data) -> {map, maps:size(Data)};
size_term(Data) when is_binary(Data) -> {binary, byte_size(Data)};
size_term(_) -> other.

entry_tag({file, Mod, _}) -> {file, Mod};
entry_tag({Mod, _}) when is_atom(Mod) -> {module, Mod};
entry_tag(Other) -> Other.

keep_entry({file, Mod, _}, Active) ->
    lists:member(Mod, Active);
keep_entry({Mod, _}, Active) when is_atom(Mod) ->
    lists:member(Mod, Active);
keep_entry(_, _) ->
    true.

filter_cover_entries(Data, Active) when is_list(Data) ->
    [Entry || Entry <- Data, keep_entry(Entry, Active)];
filter_cover_entries(Data, _Active) ->
    Data.

read_coverdata(File) ->
    {ok, Bin} = file:read_file(File),
    binary_to_term(coverdata_payload(Bin)).

coverdata_payload(Bin) ->
    case binary:match(Bin, <<131, 80>>) of
        {Pos, _} -> binary:part(Bin, Pos, byte_size(Bin) - Pos);
        nomatch -> Bin
    end.

write_coverdata(File, Data) ->
    ok = file:write_file(File, term_to_binary(Data, [compressed])).
