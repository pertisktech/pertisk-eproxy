%% @doc Normalised HTTP request map (Ranch / HTTP/1.1).
-module(pertisk_req).

-export([
    new/1,
    method/1,
    path/1,
    raw_path/1,
    qs/1,
    host/1,
    route_host/1,
    headers/1,
    header/2,
    header/3,
    body/1,
    peer/1,
    scheme/1,
    port/1,
    listener/1,
    mode/1,
    bindings/1,
    binding/2,
    qparse/1,
    http_version/1
]).

-export_type([req/0]).

-type req() :: #{
    listener := atom(),
    mode => proxy | proxy_admin,
    method := binary(),
    path := binary(),
    raw_path := binary(),
    qs := binary(),
    host := binary(),
    route_host := binary(),
    headers := #{binary() => binary()},
    body := binary(),
    peer := {inet:ip_address(), inet:port_number()},
    scheme := http | https,
    port := pos_integer(),
    bindings := #{atom() => binary()},
    http_version := binary()
}.

new(Base) when is_map(Base) ->
    maps:merge(
        #{
            headers => #{},
            body => <<>>,
            bindings => #{},
            http_version => <<"HTTP/1.1">>
        },
        Base
    ).

method(#{method := M}) -> M.
path(#{path := P}) -> P.
raw_path(#{raw_path := R}) -> R.
qs(#{qs := Q}) -> Q.
host(#{host := H}) -> H.
route_host(#{route_host := R}) -> R.
headers(#{headers := H}) -> H.
body(#{body := B}) -> B.
peer(#{peer := P}) -> P.
scheme(#{scheme := S}) -> S.
port(#{port := P}) -> P.
listener(#{listener := L}) -> L.
mode(R) -> maps:get(mode, R, undefined).
bindings(#{bindings := B}) -> B.
http_version(#{http_version := V}) -> V.

header(Req, K) -> header(Req, K, undefined).
header(#{headers := H}, K, Def) ->
    Kb = norm_key(K),
    maps:get(Kb, H, Def).

norm_key(K) when is_binary(K) -> string:lowercase(K);
norm_key(K) when is_list(K) -> string:lowercase(list_to_binary(K)).

binding(Req, K) when is_atom(K) ->
    maps:get(K, bindings(Req), undefined).

qparse(Req) ->
    cow_qs:parse_qs(qs(Req)).
