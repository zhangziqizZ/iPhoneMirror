#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
#
# mdns_probe.py —— 在本机（鸿蒙设备自身）发 mDNS 查询，验证 AirPlay 服务有没有
# 真的广播到局域网上。
#
# 为什么需要它：
#   「iPhone 搜不到设备」这个现象可能出在三层里的任何一层——
#     1) 应用没成功把服务交给系统 mDNS（addLocalService 失败 / 能力缺失）；
#     2) 系统 mDNS 收到了但没往网上发（组播不通 / 接口选错）；
#     3) 网上发出来了，但 iPhone 侧没看到（不同网段 / AP 隔离）。
#   在**本机**回环式地查一次，就能把 1、2 和 3 切开：
#     * 本机查询能查到自己的服务  → 服务确实在网上，问题在 iPhone 侧/网段；
#     * 本机查询查不到、但别的服务（如 _services._dns-sd）能查到 → 系统 mDNS 是通的，
#       是我们的服务没发布出去（回去看应用里的 mDNS 报错）；
#     * 什么都查不到 → 本机 mDNS 组播本身有问题（或这条链路被沙箱/权限挡住）。
#
# 用法（在设备上跑）：
#   python3 tools/mdns_probe.py                 # 枚举网上所有服务类型 + 直接查 AirPlay
#   python3 tools/mdns_probe.py --iface 192.168.0.108
#   python3 tools/mdns_probe.py --wait 5        # 每类查询等 5 秒（默认 3）
#
# 注意：查询从**临时端口**发出（不是 5353），按 RFC 6762 §6.7 应答会以单播回到
# 本端口，所以不需要抢系统的 5353 端口，也不会干扰系统 mDNS 服务。

import argparse
import socket
import struct
import sys
import time

MCAST_ADDR = '224.0.0.251'
MCAST_PORT = 5353

TYPE_PTR = 12
TYPE_TXT = 16
TYPE_SRV = 33
TYPE_A = 1

TYPE_NAMES = {TYPE_PTR: 'PTR', TYPE_TXT: 'TXT', TYPE_SRV: 'SRV', TYPE_A: 'A'}


def encode_name(name):
    out = b''
    for label in name.split('.'):
        if label == '':
            continue
        raw = label.encode('utf-8')
        out += bytes([len(raw)]) + raw
    return out + b'\x00'


def read_name(data, offset):
    """读 DNS 名字，支持压缩指针。返回 (name, new_offset)。"""
    labels = []
    jumped = False
    end = offset
    hops = 0
    while offset < len(data):
        length = data[offset]
        if length == 0:
            offset += 1
            if not jumped:
                end = offset
            break
        if (length & 0xC0) == 0xC0:
            pointer = ((length & 0x3F) << 8) | data[offset + 1]
            if not jumped:
                end = offset + 2
            jumped = True
            hops += 1
            if hops > 32:
                break
            offset = pointer
            continue
        labels.append(data[offset + 1:offset + 1 + length].decode('utf-8', 'replace'))
        offset += 1 + length
        if not jumped:
            end = offset
    return '.'.join(labels), end


def parse_response(data):
    if len(data) < 12:
        return []
    _, flags, qd, an, ns, ar = struct.unpack('!HHHHHH', data[:12])
    offset = 12
    for _ in range(qd):
        _, offset = read_name(data, offset)
        offset += 4
    records = []
    for _ in range(an + ns + ar):
        if offset >= len(data):
            break
        name, offset = read_name(data, offset)
        if offset + 10 > len(data):
            break
        rtype, rclass, ttl, rdlength = struct.unpack('!HHIH', data[offset:offset + 10])
        offset += 10
        rdata = data[offset:offset + rdlength]
        offset += rdlength

        value = ''
        if rtype == TYPE_PTR:
            value, _ = read_name(data, offset - rdlength)
        elif rtype == TYPE_SRV:
            if len(rdata) >= 6:
                prio, weight, port = struct.unpack('!HHH', rdata[:6])
                target, _ = read_name(data, offset - rdlength + 6)
                value = f'port={port} target={target} prio={prio} weight={weight}'
        elif rtype == TYPE_TXT:
            entries = []
            i = 0
            while i < len(rdata):
                ln = rdata[i]
                i += 1
                entries.append(rdata[i:i + ln].decode('utf-8', 'replace'))
                i += ln
            value = ' '.join(entries)
        elif rtype == TYPE_A:
            if len(rdata) == 4:
                value = socket.inet_ntoa(rdata)
        else:
            value = rdata.hex()

        records.append((name, rtype, rclass, ttl, value))
    return records, bool(flags & 0x8000), an


