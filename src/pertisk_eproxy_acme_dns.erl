%% @doc ACME DNS-01 issuance (Cloudflare / DigitalOcean / Vultr / Porkbun / Linode / Hetzner / deSEC / Gandi / PowerDNS / DuckDNS) for sites with auto SSL; queues work after config changes.
-module(pertisk_eproxy_acme_dns).

-behaviour(gen_server).

-export([start_link/0, schedule_scan/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

schedule_scan() ->
    case erlang:whereis(?SERVER) of
        undefined -> ok;
        _ -> gen_server:cast(?MODULE, scan)
    end.

init([]) ->
    _ = timer:send_after(4000, scan),
    {ok, #{}}.

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(scan, State) ->
    _ = spawn(fun scan_and_issue/0),
    {noreply, State}.

handle_info(scan, State) ->
    handle_cast(scan, State);
handle_info(_I, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_Old, State, _Extra) ->
    {ok, State}.

%% ---------------------------------------------------------------------------
scan_and_issue() ->
    DbPath = pertisk_eproxy_config:db_file(),
    Sites = pertisk_eproxy_config:get_sites(),
    maybe_warn_lego_missing(DbPath, Sites),
    lists:foreach(
        fun(S) ->
            case site_needs_issue(S) of
                true ->
                    case issue_site(DbPath, S) of
                        ok ->
                            ok;
                        {error, R} ->
                            lager:error("ACME issue failed for ~p: ~p", [maps:get(host, S), R]);
                        Err ->
                            lager:error("ACME issue failed for ~p: ~p", [maps:get(host, S), Err])
                    end;
                false ->
                    ok
            end
        end,
        Sites
    ).

maybe_warn_lego_missing(DbPath, Sites) ->
    case os:find_executable("lego") of
        false ->
            case pending_lego_hosts(DbPath, Sites) of
                [] ->
                    ok;
                Hosts ->
                    lager:warning(
                        "ACME: lego binary not found; providers ~p require lego. Pending hosts: ~p. Hint: install lego and ensure it is in PATH.",
                        [lego_provider_atoms(), Hosts]
                    )
            end;
        _ ->
            ok
    end.

pending_lego_hosts(DbPath, Sites) ->
    case pertisk_eproxy_db:list_dns_providers(DbPath) of
        {ok, Rows} ->
            NameToKind = maps:from_list([
                {name_bin(R), {dns_provider_kind(provider_type_bin(R)), provider_type_bin(R)}}
             || R <- Rows
            ]),
            [
                site_host_bin(S)
             || S <- Sites,
                site_needs_issue(S),
                is_lego_provider_kind(maps:get(dns_provider_name_bin(S), NameToKind, {unsupported, <<>>}))
            ];
        _ ->
            []
    end.

lego_provider_atoms() ->
    [route53, godaddy, namecheap, ovh, googleclouddns, azure, rfc2136, cloudns, easydns, dnsmadeeasy, dynu, customlego].

is_lego_provider(Kind) ->
    lists:member(Kind, lego_provider_atoms()).

is_lego_provider_kind({Kind, ProviderType}) ->
    is_lego_provider(Kind) orelse is_dynamic_lego_provider(Kind, ProviderType).

is_dynamic_lego_provider(unsupported, ProviderType) when is_binary(ProviderType) ->
    Norm = string:lowercase(trim_space_binary(ProviderType)),
    Norm =/= <<>>;
is_dynamic_lego_provider(_, _) ->
    false.

site_needs_issue(S) ->
    case maps:get(challenge_type, S, undefined) of
        "dns-01" ->
            case maps:get(dns_provider, S, undefined) of
                undefined -> false;
                _ ->
                    case maps:get(acme_contact_email, S, undefined) of
                        undefined -> false;
                        _ -> cert_ref_allows_acme_dns_issue(S)
                    end
            end;
        _ ->
            false
    end.

%% Issue / re-issue when no cert yet, or current PEM is Let's Encrypt staging (switch to production),
%% or PEM is missing but site still references acme/… (retry after partial failure).
cert_ref_allows_acme_dns_issue(S) ->
    case maps:get(certificate, S, undefined) of
        undefined ->
            true;
        Ref ->
            acme_should_replace_site_certificate(Ref)
    end.

acme_should_replace_site_certificate(Ref) ->
    case acme_resolved_cert_pem_path(Ref) of
        undefined ->
            ref_looks_like_acme_store(Ref);
        Path ->
            case pertisk_eproxy_tls_cert_info:describe_listener_pem(Path) of
                {ok, #{issuer := Iss}} ->
                    issuer_is_le_staging(Iss);
                _ ->
                    ref_looks_like_acme_store(Ref)
            end
    end.

ref_looks_like_acme_store(Ref) ->
    case ref_to_binary(Ref) of
        <<"acme/", _/binary>> -> true;
        _ -> false
    end.

ref_to_binary(Ref) when is_binary(Ref) -> Ref;
ref_to_binary(Ref) when is_list(Ref) -> unicode:characters_to_binary(Ref, utf8);
ref_to_binary(Ref) when is_integer(Ref) -> integer_to_binary(Ref).

issuer_is_le_staging(Iss) when is_binary(Iss) ->
    L = string:lowercase(binary_to_list(Iss)),
    nomatch =/= string:find(L, "staging") orelse nomatch =/= string:find(L, "fake le");
issuer_is_le_staging(_) -> false.

acme_resolved_cert_pem_path(Ref) ->
    Rb = ref_to_binary(Ref),
    case Rb of
        <<"acme/", _/binary>> ->
            acme_pem_disk_path_for_name(Rb);
        _ ->
            acme_db_row_pem_path_for_id_ref(Rb)
    end.

acme_pem_disk_path_for_name(<<"acme/", Slug/binary>>) ->
    Base = acme_data_dir(),
    Path = filename:join([Base, "certs", binary_to_list(Slug), "fullchain.pem"]),
    case filelib:is_file(Path) of
        true -> Path;
        false -> undefined
    end.

acme_db_row_pem_path_for_id_ref(Rb) ->
    case acme_binary_to_int_id(Rb) of
        {ok, Id} ->
            DbPath = pertisk_eproxy_config:db_file(),
            case pertisk_eproxy_db:list_certificates(DbPath) of
                {ok, Rows} ->
                    case lists:search(fun(#{id := I}) -> I =:= Id end, Rows) of
                        {value, Row} -> acme_cert_row_effective_pem_path(Row);
                        false -> undefined
                    end;
                _ ->
                    undefined
            end;
        error ->
            undefined
    end.

acme_binary_to_int_id(B) when is_binary(B) ->
    try binary_to_integer(B) of
        Id -> {ok, Id}
    catch
        error:badarg -> error
    end;
acme_binary_to_int_id(_) ->
    error.

acme_cert_row_effective_pem_path(Row) ->
    NameB = acme_name_to_binary(maps:get(name, Row)),
    case NameB of
        <<"acme/", _/binary>> -> acme_pem_disk_path_for_name(NameB);
        _ -> undefined
    end.

acme_name_to_binary(N) when is_binary(N) -> N;
acme_name_to_binary(N) when is_list(N) -> unicode:characters_to_binary(N, utf8);
acme_name_to_binary(N) when is_integer(N) -> integer_to_binary(N);
acme_name_to_binary(_) -> <<>>.

maybe_drop_staging_kid_for_production(AcmeDirUrl, KidPath) ->
    UrlB = acme_dir_to_binary(AcmeDirUrl),
    case acme_directory_is_le_production(UrlB) of
        false ->
            ok;
        true ->
            case acme_read_kid_line(KidPath) of
                undefined ->
                    ok;
                Line ->
                    L = string:lowercase(Line),
                    case string:find(L, "acme-staging") of
                        nomatch ->
                            ok;
                        _ ->
                            lager:info(
                                "ACME: removed kid.txt (staging account URL) for production Let's Encrypt directory"
                            ),
                            _ = file:delete(KidPath)
                    end
            end
    end.

acme_dir_to_binary(U) when is_binary(U) -> U;
acme_dir_to_binary(U) when is_list(U) -> unicode:characters_to_binary(U, utf8);
acme_dir_to_binary(_) -> <<>>.

%% Production LE v2 directory host does not include "staging".
acme_directory_is_le_production(UrlB) when is_binary(UrlB) ->
    L = string:lowercase(binary_to_list(UrlB)),
    nomatch =:= string:find(L, "staging");
acme_directory_is_le_production(_) ->
    false.

acme_read_kid_line(KidPath) ->
    case file:read_file(KidPath) of
        {ok, Bin} ->
            case string:trim(binary_to_list(Bin)) of
                "" -> undefined;
                Line -> Line
            end;
        _ ->
            undefined
    end.

issue_site(DbPath, Site) ->
    Host = site_host_bin(Site),
    ssl_job(Host, <<"starting">>, <<"Starting ACME DNS-01 issuance">>),
    case dns_row_for_site(DbPath, Site) of
        {error, R} ->
            lager:warning("ACME: no DNS provider for ~s: ~p", [Host, R]),
            ssl_job_err(Host, R),
            {error, R};
        {ok, Row} ->
            Pt = provider_type_bin(Row),
            case dns_provider_kind(Pt) of
                cloudflare ->
                    issue_cloudflare(DbPath, Site, Host, Row);
                digitalocean ->
                    issue_digitalocean(DbPath, Site, Host, Row);
                vultr ->
                    issue_vultr(DbPath, Site, Host, Row);
                porkbun ->
                    issue_porkbun(DbPath, Site, Host, Row);
                linode ->
                    issue_linode(DbPath, Site, Host, Row);
                hetzner ->
                    issue_hetzner(DbPath, Site, Host, Row);
                desec ->
                    issue_desec(DbPath, Site, Host, Row);
                gandi ->
                    issue_gandi(DbPath, Site, Host, Row);
                powerdns ->
                    issue_powerdns(DbPath, Site, Host, Row);
                duckdns ->
                    issue_duckdns(DbPath, Site, Host, Row);
                route53 ->
                    issue_lego_provider(DbPath, Site, Host, Row, route53);
                godaddy ->
                    issue_lego_provider(DbPath, Site, Host, Row, godaddy);
                namecheap ->
                    issue_lego_provider(DbPath, Site, Host, Row, namecheap);
                ovh ->
                    issue_lego_provider(DbPath, Site, Host, Row, ovh);
                googleclouddns ->
                    issue_lego_provider(DbPath, Site, Host, Row, googleclouddns);
                azure ->
                    issue_lego_provider(DbPath, Site, Host, Row, azure);
                rfc2136 ->
                    issue_lego_provider(DbPath, Site, Host, Row, rfc2136);
                cloudns ->
                    issue_lego_provider(DbPath, Site, Host, Row, cloudns);
                easydns ->
                    issue_lego_provider(DbPath, Site, Host, Row, easydns);
                dnsmadeeasy ->
                    issue_lego_provider(DbPath, Site, Host, Row, dnsmadeeasy);
                dynu ->
                    issue_lego_provider(DbPath, Site, Host, Row, dynu);
                customlego ->
                    issue_lego_provider(DbPath, Site, Host, Row, customlego);
                _ ->
                    %% Dynamic fallback: if provider_type is not natively mapped,
                    %% treat it as a direct lego provider name.
                    issue_lego_provider(DbPath, Site, Host, Row, string:lowercase(trim_space_binary(Pt)))
            end
    end.

site_host_bin(S) ->
    case maps:get(host, S, <<>>) of
        H when is_binary(H) -> H;
        H when is_list(H) -> unicode:characters_to_binary(H, utf8)
    end.

dns_row_for_site(DbPath, Site) ->
    Want = dns_provider_name_bin(Site),
    case pertisk_eproxy_db:list_dns_providers(DbPath) of
        {ok, Rows} ->
            case lists:search(fun(R) -> name_bin(R) =:= Want end, Rows) of
                false -> {error, dns_provider_not_found};
                {value, R} -> {ok, R}
            end;
        {error, _} = E ->
            E
    end.

dns_provider_name_bin(S) ->
    case maps:get(dns_provider, S, <<>>) of
        X when is_binary(X) -> X;
        X when is_list(X) -> unicode:characters_to_binary(X, utf8)
    end.

name_bin(#{name := N}) when is_binary(N) -> N;
name_bin(#{name := N}) when is_list(N) -> unicode:characters_to_binary(N, utf8).

provider_type_bin(#{provider_type := Pt}) when is_binary(Pt) -> Pt;
provider_type_bin(#{provider_type := Pt}) when is_list(Pt) -> unicode:characters_to_binary(Pt, utf8).

dns_provider_kind(Pt0) when is_binary(Pt0) ->
    Pt1 = string:lowercase(trim_space_binary(Pt0)),
    Pt = binary:replace(binary:replace(Pt1, <<"-">>, <<"">>, [global]), <<"_">>, <<"">>, [global]),
    case Pt of
        <<"cloudflare">> -> cloudflare;
        <<"digitalocean">> -> digitalocean;
        <<"do">> -> digitalocean;
        <<"vultr">> -> vultr;
        <<"porkbun">> -> porkbun;
        <<"linode">> -> linode;
        <<"hetzner">> -> hetzner;
        <<"desec">> -> desec;
        <<"gandi">> -> gandi;
        <<"powerdns">> -> powerdns;
        <<"duckdns">> -> duckdns;
        <<"route53">> -> route53;
        <<"godaddy">> -> godaddy;
        <<"namecheap">> -> namecheap;
        <<"ovh">> -> ovh;
        <<"googleclouddns">> -> googleclouddns;
        <<"gcloud">> -> googleclouddns;
        <<"azure">> -> azure;
        <<"rfc2136">> -> rfc2136;
        <<"cloudns">> -> cloudns;
        <<"easydns">> -> easydns;
        <<"dnsmadeeasy">> -> dnsmadeeasy;
        <<"dynu">> -> dynu;
        <<"customlego">> -> customlego;
        <<"lego">> -> customlego;
        _ -> unsupported
    end.

trim_space_binary(Bin) when is_binary(Bin) ->
    trim_space_right(trim_space_left(Bin)).

trim_space_left(<<C, Rest/binary>>) when C =:= 32; C =:= 9; C =:= 10; C =:= 13 ->
    trim_space_left(Rest);
trim_space_left(Bin) ->
    Bin.

trim_space_right(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    case binary:last(Bin) of
        C when C =:= 32; C =:= 9; C =:= 10; C =:= 13 ->
            trim_space_right(binary:part(Bin, 0, byte_size(Bin) - 1));
        _ ->
            Bin
    end;
trim_space_right(Bin) ->
    Bin.

issue_cloudflare(DbPath, Site, Host, Row) ->
    Creds = maps:get(credentials, Row, #{}),
    Token = cred_get(Creds, [<<"api_token">>, <<"apiToken">>]),
    case Token of
        undefined ->
            ssl_job_err(Host, missing_api_token),
            {error, missing_api_token};
        _ ->
            ZoneId0 = cred_get(Creds, [<<"zone_id">>, <<"zoneId">>]),
            {ZoneId, ZoneName} = resolve_zone(Token, ZoneId0, Host),
            ZoneLabel = zone_name_bin(ZoneName),
            ssl_job(Host, <<"zone">>, iolist_to_binary([<<"Cloudflare zone: ">>, ZoneLabel])),
            Identifiers = site_identifiers(Site, Host),
            case pertisk_eproxy_acme_csr:generate_rsa_csr(Identifiers) of
                {error, Reason} ->
                    ssl_job_err(Host, {csr_failed, Reason}),
                    {error, {csr_failed, Reason}};
                {ok, #{csr_der := CsrDer, key_pem := KeyPem}} ->
                    ssl_job(Host, <<"csr">>, <<"Generated private key and CSR">>),
                    issue_cloudflare_after_csr(
                        DbPath, Site, Host, Row, Token, ZoneId, ZoneName, Identifiers, CsrDer, KeyPem
                    )
            end
    end.

issue_cloudflare_after_csr(DbPath, Site, Host, _Row, Token, ZoneId, ZoneName, Identifiers, CsrDer, KeyPem) ->
    AcmeDir = acme_directory(),
    KidPathPre = filename:join(acme_data_dir(), "kid.txt"),
    ok = maybe_drop_staging_kid_for_production(AcmeDir, KidPathPre),
    Terms = application:get_env(pertisk_eproxy, acme_terms_agreed, false),
    case Terms of
        false ->
            lager:warning("ACME disabled: set {acme_terms_agreed, true} in sys.config to issue for ~s", [Host]),
            ssl_job_err(Host, terms_not_agreed),
            {error, terms_not_agreed};
        true ->
            {Jwk, Kid} = load_account_key(),
                    KidPathFile = filename:join(acme_data_dir(), "kid.txt"),
                    AddFun = fun(TxtFqdn, Digest) ->
                        RecName = pertisk_eproxy_dns_cloudflare:cf_txt_record_name(TxtFqdn, ZoneName),
                        case pertisk_eproxy_dns_cloudflare:create_txt(Token, ZoneId, RecName, Digest, <<"pertisk-acme">>) of
                            {ok, Rid} -> {ok, {cf, Token, ZoneId, Rid}};
                            Err -> Err
                        end
                    end,
                    DelFun = fun
                        ({cf, Tok, Zi, Rid}) ->
                            pertisk_eproxy_dns_cloudflare:delete_txt(Tok, Zi, Rid);
                        (_) ->
                            ok
                    end,
                    Progress = fun(Phase, Msg) -> ssl_job(Host, Phase, Msg) end,
                    Opts = #{
                        directory_url => AcmeDir,
                        account_jwk => Jwk,
                        account_kid => Kid,
                        contact_email => contact_bin(Site),
                        terms_agreed => true,
                        identifiers => Identifiers,
                        csr_der => CsrDer,
                        dns_add => AddFun,
                        dns_del => DelFun,
                        dns_propagation_delay_ms => acme_dns_propagation_delay_ms(),
                        progress => Progress
                    },
                    case pertisk_eproxy_acme_client:obtain_certificate(Opts) of
                        {error, _} = E ->
                            ssl_job_err(Host, E),
                            E;
                        {ok, PemChain, KidOut} ->
                            maybe_write_kid(KidPathFile, Kid, KidOut),
                            _ = save_and_register(DbPath, Site, Host, PemChain, KeyPem),
                            ssl_job_done(Host, <<"TLS certificate issued and saved">>),
                            ok
                    end
            end.

issue_digitalocean(DbPath, Site, Host, Row) ->
    Creds = maps:get(credentials, Row, #{}),
    Token = cred_get(Creds, [<<"api_token">>, <<"apiToken">>]),
    case Token of
        undefined ->
            ssl_job_err(Host, missing_api_token),
            {error, missing_api_token};
        _ ->
            Domain0 = cred_get(Creds, [<<"domain">>, <<"zone_name">>, <<"zoneName">>]),
            Lookup = zone_lookup_host(Host),
            case pertisk_eproxy_dns_digitalocean:resolve_domain(Token, Domain0, Lookup) of
                {error, _} = E ->
                    ssl_job_err(Host, E),
                    E;
                {ok, Domain} ->
                    ssl_job(
                        Host,
                        <<"zone">>,
                        iolist_to_binary([<<"DigitalOcean domain: ">>, Domain])
                    ),
                    Identifiers = site_identifiers(Site, Host),
                    case pertisk_eproxy_acme_csr:generate_rsa_csr(Identifiers) of
                        {error, Reason} ->
                            ssl_job_err(Host, {csr_failed, Reason}),
                            {error, {csr_failed, Reason}};
                        {ok, #{csr_der := CsrDer, key_pem := KeyPem}} ->
                            ssl_job(Host, <<"csr">>, <<"Generated private key and CSR">>),
                            issue_digitalocean_after_csr(
                                DbPath,
                                Site,
                                Host,
                                Token,
                                Domain,
                                Identifiers,
                                CsrDer,
                                KeyPem
                            )
                    end
            end
    end.

issue_digitalocean_after_csr(DbPath, Site, Host, Token, Domain, Identifiers, CsrDer, KeyPem) ->
    AcmeDir = acme_directory(),
    KidPathPre = filename:join(acme_data_dir(), "kid.txt"),
    ok = maybe_drop_staging_kid_for_production(AcmeDir, KidPathPre),
    Terms = application:get_env(pertisk_eproxy, acme_terms_agreed, false),
    case Terms of
        false ->
            lager:warning("ACME disabled: set {acme_terms_agreed, true} in sys.config to issue for ~s", [Host]),
            ssl_job_err(Host, terms_not_agreed),
            {error, terms_not_agreed};
        true ->
            {Jwk, Kid} = load_account_key(),
            KidPathFile = filename:join(acme_data_dir(), "kid.txt"),
            AddFun = fun(TxtFqdn, Digest) ->
                RecName = pertisk_eproxy_dns_digitalocean:txt_record_name(TxtFqdn, Domain),
                case pertisk_eproxy_dns_digitalocean:create_txt(Token, Domain, RecName, Digest) of
                    {ok, Rid} -> {ok, {digo, Token, Domain, Rid}};
                    Err -> Err
                end
            end,
            DelFun = fun
                ({digo, Tok, Dom, Rid}) ->
                    pertisk_eproxy_dns_digitalocean:delete_txt(Tok, Dom, Rid);
                (_) ->
                    ok
            end,
            Progress = fun(Phase, Msg) -> ssl_job(Host, Phase, Msg) end,
            Opts = #{
                directory_url => AcmeDir,
                account_jwk => Jwk,
                account_kid => Kid,
                contact_email => contact_bin(Site),
                terms_agreed => true,
                identifiers => Identifiers,
                csr_der => CsrDer,
                dns_add => AddFun,
                dns_del => DelFun,
                %% DigitalOcean DNS can take longer to become visible from LE validators.
                %% Keep configurable value, but enforce a safer floor for dns-01 reliability.
                dns_propagation_delay_ms => erlang:max(60000, acme_dns_propagation_delay_ms()),
                progress => Progress
            },
            case pertisk_eproxy_acme_client:obtain_certificate(Opts) of
                {error, _} = E ->
                    ssl_job_err(Host, E),
                    E;
                {ok, PemChain, KidOut} ->
                    maybe_write_kid(KidPathFile, Kid, KidOut),
                    _ = save_and_register(DbPath, Site, Host, PemChain, KeyPem),
                    ssl_job_done(Host, <<"TLS certificate issued and saved">>),
                    ok
            end
    end.

issue_vultr(DbPath, Site, Host, Row) ->
    Creds = maps:get(credentials, Row, #{}),
    Token = cred_get(Creds, [<<"api_token">>, <<"apiToken">>, <<"api_key">>, <<"apiKey">>]),
    case Token of
        undefined ->
            ssl_job_err(Host, missing_api_token),
            {error, missing_api_token};
        _ ->
            Zone0 = cred_get(Creds, [<<"zone">>, <<"zone_name">>, <<"zoneName">>, <<"domain">>]),
            Lookup = zone_lookup_host(Host),
            case pertisk_eproxy_dns_vultr:resolve_zone(Token, Zone0, Lookup) of
                {error, _} = E ->
                    ssl_job_err(Host, E),
                    E;
                {ok, Zone} ->
                    ssl_job(Host, <<"zone">>, iolist_to_binary([<<"Vultr zone: ">>, Zone])),
                    Identifiers = site_identifiers(Site, Host),
                    case pertisk_eproxy_acme_csr:generate_rsa_csr(Identifiers) of
                        {error, Reason} ->
                            ssl_job_err(Host, {csr_failed, Reason}),
                            {error, {csr_failed, Reason}};
                        {ok, #{csr_der := CsrDer, key_pem := KeyPem}} ->
                            ssl_job(Host, <<"csr">>, <<"Generated private key and CSR">>),
                            issue_vultr_after_csr(DbPath, Site, Host, Token, Zone, Identifiers, CsrDer, KeyPem)
                    end
            end
    end.

issue_vultr_after_csr(DbPath, Site, Host, Token, Zone, Identifiers, CsrDer, KeyPem) ->
    AcmeDir = acme_directory(),
    KidPathPre = filename:join(acme_data_dir(), "kid.txt"),
    ok = maybe_drop_staging_kid_for_production(AcmeDir, KidPathPre),
    Terms = application:get_env(pertisk_eproxy, acme_terms_agreed, false),
    case Terms of
        false ->
            lager:warning("ACME disabled: set {acme_terms_agreed, true} in sys.config to issue for ~s", [Host]),
            ssl_job_err(Host, terms_not_agreed),
            {error, terms_not_agreed};
        true ->
            {Jwk, Kid} = load_account_key(),
            KidPathFile = filename:join(acme_data_dir(), "kid.txt"),
            AddFun = fun(TxtFqdn, Digest) ->
                RecName = pertisk_eproxy_dns_vultr:txt_record_name(TxtFqdn, Zone),
                case pertisk_eproxy_dns_vultr:create_txt(Token, Zone, RecName, Digest) of
                    {ok, Rid} -> {ok, {vultr, Token, Zone, Rid}};
                    Err -> Err
                end
            end,
            DelFun = fun
                ({vultr, Tok, Zn, Rid}) ->
                    pertisk_eproxy_dns_vultr:delete_txt(Tok, Zn, Rid);
                (_) ->
                    ok
            end,
            Progress = fun(Phase, Msg) -> ssl_job(Host, Phase, Msg) end,
            Opts = #{
                directory_url => AcmeDir,
                account_jwk => Jwk,
                account_kid => Kid,
                contact_email => contact_bin(Site),
                terms_agreed => true,
                identifiers => Identifiers,
                csr_der => CsrDer,
                dns_add => AddFun,
                dns_del => DelFun,
                dns_propagation_delay_ms => erlang:max(45000, acme_dns_propagation_delay_ms()),
                progress => Progress
            },
            case pertisk_eproxy_acme_client:obtain_certificate(Opts) of
                {error, _} = E ->
                    ssl_job_err(Host, E),
                    E;
                {ok, PemChain, KidOut} ->
                    maybe_write_kid(KidPathFile, Kid, KidOut),
                    _ = save_and_register(DbPath, Site, Host, PemChain, KeyPem),
                    ssl_job_done(Host, <<"TLS certificate issued and saved">>),
                    ok
            end
    end.

issue_porkbun(DbPath, Site, Host, Row) ->
    Creds = maps:get(credentials, Row, #{}),
    ApiKey = cred_get(Creds, [<<"api_key">>, <<"apiKey">>]),
    SecretApiKey = cred_get(Creds, [<<"secret_api_key">>, <<"secretApiKey">>]),
    case {ApiKey, SecretApiKey} of
        {undefined, _} ->
            ssl_job_err(Host, missing_api_key),
            {error, missing_api_key};
        {_, undefined} ->
            ssl_job_err(Host, missing_secret_api_key),
            {error, missing_secret_api_key};
        _ ->
            Zone0 = cred_get(Creds, [<<"zone">>, <<"zone_name">>, <<"zoneName">>, <<"domain">>]),
            Lookup = zone_lookup_host(Host),
            case pertisk_eproxy_dns_porkbun:resolve_domain(ApiKey, SecretApiKey, Zone0, Lookup) of
                {error, _} = E ->
                    ssl_job_err(Host, E),
                    E;
                {ok, Domain} ->
                    ssl_job(Host, <<"zone">>, iolist_to_binary([<<"Porkbun domain: ">>, Domain])),
                    Identifiers = site_identifiers(Site, Host),
                    case pertisk_eproxy_acme_csr:generate_rsa_csr(Identifiers) of
                        {error, Reason} ->
                            ssl_job_err(Host, {csr_failed, Reason}),
                            {error, {csr_failed, Reason}};
                        {ok, #{csr_der := CsrDer, key_pem := KeyPem}} ->
                            ssl_job(Host, <<"csr">>, <<"Generated private key and CSR">>),
                            issue_porkbun_after_csr(
                                DbPath,
                                Site,
                                Host,
                                ApiKey,
                                SecretApiKey,
                                Domain,
                                Identifiers,
                                CsrDer,
                                KeyPem
                            )
                    end
            end
    end.

issue_porkbun_after_csr(DbPath, Site, Host, ApiKey, SecretApiKey, Domain, Identifiers, CsrDer, KeyPem) ->
    AcmeDir = acme_directory(),
    KidPathPre = filename:join(acme_data_dir(), "kid.txt"),
    ok = maybe_drop_staging_kid_for_production(AcmeDir, KidPathPre),
    Terms = application:get_env(pertisk_eproxy, acme_terms_agreed, false),
    case Terms of
        false ->
            lager:warning("ACME disabled: set {acme_terms_agreed, true} in sys.config to issue for ~s", [Host]),
            ssl_job_err(Host, terms_not_agreed),
            {error, terms_not_agreed};
        true ->
            {Jwk, Kid} = load_account_key(),
            KidPathFile = filename:join(acme_data_dir(), "kid.txt"),
            AddFun = fun(TxtFqdn, Digest) ->
                RecName = pertisk_eproxy_dns_porkbun:txt_record_name(TxtFqdn, Domain),
                case pertisk_eproxy_dns_porkbun:create_txt(ApiKey, SecretApiKey, Domain, RecName, Digest) of
                    {ok, Rid} -> {ok, {porkbun, ApiKey, SecretApiKey, Domain, Rid}};
                    Err -> Err
                end
            end,
            DelFun = fun
                ({porkbun, Ak, Sak, Dom, Rid}) ->
                    pertisk_eproxy_dns_porkbun:delete_txt(Ak, Sak, Dom, Rid);
                (_) ->
                    ok
            end,
            Progress = fun(Phase, Msg) -> ssl_job(Host, Phase, Msg) end,
            Opts = #{
                directory_url => AcmeDir,
                account_jwk => Jwk,
                account_kid => Kid,
                contact_email => contact_bin(Site),
                terms_agreed => true,
                identifiers => Identifiers,
                csr_der => CsrDer,
                dns_add => AddFun,
                dns_del => DelFun,
                dns_propagation_delay_ms => erlang:max(45000, acme_dns_propagation_delay_ms()),
                progress => Progress
            },
            case pertisk_eproxy_acme_client:obtain_certificate(Opts) of
                {error, _} = E ->
                    ssl_job_err(Host, E),
                    E;
                {ok, PemChain, KidOut} ->
                    maybe_write_kid(KidPathFile, Kid, KidOut),
                    _ = save_and_register(DbPath, Site, Host, PemChain, KeyPem),
                    ssl_job_done(Host, <<"TLS certificate issued and saved">>),
                    ok
            end
    end.

issue_linode(DbPath, Site, Host, Row) ->
    Creds = maps:get(credentials, Row, #{}),
    Token = cred_get(Creds, [<<"api_token">>, <<"apiToken">>]),
    case Token of
        undefined ->
            ssl_job_err(Host, missing_api_token),
            {error, missing_api_token};
        _ ->
            Domain0 = cred_get(Creds, [<<"domain">>, <<"zone_name">>, <<"zoneName">>]),
            Lookup = zone_lookup_host(Host),
            case pertisk_eproxy_dns_linode:resolve_domain(Token, Domain0, Lookup) of
                {error, _} = E ->
                    ssl_job_err(Host, E),
                    E;
                {ok, #{id := DomainId, domain := DomainName}} ->
                    ssl_job(Host, <<"zone">>, iolist_to_binary([<<"Linode domain: ">>, DomainName])),
                    Identifiers = site_identifiers(Site, Host),
                    case pertisk_eproxy_acme_csr:generate_rsa_csr(Identifiers) of
                        {error, Reason} ->
                            ssl_job_err(Host, {csr_failed, Reason}),
                            {error, {csr_failed, Reason}};
                        {ok, #{csr_der := CsrDer, key_pem := KeyPem}} ->
                            ssl_job(Host, <<"csr">>, <<"Generated private key and CSR">>),
                            issue_linode_after_csr(
                                DbPath,
                                Site,
                                Host,
                                Token,
                                DomainId,
                                DomainName,
                                Identifiers,
                                CsrDer,
                                KeyPem
                            )
                    end
            end
    end.

issue_linode_after_csr(DbPath, Site, Host, Token, DomainId, DomainName, Identifiers, CsrDer, KeyPem) ->
    AcmeDir = acme_directory(),
    KidPathPre = filename:join(acme_data_dir(), "kid.txt"),
    ok = maybe_drop_staging_kid_for_production(AcmeDir, KidPathPre),
    Terms = application:get_env(pertisk_eproxy, acme_terms_agreed, false),
    case Terms of
        false ->
            lager:warning("ACME disabled: set {acme_terms_agreed, true} in sys.config to issue for ~s", [Host]),
            ssl_job_err(Host, terms_not_agreed),
            {error, terms_not_agreed};
        true ->
            {Jwk, Kid} = load_account_key(),
            KidPathFile = filename:join(acme_data_dir(), "kid.txt"),
            AddFun = fun(TxtFqdn, Digest) ->
                RecName = pertisk_eproxy_dns_linode:txt_record_name(TxtFqdn, DomainName),
                case pertisk_eproxy_dns_linode:create_txt(Token, DomainId, RecName, Digest) of
                    {ok, Rid} -> {ok, {linode, Token, DomainId, Rid}};
                    Err -> Err
                end
            end,
            DelFun = fun
                ({linode, Tok, DomId, Rid}) ->
                    pertisk_eproxy_dns_linode:delete_txt(Tok, DomId, Rid);
                (_) ->
                    ok
            end,
            Progress = fun(Phase, Msg) -> ssl_job(Host, Phase, Msg) end,
            Opts = #{
                directory_url => AcmeDir,
                account_jwk => Jwk,
                account_kid => Kid,
                contact_email => contact_bin(Site),
                terms_agreed => true,
                identifiers => Identifiers,
                csr_der => CsrDer,
                dns_add => AddFun,
                dns_del => DelFun,
                dns_propagation_delay_ms => erlang:max(45000, acme_dns_propagation_delay_ms()),
                progress => Progress
            },
            case pertisk_eproxy_acme_client:obtain_certificate(Opts) of
                {error, _} = E ->
                    ssl_job_err(Host, E),
                    E;
                {ok, PemChain, KidOut} ->
                    maybe_write_kid(KidPathFile, Kid, KidOut),
                    _ = save_and_register(DbPath, Site, Host, PemChain, KeyPem),
                    ssl_job_done(Host, <<"TLS certificate issued and saved">>),
                    ok
            end
    end.

issue_hetzner(DbPath, Site, Host, Row) ->
    Creds = maps:get(credentials, Row, #{}),
    Token = cred_get(Creds, [<<"api_token">>, <<"apiToken">>]),
    case Token of
        undefined ->
            ssl_job_err(Host, missing_api_token),
            {error, missing_api_token};
        _ ->
            Domain0 = cred_get(Creds, [<<"domain">>, <<"zone_name">>, <<"zoneName">>]),
            Lookup = zone_lookup_host(Host),
            case pertisk_eproxy_dns_hetzner:resolve_zone(Token, Domain0, Lookup) of
                {error, _} = E ->
                    ssl_job_err(Host, E),
                    E;
                {ok, #{zone_id := ZoneId, zone_name := ZoneName}} ->
                    ssl_job(Host, <<"zone">>, iolist_to_binary([<<"Hetzner zone: ">>, ZoneName])),
                    Identifiers = site_identifiers(Site, Host),
                    case pertisk_eproxy_acme_csr:generate_rsa_csr(Identifiers) of
                        {error, Reason} ->
                            ssl_job_err(Host, {csr_failed, Reason}),
                            {error, {csr_failed, Reason}};
                        {ok, #{csr_der := CsrDer, key_pem := KeyPem}} ->
                            ssl_job(Host, <<"csr">>, <<"Generated private key and CSR">>),
                            issue_hetzner_after_csr(
                                DbPath,
                                Site,
                                Host,
                                Token,
                                ZoneId,
                                ZoneName,
                                Identifiers,
                                CsrDer,
                                KeyPem
                            )
                    end
            end
    end.

issue_hetzner_after_csr(DbPath, Site, Host, Token, ZoneId, ZoneName, Identifiers, CsrDer, KeyPem) ->
    AcmeDir = acme_directory(),
    KidPathPre = filename:join(acme_data_dir(), "kid.txt"),
    ok = maybe_drop_staging_kid_for_production(AcmeDir, KidPathPre),
    Terms = application:get_env(pertisk_eproxy, acme_terms_agreed, false),
    case Terms of
        false ->
            lager:warning("ACME disabled: set {acme_terms_agreed, true} in sys.config to issue for ~s", [Host]),
            ssl_job_err(Host, terms_not_agreed),
            {error, terms_not_agreed};
        true ->
            {Jwk, Kid} = load_account_key(),
            KidPathFile = filename:join(acme_data_dir(), "kid.txt"),
            AddFun = fun(TxtFqdn, Digest) ->
                RecName = pertisk_eproxy_dns_hetzner:txt_record_name(TxtFqdn, ZoneName),
                case pertisk_eproxy_dns_hetzner:create_txt(Token, ZoneId, RecName, Digest) of
                    {ok, Rid} -> {ok, {hetzner, Token, ZoneId, Rid}};
                    Err -> Err
                end
            end,
            DelFun = fun
                ({hetzner, Tok, Zi, Rid}) ->
                    pertisk_eproxy_dns_hetzner:delete_txt(Tok, Zi, Rid);
                (_) ->
                    ok
            end,
            Progress = fun(Phase, Msg) -> ssl_job(Host, Phase, Msg) end,
            Opts = #{
                directory_url => AcmeDir,
                account_jwk => Jwk,
                account_kid => Kid,
                contact_email => contact_bin(Site),
                terms_agreed => true,
                identifiers => Identifiers,
                csr_der => CsrDer,
                dns_add => AddFun,
                dns_del => DelFun,
                dns_propagation_delay_ms => erlang:max(45000, acme_dns_propagation_delay_ms()),
                progress => Progress
            },
            case pertisk_eproxy_acme_client:obtain_certificate(Opts) of
                {error, _} = E ->
                    ssl_job_err(Host, E),
                    E;
                {ok, PemChain, KidOut} ->
                    maybe_write_kid(KidPathFile, Kid, KidOut),
                    _ = save_and_register(DbPath, Site, Host, PemChain, KeyPem),
                    ssl_job_done(Host, <<"TLS certificate issued and saved">>),
                    ok
            end
    end.

issue_desec(DbPath, Site, Host, Row) ->
    Creds = maps:get(credentials, Row, #{}),
    Token = cred_get(Creds, [<<"api_token">>, <<"apiToken">>]),
    case Token of
        undefined ->
            ssl_job_err(Host, missing_api_token),
            {error, missing_api_token};
        _ ->
            Domain0 = cred_get(Creds, [<<"domain">>, <<"zone_name">>, <<"zoneName">>]),
            Lookup = zone_lookup_host(Host),
            case pertisk_eproxy_dns_desec:resolve_domain(Token, Domain0, Lookup) of
                {error, _} = E ->
                    ssl_job_err(Host, E),
                    E;
                {ok, Domain} ->
                    ssl_job(Host, <<"zone">>, iolist_to_binary([<<"deSEC domain: ">>, Domain])),
                    Identifiers = site_identifiers(Site, Host),
                    case pertisk_eproxy_acme_csr:generate_rsa_csr(Identifiers) of
                        {error, Reason} ->
                            ssl_job_err(Host, {csr_failed, Reason}),
                            {error, {csr_failed, Reason}};
                        {ok, #{csr_der := CsrDer, key_pem := KeyPem}} ->
                            ssl_job(Host, <<"csr">>, <<"Generated private key and CSR">>),
                            issue_desec_after_csr(
                                DbPath,
                                Site,
                                Host,
                                Token,
                                Domain,
                                Identifiers,
                                CsrDer,
                                KeyPem
                            )
                    end
            end
    end.

issue_desec_after_csr(DbPath, Site, Host, Token, Domain, Identifiers, CsrDer, KeyPem) ->
    AcmeDir = acme_directory(),
    KidPathPre = filename:join(acme_data_dir(), "kid.txt"),
    ok = maybe_drop_staging_kid_for_production(AcmeDir, KidPathPre),
    Terms = application:get_env(pertisk_eproxy, acme_terms_agreed, false),
    case Terms of
        false ->
            lager:warning("ACME disabled: set {acme_terms_agreed, true} in sys.config to issue for ~s", [Host]),
            ssl_job_err(Host, terms_not_agreed),
            {error, terms_not_agreed};
        true ->
            {Jwk, Kid} = load_account_key(),
            KidPathFile = filename:join(acme_data_dir(), "kid.txt"),
            AddFun = fun(TxtFqdn, Digest) ->
                SubName = pertisk_eproxy_dns_desec:txt_record_name(TxtFqdn, Domain),
                case pertisk_eproxy_dns_desec:create_txt(Token, Domain, SubName, Digest) of
                    {ok, Opaque} -> {ok, Opaque};
                    Err -> Err
                end
            end,
            DelFun = fun
                ({desec, Tok, Dom, SubName}) ->
                    pertisk_eproxy_dns_desec:delete_txt(Tok, Dom, SubName);
                (_) ->
                    ok
            end,
            Progress = fun(Phase, Msg) -> ssl_job(Host, Phase, Msg) end,
            Opts = #{
                directory_url => AcmeDir,
                account_jwk => Jwk,
                account_kid => Kid,
                contact_email => contact_bin(Site),
                terms_agreed => true,
                identifiers => Identifiers,
                csr_der => CsrDer,
                dns_add => AddFun,
                dns_del => DelFun,
                dns_propagation_delay_ms => erlang:max(45000, acme_dns_propagation_delay_ms()),
                progress => Progress
            },
            case pertisk_eproxy_acme_client:obtain_certificate(Opts) of
                {error, _} = E ->
                    ssl_job_err(Host, E),
                    E;
                {ok, PemChain, KidOut} ->
                    maybe_write_kid(KidPathFile, Kid, KidOut),
                    _ = save_and_register(DbPath, Site, Host, PemChain, KeyPem),
                    ssl_job_done(Host, <<"TLS certificate issued and saved">>),
                    ok
            end
    end.

issue_gandi(DbPath, Site, Host, Row) ->
    Creds = maps:get(credentials, Row, #{}),
    Token = cred_get(Creds, [<<"api_token">>, <<"apiToken">>]),
    case Token of
        undefined ->
            ssl_job_err(Host, missing_api_token),
            {error, missing_api_token};
        _ ->
            Domain0 = cred_get(Creds, [<<"domain">>, <<"zone_name">>, <<"zoneName">>]),
            Lookup = zone_lookup_host(Host),
            case pertisk_eproxy_dns_gandi:resolve_domain(Token, Domain0, Lookup) of
                {error, _} = E ->
                    ssl_job_err(Host, E),
                    E;
                {ok, Domain} ->
                    ssl_job(Host, <<"zone">>, iolist_to_binary([<<"Gandi domain: ">>, Domain])),
                    Identifiers = site_identifiers(Site, Host),
                    case pertisk_eproxy_acme_csr:generate_rsa_csr(Identifiers) of
                        {error, Reason} ->
                            ssl_job_err(Host, {csr_failed, Reason}),
                            {error, {csr_failed, Reason}};
                        {ok, #{csr_der := CsrDer, key_pem := KeyPem}} ->
                            ssl_job(Host, <<"csr">>, <<"Generated private key and CSR">>),
                            issue_gandi_after_csr(DbPath, Site, Host, Token, Domain, Identifiers, CsrDer, KeyPem)
                    end
            end
    end.

issue_gandi_after_csr(DbPath, Site, Host, Token, Domain, Identifiers, CsrDer, KeyPem) ->
    AcmeDir = acme_directory(),
    KidPathPre = filename:join(acme_data_dir(), "kid.txt"),
    ok = maybe_drop_staging_kid_for_production(AcmeDir, KidPathPre),
    Terms = application:get_env(pertisk_eproxy, acme_terms_agreed, false),
    case Terms of
        false ->
            lager:warning("ACME disabled: set {acme_terms_agreed, true} in sys.config to issue for ~s", [Host]),
            ssl_job_err(Host, terms_not_agreed),
            {error, terms_not_agreed};
        true ->
            {Jwk, Kid} = load_account_key(),
            KidPathFile = filename:join(acme_data_dir(), "kid.txt"),
            AddFun = fun(TxtFqdn, Digest) ->
                RecName = pertisk_eproxy_dns_gandi:txt_record_name(TxtFqdn, Domain),
                case pertisk_eproxy_dns_gandi:create_txt(Token, Domain, RecName, Digest) of
                    {ok, Opaque} -> {ok, Opaque};
                    Err -> Err
                end
            end,
            DelFun = fun
                ({gandi, Tok, Dom, Name}) ->
                    pertisk_eproxy_dns_gandi:delete_txt(Tok, Dom, Name);
                (_) ->
                    ok
            end,
            Progress = fun(Phase, Msg) -> ssl_job(Host, Phase, Msg) end,
            Opts = #{
                directory_url => AcmeDir,
                account_jwk => Jwk,
                account_kid => Kid,
                contact_email => contact_bin(Site),
                terms_agreed => true,
                identifiers => Identifiers,
                csr_der => CsrDer,
                dns_add => AddFun,
                dns_del => DelFun,
                dns_propagation_delay_ms => erlang:max(45000, acme_dns_propagation_delay_ms()),
                progress => Progress
            },
            case pertisk_eproxy_acme_client:obtain_certificate(Opts) of
                {error, _} = E ->
                    ssl_job_err(Host, E),
                    E;
                {ok, PemChain, KidOut} ->
                    maybe_write_kid(KidPathFile, Kid, KidOut),
                    _ = save_and_register(DbPath, Site, Host, PemChain, KeyPem),
                    ssl_job_done(Host, <<"TLS certificate issued and saved">>),
                    ok
            end
    end.

issue_powerdns(DbPath, Site, Host, Row) ->
    Creds = maps:get(credentials, Row, #{}),
    ApiUrl = cred_get(Creds, [<<"api_url">>, <<"apiUrl">>]),
    ApiKey = cred_get(Creds, [<<"api_key">>, <<"apiKey">>]),
    ServerId = cred_get(Creds, [<<"server_id">>, <<"serverId">>]),
    case {ApiUrl, ApiKey} of
        {undefined, _} ->
            ssl_job_err(Host, missing_api_url),
            {error, missing_api_url};
        {_, undefined} ->
            ssl_job_err(Host, missing_api_key),
            {error, missing_api_key};
        _ ->
            Domain0 = cred_get(Creds, [<<"domain">>, <<"zone_name">>, <<"zoneName">>]),
            Lookup = zone_lookup_host(Host),
            case pertisk_eproxy_dns_powerdns:resolve_zone(ApiUrl, ApiKey, ServerId, Domain0, Lookup) of
                {error, _} = E ->
                    ssl_job_err(Host, E),
                    E;
                {ok, #{server_id := Sid, zone_name := Zone}} ->
                    ssl_job(Host, <<"zone">>, iolist_to_binary([<<"PowerDNS zone: ">>, Zone])),
                    Identifiers = site_identifiers(Site, Host),
                    case pertisk_eproxy_acme_csr:generate_rsa_csr(Identifiers) of
                        {error, Reason} ->
                            ssl_job_err(Host, {csr_failed, Reason}),
                            {error, {csr_failed, Reason}};
                        {ok, #{csr_der := CsrDer, key_pem := KeyPem}} ->
                            ssl_job(Host, <<"csr">>, <<"Generated private key and CSR">>),
                            issue_powerdns_after_csr(
                                DbPath,
                                Site,
                                Host,
                                ApiUrl,
                                ApiKey,
                                Sid,
                                Zone,
                                Identifiers,
                                CsrDer,
                                KeyPem
                            )
                    end
            end
    end.

issue_powerdns_after_csr(DbPath, Site, Host, ApiUrl, ApiKey, ServerId, ZoneName, Identifiers, CsrDer, KeyPem) ->
    AcmeDir = acme_directory(),
    KidPathPre = filename:join(acme_data_dir(), "kid.txt"),
    ok = maybe_drop_staging_kid_for_production(AcmeDir, KidPathPre),
    Terms = application:get_env(pertisk_eproxy, acme_terms_agreed, false),
    case Terms of
        false ->
            lager:warning("ACME disabled: set {acme_terms_agreed, true} in sys.config to issue for ~s", [Host]),
            ssl_job_err(Host, terms_not_agreed),
            {error, terms_not_agreed};
        true ->
            {Jwk, Kid} = load_account_key(),
            KidPathFile = filename:join(acme_data_dir(), "kid.txt"),
            AddFun = fun(TxtFqdn, Digest) ->
                RecName = pertisk_eproxy_dns_powerdns:txt_record_name(TxtFqdn, ZoneName),
                case pertisk_eproxy_dns_powerdns:create_txt(ApiUrl, ApiKey, ServerId, ZoneName, RecName, Digest) of
                    {ok, Opaque} -> {ok, Opaque};
                    Err -> Err
                end
            end,
            DelFun = fun
                ({powerdns, Url, Key, Sid, Zone, Name}) ->
                    pertisk_eproxy_dns_powerdns:delete_txt(Url, Key, Sid, Zone, Name);
                (_) ->
                    ok
            end,
            Progress = fun(Phase, Msg) -> ssl_job(Host, Phase, Msg) end,
            Opts = #{
                directory_url => AcmeDir,
                account_jwk => Jwk,
                account_kid => Kid,
                contact_email => contact_bin(Site),
                terms_agreed => true,
                identifiers => Identifiers,
                csr_der => CsrDer,
                dns_add => AddFun,
                dns_del => DelFun,
                dns_propagation_delay_ms => erlang:max(45000, acme_dns_propagation_delay_ms()),
                progress => Progress
            },
            case pertisk_eproxy_acme_client:obtain_certificate(Opts) of
                {error, _} = E ->
                    ssl_job_err(Host, E),
                    E;
                {ok, PemChain, KidOut} ->
                    maybe_write_kid(KidPathFile, Kid, KidOut),
                    _ = save_and_register(DbPath, Site, Host, PemChain, KeyPem),
                    ssl_job_done(Host, <<"TLS certificate issued and saved">>),
                    ok
            end
    end.

issue_duckdns(DbPath, Site, Host, Row) ->
    Creds = maps:get(credentials, Row, #{}),
    Domain = cred_get(Creds, [<<"domain">>]),
    Token = cred_get(Creds, [<<"token">>]),
    case {Domain, Token} of
        {undefined, _} ->
            ssl_job_err(Host, missing_domain),
            {error, missing_domain};
        {_, undefined} ->
            ssl_job_err(Host, missing_token),
            {error, missing_token};
        _ ->
            ssl_job(Host, <<"zone">>, iolist_to_binary([<<"DuckDNS domain: ">>, Domain])),
            Identifiers = site_identifiers(Site, Host),
            case pertisk_eproxy_acme_csr:generate_rsa_csr(Identifiers) of
                {error, Reason} ->
                    ssl_job_err(Host, {csr_failed, Reason}),
                    {error, {csr_failed, Reason}};
                {ok, #{csr_der := CsrDer, key_pem := KeyPem}} ->
                    ssl_job(Host, <<"csr">>, <<"Generated private key and CSR">>),
                    issue_duckdns_after_csr(DbPath, Site, Host, Domain, Token, Identifiers, CsrDer, KeyPem)
            end
    end.

issue_duckdns_after_csr(DbPath, Site, Host, Domain, Token, Identifiers, CsrDer, KeyPem) ->
    AcmeDir = acme_directory(),
    KidPathPre = filename:join(acme_data_dir(), "kid.txt"),
    ok = maybe_drop_staging_kid_for_production(AcmeDir, KidPathPre),
    Terms = application:get_env(pertisk_eproxy, acme_terms_agreed, false),
    case Terms of
        false ->
            lager:warning("ACME disabled: set {acme_terms_agreed, true} in sys.config to issue for ~s", [Host]),
            ssl_job_err(Host, terms_not_agreed),
            {error, terms_not_agreed};
        true ->
            {Jwk, Kid} = load_account_key(),
            KidPathFile = filename:join(acme_data_dir(), "kid.txt"),
            AddFun = fun(_TxtFqdn, Digest) ->
                case pertisk_eproxy_dns_duckdns:create_txt(Domain, Token, Digest) of
                    {ok, Opaque} -> {ok, Opaque};
                    Err -> Err
                end
            end,
            DelFun = fun
                ({duckdns, Dom, Tok}) ->
                    pertisk_eproxy_dns_duckdns:delete_txt(Dom, Tok);
                (_) ->
                    ok
            end,
            Progress = fun(Phase, Msg) -> ssl_job(Host, Phase, Msg) end,
            Opts = #{
                directory_url => AcmeDir,
                account_jwk => Jwk,
                account_kid => Kid,
                contact_email => contact_bin(Site),
                terms_agreed => true,
                identifiers => Identifiers,
                csr_der => CsrDer,
                dns_add => AddFun,
                dns_del => DelFun,
                dns_propagation_delay_ms => erlang:max(45000, acme_dns_propagation_delay_ms()),
                progress => Progress
            },
            case pertisk_eproxy_acme_client:obtain_certificate(Opts) of
                {error, _} = E ->
                    ssl_job_err(Host, E),
                    E;
                {ok, PemChain, KidOut} ->
                    maybe_write_kid(KidPathFile, Kid, KidOut),
                    _ = save_and_register(DbPath, Site, Host, PemChain, KeyPem),
                    ssl_job_done(Host, <<"TLS certificate issued and saved">>),
                    ok
            end
    end.

issue_lego_provider(DbPath, Site, Host, Row, Provider) ->
    Terms = application:get_env(pertisk_eproxy, acme_terms_agreed, false),
    case Terms of
        false ->
            lager:warning("ACME disabled: set {acme_terms_agreed, true} in sys.config to issue for ~s", [Host]),
            ssl_job_err(Host, terms_not_agreed),
            {error, terms_not_agreed};
        true ->
            Creds = maps:get(credentials, Row, #{}),
            Identifiers = site_identifiers(Site, Host),
            case lego_runtime_provider(Provider, Creds) of
                {error, _} = E ->
                    ssl_job_err(Host, E),
                    E;
                {ok, LegoProvider} ->
                    ssl_job(
                        Host,
                        <<"provider">>,
                        iolist_to_binary([<<"Lego DNS provider: ">>, pertisk_eproxy_acme_lego:provider_to_binary(LegoProvider)])
                    ),
                    Progress = fun(Phase, Msg) -> ssl_job(Host, Phase, Msg) end,
                    case pertisk_eproxy_acme_lego:obtain_certificate(
                        LegoProvider,
                        Creds,
                        Identifiers,
                        contact_bin(Site),
                        acme_directory(),
                        acme_data_dir(),
                        cert_slug(Host),
                        Progress
                    ) of
                        {ok, PemChain, KeyPem} ->
                            _ = save_and_register(DbPath, Site, Host, PemChain, KeyPem),
                            ssl_job_done(Host, <<"TLS certificate issued and saved">>),
                            ok;
                        {error, lego_not_found} ->
                            Hint =
                                <<"Lego binary is not installed on this node. Install lego and ensure it is in PATH, then retry Auto SSL.">>,
                            ssl_job(Host, <<"error">>, Hint),
                            {error, {lego_not_found, Hint}};
                        {error, _} = E2 ->
                            ssl_job_err(Host, E2),
                            E2
                    end
            end
    end.

lego_runtime_provider(customlego, Creds) ->
    case cred_get(Creds, [<<"lego_provider">>, <<"provider">>, <<"provider_name">>]) of
        undefined ->
            {error, missing_lego_provider};
        Val ->
            {ok, string:lowercase(Val)}
    end;
lego_runtime_provider(Provider, _Creds) ->
    {ok, Provider}.

zone_name_bin(B) when is_binary(B) -> B;
zone_name_bin(L) when is_list(L) -> unicode:characters_to_binary(L, utf8);
zone_name_bin(X) -> iolist_to_binary(io_lib:format("~p", [X])).

ssl_job(Host, Phase, Msg) when is_binary(Host), is_binary(Phase), is_binary(Msg) ->
    pertisk_eproxy_admin_realtime:ssl_job(#{
        host => Host,
        phase => Phase,
        message => Msg
    }).

ssl_job_err(Host, Err) when is_binary(Host) ->
    Msg = iolist_to_binary(io_lib:format("~p", [Err])),
    pertisk_eproxy_admin_realtime:ssl_job(#{
        host => Host,
        phase => <<"error">>,
        message => Msg
    }),
    _ = spawn(fun() ->
        timer:sleep(60000),
        pertisk_eproxy_admin_realtime:clear_ssl_job(Host)
    end).

ssl_job_done(Host, Msg) when is_binary(Host), is_binary(Msg) ->
    pertisk_eproxy_admin_realtime:ssl_job(#{
        host => Host,
        phase => <<"complete">>,
        message => Msg
    }),
    _ = spawn(fun() ->
        timer:sleep(15000),
        pertisk_eproxy_admin_realtime:clear_ssl_job(Host)
    end).

%% Opaque: {cf, Token, ZoneId, RecordId}
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

contact_bin(Site) ->
    case maps:get(acme_contact_email, Site, <<"">>) of
        E when is_binary(E) -> E;
        E when is_list(E) -> unicode:characters_to_binary(E, utf8)
    end.

resolve_zone(Token, undefined, Host) ->
    Lookup = zone_lookup_host(Host),
    {ok, #{zone_id := Zi, zone_name := Zn}} = pertisk_eproxy_dns_cloudflare:find_zone(Token, Lookup),
    {Zi, Zn};
resolve_zone(Token, ZoneId0, _Host) when ZoneId0 =/= undefined ->
    Zi = iolist_to_binary(ZoneId0),
    {ok, #{zone_name := Zn}} = pertisk_eproxy_dns_cloudflare:get_zone(Token, Zi),
    {Zi, Zn}.

zone_lookup_host(<<$*, $., Rest/binary>>) ->
    Rest;
zone_lookup_host(H) ->
    H.

%% Wildcard + apex: identifiers *.BASE and BASE (DNS-01 for both uses _acme-challenge.<BASE>).
%% BASE defaults to site host, and can be overridden with site.acme_wildcard_base from admin UI.
site_identifiers(Site, Host) ->
    case maps:get(wildcard, Site, false) of
        true ->
            Base0 = maps:get(acme_wildcard_base, Site, wildcard_default_base(Host)),
            Base = zone_lookup_host(iolist_to_binary(Base0)),
            [<<"*.", Base/binary>>, Base];
        _ ->
            [Host]
    end.

wildcard_default_base(Host) when is_binary(Host) ->
    H = zone_lookup_host(Host),
    Parts = [P || P <- binary:split(H, <<".">>, [global]), P =/= <<>>],
    case length(Parts) >= 3 of
        true ->
            iolist_to_binary(lists:join(<<".">>, tl(Parts)));
        false ->
            H
    end.

acme_directory() ->
    case application:get_env(pertisk_eproxy, acme_directory_url) of
        {ok, U} when is_binary(U) -> U;
        {ok, U} when is_list(U) -> unicode:characters_to_binary(U, utf8);
        undefined ->
            <<"https://acme-staging-v02.api.letsencrypt.org/directory">>
    end.

acme_dns_propagation_delay_ms() ->
    case application:get_env(pertisk_eproxy, acme_dns_propagation_delay_ms) of
        {ok, Ms} when is_integer(Ms), Ms >= 0 -> Ms;
        _ -> 15000
    end.

acme_data_dir() ->
    case application:get_env(pertisk_eproxy, acme_data_dir) of
        {ok, D} when is_list(D) -> D;
        _ -> "data/acme"
    end.

load_account_key() ->
    Dir = acme_data_dir(),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    PemPath = filename:join(Dir, "account.pem"),
    KidPath = filename:join(Dir, "kid.txt"),
    Jwk = load_or_create_jwk(PemPath),
    Kid = read_kid(KidPath),
    {Jwk, Kid}.

load_or_create_jwk(Path) ->
    case file:read_file(Path) of
        {ok, Pem} when byte_size(Pem) > 32 ->
            pertisk_eproxy_acme_jwk:normalize_ec_key(jose_jwk:from_pem(Pem));
        _ ->
            Jwk = jose_jwk:generate_key({ec, <<"P-256">>}),
            {_, Pem} = jose_jwk:to_pem(Jwk),
            ok = file:write_file(Path, Pem),
            _ = try file:change_mode(Path, 8#600) catch _:_ -> ok end,
            Jwk
    end.

read_kid(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            case string:trim(binary_to_list(Bin)) of
                "" -> undefined;
                Line -> list_to_binary(Line)
            end;
        _ ->
            undefined
    end.

maybe_write_kid(_Path, _, undefined) ->
    ok;
maybe_write_kid(Path, undefined, Kid) when is_binary(Kid) ->
    write_kid(Path, Kid);
maybe_write_kid(_Path, _, _) ->
    ok.

save_and_register(DbPath, _Site, Host, PemChain, KeyPem) ->
    Slug = cert_slug(Host),
    Dir = filename:join([acme_data_dir(), "certs", Slug]),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    CertPath = filename:join(Dir, "fullchain.pem"),
    KeyPath = filename:join(Dir, "privkey.pem"),
    ok = file:write_file(CertPath, PemChain),
    ok = file:write_file(KeyPath, KeyPem),
    _ = try file:change_mode(KeyPath, 8#600) catch _:_ -> ok end,
    CertName = cert_db_name(Host),
    {ok, _Id} = pertisk_eproxy_db:upsert_acme_certificate_pem(DbPath, CertName, CertPath, KeyPath),
    spawn(fun() -> patch_site_certificate(Host, CertName, CertPath, KeyPath) end),
    ok.

cert_slug(Host) ->
    binary:replace(binary:replace(Host, <<"*">>, <<"star">>, [global]), <<"/">>, <<"_">>, [global]).

cert_db_name(Host) ->
    binary_to_list(<<"acme/", (cert_slug(Host))/binary>>).

patch_site_certificate(HostBin, CertName, CertPath, KeyPath) ->
    timer:sleep(500),
    C = pertisk_eproxy_config:get_config(),
    Sites = maps:get(sites, C, []),
    NewSites = lists:map(
        fun(S) ->
            H = site_host_bin(S),
            case H =:= HostBin of
                true -> S#{certificate => CertName};
                false -> S
            end
        end,
        Sites),
    NextC = C#{
        sites => NewSites,
        tls_cert_file => CertPath,
        tls_key_file => KeyPath
    },
    case pertisk_eproxy_config:put_config(NextC) of
        ok -> ok;
        {error, R} -> lager:error("ACME: could not attach certificate to site ~s: ~p", [HostBin, R])
    end,
    %% ACME cert updates should only refresh proxy TLS listeners.
    %% Restarting the management listener can cause transient or sticky
    %% admin UI fetch failures while /api reconnects.
    _ = catch pertisk_eproxy_app:reload_proxy_tls_listeners().

write_kid(Path, Kid) when is_binary(Kid) ->
    ok = file:write_file(Path, [Kid, $\n]).
