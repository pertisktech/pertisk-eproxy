%% @doc Shell out to host CLI tools without inheriting release OpenSSL libs.
%%
%% RPM/systemd sets `LD_LIBRARY_PATH` to `/opt/pertisk-eproxy/lib/openssl` so OTP's
%% crypto NIF loads. That breaks `/usr/bin/openssl` (built against the host libssl).
-module(pertisk_eproxy_shell).

-export([os_cmd/1, openssl_executable/0]).

-spec os_cmd(string()) -> string().
os_cmd(Cmd) when is_list(Cmd) ->
    os:cmd(wrap_host_cmd(Cmd)).

-spec openssl_executable() -> {ok, string()} | {error, openssl_not_found}.
openssl_executable() ->
    case os:find_executable("openssl") of
        false -> {error, openssl_not_found};
        Path -> {ok, Path}
    end.

%% Run via /bin/sh; clear LD_LIBRARY_PATH so host binaries use system libcrypto.
wrap_host_cmd(Cmd) ->
    "LD_LIBRARY_PATH= " ++ Cmd.
