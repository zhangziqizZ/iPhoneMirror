#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
#
# mdns_query.py —— 「App 到底向局域网宣告了什么」的解码取证工具
#
# 为什么需要它：iPhone「屏幕镜像」搜不到 / 搜到连不上，只有两种可能——要么记录
# 没发出去，要么记录发出去了但内容不对（最典型：A 记录里的 IP 不是本机可路由的
# 单播地址）。看 App 界面只能看到"已广播/已应答 N 次"，看不到**记录内容本身**。
# 这个脚本就是把记录内容摊开：它不是抓包器（沙箱里未必能开混杂模式），而是以
# 一个普通 mDNS 客户端的身份去问 App，再把 App 的应答逐条解码打印。
#
# 用法（在设备上跑）：
#   python3 tools/mdns_query.py
#
# 会做两轮查询：
#   ① 组播查询（iPhone 平时用的方式）：发到 224.0.0.251:5353；
#   ② 单播查询（legacy unicast query）：直接发到 <本机IP>:5353。
# 两轮都用临时端口 + 关掉 IP_MULTICAST_LOOP，所以只会看到 App 的应答，
# 不会看到自己发出去的查询（那是上一版脚本误判"有人在应答"的原因）。
#
# 期望结果（修好后）：
#   _airplay._tcp.local → PTR=<实例名>，SRV=<主机名>:<端口>，TXT=srcvers/deviceid/…
#                         A=<本机 wlan0 的 IPv4>
#   其中 A 记录必须等于本机 wlan0 地址。如果看到 224.0.0.251，说明又回到了
#   "拿 ipi_addr 当本机地址"那个 bug。

import fcntl
import socket
import struct
import sys
import time

MCAST_GROUP = "224.0.0.251"
MCAST_PORT = 5353
SIOCGIFADDR = 0x8915

TYPE_NAMES = {
    1: "A", 2: "NS", 5: "CNAME", 6: "SOA", 12: "PTR", 15: "MX",
    16: "TXT", 28: "AAAA", 33: "SRV", 47: "NSEC", 255: "ANY",
}


# ─────────────────────────── 本机地址 ───────────────────────────

def iface_ipv4(name: str):
    """用 SIOCGIFADDR 取某张网卡的 IPv4；读不到返回 None。"""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        packed = struct.pack("256s", name.encode()[:15])
        result = fcntl.ioctl(sock.fileno(), SIOCGIFADDR, packed)
        return socket.inet_ntoa(result[20:24])
    except OSError:
        return None
    finally:
        sock.close()


def local_ipv4():
    """挑一张"用户网络"网卡：优先 wlan0/wlan1/eth0，否则第一张有 IP 的非 lo 网卡。"""
    try:
        names = [n[1] for n in socket.if_nameindex()]
    except Exception:
        names = []
    preferred = ["wlan0", "wlan1", "wlan2", "eth0", "eth1"]
    for name in preferred + names:
        if name.startswith(("lo", "p2p", "chba", "nan", "wvmb", "wvmt",
                            "anco", "virbr", "veth", "docker", "bridge")):
            continue
        address = iface_ipv4(name)
        if address:
            return name, address
    return None, None


# ─────────────────────────── DNS 编解码 ───────────────────────────

def enc_name(name: str) -> bytes:
    out = b""
    for label in name.split("."):
        if label == "":
            continue
        raw = label.encode("utf-8")
        out += bytes([len(raw)]) + raw
    return out + b"\x00"


def dec_name(data: bytes, offset: int):
    """解码域名，返回 (名字, 紧跟其后的偏移)。支持压缩指针。"""
    labels = []
    position = offset
    jumped = False
    guard = 0
    while True:
        if position >= len(data) or guard > 128:
            break
        guard += 1
        length = data[position]
        if length == 0:
            position += 1
            break
        if length & 0xC0 == 0xC0:
            target = ((length & 0x3F) << 8) | data[position + 1]
            if not jumped:
                offset = position + 2
            jumped = True
            position = target
            continue
        labels.append(data[position + 1:position + 1 + length].decode("utf-8", "replace"))
        position += 1 + length
    if not jumped:
        offset = position
    return ".".join(labels), offset


def dec_txt(rdata: bytes):
    pairs = []
    position = 0
    while position < len(rdata):
        length = rdata[position]
        position += 1
        entry = rdata[position:position + length].decode("utf-8", "replace")
        position += length
        pairs.append(entry)
    return pairs


def parse_message(data: bytes):
    """解析一条 DNS 消息，返回 (flags, questions, answers, additionals)。"""
    if len(data) < 12:
        return None
    ident, flags, qd, an, ns, ar = struct.unpack(">HHHHHH", data[:12])
    offset = 12

    questions = []
    for _ in range(qd):
        name, offset = dec_name(data, offset)
        qtype, qclass = struct.unpack(">HH", data[offset:offset + 4])
        offset += 4
        questions.append((name, qtype, qclass))

    def read_records(count, offset):
        records = []
        for _ in range(count):
            name, offset = dec_name(data, offset)
            rtype, rclass, ttl, rdlength = struct.unpack(">HHIH", data[offset:offset + 10])
            offset += 10
            rdata_offset = offset          # 记下位置：压缩指针要相对整条消息解析
            rdata = data[offset:offset + rdlength]
            offset += rdlength
            records.append({
                "name": name, "type": rtype, "class": rclass & 0x7FFF,
                "flush": bool(rclass & 0x8000), "ttl": ttl, "rdata": rdata,
                "rdata_offset": rdata_offset,
            })
        return records, offset

    answers, offset = read_records(an, offset)
    authority, offset = read_records(ns, offset)
    additionals, offset = read_records(ar, offset)
    return {
        "flags": flags, "questions": questions, "answers": answers,
        "authority": authority, "additionals": additionals,
    }


