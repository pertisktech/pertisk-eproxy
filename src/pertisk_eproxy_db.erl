%%% SQLite database module for proxy configuration.
%%% Tables: sites, backends, upstreams, path_rewrites
%%% Uses the 'sqlite3' CLI via 'os:cmd/1' (requires the binary on disk; see
%%% {@link resolve_sqlite3_executable/0} and 'sqlite3_executable' in 'sys.config'
%%% when the VM has a minimal PATH and login fails with 'sqlite_json_decode').

-module(pertisk_eproxy_db).
-export([
    init/1,
    ensure_ready/1,
    db_file_exists/1,
    migrate_schema/1,
    get_config/1,
    get_runtime_config/1,
    put_runtime_config/2,
    list_certificates/1,
    insert_certificate/2,
    upsert_certificate_record/5,
    insert_certificate_pem/4,
    insert_certificate_pem/5,
    upsert_acme_certificate_pem/4,
    update_certificate_pem/4,
    update_certificate/3,
    delete_certificate/2,
    ensure_certificates_seeded/2,
    list_dns_providers/1,
    get_dns_provider_by_id/2,
    get_dns_provider_by_name/2,
    replace_dns_providers/2,
    insert_dns_provider/4,
    update_dns_provider/5,
    delete_dns_provider/2,
    delete_dns_provider_by_name/2,
    ensure_dns_providers_seeded/2,
    get_site/2,
    list_sites/1,
    insert_site/4,
    delete_site/2,
    get_backend/2,
    list_backends/1,
    insert_backend/5,
    insert_upstream/4,
    delete_backend/2,
    ensure_admin_users/1,
    verify_admin_login/3
]).

-include_lib("lager/include/lager.hrl").

%% @doc First deploy only: create 'proxy.db', schema, and default admin user.
-spec init(string()) -> {ok, string()} | {error, term()}.
init(DbPath) ->
    case filelib:is_dir(DbPath) of
        true ->
            lager:error("DB path ~s is a directory, not a file", [DbPath]),
            {error, is_directory};
        false ->
            case ensure_db_parent_dir(DbPath) of
                ok ->
                    case migrate_schema(DbPath) of
                        ok ->
                            _ = ensure_admin_users(DbPath),
                            lager:info("SQLite first deploy: created database at ~s", [DbPath]),
                            {ok, DbPath};
                        {error, Reason} ->
                            lager:error("Failed to initialize schema: ~p", [Reason]),
                            {error, Reason}
                    end;
                {error, Reason} ->
                    lager:error("Failed to create DB directory for ~s: ~p", [DbPath, Reason]),
                    {error, {db_dir, Reason}}
            end
    end.

%% @doc On every start: if 'proxy.db' exists run schema migration only; if not, config load creates it.
-spec ensure_ready(string()) -> {ok, string()} | {error, term()}.
ensure_ready(DbPath) ->
    case ensure_db_parent_dir(DbPath) of
        ok ->
            case db_file_exists(DbPath) of
                true ->
                    case migrate_schema(DbPath) of
                        ok ->
                            _ = ensure_admin_users(DbPath),
                            lager:info("SQLite migrate at ~s (existing database)", [DbPath]),
                            {ok, DbPath};
                        {error, Reason} ->
                            {error, Reason}
                    end;
                false ->
                    lager:info("SQLite ~s not found yet (first deploy)", [DbPath]),
                    {ok, DbPath}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec db_file_exists(string()) -> boolean().
db_file_exists(DbPath) ->
    sqlite3_path_is_usable_file(DbPath).

ensure_db_parent_dir(DbPath) ->
    case filelib:ensure_dir(DbPath) of
        ok -> ok;
        {error, Reason} -> {error, Reason}
    end.

%% @doc Idempotent schema migration ('CREATE TABLE IF NOT EXISTS' on every deploy).
-spec migrate_schema(string()) -> ok | {error, term()}.
migrate_schema(DbPath) ->
    SQL = "CREATE TABLE IF NOT EXISTS runtime_state (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS sites (
        host TEXT PRIMARY KEY,
        backend TEXT NOT NULL,
        certificate TEXT,
        dns_provider TEXT,
        challenge_type TEXT,
        wildcard INTEGER DEFAULT 0,
        acme_wildcard_base TEXT,
        advertise_http3 INTEGER DEFAULT 1,
        acme_contact_email TEXT,
        routes_json TEXT NOT NULL DEFAULT '[]'
    );
    CREATE TABLE IF NOT EXISTS certificates (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        cert_pem TEXT,
        key_pem TEXT,
        source_type TEXT NOT NULL DEFAULT 'acme'
    );
    CREATE TABLE IF NOT EXISTS dns_providers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        provider_type TEXT NOT NULL,
        credentials_json TEXT NOT NULL DEFAULT '{}',
        created_at TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE IF NOT EXISTS admin_users (
        username TEXT PRIMARY KEY,
        salt_b64 TEXT NOT NULL,
        pass_hash_b64 TEXT NOT NULL
    );",
    case sqlite_exec(DbPath, SQL) of
        ok -> ok;
        {error, Reason} -> {error, Reason}
    end.

