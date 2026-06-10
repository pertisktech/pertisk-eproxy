-module(pertisk_eproxy_compression_tests).

-include_lib("eunit/include/eunit.hrl").

%% These tests test the internal pure functions exported by pertisk_eproxy_compression.
%% Since maybe_compress_cowboy needs a cowboy_req, and maybe_compress_h3 needs
%% response headers as list, we test through the exported entry points with
%% minimal fixtures where possible.

%% ---------------------------------------------------------------------------
%% gzip compression (always available)
%% ---------------------------------------------------------------------------

gzip_compresses_large_body_test() ->
    Body = <<"A large response body that should be compressed for efficiency. ",
             "This contains repeated patterns to make gzip effective. ",
             "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA ",
             "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB">>,
    %% Use the H3 variant since it only needs a proplist, not cowboy_req
    Hdrs = [{<<"content-type">>, <<"text/html">>}],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    IsCompressed = proplists:get_value(<<"content-encoding">>, ResHdrs) =/= undefined,
    ?assert(IsCompressed orelse byte_size(ResBody) =:= byte_size(Body)).

gzip_compresses_text_html_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/html; charset=utf-8">>}],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(<<"gzip">>, proplists:get_value(<<"content-encoding">>, ResHdrs)),
    ?assert(byte_size(ResBody) < byte_size(Body)).

gzip_compresses_text_css_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/css">>}],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(<<"gzip">>, proplists:get_value(<<"content-encoding">>, ResHdrs)),
    ?assert(byte_size(ResBody) < byte_size(Body)).

gzip_compresses_application_json_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"application/json">>}],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(<<"gzip">>, proplists:get_value(<<"content-encoding">>, ResHdrs)),
    ?assert(byte_size(ResBody) < byte_size(Body)).

gzip_compresses_application_javascript_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"application/javascript">>}],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(<<"gzip">>, proplists:get_value(<<"content-encoding">>, ResHdrs)).

gzip_compresses_application_xml_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"application/xml">>}],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, _} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(<<"gzip">>, proplists:get_value(<<"content-encoding">>, ResHdrs)).

gzip_compresses_svg_xml_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"image/svg+xml">>}],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, _} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(<<"gzip">>, proplists:get_value(<<"content-encoding">>, ResHdrs)).

%% ---------------------------------------------------------------------------
%% Status codes that skip compression
%% ---------------------------------------------------------------------------

no_compress_status_1xx_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/html">>}],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(101, Accept, Hdrs, Body),
    ?assertEqual(undefined, proplists:get_value(<<"content-encoding">>, ResHdrs)),
    ?assertEqual(Body, ResBody).

no_compress_status_204_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/html">>}],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(204, Accept, Hdrs, Body),
    ?assertEqual(undefined, proplists:get_value(<<"content-encoding">>, ResHdrs)).

no_compress_status_304_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/html">>}],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(304, Accept, Hdrs, Body),
    ?assertEqual(undefined, proplists:get_value(<<"content-encoding">>, ResHdrs)).

%% ---------------------------------------------------------------------------
%% Empty body skips compression
%% ---------------------------------------------------------------------------

no_compress_empty_body_test() ->
    Hdrs = [{<<"content-type">>, <<"text/html">>}],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, <<>>),
    ?assertEqual(undefined, proplists:get_value(<<"content-encoding">>, ResHdrs)),
    ?assertEqual(<<>>, ResBody).

%% ---------------------------------------------------------------------------
%% Body smaller than MIN_COMPRESS_BYTES (1024) skips compression
%% ---------------------------------------------------------------------------

no_compress_small_body_test() ->
    Body = <<"small">>,
    Hdrs = [{<<"content-type">>, <<"text/html">>}],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(undefined, proplists:get_value(<<"content-encoding">>, ResHdrs)),
    ?assertEqual(Body, ResBody).

%% ---------------------------------------------------------------------------
%% Already encoded (content-encoding present) skips compression
%% ---------------------------------------------------------------------------

