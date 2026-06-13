%% @doc In-cluster ekub init (fixes ekub default server "https://kubernetes" → nxdomain).
-module(pertisk_ingress_ekub).

-export([init/0, merge_patch/3]).

-define(SA_DIR, "/var/run/secrets/kubernetes.io/serviceaccount").
-define(RecvTimeout, 60 * 1000).

-spec init() -> {ok, {term(), map()}} | {error, term()}.
init() ->
    case in_cluster_service_account() of
        true ->
            init_in_cluster();
        false ->
            ekub:init()
    end.

%% @doc JSON merge patch for CRD status subresources (ekub uses strategic merge).
-spec merge_patch(iolist() | binary(), map(), {term(), map()}) ->
    {ok, map()} | {error, term()}.
merge_patch(Path, Body, {_Api, Access}) when is_map(Body) ->
    Url = iolist_to_binary([maps:get(server, Access, ""), Path]),
    Headers = [
        {<<"Content-Type">>, <<"application/merge-patch+json">>},
        auth_header(Access)
    ],
    Opts = [{ssl_options, ssl_options(Access)}, {recv_timeout, ?RecvTimeout}],
    case hackney:request(patch, Url, Headers, jsx:encode(Body), Opts) of
        {ok, Code, RespHdrs, Ref} when Code >= 200, Code =< 299 ->
            case hackney:body(Ref) of
                {ok, RespBody} -> {ok, decode_json(RespHdrs, RespBody)};
                {error, Reason} -> {error, Reason}
            end;
        {ok, _Code, RespHdrs, Ref} ->
            {error, decode_json(RespHdrs, hackney_body(Ref))};
        {error, Reason} ->
            {error, Reason}
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

auth_header(#{token := Token}) ->
    {<<"Authorization">>, iolist_to_binary(["Bearer ", Token])};
auth_header(#{username := UserName, password := Password}) ->
    {<<"Authorization">>, base64:encode(iolist_to_binary([UserName, $:, Password]))};
auth_header(_) ->
    {<<"Authorization">>, <<>>}.

ssl_options(Access) ->
    Verify =
        case maps:get(insecure_skip_tls_verify, Access, false) of
            true -> verify_none;
            false -> verify_peer
        end,
    Base = [{verify, Verify}],
    Ca = case maps:get(ca_cert, Access, false) of
        false -> [];
        Cert -> [{cacerts, [Cert]}]
    end,
    Client =
        case {maps:get(client_cert, Access, false), maps:get(client_key, Access, false)} of
            {false, _} -> [];
            {ClientCert, ClientKey} -> [{cert, ClientCert}, {key, ClientKey}]
        end,
    Base ++ Ca ++ Client.

decode_json(_Headers, Body) when is_binary(Body) ->
    try jsx:decode(Body, [return_maps]) of
        Decoded -> Decoded
    catch
        _:_ -> Body
    end;
decode_json(_, Body) ->
    Body.

hackney_body(Ref) ->
    case hackney:body(Ref) of
        {ok, B} -> B;
        {error, _} -> <<>>
    end.
