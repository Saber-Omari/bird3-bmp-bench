# BIRD 3 BMP bench for nxthdr

A small, reproducible test bench to check whether a given BIRD version exports
**BMP Adj-RIB-In pre-policy and post-policy** correctly with the
[nxthdr](https://nxthdr.dev) IXP router configuration.

Context: [nxthdr/infrastructure#22](https://github.com/nxthdr/infrastructure/issues/22)
(*Update Bird to 3.0*), which is on hold because BMP RIB-In monitoring broke in BIRD 3.

## TL;DR

**BIRD 3.3.3 (released 2026-10-02) behaves like the current production version
(2.16.1)** on this bench: same pre-policy and post-policy content, same
withdrawals. The upstream fixes in 3.3.3 appear to resolve the BMP issue
without a patched BIRD.

| BIRD | Result | pre-policy (P1) | post-policy (P1) | pre withdrawn (P2) | post withdrawn (P2) | BMP messages | Router alive after withdrawals |
|---|---|---|---|---|---|---|---|
| 2.16.1 (production) | PASS | 6/6 | 4/4 | 2/2 | 1/1 | 21 | yes |
| 3.2.0 | FAIL | 0/6 | 0/4 | 0/2 | 0/1 | 8 | yes |
| 3.2.0 + `fix-bmp-adj-rib-in` | FAIL | 6/6 | **6/4** | 0/2 | 0/1 | 27–39 | **no** |
| 3.3.2 | FAIL | 0/6 | 0/4 | 0/2 | 0/1 | 2 | **no** |
| **3.3.3** | **PASS** | 6/6 | 4/4 | 2/2 | 1/1 | 24–33 | yes |

- **3.2.0**: the BGP session is up but no route is exported over BMP
  (reproduces the RIB-In issue reported in #22).
- **3.2.0 + `fix-bmp-adj-rib-in`** ([matthieugouel/bird@835ea3f](https://github.com/matthieugouel/bird/commit/835ea3fa)):
  routes are exported, but the 2 RPKI-rejected routes also appear as
  post-policy, and the bird process is no longer running a few seconds after the withdrawals
  (nothing in its log; cause not investigated).
- **3.3.2**: bird crashes when sending routes to the BMP station
  (`Assertion 'b->my_id' failed at proto/bgp/attrs.c`), presumably the crash
  fixed in 3.3.3 by *BMP: Fix crash on sending routes*.
- **3.3.3**: correct. Upstream BMP fixes included in 3.3.3 / 3.2.4 / 3.1.9:
  *BMP: Fix route sending when no import table is configured* (BIRD #463) and
  *BMP: Fix crash on sending routes* (BIRD #429).

### Scope

This bench answers one question: **does the BMP RIB-In regression that blocks #22
still exist in BIRD 3.3.3?** It does not validate 3.3.3 for production. Not covered:

- long-running stability (each run lasts ~20 s);
- behaviour of the full nxthdr configurations (only syntax is checked; behaviour is
  tested for the BMP block and `ImportFilter` of `ixpcdg01`);
- integration with risotto (a minimal BMP station is used instead);
- full routing tables (6 prefixes here), CPU and memory usage.

These need a staged rollout on the real infrastructure (e.g. one IXP router first,
comparing BMP volumes in ClickHouse before and after).

### One difference: duplicate announcements in 3.3.3

3.3.3 sends more BMP messages than 2.16.1 for the same final state (24 to 33
across runs, depending on timing, vs 21). Two sources were observed:

1. at session establishment, some announcements are sent twice;
2. about 1 s later, the RPKI-**valid** prefixes are re-sent as post-policy,
   which looks like the RPKI re-evaluation of routes whose filter result
   depends on a ROA (invalid ones are rejected again, so nothing is sent;
   not-found ones are not affected).

The final pre/post state is identical. risotto's curation (see its README,
*Data Curation*) drops announcements for prefixes already in its state, so
these duplicates should not reach ClickHouse. Not verified on the real
pipeline yet, nor whether its deduplication key distinguishes pre- and
post-policy.

### Configuration compatibility

All 7 BIRD configurations of `nxthdr/infrastructure` (rendered from the Jinja
templates with dummy values) parse with BIRD 3.3.3. Only one warning:
`vlt/bird.conf` sets `password` without `authentication md5;`
(BIRD 3 assumes MD5; adding the line makes it explicit).

Reproduce with `./check-configs.sh 2.16.1 3.3.3`: it clones `nxthdr/infrastructure`,
renders the templates with dummy values (and a stub for the runtime-generated
`peerlab-map.conf`), then runs `bird -p` on each configuration.

## What the bench does

```
 peer (BIRD 2.16.1)            router under test              BMP station
 AS 51706, acts as the         AS 215011, nxthdr config       bmp_station.py
 France-IX route server        (BMP + ImportFilter)           (one JSON line per message)
 127.0.0.2   ---- eBGP ---->   127.0.0.3   ---- BMP ---->      127.0.0.1:4000
              IPv4 + IPv6 (IPv6 over the IPv4 session, extended next hop)
```

The router under test (`dut.conf.tmpl`) copies from
`templates/config/ixp/ixpcdg01/bird/bird.conf.j2`:

- the `protocol bmp` block (`monitoring rib in pre_policy` and `post_policy`);
- `is_rpki_invalid()` and `ImportFilter`;
- the channel options `import table on; import keep filtered;`.

Differences from production: ROAs come from a `static` protocol instead of the
Cloudflare RTR; the session runs between loopback addresses (`multihop`,
`strict bind on`); IPv6 routes are carried over the IPv4 session; no export
filter, `kernel` or `direct` protocols.

The peer announces 6 prefixes:

| Prefix | Origin | ROA | RPKI | Expected |
|---|---|---|---|---|
| 198.51.100.0/24, 2001:db8:100::/48 | AS64500 | AS64500 | valid | pre + post |
| 203.0.113.0/24, 2001:db8:200::/48 | AS64501 | AS64999 | invalid | pre only |
| 192.0.2.0/24, 2001:db8:300::/48 | AS64502 | none | not found | pre + post |

- **Phase 1** (10 s): expected 6 prefixes pre-policy, 4 post-policy.
- **Phase 2**: the peer withdraws `2001:db8:100::/48` (accepted) and
  `203.0.113.0/24` (rejected). Expected: 2 withdrawals pre-policy,
  1 withdrawal post-policy.

## Reproduce

Linux (or WSL2), root needed for BGP on port 179.

```bash
sudo apt install build-essential flex bison m4 libreadline-dev libncurses-dev \
                 curl python3 python3-jinja2 git autoconf

# build into ./build/ (nothing installed system-wide, ~2 min per version)
./build-bird.sh 2.16.1 3.2.0 3.3.2 3.3.3 gouel-fix

# run every version and write runs/SUMMARY.md
sudo ./run-all.sh 2.16.1 3.2.0 gouel-fix 3.3.2 3.3.3
```

One version only:

```bash
sudo ./run.sh 3.3.3
python3 check.py runs/3.3.3-table
```

Each run directory (`runs/<version>-table/`) contains:

| File | Content |
|---|---|
| `bmp.jsonl` | every BMP message received by the station |
| `check.json` | comparison with the expected result |
| `dut.conf` | exact configuration of the router under test |
| `dut.log` | BIRD log (crash messages appear here) |
| `dut_proto_phase1.txt` | `show protocols all` (imported / filtered counts) |
| `dut_filtered_phase1.txt` | routes rejected by `ImportFilter` |

Variant without `import table on` (not nxthdr's setting): `sudo ./run.sh 3.3.3 notable`.
Without an import table, BIRD exports only post-policy (same behaviour in 2.16.1 and 3.3.3).

## Files

| File | Role |
|---|---|
| `build-bird.sh` | downloads and builds BIRD with `--with-protocols='bmp,bgp,rpki,static'` |
| `run.sh` | one test run: station, peer, router under test, two phases |
| `run-all.sh` | runs several versions and writes the summary table |
| `check.py` | compares received BMP messages with the expected result |
| `bmp_station.py` | minimal BMP station (RFC 7854) |
| `peer.conf` | peer configuration (phase 2 = same file without `# PHASE1` lines) |
| `dut.conf.tmpl` | router under test, from nxthdr's `ixpcdg01` |
| `check-configs.sh` | renders nxthdr's BIRD templates and checks they parse |

## Test environment

- Date: 2026-10-14
- OS: Ubuntu 26.04.1 LTS (aarch64), kernel 7.2.9-orbstack-00391-g2b298d05fbd4;
  results also identical on x86_64 (Ubuntu 24.04)
- BIRD builds (commit): 2.16.1, 3.2.0 (`0b91feed`), 3.3.2 (`e66773c4`), 3.3.3 (`2ed8b593`),
  `fix-bmp-adj-rib-in` (`835ea3fa`)
- `nxthdr/infrastructure` configurations checked at commit `407d3dc`
- Every version was run at least once on each architecture (aarch64 above,
  and x86_64 on Ubuntu 24.04); 2.16.1 and 3.3.3 several times on both.
  PASS/FAIL and prefix counts are identical across all runs; only the number
  of BMP messages varies.

## Limitations

- IPv4 transport only (IPv6 prefixes over MP-BGP); no native IPv6 BGP session.
- Next hops are not resolved (routes are `unreachable`); no effect on BMP.
- ROAs are static, not received over RTR, so continuous ROA updates are not exercised.
- One peer, 6 prefixes: this is a functional check, not a load test
  (BIRD 3 is multi-threaded; CPU and memory on a full table are not measured).
- The bench uses its own BMP station, not risotto; the duplicate handling
  by risotto's curation is not tested here.

## License

MIT
