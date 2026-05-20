%%% Mnesia database module for proxy configuration.
%%% Tables: runtime_state, sites, certificates, dns_providers, admin_users
-module(pertisk_eproxy_db).
-export([
    init/1,
    get_config/1,
    get_runtime_config/1,
    put_runtime_config/2,
    list_certificates/1,
    insert_certificate/2,
    insert_certificate_pem/4,
    insert_certificate_pem/5,
    upsert_acme_certificate_pem/4,
    update_certificate_pem/4,
    update_certificate/3,
    delete_certificate/2,
    ensure_certificates_seeded/2,
    list_dns_providers/1,
    insert_dns_provider/4,
    update_dns_provider/5,
    delete_dns_provider/2,
    ensure_dns_providers_seeded/2,
    get_site/2,
    list_sites/1,
    insert_site/4,
    delete_site/2,
    get_backend/2,
    list_backends/1,
    insert_backend/5,
    insert_upstream/4,
    delete_backend/2,
    ensure_admin_users/1,
    verify_admin_login/3
]).

-include("pertisk_eproxy_db_records.hrl").
-include_lib("lager/include/lager.hrl").

-define(IGNORE_DB_PATH, _DbPath).

%% @doc Initialize Mnesia under `Dir` (same argument as legacy `db_file` / `mnesia_dir`).
%% Returns `{ok, Dir}` for API compatibility.
-spec init(string()) -> {ok, string()} | {error, term()}.
init(Dir0) ->
    Dir = normalize_storage_dir(Dir0),
    case storage_path_is_plain_file(Dir) of
        true ->
            lager:error("Mnesia dir ~s is a file, expected a directory", [Dir]),
            {error, is_file};
        false ->
            init_mnesia_dir(Dir)
    end.

%% `filelib:is_regular_file/1` exists only from OTP 23+.
storage_path_is_plain_file(Path) when is_list(Path) ->
    filelib:is_file(Path) andalso not filelib:is_dir(Path).

%% Legacy `db_file` pointed at `data/proxy.db` (SQLite file); Mnesia uses a directory.
normalize_storage_dir(Dir) when is_list(Dir) ->
    case filename:extension(Dir) of
        ".db" -> filename:join(filename:dirname(Dir), "mnesia");
        _ -> Dir
    end;
normalize_storage_dir(Dir) when is_binary(Dir) ->
    normalize_storage_dir(binary_to_list(Dir)).

init_mnesia_dir(Dir) ->
    case pertisk_eproxy_mnesia:ensure_started(Dir) of
        ok ->
            _ = ensure_admin_users(Dir),
            lager:info("Mnesia database initialized at ~s", [Dir]),
            {ok, Dir};
        {error, Reason} ->
            lager:error("Failed to initialize Mnesia: ~p", [Reason]),
            {error, Reason}
    end.

%% ---------------------------------------------------------------------------
%% Runtime config
%% ---------------------------------------------------------------------------

