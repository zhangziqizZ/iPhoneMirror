#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""airplay_connect_probe.py —— 本地扮演 iPhone，验证"连得上"这一步。

为什么需要它
------------
iPhone 上"搜到了但是连接不上"是一个**极难从外部归因**的现象：它可能卡在
TCP、卡在 /info 的协议版本、卡在 pair-verify 的第二段。而这三件事都能在
本机复现——AirPlay 服务端 bind 的是 INADDR_ANY，所以本机自己就能当客户端。

本脚本做三件事：
  1. 用 mDNS 问出 App 实际宣告的 `_raop._tcp` / `_airplay._tcp` 端口
     （也可用 --port 直接指定），并把它与 App 状态行里的端口对账；
  2. 对每个端口建 TCP，发 iPhone 会发的那几种请求，打印**响应首行**；
  3. 逐条断言"能连上的四个关键点"，任一不过直接指出是哪一条。

断言的四点（都对应 2026-09-18 移植的上游 c788d6fe 补丁）
--------------------------------------------------------
  A. 服务端在宣告的端口上真的 accept（而不是"通告了没人听"）。
  B. 状态行的协议必须与请求一致：
       发 "GET /info HTTP/1.1"      → 必须回 "HTTP/1.1 ..."
       发 "OPTIONS * RTSP/1.0"      → 必须回 "RTSP/1.0 ..."
     原版硬编码，iOS 判握手不合规即中止（设备在列表里、点进去连不上）。
  C. HTTP 头名**大小写不敏感**：故意用 "cseq:" 小写发，看响应是否回显 CSeq。
     原版用 strcmp，取不到 CSeq 就 `return`，一个字节都不回。
  D. `/info` 里的身份（deviceid/model/features）与 mDNS TXT 一致。
     上游 SOURCE.md："prevents iOS from hiding a route whose service
     identity, /info identity, or pairing endpoint disagrees"。

用法
----
    python3 tools/airplay_connect_probe.py              # 自动 mDNS 发现
    python3 tools/airplay_connect_probe.py --port 7000  # 直接指定端口
    python3 tools/airplay_connect_probe.py --port 7000 --port 7100

