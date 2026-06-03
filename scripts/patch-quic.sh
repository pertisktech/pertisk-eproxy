#!/bin/sh
# Apply QUIC patches:
#   1. QPACK interop fix for static-only header blocks (RIC=0 -> Base sign bit 0).
#   2. quic_socket inet6 support: make build_genudp_opts family-aware so that
#      extra_socket_opts => [inet6, {ipv6_v6only, false}] produces a dual-stack
#      UDP socket instead of {error, einval} (Erlang rejects [inet, ..., inet6]).
set -e
ROOT="${REBAR_ROOT_DIR:-.}"
found=0

for f in $(find "${ROOT}/_build" -path '*/quic/src/qpack/quic_qpack.erl' 2>/dev/null | sort -u); do
  found=1

  if grep -q '0 -> 16#00' "$f"; then
    continue
  fi

  perl -i -0pe '
    s/BaseEncoded = 16#80,/BaseEncoded =\n        case RIC of\n            0 -> 16#00;\n            _ -> 16#80\n        end,/s
  ' "$f"

  rm -f "$(dirname "$f")/../../ebin/quic_qpack.beam" 2>/dev/null || true

done

if [ "$found" -eq 0 ]; then
  echo "patch-quic: no quic_qpack.erl under _build (run rebar3 get-deps first)" >&2
  exit 1
fi

QPACK=$(find "${ROOT}/_build" -path '*/quic/src/qpack/quic_qpack.erl' 2>/dev/null | head -1)
QUIC_APP=$(find "${ROOT}/_build" -path '*/quic/src/quic.app.src' 2>/dev/null | head -1)
QUIC_VSN=""
if [ -n "$QUIC_APP" ] && [ -f "$QUIC_APP" ]; then
  QUIC_VSN=$(sed -n 's/.*{vsn, "\([^"]*\)"}.*/\1/p' "$QUIC_APP" | head -1)
fi

if grep -q '0 -> 16#00' "$QPACK"; then
  :
else
  case "$QUIC_VSN" in
    1.4.3|1.4.[4-9]*|1.[5-9]*|[2-9].*)
      echo "patch-quic: QPACK RFC9204 fix already upstream in quic $QUIC_VSN"
      ;;
    *)
      echo "patch-quic: QPACK patch missing in $QPACK" >&2
      exit 1
      ;;
  esac
fi

echo "patch-quic: ok"

# ── quic_socket inet6 support ──────────────────────────────────────────────
# Older quic releases build gen_udp opts by hardcoding `inet` and appending
# extra_socket_opts. If `inet6` is present, gen_udp:open receives [inet, inet6]
# and returns {error, einval}. Newer quic releases changed quic_socket internals,
# so this patch must stay version-aware.
socket_patch_enabled=1
case "$QUIC_VSN" in
  1.6.*|1.[7-9]*|[2-9].*)
    socket_patch_enabled=0
    ;;
esac

if [ "$socket_patch_enabled" -eq 1 ]; then
  socket_found=0
  for f in $(find "${ROOT}/_build" -path '*/quic/src/quic_socket.erl' 2>/dev/null | sort -u); do
    socket_found=1

    if grep -q 'Family = case lists:member(inet6' "$f"; then
      continue
    fi

    perl -i -0pe '
s/(build_genudp_opts\(Opts\) ->\n    ActiveN = maps:get\(active_n, Opts, 100\),\n    ReusePort = maps:get\(reuseport, Opts, false\),\n    ExtraFlags = maps:get\(extra_socket_opts, Opts, \[\]\),\n    RecBuf = maps:get\(recbuf, Opts, \?DEFAULT_UDP_RECBUF\),\n    SndBuf = maps:get\(sndbuf, Opts, \?DEFAULT_UDP_SNDBUF\),\n    BaseOpts = \[\n        binary,\n        inet,\n        \{active, ActiveN\},\n        \{reuseaddr, true\},\n        \{recbuf, RecBuf\},\n        \{sndbuf, SndBuf\}\n    \],\n    ReuseOpts =\n        case ReusePort of\n            true -> \[\{reuseport, true\}, \{reuseport_lb, true\}\];\n            false -> \[\]\n        end,\n    BaseOpts \+\+ ReuseOpts \+\+ ExtraFlags\.)/$1 % inet6-patched/s' "$f"

    perl -i -0pe '
