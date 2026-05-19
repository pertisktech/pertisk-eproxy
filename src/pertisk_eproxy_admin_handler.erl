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

-export([init/2]).

init(Req, Resource) ->
    Method = cowboy_req:method(Req),
    case auth_public(Method, Resource) of
        true ->
            handle(Method, Resource, Req);
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
    end.

auth_public(<<"GET">>, root) -> true;
auth_public(<<"GET">>, version) -> true;
auth_public(<<"HEAD">>, version) -> true;
auth_public(<<"GET">>, proto) -> true;
auth_public(<<"HEAD">>, proto) -> true;
auth_public(<<"GET">>, auth_config) -> true;
auth_public(<<"HEAD">>, auth_config) -> true;
auth_public(<<"GET">>, auth_check) -> true;
auth_public(<<"POST">>, auth_login) -> true;
auth_public(<<"POST">>, auth_refresh) -> true;
auth_public(<<"POST">>, auth_logout) -> true;
auth_public(<<"GET">>, metrics) -> true;
auth_public(<<"GET">>, health) -> true;
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
    json_reply(200, proto_snapshot(Req), Req);
handle(<<"HEAD">>, proto, Req) ->
    json_reply(200, #{}, Req);

handle(<<"GET">>, management, Req) ->
    json_reply(200, pertisk_eproxy_admin_management_snapshot:snapshot(), Req);

handle(<<"GET">>, stats, Req) ->
    json_reply(200, pertisk_eproxy_stats:snapshot(), Req);

handle(<<"GET">>, logs, Req) ->
    Qs = maps:from_list(cowboy_req:parse_qs(Req)),
    Type = maps:get(<<"type">>, Qs, undefined),
    Host = maps:get(<<"host">>, Qs, undefined),
    Entries = pertisk_eproxy_access_log:list(Type, Host),
    json_reply(200, Entries, Req);

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
    json_reply(501, #{<<"error">> => <<"Password change is not implemented for eProxy">>}, Req);

handle(<<"GET">>, admin_api_token, Req) ->
    json_reply(200, #{<<"has_token">> => false}, Req);

handle(<<"POST">>, admin_api_token, Req) ->
    json_reply(501, #{<<"error">> => <<"API tokens are not implemented for eProxy">>}, Req);

handle(<<"GET">>, backup_export, Req) ->
    Config = pertisk_eproxy_config:get_config(),
    Body = thoas:encode(config_to_json(Config)),
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
                        ok = pertisk_eproxy_config:put_config(Config),
                        json_reply(200, #{<<"status">> => <<"ok">>}, Req2);
                    {error, R} ->
                        error_reply(400, R, Req2)
                end;
            {error, _} ->
                json_reply(400, #{<<"error">> => <<"invalid json in data">>}, Req2)
        end
    end);

handle(<<"GET">>, helm_history, Req) ->
    json_reply(200, #{<<"release">> => <<>>, <<"namespace">> => <<>>, <<"history">> => []}, Req);

handle(<<"GET">>, helm_values, Req) ->
    _Rev = cowboy_req:binding(revision, Req),
    json_reply(404, #{<<"error">> => <<"Helm is not available on eProxy">>}, Req);

handle(<<"GET">>, certificates, Req) ->
    case pertisk_eproxy_db:list_certificates(db_file_path()) of
        {ok, Certs} ->
            Config = pertisk_eproxy_config:get_config(),
            Sites = maps:get(sites, Config, []),
            AcmeRows = [certificate_row_json(C, Sites) || C <- Certs],
            json_reply(200, AcmeRows, Req);
        {error, Reason} ->
            error_reply(500, Reason, Req)
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
                Cred = parse_dns_credentials(maps:get(<<"credentials">>, Body, #{})),
                case dns_provider_name_by_id(Id) of
                    {ok, PrevName} ->
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
                        end;
                    {error, not_found} ->
                        not_found_reply(Req2);
                    {error, Reason} ->
                        error_reply(400, Reason, Req2)
                end
            end)
    end;

handle(<<"DELETE">>, dns_provider, Req) ->
    IdBin = cowboy_req:binding(id, Req),
    case parse_int_param(IdBin) of
        {error, bad_id} ->
            json_reply(400, #{<<"error">> => <<"invalid dns provider id">>}, Req);
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
            end
    end;

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
                            <<"tls_key_file">> => KeyPath,
                            <<"notice">> =>
                                <<"Restart the proxy process to load the new TLS material on the HTTPS listener.">>
                        }, Req2);
                    {error, R} ->
                        error_reply(400, R, Req2)
                end
        end
    end);

handle(<<"GET">>, root, Req) ->
    API = #{
        status => <<"ok">>,
        name => <<"Pertisk eProxy">>,
        version => <<"1.0.0">>,
        endpoints => [
            #{method => <<"GET">>, path => <<"/api/config">>, description => <<"Fetch full proxy config">>},
            #{method => <<"PUT">>, path => <<"/api/config">>, description => <<"Replace proxy config">>},
            #{method => <<"GET">>, path => <<"/api/proto">>, description => <<"Current request protocol diagnostics">>},
            #{method => <<"GET">>, path => <<"/api/sites">>, description => <<"List all sites">>},
            #{method => <<"POST">>, path => <<"/api/sites">>, description => <<"Add a site">>},
            #{method => <<"GET">>, path => <<"/api/sites/:host">>, description => <<"Get a site">>},
            #{method => <<"DELETE">>, path => <<"/api/sites/:host">>, description => <<"Delete a site">>},
            #{method => <<"GET">>, path => <<"/api/backends">>, description => <<"List all backends">>},
            #{method => <<"POST">>, path => <<"/api/backends">>, description => <<"Add a backend">>},
            #{method => <<"GET">>, path => <<"/api/backends/:name">>, description => <<"Get backend status">>},
            #{method => <<"DELETE">>, path => <<"/api/backends/:name">>, description => <<"Delete a backend">>},
            #{method => <<"GET">>, path => <<"/api/health">>, description => <<"Overall health">>},
            #{method => <<"GET">>, path => <<"/api/metrics">>, description => <<"Prometheus metrics">>},
            #{method => <<"POST">>, path => <<"/api/reload">>, description => <<"Reload config">>}
        ]
    },
    json_reply(200, API, Req);

handle(<<"GET">>, config, Req) ->
    Config = pertisk_eproxy_config:get_config(),
    Data = config_to_json(Config),
    Body = thoas:encode(Data),
    Headers = #{
        <<"content-type">> => <<"application/json">>,
        <<"cache-control">> => <<"no-store, max-age=0">>
    },
    Req2 = cowboy_req:reply(200, with_alt_svc(Req, Headers), Body, Req),
    {ok, Req2, undefined};

handle(<<"PUT">>, config, Req) ->
    with_json_body(Req, fun(Body, Req2) ->
        Config = pertisk_eproxy_config:json_to_config_pub(Body),
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
        ok = pertisk_eproxy_config:put_config(NewConfig),
        json_reply(201, site_to_json(NewSite), Req2)
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
        NewSite = parse_site(Body),
        Config  = pertisk_eproxy_config:get_config(),
        Sites   = maps:get(sites, Config, []),
        NewSites = [S || S = #{host := H} <- Sites, H =/= HostParam, H =/= maps:get(host, NewSite)],
        ok = pertisk_eproxy_config:put_config(Config#{sites => NewSites ++ [NewSite]}),
        json_reply(200, site_to_json(NewSite), Req2)
    end);

handle(<<"DELETE">>, site, Req) ->
    HostParam = cowboy_req:binding(host, Req),
    Config    = pertisk_eproxy_config:get_config(),
    Sites     = maps:get(sites, Config, []),
    NewSites  = [S || S = #{host := H} <- Sites, H =/= HostParam],
    ok = pertisk_eproxy_config:put_config(Config#{sites => NewSites}),
    json_reply(200, #{status => <<"deleted">>}, Req);

handle(<<"GET">>, backends, Req) ->
    Backends = pertisk_eproxy_config:get_backends(),
    json_reply(200, [backend_to_json(B) || B <- Backends], Req);

handle(<<"POST">>, backends, Req) ->
    with_json_body(Req, fun(Body, Req2) ->
        Config   = pertisk_eproxy_config:get_config(),
        Backends = maps:get(backends, Config, []),
        NewBe    = parse_backend(Body),
        NewConfig = Config#{backends => Backends ++ [NewBe]},
        ok = pertisk_eproxy_config:put_config(NewConfig),
        json_reply(201, backend_to_json(NewBe), Req2)
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
    ok = pertisk_eproxy_config:put_config(Config#{backends => NewBes}),
    pertisk_eproxy_backend_sup:stop_backend(Name),
    json_reply(200, #{status => <<"deleted">>}, Req);

handle(<<"GET">>, health, Req) ->
    Backends = pertisk_eproxy_config:get_backends(),
    Health = lists:map(fun(#{name := Name}) ->
        case pertisk_eproxy_backend:status(Name) of
            {ok, #{upstreams := Ups}} ->
                Healthy = length([U || U = #{healthy := true} <- Ups]),
                #{name => Name, total => length(Ups), healthy => Healthy};
            _ ->
                #{name => Name, total => 0, healthy => 0}
        end
    end, Backends),
    json_reply(200, #{backends => Health}, Req);

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
        ok         -> json_reply(200, #{status => <<"reloaded">>}, Req);
        {error, R} -> error_reply(500, R, Req)
    end;

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

json_reply(Status, Data, Req) ->
    inc_management_request_metric(Req, Status),
    Body = thoas:encode(Data),
    Req2 = reply_compressed(
        Status,
        with_alt_svc(Req, #{<<"content-type">> => <<"application/json">>}),
        Body,
        Req
    ),
    {ok, Req2, undefined}.

reply_compressed(Status, Headers, Body, Req) ->
    {OutHeaders, OutBody} =
        pertisk_eproxy_compression:maybe_compress_cowboy(Status, Req, Headers, Body),
    cowboy_req:reply(Status, OutHeaders, OutBody, Req).

error_reply(Status, Reason, Req) ->
    Msg = iolist_to_binary(io_lib:format("~p", [Reason])),
    json_reply(Status, #{error => Msg}, Req).

not_found_reply(Req) ->
    json_reply(404, #{error => <<"not found">>}, Req).

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

dns_cred_to_json(M) when is_map(M) -> M;
dns_cred_to_json(_) -> #{}.

config_to_json(Config) ->
    Base = #{
        mode            => atom_to_binary(maps:get(mode, Config, proxy_admin), utf8),
        http_port       => maps:get(http_port, Config, 80),
        management_port => maps:get(management_port, Config, 9080),
        certificates    => [json_text(V) || V <- maps:get(certificates, Config, [])],
        dns_providers   => [dns_provider_entry_to_json(P) || P <- maps:get(dns_providers, Config, [])],
        sites           => [site_to_json(S) || S <- maps:get(sites, Config, [])],
        backends        => [backend_to_json(B) || B <- maps:get(backends, Config, [])]
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
        {Cf, Kf} when Cf =/= undefined, Kf =/= undefined ->
            WithH3ProbePort#{
                <<"tls_cert_file">> => json_text(Cf),
                <<"tls_key_file">> => json_text(Kf)
            };
        _ ->
            WithH3ProbePort
    end.

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
    case maps:get(acme_contact_email, Site, undefined) of
        undefined -> WithWildcardBase;
        E -> WithWildcardBase#{acme_contact_email => json_text(E)}
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
    #{
        name      => json_text(maps:get(name, B)),
        algorithm => atom_to_binary(maps:get(algorithm, B, round_robin), utf8),
        upstreams => [#{addr => json_text(maps:get(addr, U)), weight => maps:get(weight, U, 1)}
                      || U <- maps:get(upstreams, B, [])],
        health_path => case maps:get(health_path, B, undefined) of
            undefined -> null;
            P -> json_text(P)
        end,
        health_interval_secs => maps:get(health_interval_secs, B, 30)
    }.

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
    #{
        name      => maps:get(<<"name">>, Body),
        algorithm => parse_algorithm(maps:get(<<"algorithm">>, Body, <<"round_robin">>)),
        upstreams => [#{addr   => maps:get(<<"addr">>, U),
                        weight => maps:get(<<"weight">>, U, 1)}
                      || U <- maps:get(<<"upstreams">>, Body, [])],
        health_path          => maps:get(<<"health_path">>, Body, undefined),
        health_interval_secs => maps:get(<<"health_interval_secs">>, Body, 30)
    }.

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

proto_snapshot(Req) ->
    Version = io_lib:format("~p", [cowboy_req:version(Req)]),
    Scheme = io_lib:format("~p", [cowboy_req:scheme(Req)]),
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
    #{
        <<"http_version">> => iolist_to_binary(Version),
        <<"scheme">> => iolist_to_binary(Scheme),
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
    cert_field_matches(CertRef, IdBin) orelse cert_field_matches(CertRef, NameBin).

cert_field_matches(undefined, _) -> false;
cert_field_matches(null, _) -> false;
cert_field_matches(C, N) when is_binary(C), is_binary(N) -> C =:= N;
cert_field_matches(C, N) when is_list(C), is_binary(N) -> iolist_to_binary(C) =:= N;
cert_field_matches(C, N) when is_list(C), is_list(N) -> C =:= N;
cert_field_matches(C, N) when is_binary(C), is_list(N) -> C =:= iolist_to_binary(N);
cert_field_matches(_, _) -> false.

certificate_name_by_id(Id) ->
    case pertisk_eproxy_db:list_certificates(db_file_path()) of
        {ok, Certs} ->
            case lists:search(fun(#{id := RowId}) -> RowId =:= Id end, Certs) of
                {value, #{name := Name}} -> {ok, json_text(Name)};
                false -> {error, not_found}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

certificate_in_use(Name) ->
    NameBin = json_text(Name),
    IdBin =
        case certificate_id_by_name(NameBin) of
            {ok, I} -> integer_to_binary(I);
            _ -> <<>>
        end,
    Sites = pertisk_eproxy_config:get_sites(),
    lists:any(
        fun(S) ->
            Ref = maps:get(certificate, S, undefined),
            cert_field_matches(Ref, NameBin) orelse (IdBin =/= <<>> andalso cert_field_matches(Ref, IdBin))
        end,
        Sites
    ).

certificate_id_by_name(NameBin) ->
    case pertisk_eproxy_db:list_certificates(db_file_path()) of
        {ok, Certs} ->
            case lists:search(fun(#{name := N}) -> json_text(N) =:= NameBin end, Certs) of
                {value, #{id := Id}} -> {ok, Id};
                false -> {error, not_found}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

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

parse_dns_credentials(M) when is_map(M) -> M;
parse_dns_credentials(_) -> #{}.

dns_provider_db_row_to_json(#{id := Id, name := Name, provider_type := Pt, credentials := Cred}) ->
    #{
        <<"id">> => integer_to_binary(Id),
        <<"name">> => json_text(Name),
        <<"provider_type">> => json_text(Pt),
        <<"credentials">> => Cred,
        <<"created_at">> => <<>>
    }.

dns_provider_name_by_id(Id) ->
    case pertisk_eproxy_db:list_dns_providers(db_file_path()) of
        {ok, Rows} ->
            case lists:search(fun(#{id := RowId}) -> RowId =:= Id end, Rows) of
                {value, #{name := Name}} -> {ok, json_text(Name)};
                false -> {error, not_found}
            end;
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
            DnsProviders = [
                #{
                    name => binary_to_list(json_text(maps:get(name, R))),
                    provider_type => binary_to_list(json_text(maps:get(provider_type, R))),
                    credentials => maps:get(credentials, R, #{})
                }
                || R <- Rows
            ],
            C0 = pertisk_eproxy_config:get_config(),
            _ = pertisk_eproxy_config:put_config(C0#{dns_providers => DnsProviders}),
            ok;
        {error, _} ->
            ok
    end.

bin_field(V) when is_binary(V) -> V;
bin_field(V) when is_list(V) -> unicode:characters_to_binary(V, utf8);
bin_field(V) -> iolist_to_binary(io_lib:format("~p", [V])).

with_alt_svc(Req, Headers) ->
    Host = cowboy_req:host(Req),
    pertisk_eproxy_alt_svc:merge_response_headers(Req, Host, Headers).
