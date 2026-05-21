What the bug is: send_server_handshake_flight sends the entire TLS handshake flight (EncryptedExtensions + Certificate chain + CertificateVerify + Finished, typically 3–5 KB) as a single UDP datagram, violating the QUIC RFC requirement to respect max_udp_payload_size.

Impact: Any QUIC client that strictly enforces its advertised max_udp_payload_size (e.g. Chromium, which advertises 1472 bytes) drops the oversized packet with ERR_MSG_TOO_BIG. In practice the connection is unstable in both Chrome and Firefox, and it may fall back to HTTP/2 or fail to complete HTTP/3. The TLS handshake stalls and the client closes the connection with QUIC_NETWORK_IDLE_TIMEOUT after ~4 seconds. curl works by accident because its UDP socket buffer is generous.

The fix: Fragment the CRYPTO payload into chunks that fit within the current MTU (get_current_mtu/1), each sent as a separate HANDSHAKE-level QUIC packet with the correct CRYPTO stream offset. The peer's offset-based CRYPTO buffer reassembles them — this is exactly what RFC 9000 §7 requires.

Reference: RFC 9000 §12.2 — "A sender MUST NOT send a packet with a UDP datagram payload larger than the value advertised by its peer in max_udp_payload_size".

