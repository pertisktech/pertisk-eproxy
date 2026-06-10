-module(pertisk_ingress_reconciler_tests).

-include_lib("eunit/include/eunit.hrl").

ingress_matches_class_by_spec_test() ->
    Ingress = #{
        <<"metadata">> => #{},
        <<"spec">> => #{<<"ingressClassName">> => <<"pertisk-eproxy">>}
    },
    ?assert(pertisk_ingress_reconciler:ingress_matches_class(Ingress, {ok, <<"pertisk-eproxy">>})),
    ?assertNot(pertisk_ingress_reconciler:ingress_matches_class(Ingress, {ok, <<"other">>})),
    ?assert(pertisk_ingress_reconciler:ingress_matches_class(Ingress, all)).

ingress_matches_class_by_annotation_test() ->
    Ingress = #{
        <<"metadata">> => #{
            <<"annotations">> => #{<<"kubernetes.io/ingress.class">> => <<"legacy-class">>}
        },
        <<"spec">> => #{}
    },
    ?assert(pertisk_ingress_reconciler:ingress_matches_class(Ingress, {ok, <<"legacy-class">>})).

reconcile_empty_lists_test() ->
    {ok, Result} = pertisk_ingress_reconciler:reconcile([], []),
    ?assertEqual([], maps:get(sites, Result)),
    ?assertEqual([], maps:get(backends, Result)),
    ?assertEqual([], maps:get(tls, Result)).

reconcile_skips_wrong_class_test() ->
    Ingress = #{
        <<"metadata">> => #{<<"name">> => <<"x">>},
        <<"spec">> => #{<<"ingressClassName">> => <<"other">>},
        <<"rules">> => []
    },
    {ok, Result} = pertisk_ingress_reconciler:reconcile([Ingress], []),
    ?assertEqual([], maps:get(sites, Result)).
