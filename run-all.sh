#!/usr/bin/env bash
# Runs the bench for several versions and writes a summary table (runs/SUMMARY.md).
# Usage: sudo ./run-all.sh 2.16.1 3.2.0 gouel-fix 3.3.2 3.3.3
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUM="$HERE/runs/SUMMARY.md"
mkdir -p "$HERE/runs"
{
  echo "| BIRD | Result | pre-policy (P1) | post-policy (P1) | pre withdrawn (P2) | post withdrawn (P2) | BMP messages | Router alive after withdrawals |"
  echo "|---|---|---|---|---|---|---|---|"
} > "$SUM"
for v in "$@"; do
  "$HERE/run.sh" "$v" table >/dev/null
  d="$HERE/runs/$v-table"
  python3 "$HERE/check.py" "$d" > "$d/check.json"
  alive=$(grep -q 'Connection refused' "$d/dut_routes_phase2.txt" && echo no || echo yes)
  python3 - "$d/check.json" "$v" "$alive" >> "$SUM" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); c = d["counts"]
print(f"| {sys.argv[2]} | {'PASS' if d['ok'] else 'FAIL'} | {c['p1_pre']}/6 | {c['p1_post']}/4 | "
      f"{c['p2_pre_withdrawn']}/2 | {c['p2_post_withdrawn']}/1 | {d['bmp_messages']} | {sys.argv[3]} |")
PY
  echo "$v : $(tail -1 "$SUM")"
done
echo; echo "Summary: $SUM"
