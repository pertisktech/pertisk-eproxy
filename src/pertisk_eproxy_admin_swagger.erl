%% @doc Swagger/trails dispatch builder for management listener.
-module(pertisk_eproxy_admin_swagger).

-export([management_dispatch/0]).

-spec management_dispatch() -> cowboy_router:dispatch_rule().
management_dispatch() ->
    Routes = pertisk_eproxy_admin_routes:api_routes() ++ pertisk_eproxy_admin_routes:management_ui_routes(),
    case maybe_swagger_dispatch() of
        {ok, Dispatch} ->
            Dispatch;
        _ ->
            cowboy_router:compile([{'_', Routes}])
    end.

-spec maybe_swagger_dispatch() -> {ok, cowboy_router:dispatch_rule()} | error.
maybe_swagger_dispatch() ->
    case code:ensure_loaded(cowboy_swagger_handler) of
        {module, _} ->
            case application:ensure_all_started(cowboy_swagger) of
                {ok, _} ->
                    build_swagger_dispatch();
                {error, _} ->
                    error
            end;
        _ ->
            error
    end.

-spec build_swagger_dispatch() -> {ok, cowboy_router:dispatch_rule()} | error.
build_swagger_dispatch() ->
    try
        maybe_configure_swagger(),
        ApiTrails = [
            trails:trail(Path, Handler, Opts, route_metadata(Path))
         || {Path, Handler, Opts} <- pertisk_eproxy_admin_routes:api_routes()
        ],
        UiTrails = [
            trails:trail(Path, Handler, Opts, #{get => #{hidden => true}})
         || {Path, Handler, Opts} <- pertisk_eproxy_admin_routes:management_ui_routes()
        ],
        SwaggerTrails = cowboy_swagger_handler:trails(#{server => management}),
        %% Keep Swagger trails before UI catch-all ("/[...]") so /api-docs is reachable.
        AllTrails = ApiTrails ++ SwaggerTrails ++ UiTrails,
        trails:store(management, AllTrails),
        {ok, trails:single_host_compile(AllTrails)}
    catch
        _:_ ->
            error
    end.

maybe_configure_swagger() ->
    ServerSpec = #{
        management => #{
            openapi => <<"3.0.0">>,
            info => #{
                title => <<"pertisk-eproxy Management API">>,
                version => pertisk_eproxy_admin_management_snapshot:app_version()
            },
            servers => [#{url => <<"/">>}]
        }
    },
    _ = application:set_env(cowboy_swagger, server_spec, ServerSpec),
    ok.

-spec route_metadata(string()) -> map().
route_metadata(Path) ->
    Entries = [
        {Method, Desc}
     || {Method, DocPath, Desc} <- route_docs(),
        DocPath =:= Path
    ],
    case Entries of
        [] ->
            #{get => #{hidden => true}};
        _ ->
            Tag = tag_for_path(Path),
            maps:from_list([
                {
                    method_atom(Method),
                    #{
                        tags => [Tag],
                        description => unicode:characters_to_binary(Desc),
                        responses => #{<<"200">> => #{description => <<"Success">>}}
                    }
                }
             || {Method, Desc} <- Entries
            ])
    end.

-spec method_atom(string()) -> atom().
method_atom("GET") -> get;
method_atom("HEAD") -> head;
method_atom("POST") -> post;
method_atom("PUT") -> put;
method_atom("DELETE") -> delete;
method_atom(_) -> get.

-spec tag_for_path(string()) -> binary().
tag_for_path(Path) ->
    case string:tokens(Path, "/") of
        ["api", Segment | _] -> unicode:characters_to_binary(Segment);
        _ -> <<"api">>
    end.

