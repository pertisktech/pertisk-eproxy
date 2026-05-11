%% @doc Read listener TLS certificate PEM and extract metadata for GET /api/certificates.
-module(pertisk_eproxy_tls_cert_info).

-export([listener_cert_rows/0, describe_listener_pem/1]).

%% @doc Decode listener PEM at Path (troubleshooting). Same logic as GET /api/certificates.
-spec describe_listener_pem(string() | binary()) -> {ok, map()} | error.
describe_listener_pem(Path) when is_list(Path); is_binary(Path) ->
    describe_pem_file(Path).

-include_lib("public_key/include/public_key.hrl").

-define(CERT_ID, <<"listener-tls">>).

-spec listener_cert_rows() -> [map()].
listener_cert_rows() ->
    C = pertisk_eproxy_config:get_config(),
    CF = maps:get(tls_cert_file, C, undefined),
    KF = maps:get(tls_key_file, C, undefined),
    case path_ok(CF) andalso path_ok(KF) of
        false ->
            [];
        true ->
            Path = to_list(CF),
            SiteHosts = site_hosts_for_cert_id(?CERT_ID),
            case describe_pem_file(Path) of
                {ok, #{hosts := Hosts, not_before := NB, not_after := NA, issuer := Issuer}} ->
                    [cert_json(?CERT_ID, Hosts, NB, NA, Issuer, SiteHosts)];
                error ->
                    lager:warning(
                        "Listener TLS paths set but certificate PEM at ~s could not be read or parsed",
                        [Path]
                    ),
                    []
            end
    end.

path_ok(undefined) -> false;
path_ok(<<>>) -> false;
path_ok([]) -> false;
path_ok(_) -> true.

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L.

cert_json(Id, Hosts, NB, NA, Issuer, SiteHosts) ->
    Domain =
        case Hosts of
            [H | _] -> H;
            _ -> <<>>
        end,
    #{
        <<"id">> => Id,
        <<"domain">> => Domain,
        <<"hosts">> => Hosts,
        <<"issuer">> => Issuer,
        <<"challenge">> => <<"static PEM">>,
        <<"source_type">> => <<"tls_listener">>,
        <<"created_at">> => NB,
        <<"expires_at">> => NA,
        <<"next_renew">> => <<>>,
        <<"sites">> => SiteHosts
    }.

site_hosts_for_cert_id(CertId) when is_binary(CertId) ->
    Sites = pertisk_eproxy_config:get_sites(),
    lists:filtermap(
        fun(S) ->
            H = maps:get(host, S),
            C = maps:get(certificate, S, undefined),
            case cert_field_matches(C, CertId) of
                true -> {true, host_to_bin(H)};
                false -> false
            end
        end,
        Sites
    ).

cert_field_matches(undefined, _) -> false;
cert_field_matches(null, _) -> false;
cert_field_matches(C, Id) when is_binary(C) -> C =:= Id;
cert_field_matches(C, Id) when is_list(C) -> iolist_to_binary(C) =:= Id;
cert_field_matches(_, _) -> false.

host_to_bin(H) when is_binary(H) -> H;
host_to_bin(H) when is_list(H) -> iolist_to_binary(H).

describe_pem_file(Path) ->
    case file:read_file(Path) of
        {ok, PemBin} ->
            Ders = [D || {'Certificate', D, not_encrypted} <- public_key:pem_decode(PemBin)],
            describe_pem_chain(Ders);
        _ ->
            error
    end.

describe_pem_chain([]) ->
    error;
describe_pem_chain(Ders) ->
    Infos = lists:filtermap(
        fun(Der) ->
            case describe_one_der(Der) of
                error -> false;
                Map when is_map(Map) -> {true, Map}
            end
        end,
        Ders
    ),
    case Infos of
        [] ->
            error;
        _ ->
            %% Prefer a certificate that has a real DNS name / CN (PEM order varies).
            case lists:dropwhile(fun is_placeholder_hosts_map/1, Infos) of
                [] -> {ok, hd(Infos)};
                [Best | _] -> {ok, Best}
            end
    end.