%% @doc Resolve 'sqlite3' binary: optional 'application:get_env(pertisk_eproxy, sqlite3_executable)',
%% then 'os:find_executable/1', then common absolute paths (minimal systemd PATH).
-spec resolve_sqlite3_executable() -> {ok, string()} | {error, sqlite3_executable_not_found}.
resolve_sqlite3_executable() ->
    case application:get_env(pertisk_eproxy, sqlite3_executable) of
        {ok, Bin} when is_binary(Bin) ->
            sqlite3_exe_if_regular_file(binary_to_list(Bin));
        {ok, List} when is_list(List), List =/= [] ->
            sqlite3_exe_if_regular_file(List);
        _ ->
            case os:find_executable("sqlite3") of
                false ->
                    sqlite3_exe_first_existing(
                        ["/usr/bin/sqlite3", "/bin/sqlite3", "/usr/local/bin/sqlite3"]
                    );
                Path ->
                    {ok, Path}
            end
    end.

sqlite3_exe_if_regular_file(Path) ->
    case sqlite3_path_is_usable_file(Path) of
        true -> {ok, Path};
        false -> {error, sqlite3_executable_not_found}
    end.

sqlite3_exe_first_existing([]) ->
    {error, sqlite3_executable_not_found};
sqlite3_exe_first_existing([P | Rest]) ->
    case sqlite3_path_is_usable_file(P) of
        true -> {ok, P};
        false -> sqlite3_exe_first_existing(Rest)
    end.

%% 'filelib:is_regular_file/1' exists only from OTP 23+; keep compatible with older runtimes.
sqlite3_path_is_usable_file(Path) when is_list(Path) ->
    filelib:is_file(Path) andalso not filelib:is_dir(Path).

%% Execute SQL via system sqlite3 using shell
sqlite_exec(DbPath, SQL) ->
    case resolve_sqlite3_executable() of
        {error, _} = E ->
            E;
        {ok, Sqlite3} ->
            EscapedSQL = escape_shell(SQL),
            BusyMs = integer_to_list(sqlite_busy_timeout_ms()),
            Cmd =
                escape_shell(Sqlite3)
                    ++ " -cmd "
                    ++ escape_shell(".timeout " ++ BusyMs)
                    ++ " "
                    ++ escape_shell(DbPath)
                    ++ " "
                    ++ EscapedSQL,
            Output = os:cmd(Cmd),
            case Output of
                "" ->
                    ok;
                _ ->
                    case string:str(Output, "Error") of
                        0 ->
                            case sqlite3_shell_failure_output(Output) of
                                true -> {error, {sqlite3_cli, string:trim(Output, trailing, [$\n])}};
                                false -> ok
                            end;
                        _ ->
                            {error, {sqlite_error, Output}}
                    end
            end
    end.

%% Query using sqlite3 JSON output
sqlite_query(DbPath, SQL) ->
    case resolve_sqlite3_executable() of
        {error, _} = E ->
            E;
        {ok, Sqlite3} ->
            EscapedSQL = escape_shell(SQL),
            BusyMs = integer_to_list(sqlite_busy_timeout_ms()),
            Cmd =
                escape_shell(Sqlite3)
                    ++ " -cmd "
                    ++ escape_shell(".timeout " ++ BusyMs)
                    ++ " -json "
                    ++ escape_shell(DbPath)
                    ++ " "
                    ++ EscapedSQL,
            Output = os:cmd(Cmd),
            Trimmed = string:trim(Output),
            case Trimmed of
                "" ->
                    {ok, []};
                _ ->
                    Bin0 = list_to_binary(Trimmed),
                    Bin = sqlite_json_strip_bom(Bin0),
                    %% `sqlite3 -json` for SELECT always prints a JSON array (`[...]`). Anything else is
                    %% almost always a shell error (`/bin/sh: … sqlite3: not found`) — do not feed to thoas.
                    case sqlite_json_rows_looks_valid(Bin) of
                        false ->
                            {error, {sqlite3_cli, Trimmed}};
                        true ->
                            case thoas:decode(Bin) of
                                {ok, Rows} when is_list(Rows) ->
                                    {ok, Rows};
                                {ok, Other} ->
                                    {error, {sqlite_json_not_array, Other}};
                                {error, Err} ->
                                    case sqlite3_shell_failure_output(Trimmed) of
                                        true ->
                                            {error, {sqlite3_cli, Trimmed}};
                                        false ->
                                            {error, {sqlite_json_decode, Err, sqlite_output_preview(Bin)}}
                                    end
                            end
                    end
            end
    end.

sqlite_json_strip_bom(<<239, 187, 191, Rest/binary>>) ->
    Rest;
sqlite_json_strip_bom(Bin) ->
    Bin.

sqlite_json_rows_looks_valid(<<>>) ->
    false;
