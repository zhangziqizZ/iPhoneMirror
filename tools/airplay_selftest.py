#!/usr/bin/env python3
"""iPhoneMirror 无线自检 —— 点完 App 的「应用」后立刻跑这个。

回答三个问题：
  1. 本机该用哪个 IP 广播？（排除虚拟机/虚拟网卡）
  2. 5353 上的响应器活着吗？（单播敲门，不依赖组播环回）
  3. 它宣告的 A 记录是不是就是那个 IP？（不是 = iPhone 拿到错地址）

用法：
    python3 tools/airplay_selftest.py
"""

import fcntl
import socket
import struct
import time

MCAST_PORT = 5353
SIOCGIFADDR = 0x8915
SIOCGIFFLAGS = 0x8913
SIOCGIFHWADDR = 0x8927

# 明显不是"用户网络"的接口前缀：回环、隧道、虚拟机网桥（Oseasy 的 WVMBr/WVMTap）、
# 本机 ancowlan0（172.17.1.1 内部虚拟网）。广播挑到它们 = iPhone 拿到不可达地址。
VIRTUAL_HINTS = (
    "lo", "dummy", "ip_vti", "ip6_vti", "sit", "ip6tnl", "hisilicon",
    "p2p", "chba", "nan", "wvmb", "wvmt", "ancowlan", "virbr", "veth",
    "docker", "bridge", "br-", "vmnet", "tap", "tun",
)
PREFERRED = ("wlan0", "wlan1", "eth0", "eth1", "wlan2")


def section(title):
    print("\n=== %s ===" % title)


def list_interfaces():
    out = []
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    for _idx, name in socket.if_nameindex():
        lower = name.lower()
        if any(lower.startswith(h) for h in VIRTUAL_HINTS):
            continue
        try:
            raw = fcntl.ioctl(probe.fileno(), SIOCGIFADDR,
                              struct.pack("256s", name.encode()[:15]))
            ip = socket.inet_ntoa(raw[20:24])
        except OSError:
            continue
        try:
            flags = struct.unpack(
                "H", fcntl.ioctl(probe.fileno(), SIOCGIFFLAGS,
                                 struct.pack("256s", name.encode()[:15]))[16:18])[0]
        except OSError:
            continue
        if not (flags & 0x1) or not (flags & 0x40):
            continue
        if not ip.startswith("0.") and not ip.startswith("127.") \
                and not ip.startswith("169.254."):
            out.append((name, ip))
    probe.close()
    return out


def pick_primary(entries):
    for want in PREFERRED:
        for name, ip in entries:
            if name == want:
                return name, ip
    return entries[0] if entries else (None, None)


def enc_name(name):
    out = b""
    for label in name.split("."):
        out += bytes([len(label)]) + label.encode()
    return out + b"\x00"


def dec_name(data, offset):
    labels = []
    guard = 0
    while True:
        if offset >= len(data) or guard > 40:
            break
        guard += 1
        n = data[offset]
        if n == 0:
            offset += 1
            break
        if n & 0xC0:
            offset = ((n & 0x3F) << 8) | data[offset + 1]
            continue
        labels.append(data[offset + 1:offset + 1 + n].decode("latin1"))
        offset += 1 + n
    return ".".join(labels), offset


def decode_records(data, count, offset):
    out = []
    for _ in range(count):
        name, offset = dec_name(data, offset)
        if offset + 10 > len(data):
            break
        rtype = (data[offset] << 8) | data[offset + 1]
        rdlength = (data[offset + 8] << 8) | data[offset + 9]
        offset += 10
        rdata = data[offset:offset + rdlength]
        offset += rdlength
        out.append((name, rtype, rdata))
    return out, offset


def describe(name, rtype, rdata):
    if rtype == 1:
        return "%-38s A     %s" % (name[:38], socket.inet_ntoa(rdata[:4]))
    if rtype == 12:
        return "%-38s PTR   -> %s" % (name[:38], dec_name(rdata, 0)[0])
    if rtype == 33:
        port = struct.unpack(">HHH", rdata[:6])[2]
        return "%-38s SRV   port=%d -> %s" % (name[:38], port, dec_name(rdata, 6)[0])
    if rtype == 16:
        parts = [x.decode("latin1", "replace") for x in rdata.split(b"\x03") if x]
        return "%-38s TXT   %s" % (name[:38], " ".join(parts)[:60])
    return "%-38s type=%d" % (name[:38], rtype)


