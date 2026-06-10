-module(pertisk_eproxy_tls_paths_tests).

-include_lib("eunit/include/eunit.hrl").

default_cert_file_under_priv_test() ->
    Path = pertisk_eproxy_tls_paths:default_cert_file(),
    ?assert(lists:suffix("tls/listener.pem", Path)).

default_key_file_under_priv_test() ->
    Path = pertisk_eproxy_tls_paths:default_key_file(),
    ?assert(lists:suffix("tls/listener.key", Path)).

resolve_cert_file_explicit_binary_test() ->
    ?assertEqual("/tmp/cert.pem", pertisk_eproxy_tls_paths:resolve_cert_file(#{tls_cert_file => <<"/tmp/cert.pem">>})).

resolve_key_file_explicit_list_test() ->
    ?assertEqual("/tmp/key.pem", pertisk_eproxy_tls_paths:resolve_key_file(#{tls_key_file => "/tmp/key.pem"})).

resolve_cert_file_null_is_undefined_test() ->
    ?assertEqual(undefined, pertisk_eproxy_tls_paths:resolve_cert_file(#{tls_cert_file => null})).

resolve_cert_file_invalid_type_test() ->
    ?assertEqual(undefined, pertisk_eproxy_tls_paths:resolve_cert_file(#{tls_cert_file => 42})).

resolve_cert_file_undefined_config_uses_packaged_or_none_test() ->
    Result = pertisk_eproxy_tls_paths:resolve_cert_file(undefined),
    ?assert(Result =:= undefined orelse is_list(Result)).

resolve_key_file_explicit_binary_test() ->
    ?assertEqual("/tmp/key.pem", pertisk_eproxy_tls_paths:resolve_key_file(#{tls_key_file => <<"/tmp/key.pem">>})).

resolve_both_from_config_test() ->
    C = #{tls_cert_file => <<"/c.pem">>, tls_key_file => <<"/k.pem">>},
    ?assertEqual("/c.pem", pertisk_eproxy_tls_paths:resolve_cert_file(C)),
    ?assertEqual("/k.pem", pertisk_eproxy_tls_paths:resolve_key_file(C)).

resolve_empty_map_uses_defaults_test() ->
    Cert = pertisk_eproxy_tls_paths:resolve_cert_file(#{}),
    Key = pertisk_eproxy_tls_paths:resolve_key_file(#{}),
    ?assert((Cert =:= undefined orelse is_list(Cert)) andalso (Key =:= undefined orelse is_list(Key))).

with_ingress_env(Fun) ->
    OldMode = os:getenv("PERTISK_MODE"),
    os:putenv("PERTISK_MODE", "ingress"),
    try Fun() after
        case OldMode of
            false -> os:unsetenv("PERTISK_MODE");
            V -> os:putenv("PERTISK_MODE", V)
        end
    end.

with_proxy_env(Fun) ->
    OldMode = os:getenv("PERTISK_MODE"),
    os:putenv("PERTISK_MODE", "proxy"),
    try Fun() after
        case OldMode of
            false -> os:unsetenv("PERTISK_MODE");
            V -> os:putenv("PERTISK_MODE", V)
        end
    end.

resolve_cert_file_ingress_mode_returns_undefined_test() ->
    with_ingress_env(fun() ->
        ?assertEqual(undefined, pertisk_eproxy_tls_paths:resolve_cert_file(#{tls_cert_file => undefined}))
    end).

resolve_cert_file_non_map_ingress_mode_test() ->
    with_ingress_env(fun() ->
        ?assertEqual(undefined, pertisk_eproxy_tls_paths:resolve_cert_file(undefined))
    end).

resolve_key_file_ingress_mode_returns_undefined_test() ->
    with_ingress_env(fun() ->
        ?assertEqual(undefined, pertisk_eproxy_tls_paths:resolve_key_file(#{tls_key_file => undefined}))
    end).

resolve_key_file_non_map_ingress_mode_test() ->
    with_ingress_env(fun() ->
        ?assertEqual(undefined, pertisk_eproxy_tls_paths:resolve_key_file(undefined))
    end).

resolve_key_file_non_map_proxy_mode_test() ->
    with_proxy_env(fun() ->
        Result = pertisk_eproxy_tls_paths:resolve_key_file(undefined),
        ?assert(is_list(Result))
    end).

default_if_readable_missing_packaged_file_test() ->
    Pem = pertisk_eproxy_tls_paths:default_cert_file(),
    Bak = Pem ++ ".cover_bak",
    HadFile = filelib:is_file(Pem),
    case HadFile of
        true -> ok = file:rename(Pem, Bak);
        false -> ok
    end,
    try
        with_proxy_env(fun() ->
            ?assertEqual(undefined, pertisk_eproxy_tls_paths:resolve_cert_file(#{tls_cert_file => undefined}))
        end)
    after
        case HadFile of
            true -> ok = file:rename(Bak, Pem);
            false -> ok
        end
    end.