sqlite_json_rows_looks_valid(<<$[, _/binary>>) ->
    true;
sqlite_json_rows_looks_valid(_) ->
    false.

sqlite_output_preview(Bin) when is_binary(Bin), byte_size(Bin) > 240 ->
    binary:part(Bin, 0, 240);
sqlite_output_preview(Bin) when is_binary(Bin) ->
    Bin.

%% '/bin/sh: 1: sqlite3: not found' and similar (first printable byte often '/').
sqlite3_shell_failure_output(Output) when is_list(Output) ->
    case string:find(Output, "sqlite3") of
        nomatch ->
            false;
        _ ->
            case string:find(Output, "not found") of
                nomatch -> string:str(Output, "No such file") > 0;
                _ -> true
            end
    end.

sqlite_busy_timeout_ms() ->
    case application:get_env(pertisk_eproxy, sqlite_busy_timeout_ms) of
        {ok, Ms} when is_integer(Ms), Ms > 0 ->
            Ms;
        _ ->
            5000
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

normalize_db_text(undefined) -> "";
normalize_db_text(null) -> "";
normalize_db_text(B) when is_binary(B) -> binary_to_list(B);
normalize_db_text(L) when is_list(L) -> L;
normalize_db_text(_) -> "".

read_file_text(Path) when is_list(Path), Path =/= [] ->
    case file:read_file(Path) of
        {ok, Bin} -> binary_to_list(Bin);
        _ -> ""
    end;
read_file_text(_) ->
    "".

backfill_certificate_pem_content(DbPath) ->
    SQL = "SELECT id, cert_pem, key_pem FROM certificates",
    case sqlite_query(DbPath, SQL) of
        {ok, Rows} ->
            lists:foreach(
                fun(Row) ->
                    Id = maps:get(<<"id">>, Row),
                    CertPem0 = normalize_db_text(maps:get(<<"cert_pem">>, Row, undefined)),
                    KeyPem0 = normalize_db_text(maps:get(<<"key_pem">>, Row, undefined)),
                    CertPem = CertPem0,
                    KeyPem = KeyPem0,
                    case {CertPem =:= CertPem0, KeyPem =:= KeyPem0} of
                        {true, true} ->
                            ok;
                        _ ->
                            Upd =
                                "UPDATE certificates SET cert_pem='" ++ sql_escape(CertPem) ++
                                "', key_pem='" ++ sql_escape(KeyPem) ++
                                "' WHERE id = " ++ integer_to_list(Id),
                            _ = sqlite_exec(DbPath, Upd),
                            ok
                    end
                end,
                Rows
            ),
            ok;
        _ ->
            ok
    end.

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
            case sqlite_exec(DbPath, SQL) of
                ok ->
                    sync_sites_projection(DbPath, maps:get(sites, Config, []));
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

ensure_runtime_state_table(DbPath) ->
    SQL = "CREATE TABLE IF NOT EXISTS runtime_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);",
    sqlite_exec(DbPath, SQL).

ensure_sites_projection_table(DbPath) ->
    SQL =
        "CREATE TABLE IF NOT EXISTS sites ("
        "host TEXT PRIMARY KEY,"
        "backend TEXT NOT NULL,"
        "certificate TEXT,"
        "dns_provider TEXT,"
        "challenge_type TEXT,"
        "wildcard INTEGER DEFAULT 0,"
        "acme_wildcard_base TEXT,"
        "advertise_http3 INTEGER DEFAULT 1,"
        "acme_contact_email TEXT,"
        "routes_json TEXT NOT NULL DEFAULT '[]'"
        ");",
    case sqlite_exec(DbPath, SQL) of
        ok ->
            _ = sqlite_exec_ignore_duplicate_column(DbPath, "ALTER TABLE sites ADD COLUMN certificate TEXT"),
            _ = sqlite_exec_ignore_duplicate_column(DbPath, "ALTER TABLE sites ADD COLUMN dns_provider TEXT"),
            _ = sqlite_exec_ignore_duplicate_column(DbPath, "ALTER TABLE sites ADD COLUMN challenge_type TEXT"),
            _ = sqlite_exec_ignore_duplicate_column(DbPath, "ALTER TABLE sites ADD COLUMN wildcard INTEGER DEFAULT 0"),
            _ = sqlite_exec_ignore_duplicate_column(DbPath, "ALTER TABLE sites ADD COLUMN acme_wildcard_base TEXT"),
            _ = sqlite_exec_ignore_duplicate_column(DbPath, "ALTER TABLE sites ADD COLUMN advertise_http3 INTEGER DEFAULT 1"),
            _ = sqlite_exec_ignore_duplicate_column(DbPath, "ALTER TABLE sites ADD COLUMN acme_contact_email TEXT"),
            _ = sqlite_exec_ignore_duplicate_column(DbPath, "ALTER TABLE sites ADD COLUMN routes_json TEXT NOT NULL DEFAULT '[]'"),
            ok;
        Err ->
            Err
    end.

sync_sites_projection(DbPath, Sites) when is_list(Sites) ->
    case ensure_sites_projection_table(DbPath) of
        ok ->
            _ = sqlite_exec(DbPath, "DELETE FROM sites"),
            lists:foreach(fun(S) -> _ = insert_site_projection(DbPath, S) end, Sites),
            ok;
        {error, Reason} ->
            {error, Reason}
    end;
sync_sites_projection(_DbPath, _) ->
    ok.

insert_site_projection(DbPath, S) when is_map(S) ->
    Host = sql_escape(to_list(maps:get(host, S, ""))),
    Backend = sql_escape(to_list(maps:get(backend, S, ""))),
    Certificate = sql_escape(opt_text(maps:get(certificate, S, undefined))),
    DnsProvider = sql_escape(opt_text(maps:get(dns_provider, S, undefined))),
    ChallengeType = sql_escape(opt_text(maps:get(challenge_type, S, undefined))),
    Wildcard = bool_to_int(maps:get(wildcard, S, false)),
    WildcardBase = sql_escape(opt_text(maps:get(acme_wildcard_base, S, undefined))),
    AdvertiseHttp3 = bool_to_int(maps:get(advertise_http3, S, true)),
    ContactEmail = sql_escape(opt_text(maps:get(acme_contact_email, S, undefined))),
    RoutesJson = sql_escape(binary_to_list(thoas:encode(maps:get(routes, S, [])))),
    SQL =
        "INSERT INTO sites(host,backend,certificate,dns_provider,challenge_type,wildcard,acme_wildcard_base,advertise_http3,acme_contact_email,routes_json) VALUES('" ++
        Host ++ "','" ++ Backend ++ "','" ++ Certificate ++ "','" ++ DnsProvider ++ "','" ++ ChallengeType ++ "'," ++
        integer_to_list(Wildcard) ++ ",'" ++ WildcardBase ++ "'," ++ integer_to_list(AdvertiseHttp3) ++ ",'" ++
        ContactEmail ++ "','" ++ RoutesJson ++ "')",
    sqlite_exec(DbPath, SQL);
insert_site_projection(_DbPath, _) ->
    ok.

opt_text(undefined) -> "";
opt_text(null) -> "";
opt_text(V) when is_binary(V) -> binary_to_list(V);
opt_text(V) when is_list(V) -> V;
opt_text(V) when is_atom(V) -> atom_to_list(V);
opt_text(V) when is_integer(V) -> integer_to_list(V);
opt_text(_) -> "".

bool_to_int(true) -> 1;
bool_to_int(_) -> 0.

ensure_certificates_table(DbPath) ->
    SQL = "CREATE TABLE IF NOT EXISTS certificates (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE, cert_pem TEXT, key_pem TEXT, source_type TEXT NOT NULL DEFAULT 'acme');",
    case sqlite_exec(DbPath, SQL) of
        ok ->
            _ = sqlite_exec_ignore_duplicate_column(DbPath, "ALTER TABLE certificates ADD COLUMN cert_pem TEXT"),
            _ = sqlite_exec_ignore_duplicate_column(DbPath, "ALTER TABLE certificates ADD COLUMN key_pem TEXT"),
            _ = sqlite_exec_ignore_duplicate_column(DbPath, "ALTER TABLE certificates ADD COLUMN source_type TEXT NOT NULL DEFAULT 'acme'"),
            _ = backfill_certificate_pem_content(DbPath),
            ok;
        Err ->
            Err
    end.

sqlite_exec_ignore_duplicate_column(DbPath, SQL) ->
    case sqlite_exec(DbPath, SQL) of
        ok ->
            ok;
        {error, {sqlite_error, Msg}} ->
            case string:str(Msg, "duplicate column name") of
                0 -> {error, {sqlite_error, Msg}};
                _ -> ok
            end;
        {error, Reason} ->
            {error, Reason}
    end.

ensure_dns_providers_table(DbPath) ->
    SQL = "CREATE TABLE IF NOT EXISTS dns_providers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE, provider_type TEXT NOT NULL, credentials_json TEXT NOT NULL DEFAULT '{}', created_at TEXT NOT NULL DEFAULT '');",
    case sqlite_exec(DbPath, SQL) of
        ok ->
            _ = sqlite_exec_ignore_duplicate_column(DbPath, "ALTER TABLE dns_providers ADD COLUMN created_at TEXT"),
            _ = backfill_dns_provider_created_at(DbPath),
            ok;
        Err ->
            Err
    end.

backfill_dns_provider_created_at(DbPath) ->
    sqlite_exec(DbPath, "UPDATE dns_providers SET created_at = datetime('now') WHERE created_at IS NULL OR created_at = ''").

%% ---------------------------------------------------------------------------
%% Local admin users (SQLite; Bearer sessions issued by pertisk_eproxy_auth)
%% ---------------------------------------------------------------------------

-spec ensure_admin_users(string()) -> ok | {error, term()}.
ensure_admin_users(DbPath) ->
    SQL =
        "CREATE TABLE IF NOT EXISTS admin_users ("
        "username TEXT PRIMARY KEY,"
        "salt_b64 TEXT NOT NULL,"
        "pass_hash_b64 TEXT NOT NULL"
        ");",
    case sqlite_exec(DbPath, SQL) of
        ok ->
            seed_default_admin_if_empty(DbPath);
        Err ->
            Err
    end.

seed_default_admin_if_empty(DbPath) ->
    case sqlite_query(DbPath, "SELECT COUNT(*) AS n FROM admin_users") of
        {ok, [Row | _]} ->
            case admin_user_count_value(Row) of
                N when is_integer(N), N > 0 ->
                    ok;
                _ ->
                    insert_default_admin_user(DbPath)
            end;
        {ok, []} ->
            insert_default_admin_user(DbPath);
        {error, Reason} ->
            {error, Reason}
    end.

admin_user_count_value(Row) ->
    case maps:get(<<"n">>, Row, 0) of
        N when is_integer(N) ->
            N;
        N when is_float(N) ->
            erlang:round(N);
        N when is_binary(N) ->
            try binary_to_integer(N) of
                I -> I
            catch
                _:_ -> 0
            end;
        _ ->
            0
    end.

insert_default_admin_user(DbPath) ->
    Salt = crypto:strong_rand_bytes(16),
    Pass = <<"admin">>,
    Hash = crypto:hash(sha256, <<Salt/binary, Pass/binary>>),
    SaltB64 = binary_to_list(base64:encode(Salt)),
    HashB64 = binary_to_list(base64:encode(Hash)),
    Ins =
        "INSERT INTO admin_users(username, salt_b64, pass_hash_b64) VALUES('admin','" ++
            sql_escape(SaltB64) ++ "','" ++ sql_escape(HashB64) ++ "');",
    case sqlite_exec(DbPath, Ins) of
        ok ->
            lager:info("Seeded default local admin user (username: admin)", []),
            ok;
        Err ->
            Err
    end.

-spec verify_admin_login(string(), binary(), binary()) -> ok | {error, invalid_credentials | term()}.
verify_admin_login(DbPath, Username, Password) when is_binary(Username), is_binary(Password) ->
    UEsc = sql_escape(binary_to_list(Username)),
    Sql =
        "SELECT salt_b64, pass_hash_b64 FROM admin_users WHERE username = '" ++ UEsc ++ "' LIMIT 1",
    case sqlite_query(DbPath, Sql) of
        {ok, []} ->
            {error, invalid_credentials};
        {ok, [Row | _]} ->
            try
                SaltB64 = maps:get(<<"salt_b64">>, Row),
                WantB64 = maps:get(<<"pass_hash_b64">>, Row),
                Salt = base64:decode(SaltB64),
                Want = base64:decode(WantB64),
                Got = crypto:hash(sha256, <<Salt/binary, Password/binary>>),
                case crypto:hash_equals(Want, Got) of
                    true -> ok;
                    false -> {error, invalid_credentials}
                end
            catch
                _:_ ->
                    {error, invalid_credentials}
            end;
        {error, Reason} ->
            {error, Reason}
    end;
verify_admin_login(_DbPath, _, _) ->
    {error, invalid_credentials}.

-spec list_certificates(string()) -> {ok, [map()]} | {error, term()}.
list_certificates(DbPath) ->
    case ensure_certificates_table(DbPath) of
        ok ->
            SQL = "SELECT id, name, cert_pem, key_pem, source_type FROM certificates ORDER BY id",
            case sqlite_query(DbPath, SQL) of
                {ok, Rows} ->
                    {ok, [
                        #{
                            id => maps:get(<<"id">>, Row),
                            name => maps:get(<<"name">>, Row),
                            cert_pem => maps:get(<<"cert_pem">>, Row, undefined),
                            key_pem => maps:get(<<"key_pem">>, Row, undefined),
                            source_type => maps:get(<<"source_type">>, Row, <<"acme">>)
                        }
                        || Row <- Rows
                    ]};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec upsert_certificate_record(string(), binary() | list(), binary() | list(), binary() | list(), binary() | list()) -> {ok, integer()} | {error, term()}.
