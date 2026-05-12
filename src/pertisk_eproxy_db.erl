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
    insert_certificate_pem/4,
    insert_certificate_pem/5,
    upsert_acme_certificate_pem/4,
    update_certificate_pem/4,
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
    delete_backend/2,
    ensure_admin_users/1,
    verify_admin_login/3
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
            _ = pertisk_eproxy_db:ensure_admin_users(DbPath),
            lager:info("Database initialized at ~s", [DbPath]),
                    {ok, DbPath};
                {error, Reason} ->
                    lager:error("Failed to initialize schema: ~p", [Reason]),
                    {error, Reason}
            end
    end.

%% Create tables if they don't exist
init_schema(DbPath) ->
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
        credentials_json TEXT NOT NULL DEFAULT '{}'
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
    sqlite_exec(DbPath, SQL).

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
    SQL = "CREATE TABLE IF NOT EXISTS dns_providers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE, provider_type TEXT NOT NULL, credentials_json TEXT NOT NULL DEFAULT '{}');",
    sqlite_exec(DbPath, SQL).

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
