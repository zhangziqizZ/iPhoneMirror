#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
#
# mdns_responder_proto.py —— AirPlay mDNS 响应器「原型」【诊断工具，已不参与产品】
#
# ⚠️⚠️ 绝对不要和 App 同时运行，也不要把它的进程留在后台 ⚠️⚠️
#
#   本脚本把服务宣告到网上，但**背后没有任何 AirPlay TCP 服务在监听**——
#   端口 5000/7000 是源码里写死的占位值。于是：
#     * iPhone 能"搜到"这个服务（发现层是通的）；
#     * 点进去必然"连不上"（那些端口 nobody listening，TCP 直接被拒）。
#   这正是 2026-09-18 那次「搜到了但是连接不上」的真凶：上一轮会话把本脚本
#   留在后台跑着（`timeout 1800` 没能收掉它），我杀进程前还看到它一直在应答。
#
#   所以：
#     1. 它已被原生 responder（ohos/OhosMdnsResponder.{h,cpp}）取代，
#        只在排查「发现层」问题时临时用；
#     2. 用完必须确认进程真的退了（`ps -ef | grep mdns_responder_proto`），
#        否则它会一直把 iPhone 引到一个死端口上；
#     3. 它退出时**不发 goodbye（TTL=0）**，记录会在 iPhone 缓存里留最长
#        4500 秒。要立刻清掉：把 iPhone 的 Wi-Fi 关一下再开。
#     4. 与 App 同时在跑还会造成**两个响应器宣告同名服务** → iPhone 可能判
#        冲突而干脆不显示。自检脚本 tools/airplay_connect_probe.py 会报出
#        "端口没有 accept"，看到这个先查这里。
#
# 目的：在不重新构建 HAP 的前提下，于本机用原生 UDP 套接字直接回答局域网的
# mDNS 查询，验证「iPhone 能否发现我们」这件事到底卡在 @ohos.net.mdns 还是
# 别的环节。已证实本机没有常驻 mDNS 守护进程、5353 可独占绑定。
#
# 用法：python3 tools/mdns_responder_proto.py
#   后台运行；iPhone 打开「屏幕镜像」时应能看到 "iPhoneMirror AirPlay"。
#   日志会打印收到的查询与发出的应答，方便确认 iPhone 确实在问。
#   （本机 IPv4 是运行时探测的，不要写死：DHCP 换租约后写死会把 iPhone
#    指向别的机器。）

import socket
import struct
import subprocess
import sys
import time

MCAST_GROUP = "224.0.0.251"
MCAST_PORT = 5353


def get_local_ip() -> str:
    """动态探测本机在物理网卡上的 IPv4。

    原先硬编码 192.168.0.108 —— 但 DHCP 会把地址回收再分配（实测该地址已被
    iPhone 的私有 Wi-Fi 随机 MAC 占用），那时 A 记录指向的是别的设备甚至 iPhone
    自己，iPhone 看到的"设备"就在自己身上，自然连不上/显示异常。
    每次运行必须重新探测。
    """
    import fcntl
    SIOCGIFADDR = 0x8915
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        for want in ("wlan0", "wlan1", "eth0", "eth1"):
            try:
                raw = fcntl.ioctl(probe.fileno(), SIOCGIFADDR,
                                  struct.pack("256s", want.encode()[:15]))
                ip = socket.inet_ntoa(raw[20:24])
                if ip and not ip.startswith("127.") and not ip.startswith("169.254."):
                    return ip
            except OSError:
                continue
    finally:
        probe.close()
    return "127.0.0.1"


LOCAL_IP = get_local_ip()

# 用户可见的接收端名称（与 App 里的输入框默认值一致）
SERVICE_NAME = "iPhoneMirror AirPlay"
AIRPLAY_PORT = 7000   # 原型占位；真移植时用 vendored 库实际端口
RAOP_PORT = 5000      # 原型占位
HOSTNAME = "iphonemirror.local"

# ── AirPlay / RAOP 常量（与 vendored 库 dnssd_ohos.c / global.h / dnssdint.h 对齐）──
GLOBAL_VERSION = "845.5.1"
FEATURES = "0x5A7FFEE6,0x00000000"
MODEL = "AppleTV14,1"
RAOP_SF = "0x4"
RAOP_VV = "2"