upsert_certificate_record(DbPath, Name0, CertPem0, KeyPem0, SourceType0) ->
    Name = string:trim(to_list(Name0)),
    CertPem = to_list(CertPem0),
    KeyPem = to_list(KeyPem0),
    SourceType = string:trim(to_list(SourceType0)),
    case Name of
        [] ->
            {error, empty_name};
        _ ->
            case ensure_certificates_table(DbPath) of
                ok ->
                    SelectSQL = "SELECT id FROM certificates WHERE name = '" ++ sql_escape(Name) ++ "' LIMIT 1",
                    case sqlite_query(DbPath, SelectSQL) of
                        {ok, [Row | _]} ->
                            Id = maps:get(<<"id">>, Row),
                            SQL = "UPDATE certificates SET cert_pem='" ++ sql_escape(CertPem) ++
                                "', key_pem='" ++ sql_escape(KeyPem) ++
                                "', source_type='" ++ sql_escape(SourceType) ++
                                "' WHERE id = " ++ integer_to_list(Id),
                            case sqlite_exec(DbPath, SQL) of
                                ok -> {ok, Id};
                                {error, Reason} -> {error, Reason}
                            end;
                        {ok, []} ->
                            SQL = "INSERT INTO certificates(name, cert_pem, key_pem, source_type) VALUES('" ++
                                sql_escape(Name) ++ "','" ++ sql_escape(CertPem) ++ "','" ++ sql_escape(KeyPem) ++ "','" ++ sql_escape(SourceType) ++ "')",
                            case sqlite_exec(DbPath, SQL) of
                                ok ->
                                    IdSQL = "SELECT id FROM certificates WHERE name = '" ++ sql_escape(Name) ++ "' ORDER BY id DESC LIMIT 1",
                                    case sqlite_query(DbPath, IdSQL) of
                                        {ok, [Row2 | _]} -> {ok, maps:get(<<"id">>, Row2)};
                                        _ -> {error, insert_failed}
                                    end;
                                {error, Reason} -> {error, Reason}
                            end;
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
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
                            IdSQL = "SELECT id FROM certificates WHERE name = '" ++ sql_escape(Name) ++ "' ORDER BY id DESC LIMIT 1",
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

