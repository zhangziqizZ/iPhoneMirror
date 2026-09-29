#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
#
# check_mdns_state.py —— "iPhone 搜不到设备" 现场诊断
#
# 在设备上运行：python3 tools/check_mdns_state.py
# 它会查清四件事，把输出发给我即可定位：
#   1) UDP/5353 是否被别的进程占用（最常见：上次的 Python 原型没关）；
#   2) 上次的 Python 原型 mdns_responder_proto.py 是否还在跑；
#   3) 以 App 同样的方式（SO_REUSEADDR + SO_REUSEPORT，绑 INADDR_ANY:5353，
#      加组播 224.0.0.251）能否成功绑定——不成功就说明端口被占或权限受限；
#   4) 主动发一条 _airplay._tcp / _raop._tcp 的 PTR 查询，看局域网里有没有
#      任何活着的 AirPlay mDNS 响应器应答（App 若正常广播，这里应能收到）。

import fcntl
import socket
import struct
import subprocess
import time

MCAST_GROUP = "224.0.0.251"
MCAST_PORT = 5353
PORT_HEX = "%X" % MCAST_PORT  # 14E9

SIOCGIFADDR = 0x8915
SIOCGIFFLAGS = 0x8913
SIOCGIFHWADDR = 0x8927
IFF_UP, IFF_RUNNING, IFF_LOOPBACK = 0x1, 0x40, 0x8

# 与 OhosMdnsResponder.cpp 的 LooksVirtualInterface() 保持同一份前缀表：
# 这些接口即使在、也大概率不是"用户网络"，不应被当成 A 记录里的地址。
VIRTUAL_PREFIXES = ("lo", "dummy", "ip_vti", "ip6_vti", "sit", "ip6tnl",
                    "hisilicon", "p2p", "chba", "nan", "wvmb", "wvmt",
                    "ancowlan", "virbr", "veth", "docker", "bridge", "br-")
CANDIDATE_IFACES = ["wlan0", "wlan1", "wlan2", "eth0", "eth1", "lo"]


def section(title):
    print("\n=== " + title + " ===")


def iface_ipv4(name):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        packed = fcntl.ioctl(sock.fileno(), SIOCGIFADDR,
                             struct.pack("256s", name.encode()[:15]))
        return socket.inet_ntoa(packed[20:24])
    except OSError:
        return None
    finally:
        sock.close()


def iface_flags(name):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        packed = fcntl.ioctl(sock.fileno(), SIOCGIFFLAGS,
                             struct.pack("256s", name.encode()[:15]))
        return struct.unpack_from("h", packed, 16)[0]
    except OSError:
        return None
    finally:
        sock.close()


def iface_mac(name):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        packed = fcntl.ioctl(sock.fileno(), SIOCGIFHWADDR,
                             struct.pack("256s", name.encode()[:15]))
        raw = packed[18:24]
        return ":".join("%02X" % byte for byte in raw)
    except OSError:
        return None
    finally:
        sock.close()


def list_ifaces():
    """列出每张网卡的 IPv4 / 状态 / MAC。App 会从中挑一张写进 A 记录。"""
    seen = set()
    rows = []
    try:
        names = [entry[1] for entry in socket.if_nameindex()]
    except Exception:
        names = []
    for name in CANDIDATE_IFACES + names:
        if name in seen:
            continue
        seen.add(name)
        address = iface_ipv4(name)
        if address is None:
            continue
        flags = iface_flags(name) or 0
        state = []
        if flags & IFF_UP:
            state.append("UP")
        if flags & IFF_RUNNING:
            state.append("RUNNING")
        if flags & IFF_LOOPBACK:
            state.append("LOOPBACK")
        rows.append({
            "name": name, "ip": address, "state": ",".join(state) or "-",
            "mac": iface_mac(name) or "-",
            "virtual": name.lower().startswith(VIRTUAL_PREFIXES),
        })
    return rows


def check_port_occupied():
    """返回 (状态, 内容)。状态 "unreadable" 表示沙箱里读不到 /proc/net/udp ——
    那是**读不到**，不等于"端口被占用"，两者绝不能混着报（会误导排查方向）。"""
    occupied = []
    try:
        with open("/proc/net/udp") as handle:
            next(handle, None)
            for line in handle:
                parts = line.split()
                if len(parts) < 10:
                    continue
                local = parts[1]  # hex IP:PORT
                port_hex = local.split(":")[1] if ":" in local else ""
                if port_hex.upper() == PORT_HEX:
                    occupied.append((local, parts[9]))  # inode
    except OSError as exc:
        return "unreadable", str(exc)
    return "ok", occupied


