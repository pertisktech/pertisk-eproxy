-module(pertisk_eproxy_db_tests).

-include_lib("eunit/include/eunit.hrl").

%% ---------------------------------------------------------------------------
%% Helpers
%% ---------------------------------------------------------------------------

cleanup_db(Path) ->
    _ = file:delete(Path),
    ok.

with_db(Fun) ->
    Path = pertisk_eproxy_test_helpers:tmp_db(),
    cleanup_db(Path),
    try Fun(Path) after cleanup_db(Path) end.

listener_pem_paths() ->
    Base = filename:join([code:priv_dir(pertisk_eproxy), "tls"]),
    {filename:join(Base, "listener.pem"), filename:join(Base, "listener.key")}.

read_pem(File) ->
    {ok, Bin} = file:read_file(File),
    binary_to_list(Bin).

sqlite3_exec(DbPath, SQL) ->
    Cmd = "sqlite3 " ++ DbPath ++ " " ++ SQL,
    os:cmd(Cmd).

fake_sqlite3_script(Output) ->
    Dir = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "fake_sql_" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = file:make_dir(Dir),
    Script = filename:join(Dir, "sqlite3"),
    Esc = lists:flatten([case C of $' -> "'\\''"; _ -> [C] end || C <- Output]),
    ok = file:write_file(Script, "#!/bin/sh\necho '" ++ Esc ++ "'\n"),
    ok = file:change_mode(Script, 8#755),
    Script.

with_fake_sqlite3(Output, Fun) ->
    Script = fake_sqlite3_script(Output),
    Old = application:get_env(pertisk_eproxy, sqlite3_executable),
    application:set_env(pertisk_eproxy, sqlite3_executable, Script),
    try Fun(Script) after
        case Old of
            {ok, V} -> application:set_env(pertisk_eproxy, sqlite3_executable, V);
            undefined -> application:unset_env(pertisk_eproxy, sqlite3_executable)
        end,
        file:delete(Script),
        file:del_dir(filename:dirname(Script))
    end.

seed_path_rewrites_table(DbPath) ->
    _ = sqlite3_exec(DbPath, "\"CREATE TABLE IF NOT EXISTS path_rewrites ("
        "id INTEGER PRIMARY KEY AUTOINCREMENT, site_host TEXT NOT NULL, "
        "path TEXT NOT NULL, path_type TEXT NOT NULL, rewrite TEXT);\""),
    _ = sqlite3_exec(DbPath, "\"INSERT INTO path_rewrites(site_host, path, path_type, rewrite) "
        "VALUES('example.com', '/api', 'prefix', NULL);\""),
    ok.

seed_backends_table(DbPath) ->
    _ = sqlite3_exec(DbPath, "\"CREATE TABLE IF NOT EXISTS backends ("
        "name TEXT PRIMARY KEY, algorithm TEXT NOT NULL, "
        "health_path TEXT, health_interval_secs INTEGER DEFAULT 30);\""),
    _ = sqlite3_exec(DbPath, "\"CREATE TABLE IF NOT EXISTS upstreams ("
        "id INTEGER PRIMARY KEY AUTOINCREMENT, backend_name TEXT NOT NULL, "
        "addr TEXT NOT NULL, weight INTEGER DEFAULT 1);\""),
    _ = sqlite3_exec(DbPath, "\"INSERT INTO backends(name, algorithm, health_path, health_interval_secs) "
        "VALUES('web', 'round_robin', '/healthz', 15);\""),
    _ = sqlite3_exec(DbPath, "\"INSERT INTO upstreams(backend_name, addr, weight) "
        "VALUES('web', '10.0.0.1:8080', 1);\""),
    ok.

sample_runtime_config() ->
    #{
        mode => proxy,
        sites => [
            #{
                host => <<"example.com">>,
                backend => <<"web">>,
                certificate => <<"site-cert">>,
                dns_provider => <<"cf">>,
                challenge_type => "dns-01",
                wildcard => true,
                acme_wildcard_base => <<"*.example.com">>,
                advertise_http3 => false,
                acme_contact_email => <<"ops@example.com">>,
                routes => [
                    #{path => <<"/api">>, path_type => prefix, rewrite => <<"/v1">>}
                ]
            }
        ],
        backends => [
            #{
                name => <<"web">>,
                algorithm => round_robin,
                upstreams => [#{addr => <<"10.0.0.1:8080">>, weight => 1}]
            }
        ],
        certificates => [<<"site-cert">>],
        dns_providers => [
            #{
                name => <<"cf">>,
                provider_type => <<"cloudflare">>,
                credentials => #{<<"api_token">> => <<"secret">>}
            }
        ]
    }.

