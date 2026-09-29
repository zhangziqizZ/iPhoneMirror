#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
#
# airplay_witness.py —— AirPlay 发现过程的「见证者」
#
# 为什么需要它：排查无线镜像只有一个问题值得反复问——**iPhone 到底有没有来问 AirPlay？**
# 界面上的「已应答 N 次」不可信（那 N 次可能就是本工具/别的脚本自己问的）。要判决，
# 必须把「谁在问」和「我们答了什么」两件事放在同一段时间轴上摊开。
#
# 本脚本**只听不发**（被动嗅探），所以它自己不会污染计数，可以长时间挂着：
#
#   python3 tools/airplay_witness.py              # 一直盯，直到 Ctrl+C
#   python3 tools/airplay_witness.py --seconds 90 # 盯 90 秒后自动退出
#
# 盯的时候请在 iPhone 上「控制中心 → 屏幕镜像」，然后看输出：
#   - 出现  🔍 发现 QUERY     ← iPhone 真的在问，链路通
#   - 出现  📣 本机宣告        ← 我们的 App 在答，后面会列出 A 记录 IP（必须是本机地址）
#   - 若只有本机宣告、迟迟无远程 → iPhone 没在问（网络拓扑/网段问题）
#   - 若 A 记录是 224.0.0.251   → 回到那个「拿 ipi_addr 当本机地址」的老 bug
#
# 注意：这是同一台机器上的第二双眼睛，不需要绑定 5353 的独占权（SO_REUSEPORT）。

import argparse
import collections
import datetime
import fcntl
import socket
import struct
import sys
import time

MCAST_GROUP = "224.0.0.251"
MCAST_PORT = 5353
SIOCGIFADDR = 0x8915

VIRTUAL_PREFIXES = ("lo", "dummy", "p2p", "chba", "nan", "wvmb", "wvmt",
                    "anco", "virbr", "veth", "docker", "bridge", "br-",
                    "ip_vti", "ip6_vti", "sit", "ip6tnl", "hisilicon")

WATCHED = ("_airplay", "_raop", "_companion-link", "_sleep-proxy",
           "_remotepairing", "_apple-mobdev2")

# DNS 类型码 → 可读名（只用于把"iPhone 到底问了什么类型"打印清楚，便于零重建定位）
TYPENAME = {1: "A", 2: "NS", 5: "CNAME", 12: "PTR", 16: "TXT",
            28: "AAAA", 33: "SRV", 255: "ANY", 35: "NSEC"}


def iface_ipv4(name):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        packed = struct.pack("256s", name.encode()[:15])
        result = fcntl.ioctl(sock.fileno(), SIOCGIFADDR, packed)
        return socket.inet_ntoa(result[20:24])
    except OSError:
        return None
    finally:
        sock.close()


def pick_interface():
    """挑一张"用户网络"网卡，返回 (名字, IPv4)。"""
    try:
        names = [entry[1] for entry in socket.if_nameindex()]
    except Exception:
        names = []
    preferred = ["wlan0", "wlan1", "wlan2", "eth0", "eth1"]
    for name in preferred + names:
        if name.startswith(VIRTUAL_PREFIXES):
            continue
        address = iface_ipv4(name)
        if address:
            return name, address
    return None, None


def local_addresses():
    """本机所有 IPv4，用来把"自己发的包"和"别人发的包"区分开。"""
    found = set()
    try:
        for entry in socket.if_nameindex():
            address = iface_ipv4(entry[1])
            if address:
                found.add(address)
    except Exception:
        pass
    found.add("127.0.0.1")
    return found


# ─────────────────────────── DNS 解码（够用即可） ───────────────────────────

def read_name(data, offset):
    labels = []
    jumped = False
    end = offset
    guard = 0
    while True:
        if offset >= len(data) or guard > 64:
            break
        guard += 1
        length = data[offset]
        if length == 0:
            offset += 1
            break
        if length & 0xC0:
            if not jumped:
                end = offset + 2
            jumped = True
            offset = ((length & 0x3F) << 8) | data[offset + 1]
            continue
        try:
            labels.append(data[offset + 1:offset + 1 + length].decode("utf-8", "replace"))
        except Exception:
            labels.append("?")
        offset += 1 + length
    if not jumped:
        end = offset
    return ".".join(labels), end


