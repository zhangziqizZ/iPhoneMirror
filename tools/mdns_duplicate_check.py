#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
#
# mdns_duplicate_check.py —— 抓出"同一个 AirPlay 实例名被多个响应器宣告"这件事
# 以及 dump "App 实际在 wire 上发的 TXT/SRV/A" 做零重建校验。
#
# 为什么需要它：
#   iPhone 的「屏幕镜像」列表是拿 `_airplay._tcp.local` 的 PTR 建的。如果网上
#   （**尤其是本机**）有第二个响应器用**同一个实例名**、却给出**不同的 SRV
#   目标名/端口**，mDNS 会把两份记录判成冲突，iPhone 于是干脆不显示这台设备 ——
#   而 App 界面上一切正常："注册成功、宣告成功、已应答 N 次"。
#
#   2026-09-18 就踩过一次：诊断脚本 mdns_responder_proto.py 被留在后台，与 App
#   抢同一个 "iPhoneMirror AirPlay"。当时的症状是"搜得到、点进去连不上"，因为
#   iPhone 采纳的是原型那个指向死端口 7000/5000 的 SRV。
#
# 另一个核心用途（**不重建也能验证**）：
#   跑这个脚本、同时让 App 在旁边宣告，**所有 4 段都会被打出来**——
#   PTR / SRV / TXT / A。这样你就能在不动 HAP 的前提下，逐项核对：
#     - TXT `model` 字段是不是 "AppleTV2,1"（09-19 修复后）
#     - TXT `deviceid` 是不是真实 MAC
#     - TXT `features` 是不是 0x5A7FFEE6,0x0
#     - SRV 端口是不是 35523（AirPlay）/ 33441（RAOP）等真实值
#     - A 记录是不是 192.168.0.111（你的真实本机 IP，不是某次 DHCP 漂出去的）
#   这些是 iPhone「屏幕镜像」列表**最终决定要不要列**你的根证据。
#
# 本脚本主动发两轮查询（一轮要组播应答、一轮要单播应答），把局域网里**所有**
# 回答 `_airplay._tcp.local` / `_raop._tcp.local` 的响应器打印出来，并按实例名
# 归组。**同一个实例名出现两组不同的 (目标主机, 端口) 就是冲突**，脚本会报警。
#
# 用法：
#   python3 tools/mdns_duplicate_check.py            # 默认听 8 秒
#   python3 tools/mdns_duplicate_check.py --seconds 12
#   # 想看 App 在 wire 上的完整 TXT：让 App 在跑、立刻跑这个脚本。
#
# 注意：
#   * 本脚本只发查询、只读应答，**不会**宣告任何服务；可以随时运行。
#   * 它自己发送的查询来源是本机地址；App 的响应器会把"来源=本机"的包丢弃
#     （防自反馈环的必需措施），所以**不要**期望它会出现在 App 的"已应答"计数里。
#   * 若防火墙/AP 屏蔽了组播，可能一个应答都收不到；那时改用 --unicast-target
#     指定要单播敲的地址（例如 App 所在机器的 192.168.0.111）。
#   * 本机没在跑 App 时，脚本只会列网上的其他设备（iPhone 自己的 _apple-mobdev2、
#     打印机、HomePod 之类）。这是正常现象，不是 bug。

import argparse
import fcntl
import socket
import struct
import sys
import time

MCAST_GROUP = "224.0.0.251"
MCAST_PORT = 5353
SIOCGIFADDR = 0x8915

WATCHED_TYPES = ("_airplay._tcp.local", "_raop._tcp.local")


def local_ipv4() -> str:
    """拿第一张真实网卡的 IPv4（不依赖 /sys，本机读不到）。"""
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        for want in ("wlan0", "wlan1", "eth0", "eth1"):
            try:
                raw = fcntl.ioctl(probe.fileno(), SIOCGIFADDR,
                                  struct.pack("256s", want.encode()[:15]))
            except OSError:
                continue
            ip = socket.inet_ntoa(raw[20:24])
            if ip and not ip.startswith("127."):
                return ip
    finally:
        probe.close()
    return ""


def enc_name(name: str) -> bytes:
    out = b""
    for label in name.split("."):
        if label == "":
            continue
        raw = label.encode("utf-8")
        out += bytes([len(raw)]) + raw
    return out + b"\x00"