def describe(record, whole: bytes):
    rtype = record["type"]
    rdata = record["rdata"]
    offset = record["rdata_offset"]
    if rtype == 12:      # PTR
        target, _ = dec_name(whole, offset)
        return target
    if rtype == 33:      # SRV
        priority, weight, port = struct.unpack(">HHH", rdata[:6])
        # 目标名必须在**整条消息**里解析：mDNS 常用压缩指针指回别处，
        # 只看 rdata 那几十个字节会把指针解析错。
        target, _ = dec_name(whole, offset + 6)
        return "port=%d target=%s (prio=%d weight=%d)" % (port, target, priority, weight)
    if rtype == 16:      # TXT
        return " ".join(dec_txt(rdata))
    if rtype == 1:       # A
        return socket.inet_ntoa(rdata[:4])
    if rtype == 28:      # AAAA
        return socket.inet_ntop(socket.AF_INET6, rdata[:16])
    return rdata.hex()


def type_label(rtype: int) -> str:
    return TYPE_NAMES.get(rtype, str(rtype))


# ─────────────────────────── 查询 ───────────────────────────

def query_round(title, destination, bind_ip, expected_ip, timeout=3.0):
    print("\n=== %s ===" % title)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        # 关环回：否则会收到自己发出的查询，误判成"有人在应答"。
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 0)
    except OSError:
        pass
    try:
        if bind_ip:
            sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF,
                            socket.inet_aton(bind_ip))
    except OSError:
        pass
    sock.bind(("0.0.0.0", 0))     # 临时端口：走 legacy unicast query 语义，App 会单播回我们
    sock.settimeout(0.5)

    asked = ["_airplay._tcp.local", "_raop._tcp.local", "_services._dns-sd._udp.local"]
    for qname in asked:
        packet = struct.pack(">HHHHHH", 0, 0, 1, 0, 0, 0) + enc_name(qname) + struct.pack(">HH", 12, 1)
        try:
            sock.sendto(packet, destination)
        except OSError as exc:
            print("  发送失败（%s）：%s" % (qname, exc))
    print("  已发查询：%s → %s:%d" % (", ".join(asked), destination[0], destination[1]))

    found = []          # 每条应答：(来源, 解析结果)
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            data, addr = sock.recvfrom(9000)
        except socket.timeout:
            continue
        except OSError:
            break
        parsed = parse_message(data)
        if parsed is None:
            continue
        if not (parsed["flags"] & 0x8000):
            continue                       # 别人的查询，不是应答
        found.append((addr, parsed, data))
    sock.close()

    if not found:
        print("  ✗ %.1f 秒内没有任何应答 → App 没在广播（响应器未启动 / 绑定失败 / 多播发不出去）" % timeout)
        return None

    advertised_ip = None
    advertised_port = None
    print("  收到 %d 条应答：" % len(found))
    for addr, parsed, raw in found:
        print("  ── 来自 %s:%d（%d 字节）" % (addr[0], addr[1], len(raw)))
        for section in ("answers", "additionals"):
            for record in parsed[section]:
                tag = "answer" if section == "answers" else "additional"
                flush = " [cache-flush]" if record["flush"] else ""
                print("     [%s] %s %s ttl=%d%s\n            %s"
                      % (tag, record["name"], type_label(record["type"]),
                         record["ttl"], flush, describe(record, raw)))
                if record["type"] == 1:
                    advertised_ip = socket.inet_ntoa(record["rdata"][:4])
                if record["type"] == 33:
                    advertised_port = struct.unpack(">HHH", record["rdata"][:6])[2]
        for question in parsed["questions"]:
            print("     [question] %s %s" % (question[0], type_label(question[1])))

    print("\n  ── 判定 ──")
    if advertised_ip is None:
        print("  ✗ 应答里没有 A 记录 → iPhone 拿不到地址，会搜到却连不上（或干脆不显示）")
    else:
        first = int(advertised_ip.split(".")[0])
        if advertised_ip == expected_ip:
            print("  ✓ A 记录 = %s，正是本机地址，正确。" % advertised_ip)
        elif first == 224 or advertised_ip.startswith("127.") or advertised_ip == "0.0.0.0":
            print("  ✗ A 记录 = %s 是**非法主机地址**（组播/回环）→ 这就是"
                  "\"搜到连不上 / 搜不到\"的根因：必须是本机单播 IPv4。" % advertised_ip)
        else:
            print("  ⚠ A 记录 = %s，不是本机地址（本机 %s）→ iPhone 会连到别的机器"
                  % (advertised_ip, expected_ip))
    if advertised_port:
        print("  ℹ SRV 端口 = %d（应与 App 界面显示的 RAOP/AirPlay 端口一致）" % advertised_port)
    return advertised_ip


def main():
    name, ip = local_ipv4()
    print("本机网卡：%s = %s" % (name, ip))
    if ip is None:
        print("✗ 找不到任何可用网卡 IPv4 —— 本机没连上 Wi-Fi？")
        return 1

    query_round("① 组播查询（iPhone 平时的方式）",
                (MCAST_GROUP, MCAST_PORT), ip, ip)
    query_round("② 单播查询（直接问到 %s:5353）" % ip,
                (ip, MCAST_PORT), ip, ip, timeout=2.0)

    print("\n提示：两轮都应有应答。①没应答②有应答 → 组播出不去（防火墙/IGMP），"
          "iPhone 也会搜不到，需要查网络侧。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
