#!/usr/bin/env python3
"""Minimal BMP station (RFC 7854) for testing BIRD.

Listens on TCP, decodes every BMP message and writes one JSON event per line:
  - t: reception timestamp
  - type (initiation, peer_up, route_monitoring, ...)
  - policy: "pre" (Adj-RIB-In pre-policy) or "post" (L flag of the per-peer header)
  - announced / withdrawn: IPv4 and IPv6 prefixes (plain NLRI + MP_REACH/MP_UNREACH)
  - as_path: AS path of the UPDATE

Usage: bmp_station.py <host> <port> <output.jsonl>
"""
import ipaddress
import json
import socket
import struct
import sys
import threading
import time

MSG_TYPES = {0: "route_monitoring", 1: "stats", 2: "peer_down", 3: "peer_up",
             4: "initiation", 5: "termination", 6: "route_mirroring"}
LOCK = threading.Lock()


def read_exact(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return buf


def parse_prefixes(data, afi):
    """Decodes a sequence of prefixes encoded as <length in bits><bytes>."""
    out, i = [], 0
    size = 4 if afi == 1 else 16
    while i < len(data):
        plen = data[i]
        nbytes = (plen + 7) // 8
        raw = data[i + 1:i + 1 + nbytes] + b"\x00" * (size - nbytes)
        out.append(f"{ipaddress.ip_address(raw)}/{plen}")
        i += 1 + nbytes
    return out


def parse_update(body):
    """Decodes a BGP UPDATE message (including the 19-byte BGP header)."""
    res = {"announced": [], "withdrawn": [], "as_path": []}
    if body[18] != 2:
        res["bgp_type"] = body[18]
        return res
    p = 19
    wlen = struct.unpack("!H", body[p:p + 2])[0]; p += 2
    res["withdrawn"] += parse_prefixes(body[p:p + wlen], 1); p += wlen
    alen = struct.unpack("!H", body[p:p + 2])[0]; p += 2
    attrs, p_end = body[p:p + alen], p + alen
    j = 0
    while j < len(attrs):
        flags, atype = attrs[j], attrs[j + 1]
        if flags & 0x10:
            l = struct.unpack("!H", attrs[j + 2:j + 4])[0]; j += 4
        else:
            l = attrs[j + 2]; j += 3
        val = attrs[j:j + l]; j += l
        if atype == 2:  # AS_PATH, 4-byte ASNs in BMP
            k = 0
            while k < len(val):
                cnt = val[k + 1]
                res["as_path"] += list(struct.unpack(f"!{cnt}I", val[k + 2:k + 2 + 4 * cnt]))
                k += 2 + 4 * cnt
        elif atype == 14:  # MP_REACH_NLRI
            afi = struct.unpack("!H", val[0:2])[0]
            nhlen = val[3]
            res["announced"] += parse_prefixes(val[5 + nhlen:], afi)
        elif atype == 15:  # MP_UNREACH_NLRI
            afi = struct.unpack("!H", val[0:2])[0]
            res["withdrawn"] += parse_prefixes(val[3:], afi)
    res["announced"] += parse_prefixes(body[p_end:], 1)
    if not res["announced"] and not res["withdrawn"]:
        res["end_of_rib"] = True
    return res


def handle(conn, out_path):
    with conn, open(out_path, "a") as out:
        try:
            while True:
                version, length, mtype = struct.unpack("!BIB", read_exact(conn, 6))
                body = read_exact(conn, length - 6)
                ev = {"t": time.time(), "type": MSG_TYPES.get(mtype, mtype), "version": version}
                if mtype in (0, 1, 2, 3):
                    flags = body[1]
                    addr = body[10:26]
                    ev["peer"] = str(ipaddress.ip_address(addr if flags & 0x80 else addr[12:]))
                    ev["peer_as"] = struct.unpack("!I", body[26:30])[0]
                    ev["policy"] = "post" if flags & 0x40 else "pre"
                    ev["adj_rib_out"] = bool(flags & 0x10)
                    if mtype == 0:
                        ev.update(parse_update(body[42:]))
                with LOCK:
                    out.write(json.dumps(ev) + "\n"); out.flush()
        except (EOFError, ConnectionResetError):
            with LOCK:
                out.write(json.dumps({"t": time.time(), "type": "disconnect"}) + "\n"); out.flush()


def main():
    host, port, out_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen()
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn, out_path), daemon=True).start()


if __name__ == "__main__":
    main()
