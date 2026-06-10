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
