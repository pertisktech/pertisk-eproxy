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
    handle(Method, Resource, Req).

%% ---------------------------------------------------------------------------
%% Route dispatch
%% ---------------------------------------------------------------------------

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
                Healthy = length([U || #{healthy := true} <- Ups]),
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
        http_port       => maps:get(http_port, Config, 8080),
        management_port => maps:get(management_port, Config, 9080),
        sites           => [site_to_json(S) || S <- maps:get(sites, Config, [])],
        backends        => [backend_to_json(B) || B <- maps:get(backends, Config, [])]
    }.

site_to_json(#{host := Host, backend := Backend, routes := Routes}) ->
    #{
        host    => Host,
        backend => Backend,
        routes  => [route_to_json(R) || R <- Routes]
    }.

route_to_json(R) ->
    Base = #{
        path      => maps:get(path, R, <<"/">>),
        path_type => atom_to_binary(maps:get(path_type, R, prefix), utf8)
    },
    case maps:get(rewrite, R, undefined) of
        undefined -> Base;
        Rw        -> Base#{rewrite => Rw}
    end.

backend_to_json(B) ->
    #{
        name      => maps:get(name, B),
        algorithm => atom_to_binary(maps:get(algorithm, B, round_robin), utf8),
        upstreams => [#{addr => maps:get(addr, U), weight => maps:get(weight, U, 1)}
                      || U <- maps:get(upstreams, B, [])],
        health_path => case maps:get(health_path, B, undefined) of
            undefined -> null;
            P -> P
        end,
        health_interval_secs => maps:get(health_interval_secs, B, 30)
    }.

status_to_json(#{name := Name, algorithm := Algo, upstreams := Ups}) ->
    #{
        name      => Name,
        algorithm => atom_to_binary(Algo, utf8),
        upstreams => [#{addr    => maps:get(addr, U),
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
