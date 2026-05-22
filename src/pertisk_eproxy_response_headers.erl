%% @doc App identity headers on every HTTP response (Cowboy map and HTTP/3 proplist).
-module(pertisk_eproxy_response_headers).

-export([app_name/0, app_version/0, merge/1, merge_h3/1]).

-define(APP_NAME, <<"pertisk-eproxy">>).

-spec app_name() -> binary().
app_name() ->
    ?APP_NAME.

-spec app_version() -> binary().
app_version() ->
    pertisk_eproxy_admin_management_snapshot:app_version().

-spec merge(map()) -> map().
merge(Headers) when is_map(Headers) ->
    maps:merge(Headers, identity_map()).

-spec merge_h3([{term(), term()}]) -> [{binary(), binary()}].
merge_h3(Headers) when is_list(Headers) ->
    identity_h3() ++ strip_identity_keys(Headers).

identity_map() ->
    #{
        <<"server">> => server_value(),
        <<"x-app-name">> => app_name(),
        <<"x-app-version">> => app_version()
    }.

identity_h3() ->
    [
        {<<"server">>, server_value()},
        {<<"x-app-name">>, app_name()},
        {<<"x-app-version">>, app_version()}
    ].

server_value() ->
    <<(app_name())/binary, "/", (app_version())/binary>>.

strip_identity_keys(Headers) ->
    lists:filter(
        fun({K, _}) ->
            not lists:member(header_key_lower(K), [<<"server">>, <<"x-app-name">>, <<"x-app-version">>])
        end,
        Headers
    ).

header_key_lower(K) when is_binary(K) ->
    string:lowercase(K);
header_key_lower(K) when is_list(K) ->
    list_to_binary(string:lowercase(K));
header_key_lower(K) when is_atom(K) ->
    atom_to_binary(K, utf8).
