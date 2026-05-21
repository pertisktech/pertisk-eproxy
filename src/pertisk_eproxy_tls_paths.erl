%% @doc Default listener TLS paths (release: under {@link code:priv_dir/1}).
-module(pertisk_eproxy_tls_paths).

-export([default_cert_file/0, default_key_file/0, resolve_cert_file/1, resolve_key_file/1]).

-spec default_cert_file() -> string().
default_cert_file() ->
    filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]).

-spec default_key_file() -> string().
default_key_file() ->
    filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]).

-spec resolve_cert_file(map() | undefined) -> string() | undefined.
resolve_cert_file(Config) when is_map(Config) ->
    case maps:get(tls_cert_file, Config, undefined) of
        undefined -> default_if_readable(default_cert_file());
        V -> normalize(V)
    end;
resolve_cert_file(_) ->
    default_if_readable(default_cert_file()).

-spec resolve_key_file(map() | undefined) -> string() | undefined.
resolve_key_file(Config) when is_map(Config) ->
    case maps:get(tls_key_file, Config, undefined) of
        undefined -> default_if_readable(default_key_file());
        V -> normalize(V)
    end;
resolve_key_file(_) ->
    default_if_readable(default_key_file()).

default_if_readable(Path) ->
    case filelib:is_file(Path) of
        true -> Path;
        false -> undefined
    end.

normalize(undefined) -> undefined;
normalize(null) -> undefined;
normalize(V) when is_binary(V) -> binary_to_list(V);
normalize(V) when is_list(V) -> V;
normalize(_) -> undefined.