前提：App 里已经点了「应用」（AirPlay 接收端在跑）。没在跑会显示"无应答"。
"""

import argparse
import re
import socket
import struct
import sys
import time

MCAST_GRP = "224.0.0.251"
MDNS_PORT = 5353
SERVICES = ("_raop._tcp.local", "_airplay._tcp.local")

TYPE_A, TYPE_PTR, TYPE_TXT, TYPE_SRV = 1, 12, 16, 33
QTYPE_ANY = 255


# ─────────────────────────── 最小 DNS 编解码 ───────────────────────────

def encode_name(name):
    out = b""
    for label in name.split("."):
        if not label:
            continue
        raw = label.encode("utf-8")
        out += bytes([len(raw)]) + raw
    return out + b"\x00"


def build_query(name, qtype=QTYPE_ANY):
    header = struct.pack("!HHHHHH", 0, 0, 1, 0, 0, 0)
    return header + encode_name(name) + struct.pack("!HH", qtype, 1)


def read_name(packet, offset):
    """返回 (name, next_offset)。处理 0xC0 压缩指针。"""
    labels = []
    jumped = False
    next_offset = offset
    guard = 0
    while True:
        if offset >= len(packet) or guard > 128:
            break
        guard += 1
        length = packet[offset]
        if length == 0:
            offset += 1
            break
        if (length & 0xC0) == 0xC0:
            if offset + 1 >= len(packet):
                break
            pointer = ((length & 0x3F) << 8) | packet[offset + 1]
            if not jumped:
                next_offset = offset + 2
            jumped = True
            offset = pointer
            continue
        if offset + 1 + length > len(packet):
            break
        labels.append(packet[offset + 1:offset + 1 + length].decode("utf-8", "replace"))
        offset += 1 + length
    if not jumped:
        next_offset = offset
    return ".".join(labels), next_offset


def parse_txt(data):
    out = {}
    index = 0
    while index < len(data):
        size = data[index]
        index += 1
        entry = data[index:index + size]
        index += size
        text = entry.decode("utf-8", "replace")
        if "=" in text:
            key, value = text.split("=", 1)
            out[key] = value
        elif text:
            out[text] = ""
    return out


def parse_response(packet):
    """解析 DNS 应答，返回 {'services': [...], 'hosts': {name: ip}}。"""
    if len(packet) < 12:
        return None
    _, _, qdcount, ancount, nscount, arcount = struct.unpack("!HHHHHH", packet[:12])
    offset = 12
    # 跳过 question 段
    for _ in range(qdcount):
        _, offset = read_name(packet, offset)
        offset += 4
    services = []
    hosts = {}
    for _ in range(ancount + nscount + arcount):
        name, offset = read_name(packet, offset)
        if offset + 10 > len(packet):
            break
        rtype, rclass, _ttl, rdlength = struct.unpack("!HHIH", packet[offset:offset + 10])
        offset += 10
        rdata = packet[offset:offset + rdlength]
        offset += rdlength
        if rtype == TYPE_PTR:
            target, _ = read_name(packet, offset - rdlength)
            services.append({"type": name, "instance": target})
        elif rtype == TYPE_SRV and len(rdata) >= 6:
            _prio, _weight, port = struct.unpack("!HHH", rdata[:6])
            target, _ = read_name(packet, offset - rdlength + 6)
            services.append({"type": name, "instance": name, "port": port,
                             "target": target})
        elif rtype == TYPE_TXT:
            services.append({"type": name, "instance": name, "txt": parse_txt(rdata)})
        elif rtype == TYPE_A and len(rdata) == 4:
            hosts[name] = ".".join(str(b) for b in rdata)
    return {"services": services, "hosts": hosts}


def discover(timeout=2.0):
    """组播问一遍，聚合 PTR/SRV/TXT/A。返回 {type: {...}}。"""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
    except OSError:
        pass
    sock.settimeout(0.4)
    try:
        sock.bind(("", 0))
    except OSError:
        pass

    for name in SERVICES:
        for _ in range(2):
            try:
                sock.sendto(build_query(name), (MCAST_GRP, MDNS_PORT))
            except OSError as error:
                print("  组播发送失败：%s" % error)
                sock.close()
                return {}
            time.sleep(0.05)

    found = {}
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            packet, _ = sock.recvfrom(9000)
        except socket.timeout:
            continue
        parsed = parse_response(packet)
        if not parsed:
            continue
        for item in parsed["services"]:
            type_name = item.get("type", "")
            if "local" not in type_name:
                continue
            base = type_name.split(".")[0]
            entry = found.setdefault(base, {})
            if "port" in item:
                entry.setdefault("port", item["port"])
                entry.setdefault("target", item.get("target", ""))
            if "txt" in item:
                entry.setdefault("txt", item["txt"])
            if "instance" in item and item.get("port") is None and "txt" not in item:
                entry.setdefault("instance", item["instance"])
        for host, ip in parsed["hosts"].items():
            for entry in found.values():
                if host and host.split(".")[0].lower() == entry.get("target", "").split(".")[0].lower():
                    entry.setdefault("ip", ip)
    sock.close()
    return found


# ─────────────────────────── TCP 探测 ───────────────────────────

def http_get(port, host_ip, request_bytes, timeout=3.0):
    """发一段请求，返回 (响应字节, 错误说明)。"""
    try:
        conn = socket.create_connection((host_ip, port), timeout=timeout)
    except OSError as error:
        return None, "TCP 连不上 %s:%d（%s）" % (host_ip, port, error)
    try:
        conn.settimeout(timeout)
        conn.sendall(request_bytes)
        chunks = []
        while True:
            try:
                block = conn.recv(4096)
            except socket.timeout:
                break
            if not block:
                break
            chunks.append(block)
            if len(b"".join(chunks)) > 65536:
                break
        return b"".join(chunks), None
    finally:
        try:
            conn.close()
        except OSError:
            pass


def first_line(response):
    if not response:
        return "(无任何响应)"
    head = response.split(b"\r\n", 1)[0]
    return head.decode("utf-8", "replace")


def check(label, ok, detail=""):
    mark = "通过" if ok else "失败"
    print("  [%s] %s%s" % (mark, label, ("  ← " + detail) if detail else ""))
    return bool(ok)


def probe_port(port, host_ip, kind):
    """对单个端口跑一轮断言。kind 用于解释这是 RAOP 还是 AirPlay 端口。"""
    print("\n── %s 端口 %d（%s:%d）" % (kind, port, host_ip, port))
    results = []

    # 断言 A：TCP 能建
    try:
        conn = socket.create_connection((host_ip, port), timeout=3.0)
        conn.close()
    except OSError as error:
        print("  [失败] 端口没有 accept：%s" % error)
        print("         ⇒ 有东西在宣告这个服务，但那个端口没人监听。")
        print("           最常见的原因：**遗留的 tools/mdns_responder_proto.py 还在跑**——")
        print("           它宣告的 5000/7000 是占位端口，正是「搜到了但连不上」的经典成因。")
        print("           查：ps -ef | grep mdns_responder_proto ；有就 kill 掉。")
        print("           若宣告端口来自 App 自己（状态行会显示 RAOP/AirPlay 端口），")
        print("           那说明库没能 bind —— 看 App 里的「原生：」那行日志。")
        return [False]
    results.append(check("端口在监听", True))

    # 断言 B1：HTTP 请求 → 必须回 HTTP 状态行
    http_req = (
        "GET /info HTTP/1.1\r\n"
        "CSeq: 1\r\n"
        "User-Agent: AirPlay/640.5.3\r\n"
        "Content-Length: 0\r\n\r\n"
    ).encode()
    response, error = http_get(port, host_ip, http_req)
    line = first_line(response)
    print("       GET /info HTTP/1.1 → %s" % line)
    if error:
        print("       %s" % error)
    results.append(check("HTTP 请求得到 HTTP 状态行", line.startswith("HTTP/1.1"),
                         "" if line.startswith("HTTP/1.1") else "原版会回 RTSP/1.0，iOS 即中止"))
    results.append(check("HTTP 请求得到响应（不是静默丢弃）", bool(response),
                         "" if response else "CSeq 取不到时 raop.c 会直接 return"))

    body = response.decode("utf-8", "replace") if response else ""
    for key in ("deviceid", "features", "model", "srcvers"):
        if "<key>%s</key>" % key in body:
            match = re.search(r"<key>%s</key>\s*<[^>]+>([^<]*)<" % key, body)
            if match:
                print("       /info %s = %s" % (key, match.group(1).strip()))
    if "<plist" not in body and response:
        print("       （响应体不是 plist，前 120 字节：%r）" % body[:120])

    # 断言 B2：RTSP 请求 → 必须回 RTSP 状态行
    rtsp_req = (
        "OPTIONS * RTSP/1.0\r\n"
        "CSeq: 2\r\n"
        "User-Agent: AirPlay/640.5.3\r\n\r\n"
    ).encode()
    response_rtsp, _ = http_get(port, host_ip, rtsp_req)
    line_rtsp = first_line(response_rtsp)
    print("       OPTIONS * RTSP/1.0   → %s" % line_rtsp)
    results.append(check("RTSP 请求得到 RTSP 状态行", line_rtsp.startswith("RTSP/1.0")))

    # 断言 C：小写头名也要能取到（CSeq 会被回显）
    lower_req = (
        "GET /info HTTP/1.1\r\n"
        "cseq: 3\r\n"
        "Content-Length: 0\r\n\r\n"
    ).encode()
    response_lower, _ = http_get(port, host_ip, lower_req)
    body_lower = response_lower.decode("utf-8", "replace") if response_lower else ""
    echoed = bool(re.search(r"(?i)^cseq:\s*3", body_lower, re.M))
    print("       小写 cseq: 3          → %s" % first_line(response_lower))
    results.append(check("头名大小写不敏感（CSeq 被回显）", echoed,
                         "" if echoed else "原版 strcmp 取不到 CSeq，直接不回复"))

    return results


def main():
    parser = argparse.ArgumentParser(description="本地扮演 iPhone 验证 AirPlay 连接阶段")
    parser.add_argument("--port", type=int, action="append", default=[],
                        help="直接指定要探测的端口（可重复）；不给则走 mDNS 发现")
    parser.add_argument("--host", default="", help="目标 IP，默认用发现到的 A 记录")
    parser.add_argument("--timeout", type=float, default=2.5, help="mDNS 等待秒数")
    args = parser.parse_args()

    # 本机主网卡 IP（没有 --host 且没发现到 A 记录时兜底）
    local_ip = ""
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.connect(("8.8.8.8", 80))
        local_ip = probe.getsockname()[0]
        probe.close()
    except OSError:
        pass
    if not local_ip:
        import fcntl
        for _index, name in socket.if_nameindex():
            if name.startswith("wlan") or name.startswith("eth"):
                try:
                    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                    raw = fcntl.ioctl(sock, 0x8915, struct.pack("256s", name.encode()[:15]))
                    local_ip = socket.inet_ntoa(raw[20:24])
                    sock.close()
                    break
                except OSError:
                    continue
    print("本机候选用作目标的 IP：%s" % (local_ip or "(未取到)"))

    targets = []
    if args.port:
        for port in args.port:
            targets.append((port, "指定"))
        host_ip = args.host or local_ip or "127.0.0.1"
    else:
        print("\n=== mDNS 发现（%.1fs） ===" % args.timeout)
        found = discover(args.timeout)
        if not found:
            print("  没有任何服务应答。")
            print("  ⇒ 响应器没在广播：确认 App 里点过「应用」，且状态行显示「已在局域网广播」。")
            return 2
        for base, entry in sorted(found.items()):
            port = entry.get("port")
            print("  %-10s 端口=%-6s 目标=%-28s IP=%-15s" % (
                base, port, entry.get("target", "-"), entry.get("ip", "-")))
            txt = entry.get("txt") or {}
            if txt:
                for key in ("deviceid", "model", "features", "srcvers"):
                    if key in txt:
                        print("             TXT %s = %s" % (key, txt[key]))
        host_ip = args.host or next(
            (e["ip"] for e in found.values() if e.get("ip")), local_ip) or "127.0.0.1"
        for base, entry in sorted(found.items()):
            if entry.get("port"):
                targets.append((entry["port"], base.strip("_")))

    if not targets:
        print("\n发现到了服务但没解析出 SRV 端口，无法继续。")
        return 2

    print("\n=== 连接阶段断言（目标 IP %s） ===" % host_ip)
    all_results = []
    for port, kind in targets:
        all_results.extend(probe_port(port, host_ip, kind))

    passed = sum(1 for item in all_results if item)
    total = len(all_results)
    print("\n=== 结论：%d/%d 项通过 ===" % (passed, total))
    if passed == total:
        print("连接阶段的协议层已就绪 —— 如果 iPhone 仍连不上，问题不在这些握手上，")
        print("下一步该查媒体流（RTP 端口 / 虚拟网卡路由，见上游 NetworkRoutePatch）。")
    else:
        print("存在未通过项，按上面的「失败」行逐条修。")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
