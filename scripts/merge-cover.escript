#!/usr/bin/env escript
%% -*- erlang -*-
%%! -noshell
-mode(compile).

main([ChunkDir, OutFile, MinStr, "gate"]) ->
    Min = list_to_integer(MinStr),
    Ebin = ebin_dir(),
    Excl = cover_excl_mods(),
    ChunkFiles0 = lists:sort(filelib:wildcard(filename:join(ChunkDir, "*.coverdata"))),
    case ChunkFiles0 of
        [] ->
            io:format(standard_error, "no chunk files in ~s~n", [ChunkDir]),
            halt(1);
        _ ->
            ChunkFiles = sanitize_chunk_files(ChunkFiles0, Ebin),
            Best = filter_excl(best_per_module(ChunkFiles, Ebin), Excl),
            {TotalCovered, TotalLines, Modules, Below} = gate_stats(Best, Min),
            TotalPct =
                if TotalLines > 0 -> 100.0 * TotalCovered / TotalLines;
                   true -> 0.0
                end,
            ok = filelib:ensure_dir(OutFile),
            cover:compile_beam_directory(Ebin),
            lists:foreach(fun(F) -> cover:import(F) end, ChunkFiles),
            ok = export_ebin_only(OutFile, Ebin),
            print_summary(Modules, Best, TotalPct, Min, Below, Excl),
            case Below of
                [] when TotalPct >= Min -> halt(0);
                _ -> halt(1)
            end
    end;
main([ChunkDir, OutFile, "merge"]) ->
    Ebin = ebin_dir(),
    ChunkFiles0 = lists:sort(filelib:wildcard(filename:join(ChunkDir, "*.coverdata"))),
    case ChunkFiles0 of
        [] ->
            io:format(standard_error, "no chunk files in ~s~n", [ChunkDir]),
            halt(1);
        _ ->
            ChunkFiles = sanitize_chunk_files(ChunkFiles0, Ebin),
            ok = filelib:ensure_dir(OutFile),
            cover:compile_beam_directory(Ebin),
            lists:foreach(fun(F) -> cover:import(F) end, ChunkFiles),
            ok = export_ebin_only(OutFile, Ebin),
            Best = best_per_module(ChunkFiles, Ebin),
            Modules = lists:sort(maps:keys(Best)),
            TotalCovered = lists:sum([C || {C, _} <- maps:values(Best)]),
            TotalLines = lists:sum([T || {_, T} <- maps:values(Best)]),
            TotalPct =
                if TotalLines > 0 -> 100.0 * TotalCovered / TotalLines;
                   true -> 0.0
                end,
            io:format("merged ~p chunks -> ~s (best-per-module total ~.2f%%)~n",
                      [length(ChunkFiles), OutFile, TotalPct]),
            print_summary(Modules, Best, TotalPct, 0, [], []),
            halt(0)
    end;
main(_) ->
    io:format(standard_error,
              "usage:~n"
              "  merge-cover.escript CHUNK_DIR OUT merge~n"
              "  merge-cover.escript CHUNK_DIR OUT MIN gate~n", []),
    halt(2).

ebin_dir() ->
    filename:join([os:getenv("ROOT_DIR", "."), "_build/test/lib/pertisk_eproxy/ebin"]).

cover_excl_mods() ->
    Config = filename:join([os:getenv("ROOT_DIR", "."), "rebar.config"]),
    case file:consult(Config) of
        {ok, Terms} ->
            case proplists:get_value(cover_excl_mods, Terms, []) of
                L when is_list(L) -> L;
                _ -> []
            end;
        _ ->
            []
    end.

filter_excl(Best, Excl) ->
    maps:filter(fun(M, _) -> not lists:member(M, Excl) end, Best).

gate_stats(Best, Min) ->
    Modules = lists:sort(maps:keys(Best)),
    TotalCovered = lists:sum([C || {C, _} <- maps:values(Best)]),
    TotalLines = lists:sum([T || {_, T} <- maps:values(Best)]),
    Below = [{M, pct(C, T)} || M <- Modules, {C, T} <- [maps:get(M, Best)], pct(C, T) < Min],
    {TotalCovered, TotalLines, Modules, Below}.

best_per_module(ChunkFiles, Ebin) ->
    lists:foldl(
        fun(Chunk, Acc) ->
            cover:reset(),
            cover:compile_beam_directory(Ebin),
            cover:import(Chunk),
            {result, Modules, _} = cover:analyse(coverage, module),
            lists:foldl(
                fun({M, {C, NC}}, Inner) ->
                    T = C + NC,
                    P = pct(C, T),
                    case maps:find(M, Inner) of
                        {ok, {BestC, BestT}} ->
                            case P =< pct(BestC, BestT) of
                                true -> Inner;
                                false -> maps:put(M, {C, T}, Inner)
                            end;
                        _ ->
                            maps:put(M, {C, T}, Inner)
                    end
                end,
                Acc,
                [{M, {C, NC}} || {M, {C, NC}} <- Modules, C + NC > 0]
            )
        end,
        maps:new(),
        ChunkFiles
    ).