def dec_name(data: bytes, off: int, depth: int = 0):
    """解一个（可能带压缩指针的）域名，返回 (名字, 下一字节偏移)。"""
    labels = []
    i = off
    jumped = False
    while depth < 16:
        if i >= len(data):
            break
        length = data[i]
        if length == 0:
            i += 1
            break
        if length & 0xC0 == 0xC0:
            if i + 1 >= len(data):
                break
            pointer = ((length & 0x3F) << 8) | data[i + 1]
            if not jumped:
                off = i + 2
                jumped = True
            sub, _ = dec_name(data, pointer, depth + 1)
            if sub:
                labels.append(sub)
            i = off
            break
        labels.append(data[i + 1:i + 1 + length].decode("utf-8", "replace"))
        i += 1 + length
    return ".".join(labels), (off if jumped else i)


def read_records(data: bytes, offset: int, count: int):
    """解 count 条资源记录，返回 (记录列表, 结束偏移)。"""
    records = []
    for _ in range(count):
        if offset >= len(data):
            break
        name, offset = dec_name(data, offset)
        if offset + 10 > len(data):
            break
        rtype, rclass, ttl, rdlength = struct.unpack(">HHIH", data[offset:offset + 10])
        offset += 10
        rdata_off = offset
        rdata = data[offset:offset + rdlength]
        offset += rdlength
        # rdata_off 必须留着：PTR/SRV 的 rdata 里也含域名，而别的实现可能在里面
        # 放压缩指针 —— 那种指针的基准是**整个报文**，只拿 rdata 解会解错。
        records.append((name, rtype, rclass, ttl, rdata, rdata_off))
    return records, offset


def parse_message(data: bytes):
    """返回 (qname, qtype, records)。

    records 把 **answer 段和 additional 段合并**返回 —— 这一点至关重要：
    绝大多数实现（实测 EPSON 打印机、iPhone 都是这样）把 SRV/TXT/A 放在
    additional 段，PTR 放在 answer 段。只看 answer 段会得出"没有 SRV"的错误结论。
    """
    if len(data) < 12:
        return None
    qd, ancount, nscount, arcount = struct.unpack(">HHHH", data[4:12])
    offset = 12
    qname, qtype = "", 0
    for _ in range(qd):
        qname, offset = dec_name(data, offset)
        if offset + 4 > len(data):
            return None
        qtype, _qclass = struct.unpack(">HH", data[offset:offset + 4])
        offset += 4
    answers, offset = read_records(data, offset, ancount)
    _authority, offset = read_records(data, offset, nscount)
    additionals, _ = read_records(data, offset, arcount)
    return qname, qtype, answers + additionals