-spec get_runtime_config(string()) -> {ok, map()} | not_found | {error, term()}.
get_runtime_config(?IGNORE_DB_PATH) ->
    case txn_read(fun() -> mnesia:read(pertisk_eproxy_runtime_state, runtime_config) end) of
        {ok, []} ->
            not_found;
        {ok, [#pertisk_eproxy_runtime_state{value = V}]} ->
            decode_runtime_value(V);
        {error, Reason} ->
            {error, Reason}
    end.

-spec put_runtime_config(string(), map()) -> ok | {error, term()}.
put_runtime_config(?IGNORE_DB_PATH, Config) when is_map(Config) ->
    Enc = base64:encode(term_to_binary(Config)),
    case txn_write(fun() ->
        mnesia:write(#pertisk_eproxy_runtime_state{key = runtime_config, value = Enc}),
        sync_sites_projection_tx(Config)
    end) of
        {ok, ok} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

sync_sites_projection_tx(Config) ->
    Sites = maps:get(sites, Config, []),
    %% `mnesia:clear_table/1` runs its own transaction — cannot call inside `txn_write`.
    lists:foreach(
        fun(Rec) -> mnesia:delete_object(Rec) end,
        mnesia:match_object(#pertisk_eproxy_site{_ = '_'})
    ),
    lists:foreach(fun(S) -> write_site_projection(S) end, Sites),
    ok.

write_site_projection(S) when is_map(S) ->
    Host = as_bin(maps:get(host, S, <<>>)),
    mnesia:write(
        #pertisk_eproxy_site{
            host = Host,
            backend = as_bin(maps:get(backend, S, <<>>)),
            certificate = as_bin(opt_text(maps:get(certificate, S, undefined))),
            dns_provider = as_bin(opt_text(maps:get(dns_provider, S, undefined))),
            challenge_type = as_bin(opt_text(maps:get(challenge_type, S, undefined))),
            wildcard = bool_to_int(maps:get(wildcard, S, false)),
            acme_wildcard_base = as_bin(opt_text(maps:get(acme_wildcard_base, S, undefined))),
            advertise_http3 = bool_to_int(maps:get(advertise_http3, S, true)),
            acme_contact_email = as_bin(opt_text(maps:get(acme_contact_email, S, undefined))),
            routes_json = thoas:encode(maps:get(routes, S, []))
        }
    );
write_site_projection(_) ->
    ok.

%% ---------------------------------------------------------------------------
%% Admin users
%% ---------------------------------------------------------------------------

-spec ensure_admin_users(string()) -> ok | {error, term()}.
ensure_admin_users(?IGNORE_DB_PATH) ->
    case txn_read(fun() -> mnesia:all_keys(pertisk_eproxy_admin_user) end) of
        {ok, []} ->
            seed_default_admin_user();
        {ok, _} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

seed_default_admin_user() ->
    Salt = crypto:strong_rand_bytes(16),
    Pass = <<"admin">>,
    Hash = crypto:hash(sha256, <<Salt/binary, Pass/binary>>),
    Rec = #pertisk_eproxy_admin_user{
        username = <<"admin">>,
        salt_b64 = base64:encode(Salt),
        pass_hash_b64 = base64:encode(Hash)
    },
    case txn_write(fun() -> mnesia:write(Rec) end) of
        {ok, ok} ->
            lager:info("Seeded default local admin user (username: admin)", []),
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

-spec verify_admin_login(string(), binary(), binary()) -> ok | {error, invalid_credentials | term()}.
verify_admin_login(?IGNORE_DB_PATH, Username, Password)
    when is_binary(Username), is_binary(Password) ->
    case txn_read(fun() -> mnesia:read(pertisk_eproxy_admin_user, Username) end) of
        {ok, []} ->
            {error, invalid_credentials};
        {ok, [#pertisk_eproxy_admin_user{salt_b64 = SaltB64, pass_hash_b64 = WantB64}]} ->
            try
                Salt = base64:decode(SaltB64),
                Want = base64:decode(WantB64),
                Got = crypto:hash(sha256, <<Salt/binary, Password/binary>>),
                case crypto:hash_equals(Want, Got) of
                    true -> ok;
                    false -> {error, invalid_credentials}
                end
            catch
                _:_ -> {error, invalid_credentials}
            end;
        {error, Reason} ->
            {error, Reason}
    end;
verify_admin_login(_DbPath, _, _) ->
    {error, invalid_credentials}.

%% ---------------------------------------------------------------------------
%% Certificates
%% ---------------------------------------------------------------------------

-spec list_certificates(string()) -> {ok, [map()]} | {error, term()}.
list_certificates(?IGNORE_DB_PATH) ->
    case txn_read(fun() -> table_records(pertisk_eproxy_certificate) end) of
        {ok, Rows} ->
            Sorted = lists:sort(fun(A, B) -> A#pertisk_eproxy_certificate.id =< B#pertisk_eproxy_certificate.id end, Rows),
            {ok, [certificate_to_map(R) || R <- Sorted]};
        {error, Reason} ->
            {error, Reason}
    end.

certificate_to_map(#pertisk_eproxy_certificate{} = R) ->
    #{
        id => R#pertisk_eproxy_certificate.id,
        name => R#pertisk_eproxy_certificate.name,
        cert_pem => nonempty_or_undefined(R#pertisk_eproxy_certificate.cert_pem),
        key_pem => nonempty_or_undefined(R#pertisk_eproxy_certificate.key_pem),
        source_type => R#pertisk_eproxy_certificate.source_type
    }.

nonempty_or_undefined(<<>>) -> undefined;
nonempty_or_undefined(B) when is_binary(B) -> B;
nonempty_or_undefined(_) -> undefined.

-spec insert_certificate(string(), binary() | list()) -> {ok, integer()} | {error, term()}.
insert_certificate(?IGNORE_DB_PATH, Name0) ->
    Name = as_bin(string:trim(to_list(Name0))),
    case Name of
        <<>> -> {error, empty_name};
        _ ->
            case txn_write(fun() -> insert_certificate_tx(Name, <<>>, <<>>, <<"acme">>) end) of
                {ok, {ok, Id}} -> {ok, Id};
                {error, {unique_violation, name}} -> {error, {unique_violation, name}};
                {error, Reason} -> {error, Reason}
            end
    end.

insert_certificate_tx(Name, CertPem, KeyPem, SourceType) ->
    case mnesia:index_read(pertisk_eproxy_certificate, Name, #pertisk_eproxy_certificate.name) of
        [_ | _] ->
            mnesia:abort({unique_violation, name});
        [] ->
            Id = next_id(certificate),
            mnesia:write(
                #pertisk_eproxy_certificate{
                    id = Id,
                    name = Name,
                    cert_pem = CertPem,
                    key_pem = KeyPem,
                    source_type = SourceType
                }
            ),
            {ok, Id}
    end.

-spec insert_certificate_pem(string(), binary() | list(), binary() | list(), binary() | list()) ->
    {ok, integer()} | {error, term()}.
insert_certificate_pem(DbPath, Name0, CertFile0, KeyFile0) ->
    insert_certificate_pem(DbPath, Name0, CertFile0, KeyFile0, <<"imported_pem">>).

-spec insert_certificate_pem(string(), binary() | list(), binary() | list(), binary() | list(), binary() | list()) ->
    {ok, integer()} | {error, term()}.
insert_certificate_pem(?IGNORE_DB_PATH, Name0, CertFile0, KeyFile0, SourceType0) ->
    Name = as_bin(string:trim(to_list(Name0))),
    CertPem = as_bin(read_file_text(string:trim(to_list(CertFile0)))),
    KeyPem = as_bin(read_file_text(string:trim(to_list(KeyFile0)))),
    SourceType = as_bin(to_list(SourceType0)),
    case {Name, CertPem, KeyPem} of
        {<<>>, _, _} -> {error, empty_name};
        {_, <<>>, _} -> {error, empty_cert_file};
        {_, _, <<>>} -> {error, empty_key_file};
        _ ->
            case txn_write(fun() -> insert_certificate_tx(Name, CertPem, KeyPem, SourceType) end) of
                {ok, {ok, Id}} -> {ok, Id};
                {ok, {error, _} = E} -> E;
                {error, Reason} -> {error, Reason}
            end
    end.

-spec upsert_acme_certificate_pem(string(), binary() | list(), binary() | list(), binary() | list()) ->
    {ok, integer()} | {error, term()}.
upsert_acme_certificate_pem(?IGNORE_DB_PATH, Name0, CertFile0, KeyFile0) ->
    Name = as_bin(string:trim(to_list(Name0))),
    CertPem = as_bin(read_file_text(string:trim(to_list(CertFile0)))),
    KeyPem = as_bin(read_file_text(string:trim(to_list(KeyFile0)))),
    case {Name, CertPem, KeyPem} of
        {<<>>, _, _} -> {error, empty_name};
        {_, <<>>, _} -> {error, empty_cert_file};
        {_, _, <<>>} -> {error, empty_key_file};
        _ ->
            case txn_write(fun() ->
                case mnesia:index_read(pertisk_eproxy_certificate, Name, #pertisk_eproxy_certificate.name) of
                    [#pertisk_eproxy_certificate{id = Id} = Rec | _] ->
                        mnesia:write(
                            Rec#pertisk_eproxy_certificate{
                                cert_pem = CertPem,
                                key_pem = KeyPem,
                                source_type = <<"acme">>
                            }
                        ),
                        {ok, Id};
                    [] ->
                        insert_certificate_tx(Name, CertPem, KeyPem, <<"acme">>)
                end
            end) of
                {ok, {ok, Id}} -> {ok, Id};
                {ok, {error, _} = E} -> E;
                {error, Reason} -> {error, Reason}
            end
    end.

-spec update_certificate_pem(string(), integer(), binary() | list(), binary() | list()) -> ok | {error, term()}.
update_certificate_pem(?IGNORE_DB_PATH, Id, CertFile0, KeyFile0) ->
    CertPem = as_bin(read_file_text(string:trim(to_list(CertFile0)))),
    KeyPem = as_bin(read_file_text(string:trim(to_list(KeyFile0)))),
    case {CertPem, KeyPem} of
        {<<>>, _} -> {error, empty_cert_file};
        {_, <<>>} -> {error, empty_key_file};
        _ ->
            case txn_write(fun() ->
                case mnesia:read(pertisk_eproxy_certificate, Id) of
                    [] -> mnesia:abort(not_found);
                    [Rec | _] ->
                        mnesia:write(
                            Rec#pertisk_eproxy_certificate{
                                cert_pem = CertPem,
                                key_pem = KeyPem,
                                source_type = <<"imported_pem">>
                            }
                        ),
                        ok
                end
            end) of
                {ok, ok} -> ok;
                {error, {aborted, not_found}} -> {error, not_found};
                {error, Reason} -> {error, Reason}
            end
    end.

-spec update_certificate(string(), integer(), binary() | list()) -> ok | {error, term()}.
update_certificate(?IGNORE_DB_PATH, Id, Name0) ->
    Name = as_bin(string:trim(to_list(Name0))),
    case Name of
        <<>> -> {error, empty_name};
        _ ->
            case txn_write(fun() ->
                case mnesia:read(pertisk_eproxy_certificate, Id) of
                    [] -> mnesia:abort(not_found);
                    [Rec | _] ->
                        case mnesia:index_read(pertisk_eproxy_certificate, Name, #pertisk_eproxy_certificate.name) of
                            [#pertisk_eproxy_certificate{id = OtherId}] when OtherId =/= Id ->
                                mnesia:abort({unique_violation, name});
                            _ ->
                                mnesia:write(Rec#pertisk_eproxy_certificate{name = Name}),
                                ok
                        end
                end
            end) of
                {ok, ok} -> ok;
                {error, {aborted, not_found}} -> {error, not_found};
                {error, {aborted, {unique_violation, name}}} -> {error, {unique_violation, name}};
                {error, Reason} -> {error, Reason}
            end
    end.

-spec delete_certificate(string(), integer()) -> ok | {error, term()}.
delete_certificate(?IGNORE_DB_PATH, Id) ->
    case txn_write(fun() ->
        case mnesia:read(pertisk_eproxy_certificate, Id) of
            [] -> mnesia:abort(not_found);
            [Rec | _] ->
                mnesia:delete_object(Rec),
                ok
        end
    end) of
        {ok, ok} -> ok;
        {error, {aborted, not_found}} -> {error, not_found};
        {error, Reason} -> {error, Reason}
    end.

-spec ensure_certificates_seeded(string(), [binary() | list()]) -> ok | {error, term()}.
ensure_certificates_seeded(?IGNORE_DB_PATH, Names) ->
    lists:foreach(
        fun(N0) ->
            N = as_bin(string:trim(to_list(N0))),
            case N of
                <<>> ->
                    ok;
                _ ->
                    _ = txn_write(fun() ->
                        case mnesia:index_read(pertisk_eproxy_certificate, N, #pertisk_eproxy_certificate.name) of
                            [_ | _] -> ok;
                            [] -> {ok, _} = insert_certificate_tx(N, <<>>, <<>>, <<"acme">>), ok
                        end
                    end),
                    ok
            end
        end,
        Names
    ),
    ok.

%% ---------------------------------------------------------------------------
%% DNS providers
%% ---------------------------------------------------------------------------

-spec list_dns_providers(string()) -> {ok, [map()]} | {error, term()}.
list_dns_providers(?IGNORE_DB_PATH) ->
    case txn_read(fun() -> table_records(pertisk_eproxy_dns_provider) end) of
        {ok, Rows} ->
            Sorted = lists:sort(fun(A, B) -> A#pertisk_eproxy_dns_provider.id =< B#pertisk_eproxy_dns_provider.id end, Rows),
            {ok, [dns_row_to_map(R) || R <- Sorted]};
        {error, Reason} ->
            {error, Reason}
    end.

dns_row_to_map(#pertisk_eproxy_dns_provider{} = R) ->
    Creds =
        case thoas:decode(R#pertisk_eproxy_dns_provider.credentials_json) of
            {ok, M} when is_map(M) -> M;
            _ -> #{}
        end,
    #{
        id => R#pertisk_eproxy_dns_provider.id,
        name => R#pertisk_eproxy_dns_provider.name,
        provider_type => R#pertisk_eproxy_dns_provider.provider_type,
        credentials => Creds
    }.

-spec insert_dns_provider(string(), binary() | list(), binary() | list(), map()) -> {ok, integer()} | {error, term()}.
insert_dns_provider(?IGNORE_DB_PATH, Name0, ProviderType0, Credentials) ->
    Name = as_bin(string:trim(to_list(Name0))),
    Pt = as_bin(string:trim(to_list(ProviderType0))),
    Cj = thoas:encode(Credentials),
    case {Name, Pt} of
        {<<>>, _} -> {error, empty_name};
        {_, <<>>} -> {error, empty_provider_type};
        _ ->
            case txn_write(fun() -> insert_dns_provider_tx(Name, Pt, Cj) end) of
                {ok, {ok, Id}} -> {ok, Id};
                {ok, {error, _} = E} -> E;
                {error, Reason} -> {error, Reason}
            end
    end.

insert_dns_provider_tx(Name, Pt, Cj) ->
    case mnesia:index_read(pertisk_eproxy_dns_provider, Name, #pertisk_eproxy_dns_provider.name) of
        [_ | _] ->
            mnesia:abort({unique_violation, name});
        [] ->
            Id = next_id(dns_provider),
            mnesia:write(
                #pertisk_eproxy_dns_provider{
                    id = Id,
                    name = Name,
                    provider_type = Pt,
                    credentials_json = Cj
                }
            ),
            {ok, Id}
    end.

-spec update_dns_provider(string(), integer(), binary() | list(), binary() | list(), map()) -> ok | {error, term()}.
update_dns_provider(?IGNORE_DB_PATH, Id, Name0, ProviderType0, Credentials) ->
    Name = as_bin(string:trim(to_list(Name0))),
    Pt = as_bin(string:trim(to_list(ProviderType0))),
    Cj = thoas:encode(Credentials),
    case {Name, Pt} of
        {<<>>, _} -> {error, empty_name};
        {_, <<>>} -> {error, empty_provider_type};
        _ ->
            case txn_write(fun() ->
                case mnesia:read(pertisk_eproxy_dns_provider, Id) of
                    [] -> mnesia:abort(not_found);
                    [Rec | _] ->
                        case mnesia:index_read(pertisk_eproxy_dns_provider, Name, #pertisk_eproxy_dns_provider.name) of
                            [#pertisk_eproxy_dns_provider{id = OtherId}] when OtherId =/= Id ->
                                mnesia:abort({unique_violation, name});
                            _ ->
                                mnesia:write(
                                    Rec#pertisk_eproxy_dns_provider{
                                        name = Name,
                                        provider_type = Pt,
                                        credentials_json = Cj
                                    }
                                ),
                                ok
                        end
                end
            end) of
                {ok, ok} -> ok;
                {error, {aborted, not_found}} -> {error, not_found};
                {error, Reason} -> {error, Reason}
            end
    end.

-spec delete_dns_provider(string(), integer()) -> ok | {error, term()}.
delete_dns_provider(?IGNORE_DB_PATH, Id) ->
    case txn_write(fun() ->
        case mnesia:read(pertisk_eproxy_dns_provider, Id) of
            [] -> mnesia:abort(not_found);
            [Rec | _] ->
                mnesia:delete_object(Rec),
                ok
        end
    end) of
        {ok, ok} -> ok;
        {error, {aborted, not_found}} -> {error, not_found};
        {error, Reason} -> {error, Reason}
    end.

-spec ensure_dns_providers_seeded(string(), [map()]) -> ok | {error, term()}.
ensure_dns_providers_seeded(?IGNORE_DB_PATH, Providers) ->
    lists:foreach(
        fun(P0) ->
            P =
                case P0 of
                    #{name := _} -> P0;
                    _ -> #{}
                end,
            Name = as_bin(string:trim(to_list(maps:get(name, P, "")))),
            Pt = as_bin(string:trim(to_list(maps:get(provider_type, P, "label")))),
            Cred =
                case maps:get(credentials, P, #{}) of
                    M when is_map(M) -> M;
                    _ -> #{}
                end,
            case Name of
                <<>> ->
                    ok;
                _ ->
                    Cj = thoas:encode(Cred),
                    _ = txn_write(fun() ->
                        case mnesia:index_read(pertisk_eproxy_dns_provider, Name, #pertisk_eproxy_dns_provider.name) of
                            [_ | _] -> ok;
                            [] -> {ok, _} = insert_dns_provider_tx(Name, Pt, Cj), ok
                        end
                    end),
                    ok
            end
        end,
        Providers
    ),
    ok.

%% ---------------------------------------------------------------------------
%% Sites / backends (legacy normalized tables — runtime config is primary)
%% ---------------------------------------------------------------------------

get_config(?IGNORE_DB_PATH) ->
    case list_sites(?IGNORE_DB_PATH) of
        {ok, Sites} ->
            case list_backends(?IGNORE_DB_PATH) of
                {ok, Backends} ->
                    {ok, #{sites => Sites, backends => Backends}};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

get_site(?IGNORE_DB_PATH, Host) ->
    H = as_bin(Host),
    case txn_read(fun() -> mnesia:read(pertisk_eproxy_site, H) end) of
        {ok, []} -> {error, not_found};
        {ok, [Rec | _]} -> {ok, site_to_map(Rec)};
        {error, Reason} -> {error, Reason}
    end.

list_sites(?IGNORE_DB_PATH) ->
    case txn_read(fun() -> table_records(pertisk_eproxy_site) end) of
        {ok, Rows} ->
            Sorted = lists:sort(fun(A, B) -> A#pertisk_eproxy_site.host =< B#pertisk_eproxy_site.host end, Rows),
            {ok, [site_to_map(R) || R <- Sorted]};
        {error, Reason} ->
            {error, Reason}
    end.

site_to_map(#pertisk_eproxy_site{} = S) ->
    Routes =
        case thoas:decode(S#pertisk_eproxy_site.routes_json) of
            {ok, L} when is_list(L) -> L;
            _ -> []
        end,
    #{
        host => S#pertisk_eproxy_site.host,
        backend => S#pertisk_eproxy_site.backend,
        routes => Routes
    }.

insert_site(_DbPath, _Host, _Backend, _Routes) ->
    {error, not_implemented}.

delete_site(_DbPath, _Host) ->
    {error, not_implemented}.

get_backend(_DbPath, _Name) ->
    {error, not_found}.

list_backends(_DbPath) ->
    {ok, []}.

insert_backend(_DbPath, _Name, _Algorithm, _HealthPath, _HealthInterval) ->
    {error, not_implemented}.

insert_upstream(_DbPath, _BackendName, _Addr, _Weight) ->
    {error, not_implemented}.

delete_backend(_DbPath, _Name) ->
    {error, not_implemented}.

%% ---------------------------------------------------------------------------
%% Internal helpers
%% ---------------------------------------------------------------------------

next_id(CounterKey) ->
    case mnesia:read(pertisk_eproxy_counter, CounterKey) of
        [] ->
            mnesia:write(#pertisk_eproxy_counter{key = CounterKey, next_id = 2}),
            1;
        [#pertisk_eproxy_counter{next_id = N}] ->
            mnesia:write(#pertisk_eproxy_counter{key = CounterKey, next_id = N + 1}),
            N
    end.

txn_read(Fun) ->
    txn_result(mnesia:transaction(Fun)).

txn_write(Fun) ->
    txn_result(mnesia:transaction(Fun)).

txn_result({atomic, Result}) ->
    {ok, Result};
txn_result({aborted, Reason}) ->
    {error, Reason}.

%% OTP 27+ removed `mnesia:tab2list/1`; match all rows via record pattern.
table_records(pertisk_eproxy_certificate) ->
    mnesia:match_object(#pertisk_eproxy_certificate{_ = '_'});
table_records(pertisk_eproxy_dns_provider) ->
    mnesia:match_object(#pertisk_eproxy_dns_provider{_ = '_'});
table_records(pertisk_eproxy_site) ->
    mnesia:match_object(#pertisk_eproxy_site{_ = '_'}).

decode_runtime_value(undefined) ->
    not_found;
decode_runtime_value(V0) when is_binary(V0) ->
    try
        TermBin = base64:decode(V0),
        case binary_to_term(TermBin, [safe]) of
            M when is_map(M) -> {ok, M};
            _ -> {error, invalid_runtime_config_term}
        end
    catch
        _:_ -> {error, invalid_runtime_config_encoding}
    end.

read_file_text(Path) when is_list(Path), Path =/= [] ->
    case file:read_file(Path) of
        {ok, Bin} -> binary_to_list(Bin);
        _ -> ""
    end;
read_file_text(_) ->
    "".

opt_text(undefined) -> "";
opt_text(null) -> "";
opt_text(V) when is_binary(V) -> binary_to_list(V);
opt_text(V) when is_list(V) -> V;
opt_text(V) when is_atom(V) -> atom_to_list(V);
opt_text(V) when is_integer(V) -> integer_to_list(V);
opt_text(_) -> "".

bool_to_int(true) -> 1;
bool_to_int(_) -> 0.

as_bin(B) when is_binary(B) -> B;
as_bin(L) when is_list(L) -> list_to_binary(L);
as_bin(_) -> <<>>.

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L.