%% ---------------------------------------------------------------------------
%% Schema / lifecycle
%% ---------------------------------------------------------------------------

db_file_exists_false_for_missing_test() ->
    with_db(fun(Path) ->
        ?assertNot(pertisk_eproxy_db:db_file_exists(Path))
    end).

migrate_schema_creates_file_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assert(pertisk_eproxy_db:db_file_exists(Path))
    end).

ensure_ready_new_file_test() ->
    with_db(fun(Path) ->
        ?assertMatch({ok, Path}, pertisk_eproxy_db:ensure_ready(Path))
    end).

ensure_ready_existing_runs_migration_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertMatch({ok, Path}, pertisk_eproxy_db:ensure_ready(Path))
    end).

init_creates_db_and_admin_test() ->
    with_db(fun(Path) ->
        ?assertMatch({ok, Path}, pertisk_eproxy_db:init(Path)),
        ?assert(pertisk_eproxy_db:db_file_exists(Path)),
        ?assertEqual(ok, pertisk_eproxy_db:verify_admin_login(Path, <<"admin">>, <<"admin">>))
    end).

init_rejects_directory_test() ->
    Dir = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "pertisk_db_dir_" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    _ = file:del_dir_r(Dir),
    ok = file:make_dir(Dir),
    try
        ?assertEqual({error, is_directory}, pertisk_eproxy_db:init(Dir))
    after
        _ = file:del_dir_r(Dir)
    end.

migrate_schema_idempotent_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path))
    end).

insert_site_not_implemented_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertEqual({error, not_implemented},
            pertisk_eproxy_db:insert_site(Path, <<"h">>, <<"b">>, []))
    end).

%% ---------------------------------------------------------------------------
%% Runtime config persistence
%% ---------------------------------------------------------------------------

get_runtime_config_not_found_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertEqual(not_found, pertisk_eproxy_db:get_runtime_config(Path))
    end).

put_get_runtime_config_roundtrip_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        Cfg = sample_runtime_config(),
        ?assertEqual(ok, pertisk_eproxy_db:put_runtime_config(Path, Cfg)),
        {ok, Got} = pertisk_eproxy_db:get_runtime_config(Path),
        ?assertEqual(proxy, maps:get(mode, Got)),
        ?assertEqual(1, length(maps:get(sites, Got)))
    end).

proxy_admin_mode_normalized_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        Cfg = #{mode => proxy_admin, sites => [], backends => []},
        ?assertEqual(ok, pertisk_eproxy_db:put_runtime_config(Path, Cfg)),
        ?assertMatch({ok, #{mode := proxy}}, pertisk_eproxy_db:get_runtime_config(Path))
    end).

list_sites_from_runtime_projection_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertEqual(ok, pertisk_eproxy_db:put_runtime_config(Path, sample_runtime_config())),
        {ok, [Site | _]} = pertisk_eproxy_db:list_sites(Path),
        ?assertEqual(<<"example.com">>, maps:get(host, Site)),
        ?assertEqual(<<"web">>, maps:get(backend, Site)),
        ?assertEqual(true, maps:get(wildcard, Site)),
        ?assertEqual(false, maps:get(advertise_http3, Site)),
        Routes = maps:get(routes, Site),
        ?assertEqual(1, length(Routes))
    end).

get_site_with_routes_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ok = seed_path_rewrites_table(Path),
        ?assertEqual(ok, pertisk_eproxy_db:put_runtime_config(Path, sample_runtime_config())),
        {ok, Site} = pertisk_eproxy_db:get_site(Path, <<"example.com">>),
        ?assertEqual(<<"web">>, maps:get(backend, Site)),
        ?assertEqual(1, length(maps:get(routes, Site)))
    end).

get_site_not_found_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertEqual({error, not_found}, pertisk_eproxy_db:get_site(Path, <<"missing.example">>))
    end).

get_config_aggregates_sites_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ok = seed_backends_table(Path),
        ?assertEqual(ok, pertisk_eproxy_db:put_runtime_config(Path, sample_runtime_config())),
        ?assertMatch({ok, #{sites := [_], backends := [_]}}, pertisk_eproxy_db:get_config(Path))
    end).

list_backends_with_seeded_table_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ok = seed_backends_table(Path),
        {ok, [Backend | _]} = pertisk_eproxy_db:list_backends(Path),
        ?assertEqual(<<"web">>, maps:get(name, Backend)),
        ?assertEqual(1, length(maps:get(upstreams, Backend)))
    end).