def get_wlan0_mac() -> str:
    """拿 wlan0 的真实 MAC。ioctl 优先，/sys 与 ip 命令兜底。

    这台鸿蒙 PC 上 /sys/class/net/*/address 不可读（Errno 13），只走文件读取会
    静默退化成假 MAC（aa:bb:cc:dd:ee:ff），deviceid / RAOP 实例名 / hostname
    全部失真 —— iPhone 侧看到的是一台"无名设备"。
    """
    import fcntl
    SIOCGIFHWADDR = 0x8927
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            for ifname in ("wlan0", "wlan1", "eth0"):
                try:
                    raw = fcntl.ioctl(s.fileno(), SIOCGIFHWADDR,
                                      struct.pack("256s", ifname.encode()[:15]))
                    mac = ":".join("%02x" % b for b in raw[18:24])
                    if mac != "00:00:00:00:00:00":
                        return mac
                except OSError:
                    continue
        finally:
            s.close()
    except OSError:
        pass

    for path in ("/sys/class/net/wlan0/address", "/sys/class/net/wlan1/address"):
        try:
            with open(path) as f:
                return f.read().strip().lower()
        except OSError:
            pass
    try:
        out = subprocess.check_output(["ip", "link", "show", "wlan0"],
                                      stderr=subprocess.DEVNULL).decode()
        for tok in out.split():
            if len(tok) == 17 and tok.count(":") == 5:
                return tok.lower()
    except Exception:
        pass
    return "aa:bb:cc:dd:ee:ff"


MAC = get_wlan0_mac()
DEVICEID = MAC
AIRPLAY_INSTANCE = f"{SERVICE_NAME}._airplay._tcp.local"
RAOP_INSTANCE = f"{DEVICEID}@{SERVICE_NAME}._raop._tcp.local"


# ─────────────────────────── DNS 编码工具 ───────────────────────────

def enc_name(name: str) -> bytes:
    out = b""
    for label in name.split("."):
        if label == "":
            continue
        b = label.encode("utf-8")
        out += bytes([len(b)]) + b
    return out + b"\x00"


def dec_name(data: bytes, off: int):
    labels = []
    i = off
    while True:
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
        labels.append(data[i + 1:i + 1 + length].decode("utf-8", "replace"))
        i += 1 + length
    return ".".join(labels), i


def txt_bytes(pairs: list) -> bytes:
    out = b""
    for k, v in pairs:
        entry = f"{k}={v}" if v != "" else k
        b = entry.encode("utf-8")
        out += bytes([len(b)]) + b
    return out


def srv_bytes(target: str, port: int) -> bytes:
    return struct.pack(">HHH", 0, 0, port) + enc_name(target)


def resource_record(name: str, rtype: int, rdata: bytes, ttl=4500,
                    cache_flush=True) -> bytes:
    rclass = 0x0001 | (0x8000 if cache_flush else 0)
    return enc_name(name) + struct.pack(">HHIH", rtype, rclass, ttl, len(rdata)) + rdata


def airplay_txt() -> list:
    return [
        ("srcvers", GLOBAL_VERSION), ("deviceid", DEVICEID),
        ("features", FEATURES), ("model", MODEL),
        ("flags", RAOP_SF), ("vv", RAOP_VV),
    ]


def raop_txt() -> list:
    return [
        ("txtvers", "1"), ("ch", "2"), ("cn", "0,1,3"), ("et", "0,3,5"),
        ("sv", "false"), ("da", "true"), ("sr", "44100"), ("ss", "16"),
        ("pw", "false"), ("vn", "3"), ("tp", "TCP,UDP"), ("md", "0,1,2"),
        ("vs", GLOBAL_VERSION), ("sm", "false"), ("ek", "1"), ("sf", RAOP_SF),
        ("ft", FEATURES), ("am", MODEL),
    ]


def airplay_bundle() -> bytes:
    out = b""
    out += resource_record("_airplay._tcp.local", 12, enc_name(AIRPLAY_INSTANCE),
                           cache_flush=False)
    out += resource_record(AIRPLAY_INSTANCE, 33, srv_bytes(HOSTNAME, AIRPLAY_PORT))
    out += resource_record(AIRPLAY_INSTANCE, 16, txt_bytes(airplay_txt()))
    out += resource_record(HOSTNAME, 1, socket.inet_aton(LOCAL_IP))
    return out


def raop_bundle() -> bytes:
    out = b""
    out += resource_record("_raop._tcp.local", 12, enc_name(RAOP_INSTANCE),
                           cache_flush=False)
    out += resource_record(RAOP_INSTANCE, 33, srv_bytes(HOSTNAME, RAOP_PORT))
    out += resource_record(RAOP_INSTANCE, 16, txt_bytes(raop_txt()))
    out += resource_record(HOSTNAME, 1, socket.inet_aton(LOCAL_IP))
    return out


