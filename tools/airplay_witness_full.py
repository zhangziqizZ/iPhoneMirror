#!/usr/bin/env python3
# airplay_witness_full.py — 升级版 witness，每个包都打明细
import argparse, collections, datetime, fcntl, socket, struct, time

MCAST_GROUP = "224.0.0.251"
MCAST_PORT = 5353
SIOCGIFADDR = 0x8915
WATCHED = ("_airplay", "_raop", "_companion-link", "_sleep-proxy",
           "_remotepairing", "_apple-mobdev2")


def iface_ipv4(name):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        return socket.inet_ntoa(fcntl.ioctl(s.fileno(), SIOCGIFADDR,
                struct.pack("256s", name.encode()[:15]))[20:24])
    except OSError:
        return None
    finally:
        s.close()


def pick_interface():
    try:
        names = [e[1] for e in socket.if_nameindex()]
    except Exception:
        names = []
    for n in ["wlan0", "wlan1", "wlan2", "eth0", "eth1"] + names:
        ip = iface_ipv4(n)
        if ip and not n.startswith(("lo", "docker", "veth", "br-", "virbr",
                                     "ancowlan", "WVMBr")):
            return n, ip
    return None, None


def local_addresses():
    out = {"127.0.0.1"}
    for _, n in socket.if_nameindex():
        ip = iface_ipv4(n)
        if ip:
            out.add(ip)
    return out


def read_name(data, offset):
    labels, jumped, end = [], False, offset
    for _ in range(64):
        if offset >= len(data): break
        L = data[offset]
        if L == 0: offset += 1; break
        if L & 0xC0:
            if not jumped: end = offset + 2
            jumped = True
            offset = ((L & 0x3F) << 8) | data[offset + 1]
            continue
        labels.append(data[offset + 1:offset + 1 + L].decode("utf-8", "replace"))
        offset += 1 + L
    if not jumped: end = offset
    return ".".join(labels), end


def parse(data):
    if len(data) < 12: return None
    is_resp = bool(data[2] & 0x80)
    qd = (data[4] << 8) | data[5]
    an = (data[6] << 8) | data[7]
    ar = (data[10] << 8) | data[11]
    off = 12; qname = None; addrs = []
    try:
        for _ in range(qd):
            qname, off = read_name(data, off); off += 4
        for c in (an, ar):
            for _ in range(c):
                _, off = read_name(data, off)
                rt = (data[off] << 8) | data[off + 1]
                rl = (data[off + 8] << 8) | data[off + 9]
                off += 10
                rd = data[off:off + rl]
                off += rl
                if rt == 1 and rl >= 4:
                    addrs.append(socket.inet_ntoa(rd[:4]))
    except Exception:
        pass
    return is_resp, qname, addrs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=15)
    ap.add_argument("--iface", default="")
    args = ap.parse_args()
    name, addr = (None, args.iface) if args.iface else pick_interface()
    if not addr: print("no iface"); return 1
    print(f"监听网卡 {name} = {addr}")
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try: sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except: pass
    sock.bind(("0.0.0.0", MCAST_PORT))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                    struct.pack("4s4s", socket.inet_aton(MCAST_GROUP),
                                socket.inet_aton(addr)))
    sock.settimeout(1.0)
    mine = local_addresses()
    counts = collections.Counter()
    start = time.time()
    print(f"\n盯 {args.seconds:.0f} 秒，每个包都打明细，Ctrl+C 提前停\n")
    while time.time() - start < args.seconds:
        try:
            data, addr_from = sock.recvfrom(9000)
        except socket.timeout:
            continue
        src = addr_from[0]
        counts[src] += 1
        parsed = parse(data)
        if not parsed: continue
        is_resp, qname, addrs = parsed
        ts = datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]
        kind = "ANN/Resp" if is_resp else "QUERY "
        blob = " ".join(s.decode("latin-1") for s in WATCHED if s.encode() in data)
        local = " (本机)" if src in mine else ""
        a = ",".join(addrs) if addrs else "-"
        print(f"[{ts}] {kind}  src={src}{local:8s}  q={qname or '-':50s} A={a:14s} 服务={blob or '-'}")
    print(f"\n=== 汇总 {args.seconds:.0f} 秒 ===")
    for ip, n in counts.most_common():
        print(f"  {ip:18s} {n:4d} {'(本机)' if ip in mine else ''}")


if __name__ == "__main__":
    main()