pct(C, T) when T > 0 -> 100.0 * C / T;
pct(_, _) -> 0.0.

%% Export only ebin modules to OutFile, stripping *_meck_original entries
%% that meck leaves in cover's tracking and that rebar3 cover can't load.
export_ebin_only(OutFile, Ebin) ->
    TmpFile = OutFile ++ ".meck_filter_tmp",
    ok = cover:export(TmpFile),
    EbinBeams = filelib:wildcard(filename:join(Ebin, "*.beam")),
    EbinSet = sets:from_list(
        [list_to_atom(filename:basename(F, ".beam")) || F <- EbinBeams]
    ),
    Res = case file:read_file(TmpFile) of
        {ok, Bin} ->
            Filtered = filter_coverdata_bin(Bin, EbinSet, <<>>),
            file:write_file(OutFile, Filtered);
        {error, _} = Err ->
            Err
    end,
    _ = file:delete(TmpFile),
    Res.

sanitize_chunk_files(ChunkFiles, Ebin) ->
    EbinBeams = filelib:wildcard(filename:join(Ebin, "*.beam")),
    EbinSet = sets:from_list(
        [list_to_atom(filename:basename(F, ".beam")) || F <- EbinBeams]
    ),
    TmpDir = filename:join([filename:dirname(hd(ChunkFiles)), ".sanitized"]),
    ok = filelib:ensure_dir(filename:join(TmpDir, "placeholder")),
    lists:map(
        fun(F) ->
            Target = filename:join(TmpDir, filename:basename(F)),
            case file:read_file(F) of
                {ok, Bin} ->
                    Filtered = filter_coverdata_bin(Bin, EbinSet, <<>>),
                    ok = file:write_file(Target, Filtered),
                    Target;
                {error, _} ->
                    F
            end
        end,
        ChunkFiles
    ).

%% Walk the .coverdata binary format: <<Sz:32/big, Term:Sz/binary>>* chunks.
%% Keep only chunks whose decoded {Module, _} Module is in EbinSet.
filter_coverdata_bin(<<>>, _Set, Acc) ->
    Acc;
filter_coverdata_bin(<<Sz:32/big, Chunk:Sz/binary, Rest/binary>>, Set, Acc) ->
    NewAcc =
        try binary_to_term(Chunk) of
            {Mod, _} ->
                case sets:is_element(Mod, Set) of
                    true  -> <<Acc/binary, Sz:32/big, Chunk/binary>>;
                    false -> Acc
                end;
            _ ->
                %% Unknown term shape – keep to be safe
                <<Acc/binary, Sz:32/big, Chunk/binary>>
        catch _:_ ->
            <<Acc/binary, Sz:32/big, Chunk/binary>>
        end,
    filter_coverdata_bin(Rest, Set, NewAcc);
filter_coverdata_bin(Trailing, _Set, Acc) when byte_size(Trailing) > 0 ->
    %% Trailing bytes that don't form a complete chunk – pass through unchanged
    <<Acc/binary, Trailing/binary>>.

print_summary(Modules, Best, TotalPct, Min, Below, Excl) ->
    io:format("~n  |--------------------------------------------|------------|~n"),
    io:format("  |                                    module  |  coverage  |~n"),
    io:format("  |--------------------------------------------|------------|~n"),
    lists:foreach(
        fun(M) ->
            {C, T} = maps:get(M, Best),
            io:format("  |  ~44s | ~8.2f%  |~n", [atom_to_list(M), pct(C, T)])
        end,
        Modules
    ),
    io:format("  |--------------------------------------------|------------|~n"),
    io:format("  |                                     total  | ~8.2f%  |~n", [TotalPct]),
    io:format("  |--------------------------------------------|------------|~n"),
    case Excl of
        [] -> ok;
        _ -> io:format("===> Excluded from gate (cover_excl_mods): ~p~n", [Excl])
    end,
    case Below of
        [] when Min > 0 ->
            io:format("===> Requiring ~p% coverage to pass. ~.2f% obtained (best-per-module)~n",
                      [Min, TotalPct]);
        [] ->
            ok;
        _ ->
            io:format("===> Modules below ~p%:~n", [Min]),
            lists:foreach(fun({M, P}) -> io:format("    ~p: ~.2f%~n", [M, P]) end, Below),
            io:format("===> Requiring ~p% coverage to pass. ~.2f% obtained (best-per-module)~n",
                      [Min, TotalPct])
    end.