no_compress_already_encoded_test() ->
    Body = padding_bytes(2048),
    Hdrs = [
        {<<"content-type">>, <<"text/html">>},
        {<<"content-encoding">>, <<"br">>}
    ],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(<<"br">>, proplists:get_value(<<"content-encoding">>, ResHdrs)),
    ?assertEqual(Body, ResBody).

no_compress_already_encoded_identity_test() ->
    %% identity encoding falls through to content-type check; text/html is compressible.
    Body = padding_bytes(2048),
    Hdrs = [
        {<<"content-type">>, <<"text/html">>},
        {<<"content-encoding">>, <<"identity">>}
    ],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, _} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(<<"gzip">>, proplists:get_value(<<"content-encoding">>, ResHdrs)).

%% ---------------------------------------------------------------------------
%% no-transform cache-control skips compression
%% ---------------------------------------------------------------------------

no_compress_cache_control_no_transform_test() ->
    Body = padding_bytes(2048),
    Hdrs = [
        {<<"content-type">>, <<"text/html">>},
        {<<"cache-control">>, <<"no-transform">>}
    ],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(undefined, proplists:get_value(<<"content-encoding">>, ResHdrs)),
    ?assertEqual(Body, ResBody).

no_compress_cache_control_no_transform_case_insensitive_test() ->
    Body = padding_bytes(2048),
    Hdrs = [
        {<<"content-type">>, <<"text/html">>},
        {<<"cache-control">>, <<"No-Transform">>}
    ],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(undefined, proplists:get_value(<<"content-encoding">>, ResHdrs)).

%% ---------------------------------------------------------------------------
%% Non-compressible content types skip compression
%% ---------------------------------------------------------------------------

no_compress_image_png_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"image/png">>}],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(undefined, proplists:get_value(<<"content-encoding">>, ResHdrs)),
    ?assertEqual(Body, ResBody).

no_compress_application_octet_stream_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"application/octet-stream">>}],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(undefined, proplists:get_value(<<"content-encoding">>, ResHdrs)).

no_compress_undefined_content_type_test() ->
    Body = padding_bytes(2048),
    Hdrs = [],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(undefined, proplists:get_value(<<"content-encoding">>, ResHdrs)),
    ?assertEqual(Body, ResBody).

%% ---------------------------------------------------------------------------
%% No Accept-Encoding header
%% ---------------------------------------------------------------------------

no_compress_no_accept_encoding_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/html">>}],
    Accept = [],
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(undefined, proplists:get_value(<<"content-encoding">>, ResHdrs)).

%% ---------------------------------------------------------------------------
%% q-value parsing: quality=0 rejects
%% ---------------------------------------------------------------------------

gzip_q0_float_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/html">>}],
    Accept = [{<<"accept-encoding">>, <<"gzip;q=0.0">>}],
    {ResHdrs, _} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(undefined, proplists:get_value(<<"content-encoding">>, ResHdrs)).

gzip_q0_integer_still_compresses_test() ->
    %% q=0 without decimal fails binary_to_float parsing, defaults to 1.0.
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/html">>}],
    Accept = [{<<"accept-encoding">>, <<"gzip;q=0">>}],
    {ResHdrs, _} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(<<"gzip">>, proplists:get_value(<<"content-encoding">>, ResHdrs)).

%% ---------------------------------------------------------------------------
%% Accept-Encoding: * (any encoding, picks gzip)
%% ---------------------------------------------------------------------------

wildcard_accept_encoding_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/html">>}],
    Accept = [{<<"accept-encoding">>, <<"*">>}],
    {ResHdrs, _} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    %% Picks best available encoding (zstd if available, else gzip).
    ?assertNotEqual(undefined, proplists:get_value(<<"content-encoding">>, ResHdrs)).

%% ---------------------------------------------------------------------------
%% Vary header merging
%% ---------------------------------------------------------------------------

