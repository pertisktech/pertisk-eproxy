%% @doc Path-based router for pertisk_eproxy.
%%
%% Supports three path match types (mirroring the reference Rust project):
%%   - exact  : the full request path must match exactly
%%   - prefix : the request path must start with the route path (longest prefix wins)
%%
%% Wildcard host matching: a site host of "*.example.com" matches any
%% subdomain of example.com.
%%
%% Opaque router() type is built once on config load and stored in ETS
%% for lock-free concurrent reads.

-module(pertisk_eproxy_router).

-export([empty/0, build/1, route/2]).

-export_type([router/0, route_match/0]).

-type path_type() :: exact | prefix.

-type route_rule() :: #{
    path      := binary(),
    path_type := path_type(),
    rewrite   => binary() | undefined,
    backend   := binary()
}.

-type host_entry() :: {Host :: binary(), Rules :: [route_rule()]}.

-opaque router() :: [host_entry()].

-type route_match() :: #{
    upstream_path := binary(),
    backend       := binary()
}.

%% ---------------------------------------------------------------------------
%% API
%% ---------------------------------------------------------------------------

-spec empty() -> router().
empty() -> [].

%% Build a router from a list of site config maps.
-spec build([map()]) -> router().
build(Sites) ->
    %% Merge rules by host so cross-site paths resolve correctly.
    Map = lists:foldl(fun(Site, Acc) ->
        Host   = string:lowercase(maps:get(host, Site)),
        Backend = maps:get(backend, Site),
        Rules  = [#{
            path      => maps:get(path,      R, <<"/">>),
            path_type => maps:get(path_type, R, prefix),
            rewrite   => maps:get(rewrite,   R, undefined),
            backend   => Backend
        } || R <- maps:get(routes, Site, [])],
        maps:update_with(Host, fun(Existing) -> Existing ++ Rules end,
                         Rules, Acc)
    end, #{}, Sites),
    maps:to_list(Map).

%% Find the backend and upstream path for a (Host, Path) pair.
%% Returns {ok, route_match()} or {error, no_route}.
-spec route(binary(), binary()) -> {ok, route_match()} | {error, no_route}.
route(Host, Path0) ->
    Router = pertisk_eproxy_config:get_router(),
    HostLower = string:lowercase(Host),
    NormPath  = case Path0 of <<>> -> <<"/">>; P -> P end,
    find_host(Router, HostLower, NormPath).

%% ---------------------------------------------------------------------------
%% Internal
%% ---------------------------------------------------------------------------

find_host([], _Host, _Path) ->
    {error, no_route};
find_host([{SiteHost, Rules} | Rest], Host, Path) ->
    case host_matches(Host, SiteHost) of
        true  -> match_rules(Rules, Path);
        false -> find_host(Rest, Host, Path)
    end.

%% Match rules: exact beats prefix; among prefixes, longest wins.
match_rules(Rules, Path) ->
    Exact  = [R || R = #{path_type := exact,  path := P} <- Rules, P =:= Path],
    Prefix = [R || R = #{path_type := prefix, path := P} <- Rules,
                   binary:match(Path, P) =:= {0, byte_size(P)}],
    case Exact of
        [R | _] -> {ok, apply_rewrite(R, Path)};
        [] ->
            case longest_prefix(Prefix) of
                undefined -> {error, no_route};
                R         -> {ok, apply_rewrite(R, Path)}
            end
    end.

longest_prefix([]) -> undefined;
longest_prefix(Candidates) ->
    lists:foldl(fun(R = #{path := P}, Best) ->
        case Best of
            undefined -> R;
            #{path := BP} when byte_size(P) > byte_size(BP) -> R;
            _ -> Best
        end
    end, undefined, Candidates).

apply_rewrite(#{path := RulePath, rewrite := Rewrite, backend := Backend}, RequestPath)
    when Rewrite =/= undefined ->
    %% Strip the matched prefix from the request path and prepend rewrite target.
    Stripped = binary:part(RequestPath, byte_size(RulePath),
                           byte_size(RequestPath) - byte_size(RulePath)),
    UpstreamPath = case Stripped of
        <<>> -> Rewrite;
        _    ->
            Suffix = case binary:last(Rewrite) of
                $/ -> Stripped;
                _  -> <<"/", Stripped/binary>>
            end,
            <<Rewrite/binary, Suffix/binary>>
    end,
    #{upstream_path => UpstreamPath, backend => Backend};
apply_rewrite(#{backend := Backend}, RequestPath) ->
    #{upstream_path => RequestPath, backend => Backend}.

%% Host matching: exact or wildcard (*.example.com).
host_matches(Host, <<"*.", Suffix/binary>>) ->
    case binary:match(Host, <<".">>) of
        nomatch -> false;
        {Pos, _} ->
            HostSuffix = binary:part(Host, Pos + 1, byte_size(Host) - Pos - 1),
            HostSuffix =:= Suffix
    end;
host_matches(Host, SiteHost) ->
    Host =:= SiteHost.