-spec insert_certificate_pem(string(), binary() | list(), binary() | list(), binary() | list()) -> {ok, integer()} | {error, term()}.
insert_certificate_pem(DbPath, Name0, CertFile0, KeyFile0) ->
    insert_certificate_pem(DbPath, Name0, CertFile0, KeyFile0, <<"imported_pem">>).

-spec insert_certificate_pem(string(), binary() | list(), binary() | list(), binary() | list(), binary() | list()) ->
    {ok, integer()} | {error, term()}.
insert_certificate_pem(DbPath, Name0, CertFile0, KeyFile0, SourceType0) ->
    Name = string:trim(to_list(Name0)),
    CertFile = string:trim(to_list(CertFile0)),
    KeyFile = string:trim(to_list(KeyFile0)),
    CertPem = read_file_text(CertFile),
    KeyPem = read_file_text(KeyFile),
    SourceType = sql_escape(to_list(SourceType0)),
    case {Name, CertFile, KeyFile} of
        {[], _, _} ->
            {error, empty_name};
        {_, [], _} ->
            {error, empty_cert_file};
        {_, _, []} ->
            {error, empty_key_file};
        _ ->
            case ensure_certificates_table(DbPath) of
                ok ->
                    SQL = "INSERT INTO certificates(name, cert_pem, key_pem, source_type) VALUES('" ++
                        sql_escape(Name) ++ "','" ++
                        sql_escape(CertPem) ++ "','" ++ sql_escape(KeyPem) ++ "','" ++ SourceType ++ "')",
                    case sqlite_exec(DbPath, SQL) of
                        ok ->
                            IdSQL = "SELECT id FROM certificates WHERE name = '" ++ sql_escape(Name) ++ "' ORDER BY id DESC LIMIT 1",
                            case sqlite_query(DbPath, IdSQL) of
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