def check_proto_running():
    try:
        out = subprocess.check_output(
            ["pgrep", "-af", "mdns_responder_proto.py"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
        return out
    except Exception:
        return ""


def try_bind():
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        reuseport = "yes"
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        except OSError as exc:
            reuseport = "no (%s)" % exc
        sock.bind(("0.0.0.0", MCAST_PORT))
        mreq = struct.pack("4s4s", socket.inet_aton(MCAST_GROUP),
                           socket.inet_aton("0.0.0.0"))
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
        sock.close()
        return "OK（SO_REUSEPORT=%s）" % reuseport
    except OSError as exc:
        return "FAIL：%s（errno=%d）" % (exc, exc.errno)


def enc_name(name):
    out = b""
    for label in name.split("."):
        if label == "":
            continue
        data = label.encode("utf-8")
        out += bytes([len(data)]) + data
    return out + b"\x00"


def dec_name(data, off):
    labels = []
    i = off
    while True:
        if i >= len(data):
            break
        length = data[i]
        if length == 0:
            i += 1
            break
        if length & 0xC0 == 0xC0:
            ptr = ((length & 0x3F) << 8) | data[i + 1]
            sub, _ = dec_name(data, ptr)
            labels.append(sub)
            i += 2
            break
        if i + 1 + length > len(data):
            break
        labels.append(data[i + 1:i + 1 + length].decode("utf-8", "replace"))
        i += 1 + length
    return ".".join(labels), i


def probe():
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        except OSError:
            pass
        sock.bind(("0.0.0.0", MCAST_PORT))
        mreq = struct.pack("4s4s", socket.inet_aton(MCAST_GROUP),
                           socket.inet_aton("0.0.0.0"))
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
        # 关掉环回，否则自己发出的查询会被自己收回来，误判成"有响应器"。
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 0)
        sock.settimeout(0.5)

        for qname in ("_airplay._tcp.local", "_raop._tcp.local"):
            query = enc_name(qname) + struct.pack(">HH", 12, 1)
            pkt = struct.pack(">HHHHHH", 0x1234, 0x0000, 1, 0, 0, 0) + query
            sock.sendto(pkt, (MCAST_GROUP, MCAST_PORT))

        print("  已发出 _airplay._tcp / _raop._tcp 查询，监听 3 秒…")
        airplay_hits = 0
        deadline = time.time() + 3
        while time.time() < deadline:
            try:
                data, addr = sock.recvfrom(4096)
            except socket.timeout:
                continue
            if len(data) < 12:
                continue
            flags = struct.unpack(">H", data[2:4])[0]
            qr = (flags >> 15) & 1          # 1 = 应答；0 = 查询（多半是环回残留）
            ancount = struct.unpack(">H", data[6:8])[0]
            if qr == 0:
                continue                    # 跳过查询包（含自身环回）
            # 跳过所有 question 段，取样第一条 answer 的名字
            off = 12
            qd = struct.unpack(">H", data[4:6])[0]
            ok = True
            for _ in range(qd):
                _, off = dec_name(data, off)
                if off + 4 > len(data):
                    ok = False
                    break
                off += 4
            name = ""
            if ok and ancount > 0:
                name, _ = dec_name(data, off)
            tag = ""
            if "iPhoneMirror" in name or "_airplay._tcp" in name or "_raop._tcp" in name:
                tag = "  ← 这是 iPhoneMirror/AirPlay 记录！"
                airplay_hits += 1
            print("  %s:%d 应答 %d 字节 [QR=%d ans=%d] 首条名=%s%s"
                  % (addr[0], addr[1], len(data), qr, ancount, name, tag))
        sock.close()
        if airplay_hits > 0:
            print("  ✅ 发现 iPhoneMirror/AirPlay 响应器在广播（native responder 活着）。")
        else:
            print("  ⚠️ 3 秒内没有收到任何 AirPlay/iPhoneMirror 应答 → 没人广播 AirPlay 服务")
        return airplay_hits
    except OSError as exc:
        print("  probe 失败：%s" % exc)
        return -1


def main():
    print("iPhoneMirror mDNS 状态诊断")

    section("0) 本机网卡一览（App 会从这里挑一张写进 mDNS 的 A 记录）")
    rows = list_ifaces()
    if not rows:
        print("  ✗ 一张有 IPv4 的网卡都没读到 —— 本机没连 Wi-Fi？这是最优先要解决的。")
    for row in rows:
        mark = "  [虚拟/应排除]" if row["virtual"] else ""
        print("  %-10s %-16s %-18s MAC=%s%s"
              % (row["name"], row["ip"], row["state"], row["mac"], mark))
    usable = [row for row in rows if not row["virtual"]]
    expected_ip = usable[0]["ip"] if usable else None
    print("  → App 应当宣告的地址：%s" % (expected_ip or "（无可用地址！）"))

    section("1) UDP/5353 是否被别的进程占用")
    status, payload = check_port_occupied()
    if status == "unreadable":
        print("  无法判断：沙箱里读不到 /proc/net/udp（%s）" % payload)
        print("  → 这只是「读不到」，不代表端口被占。以第 3 步的实际绑定结果为准。")
    elif payload:
        for local, inode in payload:
            print("  5353 被占用：local=%s inode=%s" % (local, inode))
        print("  → 多半是 Python 原型没关，或上一次 App 残留。需 kill 掉释放端口。")
    else:
        print("  5353 空闲")

    section("2) 上次 Python 原型是否还在跑")
    proto = check_proto_running()
    if proto:
        print("  ⚠️ 原型仍在运行：\n%s" % proto)
        print("  → 请先 pkill -f mdns_responder_proto.py")
    else:
        print("  原型未运行")

    section("3) 能否以 App 同样方式绑定 5353")
    print("  " + try_bind())

    section("4) 向局域网发 mDNS 查询看有没有响应器应答")
    hits = probe()

    section("结论")
    if hits is None or hits <= 0:
        print("  局域网里没有 AirPlay mDNS 在广播 → iPhone 必然搜不到。")
        print("  App 里点「应用」后若仍如此，看无线卡片状态行给的原因：")
        print("    · 显示「mDNS 广播未生效：…」 → 原生响应器没起来（原因已写在行里）；")
        print("    · 显示「已在局域网广播…已应答 0 次查询」 → 起来了但收不到查询，查本机 Wi-Fi / 防火墙；")
        print("    · 显示「…· 本机 <地址>」 → 那个地址必须等于上面第 0 步的地址。")
    else:
        print("  发现响应器在广播。看上面各条应答里的 A 记录：")
        print("    应为 %s；若是 224.x / 127.x / 0.0.0.0 则是非法主机地址。" % expected_ip)
    print("\n想看清「宣告了什么记录内容」，再跑：python3 tools/mdns_query.py")
    print("诊断完毕。")


if __name__ == "__main__":
    main()
