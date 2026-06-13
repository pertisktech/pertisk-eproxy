%% @doc Patch Gateway API Gateway .status (Accepted + Programmed conditions).
-module(pertisk_gateway_status).

-export([maybe_update/1, row_to_address/1]).

-spec maybe_update({term(), map()}) -> ok.
maybe_update(Conn) ->
    case pertisk_ingress_env:gateway_api_enabled() of
        false ->
            ok;
        true ->
            case pertisk_ingress_leader:is_leader() of
                false ->
                    ok;
                true ->
                    patch_gateways(Conn)
            end
    end.

patch_gateways(Conn) ->
    case list_gateways(Conn) of
        {ok, Gateways} ->
            ClassFilter = pertisk_ingress_env:ingress_class(),
            lists:foreach(
                fun(Gateway) ->
                    case gateway_matches_class(Gateway, ClassFilter) of
                        true -> patch_one(Gateway, Conn);
                        false -> ok
                    end
                end,
                Gateways
            ),
            ok;
        {error, Reason} ->
            lager:debug("Gateway list failed: ~p", [Reason]),
            ok
    end.

patch_one(Gateway, Conn) ->
    Meta = maps:get(<<"metadata">>, Gateway, #{}),
    Name = name_of(Meta),
    Endpoint = ekub_api:endpoint(
        <<"gateway.networking.k8s.io">>,
        <<"v1">>,
        <<"gateways">>,
        namespace_of(Meta),
        Name,
        <<"status">>
    ),
    Addresses = gateway_addresses(Conn),
    Body = #{
        <<"status">> => #{
            <<"addresses">> => Addresses,
            <<"conditions">> => [accepted_condition(), programmed_condition()]
        }
    },
    case pertisk_ingress_ekub:merge_patch(Endpoint, Body, Conn) of
        {ok, _} ->
            lager:info(
                "Gateway ~s/~s status Accepted=True Programmed=True addresses=~p",
                [namespace_of(Meta), Name, length(Addresses)]
            ),
            ok;
        {error, #{<<"code">> := 404}} ->
            ok;
        {error, Err} ->
            lager:warning("Gateway status patch ~s/~s failed: ~p", [namespace_of(Meta), Name, Err]),
            ok
    end.

gateway_addresses(Conn) ->
    lists:flatmap(fun row_to_address/1, load_balancer_rows(Conn)).

row_to_address(#{<<"ip">> := Ip}) when is_binary(Ip), Ip =/= <<>> ->
    [#{<<"type">> => <<"IPAddress">>, <<"value">> => Ip}];
row_to_address(#{<<"hostname">> := Host}) when is_binary(Host), Host =/= <<>> ->
    [#{<<"type">> => <<"Hostname">>, <<"value">> => Host}];
row_to_address(_) ->
    [].

load_balancer_rows(Conn) ->
    case publish_service_ref() of
        {ok, Ns, SvcName} ->
            case ekub:read(service, Ns, SvcName, Conn) of
                {ok, Svc} ->
                    ingress_rows_from_service(Svc);
                {error, _} ->
                    []
            end;
        error ->
            []
    end.

ingress_rows_from_service(Svc) ->
    Status = maps:get(<<"status">>, Svc, #{}),
    case maps:get(<<"loadBalancer">>, Status, undefined) of
        #{<<"ingress">> := Rows} when is_list(Rows) -> Rows;
        _ -> []
    end.

publish_service_ref() ->
    case pertisk_ingress_env:publish_service_name() of
        {ok, Name} ->
            Ns = pertisk_ingress_env:leader_namespace(),
            {ok, Ns, Name};
        error ->
            error
    end.

list_gateways(Conn) ->
    Query = list_query(),
    Api = {<<"gateway.networking.k8s.io">>, <<"v1">>},
    Read = case pertisk_ingress_env:namespace() of
        all_namespaces ->
            read_cluster_resource(Conn, Api, <<"gateways">>, Query);
        Ns when is_binary(Ns) ->
            read_cluster_resource(Conn, Api, <<"gateways">>, [{namespace, Ns} | Query])
    end,
    case Read of
        {ok, ListObj} -> {ok, items_from_list(ListObj)};
        {error, #{<<"code">> := 404}} -> {ok, []};
        {error, _} = Err -> Err
    end.

read_cluster_resource({_Api, Access}, {Group, Version}, ResourceType, Query) ->
    Endpoint = ekub_api:endpoint(Group, Version, ResourceType, <<>>, <<>>, <<>>),
    case Endpoint of
        <<>> ->
            {error, {resource_not_found, ResourceType}};
        _ ->
            ekub_core:http_request(Endpoint, Query, Access)
    end.

list_query() ->
    case pertisk_ingress_env:namespace() of
        all_namespaces -> [];
        Ns when is_binary(Ns) -> [{namespace, Ns}]
    end.

gateway_matches_class(_Gateway, all) ->
    true;
gateway_matches_class(Gateway, {ok, WantClass}) ->
    Spec = maps:get(<<"spec">>, Gateway, #{}),
    maps:get(<<"gatewayClassName">>, Spec, undefined) =:= WantClass.

accepted_condition() ->
    #{
        <<"type">> => <<"Accepted">>,
        <<"status">> => <<"True">>,
        <<"reason">> => <<"Accepted">>,
        <<"message">> => <<"Gateway accepted by pertisk-eproxy controller">>,
        <<"lastTransitionTime">> => pertisk_k8s_time:rfc3339_now()
    }.

programmed_condition() ->
    #{
        <<"type">> => <<"Programmed">>,
        <<"status">> => <<"True">>,
        <<"reason">> => <<"Programmed">>,
        <<"message">> => <<
            "Routes are programmed via HTTPRoute annotation pertisk.io/gateway-class"
        >>,
        <<"lastTransitionTime">> => pertisk_k8s_time:rfc3339_now()
    }.

items_from_list(#{<<"items">> := Items}) when is_list(Items) ->
    Items;
items_from_list(Obj) when is_map(Obj) ->
    case maps:is_key(<<"items">>, Obj) of
        true -> maps:get(<<"items">>, Obj, []);
        false -> [Obj]
    end;
items_from_list(_) ->
    [].

namespace_of(#{<<"namespace">> := Ns}) when is_binary(Ns) -> Ns;
namespace_of(_) -> <<"default">>.

name_of(#{<<"name">> := Name}) when is_binary(Name) -> Name;
name_of(_) -> <<"unknown">>.