def parse(data):
    """返回 (is_response, [(名字, 类型)], [A 记录 IP])。签名不对返回 None。"""
    if len(data) < 12:
        return None
    is_response = bool(data[2] & 0x80)
    qd = (data[4] << 8) | data[5]
    an = (data[6] << 8) | data[7]
    ar = (data[10] << 8) | data[11]
    offset = 12
    names = []
    addresses = []
    try:
        for _ in range(qd):
            name, offset = read_name(data, offset)
            qtype = (data[offset] << 8) | data[offset + 1]
            offset += 4
            if name:
                names.append((name, qtype))
        for section_count in (an, ar):
            for _ in range(section_count):
                name, offset = read_name(data, offset)
                rtype = (data[offset] << 8) | data[offset + 1]
                rdlength = (data[offset + 8] << 8) | data[offset + 9]
                offset += 10
                rdata = data[offset:offset + rdlength]
                offset += rdlength
                if rtype == 1 and rdlength >= 4:          # A
                    addresses.append(socket.inet_ntoa(rdata[:4]))
                elif not is_response:
                    names.append((name, None))
                else:
                    names.append((name, rtype))
    except Exception:
        pass
    return is_response, names, addresses


def describe_blob(data):
    """包里出现了哪些我们关心的服务名（只做粗筛，够快）。"""
    blob = data.decode("latin-1")
    return [key for key in WATCHED if key in blob]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=float, default=0,
                        help="盯多少秒后自动退出，0 = 一直盯")
    parser.add_argument("--iface", default="", help="指定本机 IP（默认自动挑 wlan0）")
    args = parser.parse_args()

    name, address = (None, args.iface) if args.iface else pick_interface()
    if not address:
        print("✗ 找不到可用网卡 IPv4，本机没连上任何网络？")
        return 1
    print("监听网卡：%s = %s" % (name or "(指定)", address))
    print("被动监听 %s:%d（只听不发），%s\n" %
          (MCAST_GROUP, MCAST_PORT,
           "一直盯到 Ctrl+C" if args.seconds <= 0 else "盯 %.0f 秒" % args.seconds))

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except OSError:
        pass
    sock.bind(("0.0.0.0", MCAST_PORT))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                    struct.pack("4s4s", socket.inet_aton(MCAST_GROUP),
                                socket.inet_aton(address)))
    sock.settimeout(1.0)

    mine = local_addresses()
    counts = collections.Counter()
    seen_remote_query = set()
    last_announce = None
    start = time.time()

    def stamp():
        return datetime.datetime.now().strftime("%H:%M:%S")

    try:
        while True:
            if args.seconds > 0 and time.time() - start > args.seconds:
                break
            try:
                data, addr = sock.recvfrom(9000)
            except socket.timeout:
                continue
            except OSError:
                break
            source = addr[0]
            parsed = parse(data)
            if parsed is None:
                continue
            is_response, names, addresses = parsed
            hits = describe_blob(data)
            counts[source] += 1

            if not is_response and source not in mine and hits:
                # 决定性证据：别的机器在问我们关心的服务。把"问的精确名 + 类型"
                # 打出来——这是区分"iPhone 真的在解析实例（SRV/TXT）"和
                # "只是泛泛探测 _remotepairing 之类无关服务"的唯一手段。
                key = source
                if key not in seen_remote_query:
                    seen_remote_query.add(key)
                    asked = sorted(set(
                        "%s(%s)" % (n, TYPENAME.get(t, t))
                        for n, t in names
                        if any(k in n for k in hits)))
                    print("[%s] 🔍 发现 QUERY  %s 在问 %s！%s"
                          % (stamp(), source, "/".join(hits), asked[:6] or ""))
                continue

            if is_response and "_airplay" in hits and source in mine:
                # 我们的 App 在宣告。10 秒节流地报一次，带上 A 记录里的地址。
                now = time.time()
                if last_announce is None or now - last_announce > 10:
                    last_announce = now
                    bad = [ip for ip in addresses
                           if ip.startswith("224.") or ip.startswith("127.")
                           or ip == "0.0.0.0"]
                    verdict = ("⚠ A 记录异常：" + ",".join(bad)) if bad \
                        else ("A 记录=%s" % ",".join(addresses)) if addresses \
                        else "⚠ 没有 A 记录"
                    print("[%s] 📣 本机宣告  (%s)" % (stamp(), verdict))

    except KeyboardInterrupt:
        pass
    finally:
        sock.close()

    print("\n=== 汇总 ===")
    print("总包数：%d" % sum(counts.values()))
    print("按来源：")
    for ip, count in counts.most_common(8):
        tag = "（本机）" if ip in mine else ""
        print("  %-16s %6d %s" % (ip, count, tag))
    if seen_remote_query:
        print("\n✅ 有别的机器在问 AirPlay：%s" % ", ".join(sorted(seen_remote_query)))
        print("   → iPhone 那一侧是活跃的，问题在我们发出的记录内容（看上面 A 记录判定）。")
    else:
        print("\n✗ 期间没有任何非本机设备询问 _airplay。")
        print("   → 要么 iPhone 没打开「屏幕镜像」，要么它不在这个网段上广播查询")
        print("     （典型：本机连的是 iPhone 的个人热点时，iPhone 未必会在热点子网里找接收端）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
