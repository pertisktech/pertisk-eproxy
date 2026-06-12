%% @doc Patch Kubernetes Ingress .status (loadBalancer + conditions) after reconcile.
-module(pertisk_ingress_status_patcher).

-export([maybe_update/2]).

-define(CONDITION_TYPE, <<"Programmed">>).
-define(CONDITION_REASON_OK, <<"Programmed">>).
-define(CONDITION_REASON_RESOURCE, <<"UnsupportedBackendResource">>).

-spec maybe_update([map()], {term(), map()}) -> ok.
maybe_update(Ingresses, Conn) when is_list(Ingresses) ->
    case pertisk_ingress_leader:is_leader() of
        false ->
            ok;
        true ->
            LbIngress = load_balancer_ingress(Conn),
            lists:foreach(
                fun(Ingress) ->
                    patch_one(Ingress, LbIngress, Conn)
                end,
                Ingresses
            ),
            ok
    end;
maybe_update(_, _) ->
    ok.

patch_one(Ingress, LbIngress, Conn) ->
    Meta = maps:get(<<"metadata">>, Ingress, #{}),
    Ns = namespace_of(Meta),
    Name = name_of(Meta),
    HasResource = ingress_has_resource_backend(Ingress),
    Reason = case HasResource of
        true -> ?CONDITION_REASON_RESOURCE;
        false -> ?CONDITION_REASON_OK
    end,
    Status = #{
        <<"status">> => #{
            <<"loadBalancer">> => #{<<"ingress">> => LbIngress},
            <<"conditions">> => [condition(Reason, HasResource)]
        }
    },
    case ekub:patch({ingress, <<"status">>}, Ns, Name, Status, Conn) of
        {ok, _} ->
            ok;
        {error, #{<<"code">> := 404}} ->
            ok;
        {error, Err} ->
            lager:debug("Ingress status patch ~s/~s failed: ~p", [Ns, Name, Err]),
            ok
    end.

condition(?CONDITION_REASON_OK, false) ->
    #{
        <<"type">> => ?CONDITION_TYPE,
        <<"status">> => <<"True">>,
        <<"reason">> => ?CONDITION_REASON_OK,
        <<"message">> => <<"Ingress routes programmed">>,
        <<"lastTransitionTime">> => iso8601_now()
    };
condition(?CONDITION_REASON_RESOURCE, true) ->
    #{
        <<"type">> => ?CONDITION_TYPE,
        <<"status">> => <<"False">>,
        <<"reason">> => ?CONDITION_REASON_RESOURCE,
        <<"message">> => <<
            "Resource backend requires pertisk.io/resource-upstreams annotation "
            "(JSON map: resource name -> host:port)"
        >>,
        <<"lastTransitionTime">> => iso8601_now()
    }.

ingress_has_resource_backend(Ingress) ->
    Spec = maps:get(<<"spec">>, Ingress, #{}),
    Rules = maps:get(<<"rules">>, Spec, []),
    lists:any(fun rule_has_resource_backend/1, Rules).

rule_has_resource_backend(#{<<"http">> := #{<<"paths">> := Paths}}) ->
    lists:any(
        fun(Path) ->
            case maps:get(<<"backend">>, Path, #{}) of
                #{<<"resource">> := _} -> true;
                _ -> false
            end
        end,
        Paths
    );
rule_has_resource_backend(_) ->
    false.

load_balancer_ingress(Conn) ->
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

namespace_of(#{<<"namespace">> := Ns}) when is_binary(Ns) -> Ns;
namespace_of(_) -> <<"default">>.

name_of(#{<<"name">> := Name}) when is_binary(Name) -> Name;
name_of(_) -> <<"unknown">>.

iso8601_now() ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:universal_time(),
    list_to_binary(
        io_lib:format("~4..0w-~2..0w-~2..0wT~2..0w:~2..0w:~2..0wZ", [Y, Mo, D, H, Mi, S])
    ).