-spec upsert_acme_certificate_pem(string(), binary() | list(), binary() | list(), binary() | list()) ->
    {ok, integer()} | {error, term()}.
upsert_acme_certificate_pem(DbPath, Name0, CertFile0, KeyFile0) ->
    Name = string:trim(to_list(Name0)),
    CertFile = string:trim(to_list(CertFile0)),
    KeyFile = string:trim(to_list(KeyFile0)),
    CertPem = read_file_text(CertFile),
    KeyPem = read_file_text(KeyFile),
    case {Name, CertFile, KeyFile} of
        {[], _, _} ->
            {error, empty_name};
        {_, [], _} ->
            {error, empty_cert_file};
        {_, _, []} ->
            {error, empty_key_file};
        _ ->
            case ensure_certificates_table(DbPath) of
                ok ->
                    Sel = "SELECT id FROM certificates WHERE name = '" ++ sql_escape(Name) ++ "' LIMIT 1",
                    case sqlite_query(DbPath, Sel) of
                        {ok, [Row | _]} ->
                            Id = maps:get(<<"id">>, Row),
                            Upd = "UPDATE certificates SET cert_pem='" ++ sql_escape(CertPem) ++
                                "', key_pem='" ++ sql_escape(KeyPem) ++
                                "', source_type='acme' WHERE id = " ++ integer_to_list(Id),
                            case sqlite_exec(DbPath, Upd) of
                                ok -> {ok, Id};
                                {error, R} -> {error, R}
                            end;
                        {ok, []} ->
                            insert_certificate_pem(DbPath, Name, CertFile, KeyFile, <<"acme">>);
                        {error, R} ->
                            {error, R}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

-spec update_certificate_pem(string(), integer(), binary() | list(), binary() | list()) -> ok | {error, term()}.
update_certificate_pem(DbPath, Id, CertFile0, KeyFile0) ->
    CertFile = string:trim(to_list(CertFile0)),
    KeyFile = string:trim(to_list(KeyFile0)),
    CertPem = read_file_text(CertFile),
    KeyPem = read_file_text(KeyFile),
    case {CertFile, KeyFile} of
        {[], _} ->
            {error, empty_cert_file};
        {_, []} ->
            {error, empty_key_file};
        _ ->
            case ensure_certificates_table(DbPath) of
                ok ->
                    ExistsSQL = "SELECT id FROM certificates WHERE id = " ++ integer_to_list(Id) ++ " LIMIT 1",
                    case sqlite_query(DbPath, ExistsSQL) of
                        {ok, []} ->
                            {error, not_found};
                        {ok, [_ | _]} ->
                            SQL = "UPDATE certificates SET cert_pem='" ++ sql_escape(CertPem) ++
                                "', key_pem='" ++ sql_escape(KeyPem) ++
                                "', source_type='imported_pem' WHERE id = " ++ integer_to_list(Id),
                            sqlite_exec(DbPath, SQL);
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
            _ = cleanup_placeholder_certificate_rows(DbPath),
            lists:foreach(
                fun(N0) ->
                    N = string:trim(to_list(N0)),
                    case N of
                        [] -> ok;
                        _ ->
                            case is_seedable_certificate_name(N) of
                                true ->
                                    SQL = "INSERT OR IGNORE INTO certificates(name) VALUES('" ++ sql_escape(N) ++ "')",
                                    _ = sqlite_exec(DbPath, SQL),
                                    ok;
                                false ->
                                    ok
                            end
                    end
                end,
                Names
            ),
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

cleanup_placeholder_certificate_rows(DbPath) ->
    %% Legacy bug could seed numeric site cert refs (e.g. "1", "2") as ACME rows.
    %% Remove only rows that are numeric names with no PEM material.
    Sql =
        "DELETE FROM certificates " ++
        "WHERE source_type = 'acme' " ++
        "AND (cert_pem IS NULL OR trim(cert_pem) = '') " ++
        "AND trim(name) GLOB '[0-9]*' " ++
        "AND trim(name) NOT GLOB '*[^0-9]*'",
    sqlite_exec(DbPath, Sql).