get_backend_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ok = seed_backends_table(Path),
        ?assertMatch({ok, #{name := <<"web">>}}, pertisk_eproxy_db:get_backend(Path, <<"web">>))
    end).

get_backend_not_found_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ok = seed_backends_table(Path),
        ?assertEqual({error, not_found}, pertisk_eproxy_db:get_backend(Path, <<"missing">>))
    end).

%% ---------------------------------------------------------------------------
%% Admin users
%% ---------------------------------------------------------------------------

verify_admin_login_invalid_password_test() ->
    with_db(fun(Path) ->
        ?assertMatch({ok, _}, pertisk_eproxy_db:init(Path)),
        ?assertEqual({error, invalid_credentials},
            pertisk_eproxy_db:verify_admin_login(Path, <<"admin">>, <<"wrong">>))
    end).

verify_admin_login_unknown_user_test() ->
    with_db(fun(Path) ->
        ?assertMatch({ok, _}, pertisk_eproxy_db:init(Path)),
        ?assertEqual({error, invalid_credentials},
            pertisk_eproxy_db:verify_admin_login(Path, <<"nobody">>, <<"admin">>))
    end).

%% ---------------------------------------------------------------------------
%% Certificates
%% ---------------------------------------------------------------------------

certificate_insert_list_delete_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        {ok, Id} = pertisk_eproxy_db:insert_certificate(Path, <<"my-cert">>),
        {ok, Certs} = pertisk_eproxy_db:list_certificates(Path),
        ?assertEqual(1, length(Certs)),
        ?assertEqual(<<"my-cert">>, maps:get(name, hd(Certs))),
        %% sqlite3 CLI runs each statement in a new process; changes() is unreliable.
        _ = pertisk_eproxy_db:delete_certificate(Path, Id),
        ?assertMatch({ok, []}, pertisk_eproxy_db:list_certificates(Path))
    end).

certificate_empty_name_rejected_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertEqual({error, empty_name}, pertisk_eproxy_db:insert_certificate(Path, <<"  ">>))
    end).

upsert_certificate_record_insert_and_update_test() ->
    with_db(fun(Path) ->
        {CertPem, KeyPem} = listener_pem_paths(),
        Cert = read_pem(CertPem),
        Key = read_pem(KeyPem),
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        {ok, Id1} = pertisk_eproxy_db:upsert_certificate_record(
            Path, <<"listener">>, Cert, Key, <<"imported_pem">>),
        {ok, Id2} = pertisk_eproxy_db:upsert_certificate_record(
            Path, <<"listener">>, Cert ++ "\n", Key, <<"acme">>),
        ?assertEqual(Id1, Id2),
        {ok, [Row | _]} = pertisk_eproxy_db:list_certificates(Path),
        ?assertEqual(<<"acme">>, maps:get(source_type, Row))
    end).

insert_certificate_pem_from_files_test() ->
    with_db(fun(Path) ->
        {CertFile, KeyFile} = listener_pem_paths(),
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertMatch({ok, _Id}, pertisk_eproxy_db:insert_certificate_pem(
            Path, <<"listener-import">>, CertFile, KeyFile)),
        {ok, [Row | _]} = pertisk_eproxy_db:list_certificates(Path),
        CertPem = maps:get(cert_pem, Row),
        ?assert(is_binary(CertPem) orelse is_list(CertPem))
    end).

insert_certificate_pem_empty_files_rejected_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertEqual({error, empty_cert_file},
            pertisk_eproxy_db:insert_certificate_pem(Path, <<"x">>, "", "/tmp/key.pem")),
        ?assertEqual({error, empty_key_file},
            pertisk_eproxy_db:insert_certificate_pem(Path, <<"x">>, "/tmp/cert.pem", ""))
    end).

upsert_acme_certificate_pem_test() ->
    with_db(fun(Path) ->
        {CertFile, KeyFile} = listener_pem_paths(),
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        {ok, Id1} = pertisk_eproxy_db:upsert_acme_certificate_pem(
            Path, <<"acme-site">>, CertFile, KeyFile),
        {ok, Id2} = pertisk_eproxy_db:upsert_acme_certificate_pem(
            Path, <<"acme-site">>, CertFile, KeyFile),
        ?assertEqual(Id1, Id2),
        {ok, [Row | _]} = pertisk_eproxy_db:list_certificates(Path),
        ?assertEqual(<<"acme">>, maps:get(source_type, Row))
    end).