s/build_genudp_opts\(Opts\) ->\n    ActiveN = maps:get\(active_n, Opts, 100\),\n    ReusePort = maps:get\(reuseport, Opts, false\),\n    ExtraFlags = maps:get\(extra_socket_opts, Opts, \[\]\),\n    RecBuf = maps:get\(recbuf, Opts, \?DEFAULT_UDP_RECBUF\),\n    SndBuf = maps:get\(sndbuf, Opts, \?DEFAULT_UDP_SNDBUF\),\n    BaseOpts = \[\n        binary,\n        inet,\n        \{active, ActiveN\},\n        \{reuseaddr, true\},\n        \{recbuf, RecBuf\},\n        \{sndbuf, SndBuf\}\n    \],\n    ReuseOpts =\n        case ReusePort of\n            true -> \[\{reuseport, true\}, \{reuseport_lb, true\}\];\n            false -> \[\]\n        end,\n    BaseOpts \+\+ ReuseOpts \+\+ ExtraFlags\. % inet6-patched/build_genudp_opts(Opts) ->\n    ActiveN = maps:get(active_n, Opts, 100),\n    ReusePort = maps:get(reuseport, Opts, false),\n    ExtraFlags0 = maps:get(extra_socket_opts, Opts, []),\n    RecBuf = maps:get(recbuf, Opts, ?DEFAULT_UDP_RECBUF),\n    SndBuf = maps:get(sndbuf, Opts, ?DEFAULT_UDP_SNDBUF),\n    Family = case lists:member(inet6, ExtraFlags0) of\n        true -> inet6;\n        false -> inet\n    end,\n    ExtraFlags = lists:delete(inet6, ExtraFlags0),\n    BaseOpts = [\n        binary,\n        Family,\n        {active, ActiveN},\n        {reuseaddr, true},\n        {recbuf, RecBuf},\n        {sndbuf, SndBuf}\n    ],\n    ReuseOpts =\n        case ReusePort of\n            true -> [{reuseport, true}, {reuseport_lb, true}];\n            false -> []\n        end,\n    BaseOpts ++ ReuseOpts ++ ExtraFlags./s' "$f"

    rm -f "$(dirname "$f")/../../ebin/quic_socket.beam" 2>/dev/null || true
  done

  if [ "$socket_found" -eq 0 ]; then
    echo "patch-quic: warning: no quic_socket.erl under _build (run rebar3 get-deps first)" >&2
  fi

  SOCKET=$(find "${ROOT}/_build" -path '*/quic/src/quic_socket.erl' 2>/dev/null | head -1)
  if [ -n "$SOCKET" ]; then
    grep -q 'Family = case lists:member(inet6' "$SOCKET" || {
      echo "patch-quic: quic_socket inet6 patch failed in $SOCKET" >&2
      exit 1
    }
    echo "patch-quic: quic_socket inet6 ok"
  fi
else
  echo "patch-quic: skipping quic_socket inet6 patch for quic ${QUIC_VSN:-unknown}"
fi

LISTENER=$(find "${ROOT}/_build" -path '*/quic/src/quic_listener.erl' 2>/dev/null | head -1)