def knock(target, qname, timeout=2.5):
    """向 target:5353 发一条 QU=1 的单播查询，返回应答记录列表（空 = 无应答）。

    **源地址必须钉成 127.0.0.1 —— 否则这个探测会永远返回"无应答"。**

    原因在响应器侧：OhosMdnsResponder.cpp 的收包循环里有一道自我过滤
    （`IsLocalInterfaceAddress(source_ip)` 命中就 continue），用来掐断
    "自己的宣告被组播环回回来 → 学到新地址 → 重播" 的反馈环。而
    127.0.0.1 **不在**那张网卡表里（ReadInterfaceIpv4 用 IsUsableUnicastIpv4
    排除了回环），所以只有以回环为源的查询才会被当成"别人的问题"来回答。

    之前这里 bind 的是 0.0.0.0，于是发往本机 IP 的包源地址也是本机 IP，
    被自己丢掉 → 脚本一直报"响应器没在工作"，把排查方向带偏过好几次。
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))
    sock.settimeout(0.6)
    query = enc_name(qname) + struct.pack(">HH", 12, 0x8001)
    packet = struct.pack(">HHHHHH", 0x0000, 0x0000, 1, 0, 0, 0) + query
    records = []
    try:
        sock.sendto(packet, (target, MCAST_PORT))
    except OSError:
        sock.close()
        return records
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            data, addr = sock.recvfrom(9000)
        except socket.timeout:
            continue
        if addr[0] not in (target, "127.0.0.1"):
            continue
        if not (data[2] & 0x80):
            continue
        ancount = (data[6] << 8) | data[7]
        arcount = (data[10] << 8) | data[11]
        answers, offset = decode_records(data, ancount, 12)
        additionals, _ = decode_records(data, arcount, offset)
        records = answers + additionals
        break
    sock.close()
    return records


def main():
    print("iPhoneMirror 无线自检")

    section("1) 本机该用哪个 IP 广播")
    entries = list_interfaces()
    if not entries:
        print("  ✗ 没找到任何可用的非虚拟 IPv4 网卡")
        return
    for name, ip in entries:
        print("  %-20s %s" % (name, ip))
    primary_name, primary_ip = pick_primary(entries)
    print("  → 应宣告：%s (%s)" % (primary_ip, primary_name))

    section("2) 5353 上的响应器活着吗（单播敲门）")
    alive = False
    for qname in ("_airplay._tcp.local", "_raop._tcp.local"):
        records = knock(primary_ip, qname)
        if records:
            alive = True
            print("  ✓ %s 有应答（%d 条记录）" % (qname, len(records)))
            for name, rtype, rdata in records:
                print("     " + describe(name, rtype, rdata))
        else:
            print("  ✗ %s 2.5 秒内无应答" % qname)

    section("3) 判定")
    if not alive:
        print("  响应器没在工作。按顺序排查：")
        print("   a) App 里点过「应用」吗？按钮应变成「停止」；")
        print("   b) 原生 C++ 改过之后有没有 clean rebuild？增量构建不进 .so；")
        print("   c) App 状态行若显示「本机没有可宣告的 IPv4…」，说明响应器活着")
        print("      但认为地址不可用，于是按设计**一个包都不发**。")
        return

    addresses = [socket.inet_ntoa(r[2][:4]) for r in records if r[1] == 1]
    if not addresses:
        print("  ✗ 应答里没有 A 记录 → iPhone 拿到服务却拿不到地址，会「搜到连不上」")
    elif any(a == primary_ip for a in addresses) and len(set(addresses)) == 1:
        print("  ✓ A 记录唯一且等于本机 %s —— 宣告正确" % primary_ip)
        print("    iPhone 仍搜不到的话，问题在网络拓扑或 iOS 缓存：")
        print("    · 确认 iPhone 和电脑连的是同一个 Wi-Fi（不是电脑连 iPhone 热点）；")
        print("    · iPhone 上开一次飞行模式再关，清掉 mDNS 缓存；")
        print("    · 然后跑 python3 tools/airplay_witness.py 并打开「屏幕镜像」，")
        print("      看有没有「非本机设备询问 _airplay」。")
    else:
        print("  ✗ A 记录是 %s，不等于本机 %s" % ("/".join(addresses), primary_ip))
        print("    → iPhone 会拿到错地址（或看到同一设备多个 IP 判不可信）")


if __name__ == "__main__":
    main()