def build_query(qname: str, qtype: int, unicast: bool) -> bytes:
    """unicast=True 时置 QU 位（要求单播应答）。"""
    klass = 0x0001 | (0x8000 if unicast else 0)
    header = struct.pack(">HHHHHH", 0, 0, 1, 0, 0, 0)
    return header + enc_name(qname) + struct.pack(">HH", qtype, klass)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=float, default=8.0,
                        help="总共监听多少秒")
    parser.add_argument("--unicast-target", default="",
                        help="额外把查询单播敲到这个 ip:port（默认 本机IP:5353）")
    args = parser.parse_args()

    mine = local_ipv4()
    print("[dup-check] 本机 IPv4 = %s" % (mine or "未知"))
    print("[dup-check] 目标服务 = %s" % ", ".join(WATCHED_TYPES))

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except OSError:
        pass
    sock.bind(("0.0.0.0", MCAST_PORT))
    for iface in ("0.0.0.0", mine):
        if not iface:
            continue
        try:
            mreq = struct.pack("4s4s", socket.inet_aton(MCAST_GROUP),
                               socket.inet_aton(iface))
            sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
        except OSError:
            pass
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 4)
    sock.settimeout(0.4)

    # 发两轮：一轮 QM（要组播应答），一轮 QU（要单播应答）。覆盖两种实现。
    sent = 0
    for unicast in (False, True):
        for qname in WATCHED_TYPES:
            for rtype in (12, 33, 16):
                try:
                    sock.sendto(build_query(qname, rtype, unicast),
                                (MCAST_GROUP, MCAST_PORT))
                    sent += 1
                except OSError as exc:
                    print("[dup-check] 发送失败: %s" % exc)
    target = args.unicast_target or (mine + ":5353" if mine else "")
    if target:
        host, _, port = target.partition(":")
        for qname in WATCHED_TYPES:
            try:
                sock.sendto(build_query(qname, 12, True),
                            (host, int(port or MCAST_PORT)))
                sent += 1
            except OSError:
                pass
    print("[dup-check] 已发出 %d 条查询，开始监听 %.1f 秒…\n" % (sent, args.seconds))

    # 实例名 -> {(目标主机, 端口, 来源IP)}，用于找冲突
    srv_seen = {}
    ptr_seen = {}
    txt_seen = {}
    responders = set()
    deadline = time.time() + args.seconds
    while time.time() < deadline:
        try:
            data, addr = sock.recvfrom(9000)
        except socket.timeout:
            continue
        except OSError:
            break
        if len(data) < 12:
            continue
        if (struct.unpack(">H", data[2:4])[0] & 0x8000) == 0:
            continue                       # 查询，不是应答
        parsed = parse_message(data)
        if parsed is None:
            continue
        _qname, _qtype, answers = parsed
        for name, rtype, _rclass, _ttl, rdata, rdata_off in answers:
            low = name.lower()
            if rtype == 12 and low.endswith((".local", ".local.")):
                instance, _ = dec_name(data, rdata_off)
                if instance:
                    ptr_seen.setdefault(low.rstrip("."), set()).add(
                        (instance, addr[0]))
                    responders.add(addr[0])
            elif rtype == 33:
                # priority(2) weight(2) port(2) target(name)
                if len(rdata) >= 6:
                    port = struct.unpack(">H", rdata[4:6])[0]
                    target_name, _ = dec_name(data, rdata_off + 6)
                    srv_seen.setdefault(name, set()).add(
                        (target_name, port, addr[0]))
                    responders.add(addr[0])
            elif rtype == 16:
                entries = []
                i = 0
                while i < len(rdata):
                    size = rdata[i]
                    if size == 0 or i + 1 + size > len(rdata):
                        break
                    entries.append(rdata[i + 1:i + 1 + size].decode("utf-8", "replace"))
                    i += 1 + size
                txt_seen[name] = entries
                responders.add(addr[0])

    print("[dup-check] 收到应答的来源 IP：%s"
          % (", ".join(sorted(responders)) if responders else "（无）"))
    if mine and mine in responders:
        print("[dup-check]   注意：%s 就是**本机**。本机出现应答，说明有响应器"
              "在本机运行。" % mine)

    print("\n[dup-check] PTR（谁在宣告这些服务类型）：")
    if not ptr_seen:
        print("    （没收到任何 PTR 应答）")
    for service, entries in sorted(ptr_seen.items()):
        for instance, src in sorted(entries):
            print("    %-24s -> %-52s 来自 %s" % (service, instance, src))

    print("\n[dup-check] SRV（实例名 -> 目标主机:端口）—— 冲突就看这里：")
    conflict = False
    if not srv_seen:
        print("    （没收到任何 SRV 应答）")
    for instance, entries in sorted(srv_seen.items()):
        distinct = {(target, port) for target, port, _src in entries}
        flag = ""
        if len(distinct) > 1:
            flag = "   <<< ⚠ 同一个实例名被给出了多组不同的目标/端口 = 记录冲突"
            conflict = True
        print("    %s%s" % (instance, flag))
        for target, port, src in sorted(entries):
            print("        -> %s:%d 来自 %s" % (target, port, src))

    print("\n[dup-check] TXT（每实例最后一组）：")
    for instance, entries in sorted(txt_seen.items()):
        print("    %s" % instance)
        for entry in entries:
            print("        %s" % entry)

    print()
    if conflict:
        print("[dup-check] 结论：**检测到冲突**。同一个实例名有多组 SRV —— "
              "把多余的响应器停掉（含本机残留的 mdns_responder_proto.py / "
              "第二个 App 实例）再试。")
        return 2
    if not srv_seen:
        print("[dup-check] 结论：没有任何响应器回答 `_airplay/_raop`。"
              "要么 App 没在跑，要么应答根本发不出来。" if not responders
              else "[dup-check] 结论：有主机在应答，但没有 `_airplay/_raop` 的 SRV。")
        return 1
    print("[dup-check] 结论：本实例名在网上的 SRV 只有一组，没有冲突。")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\n[dup-check] 已中断")
        sys.exit(130)
