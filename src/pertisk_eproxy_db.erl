%%% SQLite database module for proxy configuration.
%%% Tables: sites, backends, upstreams, path_rewrites
%%% Uses system sqlite3 CLI (via Erlang ports) for pure Erlang compatibility.

-module(pertisk_eproxy_db).
-export([
    init/1,
    get_config/1,
    get_runtime_config/1,
    put_runtime_config/2,
    list_certificates/1,
    insert_certificate/2,
    update_certificate/3,
    delete_certificate/2,
    ensure_certificates_seeded/2,
    list_dns_providers/1,
    insert_dns_provider/4,
    update_dns_provider/5,
    delete_dns_provider/2,
    ensure_dns_providers_seeded/2,
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
    );
    CREATE TABLE IF NOT EXISTS runtime_state (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS certificates (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE
    );
    CREATE TABLE IF NOT EXISTS dns_providers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        provider_type TEXT NOT NULL,
        credentials_json TEXT NOT NULL DEFAULT '{}'
    );",
    case sqlite_exec(DbPath, SQL) of
        ok -> ok;
        {error, Reason} -> {error, Reason}
    end.

%% Execute SQL via system sqlite3 using shell
sqlite_exec(DbPath, SQL) ->
    EscapedSQL = escape_shell(SQL),
    Cmd = "sqlite3 " ++ escape_shell(DbPath) ++ " " ++ EscapedSQL,
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
    Cmd = "sqlite3 -json " ++ escape_shell(DbPath) ++ " " ++ EscapedSQL,
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

%% Escape for shell with double quotes.
escape_shell(Str0) ->
    Str = to_list(Str0),
    "\"" ++ escape_double_quotes(Str) ++ "\"".

escape_double_quotes(Str) ->
    escape_double_quotes(Str, []).

escape_double_quotes([], Acc) ->
    lists:reverse(Acc);
escape_double_quotes([$\\ | Rest], Acc) ->
    escape_double_quotes(Rest, [$\\, $\\ | Acc]);
escape_double_quotes([$" | Rest], Acc) ->
    escape_double_quotes(Rest, [$", $\\ | Acc]);
escape_double_quotes([$$ | Rest], Acc) ->
    escape_double_quotes(Rest, [$$, $\\ | Acc]);
escape_double_quotes([$` | Rest], Acc) ->
    escape_double_quotes(Rest, [$`, $\\ | Acc]);
escape_double_quotes([C | Rest], Acc) ->
    escape_double_quotes(Rest, [C | Acc]).

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L.

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

%% ---------------------------------------------------------------------------
%% Runtime config persistence (full config term)
%% ---------------------------------------------------------------------------

-spec get_runtime_config(string()) -> {ok, map()} | not_found | {error, term()}.
get_runtime_config(DbPath) ->
    case ensure_runtime_state_table(DbPath) of
        ok ->
            SQL = "SELECT value FROM runtime_state WHERE key = 'runtime_config' LIMIT 1",
            case sqlite_query(DbPath, SQL) of
                {ok, []} ->
                    not_found;
                {ok, [Row | _]} ->
                    decode_runtime_value(maps:get(<<"value">>, Row, undefined));
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec put_runtime_config(string(), map()) -> ok | {error, term()}.
put_runtime_config(DbPath, Config) when is_map(Config) ->
    case ensure_runtime_state_table(DbPath) of
        ok ->
            Enc = binary_to_list(base64:encode(term_to_binary(Config))),
            SQL = "INSERT INTO runtime_state(key, value) VALUES('runtime_config', '" ++
                sql_escape(Enc) ++
                "') ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
            sqlite_exec(DbPath, SQL);
        {error, Reason} ->
            {error, Reason}
    end.

ensure_runtime_state_table(DbPath) ->
    SQL = "CREATE TABLE IF NOT EXISTS runtime_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);",
    sqlite_exec(DbPath, SQL).

ensure_certificates_table(DbPath) ->
    SQL = "CREATE TABLE IF NOT EXISTS certificates (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE);",
    sqlite_exec(DbPath, SQL).

ensure_dns_providers_table(DbPath) ->
    SQL = "CREATE TABLE IF NOT EXISTS dns_providers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE, provider_type TEXT NOT NULL, credentials_json TEXT NOT NULL DEFAULT '{}');",
    sqlite_exec(DbPath, SQL).

-spec list_certificates(string()) -> {ok, [map()]} | {error, term()}.
list_certificates(DbPath) ->
    case ensure_certificates_table(DbPath) of
        ok ->
            SQL = "SELECT id, name FROM certificates ORDER BY id",
            case sqlite_query(DbPath, SQL) of
                {ok, Rows} ->
                    {ok, [
                        #{
                            id => maps:get(<<"id">>, Row),
                            name => maps:get(<<"name">>, Row)
                        }
                        || Row <- Rows
                    ]};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec insert_certificate(string(), binary() | list()) -> {ok, integer()} | {error, term()}.
insert_certificate(DbPath, Name0) ->
    Name = string:trim(to_list(Name0)),
    case Name of
        [] ->
            {error, empty_name};
        _ ->
            case ensure_certificates_table(DbPath) of
                ok ->
                    InsertSQL = "INSERT INTO certificates(name) VALUES('" ++ sql_escape(Name) ++ "')",
                    case sqlite_exec(DbPath, InsertSQL) of
                        ok ->
                            IdSQL = "SELECT last_insert_rowid() AS id",
                            case sqlite_query(DbPath, IdSQL) of
                                {ok, [Row | _]} ->
                                    {ok, maps:get(<<"id">>, Row)};
                                _ ->
                                    {error, insert_failed}
                            end;
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

-spec update_certificate(string(), integer(), binary() | list()) -> ok | {error, term()}.
update_certificate(DbPath, Id, Name0) ->
    Name = string:trim(to_list(Name0)),
    case Name of
        [] ->
            {error, empty_name};
        _ ->
            case ensure_certificates_table(DbPath) of
                ok ->
                    ExistsSQL = "SELECT id FROM certificates WHERE id = " ++ integer_to_list(Id) ++ " LIMIT 1",
                    case sqlite_query(DbPath, ExistsSQL) of
                        {ok, []} ->
                            {error, not_found};
                        {ok, [_ | _]} ->
                            SQL = "UPDATE certificates SET name = '" ++ sql_escape(Name) ++ "' WHERE id = " ++ integer_to_list(Id),
                            sqlite_exec(DbPath, SQL);
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

-spec delete_certificate(string(), integer()) -> ok | {error, term()}.
delete_certificate(DbPath, Id) ->
    case ensure_certificates_table(DbPath) of
        ok ->
            SQL = "DELETE FROM certificates WHERE id = " ++ integer_to_list(Id),
            case sqlite_exec(DbPath, SQL) of
                ok ->
                    case sqlite_query(DbPath, "SELECT changes() AS n") of
                        {ok, [Row | _]} ->
                            case maps:get(<<"n">>, Row, 0) > 0 of
                                true -> ok;
                                false -> {error, not_found}
                            end;
                        _ ->
                            {error, not_found}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec ensure_certificates_seeded(string(), [binary() | list()]) -> ok | {error, term()}.
ensure_certificates_seeded(DbPath, Names) ->
    case ensure_certificates_table(DbPath) of
        ok ->
            lists:foreach(
                fun(N0) ->
                    N = string:trim(to_list(N0)),
                    case N of
                        [] -> ok;
                        _ ->
                            SQL = "INSERT OR IGNORE INTO certificates(name) VALUES('" ++ sql_escape(N) ++ "')",
                            _ = sqlite_exec(DbPath, SQL),
                            ok
                    end
                end,
                Names
            ),
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

-spec list_dns_providers(string()) -> {ok, [map()]} | {error, term()}.
list_dns_providers(DbPath) ->
    case ensure_dns_providers_table(DbPath) of
        ok ->
            SQL = "SELECT id, name, provider_type, credentials_json FROM dns_providers ORDER BY id",
            case sqlite_query(DbPath, SQL) of
                {ok, Rows} ->
                    {ok, [dns_row_to_map(Row) || Row <- Rows]};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

dns_row_to_map(Row) ->
    Cj = maps:get(<<"credentials_json">>, Row, <<"{}">>),
    Creds =
        case thoas:decode(iolist_to_binary(Cj)) of
            {ok, M} when is_map(M) -> M;
            _ -> #{}
        end,
    #{
        id => maps:get(<<"id">>, Row),
        name => maps:get(<<"name">>, Row),
        provider_type => maps:get(<<"provider_type">>, Row),
        credentials => Creds
    }.

-spec insert_dns_provider(string(), binary() | list(), binary() | list(), map()) -> {ok, integer()} | {error, term()}.
insert_dns_provider(DbPath, Name0, ProviderType0, Credentials) ->
    Name = string:trim(to_list(Name0)),
    Pt = string:trim(to_list(ProviderType0)),
    Cj = sql_escape(binary_to_list(thoas:encode(Credentials))),
    case {Name, Pt} of
        {[], _} -> {error, empty_name};
        {_, []} -> {error, empty_provider_type};
        _ ->
            case ensure_dns_providers_table(DbPath) of
                ok ->
                    SQL = "INSERT INTO dns_providers(name, provider_type, credentials_json) VALUES('" ++
                        sql_escape(Name) ++ "','" ++ sql_escape(Pt) ++ "','" ++ Cj ++ "')",
                    case sqlite_exec(DbPath, SQL) of
                        ok ->
                            case sqlite_query(DbPath, "SELECT last_insert_rowid() AS id") of
                                {ok, [Row | _]} -> {ok, maps:get(<<"id">>, Row)};
                                _ -> {error, insert_failed}
                            end;
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

-spec update_dns_provider(string(), integer(), binary() | list(), binary() | list(), map()) -> ok | {error, term()}.
update_dns_provider(DbPath, Id, Name0, ProviderType0, Credentials) ->
    Name = string:trim(to_list(Name0)),
    Pt = string:trim(to_list(ProviderType0)),
    Cj = sql_escape(binary_to_list(thoas:encode(Credentials))),
    case {Name, Pt} of
        {[], _} -> {error, empty_name};
        {_, []} -> {error, empty_provider_type};
        _ ->
            case ensure_dns_providers_table(DbPath) of
                ok ->
                    ExistsSQL = "SELECT id FROM dns_providers WHERE id = " ++ integer_to_list(Id) ++ " LIMIT 1",
                    case sqlite_query(DbPath, ExistsSQL) of
                        {ok, []} ->
                            {error, not_found};
                        {ok, [_ | _]} ->
                            SQL = "UPDATE dns_providers SET name='" ++ sql_escape(Name) ++
                                "', provider_type='" ++ sql_escape(Pt) ++
                                "', credentials_json='" ++ Cj ++
                                "' WHERE id = " ++ integer_to_list(Id),
                            sqlite_exec(DbPath, SQL);
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

-spec delete_dns_provider(string(), integer()) -> ok | {error, term()}.
delete_dns_provider(DbPath, Id) ->
    case ensure_dns_providers_table(DbPath) of
        ok ->
            SQL = "DELETE FROM dns_providers WHERE id = " ++ integer_to_list(Id),
            case sqlite_exec(DbPath, SQL) of
                ok ->
                    case sqlite_query(DbPath, "SELECT changes() AS n") of
                        {ok, [Row | _]} ->
                            case maps:get(<<"n">>, Row, 0) > 0 of
                                true -> ok;
                                false -> {error, not_found}
                            end;
                        _ -> {error, not_found}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec ensure_dns_providers_seeded(string(), [map()]) -> ok | {error, term()}.
ensure_dns_providers_seeded(DbPath, Providers) ->
    case ensure_dns_providers_table(DbPath) of
        ok ->
            lists:foreach(
                fun(P0) ->
                    P = case P0 of
                        #{name := _} -> P0;
                        _ -> #{}
                    end,
                    Name = string:trim(to_list(maps:get(name, P, ""))),
                    Pt = string:trim(to_list(maps:get(provider_type, P, "label"))),
                    Cred = case maps:get(credentials, P, #{}) of
                        M when is_map(M) -> M;
                        _ -> #{}
                    end,
                    case Name of
                        [] ->
                            ok;
                        _ ->
                            Cj = sql_escape(binary_to_list(thoas:encode(Cred))),
                            SQL = "INSERT OR IGNORE INTO dns_providers(name, provider_type, credentials_json) VALUES('" ++
                                sql_escape(Name) ++ "','" ++ sql_escape(Pt) ++ "','" ++ Cj ++ "')",
                            _ = sqlite_exec(DbPath, SQL),
                            ok
                    end
                end,
                Providers
            ),
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

decode_runtime_value(undefined) ->
    not_found;
decode_runtime_value(V0) ->
    try
        V = iolist_to_binary(V0),
        TermBin = base64:decode(V),
        case binary_to_term(TermBin, [safe]) of
            M when is_map(M) -> {ok, M};
            _ -> {error, invalid_runtime_config_term}
        end
    catch
        _:_ ->
            {error, invalid_runtime_config_encoding}
    end.

sql_escape(Str) when is_list(Str) ->
    lists:flatmap(
        fun($') -> "''";
           (C) -> [C]
        end,
        Str
    ).

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
