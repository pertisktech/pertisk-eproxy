%% @doc Merge proxy-added response headers (global config + per-site overlay).
%%
%% Same layering as pertisk-rproxy: upstream/base headers first, then global
%% {@link security_headers}, then per-site {@link security_headers} when present.
%% Empty header values remove that key from the response. Non-HTTPS responses
%% skip {@code strict-transport-security}. Legacy {@code override_security_headers}
%% still means “site map only, no global”.

-module(pertisk_eproxy_security_headers).

-export([merge_response_headers/3, parse_json_object/1]).

-spec merge_response_headers(binary(), map(), binary()) -> map().
merge_response_headers(HostBin, HeadersMap, ForwardedProto)
    when is_binary(HostBin), is_map(HeadersMap), is_binary(ForwardedProto) ->
    Host = string:lowercase(HostBin),
    Cfg = pertisk_eproxy_config:get_config(),
    Global = maps:get(security_headers, Cfg, #{}),
    Sites = maps:get(sites, Cfg, []),
    case pertisk_eproxy_router:match_best_site(Sites, Host) of
        undefined ->
            merge_layer(HeadersMap, Global, ForwardedProto);
        Site ->
            case maps:get(override_security_headers, Site, false) of
                true ->
                    SiteHs = maps:get(security_headers, Site, #{}),
                    merge_layer(HeadersMap, SiteHs, ForwardedProto);
                false ->
                    Base = merge_layer(HeadersMap, Global, ForwardedProto),
                    case maps:find(security_headers, Site) of
                        {ok, SiteHs} when is_map(SiteHs) ->
                            merge_layer(Base, SiteHs, ForwardedProto);
                        _ ->
                            Base
                    end
            end
    end.

-spec merge_layer(map(), map(), binary()) -> map().
merge_layer(Base, LayerMap, ForwardedProto) when is_map(Base), is_map(LayerMap), is_binary(ForwardedProto) ->
    maps:fold(
        fun(K, V, Acc) ->
            Kb = header_name_bin(K),
            case is_strict_transport(Kb) andalso ForwardedProto =/= <<"https">> of
                true ->
                    Acc;
                false ->
                    Val = header_value_bin(V),
                    case is_blank_header_value(Val) of
                        true ->
                            maps:remove(Kb, Acc);
                        false ->
                            Acc#{Kb => Val}
                    end
            end
        end,
        Base,
        LayerMap
    ).

-spec parse_json_object(term()) -> map().
parse_json_object(null) ->
    #{};
parse_json_object(M) when is_map(M) ->
    maps:fold(
        fun(K, V, Acc) ->
            Key = header_name_bin(K),
            Val = header_value_bin(V),
            Acc#{Key => Val}
        end,
        #{},
        M
    );
parse_json_object(_) ->
    #{}.

%% ---------------------------------------------------------------------------
%% Internal
%% ---------------------------------------------------------------------------

is_strict_transport(<<"strict-transport-security">>) -> true;
is_strict_transport(_) -> false.

is_blank_header_value(B) when is_binary(B) ->
    byte_size(string:trim(B, both, [$\s, $\t, $\r, $\n])) =:= 0;
is_blank_header_value(_) ->
    true.

header_name_bin(K) when is_binary(K) ->
    string:lowercase(K);
header_name_bin(K) when is_atom(K) ->
    string:lowercase(atom_to_binary(K, utf8));
header_name_bin(K) ->
    string:lowercase(iolist_to_binary(io_lib:format("~p", [K]))).

header_value_bin(V) when is_binary(V) ->
    V;
header_value_bin(V) when is_list(V) ->
    try unicode:characters_to_binary(V, utf8) catch _:_ -> iolist_to_binary(V) end;
header_value_bin(V) when is_integer(V) ->
    integer_to_binary(V);
header_value_bin(true) ->
    <<"true">>;
header_value_bin(false) ->
    <<"false">>;
header_value_bin(V) ->
    iolist_to_binary(io_lib:format("~p", [V])).