def query(service, iface_ip, timeout):
    packet = struct.pack('!HHHHHH', 0, 0, 1, 0, 0, 0)
    packet += encode_name(service) + struct.pack('!HH', TYPE_PTR, 1)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(('0.0.0.0', 0))
    if iface_ip:
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF,
                        socket.inet_aton(iface_ip))
    sock.settimeout(timeout)
    try:
        sock.sendto(packet, (MCAST_ADDR, MCAST_PORT))
    except OSError as error:
        print(f'  发送失败：{error}')
        sock.close()
        return []

    found = []
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            data, source = sock.recvfrom(9000)
        except socket.timeout:
            break
        except OSError as error:
            print(f'  接收失败：{error}')
            break
        parsed = parse_response(data)
        if not parsed:
            continue
        records, is_response, answer_count = parsed
        if not is_response:
            continue
        for name, rtype, rclass, ttl, value in records:
            found.append((source[0], name, rtype, value, ttl, answer_count))
    sock.close()
    return found


def report(title, service, iface_ip, timeout):
    print('=' * 72)
    print(f'{title}   查询 {service}')
    print('=' * 72)
    records = query(service, iface_ip, timeout)
    if not records:
        print('  （没有任何应答）')
        return []
    for source, name, rtype, value, ttl, _ in records:
        kind = TYPE_NAMES.get(rtype, str(rtype))
        print(f'  {name}  [{kind}]  ttl={ttl}')
        if value:
            print(f'      {value}')
        print(f'      <- 来自 {source}')
    return records


def watch(iface_ip, timeout, seconds):
    """连续查询两个 AirPlay 服务，直到出现或超时。

    用来配合「手机上点一下『应用』」这种操作：一边跑这个，一边启动接收端，
    服务一旦真的广播出来，这里会立刻打出来。
    """
    print(f'盯 {seconds:.0f} 秒，每轮查 _airplay._tcp.local 和 _raop._tcp.local …')
    deadline = time.time() + seconds
    seen = {}
    round_index = 0
    while time.time() < deadline:
        round_index += 1
        stamp = time.strftime('%H:%M:%S')
        hits = []
        for service in ('_airplay._tcp.local', '_raop._tcp.local'):
            for source, name, rtype, value, ttl, _ in query(service, iface_ip,
                                                             timeout):
                key = (service, name, value)
                if key not in seen:
                    seen[key] = True
                    hits.append((service, source, name, value))
        if hits:
            for service, source, name, value in hits:
                print(f'  [{stamp}] ✅ 发现 {service}')
                print(f'        {name}')
                if value:
                    print(f'        {value}')
                print(f'        <- 来自 {source}')
        else:
            sys.stdout.write('.')
            sys.stdout.flush()

    print()
    if seen:
        print('结果：AirPlay 服务**确实已经在网上广播**。')
        return True
    print('结果：整个观察期内没有任何 AirPlay 服务的应答 —— 服务没广播到网上。')
    return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--iface', default=None,
                        help='组播出接口的本机 IP，例如 192.168.0.108')
    parser.add_argument('--wait', type=float, default=3.0, help='每次查询等待秒数')
    parser.add_argument('--watch', type=float, default=0.0,
                        help='进入连续观察模式，参数为观察秒数（例如 180）')
    args = parser.parse_args()

    if args.watch > 0:
        print(f'本机地址：{args.iface or "（默认路由）"}')
        print()
        watch(args.iface, args.wait, args.watch)
        return

    print(f'本机地址：{args.iface or "（默认路由）"}   等待：{args.wait}s')
    print()

    # 1) 枚举网上所有服务类型——能证明"本机 mDNS 能不能看到别的设备"
    services = report('【1】服务类型枚举', '_services._dns-sd._udp.local',
                      args.iface, args.wait)

    # 2) 直接查我们要广播的两个服务
    airplay = report('【2】AirPlay 屏幕镜像', '_airplay._tcp.local',
                     args.iface, args.wait)
    raop = report('【3】RAOP 音频/镜像', '_raop._tcp.local',
                   args.iface, args.wait)

    print()
    print('=' * 72)
    print('结论')
    print('=' * 72)
    if airplay or raop:
        print('  ✅ 本机能查到 AirPlay/RAOP 服务：服务确实已经广播到网上。')
        print('     iPhone 仍搜不到的话，问题在网段隔离或 iPhone 侧，不在本机发布链路。')
    elif services:
        print('  ⚠️ 能看到局域网里别的服务，但看不到本机的 AirPlay 服务：')
        print('     说明本机 mDNS 收得到、我们的服务没发布成功 —— 回应用里看 mDNS 报错行。')
    else:
        print('  ❌ 连服务类型枚举都没有应答：')
        print('     可能是本机 mDNS 组播不通（或应用没起来 / 沙箱限制组播）。')


if __name__ == '__main__':
    sys.exit(main() or 0)
