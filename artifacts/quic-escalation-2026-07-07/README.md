# QUIC Intermittent Timeout Escalation Bundle

Timestamp (UTC): 2026-07-07T06:48:47Z
Server: homelab-apps (10.1.1.9)

## Scope
This bundle captures evidence for intermittent HTTP/3 timeout behavior after QUIC hardening and conntrack bypass mitigation.

## Applied Mitigations
- QUIC transport hardening in application config and runtime
  - address_validation: never
  - max_udp_payload_size: 1200
  - pmtu_enabled: false
- Host tuning applied
  - net.core.rmem_max = 33554432
  - net.core.wmem_max = 33554432
  - net.core.netdev_max_backlog = 250000
  - net.netfilter.nf_conntrack_max = 1048576
  - net.netfilter.nf_conntrack_udp_timeout = 30
  - net.netfilter.nf_conntrack_udp_timeout_stream = 180
- nftables conntrack bypass for UDP/443
  - table inet quic_raw, raw hook prerouting: udp dport 443 notrack
  - table inet quic_raw, raw hook output: udp sport 443 notrack
- Persistence configured
  - /etc/nftables.d/quic-notrack.nft created
  - include added to /etc/nftables.conf

## Reliability Measurements (strict HTTP/3 only)
- 120 attempts: ok=119 fail=1
- 100 attempts during packet capture: ok=99 fail=1
- 120 attempts after persistence step: ok=114 fail=6

Observed failing client error pattern:
- curl error 28 (Connection timed out after ~6000ms)

## Packet and Counter Evidence
Files in this bundle:
- quic-443-2.pcap
- quic-tcpdump2.log
- quic-snmp-before.txt
- quic-snmp-after.txt

Capture summary from test window:
- pcap size: ~1.3 MB
- packet count: 2922 UDP packets on port 443
- ICMP indicators in capture: 0 matches for unreachable or frag needed

UDP kernel counter deltas over the same window:
- InDatagrams: +1034
- OutDatagrams: +2559
- InErrors: +0
- RcvbufErrors: +0
- SndbufErrors: +0
- InCsumErrors: +0
- NoPorts: +0

## Interpretation
- Application and server host evidence do not show local UDP buffer or checksum errors during sampled failures.
- Intermittent timeout remains consistent with upstream path/provider-level UDP loss or transient filtering outside host stack.

## Recommended Provider Escalation Request
Request provider/path investigation for intermittent UDP/443 drops affecting QUIC to host 10.1.1.9, including:
- Routing/asymmetric path checks
- UDP policer/rate-limit behavior
- Anycast or edge node consistency
- MTU and fragmentation handling along path
- Time-correlated packet loss around timeout windows