update_certificate_pem_test() ->
    with_db(fun(Path) ->
        {CertFile, KeyFile} = listener_pem_paths(),
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        {ok, Id} = pertisk_eproxy_db:insert_certificate(Path, <<"rename-me">>),
        ?assertEqual(ok, pertisk_eproxy_db:update_certificate_pem(Path, Id, CertFile, KeyFile)),
        {ok, [Row | _]} = pertisk_eproxy_db:list_certificates(Path),
        ?assertEqual(<<"imported_pem">>, maps:get(source_type, Row))
    end).

update_certificate_name_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        {ok, Id} = pertisk_eproxy_db:insert_certificate(Path, <<"old-name">>),
        ?assertEqual(ok, pertisk_eproxy_db:update_certificate(Path, Id, <<"new-name">>)),
        {ok, [Row | _]} = pertisk_eproxy_db:list_certificates(Path),
        ?assertEqual(<<"new-name">>, maps:get(name, Row))
    end).

update_certificate_not_found_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertEqual({error, not_found}, pertisk_eproxy_db:update_certificate(Path, 9999, <<"x">>))
    end).

ensure_certificates_seeded_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertEqual(ok, pertisk_eproxy_db:ensure_certificates_seeded(Path, [<<"cert-a">>, <<"123">>])),
        {ok, Certs} = pertisk_eproxy_db:list_certificates(Path),
        Names = [maps:get(name, C) || C <- Certs],
        ?assert(lists:member(<<"cert-a">>, Names)),
        ?assertNot(lists:member(<<"123">>, Names))
    end).

%% ---------------------------------------------------------------------------
%% DNS providers
%% ---------------------------------------------------------------------------

dns_provider_crud_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        Cred = #{<<"api_token">> => <<"tok">>},
        ?assertMatch({ok, _}, pertisk_eproxy_db:insert_dns_provider(
            Path, <<"cf">>, <<"cloudflare">>, Cred)),
        {ok, [Row0 | _]} = pertisk_eproxy_db:list_dns_providers(Path),
        Id = maps:get(id, Row0),
        ?assertMatch({ok, #{name := <<"cf">>}}, pertisk_eproxy_db:get_dns_provider_by_id(Path, Id)),
        ?assertMatch({ok, #{provider_type := <<"cloudflare">>}},
            pertisk_eproxy_db:get_dns_provider_by_name(Path, <<"cf">>)),
        ?assertMatch({ok, [_]}, pertisk_eproxy_db:list_dns_providers(Path)),
        NewCred = #{<<"api_token">> => <<"new">>},
        ?assertEqual(ok, pertisk_eproxy_db:update_dns_provider(
            Path, Id, <<"cf-renamed">>, <<"cloudflare">>, NewCred)),
        ?assertMatch({ok, #{name := <<"cf-renamed">>}},
            pertisk_eproxy_db:get_dns_provider_by_id(Path, Id)),
        _ = pertisk_eproxy_db:delete_dns_provider(Path, Id),
        ?assertEqual({error, not_found}, pertisk_eproxy_db:get_dns_provider_by_id(Path, Id))
    end).

dns_provider_empty_name_rejected_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertEqual({error, empty_name},
            pertisk_eproxy_db:insert_dns_provider(Path, <<"">>, <<"label">>, #{}))
    end).

delete_dns_provider_by_name_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        {ok, _} = pertisk_eproxy_db:insert_dns_provider(Path, <<"cf">>, <<"label">>, #{}),
        _ = pertisk_eproxy_db:delete_dns_provider_by_name(Path, <<"cf">>),
        ?assertMatch({ok, []}, pertisk_eproxy_db:list_dns_providers(Path))
    end).

replace_dns_providers_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        Providers = [
            #{name => <<"a">>, provider_type => <<"label">>, credentials => #{}},
            #{name => <<"b">>, provider_type => <<"cloudflare">>, credentials => #{<<"k">> => <<"v">>}}
        ],
        ?assertEqual(ok, pertisk_eproxy_db:replace_dns_providers(Path, Providers)),
        {ok, Got} = pertisk_eproxy_db:list_dns_providers(Path),
        ?assertEqual(2, length(Got)),
        ?assertEqual(ok, pertisk_eproxy_db:replace_dns_providers(Path, [])),
        ?assertMatch({ok, []}, pertisk_eproxy_db:list_dns_providers(Path))
    end).

ensure_dns_providers_seeded_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        P = [#{name => <<"seed">>, provider_type => <<"label">>, credentials => #{}}],
        ?assertEqual(ok, pertisk_eproxy_db:ensure_dns_providers_seeded(Path, P)),
        ?assertEqual(ok, pertisk_eproxy_db:ensure_dns_providers_seeded(Path, P)),
        {ok, [Row | _]} = pertisk_eproxy_db:list_dns_providers(Path),
        ?assertEqual(<<"seed">>, maps:get(name, Row))
    end).

%% ---------------------------------------------------------------------------
%% Stubbed CRUD (SQLite CLI mode) and edge cases
%% ---------------------------------------------------------------------------

insert_backend_not_implemented_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertEqual({error, not_implemented},
            pertisk_eproxy_db:insert_backend(Path, <<"web">>, <<"round_robin">>, <<"/">>, 30))
    end).

insert_upstream_not_implemented_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertEqual({error, not_implemented},
            pertisk_eproxy_db:insert_upstream(Path, <<"web">>, <<"10.0.0.1:80">>, 1))
    end).

delete_backend_not_implemented_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertEqual({error, not_implemented}, pertisk_eproxy_db:delete_backend(Path, <<"web">>))
    end).

