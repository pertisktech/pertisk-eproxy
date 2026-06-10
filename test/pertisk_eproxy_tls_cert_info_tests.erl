-module(pertisk_eproxy_tls_cert_info_tests).

-include_lib("eunit/include/eunit.hrl").

describe_pem_data_empty_returns_error_test() ->
    ?assertEqual(error, pertisk_eproxy_tls_cert_info:describe_pem_data(<<>>)).

describe_pem_data_invalid_returns_error_test() ->
    ?assertEqual(error, pertisk_eproxy_tls_cert_info:describe_pem_data(<<"not a pem">>)).

describe_listener_pem_nonexistent_returns_error_test() ->
    ?assertEqual(error, pertisk_eproxy_tls_cert_info:describe_listener_pem("/nonexistent/path/to/cert.pem")).

listener_cert_rows_returns_list_test() ->
    Result = pertisk_eproxy_tls_cert_info:listener_cert_rows(),
    ?assert(is_list(Result)).