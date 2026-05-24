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
grep -q '0 -> 16#00' "$QPACK" || {
  echo "patch-quic: QPACK patch missing in $QPACK" >&2
  exit 1
}

echo "patch-quic: ok"

# ── quic_socket inet6 support ──────────────────────────────────────────────
# build_genudp_opts hardcodes `inet` in BaseOpts and then appends ExtraFlags.
# If ExtraFlags contains `inet6`, gen_udp:open gets [inet, ..., inet6] which
# Erlang rejects with {error, einval}.  Fix: derive the address family from
# ExtraFlags and strip `inet6` from ExtraFlags (it is already in BaseOpts).
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

LISTENER=$(find "${ROOT}/_build" -path '*/quic/src/quic_listener.erl' 2>/dev/null | head -1)

# H3 shutdown handling: treat peer-close and draining as normal exits so
# expected QUIC teardown does not show up as crash reports.
h3_found=0
for f in $(find "${ROOT}/_build" -path '*/quic/src/h3/quic_h3_connection.erl' 2>/dev/null | sort -u); do
  h3_found=1

  if grep -q 'invalid_state, draining' "$f" && grep -q '{stop, normal, State}' "$f"; then
    continue
  fi

  perl -i -0pe '
    s/h3_connecting\(enter, _OldState, State\) ->\n    %% Open critical streams and send SETTINGS\n    case open_critical_streams\(State\) of\n        \{ok, State1\} ->\n            case send_settings\(State1\) of\n                \{ok, State2\} ->\n                    \{keep_state, State2\};\n                \{error, Reason\} ->\n                    \{stop, \{error, Reason\}\}\n            end;\n        \{error, Reason\} ->\n            \{stop, \{error, Reason\}\}\n    end;/h3_connecting(enter, _OldState, State) ->\n    %% Open critical streams and send SETTINGS\n    case open_critical_streams(State) of\n        {ok, State1} ->\n            case send_settings(State1) of\n                {ok, State2} ->\n                    {keep_state, State2};\n                {error, {invalid_state, draining}} ->\n                    {keep_state, State1, [{next_event, cast, close}]};\n                {error, Reason} ->\n                    {stop, {error, Reason}}\n            end;\n        {error, {invalid_state, draining}} ->\n            {keep_state, State, [{next_event, cast, close}]};\n        {error, Reason} ->\n            {stop, {error, Reason}}\n    end;/s;
    s/\{stop, quic_closed, State\}/\{stop, normal, State\}/g
  ' "$f"
done

if [ "$h3_found" -eq 0 ]; then
  echo "patch-quic: warning: no quic_h3_connection.erl under _build (run rebar3 get-deps first)" >&2
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