delete_site_not_implemented_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertEqual({error, not_implemented}, pertisk_eproxy_db:delete_site(Path, <<"example.com">>))
    end).

ensure_admin_users_idempotent_test() ->
    with_db(fun(Path) ->
        ?assertMatch({ok, _}, pertisk_eproxy_db:init(Path)),
        ?assertEqual(ok, pertisk_eproxy_db:ensure_admin_users(Path)),
        ?assertEqual(ok, pertisk_eproxy_db:verify_admin_login(Path, <<"admin">>, <<"admin">>))
    end).

get_dns_provider_by_name_not_found_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertEqual({error, not_found}, pertisk_eproxy_db:get_dns_provider_by_name(Path, <<"missing">>))
    end).

get_dns_provider_by_id_not_found_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertEqual({error, not_found}, pertisk_eproxy_db:get_dns_provider_by_id(Path, 99999))
    end).

insert_certificate_pem_with_source_type_test() ->
    with_db(fun(Path) ->
        {CertFile, KeyFile} = listener_pem_paths(),
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertMatch({ok, _Id},
            pertisk_eproxy_db:insert_certificate_pem(
                Path, <<"typed-import">>, CertFile, KeyFile, <<"custom">>)),
        {ok, [Row | _]} = pertisk_eproxy_db:list_certificates(Path),
        ?assertEqual(<<"custom">>, maps:get(source_type, Row))
    end).

delete_certificate_not_found_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertEqual({error, not_found}, pertisk_eproxy_db:delete_certificate(Path, 99999))
    end).

update_dns_provider_not_found_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertEqual({error, not_found},
            pertisk_eproxy_db:update_dns_provider(Path, 99999, <<"x">>, <<"cloudflare">>, #{}))
    end).

insert_dns_provider_empty_provider_type_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertEqual({error, empty_provider_type},
            pertisk_eproxy_db:insert_dns_provider(Path, <<"cf">>, <<"">>, #{}))
    end).

delete_dns_provider_by_name_empty_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertEqual({error, not_found}, pertisk_eproxy_db:delete_dns_provider_by_name(Path, <<"  ">>))
    end).

ensure_certificates_seeded_cleans_numeric_placeholders_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        _ = sqlite3_exec(Path, "\"INSERT INTO certificates(name, source_type) VALUES('42', 'acme');\""),
        ?assertEqual(ok, pertisk_eproxy_db:ensure_certificates_seeded(Path, [<<"valid-cert">>])),
        {ok, Certs} = pertisk_eproxy_db:list_certificates(Path),
        Names = [maps:get(name, C) || C <- Certs],
        ?assert(lists:member(<<"valid-cert">>, Names)),
        ?assertNot(lists:member(<<"42">>, Names))
    end).

list_sites_routes_json_projection_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        Cfg = sample_runtime_config(),
        ?assertEqual(ok, pertisk_eproxy_db:put_runtime_config(Path, Cfg)),
        {ok, [Site | _]} = pertisk_eproxy_db:list_sites(Path),
        Routes = maps:get(routes, Site),
        ?assertEqual(1, length(Routes)),
        ?assertEqual(<<"/api">>, maps:get(path, hd(Routes)))
    end).

verify_admin_login_non_binary_rejected_test() ->
    with_db(fun(Path) ->
        ?assertMatch({ok, _}, pertisk_eproxy_db:init(Path)),
        ?assertEqual({error, invalid_credentials},
            pertisk_eproxy_db:verify_admin_login(Path, 123, <<"admin">>))
    end).

