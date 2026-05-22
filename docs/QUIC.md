# Chrome HTTP/3 (QUIC) interop

## Issue (historical)

`send_server_handshake_flight` used to send the entire TLS handshake flight (EncryptedExtensions + certificate chain + CertificateVerify + Finished, often **3–5 KB**) as **one UDP datagram**, violating [RFC 9000 §12.2](https://www.rfc-editor.org/rfc/rfc9000.html#section-12.2) (`max_udp_payload_size`).

Chrome advertises **1472** bytes and drops oversized packets (`ERR_MSG_TOO_BIG`). The handshake stalls, the client may idle-timeout, and the browser falls back to **HTTP/2**. `curl` often still works (less strict UDP handling).

## Fixes in `_checkouts/quic` (vendored `erlang_quic`)

| Area | Status |
|------|--------|
| **Handshake CRYPTO fragmentation** | `send_handshake_crypto_fragmented/3` splits the server flight into multiple HANDSHAKE packets |
| **Peer `max_udp_payload_size`** | Chunk budget uses `get_effective_max_udp_payload_size/1` (min local PMTU, peer TP — Chrome **1472**) |
| **Oversized HANDSHAKE guard** | `send_handshake_packet/2` refuses to send datagrams larger than the effective limit |
| **QPACK RIC=0 Base** | `quic_qpack` uses Sign=0 for static-only blocks (Chrome rejects `0x80` prefix) |
| **Dual-stack UDP** | `quic_listener` honors `extra_socket_opts => [inet6]` and binds `::` |
| **HTTP/3 state machine** | `quic_h3_connection` postpones early `send_response`, handles GOAWAY/`closed` cleanly |

After changing `_checkouts/quic`, sync into the build tree:

```bash
bash scripts/sync-quic-deps.sh
rebar3 compile
```

## Admin UI over HTTP/3

Management sites (`upstream` → loopback `:9080`) must serve **`/`, `/assets/*`, and `/api/*` on the same QUIC connection**. If only `/api/*` is handled on HTTP/3 and the SPA is proxied to `:9080` over HTTP/1.1, Chrome often shows **h2** for the document and normal reload while **hard reload** may show **h3** for API calls only.

`pertisk_eproxy_h3_local_admin` serves the full management site in-process on HTTP/3.

Do **not** route `/assets/*` through `cowboy_static` on HTTP/3: it uses `cowboy_rest` and the H3 stub only captures `cowboy_req:reply/4`, so requests hang for **60s** then return **502**. Static files are read directly from `priv/admin/assets/`.

## Not only QUIC library code

Chrome can still use HTTP/2 when:

- Release was built **before** vendored quic fixes (stale `deps/quic`)
- TLS PEM is **leaf-only** (no intermediate chain) — strict on QUIC
- **UDP** to `quic_port` / `alt_svc_port` is blocked (firewall, LB, K8s Service)
- **Alt-Svc** not seen yet (first request is HTTPS/TCP) or a prior failed H3 attempt is cached
- Chrome **Alt-Svc cache** marks QUIC broken after a failed attempt — clear at `chrome://net-internals/#alt-svc` or wait for `ma=86400` to expire

See `contrib/erlang_quic_upstream_patches/README.md` for upstreaming patches to [benoitc/erlang_quic](https://github.com/benoitc/erlang_quic).
