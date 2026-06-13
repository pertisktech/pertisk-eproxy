%% @doc Patch Gateway API GatewayClass .status (Accepted condition).
-module(pertisk_gateway_class_status).

-export([maybe_update/1]).

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
                    patch_accepted(Conn)
            end
    end.

patch_accepted(Conn) ->
    case gateway_class_name() of
        error ->
            ok;
        {ok, Name} ->
            patch_status(Name, Conn)
    end.

gateway_class_name() ->
    case pertisk_ingress_env:ingress_class() of
        {ok, C} when is_binary(C), byte_size(C) > 0 ->
            {ok, C};
        _ ->
            error
    end.

patch_status(Name, Conn) ->
    Endpoint = ekub_api:endpoint(
        <<"gateway.networking.k8s.io">>,
        <<"v1">>,
        <<"gatewayclasses">>,
        <<>>,
        Name,
        <<"status">>
    ),
    Body = #{
        <<"status">> => #{
            <<"conditions">> => [accepted_condition()]
        }
    },
    case pertisk_ingress_ekub:merge_patch(Endpoint, Body, Conn) of
        {ok, _} ->
            lager:info("GatewayClass ~s status Accepted=True", [Name]),
            ok;
        {error, #{<<"code">> := 404}} ->
            ok;
        {error, Err} ->
            lager:warning("GatewayClass status patch ~s failed: ~p", [Name, Err]),
            ok
    end.

accepted_condition() ->
    #{
        <<"type">> => <<"Accepted">>,
        <<"status">> => <<"True">>,
        <<"reason">> => <<"Accepted">>,
        <<"message">> => <<"GatewayClass accepted by pertisk-eproxy controller">>,
        <<"lastTransitionTime">> => iso8601_now()
    }.

iso8601_now() ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:universal_time(),
    list_to_binary(
        io_lib:format("~4..0w-~2..0w-~2..0wT~2..0w:~2..0w:~2..0wZ", [Y, Mo, D, H, Mi, S])
    ).
