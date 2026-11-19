# Chrome HTTP/3 (QUIC) interop

## Issue (historical)

`send_server_handshake_flight` used to send the entire TLS handshake flight (EncryptedExtensions + certificate chain + CertificateVerify + Finished, often **3–5 KB**) as **one UDP datagram**, violating [RFC 9000 §12.2](https://www.rfc-editor.org/rfc/rfc9000.html#section-12.2) (`max_udp_payload_size`).

Chrome advertises **1472** bytes and drops oversized packets (`ERR_MSG_TOO_BIG`). The handshake stalls, the client may idle-timeout, and the browser falls back to **HTTP/2**. `curl` often still works (less strict UDP handling).

## Upstream erlang_quic status

Tracked pin is **`3.1.3`** (see `rebar.config`). Upstream since 1.4.0 includes the Chromium interop fix for oversized TLS handshake flight datagrams (#134/#137). Highlights through **3.1.3**: hostname/EKU cert checks, secret redaction, BBRv3, ACK frequency, idle/timer CPU cuts, H3 datagram malformed close. OTP **27+** is required (CI/RPM already use 27–29).

Local `scripts/patch-quic.sh` still applies three HTTP/3 helpers not upstream yet: H3 draining `catch open_critical_streams`, listener `max_early_data` + ticket disable when 0, and PSK-resume anti-amplification. QPACK RIC / inet6 / SNI passthrough are already upstream.

## Admin UI over HTTP/3

Management sites (`upstream` → loopback `:9080`) must serve **`/`, `/assets/*`, and `/api/*` on the same QUIC connection**. If only `/api/*` is handled on HTTP/3 and the SPA is proxied to `:9080` over HTTP/1.1, Chrome often shows **h2** for the document and normal reload while **hard reload** may show **h3** for API calls only.

`pertisk_eproxy_h3_local_admin` serves the full management site in-process on HTTP/3.

Do **not** route `/assets/*` through `cowboy_static` on HTTP/3: it uses `cowboy_rest` and the H3 stub only captures `cowboy_req:reply/4`, so requests hang for **60s** then return **502**. Static files are read directly from `priv/admin/assets/`.

## Not only QUIC library code

Chrome can still use HTTP/2 when:

- Release was built with an older `erlang_quic` than expected
- TLS PEM is **leaf-only** (no intermediate chain) — strict on QUIC
- **UDP** to `quic_port` / `alt_svc_port` is blocked (firewall, LB, K8s Service)
- **Alt-Svc** not seen yet (first request is HTTPS/TCP) or a prior failed H3 attempt is cached
- Chrome **Alt-Svc cache** marks QUIC broken after a failed attempt — clear at `chrome://net-internals/#alt-svc` or wait for `ma=86400` to expire
- **Kubernetes: multiple replicas** — UDP LB often is not sticky per QUIC connection; use `replicaCount: 1`, `service.externalTrafficPolicy: Local`, or hostNetwork (see `deploy/helm/pertisk-eproxy/examples/cloud/README.md`)

Project now tracks upstream `erlang_quic` directly via `rebar.config`.
