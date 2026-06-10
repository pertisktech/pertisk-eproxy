-module(pertisk_eproxy_shell_tests).

-include_lib("eunit/include/eunit.hrl").

os_cmd_wraps_ld_library_path_test() ->
    Out = pertisk_eproxy_shell:os_cmd("echo marker"),
    ?assertNotEqual(nomatch, binary:match(list_to_binary(Out), <<"marker">>)).

openssl_executable_finds_or_errors_test() ->
    case pertisk_eproxy_shell:openssl_executable() of
        {ok, Path} ->
            ?assert(is_list(Path)),
            ?assert(filelib:is_file(Path));
        {error, openssl_not_found} ->
            ok
    end.
