#!/usr/bin/env bash
set -euo pipefail

REPORT_DIR="${1:-/Users/nat/projects/pertisk-tech/pertisk-k6-proxy/reports/proxy}"

if [[ ! -d "$REPORT_DIR" ]]; then
  echo "report directory not found: $REPORT_DIR" >&2
  exit 1
fi

python3 - "$REPORT_DIR" <<'PY'
import glob
import os
import re
import statistics
import sys

report_dir = sys.argv[1]
paths = sorted(glob.glob(os.path.join(report_dir, "*.txt")))
if not paths:
    print(f"No report files found in {report_dir}")
    raise SystemExit(1)

rows = []
for p in paths:
    text = open(p, "r", encoding="utf-8", errors="replace").read()
    base_m = re.search(r"BASE_URL: (.+)", text)
    dur_m = re.search(r"Duration: ([0-9.]+)s", text)
    tps_m = re.search(r"TPS \(req/s\): ([0-9.]+)", text)
    avg_m = re.search(r"Latency avg: ([0-9.]+) ms", text)
    p90_m = re.search(r"Latency p90: ([0-9.]+) ms", text)
    p95_m = re.search(r"Latency p95: ([0-9.]+) ms", text)
    if not (base_m and dur_m and tps_m and avg_m and p90_m and p95_m):
        continue

    base = base_m.group(1).strip()
    kind = "cloud" if ".cloud." in base else ("erlang" if ".erlang." in base else "other")
    rows.append(
        {
            "file": os.path.basename(p),
            "base": base,
            "kind": kind,
            "duration": float(dur_m.group(1)),
            "tps": float(tps_m.group(1)),
            "avg": float(avg_m.group(1)),
            "p90": float(p90_m.group(1)),
            "p95": float(p95_m.group(1)),
        }
    )

if not rows:
    print("No parseable report files found.")
    raise SystemExit(1)

print("# Proxy Report Comparison")
print()
print(f"Directory: {report_dir}")
print()
print("## Parsed Runs")
print("| file | kind | duration_s | tps | avg_ms | p90_ms | p95_ms |")
print("|---|---:|---:|---:|---:|---:|---:|")
for r in rows:
    print(
        f"| {r['file']} | {r['kind']} | {r['duration']:.2f} | {r['tps']:.2f} | {r['avg']:.2f} | {r['p90']:.2f} | {r['p95']:.2f} |"
    )

print()
print("## Window Averages (Erlang vs Cloud)")
print("| window_s | cloud_tps | erlang_tps | erlang_vs_cloud_tps | cloud_p95_ms | erlang_p95_ms | erlang_vs_cloud_p95 |")
print("|---:|---:|---:|---:|---:|---:|---:|")

for window in (60, 90):
    cloud = [r for r in rows if r["kind"] == "cloud" and abs(r["duration"] - window) < 1.0]
    erlang = [r for r in rows if r["kind"] == "erlang" and abs(r["duration"] - window) < 1.0]
    if not cloud or not erlang:
        continue

    cloud_tps = statistics.mean(r["tps"] for r in cloud)
    erlang_tps = statistics.mean(r["tps"] for r in erlang)
    cloud_p95 = statistics.mean(r["p95"] for r in cloud)
    erlang_p95 = statistics.mean(r["p95"] for r in erlang)

    tps_delta = (erlang_tps / cloud_tps - 1.0) * 100.0
    p95_delta = (erlang_p95 / cloud_p95 - 1.0) * 100.0

    print(
        f"| {window} | {cloud_tps:.2f} | {erlang_tps:.2f} | {tps_delta:+.1f}% | {cloud_p95:.2f} | {erlang_p95:.2f} | {p95_delta:+.1f}% |"
    )

cloud90 = sorted(
    [r for r in rows if r["kind"] == "cloud" and abs(r["duration"] - 90) < 1.0],
    key=lambda x: x["file"],
)
erlang90 = sorted(
    [r for r in rows if r["kind"] == "erlang" and abs(r["duration"] - 90) < 1.0],
    key=lambda x: x["file"],
)

if cloud90 and erlang90:
    print()
    print("## 90s Pairwise vs Latest Cloud")
    latest_cloud = cloud90[-1]
    print(
        f"Reference cloud: {latest_cloud['file']} (TPS {latest_cloud['tps']:.2f}, p95 {latest_cloud['p95']:.2f} ms)"
    )
    print("| erlang_file | tps | p95_ms | tps_delta_vs_cloud | p95_delta_vs_cloud |")
    print("|---|---:|---:|---:|---:|")
    for e in erlang90:
        tps_delta = (e["tps"] / latest_cloud["tps"] - 1.0) * 100.0
        p95_delta = (e["p95"] / latest_cloud["p95"] - 1.0) * 100.0
        print(
            f"| {e['file']} | {e['tps']:.2f} | {e['p95']:.2f} | {tps_delta:+.1f}% | {p95_delta:+.1f}% |"
        )
PY
