%% @doc Admin REST API handler for pertisk_eproxy.
%%
%% Endpoints (served on the management listener, default 0.0.0.0:9080):
%%
%%   GET  /api/config              — Return full proxy config as JSON
%%   PUT  /api/config              — Replace proxy config (hot-reload)
%%   GET  /api/sites               — List all sites
%%   POST /api/sites               — Add a site
%%   GET  /api/sites/:host         — Get a site by host
%%   DELETE /api/sites/:host       — Remove a site
%%   GET  /api/backends            — List all backends
%%   POST /api/backends            — Add a backend
%%   GET  /api/backends/:name      — Get backend + live status
%%   DELETE /api/backends/:name    — Remove a backend
%%   GET  /api/health              — Overall health (counts)
%%   GET  /api/metrics             — Prometheus text metrics
%%   POST /api/reload              — Reload config from file

-module(pertisk_eproxy_admin_handler).
-behaviour(cowboy_handler).

-export([init/2, h3_light_health_json/0, build_health_json/0]).

init(Req, Resource) ->
    Method = cowboy_req:method(Req),
    case auth_public(Method, Resource) of
        true ->
            handle(Method, Resource, Req);
        false ->
            case ingress_viewer_blocked(Method, Resource) of
                true ->
                    json_reply(403, #{<<"error">> => <<"read-only in ingress mode">>}, Req);
                false ->
                    case pertisk_eproxy_auth:auth_mode() of
                        disabled ->
                            handle(Method, Resource, Req);
                        local ->
                            case pertisk_eproxy_auth:verify_request(Req) of
                                ok ->
                                    handle(Method, Resource, Req);
                                {error, _} ->
                                    json_reply(401, #{<<"error">> => <<"Unauthorized">>}, Req)
                            end
                    end
            end
    end.

ingress_viewer_blocked(Method, Resource) ->
    pertisk_eproxy_config:ingress_mode()
        andalso (not pertisk_eproxy_auth:admin_login_required())
        andalso ingress_mutating(Method, Resource).

ingress_mutating(_, kubernetes_pods) -> false;
ingress_mutating(_, kubernetes_services) -> false;
ingress_mutating(_, kubernetes_tls_secrets) -> false;
ingress_mutating(<<"GET">>, kubernetes_ingresses) -> false;
ingress_mutating(<<"HEAD">>, kubernetes_ingresses) -> false;
ingress_mutating(<<"POST">>, kubernetes_ingresses) -> false;
ingress_mutating(<<"GET">>, kubernetes_ingress) -> false;
ingress_mutating(<<"HEAD">>, kubernetes_ingress) -> false;
ingress_mutating(<<"PUT">>, kubernetes_ingress) -> false;
ingress_mutating(<<"DELETE">>, kubernetes_ingress) -> false;
ingress_mutating(_, _) -> true.

auth_public(<<"GET">>, version) -> true;
auth_public(<<"HEAD">>, version) -> true;
auth_public(<<"GET">>, proto) -> true;
auth_public(<<"HEAD">>, proto) -> true;
auth_public(<<"GET">>, auth_config) -> true;
auth_public(<<"HEAD">>, auth_config) -> true;
auth_public(<<"GET">>, auth_check) -> true;
auth_public(<<"HEAD">>, auth_check) -> true;
auth_public(<<"POST">>, auth_login) -> true;
auth_public(<<"POST">>, auth_refresh) -> true;
auth_public(<<"POST">>, auth_logout) -> true;
auth_public(<<"GET">>, metrics) -> true;
auth_public(<<"GET">>, health) -> true;
auth_public(<<"HEAD">>, health) -> true;
auth_public(<<"GET">>, ingress_live) -> true;
auth_public(<<"HEAD">>, ingress_live) -> true;
auth_public(<<"GET">>, ingress_ready) -> true;
auth_public(<<"HEAD">>, ingress_ready) -> true;
auth_public(<<"GET">>, ingress_status) -> true;
auth_public(<<"HEAD">>, ingress_status) -> true;
auth_public(<<"GET">>, config) -> true;
auth_public(<<"HEAD">>, config) -> true;
auth_public(_, _) -> false.

%% ---------------------------------------------------------------------------
%% Route dispatch
%% ---------------------------------------------------------------------------

handle(<<"GET">>, version, Req) ->
    json_reply(200, #{<<"version">> => pertisk_eproxy_admin_management_snapshot:app_version()}, Req);
handle(<<"HEAD">>, version, Req) ->
    %% Chrome probes public endpoints with HEAD over HTTP/3; must not require auth (GET is public).
    json_reply(200, #{}, Req);

handle(<<"GET">>, proto, Req) ->
    Snapshot = proto_snapshot(Req),
    json_reply(200, Snapshot, Req, proto_debug_headers(Snapshot));

handle(<<"GET">>, management, Req) ->
    json_reply(200, pertisk_eproxy_admin_management_snapshot:snapshot(), Req);

handle(<<"GET">>, stats, Req) ->
    json_reply(200, pertisk_eproxy_stats:snapshot(), Req);

handle(<<"GET">>, logs, Req) ->
    Qs = maps:from_list(cowboy_req:parse_qs(Req)),
    Type = maps:get(<<"type">>, Qs, undefined),
    Host = maps:get(<<"host">>, Qs, undefined),
    Site = maps:get(<<"site">>, Qs, undefined),
    MinLevel = logs_min_level(Qs),
    Logs0 = pertisk_eproxy_access_log:list(Type, Host, Site),
    Logs = filter_logs_by_min_level(Logs0, MinLevel),
    json_reply(200, Logs, Req);

handle(<<"GET">>, auth_config, Req) ->
    json_reply(200, pertisk_eproxy_auth:auth_config_map(), Req);
handle(<<"HEAD">>, auth_config, Req) ->
    json_reply(200, #{}, Req);

handle(<<"POST">>, auth_login, Req) ->
    with_json_body(Req, fun(Body, Req2) ->
        case pertisk_eproxy_auth:auth_mode() of
            local ->
                User = bin_field(maps:get(<<"username">>, Body, <<>>)),
                Pass = bin_field(maps:get(<<"password">>, Body, <<>>)),
                case pertisk_eproxy_auth:login(User, Pass) of
                    {ok, #{token := T, username := U, expires_in := E}} ->
                        json_reply(200, #{<<"token">> => T, <<"username">> => U, <<"expires_in">> => E}, Req2);
                    {error, invalid_credentials} ->
                        json_reply(401, #{<<"error">> => <<"Invalid credentials">>}, Req2);
                    {error, login_disabled} ->
                        json_reply(400, #{<<"error">> => <<"login not configured">>}, Req2)
                end;
            _ ->
                json_reply(400, #{<<"error">> => <<"login not configured">>}, Req2)
        end
    end);

handle(<<"POST">>, auth_refresh, Req) ->
    case pertisk_eproxy_auth:auth_mode() of
        disabled ->
            json_reply(200, #{<<"token">> => <<"guest">>, <<"username">> => <<"operator">>, <<"expires_in">> => 86400}, Req);
        local ->
            case pertisk_eproxy_auth:bearer_from_request(Req) of
                {ok, Token} ->
                    case pertisk_eproxy_auth:refresh(Token) of
                        {ok, #{token := T, username := U, expires_in := E}} ->
                            json_reply(200, #{<<"token">> => T, <<"username">> => U, <<"expires_in">> => E}, Req);
                        {error, _} ->
                            json_reply(401, #{<<"error">> => <<"Unauthorized">>}, Req)
                    end;
                error ->
                    json_reply(401, #{<<"error">> => <<"Unauthorized">>}, Req)
            end
    end;

handle(<<"GET">>, auth_check, Req) ->
    case pertisk_eproxy_auth:auth_mode() of
        disabled ->
            json_reply(200, #{<<"authenticated">> => true, <<"username">> => <<"operator">>}, Req);
        local ->
            case pertisk_eproxy_auth:bearer_from_request(Req) of
                {ok, Token} ->
                    case pertisk_eproxy_auth:verify_token(Token) of
                        {ok, U} ->
                            json_reply(200, #{<<"authenticated">> => true, <<"username">> => U}, Req);
                        {error, _} ->
                            json_reply(200, #{<<"authenticated">> => false}, Req)
                    end;
                error ->
                    json_reply(200, #{<<"authenticated">> => false}, Req)
            end
    end;

handle(<<"POST">>, auth_logout, Req) ->
    case pertisk_eproxy_auth:bearer_from_request(Req) of
        {ok, Token} -> pertisk_eproxy_auth:logout(Token);
        error -> ok
    end,
    json_reply(200, #{<<"success">> => true}, Req);

handle(<<"POST">>, admin_change_password, Req) ->
    case pertisk_eproxy_config:ingress_mode() of
        true ->
            json_reply(403, #{<<"error">> => <<"read-only in ingress mode">>}, Req);
        false ->
            json_reply(501, #{<<"error">> => <<"Password change is not implemented for eProxy">>}, Req)
    end;

handle(<<"GET">>, admin_api_token, Req) ->
    case ingress_api_token_supported() of
        true ->
            json_reply(200, #{<<"has_token">> => pertisk_eproxy_env_auth:api_token_configured()}, Req);
        false ->
            json_reply(200, #{<<"has_token">> => false}, Req)
    end;

handle(<<"POST">>, admin_api_token, Req) ->
    case ingress_api_token_supported() of
        false ->
            json_reply(501, #{<<"error">> => <<"API tokens are not implemented for eProxy">>}, Req);
        true ->
            with_json_body(Req, fun(Body, Req2) ->
                Pass = maps:get(<<"password">>, Body, <<>>),
                case pertisk_eproxy_env_auth:rotate_api_token(Pass) of
                    {ok, Token} ->
                        json_reply(200, #{
                            <<"token">> => Token,
                            <<"notice">> => <<
                                "Token is active until pod restart. "
                                "Persist by updating PERTISK_API_TOKEN in the auth Secret."
                            >>
                        }, Req2);
                    {error, invalid_credentials} ->
                        json_reply(401, #{<<"error">> => <<"invalid password">>}, Req2);
                    {error, env_not_configured} ->
                        json_reply(503, #{<<"error">> => <<"admin credentials not configured">>}, Req2);
                    {error, Reason} ->
                        error_reply(400, Reason, Req2)
                end
            end)
    end;

handle(<<"GET">>, backup_export, Req) ->
    Config = backup_export_config(),
    Body = thoas:encode(backup_config_to_json(Config)),
    Headers = #{
        <<"content-type">> => <<"application/json">>,
        <<"content-disposition">> => <<"attachment; filename=\"eproxy-config.json\"">>
    },
    Req2 = reply_compressed(200, with_alt_svc(Req, Headers), Body, Req),
    {ok, Req2, undefined};

handle(<<"POST">>, backup_restore, Req) ->
    with_json_body(Req, fun(Body, Req2) ->
        Data0 = maps:get(<<"data">>, Body, <<>>),
        JsonBin = bin_field(Data0),
        case thoas:decode(JsonBin) of
            {ok, Json} ->
                case pertisk_eproxy_config:json_to_config_pub(Json) of
                    Config when is_map(Config) ->
                        Existing = pertisk_eproxy_config:get_config(),
                        Config0 = preserve_redacted_tls_paths(Json, Config, Existing),
                        Config1 = preserve_redacted_dns_providers_in_config(Config0, Existing),
                        case restore_backup_certificate_records(Json) of
                            ok ->
                                ok = pertisk_eproxy_config:put_config(Config1),
                                json_reply(200, #{<<"status">> => <<"ok">>}, Req2);
                            {error, Reason} ->
                                error_reply(400, Reason, Req2)
                        end;
                    {error, R} ->
                        error_reply(400, R, Req2)
                end;
            {error, _} ->
                json_reply(400, #{<<"error">> => <<"invalid json in data">>}, Req2)
        end
    end);

handle(<<"GET">>, helm_history, Req) ->
    case pertisk_eproxy_config:ingress_mode() of
        false ->
            json_reply(404, #{<<"error">> => <<"Helm history is only available in ingress mode">>}, Req);
        true ->
            case helm_release_name() of
                {error, release_not_set} ->
                    json_reply(400, #{<<"error">> => <<"PERTISK_HELM_RELEASE is not set">>}, Req);
                {ok, Release} ->
                    case helm_enabled() of
                        false ->
                            json_reply(404, #{<<"error">> => <<"Helm history is disabled">>}, Req);
                        true ->
                            Namespace = helm_namespace(),
                            HistoryMax = helm_history_max(),
                            Args0 = ["history", binary_to_list(Release), "-n", binary_to_list(Namespace), "--output", "json"],
                            Args = case HistoryMax of
                                undefined -> Args0;
                                V -> Args0 ++ ["--max", integer_to_list(V)]
                            end,
                            case run_helm_cmd(Args) of
                                {ok, Out} ->
                                    case thoas:decode(iolist_to_binary(Out)) of
                                        {ok, Parsed} ->
                                            json_reply(200, #{
                                                <<"release">> => Release,
                                                <<"namespace">> => Namespace,
                                                <<"history">> => Parsed
                                            }, Req);
                                        {error, Reason} ->
                                            error_reply(500, {invalid_helm_output, Reason}, Req)
                                    end;
                                {error, not_found} ->
                                    json_reply(500, #{<<"error">> => <<"Failed to run helm: binary not found">>}, Req);
                                {error, {exit_status, _Code, Stderr}} ->
                                    json_reply(502, #{<<"error">> => iolist_to_binary(Stderr)}, Req)
                            end
                    end
            end
    end;

handle(<<"GET">>, helm_values, Req) ->
    case pertisk_eproxy_config:ingress_mode() of
        false ->
            json_reply(404, #{<<"error">> => <<"Helm values is only available in ingress mode">>}, Req);
        true ->
            case parse_int_param(cowboy_req:binding(revision, Req)) of
                {error, bad_id} ->
                    json_reply(400, #{<<"error">> => <<"invalid revision">>}, Req);
                {ok, Revision} when Revision < 0 ->
                    json_reply(400, #{<<"error">> => <<"invalid revision">>}, Req);
                {ok, Revision} ->
                    case helm_release_name() of
                        {error, release_not_set} ->
                            json_reply(400, #{<<"error">> => <<"PERTISK_HELM_RELEASE is not set">>}, Req);
                        {ok, Release} ->
                            case helm_enabled() of
                                false ->
                                    json_reply(404, #{<<"error">> => <<"Helm values is disabled">>}, Req);
                                true ->
                                    Namespace = helm_namespace(),
                                    Args = [
                                        "get", "values",
                                        binary_to_list(Release),
                                        "-n", binary_to_list(Namespace),
                                        "--revision", integer_to_list(Revision),
                                        "--all"
                                    ],
                                    case run_helm_cmd(Args) of
                                        {ok, Out} ->
                                            json_reply(200, #{
                                                <<"release">> => Release,
                                                <<"namespace">> => Namespace,
                                                <<"revision">> => Revision,
                                                <<"values">> => iolist_to_binary(Out)
                                            }, Req);
                                        {error, not_found} ->
                                            json_reply(500, #{<<"error">> => <<"Failed to run helm: binary not found">>}, Req);
                                        {error, {exit_status, _Code, Stderr}} ->
                                            json_reply(502, #{<<"error">> => iolist_to_binary(Stderr)}, Req)
                                    end
                            end
                    end
            end
    end;

handle(<<"GET">>, certificates, Req) ->
    Config = pertisk_eproxy_config:get_config(),
    Sites = safe_sites_list(maps:get(sites, Config, [])),
    IngressRows = ingress_certificate_rows(Sites),
    case pertisk_eproxy_db:list_certificates(db_file_path()) of
        {ok, Certs} ->
            DbRows = certificate_rows_json(Certs, Sites),
            json_reply(200, merge_certificate_rows(DbRows, IngressRows), Req);
        {error, Reason} ->
            case pertisk_eproxy_config:ingress_mode() of
                true ->
                    %% In ingress mode SQLite can be intentionally absent; use live Ingress TLS data.
                    json_reply(200, IngressRows, Req);
                false ->
                    error_reply(500, Reason, Req)
            end
    end;

handle(<<"POST">>, certificates, Req) ->
    with_json_body(Req, fun(Body, Req2) ->
        Name = maps:get(<<"name">>, Body, <<>>),
        case pertisk_eproxy_db:insert_certificate(db_file_path(), Name) of
            {ok, Id} ->
                json_reply(201, #{<<"status">> => <<"ok">>, <<"id">> => Id}, Req2);
            {error, empty_name} ->
                json_reply(400, #{<<"error">> => <<"name is required">>}, Req2);
            {error, Reason} ->
                error_reply(400, Reason, Req2)
        end
    end);

handle(<<"POST">>, certificates_import, Req) ->
    with_json_body(Req, fun(Body, Req2) ->
        CertPem = bin_field(maps:get(<<"cert_pem">>, Body, <<>>)),
        KeyPem = bin_field(maps:get(<<"key_pem">>, Body, <<>>)),
        case pertisk_eproxy_tls_import:save_listener_pem(CertPem, KeyPem) of
            {error, Msg} ->
                json_reply(400, #{<<"error">> => Msg}, Req2);
            {ok, {CertPath, KeyPath}} ->
                Name = imported_cert_name(CertPath),
                case insert_imported_certificate(Name, CertPath, KeyPath) of
                    {ok, Id} ->
                        json_reply(201, #{
                            <<"status">> => <<"ok">>,
                            <<"id">> => Id,
                            <<"notice">> => <<"Certificate imported as a new TLS certificate.">>
                        }, Req2);
                    {error, Reason} ->
                        error_reply(400, Reason, Req2)
                end
        end
    end);

handle(<<"PUT">>, certificate_import, Req) ->
    IdBin = cowboy_req:binding(id, Req),
    case parse_int_param(IdBin) of
        {error, bad_id} ->
            json_reply(400, #{<<"error">> => <<"invalid certificate id">>}, Req);
        {ok, Id} ->
            with_json_body(Req, fun(Body, Req2) ->
                CertPem = bin_field(maps:get(<<"cert_pem">>, Body, <<>>)),
                KeyPem = bin_field(maps:get(<<"key_pem">>, Body, <<>>)),
                case pertisk_eproxy_tls_import:save_listener_pem(CertPem, KeyPem) of
                    {error, Msg} ->
                        json_reply(400, #{<<"error">> => Msg}, Req2);
                    {ok, {CertPath, KeyPath}} ->
                        case pertisk_eproxy_db:update_certificate_pem(db_file_path(), Id, CertPath, KeyPath) of
                            ok ->
                                json_reply(200, #{
                                    <<"status">> => <<"ok">>,
                                    <<"notice">> => <<"Certificate PEM updated.">>
                                }, Req2);
                            {error, Reason} ->
                                error_reply(400, Reason, Req2)
                        end
                end
            end)
    end;

handle(<<"PUT">>, certificate, Req) ->
    IdBin = cowboy_req:binding(id, Req),
    case parse_int_param(IdBin) of
        {error, bad_id} ->
            json_reply(400, #{<<"error">> => <<"invalid certificate id">>}, Req);
        {ok, Id} ->
            with_json_body(Req, fun(Body, Req2) ->
                Name = maps:get(<<"name">>, Body, <<>>),
                case certificate_name_by_id(Id) of
                    {ok, PrevName} ->
                        case pertisk_eproxy_db:update_certificate(db_file_path(), Id, Name) of
                            ok ->
                                update_sites_cert_name(PrevName, bin_field(Name)),
                                json_reply(200, #{<<"status">> => <<"ok">>}, Req2);
                            {error, empty_name} ->
                                json_reply(400, #{<<"error">> => <<"name is required">>}, Req2);
                            {error, Reason} ->
                                error_reply(400, Reason, Req2)
                        end;
                    {error, not_found} ->
                        not_found_reply(Req2);
                    {error, Reason} ->
                        error_reply(400, Reason, Req2)
                end
            end)
    end;

handle(<<"DELETE">>, certificate, Req) ->
    IdBin = cowboy_req:binding(id, Req),
    case parse_int_param(IdBin) of
        {error, bad_id} ->
            json_reply(400, #{<<"error">> => <<"invalid certificate id">>}, Req);
        {ok, Id} ->
            case certificate_name_by_id(Id) of
                {ok, Name} ->
                    case certificate_in_use(Name) of
                        true ->
                            json_reply(400, #{<<"error">> => <<"Certificate is used by one or more sites">>}, Req);
                        false ->
                            case pertisk_eproxy_db:delete_certificate(db_file_path(), Id) of
                                ok -> json_reply(200, #{<<"status">> => <<"deleted">>}, Req);
                                {error, not_found} -> not_found_reply(Req);
                                {error, Reason} -> error_reply(400, Reason, Req)
                            end
                    end;
                {error, not_found} ->
                    not_found_reply(Req);
                {error, Reason} ->
                    error_reply(400, Reason, Req)
            end
    end;

handle(<<"POST">>, certificate_renew, Req) ->
    IdBin = cowboy_req:binding(id, Req),
    case parse_int_param(IdBin) of
        {error, bad_id} ->
            json_reply(400, #{<<"error">> => <<"invalid certificate id">>}, Req);
        {ok, Id} ->
            case certificate_name_by_id(Id) of
                {ok, Name} ->
                    Sites = sites_for_certificate(Name),
                    case Sites of
                        [] ->
                            json_reply(400, #{<<"error">> => <<"certificate is not assigned to any site">>}, Req);
                        _ ->
                            _ = pertisk_eproxy_acme_dns:schedule_scan(),
                            json_reply(202, #{
                                <<"status">> => <<"scheduled">>,
                                <<"sites">> => [json_text(H) || H <- Sites],
                                <<"notice">> => <<"ACME renewal scan queued for assigned sites">>
                            }, Req)
                    end;
                {error, not_found} ->
                    not_found_reply(Req);
                {error, Reason} ->
                    error_reply(400, Reason, Req)
            end
    end;

handle(<<"GET">>, dns_providers, Req) ->
    case pertisk_eproxy_db:list_dns_providers(db_file_path()) of
        {ok, Rows} ->
            json_reply(200, [dns_provider_db_row_to_json(R) || R <- Rows], Req);
        {error, Reason} ->
            error_reply(500, Reason, Req)
    end;

handle(<<"POST">>, dns_providers, Req) ->
    with_json_body(Req, fun(Body, Req2) ->
        Name = bin_field(maps:get(<<"name">>, Body, <<>>)),
        Pt = bin_field(maps:get(<<"provider_type">>, Body, <<"label">>)),
        Cred = parse_dns_credentials(maps:get(<<"credentials">>, Body, #{})),
        case dns_credentials_has_redacted(Cred) of
            true ->
                json_reply(
                    400,
                    #{<<"error">> => <<"credentials contain [redacted]; provide real secret values when creating provider">>},
                    Req2
                );
            false ->
                case pertisk_eproxy_db:insert_dns_provider(db_file_path(), Name, Pt, Cred) of
                    {ok, Id} ->
                        sync_dns_providers_into_runtime_config(),
                        json_reply(201, #{<<"status">> => <<"ok">>, <<"id">> => Id}, Req2);
                    {error, empty_name} ->
                        json_reply(400, #{<<"error">> => <<"name is required">>}, Req2);
                    {error, empty_provider_type} ->
                        json_reply(400, #{<<"error">> => <<"provider_type is required">>}, Req2);
                    {error, Reason} ->
                        error_reply(400, Reason, Req2)
                end
        end
    end);

handle(<<"PUT">>, dns_provider, Req) ->
    IdBin = cowboy_req:binding(id, Req),
    case parse_int_param(IdBin) of
        {error, bad_id} ->
            json_reply(400, #{<<"error">> => <<"invalid dns provider id">>}, Req);
        {ok, Id} ->
            with_json_body(Req, fun(Body, Req2) ->
                Name = bin_field(maps:get(<<"name">>, Body, <<>>)),
                Pt = bin_field(maps:get(<<"provider_type">>, Body, <<"label">>)),
                CredIn = parse_dns_credentials(maps:get(<<"credentials">>, Body, #{})),
                case dns_credentials_has_redacted(CredIn) of
                    true ->
                        json_reply(
                            400,
                            #{
                                <<"error">> =>
                                    <<"credentials contain [redacted]; provide real secret values when updating provider">>
                            },
                            Req2
                        );
                    false ->
                        case pertisk_eproxy_db:get_dns_provider_by_id(db_file_path(), Id) of
                            {ok, PrevRow} ->
                                PrevName = json_text(maps:get(name, PrevRow, <<>>)),
                                PrevCred = maps:get(credentials, PrevRow, #{}) ,
                                RuntimeCred = find_dns_provider_creds(PrevName, maps:get(dns_providers, pertisk_eproxy_config:get_config(), [])),
                                ExistingCred = merge_dns_credentials_for_update(PrevCred, RuntimeCred),
                                Cred = merge_dns_credentials_for_update(CredIn, ExistingCred),
                                case dns_credentials_has_redacted(Cred) of
                                    true ->
                                        json_reply(
                                            400,
                                            #{
                                                <<"error">> =>
                                                    <<"credentials still contain [redacted]. Re-enter real secret values before saving.">>
                                            },
                                            Req2
                                        );
                                    false ->
                                        case pertisk_eproxy_db:update_dns_provider(db_file_path(), Id, Name, Pt, Cred) of
                                            ok ->
                                                update_sites_dns_provider_name(PrevName, Name),
                                                sync_dns_providers_into_runtime_config(),
                                                json_reply(200, #{<<"status">> => <<"ok">>}, Req2);
                                            {error, empty_name} ->
                                                json_reply(400, #{<<"error">> => <<"name is required">>}, Req2);
                                            {error, empty_provider_type} ->
                                                json_reply(400, #{<<"error">> => <<"provider_type is required">>}, Req2);
                                            {error, Reason} ->
                                                error_reply(400, Reason, Req2)
                                        end
                                end;
                            {error, not_found} ->
                                not_found_reply(Req2);
                            {error, Reason} ->
                                error_reply(400, Reason, Req2)
                        end
                end
            end)
    end;

handle(<<"DELETE">>, dns_provider, Req) ->
    IdOrName = cowboy_req:binding(id, Req),
    case parse_int_param(IdOrName) of
        {ok, Id} ->
            case dns_provider_name_by_id(Id) of
                {ok, Name} ->
                    case dns_provider_in_use(Name) of
                        true ->
                            json_reply(400, #{<<"error">> => <<"DNS provider is used by one or more sites">>}, Req);
                        false ->
                            case pertisk_eproxy_db:delete_dns_provider(db_file_path(), Id) of
                                ok ->
                                    sync_dns_providers_into_runtime_config(),
                                    json_reply(200, #{<<"status">> => <<"deleted">>}, Req);
                                {error, not_found} ->
                                    not_found_reply(Req);
                                {error, Reason} ->
                                    error_reply(400, Reason, Req)
                            end
                    end;
                {error, not_found} ->
                    not_found_reply(Req);
                {error, Reason} ->
                    error_reply(400, Reason, Req)
            end;
        {error, bad_id} ->
            Name = json_text(IdOrName),
            case dns_provider_in_use(Name) of
                true ->
                    json_reply(400, #{<<"error">> => <<"DNS provider is used by one or more sites">>}, Req);
                false ->
                    case pertisk_eproxy_db:delete_dns_provider_by_name(db_file_path(), Name) of
                        ok ->
                            sync_dns_providers_into_runtime_config(),
                            json_reply(200, #{<<"status">> => <<"deleted">>}, Req);
                        {error, not_found} ->
                            not_found_reply(Req);
                        {error, Reason} ->
                            error_reply(400, Reason, Req)
                    end
            end
    end;

handle(<<"POST">>, dns_provider_validate, Req) ->
    with_json_body(Req, fun(Body, Req2) ->
        Pt = bin_field(maps:get(<<"provider_type">>, Body, <<>>)),
        Cred = parse_dns_credentials(maps:get(<<"credentials">>, Body, #{})),
        case Pt of
            <<>> ->
                json_reply(400, #{<<"error">> => <<"provider_type is required">>}, Req2);
            _ ->
                case pertisk_eproxy_acme_dns:validate_dns_provider(Pt, Cred) of
                    {ok, Details} ->
                        json_reply(200, #{<<"ok">> => true, <<"details">> => Details}, Req2);
                    {error, Reason} ->
                        json_reply(400, #{<<"ok">> => false, <<"error">> => format_validate_error(Reason)}, Req2)
                end
        end
    end);

handle(<<"POST">>, tls_listener, Req) ->
    with_json_body(Req, fun(Body, Req2) ->
        CertPem = bin_field(maps:get(<<"cert_pem">>, Body, <<>>)),
        KeyPem = bin_field(maps:get(<<"key_pem">>, Body, <<>>)),
        case pertisk_eproxy_tls_import:save_listener_pem(CertPem, KeyPem) of
            {error, Msg} ->
                json_reply(400, #{<<"error">> => Msg}, Req2);
            {ok, {CertPath, KeyPath}} ->
                C0 = pertisk_eproxy_config:get_config(),
                NewC = maps:merge(C0, #{tls_cert_file => CertPath, tls_key_file => KeyPath}),
                case pertisk_eproxy_config:put_config(NewC) of
                    ok ->
                        json_reply(200, #{
                            <<"status">> => <<"ok">>,
                            <<"tls_cert_file">> => CertPath,
                            <<"tls_key_file">> => <<"[redacted]">>,
                            <<"notice">> =>
                                <<"Restart the proxy process to load the new TLS material on the HTTPS listener.">>
                        }, Req2);
                    {error, R} ->
                        error_reply(400, R, Req2)
                end
        end
    end);

handle(<<"GET">>, config, Req) ->
    Config = pertisk_eproxy_config:get_config(),
    Data =
        case should_show_all_config(Req) of
            true -> config_to_json_all(Config);
            false -> config_to_json(Config)
        end,
    Body = thoas:encode(Data),
    Headers = #{
        <<"content-type">> => <<"application/json">>,
        <<"cache-control">> => <<"no-store, max-age=0">>
    },
    Req2 = cowboy_req:reply(200, with_tracking_id_header(Req, with_alt_svc(Req, Headers)), Body, Req),
    {ok, Req2, undefined};

handle(<<"PUT">>, config, Req) ->
    with_json_body(Req, fun(Body, Req2) ->
        Existing = pertisk_eproxy_config:get_config(),
        Parsed = pertisk_eproxy_config:json_to_config_pub(Body),
        Config0 = preserve_redacted_tls_paths(Body, Parsed, Existing),
        Config = preserve_redacted_dns_providers_in_config(Config0, Existing),
        case pertisk_eproxy_config:put_config(Config) of
            ok -> json_reply(200, #{status => <<"ok">>}, Req2);
            {error, R} -> error_reply(400, R, Req2)
        end
    end);

handle(<<"GET">>, sites, Req) ->
    Sites = pertisk_eproxy_config:get_sites(),
    json_reply(200, [site_to_json(S) || S <- Sites], Req);

handle(<<"POST">>, sites, Req) ->
    with_json_body(Req, fun(Body, Req2) ->
        Config  = pertisk_eproxy_config:get_config(),
        Sites   = maps:get(sites, Config, []),
        NewSite = parse_site(Body),
        NewConfig = Config#{sites => Sites ++ [NewSite]},
        case pertisk_eproxy_config:put_config(NewConfig) of
            ok ->
                json_reply(201, site_to_json(NewSite), Req2);
            {error, R} ->
                error_reply(400, R, Req2)
        end
    end);

handle(<<"GET">>, site, Req) ->
    HostParam = cowboy_req:binding(host, Req),
    Sites = pertisk_eproxy_config:get_sites(),
    case lists:search(fun(#{host := H}) -> H =:= HostParam end, Sites) of
        {value, S} -> json_reply(200, site_to_json(S), Req);
        false      -> not_found_reply(Req)
    end;

handle(<<"PUT">>, site, Req) ->
    HostParam = cowboy_req:binding(host, Req),
    with_json_body(Req, fun(Body, Req2) ->
        ParsedSite = parse_site(Body),
        Config  = pertisk_eproxy_config:get_config(),
        Sites   = maps:get(sites, Config, []),
        ExistingSite = find_site_by_host(HostParam, Sites),
        NewSite = preserve_site_tls_fields(Body, ParsedSite, ExistingSite),
        NewSites = [S || S = #{host := H} <- Sites, H =/= HostParam, H =/= maps:get(host, NewSite)],
        case pertisk_eproxy_config:put_config(Config#{sites => NewSites ++ [NewSite]}) of
            ok ->
                json_reply(200, site_to_json(NewSite), Req2);
            {error, R} ->
                error_reply(400, R, Req2)
        end
    end);

handle(<<"DELETE">>, site, Req) ->
    HostParam = cowboy_req:binding(host, Req),
    Config    = pertisk_eproxy_config:get_config(),
    Sites     = maps:get(sites, Config, []),
    NewSites  = [S || S = #{host := H} <- Sites, H =/= HostParam],
    case pertisk_eproxy_config:put_config(Config#{sites => NewSites}) of
        ok ->
            json_reply(200, #{status => <<"deleted">>}, Req);
        {error, R} ->
            error_reply(400, R, Req)
    end;

handle(<<"GET">>, backends, Req) ->
    Backends = pertisk_eproxy_config:get_backends(),
    json_reply(200, [backend_to_json(B) || B <- Backends], Req);

handle(<<"POST">>, backends, Req) ->
    with_json_body(Req, fun(Body, Req2) ->
        Config   = pertisk_eproxy_config:get_config(),
        Backends = maps:get(backends, Config, []),
        NewBe    = parse_backend(Body),
        NewConfig = Config#{backends => Backends ++ [NewBe]},
        case pertisk_eproxy_config:put_config(NewConfig) of
            ok ->
                json_reply(201, backend_to_json(NewBe), Req2);
            {error, R} ->
                error_reply(400, R, Req2)
        end
    end);

handle(<<"GET">>, backend, Req) ->
    Name = cowboy_req:binding(name, Req),
    case pertisk_eproxy_backend:status(Name) of
        {ok, Status}       -> json_reply(200, status_to_json(Status), Req);
        {error, not_found} -> not_found_reply(Req)
    end;

handle(<<"DELETE">>, backend, Req) ->
    Name     = cowboy_req:binding(name, Req),
    Config   = pertisk_eproxy_config:get_config(),
    Backends = maps:get(backends, Config, []),
    NewBes   = [B || B = #{name := N} <- Backends, N =/= Name],
    case pertisk_eproxy_config:put_config(Config#{backends => NewBes}) of
        ok ->
            pertisk_eproxy_backend_sup:stop_backend(Name),
            json_reply(200, #{status => <<"deleted">>}, Req);
        {error, R} ->
            error_reply(400, R, Req)
    end;

handle(<<"GET">>, health, Req) ->
    case pertisk_eproxy_health_cache:get() of
        {ok, Body} ->
            json_reply_body(200, Body, Req);
        {error, Reason} ->
            error_reply(500, Reason, Req)
    end;

handle(<<"HEAD">>, health, Req) ->
    case pertisk_eproxy_health_cache:get() of
        {ok, _Body} ->
            json_reply_body(200, <<>>, Req);
        {error, Reason} ->
            error_reply(500, Reason, Req)
    end;

handle(<<"GET">>, metrics, Req) ->
    Output = prometheus_text_format:format(),
    Req2 = reply_compressed(
        200,
        with_alt_svc(Req, #{<<"content-type">> => <<"text/plain; version=0.0.4">>}),
        Output,
        Req
    ),
    {ok, Req2, metrics};

handle(<<"POST">>, reload, Req) ->
    case pertisk_eproxy_config:reload() of
        ok ->
            _ = pertisk_eproxy_health_cache:invalidate(),
            json_reply(200, #{status => <<"reloaded">>}, Req);
        {error, R} -> error_reply(500, R, Req)
    end;

handle(<<"GET">>, ingress_live, Req) ->
    _ = pertisk_ingress_status:live_ok(),
    json_reply(200, #{<<"status">> => <<"ok">>}, Req);
handle(<<"HEAD">>, ingress_live, Req) ->
    json_reply(200, #{}, Req);

handle(<<"GET">>, ingress_ready, Req) ->
    ingress_ready_reply(Req, true);
handle(<<"HEAD">>, ingress_ready, Req) ->
    ingress_ready_reply(Req, false);

handle(<<"GET">>, ingress_status, Req) ->
    json_reply(200, pertisk_ingress_status:snapshot(), Req);
handle(<<"HEAD">>, ingress_status, Req) ->
    json_reply(200, #{}, Req);

handle(<<"GET">>, ingress_watchers, Req) ->
    S = pertisk_ingress_status:snapshot(),
    json_reply(200, #{
        <<"watcher">> => maps:get(<<"watcher">>, S, <<"disconnected">>),
        <<"leader">> => maps:get(<<"leader">>, S, false)
    }, Req);

handle(<<"GET">>, ingress_errors, Req) ->
    S = pertisk_ingress_status:snapshot(),
    json_reply(200, #{<<"last_error">> => maps:get(<<"last_error">>, S, null)}, Req);

handle(<<"GET">>, ingress_resources, Req) ->
    Sites = pertisk_eproxy_config:get_sites(),
    Backends = pertisk_eproxy_config:get_backends(),
    json_reply(200, #{
        <<"sites">> => [site_to_json(S) || S <- Sites],
        <<"backends">> => [backend_to_json(B) || B <- Backends]
    }, Req);

handle(<<"GET">>, kubernetes_namespaces, Req) ->
    kubernetes_reply(pertisk_eproxy_admin_kubernetes:namespaces(), Req);

handle(<<"GET">>, kubernetes_pods, Req) ->
    Qs = maps:from_list(cowboy_req:parse_qs(Req)),
    Ns = maps:get(<<"namespace">>, Qs, <<>>),
    kubernetes_reply(pertisk_eproxy_admin_kubernetes:pods(Ns), Req);

handle(<<"GET">>, kubernetes_services, Req) ->
    Qs = maps:from_list(cowboy_req:parse_qs(Req)),
    Ns = maps:get(<<"namespace">>, Qs, <<>>),
    kubernetes_reply(pertisk_eproxy_admin_kubernetes:services(Ns), Req);

handle(<<"GET">>, kubernetes_tls_secrets, Req) ->
    Qs = maps:from_list(cowboy_req:parse_qs(Req)),
    Ns = maps:get(<<"namespace">>, Qs, <<>>),
    kubernetes_reply(pertisk_eproxy_admin_kubernetes:tls_secrets(Ns), Req);

handle(<<"GET">>, kubernetes_ingresses, Req) ->
    kubernetes_reply(pertisk_eproxy_admin_kubernetes:list_ingresses(), Req);

handle(<<"POST">>, kubernetes_ingresses, Req) ->
    with_json_body(Req, fun(Body, Req2) ->
        kubernetes_reply(201, pertisk_eproxy_admin_kubernetes:create_ingress(Body), Req2)
    end);

handle(<<"GET">>, kubernetes_ingress, Req) ->
    Ns = cowboy_req:binding(namespace, Req),
    Name = cowboy_req:binding(name, Req),
    kubernetes_reply(pertisk_eproxy_admin_kubernetes:get_ingress(Ns, Name), Req);

handle(<<"PUT">>, kubernetes_ingress, Req) ->
    Ns = cowboy_req:binding(namespace, Req),
    Name = cowboy_req:binding(name, Req),
    with_json_body(Req, fun(Body, Req2) ->
        kubernetes_reply(pertisk_eproxy_admin_kubernetes:update_ingress(Ns, Name, Body), Req2)
    end);

handle(<<"DELETE">>, kubernetes_ingress, Req) ->
    Ns = cowboy_req:binding(namespace, Req),
    Name = cowboy_req:binding(name, Req),
    kubernetes_reply(pertisk_eproxy_admin_kubernetes:delete_ingress(Ns, Name), Req);

handle(_Method, _Resource, Req) ->
    Req2 = reply_compressed(
        405,
        #{<<"content-type">> => <<"text/plain">>},
        <<"Method Not Allowed">>,
        Req
    ),
    {ok, Req2, undefined}.

%% ---------------------------------------------------------------------------
%% JSON helpers
%% ---------------------------------------------------------------------------

%% Count management-plane JSON responses so /api/stats reflects admin traffic
%% (proxy listeners do not hit this module).
inc_management_request_metric(Req, Status) when is_integer(Status) ->
    try
        Host = cowboy_req:host(Req),
        HostBin = host_metric_bin(Host),
        StatusBin = integer_to_binary(Status),
        ok = pertisk_eproxy_metrics:inc_request(HostBin, StatusBin, <<"admin">>)
    catch _:_ ->
        ok
    end;
inc_management_request_metric(_Req, _Status) ->
    ok.

host_metric_bin(H) when is_binary(H) -> H;
host_metric_bin(H) -> iolist_to_binary(io_lib:format("~s", [H])).

%% Minimal JSON for HTTP/3 fast path when cache is cold (rare).
-spec h3_light_health_json() -> binary().
h3_light_health_json() ->
    thoas:encode(#{<<"status">> => <<"ok">>}).

-spec build_health_json() -> binary().
build_health_json() ->
    Backends = pertisk_eproxy_config:get_backends(),
    Sites = pertisk_eproxy_config:get_sites(),
    Health = parallel_backend_health_summary(Backends),
    TlsSites = site_tls_health_rows(Sites),
    thoas:encode(#{backends => Health, acme => lego_health_snapshot(), tls_sites => TlsSites}).

parallel_backend_health_summary(Backends) ->
    Parent = self(),
    Ref = erlang:make_ref(),
    lists:foreach(
        fun(#{name := Name}) ->
            spawn(fun() ->
                Row =
                    case pertisk_eproxy_backend:status(Name) of
                        {ok, #{upstreams := Ups}} ->
                            Healthy = length([U || U = #{healthy := true} <- Ups]),
                            #{name => Name, total => length(Ups), healthy => Healthy};
                        _ ->
                            #{name => Name, total => 0, healthy => 0}
                    end,
                Parent ! {Ref, Row}
            end)
        end,
        Backends
    ),
    collect_backend_health_rows(length(Backends), Ref, []).

collect_backend_health_rows(0, _Ref, Acc) ->
    Acc;
collect_backend_health_rows(N, Ref, Acc) ->
    receive
        {Ref, Row} ->
            collect_backend_health_rows(N - 1, Ref, [Row | Acc])
    after 30000 ->
        Acc
    end.

json_reply(Status, Data, Req) ->
    json_reply(Status, Data, Req, #{}).

json_reply_body(Status, Body, Req) when is_binary(Body) ->
    inc_management_request_metric(Req, Status),
    Req2 = reply_compressed(
        Status,
        with_alt_svc(Req, #{<<"content-type">> => <<"application/json">>}),
        Body,
        Req
    ),
    {ok, Req2, undefined}.

json_reply(Status, Data, Req, ExtraHeaders) when is_map(ExtraHeaders) ->
    inc_management_request_metric(Req, Status),
    Body = thoas:encode(Data),
    Req2 = reply_compressed(
        Status,
        maps:merge(with_alt_svc(Req, #{<<"content-type">> => <<"application/json">>}), ExtraHeaders),
        Body,
        Req
    ),
    {ok, Req2, undefined}.

reply_compressed(Status, Headers, Body, Req) ->
    HeadersWithTracking = with_tracking_id_header(Req, Headers),
    {OutHeaders, OutBody} =
        pertisk_eproxy_compression:maybe_compress_cowboy(Status, Req, HeadersWithTracking, Body),
    cowboy_req:reply(Status, OutHeaders, OutBody, Req).

with_tracking_id_header(_Req, Headers) when is_map(Headers) ->
    Headers.

request_tracking_id(Req) ->
    case cowboy_req:header(<<"x-request-id">>, Req, <<>>) of
        <<>> -> generate_tracking_id();
        Existing -> Existing
    end.

generate_tracking_id() ->
    hex_bin(crypto:strong_rand_bytes(16)).

logs_min_level(Qs) ->
    case maps:get(<<"min_level">>, Qs, undefined) of
        undefined ->
            case maps:get(<<"level">>, Qs, undefined) of
                undefined ->
                    iolist_to_binary(pertisk_eproxy_log_level:label(pertisk_eproxy_log_level:configured()));
                LevelBin ->
                    normalize_log_level(LevelBin)
            end;
        LevelBin ->
            normalize_log_level(LevelBin)
    end.

normalize_log_level(LevelBin) when is_binary(LevelBin) ->
    case pertisk_eproxy_log_level:parse(LevelBin) of
        {ok, Level} -> iolist_to_binary(pertisk_eproxy_log_level:label(Level));
        error -> iolist_to_binary(pertisk_eproxy_log_level:label(pertisk_eproxy_log_level:configured()))
    end;
normalize_log_level(Level) when is_atom(Level) ->
    iolist_to_binary(pertisk_eproxy_log_level:label(Level));
normalize_log_level(_) ->
    iolist_to_binary(pertisk_eproxy_log_level:label(pertisk_eproxy_log_level:configured())).

filter_logs_by_min_level(Logs, MinLevel) when is_list(Logs) ->
    MinRank = log_level_rank(MinLevel),
    lists:filter(
        fun(E) ->
            Level = maps:get(<<"level">>, E, <<"info">>),
            log_level_rank(Level) >= MinRank
        end,
        Logs
    ).

log_level_rank(<<"debug">>) -> 10;
log_level_rank(<<"info">>) -> 20;
log_level_rank(<<"notice">>) -> 30;
log_level_rank(<<"warn">>) -> 40;
log_level_rank(<<"warning">>) -> 40;
log_level_rank(<<"error">>) -> 50;
log_level_rank(<<"critical">>) -> 60;
log_level_rank(<<"alert">>) -> 70;
log_level_rank(<<"emergency">>) -> 80;
log_level_rank(Level) when is_atom(Level) ->
    log_level_rank(iolist_to_binary(pertisk_eproxy_log_level:label(Level)));
log_level_rank(_) -> 20.

hex_bin(Bin) when is_binary(Bin) ->
    iolist_to_binary([io_lib:format("~2.16.0b", [B]) || <<B:8>> <= Bin]).

error_reply(Status, Reason, Req) ->
    Method = cowboy_req:method(Req),
    Path = cowboy_req:path(Req),
    RequestId = request_tracking_id(Req),
    case Status >= 500 of
        true ->
            lager:error(
                "admin api error status=~w method=~s path=~s request_id=~s reason=~p",
                [Status, Method, Path, RequestId, Reason]
            );
        false ->
            lager:warning(
                "admin api error status=~w method=~s path=~s request_id=~s reason=~p",
                [Status, Method, Path, RequestId, Reason]
            )
    end,
    Msg = iolist_to_binary(io_lib:format("~p", [Reason])),
    json_reply(Status, #{error => Msg}, Req).

format_validate_error(Reason) when is_binary(Reason) ->
    Reason;
format_validate_error(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).

lego_health_snapshot() ->
    LegoRequired = lego_required_for_configured_providers(),
    case pertisk_eproxy_acme_lego:find_lego_executable() of
        false ->
            #{lego_installed => false, lego_path => null, lego_required => LegoRequired};
        Path ->
            #{lego_installed => true, lego_path => iolist_to_binary(Path), lego_required => LegoRequired}
    end.

lego_required_for_configured_providers() ->
    case pertisk_eproxy_db:list_dns_providers(db_file_path()) of
        {ok, Rows} ->
            lists:any(fun provider_row_requires_lego/1, Rows);
        {error, _} ->
            true
    end.

provider_row_requires_lego(Row) when is_map(Row) ->
    case provider_type_to_bin(maps:get(provider_type, Row, <<>>)) of
        <<"route53">> -> true;
        <<"godaddy">> -> true;
        <<"namecheap">> -> true;
        <<"ovh">> -> true;
        <<"googleclouddns">> -> true;
        <<"azure">> -> true;
        <<"rfc2136">> -> true;
        <<"cloudns">> -> true;
        <<"easydns">> -> true;
        <<"dnsmadeeasy">> -> true;
        <<"dynu">> -> true;
        <<"customlego">> -> true;
        _ -> false
    end;
provider_row_requires_lego(_) ->
    false.

provider_type_to_bin(V) when is_binary(V) ->
    unicode:characters_to_binary(string:lowercase(unicode:characters_to_list(V)), utf8);
provider_type_to_bin(V) when is_list(V) ->
    unicode:characters_to_binary(string:lowercase(V), utf8);
provider_type_to_bin(V) when is_atom(V) ->
    unicode:characters_to_binary(string:lowercase(atom_to_list(V)), utf8);
provider_type_to_bin(_) ->
    <<>>.

not_found_reply(Req) ->
    json_reply(404, #{error => <<"not found">>}, Req).

kubernetes_reply(Result, Req) ->
    kubernetes_reply(200, Result, Req).

kubernetes_reply(Status, {ok, Data}, Req) when is_list(Data) ->
    json_reply(Status, Data, Req);
kubernetes_reply(Status, {ok, Data}, Req) when is_map(Data) ->
    json_reply(Status, Data, Req);
kubernetes_reply(_Status, {error, not_available}, Req) ->
    json_reply(404, #{error => <<"Kubernetes API is only available in ingress mode">>}, Req);
kubernetes_reply(_Status, {error, Msg}, Req) when is_binary(Msg) ->
    json_reply(400, #{error => Msg}, Req);
kubernetes_reply(_Status, {error, Reason}, Req) ->
    ErrStatus = kubernetes_error_status(Reason),
    json_reply(ErrStatus, #{error => kubernetes_error_message(Reason)}, Req).

kubernetes_error_status({error, #{<<"code">> := 404}}) -> 404;
kubernetes_error_status({error, #{<<"reason">> := <<"NotFound">>}}) -> 404;
kubernetes_error_status({error, #{<<"code">> := 403}}) -> 403;
kubernetes_error_status({error, #{<<"reason">> := <<"Forbidden">>}}) -> 403;
kubernetes_error_status(#{<<"code">> := 404}) -> 404;
kubernetes_error_status(#{<<"reason">> := <<"NotFound">>}) -> 404;
kubernetes_error_status(#{<<"code">> := 403}) -> 403;
kubernetes_error_status(#{<<"reason">> := <<"Forbidden">>}) -> 403;
kubernetes_error_status(#{<<"status">> := #{<<"code">> := 403}}) -> 403;
kubernetes_error_status(#{<<"status">> := #{<<"code">> := 404}}) -> 404;
kubernetes_error_status(Reason) when is_map(Reason) -> 500;
kubernetes_error_status(_) -> 400.

kubernetes_error_message(Reason) when is_binary(Reason) ->
    Reason;
kubernetes_error_message(econnrefused) ->
    <<"Kubernetes API connection refused">>;
kubernetes_error_message(timeout) ->
    <<"Kubernetes API request timed out">>;
kubernetes_error_message({failed_connect, _}) ->
    <<"Failed to connect to Kubernetes API">>;
kubernetes_error_message({conn_failed, _}) ->
    <<"Failed to connect to Kubernetes API">>;
kubernetes_error_message(#{<<"message">> := Msg}) when is_binary(Msg) ->
    Msg;
kubernetes_error_message(#{<<"status">> := #{<<"message">> := Msg}}) when is_binary(Msg) ->
    Msg;
kubernetes_error_message(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).

with_json_body(Req, Fun) ->
    case read_body_full(Req) of
        {error, Reason} ->
            Msg = iolist_to_binary(io_lib:format("~p", [Reason])),
            json_reply(400, #{error => Msg}, Req);
        {ok, Body, Req2} ->
            case thoas:decode(Body) of
                {ok, Json}       -> Fun(Json, Req2);
                {error, _Reason} -> json_reply(400, #{error => <<"invalid json">>}, Req2)
            end
    end.

%% Cowboy may return {more, Data, Req} for large bodies; read until complete.
read_body_full(Req) ->
    read_body_full(Req, <<>>).

read_body_full(Req, Acc) ->
    case cowboy_req:read_body(Req, #{length => 16#1000000, period => 10000}) of
        {ok, Data, Req2} ->
            {ok, <<Acc/binary, Data/binary>>, Req2};
        {more, Data, Req2} ->
            read_body_full(Req2, <<Acc/binary, Data/binary>>);
        {error, Reason} ->
            {error, Reason}
    end.

%% ---------------------------------------------------------------------------
%% Serialisation
%% ---------------------------------------------------------------------------

%% Legacy entries were plain binaries in older configs; treat as label-only names.
dns_provider_entry_to_json(P) when is_binary(P) ->
    #{
        <<"name">> => P,
        <<"provider_type">> => <<"label">>,
        <<"credentials">> => #{}
    };
dns_provider_entry_to_json(P) when is_map(P) ->
    Name = maps:get(name, P),
    Pt = maps:get(provider_type, P, "label"),
    Cred = maps:get(credentials, P, #{}),
    #{
        <<"name">> => json_text(Name),
        <<"provider_type">> => json_text(Pt),
        <<"credentials">> => dns_cred_to_json(Cred)
    }.

dns_cred_to_json(M) when is_map(M) -> redact_sensitive_map(M);
dns_cred_to_json(_) -> #{}.

redact_sensitive_map(M) when is_map(M) ->
    maps:from_list([
        {K, redact_sensitive_value(K, V)} || {K, V} <- maps:to_list(M)
    ]);
redact_sensitive_map(V) ->
    V.

redact_sensitive_value(K, V) ->
    case is_sensitive_key(K) of
        true ->
            <<"[redacted]">>;
        false when is_map(V) ->
            redact_sensitive_map(V);
        false when is_list(V) ->
            [redact_sensitive_value(K, Item) || Item <- V];
        false ->
            V
    end.

is_sensitive_key(K) ->
    Key = normalize_key_bin(K),
    lists:any(
        fun(Pattern) ->
            binary:match(Key, Pattern) =/= nomatch
        end,
        [
            <<"token">>,
            <<"secret">>,
            <<"password">>,
            <<"private_key">>,
            <<"ssl_key">>,
            <<"api_key">>,
            <<"key_pem">>,
            <<"cert_pem">>
        ]
    ).

normalize_key_bin(K) when is_binary(K) ->
    string:lowercase(K);
normalize_key_bin(K) when is_list(K) ->
    string:lowercase(unicode:characters_to_binary(K, utf8));
normalize_key_bin(K) when is_atom(K) ->
    string:lowercase(atom_to_binary(K, utf8));
normalize_key_bin(K) ->
    string:lowercase(iolist_to_binary(io_lib:format("~p", [K]))).

config_to_json(Config) ->
    RuntimeMode =
        case pertisk_eproxy_config:ingress_mode() of
            true -> ingress;
            false -> proxy
        end,
    Base = #{
        mode            => mode_to_json(RuntimeMode),
        http_port       => maps:get(http_port, Config, 80),
        management_port => maps:get(management_port, Config, 9080),
        log_level       => iolist_to_binary(pertisk_eproxy_log_level:label(pertisk_eproxy_log_level:configured())),
        certificates    => [json_text(V) || V <- safe_list(maps:get(certificates, Config, []))],
        dns_providers   => safe_dns_providers_json(maps:get(dns_providers, Config, [])),
        sites           => safe_sites_json(maps:get(sites, Config, [])),
        backends        => safe_backends_json(maps:get(backends, Config, []))
    },
    WithHttps = case maps:get(https_port, Config, undefined) of
        undefined -> Base;
        P when is_integer(P) -> Base#{<<"https_port">> => P};
        _ -> Base
    end,
    WithQuic = case maps:get(quic_enabled, Config, undefined) of
        V when is_boolean(V) -> WithHttps#{<<"quic_enabled">> => V};
        _ -> WithHttps
    end,
    WithQuicPort = case maps:get(quic_port, Config, undefined) of
        Pq when is_integer(Pq) -> WithQuic#{<<"quic_port">> => Pq};
        _ -> WithQuic
    end,
    WithH3Gw = WithQuicPort#{
        <<"h3_api_gateway_enabled">> => maps:get(h3_api_gateway_enabled, Config, true),
        <<"h3_probe_enabled">> => maps:get(h3_probe_enabled, Config, true)
    },
    WithTlsH2 = case maps:get(tls_http2_enabled, Config, undefined) of
        Vh2 when is_boolean(Vh2) -> WithH3Gw#{<<"tls_http2_enabled">> => Vh2};
        _ -> WithH3Gw
    end,
    WithH3ProbePort = case maps:get(h3_probe_port, Config, undefined) of
        Pp when is_integer(Pp) -> WithTlsH2#{<<"h3_probe_port">> => Pp};
        _ -> WithTlsH2
    end,
    case {maps:get(tls_cert_file, Config, undefined), maps:get(tls_key_file, Config, undefined)} of
        {Cf, _Kf} when Cf =/= undefined ->
            WithH3ProbePort#{
                <<"tls_cert_file">> => json_text(Cf),
                <<"tls_key_file">> => <<"[redacted]">>
            };
        _ ->
            WithH3ProbePort
    end.

config_to_json_all(Config) ->
    Base = config_to_json(Config),
    IntKeys = [
        {<<"proxy_max_connections">>, proxy_max_connections},
        {<<"management_max_connections">>, management_max_connections},
        {<<"metrics_port">>, metrics_port},
        {<<"upstream_request_timeout_ms">>, upstream_request_timeout_ms},
        {<<"upstream_stream_request_timeout_ms">>, upstream_stream_request_timeout_ms},
        {<<"upstream_pool_size">>, upstream_pool_size},
        {<<"upstream_pool_idle_timeout_secs">>, upstream_pool_idle_timeout_secs},
        {<<"health_cache_refresh_ms">>, health_cache_refresh_ms},
        {<<"h3_idle_timeout_secs">>, h3_idle_timeout_secs},
        {<<"h3_keepalive_interval_secs">>, h3_keepalive_interval_secs},
        {<<"h3_quic_pool_size">>, h3_quic_pool_size},
        {<<"h3_max_udp_payload_size">>, h3_max_udp_payload_size},
        {<<"h3_max_streams">>, h3_max_streams},
        {<<"h3_stream_receive_window">>, h3_stream_receive_window},
        {<<"h3_conn_receive_window">>, h3_conn_receive_window},
        {<<"alt_svc_port">>, alt_svc_port},
        {<<"alt_svc_ma_secs">>, alt_svc_ma_secs}
    ],
    BoolKeys = [
        {<<"proxy_access_log">>, proxy_access_log},
        {<<"health_access_log">>, health_access_log},
        {<<"h3_pmtu_enabled">>, h3_pmtu_enabled},
        {<<"h3_qpack_static">>, h3_qpack_static},
        {<<"alt_svc_persist">>, alt_svc_persist},
        {<<"sse_early_flush_enabled">>, sse_early_flush_enabled},
        {<<"metrics_enabled">>, metrics_enabled}
    ],
    StrKeys = [
        {<<"http_addr">>, http_addr},
        {<<"management_addr">>, management_addr},
        {<<"metrics_addr">>, metrics_addr},
        {<<"h3_udp_bind">>, h3_udp_bind}
    ],
    Base1 = lists:foldl(fun maybe_put_int_key/2, Base, [{Config, JK, MK} || {JK, MK} <- IntKeys]),
    Base2 = lists:foldl(fun maybe_put_bool_key/2, Base1, [{Config, JK, MK} || {JK, MK} <- BoolKeys]),
    lists:foldl(fun maybe_put_str_key/2, Base2, [{Config, JK, MK} || {JK, MK} <- StrKeys]).

maybe_put_int_key({Config, JsonKey, MapKey}, Acc) ->
    case maps:get(MapKey, Config, undefined) of
        V when is_integer(V) -> Acc#{JsonKey => V};
        _ -> Acc
    end.

maybe_put_bool_key({Config, JsonKey, MapKey}, Acc) ->
    case maps:get(MapKey, Config, undefined) of
        V when is_boolean(V) -> Acc#{JsonKey => V};
        _ -> Acc
    end.

maybe_put_str_key({Config, JsonKey, MapKey}, Acc) ->
    case maps:get(MapKey, Config, undefined) of
        V when is_atom(V) -> Acc#{JsonKey => atom_to_binary(V, utf8)};
        V when is_binary(V) -> Acc#{JsonKey => V};
        V when is_list(V) -> Acc#{JsonKey => json_text(V)};
        V when is_tuple(V) -> Acc#{JsonKey => json_text(inet:ntoa(V))};
        _ -> Acc
    end.

should_show_all_config(Req) ->
    Qs = maps:from_list(cowboy_req:parse_qs(Req)),
    case maps:get(<<"show_all">>, Qs, <<>>) of
        <<"1">> -> true;
        <<"true">> -> true;
        <<"yes">> -> true;
        _ -> false
    end.

backup_config_to_json(Config) ->
    Base = # {
        mode            => mode_to_json(maps:get(mode, Config, proxy)),
        http_port       => maps:get(http_port, Config, 80),
        management_port => maps:get(management_port, Config, 9080),
        certificates    => [json_text(V) || V <- safe_list(maps:get(certificates, Config, []))],
        certificate_records => safe_list(maps:get(certificate_records, Config, [])),
        dns_providers   => backup_dns_providers_json(maps:get(dns_providers, Config, [])),
        sites           => safe_sites_json(maps:get(sites, Config, [])),
        backends        => safe_backends_json(maps:get(backends, Config, []))
    },
    WithHttps = case maps:get(https_port, Config, undefined) of
        undefined -> Base;
        P when is_integer(P) -> Base#{<<"https_port">> => P};
        _ -> Base
    end,
    WithQuic = case maps:get(quic_enabled, Config, undefined) of
        V when is_boolean(V) -> WithHttps#{<<"quic_enabled">> => V};
        _ -> WithHttps
    end,
    WithQuicPort = case maps:get(quic_port, Config, undefined) of
        Pq when is_integer(Pq) -> WithQuic#{<<"quic_port">> => Pq};
        _ -> WithQuic
    end,
    WithH3Gw = WithQuicPort#{
        <<"h3_api_gateway_enabled">> => maps:get(h3_api_gateway_enabled, Config, true),
        <<"h3_probe_enabled">> => maps:get(h3_probe_enabled, Config, true)
    },
    WithTlsH2 = case maps:get(tls_http2_enabled, Config, undefined) of
        Vh2 when is_boolean(Vh2) -> WithH3Gw#{<<"tls_http2_enabled">> => Vh2};
        _ -> WithH3Gw
    end,
    WithH3ProbePort = case maps:get(h3_probe_port, Config, undefined) of
        Pp when is_integer(Pp) -> WithTlsH2#{<<"h3_probe_port">> => Pp};
        _ -> WithTlsH2
    end,
    case {maps:get(tls_cert_file, Config, undefined), maps:get(tls_key_file, Config, undefined)} of
        {undefined, undefined} ->
            WithH3ProbePort;
        {Cf, Kf} ->
            WithH3ProbePort#{
                <<"tls_cert_file">> => json_text(Cf),
                <<"tls_key_file">> => json_text(Kf)
            }
    end.

backup_dns_providers_json(Providers) ->
    safe_json_rows(fun backup_dns_provider_entry_to_json/1, Providers).

backup_dns_provider_entry_to_json(P) when is_binary(P) ->
    #{
        <<"name">> => P,
        <<"provider_type">> => <<"label">>,
        <<"credentials">> => #{}
    };
backup_dns_provider_entry_to_json(P) when is_map(P) ->
    Name = maps:get(name, P),
    Pt = maps:get(provider_type, P, "label"),
    Cred = maps:get(credentials, P, #{}),
    #{
        <<"name">> => json_text(Name),
        <<"provider_type">> => json_text(Pt),
        <<"credentials">> => Cred
    }.

backup_export_config() ->
    Base = pertisk_eproxy_config:get_config(),
    DbPath = db_file_path(),
    Sites = backup_sites_from_db(DbPath),
    Backends = backup_backends_from_db(DbPath),
    DnsProviders = backup_dns_providers_from_db(DbPath),
    Certificates = backup_certificate_names(Base, Sites, DbPath),
    CertificateRecords = backup_certificate_records(DbPath),
    Base#{
        sites => Sites,
        backends => Backends,
        dns_providers => DnsProviders,
        certificates => Certificates,
        certificate_records => CertificateRecords
    }.

backup_sites_from_db(DbPath) ->
    case pertisk_eproxy_db:list_sites(DbPath) of
        {ok, Sites} -> Sites;
        {error, _} -> maps:get(sites, pertisk_eproxy_config:get_config(), [])
    end.

backup_backends_from_db(DbPath) ->
    case pertisk_eproxy_db:list_backends(DbPath) of
        {ok, Backends} -> Backends;
        {error, _} -> maps:get(backends, pertisk_eproxy_config:get_config(), [])
    end.

backup_dns_providers_from_db(DbPath) ->
    case pertisk_eproxy_db:list_dns_providers(DbPath) of
        {ok, Rows} ->
            [#{
                name => maps:get(name, R),
                provider_type => maps:get(provider_type, R),
                credentials => maps:get(credentials, R, #{})
            } || R <- Rows];
        {error, _} -> maps:get(dns_providers, pertisk_eproxy_config:get_config(), [])
    end.

backup_certificate_names(Base, Sites, DbPath) ->
    BaseCerts = maps:get(certificates, Base, []),
    SiteCerts = [maps:get(certificate, S) || S <- Sites, is_map(S), maps:is_key(certificate, S)],
    DbCerts = case pertisk_eproxy_db:list_certificates(DbPath) of
        {ok, Rows} -> [maps:get(name, Row) || Row <- Rows, maps:is_key(name, Row)];
        {error, _} -> []
    end,
    lists:usort([json_text(C) || C <- BaseCerts ++ SiteCerts ++ DbCerts, C =/= undefined, C =/= null]).

backup_certificate_records(DbPath) ->
    case pertisk_eproxy_db:list_certificates(DbPath) of
        {ok, Rows} -> safe_json_rows(fun backup_certificate_record_to_json/1, Rows);
        {error, _} -> []
    end.

backup_certificate_record_to_json(#{id := Id, name := Name} = Row) ->
    # {
        <<"id">> => integer_to_binary(Id),
        <<"name">> => json_text(Name),
        <<"cert_pem">> => backup_text_or_null(maps:get(cert_pem, Row, undefined)),
        <<"key_pem">> => backup_text_or_null(maps:get(key_pem, Row, undefined)),
        <<"source_type">> => json_text(maps:get(source_type, Row, <<"acme">>))
    }.

backup_text_or_null(undefined) -> null;
backup_text_or_null(null) -> null;
backup_text_or_null(V) -> json_text(V).

restore_backup_certificate_records(Json) when is_map(Json) ->
    case maps:get(<<"certificate_records">>, Json, undefined) of
        undefined -> ok;
        Recs when is_list(Recs) ->
            restore_backup_certificate_records_list(Recs);
        _ ->
            ok
    end;
restore_backup_certificate_records(_) ->
    ok.

restore_backup_certificate_records_list([]) ->
    ok;
restore_backup_certificate_records_list([R | Rest]) when is_map(R) ->
    case restore_backup_certificate_record(R) of
        ok -> restore_backup_certificate_records_list(Rest);
        {ok, _Id} -> restore_backup_certificate_records_list(Rest);
        {error, _} = Err -> Err
    end;
restore_backup_certificate_records_list([_ | Rest]) ->
    restore_backup_certificate_records_list(Rest).

restore_backup_certificate_record(#{<<"name">> := Name0} = Row) ->
    Name = json_text(Name0),
    CertPem = backup_restore_text(maps:get(<<"cert_pem">>, Row, undefined)),
    KeyPem = backup_restore_text(maps:get(<<"key_pem">>, Row, undefined)),
    SourceType = backup_restore_text(maps:get(<<"source_type">>, Row, <<"acme">>)),
    case Name of
        <<>> -> {error, empty_certificate_name};
        _ -> pertisk_eproxy_db:upsert_certificate_record(db_file_path(), Name, CertPem, KeyPem, SourceType)
    end;
restore_backup_certificate_record(_) ->
    ok.

backup_restore_text(undefined) -> <<>>;
backup_restore_text(null) -> <<>>;
backup_restore_text(V) -> json_text(V).

site_to_json(Site = #{host := Host, backend := Backend, routes := Routes}) ->
    Base = #{
        host    => json_text(Host),
        backend => json_text(Backend),
        routes  => [route_to_json(R) || R <- Routes]
    },
    WithCertificate = case maps:get(certificate, Site, undefined) of
        undefined -> Base;
        Certificate -> Base#{certificate => json_text(Certificate)}
    end,
    WithDns = case maps:get(dns_provider, Site, undefined) of
        undefined -> WithCertificate;
        DnsProvider -> WithCertificate#{dns_provider => json_text(DnsProvider)}
    end,
    WithChallenge = case maps:get(challenge_type, Site, undefined) of
        undefined -> WithDns;
        T -> WithDns#{challenge_type => json_text(T)}
    end,
    WithWildcard = case maps:get(wildcard, Site, undefined) of
        undefined -> WithChallenge;
        V when is_boolean(V) -> WithChallenge#{wildcard => V};
        _ -> WithChallenge
    end,
    WithHttp3 = case maps:get(advertise_http3, Site, undefined) of
        undefined -> WithWildcard;
        V2 when is_boolean(V2) -> WithWildcard#{advertise_http3 => V2};
        _ -> WithWildcard
    end,
    WithWildcardBase = case maps:get(acme_wildcard_base, Site, undefined) of
        undefined -> WithHttp3;
        WB -> WithHttp3#{acme_wildcard_base => json_text(WB)}
    end,
    WithEmail = case maps:get(acme_contact_email, Site, undefined) of
        undefined -> WithWildcardBase;
        E -> WithWildcardBase#{acme_contact_email => json_text(E)}
    end,
    WithIngressNs = case maps:get(ingress_namespace, Site, undefined) of
        undefined -> WithEmail;
        INs -> WithEmail#{ingress_namespace => json_text(INs)}
    end,
    case maps:get(ingress_name, Site, undefined) of
        undefined -> WithIngressNs;
        IName -> WithIngressNs#{ingress_name => json_text(IName)}
    end.

route_to_json(R) ->
    Base = #{
        path      => json_text(maps:get(path, R, <<"/">>)),
        path_type => atom_to_binary(maps:get(path_type, R, prefix), utf8)
    },
    case maps:get(rewrite, R, undefined) of
        undefined -> Base;
        Rw        -> Base#{rewrite => json_text(Rw)}
    end.

backend_to_json(B) ->
    Base = #{
        name      => json_text(maps:get(name, B)),
        algorithm => atom_to_binary(maps:get(algorithm, B, round_robin), utf8),
        upstreams => [#{addr => json_text(maps:get(addr, U)), weight => maps:get(weight, U, 1)}
                      || U <- maps:get(upstreams, B, [])],
        health_path => case maps:get(health_path, B, undefined) of
            undefined -> null;
            P -> json_text(P)
        end,
        health_interval_secs => maps:get(health_interval_secs, B, 30)
    },
    case maps:get(grpc_upstream, B, undefined) of
        true -> Base#{grpc_upstream => true};
        false -> Base#{grpc_upstream => false};
        _ -> Base
    end.

status_to_json(#{name := Name, algorithm := Algo, upstreams := Ups}) ->
    #{
        name      => json_text(Name),
        algorithm => atom_to_binary(Algo, utf8),
        upstreams => [#{addr    => json_text(maps:get(addr, U)),
                        healthy => maps:get(healthy, U, true),
                        conns   => maps:get(conns, U, 0),
                        weight  => maps:get(weight, U, 1)}
                      || U <- Ups]
    }.

%% ---------------------------------------------------------------------------
%% Parsing (for POST/PUT bodies)
%% ---------------------------------------------------------------------------

parse_site(Body) ->
    Routes = [#{
        path      => maps:get(<<"path">>, R, <<"/">>),
        path_type => parse_path_type(maps:get(<<"path_type">>, R, <<"prefix">>)),
        rewrite   => maps:get(<<"rewrite">>, R, undefined)
    } || R <- maps:get(<<"routes">>, Body, [])],
    #{
        host    => maps:get(<<"host">>, Body),
        backend => maps:get(<<"backend">>, Body),
        certificate => optional_string(maps:get(<<"certificate">>, Body, null)),
        dns_provider => optional_string(maps:get(<<"dns_provider">>, Body, null)),
        challenge_type => optional_challenge_type(maps:get(<<"challenge_type">>, Body, null)),
        wildcard => optional_bool(maps:get(<<"wildcard">>, Body, null)),
        acme_wildcard_base => optional_string(maps:get(<<"acme_wildcard_base">>, Body, null)),
        advertise_http3 => optional_bool(maps:get(<<"advertise_http3">>, Body, true)),
        acme_contact_email => optional_string(maps:get(<<"acme_contact_email">>, Body, null)),
        routes  => Routes
    }.

parse_backend(Body) ->
    Base = #{
        name      => maps:get(<<"name">>, Body),
        algorithm => parse_algorithm(maps:get(<<"algorithm">>, Body, <<"round_robin">>)),
        upstreams => [#{addr   => maps:get(<<"addr">>, U),
                        weight => maps:get(<<"weight">>, U, 1)}
                      || U <- maps:get(<<"upstreams">>, Body, [])],
        health_path          => maps:get(<<"health_path">>, Body, undefined),
        health_interval_secs => maps:get(<<"health_interval_secs">>, Body, 30)
    },
    case optional_bool(maps:get(<<"grpc_upstream">>, Body, null)) of
        undefined -> Base;
        V -> Base#{grpc_upstream => V}
    end.

parse_path_type(<<"exact">>)  -> exact;
parse_path_type(<<"prefix">>) -> prefix;
parse_path_type(_)            -> prefix.

parse_algorithm(<<"round_robin">>)       -> round_robin;
parse_algorithm(<<"least_connections">>) -> least_connections;
parse_algorithm(<<"ip_hash">>)           -> ip_hash;
parse_algorithm(_)                       -> round_robin.

optional_string(null) -> undefined;
optional_string(V) when is_binary(V) -> binary_to_list(V);
optional_string(_) -> undefined.

optional_bool(true) -> true;
optional_bool(false) -> false;
optional_bool(_) -> undefined.

optional_challenge_type(<<"http-01">>) -> "http-01";
optional_challenge_type(<<"dns-01">>) -> "dns-01";
optional_challenge_type("http-01") -> "http-01";
optional_challenge_type("dns-01") -> "dns-01";
optional_challenge_type(_) -> undefined.

json_text(V) when is_binary(V) -> V;
json_text(V) when is_list(V) -> list_to_binary(V);
json_text(V) -> V.

safe_list(V) when is_list(V) -> V;
safe_list(_) -> [].

mode_to_json(V) when is_atom(V) -> atom_to_binary(V, utf8);
mode_to_json(V) when is_binary(V) -> V;
mode_to_json(V) when is_list(V) -> list_to_binary(V);
mode_to_json(_) -> <<"proxy">>.

safe_sites_list(V) ->
    [S || S <- safe_list(V), is_map(S)].

safe_sites_json(Sites) ->
    safe_json_rows(fun site_to_json/1, Sites).

safe_backends_json(Backends) ->
    safe_json_rows(fun backend_to_json/1, Backends).

safe_dns_providers_json(Providers) ->
    safe_json_rows(fun dns_provider_entry_to_json/1, Providers).

safe_json_rows(Fun, Values) ->
    lists:reverse(
        lists:foldl(
            fun(V, Acc) ->
                case safe_json_row(Fun, V) of
                    {ok, Row} -> [Row | Acc];
                    skip -> Acc
                end
            end,
            [],
            safe_list(Values)
        )
    ).

safe_json_row(Fun, V) ->
    try
        {ok, Fun(V)}
    catch
        _:_ ->
            skip
    end.

preserve_redacted_tls_paths(Body, Parsed, Existing) when is_map(Body), is_map(Parsed), is_map(Existing) ->
    KeyIn = maps:get(<<"tls_key_file">>, Body, undefined),
    CertIn = maps:get(<<"tls_cert_file">>, Body, undefined),
    KeepKey = case KeyIn of
        <<"[redacted]">> -> true;
        "[redacted]" -> true;
        _ -> false
    end,
    KeepCert = case CertIn of
        <<"[redacted]">> -> true;
        "[redacted]" -> true;
        _ -> false
    end,
    Parsed1 = case KeepKey of
        true ->
            case maps:get(tls_key_file, Existing, undefined) of
                undefined -> Parsed;
                V -> Parsed#{tls_key_file => V}
            end;
        false -> Parsed
    end,
    case KeepCert of
        true ->
            case maps:get(tls_cert_file, Existing, undefined) of
                undefined -> Parsed1;
                V2 -> Parsed1#{tls_cert_file => V2}
            end;
        false -> Parsed1
    end.

preserve_redacted_dns_providers_in_config(Parsed, Existing) when is_map(Parsed), is_map(Existing) ->
    ParsedProviders = maps:get(dns_providers, Parsed, []),
    ExistingProviders = maps:get(dns_providers, Existing, []),
    NewProviders = [
        preserve_redacted_dns_provider_entry(P, ExistingProviders)
     || P <- ParsedProviders
    ],
    Parsed#{dns_providers => NewProviders};
preserve_redacted_dns_providers_in_config(Parsed, _Existing) ->
    Parsed.

preserve_redacted_dns_provider_entry(P, ExistingProviders) when is_map(P) ->
    Name = provider_name(P),
    OldCreds = find_dns_provider_creds(Name, ExistingProviders),
    CredIn = provider_creds(P),
    MergedCreds = merge_dns_credentials_for_update(CredIn, OldCreds),
    set_provider_creds(P, MergedCreds);
preserve_redacted_dns_provider_entry(P, _ExistingProviders) ->
    P.

provider_name(P) when is_map(P) ->
    case maps:get(name, P, maps:get(<<"name">>, P, <<>>)) of
        V when is_binary(V) -> V;
        V when is_list(V) -> unicode:characters_to_binary(V, utf8);
        _ -> <<>>
    end.

provider_creds(P) when is_map(P) ->
    case maps:get(credentials, P, maps:get(<<"credentials">>, P, #{})) of
        M when is_map(M) -> M;
        _ -> #{}
    end.

set_provider_creds(P, Creds) when is_map(P), is_map(Creds) ->
    case maps:is_key(credentials, P) of
        true -> P#{credentials => Creds};
        false ->
            case maps:is_key(<<"credentials">>, P) of
                true -> P#{<<"credentials">> => Creds};
                false -> P#{credentials => Creds}
            end
    end.

find_dns_provider_creds(_Name, []) ->
    #{};
find_dns_provider_creds(Name, [P | Rest]) ->
    case provider_name(P) =:= Name of
        true -> provider_creds(P);
        false -> find_dns_provider_creds(Name, Rest)
    end.

merge_dns_credentials_for_update(NewCreds, OldCreds) when is_map(NewCreds), is_map(OldCreds) ->
    maps:fold(
        fun(K, V, Acc) when is_map(V) ->
            OldChild =
                case maps:get(K, OldCreds, undefined) of
                    M when is_map(M) -> M;
                    _ -> #{}
                end,
            maps:put(K, merge_dns_credentials_for_update(V, OldChild), Acc);
        (K, V, Acc) ->
            case is_redacted_dns_value(V) of
                true ->
                    case maps:find(K, OldCreds) of
                        {ok, OldV} -> maps:put(K, OldV, Acc);
                        error -> maps:remove(K, Acc)
                    end;
                false ->
                    maps:put(K, V, Acc)
            end
        end,
        OldCreds,
        NewCreds
    );
merge_dns_credentials_for_update(NewCreds, _OldCreds) ->
    NewCreds.

dns_credentials_has_redacted(M) when is_map(M) ->
    lists:any(
        fun({_K, V}) ->
            case V of
                VM when is_map(VM) -> dns_credentials_has_redacted(VM);
                _ -> is_redacted_dns_value(V)
            end
        end,
        maps:to_list(M)
    );
dns_credentials_has_redacted(_) ->
    false.

is_redacted_dns_value(V) when is_binary(V) ->
    string:lowercase(V) =:= <<"[redacted]">>;
is_redacted_dns_value(V) when is_list(V) ->
    string:lowercase(unicode:characters_to_binary(V, utf8)) =:= <<"[redacted]">>;
is_redacted_dns_value(_) ->
    false.

find_site_by_host(HostParam, Sites) ->
    case lists:search(fun(#{host := H}) -> H =:= HostParam end, Sites) of
        {value, Site} -> Site;
        false -> #{}
    end.

%% Keep current TLS/ACME site fields only when they are omitted in PUT /api/sites/:host.
%% Explicit null means caller intentionally clears the value.
preserve_site_tls_fields(Body, Parsed, Existing)
    when is_map(Body), is_map(Parsed), is_map(Existing) ->
    lists:foldl(
        fun({JsonKey, SiteKey}, Acc) ->
            case should_preserve_site_tls_key(Body, JsonKey) of
                true ->
                    case maps:get(SiteKey, Existing, undefined) of
                        undefined -> Acc;
                        V -> Acc#{SiteKey => V}
                    end;
                false ->
                    Acc
            end
        end,
        Parsed,
        [
            {<<"certificate">>, certificate},
            {<<"dns_provider">>, dns_provider},
            {<<"challenge_type">>, challenge_type},
            {<<"wildcard">>, wildcard},
            {<<"acme_wildcard_base">>, acme_wildcard_base},
            {<<"acme_contact_email">>, acme_contact_email}
        ]
    ).

should_preserve_site_tls_key(Body, JsonKey) when is_map(Body), is_binary(JsonKey) ->
    maps:is_key(JsonKey, Body) =:= false.

proto_snapshot(Req) ->
    Version = normalize_http_version(cowboy_req:version(Req)),
    Scheme = normalize_scheme(cowboy_req:scheme(Req)),
    Host = cowboy_req:host(Req),
    Port = cowboy_req:port(Req),
    {PeerIp, PeerPort} = cowboy_req:peer(Req),
    Xfp = cowboy_req:header(<<"x-forwarded-proto">>, Req, <<>>),
    Xff = cowboy_req:header(<<"x-forwarded-for">>, Req, <<>>),
    Xfpv = cowboy_req:header(<<"x-forwarded-proto-version">>, Req, <<>>),
    Xfh = cowboy_req:header(<<"x-forwarded-host">>, Req, <<>>),
    Forwarded = cowboy_req:header(<<"forwarded">>, Req, <<>>),
    CfVisitor = cowboy_req:header(<<"cf-visitor">>, Req, <<>>),
    CfRay = cowboy_req:header(<<"cf-ray">>, Req, <<>>),
    Via = cowboy_req:header(<<"via">>, Req, <<>>),
    Ua = cowboy_req:header(<<"user-agent">>, Req, <<>>),
    SecChUa = cowboy_req:header(<<"sec-ch-ua">>, Req, <<>>),
    SecChUaPlatform = cowboy_req:header(<<"sec-ch-ua-platform">>, Req, <<>>),
    SecChUaMobile = cowboy_req:header(<<"sec-ch-ua-mobile">>, Req, <<>>),
    Snapshot0 = #{
        <<"http_version">> => Version,
        <<"scheme">> => Scheme,
        <<"host">> => host_metric_bin(Host),
        <<"port">> => Port,
        <<"peer_ip">> => iolist_to_binary(inet:ntoa(PeerIp)),
        <<"peer_port">> => PeerPort,
        <<"x_forwarded_proto">> => Xfp,
        <<"x_forwarded_for">> => Xff,
        <<"x_forwarded_proto_version">> => Xfpv,
        <<"x_forwarded_host">> => Xfh,
        <<"forwarded">> => Forwarded,
        <<"cf_visitor">> => CfVisitor,
        <<"cf_ray">> => CfRay,
        <<"via">> => Via,
        <<"user_agent">> => Ua,
        <<"sec_ch_ua">> => SecChUa,
        <<"sec_ch_ua_platform">> => SecChUaPlatform,
        <<"sec_ch_ua_mobile">> => SecChUaMobile
    },
    EffectiveClientProtoVersion =
        case Xfpv of
            <<>> -> Version;
            _ -> Xfpv
        end,
    Snapshot0#{
        <<"effective_client_proto_version">> => EffectiveClientProtoVersion,
        <<"client_h3">> => is_http3(EffectiveClientProtoVersion)
    }.

normalize_http_version(V) when is_atom(V) -> atom_to_binary(V, utf8);
normalize_http_version(V) when is_binary(V) -> V;
normalize_http_version(V) -> iolist_to_binary(io_lib:format("~p", [V])).

normalize_scheme(S) when is_binary(S) -> S;
normalize_scheme(S) when is_atom(S) -> atom_to_binary(S, utf8);
normalize_scheme(S) -> iolist_to_binary(io_lib:format("~p", [S])).

is_http3(<<"HTTP/3">>) -> true;
is_http3(<<"h3">>) -> true;
is_http3(<<"h3-29">>) -> true;
is_http3(_) -> false.

bool_to_header(true) -> <<"true">>;
bool_to_header(false) -> <<"false">>.

proto_debug_headers(Snapshot) ->
    ClientH3 = maps:get(<<"client_h3">>, Snapshot, false),
    #{
        <<"cache-control">> => <<"no-store">>,
        <<"x-eproxy-debug-http-version">> => maps:get(<<"http_version">>, Snapshot, <<>>),
        <<"x-eproxy-debug-scheme">> => maps:get(<<"scheme">>, Snapshot, <<>>),
        <<"x-eproxy-debug-client-h3">> => bool_to_header(ClientH3),
        <<"x-eproxy-debug-xfp">> => maps:get(<<"x_forwarded_proto">>, Snapshot, <<>>),
        <<"x-eproxy-debug-xfp-version">> => maps:get(<<"x_forwarded_proto_version">>, Snapshot, <<>>),
        <<"x-eproxy-debug-via">> => maps:get(<<"via">>, Snapshot, <<>>),
        <<"x-eproxy-debug-cf-ray">> => maps:get(<<"cf_ray">>, Snapshot, <<>>)
    }.

%% ---------------------------------------------------------------------------
%% Misc
%% ---------------------------------------------------------------------------

db_file_path() ->
    case application:get_env(pertisk_eproxy, db_file) of
        {ok, F} when is_list(F) -> F;
        {ok, F} when is_binary(F) -> binary_to_list(F);
        _ -> "data/proxy.db"
    end.

parse_int_param(Bin) when is_binary(Bin) ->
    try
        {ok, binary_to_integer(Bin)}
    catch
        _:_ -> {error, bad_id}
    end;
parse_int_param(_) ->
    {error, bad_id}.

effective_cert_pem(CertRow) ->
    Pem0 = maps:get(cert_pem, CertRow, undefined),
    case normalize_cert_pem_value(Pem0) of
        undefined ->
            undefined;
        V ->
            iolist_to_binary(V)
    end.

normalize_cert_pem_value(undefined) -> undefined;
normalize_cert_pem_value(null) -> undefined;
normalize_cert_pem_value(<<"">>) -> undefined;
normalize_cert_pem_value([]) -> undefined;
normalize_cert_pem_value(V) -> V.

certificate_row_json(#{id := Id, name := Name} = CertRow, Sites) ->
    IdBin = integer_to_binary(Id),
    NameBin = json_text(Name),
    Source0 = maps:get(source_type, CertRow, <<"acme">>),
    Source = json_text(Source0),
    CertPem = effective_cert_pem(CertRow),
    case {Source, CertPem =/= undefined} of
        {<<"imported_pem">>, true} ->
            stored_pem_cert_row_json(IdBin, NameBin, CertPem, Sites, <<"imported_pem">>, <<"imported PEM">>);
        {_, true} ->
            Chal =
                case Source of
                    <<"acme">> -> acme_dns_challenge_label();
                    _ -> <<"PEM">>
                end,
            stored_pem_cert_row_json(IdBin, NameBin, CertPem, Sites, Source, Chal);
        _ ->
            #{
                <<"id">> => IdBin,
                <<"domain">> => NameBin,
                <<"hosts">> => [NameBin],
                <<"issuer">> => <<>>,
                <<"challenge">> =>
                    case Source of
                        <<"acme">> -> acme_dns_challenge_label();
                        _ -> Source
                    end,
                <<"source_type">> => Source,
                <<"created_at">> => <<>>,
                <<"expires_at">> => <<>>,
                <<"next_renew">> => <<>>,
                <<"sites">> => sites_for_cert(Sites, IdBin, NameBin)
            }
    end.

certificate_rows_json(Certs, Sites) ->
    lists:reverse(
        lists:foldl(
            fun(C, Acc) ->
                case certificate_row_json_safe(C, Sites) of
                    {ok, Row} -> [Row | Acc];
                    skip -> Acc
                end
            end,
            [],
            safe_list(Certs)
        )
    ).

certificate_row_json_safe(#{id := _, name := _} = CertRow, Sites) ->
    try
        {ok, certificate_row_json(CertRow, Sites)}
    catch
        _:_ ->
            skip
    end;
certificate_row_json_safe(_, _) ->
    skip.

%% Challenge column text for ACME rows; includes staging hint when directory URL is LE staging.
acme_dns_challenge_label() ->
    case application:get_env(pertisk_eproxy, acme_directory_url) of
        {ok, Url} when is_list(Url); is_binary(Url) ->
            Str = case Url of
                B when is_binary(B) -> binary_to_list(B);
                L when is_list(L) -> L
            end,
            case string:find(string:lowercase(Str), "staging") of
                nomatch -> <<"dns-01">>;
                _ -> <<"dns-01 (Let's Encrypt staging)">>
            end;
        _ ->
            <<"dns-01">>
    end.

stored_pem_cert_row_json(IdBin, NameBin, CertPem, Sites, SourceTypeBin, ChallengeBin) ->
    case pertisk_eproxy_tls_cert_info:describe_pem_data(CertPem) of
        {ok, #{hosts := Hosts, not_before := NB, not_after := NA, issuer := Issuer}} ->
            Domain = case Hosts of
                [H | _] -> H;
                _ -> NameBin
            end,
            #{
                <<"id">> => IdBin,
                <<"domain">> => Domain,
                <<"hosts">> => Hosts,
                <<"issuer">> => Issuer,
                <<"challenge">> => ChallengeBin,
                <<"source_type">> => SourceTypeBin,
                <<"created_at">> => NB,
                <<"expires_at">> => NA,
                <<"next_renew">> => <<>>,
                <<"sites">> => sites_for_cert(Sites, IdBin, NameBin)
            };
        _ ->
            #{
                <<"id">> => IdBin,
                <<"domain">> => NameBin,
                <<"hosts">> => [NameBin],
                <<"issuer">> => <<>>,
                <<"challenge">> => ChallengeBin,
                <<"source_type">> => SourceTypeBin,
                <<"created_at">> => <<>>,
                <<"expires_at">> => <<>>,
                <<"next_renew">> => <<>>,
                <<"sites">> => sites_for_cert(Sites, IdBin, NameBin)
            }
    end.

sites_for_cert(Sites, IdBin, NameBin) ->
    [json_text(maps:get(host, S)) || S <- Sites, cert_ref_matches(maps:get(certificate, S, undefined), IdBin, NameBin)].

cert_ref_matches(CertRef, IdBin, NameBin) ->
    cert_field_matches(CertRef, IdBin) orelse
        case is_numeric_bin(NameBin) of
            true -> false;
            false -> cert_field_matches(CertRef, NameBin)
        end.

cert_field_matches(undefined, _) -> false;
cert_field_matches(null, _) -> false;
cert_field_matches(C, N) when is_binary(C), is_binary(N) -> C =:= N;
cert_field_matches(C, N) when is_list(C), is_binary(N) -> iolist_to_binary(C) =:= N;
cert_field_matches(C, N) when is_list(C), is_list(N) -> C =:= N;
cert_field_matches(C, N) when is_binary(C), is_list(N) -> C =:= iolist_to_binary(N);
cert_field_matches(_, _) -> false.

site_tls_health_rows(Sites) ->
    Rows = all_certificate_rows_for_tls_health(Sites),
    [
        site_tls_health_row(S, Rows)
        || S <- safe_list(Sites),
           is_map(S),
           site_health_host_bin(site_map_get(S, host)) =/= undefined
    ].

all_certificate_rows_for_tls_health(Sites) ->
    IngressRows = ingress_certificate_rows(Sites),
    DbRows =
        case pertisk_eproxy_db:list_certificates(db_file_path()) of
            {ok, Certs} -> certificate_rows_json(Certs, Sites);
            _ -> []
        end,
    merge_certificate_rows(DbRows, IngressRows).

site_tls_health_row(Site, CertRows) ->
    Host = site_health_host_bin(site_map_get(Site, host)),
    CertRef = site_health_cert_ref_bin(site_map_get(Site, certificate)),
    Base = #
    {
        <<"host">> => json_text(Host),
        <<"certificate">> => cert_ref_json(CertRef),
        <<"certificate_id">> => null
    },
    case CertRef of
        undefined ->
            maps:merge(Base, #
            {
                <<"valid">> => false,
                <<"status">> => <<"none">>,
                <<"reason">> => <<"no_certificate_assigned">>,
                <<"presented_hosts">> => []
            });
        _ ->
            case find_certificate_row_for_ref(CertRef, CertRows) of
                {ok, Row} ->
                    BaseWithId = Base#{<<"certificate_id">> => cert_row_id_json(Row)},
                    Hosts = cert_hosts_from_row(Row),
                    case Hosts of
                        [] ->
                            case is_acme_cert_ref(CertRef) of
                                true ->
                                    maps:merge(BaseWithId, #
                                    {
                                        <<"valid">> => false,
                                        <<"status">> => <<"mismatch">>,
                                        <<"reason">> => <<"certificate_not_found">>,
                                        <<"presented_hosts">> => []
                                    });
                                false ->
                                    maps:merge(BaseWithId, #
                                    {
                                        <<"valid">> => false,
                                        <<"status">> => <<"unknown">>,
                                        <<"reason">> => <<"certificate_hosts_unavailable">>,
                                        <<"presented_hosts">> => []
                                    })
                            end;
                        _ ->
                            case cert_hosts_cover_site_host(Host, Hosts) of
                                true ->
                                    maps:merge(BaseWithId, #
                                    {
                                        <<"valid">> => true,
                                        <<"status">> => <<"ok">>,
                                        <<"reason">> => <<"host_covered">>,
                                        <<"presented_hosts">> => Hosts
                                    });
                                false ->
                                    maps:merge(BaseWithId, #
                                    {
                                        <<"valid">> => false,
                                        <<"status">> => <<"mismatch">>,
                                        <<"reason">> => <<"certificate_host_mismatch">>,
                                        <<"presented_hosts">> => Hosts
                                    })
                            end
                    end;
                error ->
                    case is_acme_cert_ref(CertRef) of
                        true ->
                            AcmeHosts = acme_cert_hosts_for_ref(CertRef),
                            case AcmeHosts of
                                [] ->
                                    maps:merge(Base, #
                                    {
                                        <<"valid">> => false,
                                        <<"status">> => <<"mismatch">>,
                                        <<"reason">> => <<"certificate_not_found">>,
                                        <<"presented_hosts">> => []
                                    });
                                _ ->
                                    case cert_hosts_cover_site_host(Host, AcmeHosts) of
                                        true ->
                                            maps:merge(Base, #
                                            {
                                                <<"valid">> => true,
                                                <<"status">> => <<"ok">>,
                                                <<"reason">> => <<"host_covered">>,
                                                <<"presented_hosts">> => AcmeHosts
                                            });
                                        false ->
                                            maps:merge(Base, #
                                            {
                                                <<"valid">> => false,
                                                <<"status">> => <<"mismatch">>,
                                                <<"reason">> => <<"certificate_host_mismatch">>,
                                                <<"presented_hosts">> => AcmeHosts
                                            })
                                    end
                            end;
                        false ->
                            maps:merge(Base, #
                            {
                                <<"valid">> => false,
                                <<"status">> => <<"unknown">>,
                                <<"reason">> => <<"certificate_not_found">>,
                                <<"presented_hosts">> => []
                            })
                    end
            end
    end.

cert_ref_json(undefined) -> null;
cert_ref_json(V) -> json_text(V).

cert_row_id_json(Row) when is_map(Row) ->
    case maps:get(<<"id">>, Row, null) of
        <<>> -> null;
        V -> V
    end;
cert_row_id_json(_) ->
    null.

site_map_get(Site, Key) when is_map(Site), is_atom(Key) ->
    case maps:get(Key, Site, undefined) of
        undefined ->
            BinKey = atom_to_binary(Key, utf8),
            maps:get(BinKey, Site, undefined);
        V ->
            V
    end;
site_map_get(_, _) ->
    undefined.

site_health_host_bin(undefined) -> undefined;
site_health_host_bin(null) -> undefined;
site_health_host_bin(B) when is_binary(B), B =/= <<>> -> B;
site_health_host_bin(L) when is_list(L), L =/= [] -> unicode:characters_to_binary(L, utf8);
site_health_host_bin(_) -> undefined.

site_health_cert_ref_bin(undefined) -> undefined;
site_health_cert_ref_bin(null) -> undefined;
site_health_cert_ref_bin(B) when is_binary(B), B =/= <<>> -> B;
site_health_cert_ref_bin(L) when is_list(L), L =/= [] -> unicode:characters_to_binary(L, utf8);
site_health_cert_ref_bin(I) when is_integer(I) -> integer_to_binary(I);
site_health_cert_ref_bin(_) -> undefined.

is_acme_cert_ref(<<"acme/", _/binary>>) -> true;
is_acme_cert_ref(_) -> false.

acme_cert_hosts_for_ref(<<"acme/", Slug/binary>>) ->
    Path = filename:join([acme_health_data_dir(), "certs", binary_to_list(Slug), "fullchain.pem"]),
    case pertisk_eproxy_tls_cert_info:describe_listener_pem(Path) of
        {ok, #{hosts := Hosts}} when is_list(Hosts) ->
            [
                json_text(H)
                || H <- Hosts,
                   is_binary(json_text(H)),
                   json_text(H) =/= <<>>
            ];
        _ ->
            acme_db_cert_hosts_for_ref(<<"acme/", Slug/binary>>)
    end;
acme_cert_hosts_for_ref(_) ->
    [].

acme_db_cert_hosts_for_ref(NameRef) when is_binary(NameRef) ->
    case pertisk_eproxy_db:list_certificates(db_file_path()) of
        {ok, Rows} ->
            case lists:search(
                fun(Row) ->
                    Ref = site_health_cert_ref_bin(maps:get(name, Row, undefined)),
                    Ref =:= NameRef
                end,
                Rows
            ) of
                {value, Row} ->
                    acme_db_hosts_from_row(Row);
                false ->
                    []
            end;
        _ ->
            []
    end;
acme_db_cert_hosts_for_ref(_) ->
    [].

acme_db_hosts_from_row(Row) when is_map(Row) ->
    Pem = site_health_cert_ref_bin(maps:get(cert_pem, Row, undefined)),
    case Pem of
        undefined ->
            [];
        PemBin ->
            case pertisk_eproxy_tls_cert_info:describe_pem_data(PemBin) of
                {ok, #{hosts := Hosts}} when is_list(Hosts) ->
                    [
                        json_text(H)
                        || H <- Hosts,
                           is_binary(json_text(H)),
                           json_text(H) =/= <<>>
                    ];
                _ ->
                    []
            end
    end;
acme_db_hosts_from_row(_) ->
    [].

acme_health_data_dir() ->
    case application:get_env(pertisk_eproxy, acme_data_dir) of
        {ok, D} when is_list(D), D =/= [] -> D;
        {ok, D} when is_binary(D), D =/= <<>> -> binary_to_list(D);
        _ -> "data/acme"
    end.

find_certificate_row_for_ref(CertRef, CertRows) ->
    case lists:search(
        fun(Row) ->
            Id = maps:get(<<"id">>, Row, <<>>),
            Domain = maps:get(<<"domain">>, Row, <<>>),
            cert_field_matches(CertRef, Id) orelse cert_field_matches(CertRef, Domain)
        end,
        CertRows
    ) of
        {value, Row} -> {ok, Row};
        false -> error
    end.

cert_hosts_from_row(Row) when is_map(Row) ->
    [
        json_text(H)
        || H <- safe_list(maps:get(<<"hosts">>, Row, [])),
           is_binary(json_text(H)),
           json_text(H) =/= <<>>
    ];
cert_hosts_from_row(_) ->
    [].

cert_hosts_cover_site_host(Host, Hosts) when is_binary(Host), is_list(Hosts) ->
    CheckHost = cert_check_host_for_health(Host),
    lists:any(fun(Pattern) -> cert_pattern_matches_host(CheckHost, Pattern) end, Hosts);
cert_hosts_cover_site_host(_, _) ->
    false.

cert_check_host_for_health(<<"*.", Rest/binary>>) when Rest =/= <<>> ->
    <<"probe.", Rest/binary>>;
cert_check_host_for_health(Host) ->
    Host.

cert_pattern_matches_host(Host0, Pattern0) when is_binary(Host0), is_binary(Pattern0) ->
    Host = string:lowercase(Host0),
    Pattern = string:lowercase(Pattern0),
    case Host =:= Pattern of
        true ->
            true;
        false ->
            case Pattern of
                <<"*.", Suffix/binary>> when Suffix =/= <<>> ->
                    wildcard_suffix_matches_host(Host, Suffix);
                _ ->
                    false
            end
    end;
cert_pattern_matches_host(_, _) ->
    false.

wildcard_suffix_matches_host(Host, Suffix) when is_binary(Host), is_binary(Suffix) ->
    HostParts = binary:split(Host, <<".">>, [global]),
    SuffixParts = binary:split(Suffix, <<".">>, [global]),
    case length(HostParts) =:= (length(SuffixParts) + 1) of
        false ->
            false;
        true ->
            lists:nthtail(1, HostParts) =:= SuffixParts
    end;
wildcard_suffix_matches_host(_, _) ->
    false.

is_numeric_bin(Bin) when is_binary(Bin), Bin =/= <<>> ->
    lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary:bin_to_list(Bin));
is_numeric_bin(_) ->
    false.

certificate_name_by_id(Id) ->
    case pertisk_eproxy_db:list_certificates(db_file_path()) of
        {ok, Certs} ->
            case lists:search(fun(#{id := RowId}) -> cert_id_equals(RowId, Id) end, Certs) of
                {value, #{name := Name}} -> {ok, json_text(Name)};
                false -> {error, not_found}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

certificate_in_use(Name) ->
    sites_for_certificate(Name) =/= [].

sites_for_certificate(Name) ->
    NameBin = json_text(Name),
    IdBin =
        case certificate_id_by_name(NameBin) of
            {ok, I} -> integer_to_binary(I);
            _ -> <<>>
        end,
    Sites = pertisk_eproxy_config:get_sites(),
    [maps:get(host, S) || S <- Sites, site_uses_certificate(S, NameBin, IdBin)].

site_uses_certificate(S, NameBin, IdBin) ->
    Ref = maps:get(certificate, S, undefined),
    cert_field_matches(Ref, NameBin)
        orelse (IdBin =/= <<>> andalso cert_field_matches(Ref, IdBin)).

ingress_api_token_supported() ->
    pertisk_eproxy_config:ingress_mode() andalso pertisk_eproxy_env_auth:supports_local().

certificate_id_by_name(NameBin) ->
    case pertisk_eproxy_db:list_certificates(db_file_path()) of
        {ok, Certs} ->
            case lists:search(fun(#{name := N}) -> json_text(N) =:= NameBin end, Certs) of
                {value, #{id := Id}} -> {ok, cert_id_to_int(Id)};
                false -> {error, not_found}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

cert_id_equals(RowId, Id) when is_integer(Id) ->
    cert_id_to_int(RowId) =:= Id;
cert_id_equals(RowId, Id) ->
    cert_id_to_int(RowId) =:= cert_id_to_int(Id).

cert_id_to_int(I) when is_integer(I) ->
    I;
cert_id_to_int(B) when is_binary(B), B =/= <<>> ->
    try binary_to_integer(B) catch _:_ -> -1 end;
cert_id_to_int(L) when is_list(L), L =/= [] ->
    try list_to_integer(L) catch _:_ -> -1 end;
cert_id_to_int(_) ->
    -1.

imported_cert_name(CertPath0) ->
    CertPath =
        case CertPath0 of
            B when is_binary(B) -> binary_to_list(B);
            L when is_list(L) -> L;
            _ -> ""
        end,
    case pertisk_eproxy_tls_cert_info:describe_listener_pem(CertPath) of
        {ok, #{hosts := [H | _]}} ->
            json_text(H);
        _ ->
            iolist_to_binary(io_lib:format("imported-~B", [erlang:system_time(second)]))
    end.

insert_imported_certificate(Name, CertPath, KeyPath) ->
    case pertisk_eproxy_db:insert_certificate_pem(db_file_path(), Name, CertPath, KeyPath) of
        {error, {sqlite_error, Msg}} ->
            case string:str(Msg, "UNIQUE constraint failed: certificates.name") of
                0 ->
                    {error, {sqlite_error, Msg}};
                _ ->
                    Name2 = <<(json_text(Name))/binary, "-", (integer_to_binary(erlang:system_time(second)))/binary>>,
                    pertisk_eproxy_db:insert_certificate_pem(db_file_path(), Name2, CertPath, KeyPath)
            end;
        Other ->
            Other
    end.

update_sites_cert_name(PrevName, NextName0) ->
    NextName = json_text(NextName0),
    C0 = pertisk_eproxy_config:get_config(),
    Sites0 = maps:get(sites, C0, []),
    Sites = [
        case cert_field_matches(maps:get(certificate, S, undefined), PrevName) of
            true -> S#{certificate => binary_to_list(NextName)};
            false -> S
        end
        || S <- Sites0
    ],
    _ = pertisk_eproxy_config:put_config(C0#{sites => Sites}),
    ok.

parse_dns_credentials(M) when is_map(M) -> normalize_dns_credentials(M);
parse_dns_credentials(_) -> #{}.

normalize_dns_credentials(M) when is_map(M) ->
    maps:fold(
        fun(K, V, Acc) ->
            NK = normalize_cred_key(K),
            NV = normalize_dns_cred_value(V),
            maps:put(NK, NV, Acc)
        end,
        #{},
        M
    );
normalize_dns_credentials(_) ->
    #{}.

normalize_dns_cred_value(V) when is_map(V) ->
    normalize_dns_credentials(V);
normalize_dns_cred_value(V) when is_list(V) ->
    [normalize_dns_cred_value(Item) || Item <- V];
normalize_dns_cred_value(V) ->
    V.

normalize_cred_key(K) when is_binary(K) ->
    K;
normalize_cred_key(K) when is_list(K) ->
    unicode:characters_to_binary(K, utf8);
normalize_cred_key(K) when is_atom(K) ->
    atom_to_binary(K, utf8);
normalize_cred_key(K) ->
    iolist_to_binary(io_lib:format("~p", [K])).

dns_provider_db_row_to_json(#{id := Id, name := Name, provider_type := Pt, credentials := Cred} = Row) ->
    #{
        <<"id">> => integer_to_binary(Id),
        <<"name">> => json_text(Name),
        <<"provider_type">> => json_text(Pt),
        <<"credentials">> => dns_cred_to_json(Cred),
        <<"created_at">> => json_text(maps:get(created_at, Row, <<>>))
    }.

dns_provider_name_by_id(Id) ->
    case pertisk_eproxy_db:get_dns_provider_by_id(db_file_path(), Id) of
        {ok, #{name := Name}} ->
            {ok, json_text(Name)};
        {error, Reason} ->
            {error, Reason}
    end.

dns_provider_in_use(Name) ->
    Sites = pertisk_eproxy_config:get_sites(),
    lists:any(fun(S) -> cert_field_matches(maps:get(dns_provider, S, undefined), Name) end, Sites).

update_sites_dns_provider_name(PrevName, NextName0) ->
    NextName = json_text(NextName0),
    C0 = pertisk_eproxy_config:get_config(),
    Sites0 = maps:get(sites, C0, []),
    Sites = [
        case cert_field_matches(maps:get(dns_provider, S, undefined), PrevName) of
            true -> S#{dns_provider => binary_to_list(NextName)};
            false -> S
        end
        || S <- Sites0
    ],
    _ = pertisk_eproxy_config:put_config(C0#{sites => Sites}),
    ok.

sync_dns_providers_into_runtime_config() ->
    case pertisk_eproxy_db:list_dns_providers(db_file_path()) of
        {ok, Rows} ->
            ExistingProviders = maps:get(dns_providers, pertisk_eproxy_config:get_config(), []),
            DnsProviders = [
                preserve_redacted_dns_provider_entry(
                    #{
                        name => binary_to_list(json_text(maps:get(name, R))),
                        provider_type => binary_to_list(json_text(maps:get(provider_type, R))),
                        credentials => maps:get(credentials, R, #{})
                    },
                    ExistingProviders
                )
                || R <- Rows
            ],
            C0 = pertisk_eproxy_config:get_config(),
            _ = pertisk_eproxy_config:put_config(C0#{dns_providers => DnsProviders}),
            ok;
        {error, _} ->
            ok
    end.

merge_certificate_rows(DbRows, IngressRows) ->
    {_, Acc} = lists:foldl(
        fun(Row, {Seen, Rows}) ->
            Id = maps:get(<<"id">>, Row, <<>>),
            case maps:is_key(Id, Seen) of
                true ->
                    {Seen, Rows};
                false ->
                    {maps:put(Id, true, Seen), [Row | Rows]}
            end
        end,
        {#{}, []},
        DbRows ++ IngressRows
    ),
    lists:reverse(Acc).

ingress_certificate_rows(Sites) ->
    case pertisk_eproxy_config:ingress_mode() of
        false ->
            [];
        true ->
            Groups = ingress_cert_groups(Sites),
            lists:sort(
                fun(A, B) -> maps:get(<<"id">>, A, <<>>) =< maps:get(<<"id">>, B, <<>>) end,
                maps:fold(
                    fun(CertRef, Hosts, Acc) ->
                        [ingress_cert_row_json(CertRef, Hosts, Sites) | Acc]
                    end,
                    [],
                    Groups
                )
            )
    end.

ingress_cert_groups(Sites) ->
    lists:foldl(
        fun(Site, Acc) ->
            Ref0 = maps:get(certificate, Site, undefined),
            Host0 = maps:get(host, Site, undefined),
            Ref = json_text(Ref0),
            Host = json_text(Host0),
            case is_k8s_cert_ref(Ref) andalso is_binary(Host) andalso Host =/= <<>> of
                true ->
                    Prev = maps:get(Ref, Acc, []),
                    maps:put(Ref, lists:usort([Host | Prev]), Acc);
                false ->
                    Acc
            end
        end,
        #{},
        Sites
    ).

is_k8s_cert_ref(Bin) when is_binary(Bin) ->
    byte_size(Bin) > 4 andalso binary:match(Bin, <<"k8s/">>) =:= {0, 4};
is_k8s_cert_ref(_) ->
    false.

ingress_cert_row_json(CertRefBin, Hosts0, Sites) ->
    Hosts = lists:sort([json_text(H) || H <- Hosts0, json_text(H) =/= <<>>]),
    Domain = case Hosts of
        [H | _] -> H;
        _ -> CertRefBin
    end,
    case ingress_cert_pem_for_hosts(Hosts) of
        undefined ->
            #{
                <<"id">> => CertRefBin,
                <<"domain">> => Domain,
                <<"hosts">> => Hosts,
                <<"issuer">> => <<>>,
                <<"challenge">> => <<"k8s secret">>,
                <<"source_type">> => <<"kubernetes">>,
                <<"created_at">> => <<>>,
                <<"expires_at">> => <<>>,
                <<"next_renew">> => <<>>,
                <<"sites">> => sites_for_cert(Sites, CertRefBin, Domain)
            };
        CertPem ->
            stored_pem_cert_row_json(
                CertRefBin,
                Domain,
                CertPem,
                Sites,
                <<"kubernetes">>,
                <<"k8s secret">>
            )
    end.

ingress_cert_pem_for_hosts([]) ->
    undefined;
ingress_cert_pem_for_hosts([Host | Rest]) ->
    case pertisk_ingress_tls:lookup(Host) of
        {ok, #{cert_pem := CertPem}} when is_binary(CertPem), CertPem =/= <<>> ->
            CertPem;
        _ ->
            ingress_cert_pem_for_hosts(Rest)
    end.

helm_enabled() ->
    case lower_bin(helm_env_value("PERTISK_HELM_ENABLED")) of
        undefined -> true;
        <<"1">> -> true;
        <<"true">> -> true;
        <<"yes">> -> true;
        _ -> false
    end.

helm_release_name() ->
    case helm_env_value("PERTISK_HELM_RELEASE") of
        undefined -> {error, release_not_set};
        V -> {ok, V}
    end.

helm_namespace() ->
    case helm_env_value("PERTISK_HELM_NAMESPACE") of
        undefined ->
            case helm_env_value("POD_NAMESPACE") of
                undefined -> <<"default">>;
                Ns -> Ns
            end;
        Ns -> Ns
    end.

helm_history_max() ->
    case helm_env_value("PERTISK_HELM_HISTORY_MAX") of
        undefined ->
            undefined;
        V ->
            try binary_to_integer(V) of
                N when is_integer(N), N > 0 -> N;
                _ -> undefined
            catch
                _:_ -> undefined
            end
    end.

helm_env_value(Key) when is_list(Key) ->
    case os:getenv(Key) of
        false -> undefined;
        V when is_list(V) ->
            Trimmed = string:trim(V),
            case Trimmed of
                "" -> undefined;
                _ -> list_to_binary(Trimmed)
            end
    end.

run_helm_cmd(Args) when is_list(Args) ->
    case os:find_executable("helm") of
        false ->
            {error, not_found};
        HelmPath ->
            Cmd = iolist_to_binary([
                sh_quote(HelmPath),
                " ",
                string:join([sh_quote(A) || A <- Args], " "),
                " 2>&1; __rc=$?; printf '\\n__PERTISK_HELM_RC__:%s\\n' \"$__rc\""
            ]),
            parse_host_cmd_result(pertisk_eproxy_shell:os_cmd(binary_to_list(Cmd)))
    end.

parse_host_cmd_result(Output0) when is_list(Output0) ->
    case re:run(Output0, "\\n__PERTISK_HELM_RC__:(\\d+)\\n?$", [{capture, [1], list}]) of
        {match, [CodeStr]} ->
            Output = re:replace(Output0, "\\n__PERTISK_HELM_RC__:\\d+\\n?$", "", [{return, list}]),
            Code = list_to_integer(CodeStr),
            case Code of
                0 -> {ok, Output};
                _ -> {error, {exit_status, Code, string:trim(Output)}}
            end;
        nomatch ->
            {error, {exit_status, 1, string:trim(Output0)}}
    end.

sh_quote(Bin) when is_binary(Bin) ->
    sh_quote(binary_to_list(Bin));
sh_quote(Str) when is_list(Str) ->
    Escaped = lists:flatten(re:replace(Str, "'", "'\"'\"'", [global, {return, list}])),
    [$' | Escaped] ++ [$'].

lower_bin(undefined) -> undefined;
lower_bin(Bin) when is_binary(Bin) -> list_to_binary(string:lowercase(binary_to_list(Bin))).

bin_field(V) when is_binary(V) -> V;
bin_field(V) when is_list(V) -> unicode:characters_to_binary(V, utf8);
bin_field(V) -> iolist_to_binary(io_lib:format("~p", [V])).

with_alt_svc(Req, Headers) ->
    Host = cowboy_req:host(Req),
    pertisk_eproxy_alt_svc:merge_response_headers(
        Req, Host, pertisk_eproxy_response_headers:merge(Headers)
    ).

ingress_ready_reply(Req, WithBody) ->
    case pertisk_ingress_status:ready_from_runtime() of
        ok when WithBody ->
            json_reply(200, #{<<"status">> => <<"ready">>}, Req);
        ok ->
            json_reply(200, #{}, Req);
        {error, Reason} when WithBody ->
            json_reply(503, #{<<"status">> => <<"not_ready">>, <<"reason">> => Reason}, Req);
        {error, _} ->
            json_reply(503, #{}, Req)
    end.