put_runtime_config_invalid_encoding_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        Bad = binary_to_list(base64:encode(term_to_binary(not_a_map))),
        _ = sqlite3_exec(Path, "\"INSERT INTO runtime_state(key, value) VALUES('runtime_config', '" ++ Bad ++ "');\""),
        ?assertMatch({error, _}, pertisk_eproxy_db:get_runtime_config(Path))
    end).

delete_dns_provider_not_found_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertEqual({error, not_found}, pertisk_eproxy_db:delete_dns_provider(Path, 99999))
    end).

update_certificate_empty_name_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        {ok, Id} = pertisk_eproxy_db:insert_certificate(Path, <<"rename-target">>),
        ?assertEqual({error, empty_name}, pertisk_eproxy_db:update_certificate(Path, Id, <<"  ">>))
    end).

update_dns_provider_empty_name_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        {ok, Id} = pertisk_eproxy_db:insert_dns_provider(Path, <<"cf">>, <<"cloudflare">>, #{}),
        ?assertEqual({error, empty_name},
            pertisk_eproxy_db:update_dns_provider(Path, Id, <<"">>, <<"cloudflare">>, #{}))
    end).

upsert_certificate_record_empty_name_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertEqual({error, empty_name},
            pertisk_eproxy_db:upsert_certificate_record(Path, <<"">>, <<"cert">>, <<"key">>, <<"imported">>))
    end).

insert_certificate_pem_empty_name_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        {CertFile, KeyFile} = listener_pem_paths(),
        ?assertEqual({error, empty_name},
            pertisk_eproxy_db:insert_certificate_pem(Path, <<"">>, CertFile, KeyFile))
    end).

list_sites_exact_path_type_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        Cfg = (sample_runtime_config())#{
            sites => [
                #{
                    host => <<"exact.example">>,
                    backend => <<"web">>,
                    routes => [#{path => <<"/health">>, path_type => exact}]
                }
            ]
        },
        ?assertEqual(ok, pertisk_eproxy_db:put_runtime_config(Path, Cfg)),
        {ok, [Site | _]} = pertisk_eproxy_db:list_sites(Path),
        [Route | _] = maps:get(routes, Site),
        ?assertEqual(exact, maps:get(path_type, Route))
    end).

list_sites_empty_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertMatch({ok, []}, pertisk_eproxy_db:list_sites(Path))
    end).

routes_json_invalid_fallback_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ok = seed_path_rewrites_table(Path),
        _ = sqlite3_exec(Path, "\"INSERT INTO sites(host, backend, routes_json) "
            "VALUES('example.com', 'web', 'not-json');\""),
        {ok, [Site | _]} = pertisk_eproxy_db:list_sites(Path),
        Routes = maps:get(routes, Site),
        ?assertEqual(1, length(Routes)),
        ?assertEqual(<<"/api">>, maps:get(path, hd(Routes)))
    end).

get_backend_after_drop_upstreams_table_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ok = seed_backends_table(Path),
        _ = sqlite3_exec(Path, "\"DROP TABLE upstreams;\""),
        ?assertMatch({error, _}, pertisk_eproxy_db:get_backend(Path, <<"web">>))
    end).

upsert_certificate_record_quote_in_pem_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        Cert = "-----BEGIN CERTIFICATE-----\nO'Hara\n-----END CERTIFICATE-----\n",
        Key = "-----BEGIN PRIVATE KEY-----\nkey\n-----END PRIVATE KEY-----\n",
        ?assertMatch({ok, _Id},
            pertisk_eproxy_db:upsert_certificate_record(Path, <<"quoted">>, Cert, Key, <<"imported_pem">>)),
        {ok, [Row | _]} = pertisk_eproxy_db:list_certificates(Path),
        Stored = maps:get(cert_pem, Row),
        StoredBin =
            case Stored of
                B when is_binary(B) -> B;
                L when is_list(L) -> list_to_binary(L)
            end,
        ?assertNotEqual(nomatch, binary:match(StoredBin, <<"O'Hara">>))
    end).

insert_certificate_pem_missing_file_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        MissingCert = filename:join([
            os:getenv("TMPDIR", "/tmp"),
            "missing-cert-" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".pem"
        ]),
        MissingKey = filename:join([
            os:getenv("TMPDIR", "/tmp"),
            "missing-key-" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".pem"
        ]),
        ?assertMatch({ok, _Id},
            pertisk_eproxy_db:insert_certificate_pem(Path, <<"missing-files">>, MissingCert, MissingKey)),
        {ok, [Row | _]} = pertisk_eproxy_db:list_certificates(Path),
        ?assertEqual(<<>>, maps:get(cert_pem, Row, <<>>))
    end).