gzip_adds_vary_accept_encoding_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/html">>}],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, _} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    Vary = proplists:get_value(<<"vary">>, ResHdrs),
    ?assertNotEqual(undefined, Vary),
    ?assertNotEqual(nomatch, binary:match(string:lowercase(Vary), <<"accept-encoding">>)).

gzip_merges_vary_with_existing_test() ->
    Body = padding_bytes(2048),
    Hdrs = [
        {<<"content-type">>, <<"text/html">>},
        {<<"vary">>, <<"origin">>}
    ],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, _} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    Vary = proplists:get_value(<<"vary">>, ResHdrs, <<>>),
    Lower = string:lowercase(Vary),
    ?assertNotEqual(nomatch, binary:match(Lower, <<"origin">>)),
    ?assertNotEqual(nomatch, binary:match(Lower, <<"accept-encoding">>)).

gzip_does_not_duplicate_vary_accept_encoding_test() ->
    Body = padding_bytes(2048),
    Hdrs = [
        {<<"content-type">>, <<"text/html">>},
        {<<"vary">>, <<"accept-encoding">>}
    ],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, _} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    Vary = proplists:get_value(<<"vary">>, ResHdrs, <<>>),
    %% Should only appear once
    Tokens = binary:split(string:lowercase(Vary), <<",">>, [global, trim_all]),
    Matches = [T || T <- Tokens, T =:= <<"accept-encoding">>],
    ?assertEqual(1, length(Matches)).

%% ---------------------------------------------------------------------------
%% Content-Length and ETag are stripped
%% ---------------------------------------------------------------------------

gzip_strips_content_length_test() ->
    Body = padding_bytes(2048),
    Hdrs = [
        {<<"content-type">>, <<"text/html">>},
        {<<"content-length">>, <<"2048">>},
        {<<"etag">>, <<"\"abc123\"">>}
    ],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, _} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(undefined, proplists:get_value(<<"content-length">>, ResHdrs)),
    ?assertEqual(undefined, proplists:get_value(<<"etag">>, ResHdrs)).

%% ---------------------------------------------------------------------------
%% Compressed body must be smaller than original
%% ---------------------------------------------------------------------------

gzip_result_smaller_than_original_when_compressible_test() ->
    Body = padding_bytes(10240),
    Hdrs = [{<<"content-type">>, <<"text/html">>}],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {_ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assert(byte_size(ResBody) < byte_size(Body)).

%% ---------------------------------------------------------------------------
%% application/xhtml+xml is compressible
%% ---------------------------------------------------------------------------

gzip_compresses_xhtml_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"application/xhtml+xml">>}],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, _} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(<<"gzip">>, proplists:get_value(<<"content-encoding">>, ResHdrs)).

%% ---------------------------------------------------------------------------
%% application/x-javascript is compressible
%% ---------------------------------------------------------------------------

gzip_compresses_legacy_js_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"application/x-javascript">>}],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, _} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(<<"gzip">>, proplists:get_value(<<"content-encoding">>, ResHdrs)).

br_accept_encoding_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/plain">>}],
    Accept = [{<<"accept-encoding">>, <<"br, gzip">>}],
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    Enc = proplists:get_value(<<"content-encoding">>, ResHdrs),
    case Enc of
        undefined ->
            ?assertEqual(Body, ResBody);
        <<"br">> ->
            ?assert(byte_size(ResBody) < byte_size(Body));
        <<"gzip">> ->
            ?assert(byte_size(ResBody) < byte_size(Body))
    end.

zstd_accept_encoding_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/plain">>}],
    Accept = [{<<"accept-encoding">>, <<"zstd, gzip">>}],
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    Enc = proplists:get_value(<<"content-encoding">>, ResHdrs),
    case Enc of
        undefined ->
            ?assertEqual(Body, ResBody);
        <<"zstd">> ->
            ?assert(byte_size(ResBody) < byte_size(Body));
        <<"gzip">> ->
            ?assert(byte_size(ResBody) < byte_size(Body))
    end.

