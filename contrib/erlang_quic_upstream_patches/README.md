# Upstream PR: `erlang_quic` interop fixes (QPACK + QUIC listener)

These changes are vendored in `_checkouts/quic/` in this repo. To contribute them upstream to [benoitc/erlang_quic](https://github.com/benoitc/erlang_quic), apply `pertisk-vendor-quic-interop-v1.3.0.patch` on tag **`v1.3.0`** (commit `e3261d38486325d4eb68626b551debd181322c4a`). The same patch file also updates **`src/h3/quic_h3_connection.erl`**: `gen_statem` **postpone** for outbound H3 during `awaiting_quic` / `h3_connecting`, **`{quic, …, {closed, …}}`** handling, transition **`quic_ref` `DOWN`** to **`closing`** (instead of **`stop`**), and explicit **`send_response` / `send_trailers`** in **`goaway_sent` / `goaway_received`** so **`gen_statem:call`** always gets a reply.

## Local first (automated)

From the **pertisk-eproxy** repo root:

```bash
make quic-upstream-local
```

Or:

```bash
bash contrib/erlang_quic_upstream_patches/apply-local.sh
```

This clones **`../erlang_quic`** next to this repository (unless **`ERLANG_QUIC_LOCAL`** points elsewhere), checks out **`v1.3.0`**, applies **`pertisk-vendor-quic-interop-v1.3.0.patch`**, and runs **`rebar3 compile`** in that clone. Then create a branch and push when satisfied.

Optional environment variables:

| Variable | Default | Purpose |
|----------|---------|---------|
| `ERLANG_QUIC_LOCAL` | `<parent-of-this-repo>/erlang_quic` | Clone directory |
| `ERLANG_QUIC_TAG` | `v1.3.0` | Tag to check out before applying |
| `ERLANG_QUIC_GIT_URL` | `https://github.com/benoitc/erlang_quic.git` | Upstream URL |

To run the script again on the **same** clone, reset it first (the script refuses a dirty working tree):

```bash
git -C "$ERLANG_QUIC_LOCAL" reset --hard "${ERLANG_QUIC_TAG:-v1.3.0}"
```

## Apply manually (upstream clone)

```bash
git clone https://github.com/benoitc/erlang_quic.git && cd erlang_quic
git checkout v1.3.0
git apply /path/to/pertisk-eproxy/contrib/erlang_quic_upstream_patches/pertisk-vendor-quic-interop-v1.3.0.patch
rebar3 compile
```

## Suggested PR title

**QPACK RIC=0 Base (RFC 9204); inet6 dual-stack UDP listener; quic_h3_connection gen_statem hardening**

## Suggested PR body (paste into GitHub)

### Summary

Interop and robustness fixes discovered while using `quic_h3` behind Chrome, dual-stack DNS (A + AAAA), and server handlers that can finish before SETTINGS exchange completes.

### 1) QPACK encoder: invalid Base prefix when RIC = 0

RFC 9204 §4.5.1.2: a field block with **Sign = 1** is invalid when **Required Insert Count ≤ Delta Base**. For static-only sections **RIC = 0** and **Base = 0**, the encoder must use **Sign = 0**, **DeltaBase = 0** (second prefix byte `0x00`), not `0x80`.

Previously `quic_qpack:encode/2` always used `BaseEncoded = 16#80`, which strict decoders (e.g. Chromium) reject with errors along the lines of “Error calculating Base”.

### 2) `socket` backend: `extra_socket_opts => [inet6]` was ignored

`open_socket_backend/3` always opened `inet` and bound `#{family => inet, ...}`, so callers could not obtain an IPv6 dual-stack UDP listener via `extra_socket_opts`.

When `inet6` is present in `extra_socket_opts`, the listener now opens **`inet6`**, attempts **`{ipv6, v6only}, false`** before bind (ignored if unsupported), and binds **`::`**.

### 3) `quic_h3_connection`: avoid `gen_statem:call` hangs / silent failures during connect and GOAWAY

- **`awaiting_quic` / `h3_connecting`**: **`send_response`**, **`send_data`**, and **`send_trailers`** calls are **postponed** until **`connected`**, matching the race where a request handler replies before SETTINGS complete.
- **`quic_ref` `DOWN`**: use **`{next_state, closing, …}`** instead of **`{stop, quic_closed, …}`** so the owner gets the normal **`{quic_h3, _, closed}`** path.
- **`{quic, _, {closed, _}}`**: transition to **`closing`** during early states and in **`goaway_*`**.
- **`goaway_sent` / `goaway_received`**: handle **`send_response`** and **`send_trailers`** (same pattern as **`send_data`**) instead of falling through to the catch-all (which does not reply to **`call`**).

### Testing

- `rebar3 compile`
- Manual: HTTP/3 from Chrome to a server using `qpack_max_table_capacity => 0` (static QPACK) and `extra_socket_opts => [inet6]` on Linux (`socket` backend).
- Optional: extend `quic_qpack_tests` with a decode-roundtrip for an encoded block with RIC=0 if not already covered.

### References

- RFC 9204 (QPACK), §4.5.1.2 Base encoding
- RFC 3493 / dual-stack `IPV6_V6ONLY` behaviour for `::` listeners

---

Maintainers: happy to split into two PRs if you prefer separate review for QPACK vs socket listener.