def answer_for(qname: str) -> bytes:
    q = qname.lower()
    if q == "_airplay._tcp.local":
        return airplay_bundle()
    if q == "_raop._tcp.local":
        return raop_bundle()
    if q == AIRPLAY_INSTANCE.lower():
        return (resource_record(AIRPLAY_INSTANCE, 33, srv_bytes(HOSTNAME, AIRPLAY_PORT))
                + resource_record(AIRPLAY_INSTANCE, 16, txt_bytes(airplay_txt()))
                + resource_record(HOSTNAME, 1, socket.inet_aton(LOCAL_IP)))
    if q == RAOP_INSTANCE.lower():
        return (resource_record(RAOP_INSTANCE, 33, srv_bytes(HOSTNAME, RAOP_PORT))
                + resource_record(RAOP_INSTANCE, 16, txt_bytes(raop_txt()))
                + resource_record(HOSTNAME, 1, socket.inet_aton(LOCAL_IP)))
    if q == HOSTNAME.lower():
        return resource_record(HOSTNAME, 1, socket.inet_aton(LOCAL_IP))
    return b""


def count_records(body: bytes) -> int:
    n = 0
    i = 0
    while i < len(body):
        j = i
        while body[j] != 0:
            if body[j] & 0xC0 == 0xC0:
                j += 2
                break
            j += 1 + body[j]
        else:
            j += 1
        rdlen = struct.unpack(">H", body[j + 8:j + 10])[0]
        i = j + 10 + rdlen
        n += 1
    return n


def response(qname: str, qtype: int, qclass: int, answers: bytes) -> bytes:
    flags = 0x8400  # QR=1, AA=1
    ancount = count_records(answers)
    header = struct.pack(">HHHHHH", 0, flags, 1, ancount, 0, 0)
    question = enc_name(qname) + struct.pack(">HH", qtype, qclass & 0x7FFF)
    return header + question + answers


def announcement(answers: bytes) -> bytes:
    """主动宣告：qd=0，全部放 answer 段。"""
    flags = 0x8400
    ancount = count_records(answers)
    header = struct.pack(">HHHHHH", 0, flags, 0, ancount, 0, 0)
    return header + answers


def main():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except OSError:
        pass
    sock.bind(("0.0.0.0", MCAST_PORT))
    mreq = struct.pack("4s4s", socket.inet_aton(MCAST_GROUP), socket.inet_aton("0.0.0.0"))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    sock.settimeout(1.0)

    print(f"[responder] 本机 {LOCAL_IP}  mac={MAC}", flush=True)
    print(f"[responder] AirPlay 实例: {AIRPLAY_INSTANCE}", flush=True)
    print(f"[responder] RAOP 实例:    {RAOP_INSTANCE}", flush=True)
    print("[responder] !! 这是诊断用原型：SRV 里宣告的端口 ",
          f"{AIRPLAY_PORT}(AirPlay)/{RAOP_PORT}(RAOP) 是**占位值**，",
          "背后没有服务在听。", flush=True)
    print("[responder] !! iPhone 能搜到它、点进去必然连不上。",
          "用完请务必确认进程已退出（ps -ef | grep mdns_responder_proto），",
          "也不要与 App 同时运行。", flush=True)
    print(f"[responder] 监听 {MCAST_GROUP}:{MCAST_PORT} ... (Ctrl-C 退出)", flush=True)

    def announce_once():
        for bundle in (airplay_bundle(), raop_bundle()):
            sock.sendto(announcement(bundle), (MCAST_GROUP, MCAST_PORT))

    for _ in range(3):
        announce_once()
        time.sleep(0.4)
    print("[responder] 已主动宣告，等待 iPhone 查询…")

    last_announce = time.time()
    while True:
        try:
            data, addr = sock.recvfrom(4096)
        except socket.timeout:
            if time.time() - last_announce > 5:
                announce_once()
                last_announce = time.time()
            continue

        print(f"[{time.strftime('%H:%M:%S')}] RAW 收到来自 {addr[0]}:{addr[1]} 的 {len(data)} 字节", flush=True)
        if len(data) < 12:
            continue
        qd = struct.unpack(">H", data[4:6])[0]
        off = 12
        for _ in range(qd):
            try:
                qname, off = dec_name(data, off)
            except Exception:
                break
            if off + 4 > len(data):
                break
            qtype, qclass = struct.unpack(">HH", data[off:off + 4])
            off += 4
            ql = qname.lower()
            if ql in (AIRPLAY_INSTANCE.lower(), RAOP_INSTANCE.lower(),
                      "_airplay._tcp.local", "_raop._tcp.local", HOSTNAME.lower()):
                answers = answer_for(qname)
                if answers:
                    resp = response(qname, qtype, qclass, answers)
                    try:
                        sock.sendto(resp, addr)
                        print(f"[{time.strftime('%H:%M:%S')}] {addr[0]}:{addr[1]} "
                              f"查询 {qname} (type={qtype}) → 应答 {count_records(answers)} 条")
                    except OSError as e:
                        print(f"[responder] 发送失败: {e}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n[responder] 退出")
        sys.exit(0)