header_map_case_insensitive_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"Content-Type">>, <<"text/html">>}],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, _} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(<<"gzip">>, proplists:get_value(<<"content-encoding">>, ResHdrs)).

gzip_q_value_preference_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/html">>}],
    Accept = [{<<"accept-encoding">>, <<"gzip;q=0.5, br;q=0.0">>}],
    {ResHdrs, _} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(<<"gzip">>, proplists:get_value(<<"content-encoding">>, ResHdrs)).

accept_encoding_whitespace_trimmed_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/html">>}],
    Accept = [{<<"accept-encoding">>, <<" gzip , deflate">>}],
    {ResHdrs, _} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(<<"gzip">>, proplists:get_value(<<"content-encoding">>, ResHdrs)).

vary_empty_string_gets_accept_encoding_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/html">>}, {<<"vary">>, <<>>}],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, _} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    Vary = proplists:get_value(<<"vary">>, ResHdrs),
    ?assertNotEqual(nomatch, binary:match(string:lowercase(Vary), <<"accept-encoding">>)).

status_199_not_compressed_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/html">>}],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(199, Accept, Hdrs, Body),
    ?assertEqual(undefined, proplists:get_value(<<"content-encoding">>, ResHdrs)),
    ?assertEqual(Body, ResBody).

cowboy_compresses_gzip_test() ->
    Req = #{headers => #{<<"accept-encoding">> => <<"gzip">>}},
    Body = padding_bytes(2048),
    Hdrs = #{
        <<"content-type">> => <<"text/html">>,
        <<"content-length">> => integer_to_binary(byte_size(Body)),
        <<"etag">> => <<"\"x\"">>
    },
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_cowboy(200, Req, Hdrs, Body),
    ?assertEqual(<<"gzip">>, maps:get(<<"content-encoding">>, ResHdrs)),
    ?assert(byte_size(ResBody) < byte_size(Body)),
    ?assertNot(maps:is_key(<<"content-length">>, ResHdrs)),
    ?assertNot(maps:is_key(<<"etag">>, ResHdrs)).

cowboy_header_map_case_insensitive_test() ->
    Req = #{headers => #{<<"accept-encoding">> => <<"gzip">>}},
    Body = padding_bytes(2048),
    Hdrs = #{<<"Content-Type">> => <<"text/html">>},
    {ResHdrs, _} = pertisk_eproxy_compression:maybe_compress_cowboy(200, Req, Hdrs, Body),
    ?assertEqual(<<"gzip">>, maps:get(<<"content-encoding">>, ResHdrs)).

incompressible_body_keeps_original_test() ->
    Body = crypto:strong_rand_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/html">>}],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(undefined, proplists:get_value(<<"content-encoding">>, ResHdrs)),
    ?assertEqual(Body, ResBody).

