#!/usr/bin/env escript
%% Initialize SQLite database with sample data from proxy.json

main([DbPath]) ->
    case pertisk_eproxy_db:init(DbPath) of
        {ok, Conn} ->
            io:format("Database initialized at ~s~n", [DbPath]),
            populate_sample_data(Conn),
            ok;
        {error, Reason} ->
            io:format("Error: ~p~n", [Reason]),
            halt(1)
    end;

main(_) ->
    io:format("Usage: init_db.escript <db_path>~n"),
    halt(1).

populate_sample_data(Conn) ->
    % Insert example backend
    case pertisk_eproxy_db:insert_backend(Conn, <<"example-backend">>, <<"round_robin">>, <<"/health">>, 30) of
        ok ->
            io:format("Inserted backend: example-backend~n");
        {error, Reason} ->
            io:format("Error inserting backend: ~p~n", [Reason])
    end,
    
    % Insert upstreams for the backend
    insert_upstream(Conn, <<"example-backend">>, <<"127.0.0.1:3000">>, 1),
    insert_upstream(Conn, <<"example-backend">>, <<"127.0.0.1:3001">>, 1),
    
    % Insert site
    case pertisk_eproxy_db:insert_site(Conn, <<"example.localhost">>, <<"example-backend">>, [
        #{path => <<"/">>, path_type => <<"prefix">>}
    ]) of
        ok ->
            io:format("Inserted site: example.localhost~n");
        {error, Reason} ->
            io:format("Error inserting site: ~p~n", [Reason])
    end,
    
    io:format("Sample data loaded~n").

insert_upstream(Conn, BackendName, Addr, Weight) ->
    case pertisk_eproxy_db:insert_upstream(Conn, BackendName, Addr, Weight) of
        ok ->
            io:format("Inserted upstream: ~s -> ~s (weight: ~w)~n", [BackendName, Addr, Weight]);
        {error, Reason} ->
            io:format("Error inserting upstream: ~p~n", [Reason])
    end.