is_seedable_certificate_name(Name) when is_list(Name), Name =/= [] ->
    not lists:all(fun(C) -> C >= $0 andalso C =< $9 end, Name);
is_seedable_certificate_name(_) ->
    false.

-spec list_dns_providers(string()) -> {ok, [map()]} | {error, term()}.
list_dns_providers(DbPath) ->
    case ensure_dns_providers_table(DbPath) of
        ok ->
            SQL = "SELECT id, name, provider_type, credentials_json, created_at FROM dns_providers ORDER BY id",
            case sqlite_query(DbPath, SQL) of
                {ok, Rows} ->
                    {ok, [dns_row_to_map(Row) || Row <- Rows]};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec get_dns_provider_by_id(string(), integer()) -> {ok, map()} | {error, not_found | term()}.
get_dns_provider_by_id(DbPath, Id) when is_integer(Id) ->
    case ensure_dns_providers_table(DbPath) of
        ok ->
            SQL =
                "SELECT id, name, provider_type, credentials_json, created_at FROM dns_providers WHERE id = " ++
                integer_to_list(Id) ++ " LIMIT 1",
            case sqlite_query(DbPath, SQL) of
                {ok, [Row | _]} ->
                    {ok, dns_row_to_map(Row)};
                {ok, []} ->
                    {error, not_found};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec get_dns_provider_by_name(string(), binary() | list()) -> {ok, map()} | {error, not_found | term()}.
get_dns_provider_by_name(DbPath, Name0) ->
    Name = string:trim(to_list(Name0)),
    case Name of
        [] ->
            {error, not_found};
        _ ->
            case ensure_dns_providers_table(DbPath) of
                ok ->
                    SQL =
                        "SELECT id, name, provider_type, credentials_json, created_at FROM dns_providers " ++
                        "WHERE lower(trim(name)) = lower(trim('" ++ sql_escape(Name) ++ "')) LIMIT 1",
                    case sqlite_query(DbPath, SQL) of
                        {ok, [Row | _]} ->
                            {ok, dns_row_to_map(Row)};
                        {ok, []} ->
                            {error, not_found};
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

-spec replace_dns_providers(string(), [map()]) -> ok | {error, term()}.
replace_dns_providers(DbPath, Providers0) ->
    Providers = [P || P <- Providers0, is_map(P)],
    case ensure_dns_providers_table(DbPath) of
        ok ->
            case sqlite_exec(DbPath, "DELETE FROM dns_providers") of
                ok ->
                    replace_dns_providers_insert(DbPath, Providers);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

replace_dns_providers_insert(_DbPath, []) ->
    ok;