is_placeholder_hosts_map(#{hosts := [<<"TLS listener">>]}) -> true;
is_placeholder_hosts_map(_) -> false.

describe_one_der(Der) ->
    try
        %% Do not match on #'OTPCertificate'{} / #'OTPTBSCertificate'{}: record layouts can
        %% differ between the OTP used to compile this module and the runtime OTP, which
        %% caused silent match failures and empty metadata. Use positional tuple access.
        Cert = public_key:pkix_decode_cert(Der, otp),
        true = tuple_size(Cert) >= 4,
        OTPCertTag = element(1, Cert),
        true = (OTPCertTag =:= 'OTPCertificate'),
        Tbs = element(2, Cert),
        true = tuple_size(Tbs) >= 7,
        Issuer = element(5, Tbs),
        Validity = element(6, Tbs),
        Subject = element(7, Tbs),
        Exts0 =
            case tuple_size(Tbs) of
                Sz when Sz >= 11 -> element(11, Tbs);
                _ -> asn1_NOVALUE
            end,
        {NB, NA} = validity_not_before_after(Validity),
        SanDns = subject_alt_dns_names(Exts0),
        SubjectPairs = directory_name_to_pairs(Subject),
        Cns = [V || {commonName, V} <- SubjectPairs],
        Hosts = merge_display_hosts(SanDns, Cns),
        IssuerStr = directory_name_to_issuer_label(Issuer),
        #{hosts => Hosts, not_before => NB, not_after => NA, issuer => IssuerStr}
    catch
        _:_ ->
            error
    end.

validity_not_before_after(V) when is_tuple(V), tuple_size(V) =:= 3, element(1, V) =:= 'Validity' ->
    NB = element(2, V),
    NA = element(3, V),
    {format_asn1_time(NB), format_asn1_time(NA)};
validity_not_before_after(_) ->
    {<<>>, <<>>}.

%% Prefer SAN dNSName entries; add subject CN if not already listed.
merge_display_hosts(SanDns, Cns) ->
    SanB = [as_bin(S) || S <- SanDns],
    CnB = [as_bin(C) || C <- Cns],
    Merged = SanB ++ [C || C <- CnB, not lists:member(C, SanB)],
    case Merged of
        [] -> [<<"TLS listener">>];
        _ -> Merged
    end.

as_bin(V) when is_binary(V) -> V;
as_bin(V) when is_list(V) -> iolist_to_binary(V);
as_bin(V) -> iolist_to_binary(io_lib:format("~p", [V])).

extensions_list(asn1_NOVALUE) -> [];
extensions_list(undefined) -> [];
extensions_list(L) when is_list(L) -> L;
extensions_list(_) -> [].

subject_alt_dns_names(Exts0) ->
    Exts = extensions_list(Exts0),
    lists:flatmap(fun ext_san_dns/1, Exts).

ext_san_dns(#'Extension'{extnID = ?'id-ce-subjectAltName', extnValue = Names}) ->
    dns_names_from_general_names(Names);
ext_san_dns(_) ->
    [].

dns_names_from_general_names(Names) when is_list(Names) ->
    [as_bin(D) || {dNSName, D} <- Names];
dns_names_from_general_names(_) ->
    [].

directory_name_to_issuer_label(DN) ->
    case directory_name_to_pairs(DN) of
        [] ->
            <<>>;
        Pairs ->
            Parts = [pair_to_label(P) || P <- Pairs],
            iolist_to_binary(lists:join(<<", ">>, Parts))
    end.

pair_to_label({unknown_oid, OID, V}) ->
    OStr = oid_to_dotted(OID),
    <<OStr/binary, <<"=">>/binary, (as_bin(V))/binary>>;
pair_to_label({Attr, V}) when is_atom(Attr) ->
    dn_pair(Attr, V).

oid_to_dotted(OID) when is_tuple(OID) ->
    iolist_to_binary(lists:join(<<$.>>, [integer_to_binary(I) || I <- tuple_to_list(OID)]));
oid_to_dotted(_) ->
    <<"oid">>.

directory_name_to_pairs(Name) ->
    Rows =
        case Name of
            {rdnSequence, R} when is_list(R) ->
                R;
            _ ->
                []
        end,
    lists:flatmap(fun(RDN) -> lists:flatmap(fun atv_pair/1, RDN) end, Rows).

atv_pair({'AttributeTypeAndValue', OID, Enc}) ->
    atv_pair_oid(OID, Enc);
atv_pair(_) ->
    [].

atv_pair_oid(OID, Enc) ->
    Val = decode_directory_string(Enc),
    case oid_to_attr(OID) of
        undefined ->
            [{unknown_oid, OID, Val}];
        Attr ->
            [{Attr, Val}]
    end.

oid_to_attr(?'id-at-commonName') -> commonName;
oid_to_attr(?'id-at-countryName') -> countryName;
oid_to_attr(?'id-at-organizationName') -> organizationName;
oid_to_attr(?'id-at-organizationalUnitName') -> organizationalUnitName;
oid_to_attr(?'id-at-serialNumber') -> serialNumber;
oid_to_attr(_) -> undefined.

decode_directory_string({utf8String, B}) when is_binary(B) ->
    B;
decode_directory_string({printableString, L}) ->
    iolist_to_binary(L);
decode_directory_string({ia5String, L}) ->
    iolist_to_binary(L);
decode_directory_string({teletexString, L}) ->
    iolist_to_binary(L);
decode_directory_string({universalString, L}) ->
    iolist_to_binary(L);
decode_directory_string({bmpString, L}) ->
    iolist_to_binary(L);
decode_directory_string(Other) ->
    iolist_to_binary(io_lib:format("~p", [Other])).

dn_pair(Attr, Val) ->
    A = attr_label(Attr),
    V = as_bin(Val),
    <<A/binary, <<"=">>/binary, V/binary>>.

attr_label(commonName) -> <<"CN">>;
attr_label(organizationName) -> <<"O">>;
attr_label(organizationalUnitName) -> <<"OU">>;
attr_label(countryName) -> <<"C">>;
attr_label(serialNumber) -> <<"SN">>;
attr_label(_) -> <<"attr">>.

format_asn1_time({utcTime, T}) ->
    format_asn1_time(iolist_to_binary(T));
format_asn1_time({generalTime, T}) ->
    format_asn1_time(iolist_to_binary(T));
format_asn1_time(B) when is_binary(B) ->
    case B of
        <<_:4/binary, _:2/binary, _:2/binary, _:2/binary, _:2/binary, _:2/binary, "Z">> when byte_size(B) =:= 15 ->
            format_general_time(B);
        _ ->
            format_utc_time(B)
    end;
format_asn1_time(_) ->
    <<>>.

%% UTCTime: YYMMDDhhmmssZ (13) or YYMMDDhhmmZ (11) with optional trailing Z
format_utc_time(Bin) ->
    case Bin of
        <<YY:2/binary, Mo:2/binary, Da:2/binary, H:2/binary, Mi:2/binary, S:2/binary, "Z">> ->
            format_ymdhms_utc(YY, Mo, Da, H, Mi, S);
        <<YY:2/binary, Mo:2/binary, Da:2/binary, H:2/binary, Mi:2/binary, "Z">> ->
            format_ymdhms_utc(YY, Mo, Da, H, Mi, <<"00">>);
        _ ->
            Bin
    end.

format_ymdhms_utc(YY, Mo, Da, H, Mi, S) ->
    YNum = binary_to_integer(YY),
    Year =
        case YNum >= 50 of
            true -> 1900 + YNum;
            false -> 2000 + YNum
        end,
    iolist_to_binary(
        io_lib:format("~4..0w-~ts-~ts ~ts:~ts:~ts UTC", [
            Year, Mo, Da, H, Mi, S
        ])
    ).

%% GeneralizedTime: YYYYMMDDhhmmssZ (15) or fractional / timezone variants — handle Zulu 15-char
format_general_time(Bin) ->
    case Bin of
        <<Y:4/binary, Mo:2/binary, Da:2/binary, H:2/binary, Mi:2/binary, S:2/binary, "Z">> ->
            iolist_to_binary(
                io_lib:format("~ts-~ts-~ts ~ts:~ts:~ts UTC", [Y, Mo, Da, H, Mi, S])
            );
        _ ->
            Bin
    end.