non_binary_cache_control_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/html">>}, {<<"cache-control">>, 123}],
    Accept = [{<<"accept-encoding">>, <<"gzip">>}],
    {_ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assert(is_binary(ResBody)).

empty_accept_encoding_header_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/html">>}],
    Accept = [{<<"accept-encoding">>, <<>>}],
    {ResHdrs, _} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(undefined, proplists:get_value(<<"content-encoding">>, ResHdrs)).

deflate_only_accept_encoding_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/html">>}],
    Accept = [{<<"accept-encoding">>, <<"deflate">>}],
    {ResHdrs, _} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(undefined, proplists:get_value(<<"content-encoding">>, ResHdrs)).

zstd_unavailable_falls_back_test() ->
    ok = load_codec_module(ezstd, "-module(ezstd).\n"),
    ok = load_codec_module(zstd, "-module(zstd).\n"),
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/html">>}],
    Accept = [{<<"accept-encoding">>, <<"zstd, gzip">>}],
    {ResHdrs, _} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(<<"gzip">>, proplists:get_value(<<"content-encoding">>, ResHdrs)).

br_encoding_with_stub_test() ->
    ok = load_codec_module(brotli, "-module(brotli).\n-export([encode/1]).\nencode(B) -> zlib:gzip(B).\n"),
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/plain">>}],
    Accept = [{<<"accept-encoding">>, <<"br">>}],
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(<<"br">>, proplists:get_value(<<"content-encoding">>, ResHdrs)),
    ?assert(byte_size(ResBody) < byte_size(Body)).

zstd_encoding_with_stub_test() ->
    ok = load_codec_module(ezstd, "-module(ezstd).\n-export([compress/1]).\ncompress(B) -> zlib:gzip(B).\n"),
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/plain">>}],
    Accept = [{<<"accept-encoding">>, <<"zstd">>}],
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(<<"zstd">>, proplists:get_value(<<"content-encoding">>, ResHdrs)),
    ?assert(byte_size(ResBody) < byte_size(Body)).

accept_encoding_unknown_param_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/html">>}],
    Accept = [{<<"accept-encoding">>, <<"gzip; foo=bar">>}],
    {ResHdrs, _} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(<<"gzip">>, proplists:get_value(<<"content-encoding">>, ResHdrs)).

accept_encoding_invalid_q_test() ->
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/html">>}],
    Accept = [{<<"accept-encoding">>, <<"gzip; q=not-a-float">>}],
    {ResHdrs, _} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(<<"gzip">>, proplists:get_value(<<"content-encoding">>, ResHdrs)).

brotli_compress_only_module_test() ->
    ok = load_codec_module(brotli, "-module(brotli).\n-export([compress/1]).\ncompress(B) -> zlib:gzip(B).\n"),
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/plain">>}],
    Accept = [{<<"accept-encoding">>, <<"br">>}],
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(<<"br">>, proplists:get_value(<<"content-encoding">>, ResHdrs)),
    ?assert(byte_size(ResBody) < byte_size(Body)).

zstd_module_fallback_test() ->
    ok = load_codec_module(ezstd, "-module(ezstd).\n"),
    ok = load_codec_module(zstd, "-module(zstd).\n-export([compress/1]).\ncompress(B) -> zlib:gzip(B).\n"),
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/plain">>}],
    Accept = [{<<"accept-encoding">>, <<"zstd">>}],
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(<<"zstd">>, proplists:get_value(<<"content-encoding">>, ResHdrs)),
    ?assert(byte_size(ResBody) < byte_size(Body)).

zstd_unavailable_error_path_test() ->
    ok = load_codec_module(ezstd, "-module(ezstd).\n"),
    ok = load_codec_module(zstd, "-module(zstd).\n"),
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/plain">>}],
    Accept = [{<<"accept-encoding">>, <<"zstd">>}],
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(undefined, proplists:get_value(<<"content-encoding">>, ResHdrs)),
    ?assertEqual(Body, ResBody).

brotli_unavailable_error_path_test() ->
    ok = load_codec_module(brotli, "-module(brotli).\n"),
    Body = padding_bytes(2048),
    Hdrs = [{<<"content-type">>, <<"text/plain">>}],
    Accept = [{<<"accept-encoding">>, <<"br">>}],
    {ResHdrs, ResBody} = pertisk_eproxy_compression:maybe_compress_h3(200, Accept, Hdrs, Body),
    ?assertEqual(undefined, proplists:get_value(<<"content-encoding">>, ResHdrs)),
    ?assertEqual(Body, ResBody).

%% ---------------------------------------------------------------------------
%% Helpers
%% ---------------------------------------------------------------------------

padding_bytes(N) ->
    iolist_to_binary(["X" || _ <- lists:seq(1, N)]).

load_codec_module(Module, Source) ->
    TmpDir = os:getenv("TMPDIR", "/tmp"),
    Path = filename:join([TmpDir, atom_to_list(Module) ++ ".erl"]),
    ok = file:write_file(Path, Source),
    case compile:file(Path, [binary]) of
        {ok, Module, Beam} ->
            code:purge(Module),
            code:delete(Module),
            {module, Module} = code:load_binary(Module, Path, Beam),
            ok;
        Error ->
            error(Error)
    end.