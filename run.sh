#!/usr/bin/env bash
# One full BMP test for one BIRD version and one configuration variant.
# Usage: sudo ./run.sh <version> [table|notable]
#   e.g. sudo ./run.sh 3.3.3          -> results in runs/3.3.3-table/
#   table   = "import table on" (nxthdr's production setting)
#   notable = without import table (case covered by upstream BIRD fix #463)
# The peer always runs BIRD 2.16.1: only the router under test changes.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
VERSION="$1"; VARIANT="${2:-table}"
DUT_BIN="$HERE/build/inst-$VERSION/sbin"
PEER_BIN="$HERE/build/inst-2.16.1/sbin"
OUT="$HERE/runs/$VERSION-$VARIANT"
for b in "$DUT_BIN/bird" "$PEER_BIN/bird"; do
  [ -x "$b" ] || { echo "Not found: $b  -> run ./build-bird.sh 2.16.1 $VERSION first"; exit 1; }
done
[ "$(id -u)" = 0 ] || { echo "Run with sudo (BGP listens on port 179)"; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT"; cd "$OUT"

cp "$HERE/peer.conf" peer.conf
grep -v '# PHASE1' "$HERE/peer.conf" > peer2.conf
if [ "$VARIANT" = table ]; then IT='import table on;'; else IT=''; fi
sed "s/@IMPORT_TABLE@/$IT/" "$HERE/dut.conf.tmpl" > dut.conf

python3 -I "$HERE/bmp_station.py" 127.0.0.1 4000 "$OUT/bmp.jsonl" & STATION=$!
sleep 0.5
"$PEER_BIN/bird" -c peer.conf -s peer.sock -P peer.pid
"$DUT_BIN/bird"  -c dut.conf  -s dut.sock  -P dut.pid

# Phase 1: session establishment and initial announcements
sleep 10
date +%s.%N > phase2.start
"$DUT_BIN/birdc" -s dut.sock show protocols all FranceIX1 > dut_proto_phase1.txt 2>&1
"$DUT_BIN/birdc" -s dut.sock show route all > dut_routes_phase1.txt 2>&1
"$DUT_BIN/birdc" -s dut.sock show route filtered > dut_filtered_phase1.txt 2>&1

# Phase 2: the peer withdraws 2001:db8:100::/48 (accepted) and 203.0.113.0/24 (rejected)
"$PEER_BIN/birdc" -s peer.sock configure \"peer2.conf\" > peer_reconf.txt 2>&1
sleep 8
"$DUT_BIN/birdc" -s dut.sock show route all > dut_routes_phase2.txt 2>&1

kill "$(cat dut.pid)" "$(cat peer.pid)" 2>/dev/null
sleep 1
kill "$STATION" 2>/dev/null
wait "$STATION" 2>/dev/null
echo "Done. Check with: python3 check.py runs/$VERSION-$VARIANT"
exit 0
