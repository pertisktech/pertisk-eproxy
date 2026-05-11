%%% SQLite database module for proxy configuration.
%%% Tables: sites, backends, upstreams, path_rewrites
%%% Uses system sqlite3 CLI (via Erlang ports) for pure Erlang compatibility.

-module(pertisk_eproxy_db).
-export([
    init/1,
    get_config/1,
    get_site/2,
    list_sites/1,
    insert_site/4,
    delete_site/2,
    get_backend/2,
    list_backends/1,
    insert_backend/5,
    insert_upstream/4,
    delete_backend/2
]).

-include_lib("lager/include/lager.hrl").

%% Initialize SQLite database with schema
%% Returns {ok, DbPath} tuple (DbPath is kept for compatibility, all ops use system sqlite3)
init(DbPath) ->
    %% Ensure database file exists (will be created by sqlite3 if needed)
    case filelib:is_dir(DbPath) of
        true ->
            lager:error("DB path ~s is a directory, not a file", [DbPath]),
            {error, is_directory};
        false ->
            case init_schema(DbPath) of
                ok ->
                    lager:info("Database initialized at ~s", [DbPath]),
                    {ok, DbPath};
                {error, Reason} ->
                    lager:error("Failed to initialize schema: ~p", [Reason]),
                    {error, Reason}
            end
    end.

%% Create tables if they don't exist
init_schema(DbPath) ->
    SQL = "CREATE TABLE IF NOT EXISTS backends (
        name TEXT PRIMARY KEY,
        algorithm TEXT NOT NULL,
        health_path TEXT,
        health_interval_secs INTEGER DEFAULT 30
    );
    CREATE TABLE IF NOT EXISTS upstreams (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        backend_name TEXT NOT NULL,
        addr TEXT NOT NULL,
        weight INTEGER DEFAULT 1,
        FOREIGN KEY(backend_name) REFERENCES backends(name)
    );
    CREATE TABLE IF NOT EXISTS sites (
        host TEXT PRIMARY KEY,
        backend TEXT NOT NULL,
        FOREIGN KEY(backend) REFERENCES backends(name)
    );
    CREATE TABLE IF NOT EXISTS path_rewrites (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        site_host TEXT NOT NULL,
        path TEXT NOT NULL,
        path_type TEXT DEFAULT 'prefix',
        rewrite TEXT,
        FOREIGN KEY(site_host) REFERENCES sites(host)
    );",
    case sqlite_exec(DbPath, SQL) of
        ok -> ok;
        {error, Reason} -> {error, Reason}
    end.

%% Execute SQL via system sqlite3 using shell
sqlite_exec(DbPath, SQL) ->
    EscapedSQL = escape_shell(SQL),
    Cmd = "sqlite3 " ++ DbPath ++ " " ++ EscapedSQL,
    Output = os:cmd(Cmd),
    case Output of
        "" -> ok;
        _ ->
            case string:str(Output, "Error") of
                0 -> ok;
                _ -> {error, {sqlite_error, Output}}
            end
    end.

%% Query using sqlite3 JSON output
sqlite_query(DbPath, SQL) ->
    EscapedSQL = escape_shell(SQL),
    Cmd = "sqlite3 -json " ++ DbPath ++ " " ++ EscapedSQL,
    Output = os:cmd(Cmd),
    case Output of
        "" -> {ok, []};
        _ ->
            try
                thoas:decode(list_to_binary(Output))
            catch
                _:Reason -> {error, {json_parse, Reason}}
            end
    end.

%% Escape shell special characters (single quote wrapping with escaped quotes inside)
escape_shell(Str) ->
    "'" ++ replace_quotes(Str) ++ "'".

replace_quotes(Str) ->
    replace_quotes(Str, []).

replace_quotes([], Acc) ->
    lists:reverse(Acc);
replace_quotes([39 | Rest], Acc) ->  %% 39 is '
    replace_quotes(Rest, [39, 92, 39 | Acc]);  %% Add '\''
replace_quotes([C | Rest], Acc) ->
    replace_quotes(Rest, [C | Acc]).

