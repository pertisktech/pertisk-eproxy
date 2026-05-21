%% @doc In-cluster ekub init (fixes ekub default server "https://kubernetes" → nxdomain).
-module(pertisk_ingress_ekub).

-export([init/0]).

-define(SA_DIR, "/var/run/secrets/kubernetes.io/serviceaccount").

-spec init() -> {ok, {term(), map()}} | {error, term()}.
init() ->
    case in_cluster_service_account() of
        true ->
            init_in_cluster();
        false ->
            ekub:init()
    end.

init_in_cluster() ->
    Options = [
        {server, api_server_url()},
        {ca_cert_file, ?SA_DIR ++ "/ca.crt"},
        {token_file, ?SA_DIR ++ "/token"},
        {namespace_file, ?SA_DIR ++ "/namespace"}
    ],
    case ekub_access:read(Options) of
        {ok, Access} ->
            case ekub_api:load(Access) of
                {ok, Api} ->
                    lager:info("ekub: in-cluster API ~s", [maps:get(server, Access, "")]),
                    {ok, {Api, Access}};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

api_server_url() ->
    case os:getenv("PERTISK_K8S_API_SERVER") of
        false -> default_api_server_url();
        "" -> default_api_server_url();
        Url -> Url
    end.

default_api_server_url() ->
    case {os:getenv("KUBERNETES_SERVICE_HOST"), os:getenv("KUBERNETES_SERVICE_PORT_HTTPS")} of
        {false, _} ->
            "https://kubernetes.default.svc.cluster.local";
        {Host, Port} ->
            "https://" ++ Host ++ ":" ++ coalesce_port(Port)
    end.

coalesce_port(false) -> "443";
coalesce_port(P) when is_list(P) -> P.

in_cluster_service_account() ->
    filelib:is_regular(?SA_DIR ++ "/token")
        andalso filelib:is_regular(?SA_DIR ++ "/ca.crt").
