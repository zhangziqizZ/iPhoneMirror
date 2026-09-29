#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
#
# airplay_responder_probe.py —— 模拟 iPhone 真实查询方式 dump 响应。
#
# 为什么要这个工具：airplay_selftest.py 只看"有没有应答"，但 iPhone "搜不到"
# 的根因往往是"应答里有 iOS 不认的字段"。这个工具把响应里所有字段（含 cache-flush
# 标记、SRV 端口、TXT 键值对、A 记录 IP）按 RFC 6763 风格拆开打印，能远程定位
# "iOS 拒收响应" 的具体原因。
#
# 用法：
#   python3 tools/airplay_responder_probe.py [--unicast] [--iface 192.168.0.x]
#
# 默认 multicast QU=0（iPhone 屏幕镜像初次浏览的方式）。--unicast 改单播敲门。

import argparse
import socket
import struct
import sys
import time

TYPE_NAMES = {1: "A", 12: "PTR", 16: "TXT", 33: "SRV", 28: "AAAA", 255: "ANY"}


def enc_name(name):
    out = b""
    for label in name.split("."):
        out += bytes([len(label)]) + label.encode()
    return out + b"\x00"


def parse_name(data, off):
    labels = []
    while True:
        if off >= len(data):
            return ".".join(labels), off
        n = data[off]
        if n == 0:
            off += 1
            break
        if (n & 0xC0) == 0xC0:
            ptr = ((n & 0x3F) << 8) | data[off + 1]
            sub, _ = parse_name(data, ptr)
            labels.append(sub)
            off += 2
            break
        labels.append(data[off + 1:off + 1 + n].decode(errors="replace"))
        off += 1 + n
    return ".".join(labels), off


def parse_record(data, off):
    name, off = parse_name(data, off)
    rtype, rclass, ttl, rdlen = struct.unpack(">HHIH", data[off:off + 10])
    off += 10
    rdata = data[off:off + rdlen]
    return (name, rtype, rclass, ttl, rdata), off + rdlen


def dump_records(records):
    for n, t, c, ttl, rd in records:
        tname = TYPE_NAMES.get(t, str(t))
        rc = "cache-flush" if (c & 0x8000) else "no-flush"
        if t == 1 and len(rd) == 4:
            v = ".".join(str(b) for b in rd)
            print(f"  {n:60s} {tname:4s} ttl={ttl:4d} {rc:11s} A={v}")
        elif t == 12:
            tn, _ = parse_name(rd, 0)
            print(f"  {n:60s} {tname:4s} ttl={ttl:4d} {rc:11s} PTR={tn}")
        elif t == 16:
            i = 0
            parts = []
            while i < len(rd):
                if i >= len(rd):
                    break
                l = rd[i]
                parts.append(rd[i + 1:i + 1 + l].decode(errors="replace"))
                i += 1 + l
            txt = " | ".join(parts)
            print(f"  {n:60s} {tname:4s} ttl={ttl:4d} {rc:11s} TXT={txt[:200]}")
        elif t == 33 and len(rd) >= 6:
            prio, port = struct.unpack(">HH", rd[:4])
            target, _ = parse_name(rd, 4)
            print(f"  {n:60s} {tname:4s} ttl={ttl:4d} {rc:11s} SRV={target}:{port}")
        else:
            print(f"  {n:60s} {tname:4s} ttl={ttl:4d} {rc:11s} rdata={rd[:40].hex()}")


def decode_txt_kv(rd):
    """TXT 记录是 [len][str][len][str]…，key=value 形式。返回 dict（保留重复 key 的最后一次）。"""
    parts = []
    i = 0
    while i < len(rd):
        l = rd[i]
        if l == 0 or i + 1 + l > len(rd):
            break
        parts.append(rd[i + 1:i + 1 + l].decode(errors="replace"))
        i += 1 + l
    out = {}
    for p in parts:
        if "=" in p:
            k, _, v = p.partition("=")
            out[k] = v
    return out