%% Load complete proxy config from database
get_config(DbPath) ->
    case list_sites(DbPath) of
        {ok, Sites} ->
            case list_backends(DbPath) of
                {ok, Backends} ->
                    {ok, #{sites => Sites, backends => Backends}};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% Get a single site with its routes
get_site(DbPath, Host) ->
    SQL = <<"SELECT host, backend FROM sites WHERE host = '", Host/binary, "'">> ,
    case sqlite_query(DbPath, SQL) of
        {ok, []} ->
            {error, not_found};
        {ok, [SiteData]} ->
            HostBin = maps:get(<<"host">>, SiteData),
            Backend = maps:get(<<"backend">>, SiteData),
            case get_routes(DbPath, HostBin) of
                {ok, Routes} ->
                    {ok, #{host => HostBin, backend => Backend, routes => Routes}};
                {error, Reason} ->
                    {error, Reason}
            end;
        {ok, _} ->
            {error, multiple_results};
        {error, Reason} ->
            {error, Reason}
    end.

get_routes(DbPath, Host) ->
    SQL = <<"SELECT path, path_type, rewrite FROM path_rewrites WHERE site_host = '", Host/binary, "' ORDER BY id">>,
    case sqlite_query(DbPath, SQL) of
        {ok, Rows} ->
            Routes = [
                #{path => Path, path_type => PathType, rewrite => Rewrite}
                || Row <- Rows,
                   Path <- [maps:get(<<"path">>, Row)],
                   PathType <- [maps:get(<<"path_type">>, Row)],
                   Rewrite <- [maps:get(<<"rewrite">>, Row, null)]
            ],
            {ok, Routes};
        {error, Reason} ->
            {error, Reason}
    end.

%% List all sites
list_sites(DbPath) ->
    SQL = <<"SELECT host, backend FROM sites ORDER BY host">>,
    case sqlite_query(DbPath, SQL) of
        {ok, Rows} ->
            Sites = [
                begin
                    HostBin = maps:get(<<"host">>, Row),
                    {ok, Routes} = get_routes(DbPath, HostBin),
                    Backend = maps:get(<<"backend">>, Row),
                    #{host => HostBin, backend => Backend, routes => Routes}
                end
                || Row <- Rows
            ],
            {ok, Sites};
        {error, Reason} ->
            {error, Reason}
    end.

%% Insert or update a site
insert_site(_DbPath, _Host, _Backend, _Routes) ->
    %% Not implemented in SQLite CLI mode - use direct SQL
    {error, not_implemented}.

%% Delete a site (also deletes associated routes)
delete_site(_DbPath, _Host) ->
    %% Not implemented in SQLite CLI mode - use direct SQL
    {error, not_implemented}.

%% Get a single backend with upstreams
get_backend(DbPath, Name) ->
    SQL = <<"SELECT name, algorithm, health_path, health_interval_secs FROM backends WHERE name = '", Name/binary, "'">>,
    case sqlite_query(DbPath, SQL) of
        {ok, []} ->
            {error, not_found};
        {ok, [BackendData]} ->
            BName = maps:get(<<"name">>, BackendData),
            Algo = maps:get(<<"algorithm">>, BackendData),
            HealthPath = maps:get(<<"health_path">>, BackendData, null),
            HealthInterval = maps:get(<<"health_interval_secs">>, BackendData, 30),
            case get_upstreams(DbPath, BName) of
                {ok, Upstreams} ->
                    {ok, #{
                        name => BName,
                        algorithm => Algo,
                        health_path => HealthPath,
                        health_interval_secs => HealthInterval,
                        upstreams => Upstreams
                    }};
                {error, Reason} ->
                    {error, Reason}
            end;
        {ok, _} ->
            {error, multiple_results};
        {error, Reason} ->
            {error, Reason}
    end.

get_upstreams(DbPath, BackendName) ->
    SQL = <<"SELECT addr, weight FROM upstreams WHERE backend_name = '", BackendName/binary, "' ORDER BY id">>,
    case sqlite_query(DbPath, SQL) of
        {ok, Rows} ->
            Upstreams = [
                #{addr => Addr, weight => Weight}
                || Row <- Rows,
                   Addr <- [maps:get(<<"addr">>, Row)],
                   Weight <- [maps:get(<<"weight">>, Row, 1)]
            ],
            {ok, Upstreams};
        {error, Reason} ->
            {error, Reason}
    end.

%% List all backends
list_backends(DbPath) ->
    SQL = <<"SELECT name, algorithm, health_path, health_interval_secs FROM backends ORDER BY name">>,
    case sqlite_query(DbPath, SQL) of
        {ok, Rows} ->
            Backends = [
                begin
                    BName = maps:get(<<"name">>, Row),
                    {ok, Ups} = get_upstreams(DbPath, BName),
                    Algo = maps:get(<<"algorithm">>, Row),
                    HealthPath = maps:get(<<"health_path">>, Row, null),
                    HealthInterval = maps:get(<<"health_interval_secs">>, Row, 30),
                    #{
                        name => BName,
                        algorithm => Algo,
                        health_path => HealthPath,
                        health_interval_secs => HealthInterval,
                        upstreams => Ups
                    }
                end
                || Row <- Rows
            ],
            {ok, Backends};
        {error, Reason} ->
            {error, Reason}
    end.

%% Insert or update a backend
insert_backend(_DbPath, _Name, _Algorithm, _HealthPath, _HealthInterval) ->
    %% Not implemented in SQLite CLI mode - use direct SQL
    {error, not_implemented}.

%% Insert an upstream for a backend
insert_upstream(_DbPath, _BackendName, _Addr, _Weight) ->
    %% Not implemented in SQLite CLI mode - use direct SQL
    {error, not_implemented}.

%% Delete a backend (also deletes associated upstreams)
delete_backend(_DbPath, _Name) ->
    %% Not implemented in SQLite CLI mode - use direct SQL
    {error, not_implemented}.