replace_dns_providers_insert(DbPath, [P | Rest]) ->
    Name = string:trim(to_list(maps:get(name, P, ""))),
    Pt = string:trim(to_list(maps:get(provider_type, P, "label"))),
    Cred =
        case maps:get(credentials, P, #{}) of
            M when is_map(M) -> M;
            _ -> #{}
        end,
    case {Name, Pt} of
        {[], _} ->
            replace_dns_providers_insert(DbPath, Rest);
        {_, []} ->
            replace_dns_providers_insert(DbPath, Rest);
        _ ->
            Cj = sql_escape(binary_to_list(thoas:encode(Cred))),
            SQL =
                "INSERT INTO dns_providers(name, provider_type, credentials_json, created_at) VALUES('" ++
                sql_escape(Name) ++ "','" ++ sql_escape(Pt) ++ "','" ++ Cj ++ "', datetime('now'))",
            case sqlite_exec(DbPath, SQL) of
                ok ->
                    replace_dns_providers_insert(DbPath, Rest);
                {error, Reason} ->
                    {error, Reason}
            end
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
        credentials => Creds,
        created_at => maps:get(<<"created_at">>, Row, <<>>)
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
                    SQL = "INSERT INTO dns_providers(name, provider_type, credentials_json, created_at) VALUES('" ++
                        sql_escape(Name) ++ "','" ++ sql_escape(Pt) ++ "','" ++ Cj ++ "', datetime('now'))",
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
            ExistsSQL = "SELECT id FROM dns_providers WHERE id = " ++ integer_to_list(Id) ++ " LIMIT 1",
            case sqlite_query(DbPath, ExistsSQL) of
                {ok, []} ->
                    {error, not_found};
                {ok, [_ | _]} ->
                    SQL = "DELETE FROM dns_providers WHERE id = " ++ integer_to_list(Id),
                    sqlite_exec(DbPath, SQL);
                {error, {sqlite3_cli, Msg}} ->
                    case string:str(string:trim(Msg), "Error:") of
                        1 -> {error, {sqlite_error, Msg}};
                        _ -> {error, {sqlite3_cli, Msg}}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec delete_dns_provider_by_name(string(), binary() | list()) -> ok | {error, term()}.
delete_dns_provider_by_name(DbPath, Name0) ->
    Name = string:trim(to_list(Name0)),
    case Name of
        [] ->
            {error, not_found};
        _ ->
            case ensure_dns_providers_table(DbPath) of
                ok ->
                    ExistsSQL =
                        "SELECT id FROM dns_providers WHERE lower(trim(name)) = lower(trim('" ++
                        sql_escape(Name) ++ "')) LIMIT 1",
                    case sqlite_query(DbPath, ExistsSQL) of
                        {ok, []} ->
                            {error, not_found};
                        {ok, [_ | _]} ->
                            SQL =
                                "DELETE FROM dns_providers WHERE lower(trim(name)) = lower(trim('" ++
                                sql_escape(Name) ++ "'))",
                            sqlite_exec(DbPath, SQL);
                        {error, {sqlite3_cli, Msg}} ->
                            case string:str(string:trim(Msg), "Error:") of
                                1 -> {error, {sqlite_error, Msg}};
                                _ -> {error, {sqlite3_cli, Msg}}
                            end;
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
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
                            SQL = "INSERT OR IGNORE INTO dns_providers(name, provider_type, credentials_json, created_at) VALUES('" ++
                                sql_escape(Name) ++ "','" ++ sql_escape(Pt) ++ "','" ++ Cj ++ "', datetime('now'))",
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
        decode_runtime_term(TermBin)
    catch
        _:_ ->
            {error, invalid_runtime_config_encoding}
    end.

decode_runtime_term(TermBin) when is_binary(TermBin) ->
    case catch binary_to_term(TermBin, [safe]) of
        M when is_map(M) ->
            {ok, normalize_runtime_config_term(M)};
        _ ->
            decode_runtime_term_unsafe(TermBin)
    end.

decode_runtime_term_unsafe(TermBin) when is_binary(TermBin) ->
    case catch binary_to_term(TermBin) of
        M when is_map(M) ->
            {ok, normalize_runtime_config_term(M)};
        {'EXIT', _} ->
            {error, invalid_runtime_config_encoding};
        _ ->
            {error, invalid_runtime_config_term}
    end.

normalize_runtime_config_term(#{mode := proxy_admin} = M) ->
    M#{mode => proxy};
normalize_runtime_config_term(M) when is_map(M) ->
    M.

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
    SQL = <<"SELECT host, backend, certificate, dns_provider, challenge_type, wildcard, acme_wildcard_base, advertise_http3, acme_contact_email, routes_json FROM sites ORDER BY host">>,
    case sqlite_query(DbPath, SQL) of
        {ok, Rows} ->
            Sites = [
                begin
                    HostBin = maps:get(<<"host">>, Row),
                    Backend = maps:get(<<"backend">>, Row),
                    Routes = site_routes_from_row(DbPath, HostBin, Row),
                    Site0 = #{host => HostBin, backend => Backend, routes => Routes},
                    site_row_to_map(Row, Site0)
                end
                || Row <- Rows
            ],
            {ok, Sites};
        {error, Reason} ->
            {error, Reason}
    end.

site_routes_from_row(DbPath, HostBin, Row) ->
    case maps:get(<<"routes_json">>, Row, undefined) of
        undefined ->
            fallback_site_routes(DbPath, HostBin);
        null ->
            fallback_site_routes(DbPath, HostBin);
        <<>> ->
            fallback_site_routes(DbPath, HostBin);
        Json when is_binary(Json); is_list(Json) ->
            case decode_routes_json(Json) of
                {ok, []} -> fallback_site_routes(DbPath, HostBin);
                {ok, Routes} -> Routes;
                {error, _} -> fallback_site_routes(DbPath, HostBin)
            end;
        _ ->
            fallback_site_routes(DbPath, HostBin)
    end.

fallback_site_routes(DbPath, HostBin) ->
    case get_routes(DbPath, HostBin) of
        {ok, Routes} -> Routes;
        _ -> []
    end.

decode_routes_json(Json) when is_list(Json) ->
    decode_routes_json(iolist_to_binary(Json));
decode_routes_json(Json) when is_binary(Json) ->
    case thoas:decode(Json) of
        {ok, Rows} when is_list(Rows) ->
            {ok, [decode_route_row(R) || R <- Rows, is_map(R)]};
        {ok, _} ->
            {ok, []};
        {error, Reason} ->
            {error, Reason}
    end.

decode_route_row(R) ->
    #{
        path => maps:get(<<"path">>, R, <<"/">>),
        path_type => parse_route_path_type(maps:get(<<"path_type">>, R, <<"prefix">>)),
        rewrite => maps:get(<<"rewrite">>, R, null)
    }.

parse_route_path_type(<<"exact">>) -> exact;
parse_route_path_type(<<"prefix">>) -> prefix;
parse_route_path_type(exact) -> exact;
parse_route_path_type(prefix) -> prefix;
parse_route_path_type(_) -> prefix.

site_row_to_map(Row, Site0) ->
    Site0#{
        certificate => null_to_undefined(maps:get(<<"certificate">>, Row, undefined)),
        dns_provider => null_to_undefined(maps:get(<<"dns_provider">>, Row, undefined)),
        challenge_type => null_to_undefined(maps:get(<<"challenge_type">>, Row, undefined)),
        wildcard => int_to_bool(maps:get(<<"wildcard">>, Row, 0)),
        acme_wildcard_base => null_to_undefined(maps:get(<<"acme_wildcard_base">>, Row, undefined)),
        advertise_http3 => int_to_bool(maps:get(<<"advertise_http3">>, Row, 1)),
        acme_contact_email => null_to_undefined(maps:get(<<"acme_contact_email">>, Row, undefined))
    }.

null_to_undefined(undefined) -> undefined;
null_to_undefined(null) -> undefined;
null_to_undefined(V) -> V.

int_to_bool(0) -> false;
int_to_bool(1) -> true;
int_to_bool(V) when is_integer(V), V =/= 0 -> true;
int_to_bool(_) -> false.

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