put_runtime_config_after_drop_runtime_state_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        _ = sqlite3_exec(Path, "\"DROP TABLE runtime_state;\""),
        Cfg = #{mode => proxy, sites => [], backends => []},
        ?assertEqual(ok, pertisk_eproxy_db:put_runtime_config(Path, Cfg)),
        ?assertMatch({ok, #{mode := proxy}}, pertisk_eproxy_db:get_runtime_config(Path))
    end).

%% ---------------------------------------------------------------------------
%% Additional coverage (sqlite errors, CRUD edge cases, decode paths)
%% ---------------------------------------------------------------------------

ensure_ready_db_dir_error_test() ->
    BadPath = filename:join(["/dev/null/pertisk-db", "proxy.db"]),
    ?assertMatch({error, {db_dir, _}}, pertisk_eproxy_db:init(BadPath)).

resolve_sqlite3_from_app_env_binary_test() ->
    with_db(fun(Path) ->
        Old = application:get_env(pertisk_eproxy, sqlite3_executable),
        Exe =
            case os:find_executable("sqlite3") of
                false -> "/usr/bin/sqlite3";
                P -> P
            end,
        application:set_env(pertisk_eproxy, sqlite3_executable, list_to_binary(Exe)),
        try
            ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path))
        after
            case Old of
                {ok, V} -> application:set_env(pertisk_eproxy, sqlite3_executable, V);
                undefined -> application:unset_env(pertisk_eproxy, sqlite3_executable)
            end
        end
    end).

sqlite_query_executable_missing_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        Old = application:get_env(pertisk_eproxy, sqlite3_executable),
        application:set_env(pertisk_eproxy, sqlite3_executable, "/nonexistent/sqlite3"),
        try
            ?assertEqual({error, sqlite3_executable_not_found}, pertisk_eproxy_db:list_sites(Path))
        after
            case Old of
                {ok, V} -> application:set_env(pertisk_eproxy, sqlite3_executable, V);
                undefined -> application:unset_env(pertisk_eproxy, sqlite3_executable)
            end
        end
    end).

replace_dns_providers_skips_invalid_entries_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        Providers = [
            #{name => <<"">>, provider_type => <<"label">>, credentials => #{}},
            #{name => <<"ok">>, provider_type => <<"">>, credentials => #{}},
            #{name => <<"valid">>, provider_type => <<"cloudflare">>, credentials => #{}}
        ],
        ?assertEqual(ok, pertisk_eproxy_db:replace_dns_providers(Path, Providers)),
        {ok, Got} = pertisk_eproxy_db:list_dns_providers(Path),
        ?assertEqual(1, length(Got)),
        ?assertEqual(<<"valid">>, maps:get(name, hd(Got)))
    end).

replace_dns_providers_insert_error_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        Old = application:get_env(pertisk_eproxy, sqlite3_executable),
        application:set_env(pertisk_eproxy, sqlite3_executable, "/nonexistent/sqlite3"),
        try
            ?assertEqual({error, sqlite3_executable_not_found},
                pertisk_eproxy_db:replace_dns_providers(Path, [
                    #{name => <<"cf">>, provider_type => <<"label">>, credentials => #{}}
                ]))
        after
            case Old of
                {ok, V} -> application:set_env(pertisk_eproxy, sqlite3_executable, V);
                undefined -> application:unset_env(pertisk_eproxy, sqlite3_executable)
            end
        end
    end).

verify_admin_login_corrupt_credentials_test() ->
    with_db(fun(Path) ->
        ?assertMatch({ok, _}, pertisk_eproxy_db:init(Path)),
        _ = sqlite3_exec(Path, "\"UPDATE admin_users SET pass_hash_b64='not-base64!!!' WHERE username='admin';\""),
        ?assertEqual({error, invalid_credentials},
            pertisk_eproxy_db:verify_admin_login(Path, <<"admin">>, <<"admin">>))
    end).

update_certificate_pem_not_found_test() ->
    with_db(fun(Path) ->
        {CertFile, KeyFile} = listener_pem_paths(),
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertEqual({error, not_found},
            pertisk_eproxy_db:update_certificate_pem(Path, 99999, CertFile, KeyFile))
    end).

