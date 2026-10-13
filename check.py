#!/usr/bin/env python3
"""Compares the BMP messages received with the expected result.

Expected (peer = route server AS 51706, nxthdr's RPKI import filter):
  Phase 1: pre-policy  = 6 prefixes (everything the peer announces)
           post-policy = 4 prefixes (the 2 RPKI-invalid ones are rejected)
  Phase 2: pre-policy  withdraws 2001:db8:100::/48 and 203.0.113.0/24
           post-policy withdraws 2001:db8:100::/48 (203.0.113.0/24 was never there)
Usage: check.py <run_directory>   -> prints a JSON summary, exit code 0 if everything matches.
"""
import json
import sys
from pathlib import Path

ALL = {"198.51.100.0/24", "203.0.113.0/24", "192.0.2.0/24",
       "2001:db8:100::/48", "2001:db8:200::/48", "2001:db8:300::/48"}
INVALID = {"203.0.113.0/24", "2001:db8:200::/48"}
EXPECT = {
    "p1_pre": ALL,
    "p1_post": ALL - INVALID,
    "p2_pre_withdrawn": {"2001:db8:100::/48", "203.0.113.0/24"},
    "p2_post_withdrawn": {"2001:db8:100::/48"},
}


def main():
    d = Path(sys.argv[1])
    t2 = float((d / "phase2.start").read_text())
    events = [json.loads(l) for l in (d / "bmp.jsonl").read_text().splitlines() if l.strip()]
    got = {k: set() for k in ("p1_pre", "p1_post", "p2_pre_withdrawn", "p2_post_withdrawn",
                              "p2_pre_announced", "p2_post_announced")}
    peer_up = {"pre": 0, "post": 0}
    paths = {}
    for e in events:
        if e["type"] == "peer_up":
            peer_up[e["policy"]] += 1
        if e["type"] != "route_monitoring":
            continue
        pol, phase = e["policy"], (1 if e["t"] < t2 else 2)
        if phase == 1:
            got[f"p1_{pol}"] |= set(e["announced"])
            got[f"p1_{pol}"] -= set(e["withdrawn"])
            for p in e["announced"]:
                paths[(pol, p)] = e["as_path"]
        else:
            got[f"p2_{pol}_withdrawn"] |= set(e["withdrawn"])
            got[f"p2_{pol}_announced"] |= set(e["announced"])

    checks = {k: got[k] == v for k, v in EXPECT.items()}
    checks["peer_up_received"] = peer_up["pre"] + peer_up["post"] >= 1
    checks["as_path_198.51.100.0/24"] = paths.get(("pre", "198.51.100.0/24")) == [51706, 64500]
    # No spurious announcement in phase 2 (remaining routes do not change)
    checks["p2_no_spurious_announce"] = not got["p2_pre_announced"] and not got["p2_post_announced"]
    summary = {
        "ok": all(checks.values()),
        "checks": checks,
        "counts": {k: len(v) for k, v in got.items()},
        "missing_or_extra": {k: {"missing": sorted(EXPECT[k] - got[k]), "extra": sorted(got[k] - EXPECT[k])}
                             for k in EXPECT if got[k] != EXPECT[k]},
        "peer_up": peer_up,
        "bmp_messages": len(events),
    }
    print(json.dumps(summary, indent=1))
    sys.exit(0 if summary["ok"] else 1)


if __name__ == "__main__":
    main()