-spec route_docs() -> [{string(), string(), string()}].
route_docs() ->
    [
        {"GET", "/api/version", "Application version"},
        {"HEAD", "/api/version", "Same as GET (no JSON body); Chrome HTTP/3 probe"},
        {"GET", "/api/proto", "Protocol/debug snapshot (request scheme/protocol details and headers)"},
        {"GET", "/api/management", "Node/listener/process/runtime snapshot"},
        {"GET", "/api/stats", "Management counters snapshot"},
        {"GET", "/api/realtime", "WebSocket live snapshots"},
        {"GET", "/api/logs", "Access log ring"},
        {"GET", "/api/auth/config", "Auth mode and login fields"},
        {"HEAD", "/api/auth/config", "Same as GET (no JSON body)"},
        {"POST", "/api/auth/login", "Obtain session token"},
        {"POST", "/api/auth/refresh", "Refresh session token"},
        {"GET", "/api/auth/check", "Authentication status"},
        {"POST", "/api/auth/logout", "End session"},
        {"POST", "/api/admin/change-password", "Password change endpoint"},
        {"GET", "/api/admin/api-token", "API token status"},
        {"POST", "/api/admin/api-token", "Create/rotate API token"},
        {"GET", "/api/backup/export", "Download configuration backup"},
        {"POST", "/api/backup/restore", "Restore configuration backup"},
        {"GET", "/api/helm/history", "Helm history"},
        {"GET", "/api/helm/values/:revision", "Helm values for revision"},
        {"GET", "/api/certificates", "List certificates"},
        {"POST", "/api/certificates", "Create certificate metadata"},
        {"POST", "/api/certificates/import", "Import certificate PEM bundle"},
        {"PUT", "/api/certificates/:id/import", "Import PEM for existing certificate"},
        {"PUT", "/api/certificates/:id", "Update certificate metadata"},
        {"DELETE", "/api/certificates/:id", "Delete certificate"},
        {"GET", "/api/dns-providers", "List DNS providers"},
        {"POST", "/api/dns-providers", "Create DNS provider"},
        {"POST", "/api/dns-providers/validate", "Validate DNS provider credentials"},
        {"PUT", "/api/dns-providers/:id", "Update DNS provider"},
        {"DELETE", "/api/dns-providers/:id", "Delete DNS provider"},
        {"POST", "/api/tls/listener", "Set in-memory TLS listener cert/key files"},
        {"GET", "/api/config", "Get full runtime config"},
        {"PUT", "/api/config", "Replace full runtime config"},
        {"GET", "/api/sites", "List sites"},
        {"POST", "/api/sites", "Create site"},
        {"GET", "/api/sites/:host", "Get site by host"},
        {"PUT", "/api/sites/:host", "Update site"},
        {"DELETE", "/api/sites/:host", "Delete site"},
        {"GET", "/api/backends", "List backends"},
        {"POST", "/api/backends", "Create backend"},
        {"GET", "/api/backends/:name", "Get backend status"},
        {"DELETE", "/api/backends/:name", "Delete backend"},
        {"GET", "/api/health", "Aggregated health"},
        {"GET", "/api/metrics", "Prometheus metrics"},
        {"POST", "/api/reload", "Reload configuration from file"},
        {"GET", "/api/ingress/live", "Ingress liveness probe"},
        {"HEAD", "/api/ingress/live", "Same as GET (no JSON body)"},
        {"GET", "/api/ingress/ready", "Ingress readiness probe"},
        {"HEAD", "/api/ingress/ready", "Same as GET (no JSON body)"},
        {"GET", "/api/ingress/status", "Ingress status snapshot"},
        {"HEAD", "/api/ingress/status", "Same as GET (no JSON body)"},
        {"GET", "/api/ingress/watchers", "Ingress watcher and leader state"},
        {"GET", "/api/ingress/errors", "Last ingress reconciliation error"},
        {"GET", "/api/ingress/resources", "Effective ingress resources"},
        {"GET", "/api/kubernetes/namespaces", "List Kubernetes namespaces"},
        {"GET", "/api/kubernetes/pods", "List Kubernetes pods"},
        {"GET", "/api/kubernetes/services", "List Kubernetes services"},
        {"GET", "/api/kubernetes/tls-secrets", "List Kubernetes TLS secrets"},
        {"GET", "/api/kubernetes/ingresses", "List Kubernetes ingresses"},
        {"POST", "/api/kubernetes/ingresses", "Create Kubernetes ingress"},
        {"GET", "/api/kubernetes/ingresses/:namespace/:name", "Get Kubernetes ingress"},
        {"PUT", "/api/kubernetes/ingresses/:namespace/:name", "Update Kubernetes ingress"},
        {"DELETE", "/api/kubernetes/ingresses/:namespace/:name", "Delete Kubernetes ingress"}
    ].