list_dns_providers_invalid_credentials_json_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        _ = sqlite3_exec(Path, "\"INSERT INTO dns_providers(name, provider_type, credentials_json, created_at) "
            "VALUES('bad-json', 'label', 'not-json', '');\""),
        {ok, [Row | _]} = pertisk_eproxy_db:list_dns_providers(Path),
        ?assertEqual(#{}, maps:get(credentials, Row))
    end).

ensure_dns_providers_seeded_skips_non_map_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        ?assertEqual(ok, pertisk_eproxy_db:ensure_dns_providers_seeded(Path, [not_a_map, #{name => <<"ok">>}]))
    end).

decode_runtime_config_legacy_unsafe_term_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        Enc = binary_to_list(base64:encode(term_to_binary(#{mode => proxy, sites => [], backends => []}))),
        _ = sqlite3_exec(Path, "\"INSERT INTO runtime_state(key, value) VALUES('runtime_config', '" ++ Enc ++ "');\""),
        ?assertMatch({ok, #{mode := proxy}}, pertisk_eproxy_db:get_runtime_config(Path))
    end).

migrate_schema_init_error_test() ->
    with_db(fun(Path) ->
        Old = application:get_env(pertisk_eproxy, sqlite3_executable),
        application:set_env(pertisk_eproxy, sqlite3_executable, "/nonexistent/sqlite3"),
        try
            ?assertEqual({error, sqlite3_executable_not_found}, pertisk_eproxy_db:init(Path))
        after
            case Old of
                {ok, V} -> application:set_env(pertisk_eproxy, sqlite3_executable, V);
                undefined -> application:unset_env(pertisk_eproxy, sqlite3_executable)
            end
        end
    end).

ensure_ready_migrate_error_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        Old = application:get_env(pertisk_eproxy, sqlite3_executable),
        application:set_env(pertisk_eproxy, sqlite3_executable, "/nonexistent/sqlite3"),
        try
            ?assertEqual({error, sqlite3_executable_not_found}, pertisk_eproxy_db:ensure_ready(Path))
        after
            case Old of
                {ok, V} -> application:set_env(pertisk_eproxy, sqlite3_executable, V);
                undefined -> application:unset_env(pertisk_eproxy, sqlite3_executable)
            end
        end
    end).

ensure_ready_bad_parent_dir_test() ->
    BadPath = filename:join(["/dev/null/pertisk-ready", "proxy.db"]),
    ?assertMatch({error, _}, pertisk_eproxy_db:ensure_ready(BadPath)).

sqlite_exec_shell_failure_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        with_fake_sqlite3("/bin/sh: 1: sqlite3: not found", fun(_) ->
            ?assertMatch({error, {sqlite3_cli, _}},
                pertisk_eproxy_db:replace_dns_providers(Path, [
                    #{name => <<"cf">>, provider_type => <<"label">>, credentials => #{}}
                ]))
        end)
    end).

sqlite_query_shell_failure_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        with_fake_sqlite3("/bin/sh: sqlite3: not found", fun(_) ->
            ?assertMatch({error, {sqlite3_cli, _}}, pertisk_eproxy_db:list_sites(Path))
        end)
    end).

sqlite_query_json_not_array_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        with_fake_sqlite3("{\"not\":\"array\"}", fun(_) ->
            ?assertMatch({error, {sqlite3_cli, _}}, pertisk_eproxy_db:list_sites(Path))
        end)
    end).

sqlite_query_json_decode_error_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        with_fake_sqlite3("[{not valid json", fun(_) ->
            ?assertMatch({error, {sqlite_json_decode, _, _}}, pertisk_eproxy_db:list_sites(Path))
        end)
    end).

resolve_sqlite3_from_app_env_list_test() ->
    with_db(fun(Path) ->
        Old = application:get_env(pertisk_eproxy, sqlite3_executable),
        Exe =
            case os:find_executable("sqlite3") of
                false -> "/usr/bin/sqlite3";
                P -> P
            end,
        application:set_env(pertisk_eproxy, sqlite3_executable, Exe),
        try
            ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path))
        after
            case Old of
                {ok, V} -> application:set_env(pertisk_eproxy, sqlite3_executable, V);
                undefined -> application:unset_env(pertisk_eproxy, sqlite3_executable)
            end
        end
    end).

insert_site_sqlite_error_test() ->
    with_db(fun(Path) ->
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
        with_fake_sqlite3("Error: near \"SYNTAX\": syntax error", fun(_) ->
            ?assertMatch({error, {sqlite_error, _}},
                pertisk_eproxy_db:delete_dns_provider_by_name(Path, <<"missing">>))
        end)
    end).