def highlight_airplay_txt(records, label):
    """从 responses 里挑出 TXT（或 SRV instance 后面跟的 TXT），高亮关键 AirPlay 字段并判定。"""
    txt_records = [r for r in records if r[1] == 16]
    if not txt_records:
        print(f"  ⚠️ {label}: 响应里没有任何 TXT 字段 → iPhone 不会列出设备")
        return
    for owner, _t, _c, _ttl, rd in txt_records:
        kv = decode_txt_kv(rd)
        if not kv:
            continue
        # AirPlay 关键键：model/features/pk/am/tp/vn/vs/md/vv/et/cn/ch/da/sr/ss/sv
        important = ("model", "features", "pk", "am", "tp", "vn", "vs", "md", "vv",
                     "et", "cn", "ch", "da", "sr", "ss", "sv", "sf", "fv", "ft")
        shown = {k: kv[k] for k in important if k in kv}
        shown["_owner"] = owner
        print(f"  📋 {label} TXT 关键字段（{owner}）:")
        for k, v in shown.items():
            print(f"      {k:10s} = {v}")

    # 判定 model 字段
    for owner, _t, _c, _ttl, rd in txt_records:
        kv = decode_txt_kv(rd)
        model = kv.get("model", "")
        if not model:
            continue
        if "AppleTV" in model:
            # 提取数字位（AppleTV14,1 → 14），iOS 按主版本号挑协议栈分支
            import re
            m = re.search(r"AppleTV(\d+)", model)
            ver = int(m.group(1)) if m else 99
            if ver >= 6:
                print(f"      ❌ model={model} → iOS 会走 APv2 + FairPlay 路径")
                print(f"         （我们用 RPiPlay 协议栈，不能完成 FairPlay → iPhone 收到响应但不显示设备）")
                print(f"         改 GLOBAL_MODEL 为 AppleTV2,1（推荐）或 iPhoneMirror,1（自定义）")
            else:
                print(f"      ✅ model={model} → 老 Apple TV 路径，RPiPlay 协议栈能完成")
        elif model.startswith("iPhoneMirror"):
            print(f"      ✅ model={model} → 第三方 AirPlay 接收端路径，RPiPlay 协议栈能完成")
        else:
            print(f"      ⚠️ model={model} → 自定义型号，iOS 按未知接收端处理（一般可工作）")


def query(target, iface, qtype, klass_bit, timeout=2.0, unicast=False):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except OSError:
        pass
    sock.bind(("0.0.0.0", 0))
    if iface:
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(iface))
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 4)
    sock.settimeout(0.6)
    dst = (target, 5353)
    query = enc_name("_airplay._tcp.local") + struct.pack(">HH", qtype, klass_bit)
    packet = struct.pack(">HHHHHH", 0, 0, 1, 0, 0, 0) + query
    sock.sendto(packet, dst)
    records = []
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            data, addr = sock.recvfrom(9000)
        except socket.timeout:
            continue
        if not (data[2] & 0x80):
            continue
        ancount = (data[6] << 8) | data[7]
        arcount = (data[10] << 8) | data[11]
        off = 12
        n = data[off]
        while n != 0:
            if (n & 0xC0) == 0xC0:
                off += 2
                break
            off += 1 + n
            if off >= len(data):
                break
            n = data[off]
        off += 5
        for _ in range(ancount):
            try:
                rec, off = parse_record(data, off)
                records.append(rec)
            except (IndexError, struct.error):
                break
        for _ in range(arcount):
            try:
                rec, off = parse_record(data, off)
                records.append(rec)
            except (IndexError, struct.error):
                break
        break
    sock.close()
    return records


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--unicast", action="store_true", help="改单播敲门 (QU=1)")
    ap.add_argument("--iface", default="192.168.0.110")
    args = ap.parse_args()
    iface = args.iface
    target = iface
    klass_bit = 0x8001 if args.unicast else 0x0001
    mode = "unicast QU=1" if args.unicast else "multicast QU=0"
    print(f"=== {mode} PTR _airplay._tcp.local → {target}:5353 (出向网卡 {iface}) ===")
    recs = query(target, iface if not args.unicast else None, 12, klass_bit)
    if not recs:
        print("  ✗ 0 应答")
    else:
        dump_records(recs)
        highlight_airplay_txt(recs, "_airplay._tcp.local")
    print()
    print(f"=== {mode} PTR _raop._tcp.local → {target}:5353 ===")
    sock_klass = klass_bit
    if args.unicast:
        recs = query(target, None, 12, sock_klass)
    else:
        recs = query(target, iface, 12, sock_klass)
    if not recs:
        print("  ✗ 0 应答")
    else:
        dump_records(recs)
        highlight_airplay_txt(recs, "_raop._tcp.local")


if __name__ == "__main__":
    main()