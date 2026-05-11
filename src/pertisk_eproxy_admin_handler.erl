%% @doc Admin REST API handler for pertisk_eproxy.
%%
%% Endpoints (served on the management listener, default 127.0.0.1:9080):
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
auth_public(<<"GET">>, auth_config) -> true;
auth_public(<<"POST">>, auth_login) -> true;
auth_public(<<"POST">>, auth_logout) -> true;
auth_public(<<"GET">>, metrics) -> true;
auth_public(<<"GET">>, health) -> true;
auth_public(_, _) -> false.

%% ---------------------------------------------------------------------------
%% Route dispatch
%% ---------------------------------------------------------------------------

handle(<<"GET">>, version, Req) ->
    json_reply(200, #{<<"version">> => app_version()}, Req);

handle(<<"GET">>, management, Req) ->
    json_reply(200, management_info(), Req);

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
            case cowboy_req:parse_header(<<"authorization">>, Req) of
                {bearer, Token} ->
                    case pertisk_eproxy_auth:refresh(Token) of
                        {ok, #{token := T, username := U, expires_in := E}} ->
                            json_reply(200, #{<<"token">> => T, <<"username">> => U, <<"expires_in">> => E}, Req);
                        {error, _} ->
                            json_reply(401, #{<<"error">> => <<"Unauthorized">>}, Req)
                    end;
                _ ->
                    json_reply(401, #{<<"error">> => <<"Unauthorized">>}, Req)
            end
    end;

handle(<<"GET">>, auth_check, Req) ->
    case pertisk_eproxy_auth:auth_mode() of
        disabled ->
            json_reply(200, #{<<"authenticated">> => true, <<"username">> => <<"operator">>}, Req);
        local ->
            case cowboy_req:parse_header(<<"authorization">>, Req) of
                {bearer, Token} ->
                    case pertisk_eproxy_auth:verify_token(Token) of
                        {ok, U} ->
                            json_reply(200, #{<<"authenticated">> => true, <<"username">> => U}, Req);
                        {error, _} ->
                            json_reply(200, #{<<"authenticated">> => false}, Req)
                    end;
                _ ->
                    json_reply(200, #{<<"authenticated">> => false}, Req)
            end
    end;

handle(<<"POST">>, auth_logout, Req) ->
    case cowboy_req:parse_header(<<"authorization">>, Req) of
        {bearer, Token} -> pertisk_eproxy_auth:logout(Token);
        _ -> ok
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
    Req2 = cowboy_req:reply(200, Headers, Body, Req),
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
    json_reply(200, [], Req);

handle(<<"GET">>, root, Req) ->
    API = #{
        status => <<"ok">>,
        name => <<"Pertisk eProxy">>,
        version => <<"1.0.0">>,
        endpoints => [
            #{method => <<"GET">>, path => <<"/api/config">>, description => <<"Fetch full proxy config">>},
            #{method => <<"PUT">>, path => <<"/api/config">>, description => <<"Replace proxy config">>},
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
    json_reply(200, config_to_json(Config), Req);

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
    Req2   = cowboy_req:reply(200,
                              #{<<"content-type">> => <<"text/plain; version=0.0.4">>},
                              Output, Req),
    {ok, Req2, metrics};

handle(<<"POST">>, reload, Req) ->
    case pertisk_eproxy_config:reload() of
        ok         -> json_reply(200, #{status => <<"reloaded">>}, Req);
        {error, R} -> error_reply(500, R, Req)
    end;

handle(_Method, _Resource, Req) ->
    Req2 = cowboy_req:reply(405, #{<<"content-type">> => <<"text/plain">>},
                            <<"Method Not Allowed">>, Req),
    {ok, Req2, undefined}.

%% ---------------------------------------------------------------------------
%% JSON helpers
%% ---------------------------------------------------------------------------

json_reply(Status, Data, Req) ->
    Body = thoas:encode(Data),
    Req2 = cowboy_req:reply(Status,
                            #{<<"content-type">> => <<"application/json">>},
                            Body, Req),
    {ok, Req2, undefined}.

error_reply(Status, Reason, Req) ->
    Msg = iolist_to_binary(io_lib:format("~p", [Reason])),
    json_reply(Status, #{error => Msg}, Req).

not_found_reply(Req) ->
    json_reply(404, #{error => <<"not found">>}, Req).

with_json_body(Req, Fun) ->
    {ok, Body, Req2} = cowboy_req:read_body(Req),
    case thoas:decode(Body) of
        {ok, Json}       -> Fun(Json, Req2);
        {error, _Reason} -> json_reply(400, #{error => <<"invalid json">>}, Req2)
    end.

%% ---------------------------------------------------------------------------
%% Serialisation
%% ---------------------------------------------------------------------------

config_to_json(Config) ->
    #{
        mode            => atom_to_binary(maps:get(mode, Config, proxy_admin), utf8),
        http_port       => maps:get(http_port, Config, 8080),
        management_port => maps:get(management_port, Config, 9080),
        certificates    => [json_text(V) || V <- maps:get(certificates, Config, [])],
        dns_providers   => [json_text(V) || V <- maps:get(dns_providers, Config, [])],
        sites           => [site_to_json(S) || S <- maps:get(sites, Config, [])],
        backends        => [backend_to_json(B) || B <- maps:get(backends, Config, [])]
    }.

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
    case maps:get(dns_provider, Site, undefined) of
        undefined -> WithCertificate;
        DnsProvider -> WithCertificate#{dns_provider => json_text(DnsProvider)}
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

json_text(V) when is_binary(V) -> V;
json_text(V) when is_list(V) -> list_to_binary(V);
json_text(V) -> V.

%% ---------------------------------------------------------------------------
%% Misc
%% ---------------------------------------------------------------------------

app_version() ->
    case application:get_key(pertisk_eproxy, vsn) of
        {ok, V} when is_list(V) -> list_to_binary(V);
        {ok, V} when is_binary(V) -> V;
        _ -> <<"0.1.0">>
    end.

management_info() ->
    C = pertisk_eproxy_config:get_config(),
    HttpPort = maps:get(http_port, C, 8080),
    MgmtPort = maps:get(management_port, C, 9080),
    MgmtAddr = maps:get(management_addr, C, {127, 0, 0, 1}),
    Mode0 = maps:get(mode, C, proxy_admin),
    ModeBin = case Mode0 of
        proxy_admin -> <<"proxy">>;
        proxy -> <<"proxy">>;
        M -> atom_to_binary(M, utf8)
    end,
    HttpsAddr = case maps:find(https_port, C) of
        {ok, Hp} -> iolist_to_binary(io_lib:format("0.0.0.0:~w", [Hp]));
        _ -> <<>>
    end,
    #{
        <<"version">> => app_version(),
        <<"mode">> => ModeBin,
        <<"http_addr">> => iolist_to_binary(io_lib:format("0.0.0.0:~w", [HttpPort])),
        <<"https_addr">> => HttpsAddr,
        <<"management_addr">> => iolist_to_binary([inet:ntoa(MgmtAddr), $:, integer_to_list(MgmtPort)]),
        <<"db_path">> => null,
        <<"http_versions">> => [<<"1.1">>, <<"2">>]
    }.

bin_field(V) when is_binary(V) -> V;
bin_field(V) when is_list(V) -> unicode:characters_to_binary(V, utf8);
bin_field(V) -> iolist_to_binary(io_lib:format("~p", [V])).
