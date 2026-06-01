%% @doc Generic Lego-based ACME DNS issuance fallback for providers not yet natively implemented.
-module(pertisk_eproxy_acme_lego).

-export([obtain_certificate/8, validate_provider/3, provider_to_binary/1, find_lego_executable/0]).

-spec validate_provider(atom() | binary(), map(), string()) -> {ok, map()} | {error, term()}.
validate_provider(Provider, Creds, WorkRoot) when is_map(Creds), is_list(WorkRoot) ->
    case find_lego_executable() of
        false ->
            {error, lego_not_found};
        LegoBin ->
            ProbePath = filename:join([WorkRoot, "lego", "validate"]),
            ok = filelib:ensure_dir(filename:join(ProbePath, "x")),
            case provider_env(Provider, Creds, ProbePath) of
                {ok, EnvPairs} ->
                    {ok, #{lego_path => iolist_to_binary(LegoBin), env_var_count => length(EnvPairs)}};
                {error, _} = E ->
                    E
            end
    end.

-spec obtain_certificate(
    atom() | binary(),
    map(),
    [binary()],
    binary(),
    binary(),
    string(),
    binary(),
    fun((binary(), binary()) -> any())
) -> {ok, binary(), binary()} | {error, term()}.
obtain_certificate(Provider, Creds, Identifiers, ContactEmail, DirectoryUrl, AcmeDataDir, HostSlug, Progress)
when is_map(Creds), is_list(Identifiers), is_binary(ContactEmail), is_binary(DirectoryUrl), is_list(AcmeDataDir), is_binary(HostSlug) ->
    case find_lego_executable() of
        false ->
            {error, lego_not_found};
        LegoBin ->
            LegoPath = filename:join([AcmeDataDir, "lego", binary_to_list(HostSlug)]),
            ok = filelib:ensure_dir(filename:join(LegoPath, "x")),
            case provider_env(Provider, Creds, LegoPath) of
                {error, _} = E ->
                    E;
                {ok, EnvPairs} ->
                    maybe_progress(Progress, <<"lego">>, <<"Starting lego ACME flow">>),
                    Args = lego_args(Provider, ContactEmail, DirectoryUrl, LegoPath, Identifiers, run),
                    case run_lego(LegoBin, Args, EnvPairs, LegoPath) of
                        {ok, _Out} ->
                            maybe_progress(Progress, <<"lego">>, <<"Lego issuance finished; loading certificate files">>),
                            read_issued_certificate(LegoPath, Identifiers);
                        {error, {exit_status, _Code, Out}} ->
                            {error, {lego_failed, Out}};
                        {error, _} = E2 ->
                            E2
                    end
            end
    end.

lego_args(Provider, ContactEmail, DirectoryUrl, LegoPath, Identifiers, Command) ->
    Base = [
        "--accept-tos",
        "--email",
        binary_to_list(ContactEmail),
        "--dns",
        lego_provider_name(Provider),
        "--path",
        LegoPath,
        "--server",
        binary_to_list(DirectoryUrl)
    ],
    DomainArgs = lists:flatmap(fun(D) -> ["--domains", binary_to_list(D)] end, Identifiers),
    Base ++ DomainArgs ++ [atom_to_list(Command)].

provider_to_binary(Provider) when is_atom(Provider) -> atom_to_binary(Provider, utf8);
provider_to_binary(Provider) when is_binary(Provider) -> Provider;
provider_to_binary(Provider) when is_list(Provider) -> unicode:characters_to_binary(Provider, utf8);
provider_to_binary(Provider) -> unicode:characters_to_binary(io_lib:format("~p", [Provider]), utf8).

find_lego_executable() ->
    case os:getenv("PERTISK_LEGO_BIN") of
        false ->
            find_lego_from_path_or_defaults();
        "" ->
            find_lego_from_path_or_defaults();
        Path when is_list(Path) ->
            Trimmed = string:trim(Path),
            case Trimmed of
                "" -> find_lego_from_path_or_defaults();
                _ ->
                    case filelib:is_file(Trimmed) of
                        true -> Trimmed;
                        false -> find_lego_from_path_or_defaults()
                    end
            end
    end.

find_lego_from_path_or_defaults() ->
    case os:find_executable("lego") of
        false ->
            first_existing([
                "/opt/pertisk-eproxy/bin/lego",
                "/usr/local/bin/lego",
                "/usr/bin/lego"
            ]);
        Path ->
            Path
    end.

first_existing([Path | Rest]) ->
    case filelib:is_file(Path) of
        true -> Path;
        false -> first_existing(Rest)
    end;
first_existing([]) ->
    false.

lego_provider_name(route53) -> "route53";
lego_provider_name(godaddy) -> "godaddy";
lego_provider_name(namecheap) -> "namecheap";
lego_provider_name(ovh) -> "ovh";
lego_provider_name(googleclouddns) -> "gcloud";
lego_provider_name(azure) -> "azuredns";
lego_provider_name(rfc2136) -> "rfc2136";
lego_provider_name(cloudns) -> "cloudns";
lego_provider_name(easydns) -> "easydns";
lego_provider_name(dnsmadeeasy) -> "dnsmadeeasy";
lego_provider_name(dynu) -> "dynu";
lego_provider_name(Bin) when is_binary(Bin) -> binary_to_list(string:lowercase(Bin));
lego_provider_name(Other) -> atom_to_list(Other).

provider_env(route53, Creds, _LegoPath) ->
    require_and_collect(Creds, [
        {<<"access_key_id">>, "AWS_ACCESS_KEY_ID"},
        {<<"secret_access_key">>, "AWS_SECRET_ACCESS_KEY"}
    ], [
        {<<"session_token">>, "AWS_SESSION_TOKEN"},
        {<<"region">>, "AWS_REGION"},
        {<<"zone_id">>, "AWS_HOSTED_ZONE_ID"}
    ]);
provider_env(godaddy, Creds, _LegoPath) ->
    require_and_collect(Creds, [
        {<<"api_key">>, "GODADDY_API_KEY"},
        {<<"api_secret">>, "GODADDY_API_SECRET"}
    ], []);
provider_env(namecheap, Creds, _LegoPath) ->
    require_and_collect(Creds, [
        {<<"api_user">>, "NAMECHEAP_API_USER"},
        {<<"api_key">>, "NAMECHEAP_API_KEY"},
        {<<"username">>, "NAMECHEAP_USERNAME"},
        {<<"client_ip">>, "NAMECHEAP_CLIENT_IP"}
    ], []);
provider_env(ovh, Creds, _LegoPath) ->
    require_and_collect(Creds, [
        {<<"application_key">>, "OVH_APPLICATION_KEY"},
        {<<"application_secret">>, "OVH_APPLICATION_SECRET"},
        {<<"consumer_key">>, "OVH_CONSUMER_KEY"}
    ], []);
provider_env(googleclouddns, Creds, LegoPath) ->
    case {cred_get(Creds, [<<"project_id">>]), cred_get(Creds, [<<"service_account_json">>])} of
        {undefined, _} -> {error, missing_project_id};
        {_, undefined} -> {error, missing_service_account_json};
        {ProjectId, Json} ->
            JsonPath = filename:join(LegoPath, "gcloud-service-account.json"),
            ok = file:write_file(JsonPath, Json),
            {ok, [{"GCE_PROJECT", binary_to_list(ProjectId)}, {"GCE_SERVICE_ACCOUNT_FILE", JsonPath}]}
    end;
provider_env(azure, Creds, _LegoPath) ->
    require_and_collect(Creds, [
        {<<"tenant_id">>, "AZURE_TENANT_ID"},
        {<<"client_id">>, "AZURE_CLIENT_ID"},
        {<<"client_secret">>, "AZURE_CLIENT_SECRET"},
        {<<"subscription_id">>, "AZURE_SUBSCRIPTION_ID"},
        {<<"resource_group">>, "AZURE_RESOURCE_GROUP"}
    ], [
        {<<"zone_name">>, "AZURE_ZONE_NAME"}
    ]);
provider_env(rfc2136, Creds, _LegoPath) ->
    require_and_collect(Creds, [
        {<<"nameserver">>, "RFC2136_NAMESERVER"},
        {<<"tsig_key_name">>, "RFC2136_TSIG_KEY"},
        {<<"tsig_secret">>, "RFC2136_TSIG_SECRET"}
    ], [
        {<<"tsig_algorithm">>, "RFC2136_TSIG_ALGORITHM"}
    ]);
provider_env(cloudns, Creds, _LegoPath) ->
    require_and_collect(Creds, [
        {<<"auth_id">>, "CLOUDNS_AUTH_ID"},
        {<<"auth_password">>, "CLOUDNS_AUTH_PASSWORD"}
    ], []);
provider_env(easydns, Creds, _LegoPath) ->
    require_and_collect(Creds, [
        {<<"token">>, "EASYDNS_TOKEN"},
        {<<"key">>, "EASYDNS_KEY"}
    ], []);
provider_env(dnsmadeeasy, Creds, _LegoPath) ->
    require_and_collect(Creds, [
        {<<"api_key">>, "DNSMADEEASY_API_KEY"},
        {<<"secret_key">>, "DNSMADEEASY_API_SECRET"}
    ], []);
provider_env(dynu, Creds, _LegoPath) ->
    require_and_collect(Creds, [
        {<<"api_token">>, "DYNU_API_TOKEN"}
    ], []);
provider_env(customlego, Creds, _LegoPath) ->
    custom_provider_env(Creds);
provider_env(_Other, Creds, _LegoPath) ->
    custom_provider_env(Creds).

custom_provider_env(Creds) ->
    case cred_get(Creds, [<<"env_vars_json">>, <<"envVarsJson">>]) of
        undefined ->
            case generic_env_from_credentials(Creds) of
                [] -> {error, missing_env_vars_json};
                Env -> {ok, Env}
            end;
        JsonBin ->
            case thoas:decode(JsonBin) of
                {ok, Map} when is_map(Map) ->
                    {ok, env_from_map(Map)};
                {ok, _Other} ->
                    {error, invalid_env_vars_json};
                {error, _} ->
                    {error, invalid_env_vars_json}
            end
    end.

generic_env_from_credentials(Creds) ->
    Pairs = maps:to_list(Creds),
    lists:reverse(
        lists:foldl(
            fun({K, V0}, Acc) ->
                KeyBin =
                    case K of
                        KB when is_binary(KB) -> KB;
                        KL when is_list(KL) -> unicode:characters_to_binary(KL, utf8);
                        _ -> <<>>
                    end,
                case {is_env_key(KeyBin), credential_value_to_string(V0)} of
                    {true, {ok, V}} ->
                        [{binary_to_list(KeyBin), V} | Acc];
                    _ ->
                        Acc
                end
            end,
            [],
            Pairs
        )
    ).

env_from_map(Map) ->
    lists:reverse(
        lists:foldl(
            fun({K, V0}, Acc) ->
                KeyBin =
                    case K of
                        KB when is_binary(KB) -> KB;
                        KL when is_list(KL) -> unicode:characters_to_binary(KL, utf8);
                        _ -> <<>>
                    end,
                case credential_value_to_string(V0) of
                    {ok, V} when byte_size(KeyBin) > 0 ->
                        [{binary_to_list(KeyBin), V} | Acc];
                    _ ->
                        Acc
                end
            end,
            [],
            maps:to_list(Map)
        )
    ).

is_env_key(<<>>) ->
    false;
is_env_key(Bin) when is_binary(Bin) ->
    lists:all(
        fun(C) ->
            (C >= $A andalso C =< $Z) orelse
                (C >= $0 andalso C =< $9) orelse
                C =:= $_
        end,
        binary_to_list(Bin)
    ).

credential_value_to_string(V) when is_binary(V), byte_size(V) > 0 -> {ok, binary_to_list(V)};
credential_value_to_string(V) when is_list(V), length(V) > 0 -> {ok, V};
credential_value_to_string(V) when is_integer(V) -> {ok, integer_to_list(V)};
credential_value_to_string(V) when is_float(V) -> {ok, lists:flatten(io_lib:format("~p", [V]))};
credential_value_to_string(_) -> error.

require_and_collect(Creds, Required, Optional) ->
    case collect_required(Creds, Required, []) of
        {error, _} = E ->
            E;
        {ok, ReqEnv} ->
            {ok, ReqEnv ++ collect_optional(Creds, Optional, [])}
    end.

collect_required(_Creds, [], Acc) ->
    {ok, lists:reverse(Acc)};
collect_required(Creds, [{Key, EnvName} | Rest], Acc) ->
    case cred_get(Creds, [Key, camel_key(Key)]) of
        undefined -> {error, {missing_credential, Key}};
        Val -> collect_required(Creds, Rest, [{EnvName, binary_to_list(Val)} | Acc])
    end.

collect_optional(_Creds, [], Acc) ->
    lists:reverse(Acc);
collect_optional(Creds, [{Key, EnvName} | Rest], Acc) ->
    case cred_get(Creds, [Key, camel_key(Key)]) of
        undefined -> collect_optional(Creds, Rest, Acc);
        Val -> collect_optional(Creds, Rest, [{EnvName, binary_to_list(Val)} | Acc])
    end.

camel_key(Bin) when is_binary(Bin) ->
    Parts = binary:split(Bin, <<"_">>, [global]),
    case Parts of
        [] -> Bin;
        [H | T] ->
            Tail = [capitalize(P) || P <- T],
            iolist_to_binary([H | Tail])
    end.

capitalize(<<>>) -> <<>>;
capitalize(<<C, Rest/binary>>) when C >= $a, C =< $z -> <<(C - 32), Rest/binary>>;
capitalize(B) -> B.

cred_get(C, Keys) ->
    lists:foldl(
        fun(K, undefined) ->
            case maps:find(K, C) of
                {ok, V} when is_binary(V), byte_size(V) > 0 -> V;
                {ok, V} when is_list(V), length(V) > 0 -> unicode:characters_to_binary(V, utf8);
                _ -> undefined
            end;
            (_, Acc) ->
                Acc
        end,
        undefined,
        Keys
    ).

run_lego(LegoBin, Args, EnvPairs, WorkDir) ->
    Port = open_port(
        {spawn_executable, LegoBin},
        [binary, exit_status, use_stdio, stderr_to_stdout, hide, {cd, WorkDir}, {env, EnvPairs}, {args, Args}]
    ),
    gather_port_output(Port, []).

gather_port_output(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            gather_port_output(Port, [Data | Acc]);
        {Port, {exit_status, 0}} ->
            {ok, iolist_to_binary(lists:reverse(Acc))};
        {Port, {exit_status, Code}} ->
            {error, {exit_status, Code, iolist_to_binary(lists:reverse(Acc))}}
    after 600000 ->
        port_close(Port),
        {error, lego_timeout}
    end.

read_issued_certificate(LegoPath, _Identifiers) ->
    CertDir = filename:join(LegoPath, "certificates"),
    Crts0 = filelib:wildcard(filename:join(CertDir, "*.crt")),
    Crts = [C || C <- Crts0, not lists:suffix(".issuer.crt", C)],
    case Crts of
        [] ->
            {error, {lego_no_certificate_files, CertDir}};
        [First | _] ->
            Base = filename:rootname(First, ".crt"),
            KeyPath = Base ++ ".key",
            case {file:read_file(First), file:read_file(KeyPath)} of
                {{ok, Pem}, {ok, Key}} -> {ok, Pem, Key};
                {E1, E2} -> {error, {lego_read_failed, First, E1, KeyPath, E2}}
            end
    end.

maybe_progress(Progress, Phase, Msg) when is_function(Progress, 2) ->
    _ = catch Progress(Phase, Msg),
    ok;
maybe_progress(_, _, _) ->
    ok.