# H3 shutdown handling: treat peer-close and draining as normal exits so
# expected QUIC teardown does not show up as crash reports.
h3_found=0
for f in $(find "${ROOT}/_build" -path '*/quic/src/h3/quic_h3_connection.erl' 2>/dev/null | sort -u); do
  h3_found=1

  if grep -q 'catch open_critical_streams(State)' "$f" && grep -q "'EXIT', {{badmatch, {error, {invalid_state, draining}}}, _}" "$f"; then
    continue
  fi

  perl -i -0pe '
    s/h3_connecting\(enter, _OldState, State\) ->\n    %% Open critical streams and send SETTINGS\n    case open_critical_streams\(State\) of\n        \{ok, State1\} ->\n            case send_settings\(State1\) of\n                \{ok, State2\} ->\n                    \{keep_state, State2\};\n                \{error, Reason\} ->\n                    \{stop, \{error, Reason\}\}\n            end;\n        \{error, Reason\} ->\n            \{stop, \{error, Reason\}\}\n    end;/h3_connecting(enter, _OldState, State) ->\n    %% Open critical streams and send SETTINGS.\n    %% During shutdown\/draining, older quic code can raise badmatch from\n    %% open_critical_streams\/1 (ok = quic:send_data(...)). Catch and close\n    %% cleanly instead of crashing the state machine.\n    case catch open_critical_streams(State) of\n        {ok, State1} ->\n            case send_settings(State1) of\n                {ok, State2} ->\n                    {keep_state, State2};\n                {error, {invalid_state, draining}} ->\n                    {stop, normal};\n                {error, Reason} ->\n                    {stop, {error, Reason}}\n            end;\n        {error, {invalid_state, draining}} ->\n            {stop, normal};\n        {'\''EXIT'\'', {{badmatch, {error, {invalid_state, draining}}}, _}} ->\n            {stop, normal};\n        {'\''EXIT'\'', Reason} ->\n            {stop, {error, Reason}};\n        {error, Reason} ->\n            {stop, {error, Reason}}\n    end;/s;
    s/h3_connecting\(enter, _OldState, State\) ->\n    %% Open critical streams and send SETTINGS\n    case open_critical_streams\(State\) of\n        \{ok, State1\} ->\n            case send_settings\(State1\) of\n                \{ok, State2\} ->\n                    \{keep_state, State2\};\n                \{error, \{invalid_state, draining\}\} ->\n                    \{keep_state, State1, \[\{next_event, cast, close\}\]\};\n                \{error, Reason\} ->\n                    \{stop, \{error, Reason\}\}\n            end;\n        \{error, \{invalid_state, draining\}\} ->\n            \{keep_state, State, \[\{next_event, cast, close\}\]\};\n        \{error, Reason\} ->\n            \{stop, \{error, Reason\}\}\n    end;/h3_connecting(enter, _OldState, State) ->\n    %% Open critical streams and send SETTINGS.\n    %% During shutdown\/draining, older quic code can raise badmatch from\n    %% open_critical_streams\/1 (ok = quic:send_data(...)). Catch and close\n    %% cleanly instead of crashing the state machine.\n    case catch open_critical_streams(State) of\n        {ok, State1} ->\n            case send_settings(State1) of\n                {ok, State2} ->\n                    {keep_state, State2};\n                {error, {invalid_state, draining}} ->\n                    {stop, normal};\n                {error, Reason} ->\n                    {stop, {error, Reason}}\n            end;\n        {error, {invalid_state, draining}} ->\n            {stop, normal};\n        {'\''EXIT'\'', {{badmatch, {error, {invalid_state, draining}}}, _}} ->\n            {stop, normal};\n        {'\''EXIT'\'', Reason} ->\n            {stop, {error, Reason}};\n        {error, Reason} ->\n            {stop, {error, Reason}}\n    end;/s;
    s/\{stop, quic_closed, State\}/\{stop, normal, State\}/g
  ' "$f"

  rm -f "$(dirname "$f")/../../ebin/quic_h3_connection.beam" 2>/dev/null || true
done

if [ "$h3_found" -eq 0 ]; then
  echo "patch-quic: warning: no quic_h3_connection.erl under _build (run rebar3 get-deps first)" >&2
fi
H3=$(find "${ROOT}/_build" -path '*/quic/src/h3/quic_h3_connection.erl' 2>/dev/null | head -1)
if [ -n "$H3" ]; then
  grep -q 'catch open_critical_streams(State)' "$H3" || {
    echo "patch-quic: h3 safety patch missing in $H3" >&2
    exit 1
  }
  grep -q '{stop, normal};' "$H3" || {
    echo "patch-quic: h3 draining-stop patch missing in $H3" >&2
    exit 1
  }
  if grep -q 'next_event, cast, close' "$H3"; then
    echo "patch-quic: illegal state_enter next_event still present in $H3" >&2
    exit 1
  fi
  echo "patch-quic: h3 state-enter safety ok"
fi

# H3 SNI support: preserve TLS override fields when translating quic_h3 server
# options to quic:start_server options. Without this, sni_certs/cert_chain/private_key
# are dropped and QUIC can serve only the default cert.
h3_opts_found=0
for f in $(find "${ROOT}/_build" -path '*/quic/src/h3/quic_h3.erl' 2>/dev/null | sort -u); do
  h3_opts_found=1

  if grep -q 'maps:with(\[cert, key, cert_chain, private_key, cacerts, sni_certs\], Opts)' "$f"; then
    continue
  fi

  perl -i -0pe '
    s/TlsOpts = maps:with\(\[cert, key, cacerts\], Opts\),/TlsOpts = maps:with([cert, key, cert_chain, private_key, cacerts, sni_certs], Opts),/s
  ' "$f"

  rm -f "$(dirname "$f")/../../ebin/quic_h3.beam" 2>/dev/null || true
