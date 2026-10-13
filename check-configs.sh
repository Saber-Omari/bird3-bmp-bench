#!/usr/bin/env bash
# Renders the BIRD configuration templates of nxthdr/infrastructure with dummy
# values and checks that each one parses (bird -p) with the given BIRD versions.
# Requires: git, python3-jinja2, and the versions built with ./build-bird.sh
#
# Usage: ./check-configs.sh 2.16.1 3.3.3
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$HERE/runs/configs"
rm -rf "$WORK"; mkdir -p "$WORK"

git clone -q --depth 1 https://github.com/nxthdr/infrastructure.git "$WORK/infrastructure"
echo "nxthdr/infrastructure at commit $(git -C "$WORK/infrastructure" rev-parse --short HEAD)"

# peerlab-map.conf is generated at runtime by peerlab-bird-config; this stub
# follows the format of that tool (function enforce_user_policy).
cat > "$WORK/peerlab-map.conf" <<'EOF'
function enforce_user_policy(ip remote_ip) {
    if (remote_ip = 100.64.0.10) then {
        if (bgp_path.last != 65000) then reject;
        if !(net ~ [ 2a06:de00:5b:1000::/64 ]) then reject;
        accept;
    }
    reject;
}
EOF

python3 - "$WORK" <<'EOF'
import pathlib, sys, jinja2
work = pathlib.Path(sys.argv[1]); repo = work / "infrastructure"; out = work / "rendered"
dummy = dict(tailscale_ip="100.64.0.1", uniprobe0="2001:db8:ffff::/48",
             v6_main_ip="2001:db8:1:2:3:4:5:6", main_ip="192.0.2.10",
             bird_vultr_peering_password="dummy")
env = jinja2.Environment(undefined=jinja2.StrictUndefined)
for t in sorted(repo.glob("templates/config/**/bird/*.conf.j2")):
    host = t.parts[-3]; d = out / host; d.mkdir(parents=True, exist_ok=True)
    txt = env.from_string(t.read_text()).render(**dummy, inventory_hostname=host)
    txt = txt.replace('include "/etc/bird/peerlab.conf";', f'include "{d}/peerlab.conf";')
    txt = txt.replace('include "/etc/bird/peerlab-map.conf";', f'include "{work}/peerlab-map.conf";')
    (d / t.name[:-3]).write_text(txt)
EOF

for v in "$@"; do
  echo "=== BIRD $v ==="
  for conf in "$WORK"/rendered/*/bird.conf; do
    host="$(basename "$(dirname "$conf")")"
    res="$("$HERE/build/inst-$v/sbin/bird" -p -c "$conf" 2>&1 | sed -E 's/^bird: ([0-9-]+ [0-9:.]+ \[[0-9]+\] )?//; s|'"$WORK"'/rendered/||')"
    printf '  %-10s %s\n' "$host" "${res:-OK}"
  done
done