done

if [ "$h3_opts_found" -eq 0 ]; then
  echo "patch-quic: warning: no quic_h3.erl under _build (run rebar3 get-deps first)" >&2
fi

H3_API=$(find "${ROOT}/_build" -path '*/quic/src/h3/quic_h3.erl' 2>/dev/null | head -1)
if [ -n "$H3_API" ]; then
  grep -q 'maps:with(\[cert, key, cert_chain, private_key, cacerts, sni_certs\], Opts)' "$H3_API" || {
    echo "patch-quic: h3 sni/tls opts patch missing in $H3_API" >&2
    exit 1
  }
  echo "patch-quic: h3 sni/tls opts ok"
fi

# 0-RTT PSK binder hard-fail mitigation:
# Keep this only for older quic releases. quic >= 1.6.0 reworked 0-RTT
# acceptance/rejection flow, so rewriting binder failure handling here can
# conflict with upstream behavior.
psk_patch_enabled=1
case "$QUIC_VSN" in
  1.6.*|1.[7-9]*|[2-9].*)
    psk_patch_enabled=0
    ;;
esac

if [ "$psk_patch_enabled" -eq 1 ]; then
  psk_found=0
  for f in $(find "${ROOT}/_build" -path '*/quic/src/quic_connection.erl' 2>/dev/null | sort -u); do
    psk_found=1

    perl -i -0pe '
      s/false\s*->\s*\n\s*\?LOG_WARNING\(\n\s*#\{what => resumption_psk_binder_failed\},\n\s*\?QUIC_LOG_META\n\s*\),\n\s*send_tls_alert\(\?TLS_ALERT_DECRYPT_ERROR, State\),\n\s*exit\(\{tls_alert, decrypt_error\}\)/false ->\n                                        ?LOG_WARNING(\n                                            #{what => resumption_psk_binder_failed},\n                                            ?QUIC_LOG_META\n                                        ),\n                                        {\n                                            undefined,\n                                            quic_crypto:derive_early_secret(Cipher, ZeroPSK),\n                                            undefined\n                                        }/s
    ' "$f"

    rm -f "$(dirname "$f")/../../ebin/quic_connection.beam" 2>/dev/null || true
  done

  if [ "$psk_found" -eq 0 ]; then
    echo "patch-quic: warning: no quic_connection.erl under _build (run rebar3 get-deps first)" >&2
  fi

  PSK_CONN=$(find "${ROOT}/_build" -path '*/quic/src/quic_connection.erl' 2>/dev/null | head -1)
  if [ -n "$PSK_CONN" ]; then
    perl -0777 -ne 'exit((/resumption_psk_binder_failed[\s\S]*?\{\s*undefined,\s*quic_crypto:derive_early_secret\(Cipher, ZeroPSK\),\s*undefined\s*\}/) ? 0 : 1)' "$PSK_CONN" || {
      echo "patch-quic: 0-RTT binder fallback patch missing in $PSK_CONN" >&2
      exit 1
    }
    echo "patch-quic: 0-RTT binder fallback ok"
  fi
else
  echo "patch-quic: skipping 0-RTT binder fallback for quic ${QUIC_VSN:-unknown}"
fi

# QUIC SNI certificate selection: apply per-host cert override from sni_certs
# during ClientHello processing (exact host first, wildcard fallback).
conn_found=0
for f in $(find "${ROOT}/_build" -path '*/quic/src/quic_connection.erl' 2>/dev/null | sort -u); do
  conn_found=1

  if grep -q 'maybe_apply_server_cert_for_sni(#{server_name := undefined}, State) ->' "$f"; then
    continue
  fi

  perl -i -0pe '
    s/server_private_key :: term\(\) \| undefined,\n    %% Server preferred address config/server_private_key :: term() | undefined,\n    sni_certs = #{} :: map(),\n    %% Server preferred address config/s
  ' "$f"

  perl -i -0pe '
    s/PrivateKey = maps:get\(private_key, Opts\),\n    ALPNList = maps:get\(alpn, Opts, \[<<"h3">>\]\),/PrivateKey = maps:get(private_key, Opts),\n    SniCerts = maps:get(sni_certs, Opts, #{}),\n    ALPNList = maps:get(alpn, Opts, [<<"h3">>]),/s
  ' "$f"

  perl -i -0pe '
    s/server_private_key = PrivateKey,\n        server_preferred_address = build_server_preferred_address\(Opts\),/server_private_key = PrivateKey,\n        sni_certs = SniCerts,\n        server_preferred_address = build_server_preferred_address(Opts),/s
  ' "$f"

  perl -i -0pe '
    s/session_id := SessionId\n            } = ClientHelloInfo} ->\n            %% Select cipher suite \(prefer server.*?\)\n            Cipher = select_cipher\(CipherSuites\),/session_id := SessionId\n            } = ClientHelloInfo} ->\n            %% Apply SNI certificate override before building server handshake\n            %% flight so Certificate\/CertificateVerify match the requested host.\n            StateSni = maybe_apply_server_cert_for_sni(ClientHelloInfo, State),\n            %% Select cipher suite (prefer server order)\n            Cipher = select_cipher(CipherSuites),/s
  ' "$f"

  perl -i -0pe '
    s/State#state\.tls_groups, KeyShareEntries, SupportedGroups/StateSni#state.tls_groups, KeyShareEntries, SupportedGroups/s;
    s/SelGroup, ClientPubKey, Cipher, ClientHelloInfo, OriginalMsg, State\n                    \)/SelGroup, ClientPubKey, Cipher, ClientHelloInfo, OriginalMsg, StateSni\n                    )/s;
    s/\{hrr, HrrGroup\} when not State#state\.hrr_sent ->\n                    send_hello_retry_request\(HrrGroup, Cipher, SessionId, OriginalMsg, State\);/{hrr, HrrGroup} when not StateSni#state.hrr_sent ->\n                    send_hello_retry_request(HrrGroup, Cipher, SessionId, OriginalMsg, StateSni);/s;
    s/send_tls_alert\(\n                        \?TLS_ALERT_ILLEGAL_PARAMETER, <<"bad retry key_share">>, State\n                    \);/send_tls_alert(\n                        ?TLS_ALERT_ILLEGAL_PARAMETER, <<"bad retry key_share">>, StateSni\n                    );/s;
    s/send_tls_alert\(\?TLS_ALERT_HANDSHAKE_FAILURE, <<"no common group">>, State\)/send_tls_alert(?TLS_ALERT_HANDSHAKE_FAILURE, <<"no common group">>, StateSni)/s;
  ' "$f"

  perl -i -0pe '
    s/%% @private Continue a server-side ClientHello once the key-exchange\n%% group is settled \(direct or post-HRR\)\. SelectedGroup is the agreed\n%% named group; ClientPubKey is the client\x27s key_share for it\./maybe_apply_server_cert_for_sni(#{server_name := undefined}, State) ->\n    State;\nmaybe_apply_server_cert_for_sni(#{server_name := Name0}, #state{sni_certs = SniCerts} = State)\nwhen is_binary(Name0); is_list(Name0) ->\n    case normalize_sni_hostname(Name0) of\n        undefined ->\n            State;\n        Name ->\n            case sni_cert_entry(Name, SniCerts) of\n                undefined ->\n                    State;\n                Entry ->\n                    apply_sni_cert_entry(Entry, State)\n            end\n    end;\nmaybe_apply_server_cert_for_sni(_, State) ->\n    State.\n\nnormalize_sni_hostname(Name) when is_list(Name) ->\n    normalize_sni_hostname(unicode:characters_to_binary(Name, utf8));\nnormalize_sni_hostname(Name) when is_binary(Name) ->\n    Lower0 = string:lowercase(Name),\n    case re:replace(Lower0, <<"\\\\.$">>, <<>>, [{return, binary}]) of\n        <<>> -> undefined;\n        Lower -> Lower\n    end;\nnormalize_sni_hostname(_) ->\n    undefined.\n\nsni_cert_entry(Name, SniCerts) ->\n    case maps:get(Name, SniCerts, undefined) of\n        undefined ->\n            wildcard_sni_cert_entry(Name, maps:to_list(SniCerts), undefined);\n        Entry ->\n            Entry\n    end.\n\nwildcard_sni_cert_entry(_Name, [], Best) ->\n    Best;\nwildcard_sni_cert_entry(Name, [{Key, Entry} | Rest], Best0) ->\n    KeyBin = normalize_sni_hostname(Key),\n    Best1 =\n        case wildcard_match_len(Name, KeyBin) of\n            none -> Best0;\n            Len ->\n                case Best0 of\n                    undefined -> {Len, Entry};\n                    {BestLen, _} when Len > BestLen -> {Len, Entry};\n                    _ -> Best0\n                end\n        end,\n    wildcard_sni_cert_entry(Name, Rest, Best1).\n\nwildcard_match_len(_Name, undefined) ->\n    none;\nwildcard_match_len(Name, <<"*.", Suffix\/binary>>) ->\n    case {byte_size(Suffix) > 0, byte_size(Name) > byte_size(Suffix), binary:match(Name, Suffix)} of\n        {true, true, {Pos, _Len}} when Pos + byte_size(Suffix) =:= byte_size(Name) ->\n            DotPos = byte_size(Name) - byte_size(Suffix) - 1,\n            case binary:at(Name, DotPos) of\n                $. -> byte_size(Suffix);\n                _ -> none\n            end;\n        _ ->\n            none\n    end;\nwildcard_match_len(_Name, _) ->\n    none.\n\napply_sni_cert_entry({_, Entry}, State) ->\n    apply_sni_cert_entry(Entry, State);\napply_sni_cert_entry(Entry, State) when is_map(Entry) ->\n    Cert = maps:get(cert, Entry, State#state.server_cert),\n    Chain = maps:get(cert_chain, Entry, State#state.server_cert_chain),\n    Key =\n        case maps:get(private_key, Entry, undefined) of\n            undefined -> maps:get(key, Entry, State#state.server_private_key);\n            PrivateKey -> PrivateKey\n        end,\n    State#state{server_cert = Cert, server_cert_chain = Chain, server_private_key = Key};\napply_sni_cert_entry(_, State) ->\n    State.\n\n%% @private Continue a server-side ClientHello once the key-exchange\n%% group is settled (direct or post-HRR). SelectedGroup is the agreed\n%% named group; ClientPubKey is the client\x27s key_share for it\./s
  ' "$f"

    # Fallback: if pattern-based insertion misses due upstream source drift,
    # append helper functions to keep build deterministic.
    # Check for function definition specifically (the call site also contains
    # this token and must not suppress fallback insertion).
    if ! grep -q 'maybe_apply_server_cert_for_sni(#{server_name := undefined}, State) ->' "$f"; then
    cat >> "$f" <<'EOF'

  maybe_apply_server_cert_for_sni(#{server_name := undefined}, State) ->
    State;
  maybe_apply_server_cert_for_sni(#{server_name := Name0}, #state{sni_certs = SniCerts} = State)
  when is_binary(Name0); is_list(Name0) ->
    case normalize_sni_hostname(Name0) of
      undefined ->
        State;
      Name ->
        case sni_cert_entry(Name, SniCerts) of
          undefined ->
            State;
          Entry ->
            apply_sni_cert_entry(Entry, State)
        end
    end;
  maybe_apply_server_cert_for_sni(_, State) ->
    State.

  normalize_sni_hostname(Name) when is_list(Name) ->
    normalize_sni_hostname(unicode:characters_to_binary(Name, utf8));
  normalize_sni_hostname(Name) when is_binary(Name) ->
    Lower0 = string:lowercase(Name),
    case re:replace(Lower0, <<"\\.$">>, <<>>, [{return, binary}]) of
      <<>> -> undefined;
      Lower -> Lower
    end;
  normalize_sni_hostname(_) ->
    undefined.

  sni_cert_entry(Name, SniCerts) ->
    case maps:get(Name, SniCerts, undefined) of
      undefined ->
        case wildcard_sni_cert_entry(Name, maps:to_list(SniCerts), undefined) of
          undefined -> undefined;
          {_Len, Entry} -> Entry
        end;
      Entry ->
        Entry
    end.

  wildcard_sni_cert_entry(_Name, [], Best) ->
    Best;
  wildcard_sni_cert_entry(Name, [{Key, Entry} | Rest], Best0) ->
    KeyBin = normalize_sni_hostname(Key),
    Best1 =
      case wildcard_match_len(Name, KeyBin) of
        none -> Best0;
        Len ->
          case Best0 of
            undefined -> {Len, Entry};
            {BestLen, _} when Len > BestLen -> {Len, Entry};
            _ -> Best0
          end
      end,
    wildcard_sni_cert_entry(Name, Rest, Best1).

  wildcard_match_len(_Name, undefined) ->
    none;
  wildcard_match_len(Name, <<"*.", Suffix/binary>>) ->
    case {byte_size(Suffix) > 0, byte_size(Name) > byte_size(Suffix), binary:match(Name, Suffix)} of
      {true, true, {Pos, _Len}} when Pos + byte_size(Suffix) =:= byte_size(Name) ->
        DotPos = byte_size(Name) - byte_size(Suffix) - 1,
        case binary:at(Name, DotPos) of
          $. -> byte_size(Suffix);
          _ -> none
        end;
      _ ->
        none
    end;
  wildcard_match_len(_Name, _) ->
    none.

  apply_sni_cert_entry(Entry, State) when is_map(Entry) ->
    Cert = maps:get(cert, Entry, State#state.server_cert),
    Chain = maps:get(cert_chain, Entry, State#state.server_cert_chain),
    Key =
      case maps:get(private_key, Entry, undefined) of
        undefined -> maps:get(key, Entry, State#state.server_private_key);
        PrivateKey -> PrivateKey
      end,
    State#state{server_cert = Cert, server_cert_chain = Chain, server_private_key = Key};
  apply_sni_cert_entry(_, State) ->
    State.
EOF
    fi

  rm -f "$(dirname "$f")/../../ebin/quic_connection.beam" 2>/dev/null || true
done

if [ "$conn_found" -eq 0 ]; then
  echo "patch-quic: warning: no quic_connection.erl under _build (run rebar3 get-deps first)" >&2
fi

CONN=$(find "${ROOT}/_build" -path '*/quic/src/quic_connection.erl' 2>/dev/null | head -1)
if [ -n "$CONN" ]; then
  grep -q 'maybe_apply_server_cert_for_sni(#{server_name := undefined}, State) ->' "$CONN" || {
    echo "patch-quic: quic_connection SNI cert selection patch missing in $CONN" >&2
    exit 1
  }
  echo "patch-quic: quic_connection SNI cert selection ok"
fi
if [ -n "$LISTENER" ]; then
  if grep -q 'Family = case lists:member(inet6' "$LISTENER"; then
    echo "patch-quic: quic_listener inet6 ok"
  else
  perl -i -0pe '
s/init_genudp_backend\(Port, Opts\) ->\n    ActiveN = maps:get\(active_n, Opts, 100\),\n    ReusePort = maps:get\(reuseport, Opts, false\),\n    ExtraFlags = maps:get\(extra_socket_opts, Opts, \[\]\),\n\n    %% UDP buffer sizing - larger buffers improve throughput significantly\n    %% OS may cap to lower values \(check sysctl net.core.rmem_max on Linux\)\n    RecBuf = maps:get\(recbuf, Opts, \?DEFAULT_UDP_RECBUF\),\n    SndBuf = maps:get\(sndbuf, Opts, \?DEFAULT_UDP_SNDBUF\),\n\n    SocketOpts =\n        \[\n            binary,\n            inet,\n            \{active, ActiveN\},\n            \{reuseaddr, true\},\n            \{recbuf, RecBuf\},\n            \{sndbuf, SndBuf\}\n        \] \+\+\n            case ReusePort of\n                true -> \[\{reuseport, true\}, \{reuseport_lb, true\}\];\n                false -> \[\]\n            end \+\+ ExtraFlags,/init_genudp_backend(Port, Opts) ->
  ActiveN = maps:get(active_n, Opts, 100),
  ReusePort = maps:get(reuseport, Opts, false),
  ExtraFlags0 = maps:get(extra_socket_opts, Opts, []),

  %% UDP buffer sizing - larger buffers improve throughput significantly
  %% OS may cap to lower values (check sysctl net.core.rmem_max on Linux)
  RecBuf = maps:get(recbuf, Opts, ?DEFAULT_UDP_RECBUF),
  SndBuf = maps:get(sndbuf, Opts, ?DEFAULT_UDP_SNDBUF),
  Family = case lists:member(inet6, ExtraFlags0) of
    true -> inet6;
    false -> inet
  end,
  ExtraFlags = lists:delete(inet6, ExtraFlags0),

  SocketOpts =
    [
      binary,
      Family,
      {active, ActiveN},
      {reuseaddr, true},
      {recbuf, RecBuf},
      {sndbuf, SndBuf}
    ] ++
      case ReusePort of
        true -> [{reuseport, true}, {reuseport_lb, true}];
        false -> []
      end ++ ExtraFlags,/s' "$LISTENER"

  rm -f "$(dirname "$LISTENER")/../../ebin/quic_listener.beam" 2>/dev/null || true
fi
fi
