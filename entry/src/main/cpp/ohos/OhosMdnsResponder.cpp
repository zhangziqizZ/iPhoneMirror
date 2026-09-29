// SPDX-License-Identifier: GPL-3.0-only
//
// OhosMdnsResponder.cpp —— 鸿蒙上自实现的 mDNS / DNS-SD 响应器
//
// 设计说明见同目录 OhosMdnsResponder.h。这里只强调几条实现上的取舍：
//
// 1. **地址绝不写死**。DHCP 换租约后本机 IP 会变（实测一天之内就从
//    192.168.0.108 变成了 192.168.0.110），而 mDNS 应答里的 A 记录一旦
//    写死就等于把 iPhone 指向别的机器 —— 表现是"能搜到、连不上"。
//    所以：启动时按网卡优先级解析，收到查询时再用 IP_PKTINFO 学到的
//    本机地址纠正（那个地址一定是对的，因为包就是从这个地址进来的）。
//
// 2. **主机名（SRV target）用本机 MAC 派生，全小写**，形如 iphonemirror-abcdef.local。
//    不用 gethostname()：这台设备上它就是 "localhost"，与本机名撞车没意义。
//    小写是 RFC 6762 §3 的 SHOULD，也是原型验证过能被 iPhone 发现的格式。
//
// 3. **AAAA 查询也回 A 记录**（09-19 修复）。旧版对 AAAA 回空 NODATA，理由是
//    "iPhone 会立刻用 A 记录"——但实测 iPhone 只问 AAAA 拿不到就放弃了，不会
//    主动再问 A。原型（tools/mdns_responder_proto.py）对任何 qtype 都回 A bundle，
//    iPhone 能稳定发现。RFC 6762 上"AAAA 问、A 答"不合规，但 iOS 接受。
//    同理，PTR 查询的 SRV/TXT/A 也全塞 answer 段（不放 additional），与原型一致。
//
// 4. 应答一律**单播**回查询来源（原型就是这么做的，iPhone 能正常发现）；
//    另外周期性组播宣告一份，作为缓存过期后的兜底。

#include "OhosMdnsResponder.h"

#include "im_dnssd_queue.h"

#include <arpa/inet.h>
#include <errno.h>
#include <net/if.h>
#include <netinet/in.h>
#include <poll.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

#include <sys/uio.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

// ─────────────────────────── 常量 ───────────────────────────

constexpr const char *kMulticastGroup = "224.0.0.251";
constexpr std::uint16_t kMdnsPort = 5353;
constexpr std::uint32_t kTtlShared = 4500;   // PTR / SRV / TXT：AirPlay 惯例
constexpr std::uint32_t kTtlAddress = 120;   // A 记录
// 周期性重播间隔。取 5 秒是刻意的：tools/mdns_responder_proto.py 原型用的就是
// 5 秒，而那个频率在本机上被证实"iPhone 能稳定发现"；改成低频只会在
// iPhone 缓存被污染/过期时拖长恢复时间，收益却接近零（每次才 ~2 个包）。
constexpr int kAnnounceIntervalSeconds = 5;
// 新服务注册后连续重播几次（mDNS 允许宣告重复，防单包丢失）。
constexpr int kRegistrationBurst = 3;
constexpr int kBurstSpacingMs = 250;
constexpr int kPollTimeoutMs = 200;

constexpr std::uint16_t kTypeA = 1;
constexpr std::uint16_t kTypePtr = 12;
constexpr std::uint16_t kTypeTxt = 16;
constexpr std::uint16_t kTypeAaaa = 28;
constexpr std::uint16_t kTypeSrv = 33;
constexpr std::uint16_t kTypeAny = 255;

// mDNS 响应头 flag：QR=1 + AA=1，完全不做 DNSSEC。
constexpr std::uint16_t kFlagsResponse = 0x8400;

// ─────────────────────────── 网卡枚举（ioctl，不依赖 /sys） ───────────────────────────
//
// 为什么不用 getifaddrs()：sysroot 里确实有 <ifaddrs.h>，但 ioctl 这条路已经在
// 本机用 Python 验证过（SIOCGIFADDR / SIOCGIFFLAGS / SIOCGIFHWADDR 全部可用），
// 且不需要额外遍历 sockaddr 结构的地址族判断。两者都只依赖 libc。

struct IfaceEntry {
    std::string name;
    std::string ip;
    std::string mac;
    int index{0};               // 内核接口索引（SIOCGIFINDEX），用于对上 IP_PKTINFO
    bool virtual_iface{false};
};

bool IoctlInterface(const char *name, unsigned long request, struct ifreq &out) {
    const int descriptor = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (descriptor < 0) return false;
    std::memset(&out, 0, sizeof(out));
    std::snprintf(out.ifr_name, IFNAMSIZ, "%s", name);
    const bool ok = ::ioctl(descriptor, request, &out) == 0;
    ::close(descriptor);
    return ok;
}

// 按索引反查网卡名（SIOCGIFNAME）。为什么要它：应用沙箱里 /proc/net/dev
// 未必可读，而"网卡名列表"是后面一切（IP、MAC、接口索引）的入口——
// 这里读不到就等于整个响应器宣告不出可用地址。纯 ioctl 不碰 /proc。
void CollectInterfaceNamesByIndex(std::vector<std::string> &names) {
    const int descriptor = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (descriptor < 0) return;
    for (int index = 1; index <= 32; ++index) {
        struct ifreq request;
        std::memset(&request, 0, sizeof(request));
        request.ifr_ifindex = index;
        if (::ioctl(descriptor, SIOCGIFNAME, &request) != 0) continue;
        if (request.ifr_name[0] == '\0') continue;
        const std::string name(request.ifr_name);
        if (std::find(names.begin(), names.end(), name) == names.end()) {
            names.push_back(name);
        }
    }
    ::close(descriptor);
}

std::string ToLower(std::string text) {
    for (char &character : text) {
        if (character >= 'A' && character <= 'Z') {
            character = static_cast<char>(character - 'A' + 'a');
        }
    }
    return text;
}

// ── 什么才算"能被 iPhone 访问到的本机地址" ──
//
// 这条判断是整个响应器的安全阀，必须卡死。血泪教训：**组播地址 224.0.0.251
// 一度被当成本机 IP 写进 A 记录**（因为错拿了 IP_PKTINFO 的 ipi_addr —— 那是
// IP 头里的*目的*地址，组播查询时它恒等于组播组地址），结果 iPhone 先"搜到但
// 连不上"、再"彻底搜不到"：它拿到的 A 记录指向组播组，既不可能是主机地址，
// 还可能被系统 mDNSResponder 判定为非法记录而整条丢弃。
//
// 所以凡是写进 A 记录的地址，一律先过这道闸：只接受可路由的单播地址。
bool IsUsableUnicastIpv4(const std::string &ip) {
    if (ip.empty()) return false;
    struct in_addr address;
    if (::inet_pton(AF_INET, ip.c_str(), &address) != 1) return false;
    const std::uint32_t value = ntohl(address.s_addr);
    if (value == 0) return false;                       // 0.0.0.0 / "未指定"
    if ((value >> 24) == 127) return false;             // 127/8 回环
    if ((value >> 16) == 0xA9FE) return false;          // 169.254/16 link-local
    if ((value >> 28) == 0xE) return false;             // 224/4 组播（就是它！）
    if ((value >> 28) == 0xF) return false;             // 240/4 保留 + 255.255.255.255
    return true;
}

// 明显不是"用户网络"的接口：回环、隧道、虚拟机网桥（Oseasy 的 WVMBr/WVMTap）、
// 以及这台设备上的 ancowlan0（172.17.1.1，内部虚拟网）。广播时如果挑到它们，
// iPhone 拿到的 A 记录就是个不可达地址。
bool LooksVirtualInterface(const std::string &name) {
    static const char *kPrefixes[] = {
        "lo", "dummy", "ip_vti", "ip6_vti", "sit", "ip6tnl", "hisilicon",
        "p2p", "chba", "nan", "wvmb", "wvmt", "ancowlan", "virbr", "veth",
        "docker", "bridge", "br-",
    };
    const std::string lower = ToLower(name);
    for (const char *prefix : kPrefixes) {
        if (lower.rfind(prefix, 0) == 0) return true;
    }
    return false;
}

// 网卡名集合，三路并集，任何一路失效都不影响结果：
//   ① /proc/net/dev（最全，但沙箱里未必可读）；
//   ② SIOCGIFNAME 按索引反查（纯 ioctl，见上）；
//   ③ 常见名兜底（保证至少能试到 wlan0）。
void CollectInterfaceNames(std::vector<std::string> &names) {
    std::FILE *file = std::fopen("/proc/net/dev", "r");
    if (file != nullptr) {
        char line[512];
        int index = 0;
        while (std::fgets(line, sizeof(line), file) != nullptr) {
            if (++index <= 2) continue; // 两行表头
            const char *colon = std::strchr(line, ':');
            if (colon == nullptr) continue;
            std::string name(line, static_cast<std::size_t>(colon - line));
            const std::size_t head = name.find_first_not_of(" \t");
            if (head == std::string::npos) continue;
            const std::size_t tail = name.find_last_not_of(" \t");
            names.push_back(name.substr(head, tail - head + 1));
        }
        std::fclose(file);
    }
    CollectInterfaceNamesByIndex(names);
    for (const char *extra : {"wlan0", "wlan1", "eth0", "eth1"}) {
        if (std::find(names.begin(), names.end(), extra) == names.end()) {
            names.push_back(extra);
        }
    }
}

bool ReadInterfaceIpv4(const char *name, std::string &out) {
    struct ifreq request;
    if (!IoctlInterface(name, SIOCGIFADDR, request)) return false;
    const auto *address =
        reinterpret_cast<const struct sockaddr_in *>(&request.ifr_addr);
    char text[INET_ADDRSTRLEN] = {0};
    if (::inet_ntop(AF_INET, &address->sin_addr, text, sizeof(text)) == nullptr) {
        return false;
    }
    // 回环 / link-local / 组播 / 0.0.0.0 都排除：它们不可能被 iPhone 访问到。
    if (!IsUsableUnicastIpv4(text)) return false;
    out = text;
    return true;
}

// 接口索引。IP_PKTINFO 给的 ipi_ifindex 只能靠它反查网卡——sysroot 里没有
// if_indextoname()（net/if.h 里不存在），所以自己用 SIOCGIFINDEX 建表。
bool ReadInterfaceIndex(const char *name, int &out) {
    struct ifreq request;
    if (!IoctlInterface(name, SIOCGIFINDEX, request)) return false;
    out = request.ifr_ifindex;
    return true;
}

bool ReadInterfaceFlags(const char *name, short &out) {
    struct ifreq request;
    if (!IoctlInterface(name, SIOCGIFFLAGS, request)) return false;
    out = request.ifr_flags;
    return true;
}

bool ReadInterfaceMac(const char *name, std::string &out) {
    struct ifreq request;
    if (!IoctlInterface(name, SIOCGIFHWADDR, request)) return false;
    const auto *bytes =
        reinterpret_cast<const unsigned char *>(request.ifr_hwaddr.sa_data);
    bool all_zero = true;
    for (int i = 0; i < 6; ++i) {
        if (bytes[i] != 0) all_zero = false;
    }
    if (all_zero) return false;
    char text[32];
    std::snprintf(text, sizeof(text), "%02X:%02X:%02X:%02X:%02X:%02X",
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5]);
    out = text;
    return true;
}

// 收集所有"有 IPv4 且已 UP/RUNNING"的接口（含虚拟接口，虚拟的只做排除判断用）。
std::vector<IfaceEntry> CollectInterfaces() {
    std::vector<std::string> names;
    CollectInterfaceNames(names);

    std::vector<IfaceEntry> entries;
    for (const std::string &name : names) {
        IfaceEntry entry;
        entry.name = name;
        entry.virtual_iface = LooksVirtualInterface(name);
        if (!ReadInterfaceIpv4(name.c_str(), entry.ip)) continue;
        short flags = 0;
        if (!ReadInterfaceFlags(name.c_str(), flags)) continue;
        if ((flags & IFF_UP) == 0 || (flags & IFF_RUNNING) == 0) continue;
        if ((flags & IFF_LOOPBACK) != 0) continue;
        ReadInterfaceIndex(name.c_str(), entry.index);
        ReadInterfaceMac(name.c_str(), entry.mac);
        entries.push_back(entry);
    }
    return entries;
}

// 接口表做短缓存。
//
// 早期实现里 **每收到一个包就 CollectInterfaces() 一次** —— 那背后是一串 ioctl。
// 本机曾经有进程以 200 包/秒宣告 mDNS（就是宣告风暴，见 AnnounceThrottleAllowed），
// 于是每秒几千次系统调用白烧 CPU，应答也被拖慢。这里缓存 2 秒足够：
// 换网后最迟 2 秒就会被 RefreshLocalAddress 看到。
std::mutex g_iface_cache_lock;
std::vector<IfaceEntry> g_iface_cache;
std::chrono::steady_clock::time_point g_iface_cache_stamp{};
constexpr auto kIfaceCacheTtl = std::chrono::seconds(2);

std::vector<IfaceEntry> CachedInterfaces() {
    std::lock_guard<std::mutex> lock(g_iface_cache_lock);
    const auto now = std::chrono::steady_clock::now();
    if (g_iface_cache_stamp.time_since_epoch().count() == 0 ||
        now - g_iface_cache_stamp >= kIfaceCacheTtl) {
        g_iface_cache = CollectInterfaces();
        g_iface_cache_stamp = now;
    }
    return g_iface_cache;   // 回值拷贝：条目只有个位数，换来无锁读的确定性
}

// 这个地址是不是本机某张网卡的？
//
// 用途：**认出自己发给自己的包**。组播环回（IP_MULTICAST_LOOP）会把我们发出的
// 宣告原样送回自己的 socket，源地址就是本机某张网卡。早期版本拿这类包去"学"
// 本机地址，于是每宣告一次就学到一个新地址（有时还是虚拟网卡的地址），地址一变
// 就重播 → 又被自己收到 → 无限循环。实测结果是 204 包/秒的宣告风暴，同一实例
// 被宣告成三个不同 IP（其中两个不可达），iPhone 因此完全找不到可用记录。
// 认出并丢掉自己的包，是从根上掐断这个反馈环的最稳做法。
bool IsLocalInterfaceAddress(const std::string &ip) {
    if (ip.empty()) return false;
    for (const IfaceEntry &entry : CachedInterfaces()) {
        if (entry.ip == ip) return true;
    }
    return false;
}

// 优先真实网卡，其次才轮到其它接口。
std::string PickBestIpv4(const std::vector<IfaceEntry> &entries) {
    static const char *kPreferred[] = {"wlan0", "wlan1", "eth0", "wlan2", "eth1"};
    for (const char *name : kPreferred) {
        for (const IfaceEntry &entry : entries) {
            if (entry.name == name && !entry.virtual_iface) return entry.ip;
        }
    }
    for (const IfaceEntry &entry : entries) {
        if (!entry.virtual_iface) return entry.ip;
    }
    return entries.empty() ? std::string() : entries.front().ip;
}

bool IpBelongsToVirtualInterface(const std::vector<IfaceEntry> &entries,
    const std::string &ip) {
    for (const IfaceEntry &entry : entries) {
        if (entry.ip == ip) return entry.virtual_iface;
    }
    return false;
}

// ─────────────────────────── DNS 编码 ───────────────────────────
//
// 名字统一表示成 label 序列（而不是 "a.b.c" 字符串），这样实例名里出现的
// 点号天然按"字面字节"处理，不必做 RFC 1035 的转义。

using Name = std::vector<std::string>;

struct Writer {
    std::vector<std::uint8_t> data;

    void put8(std::uint8_t value) { data.push_back(value); }
    void put16(std::uint16_t value) {
        put8(static_cast<std::uint8_t>(value >> 8));
        put8(static_cast<std::uint8_t>(value & 0xFF));
    }
    void put32(std::uint32_t value) {
        put16(static_cast<std::uint16_t>(value >> 16));
        put16(static_cast<std::uint16_t>(value & 0xFFFF));
    }
    void put_name(const Name &name) {
        for (const std::string &label : name) {
            const std::size_t size = std::min<std::size_t>(label.size(), 63);
            put8(static_cast<std::uint8_t>(size));
            data.insert(data.end(), label.begin(), label.begin() + size);
        }
        put8(0);
    }
    void put_bytes(const std::vector<std::uint8_t> &bytes) {
        data.insert(data.end(), bytes.begin(), bytes.end());
    }
};

Name SplitDotted(const std::string &text) {
    Name labels;
    std::size_t start = 0;
    while (start <= text.size()) {
        const std::size_t dot = text.find('.', start);
        const std::size_t end = (dot == std::string::npos) ? text.size() : dot;
        if (end > start) labels.push_back(text.substr(start, end - start));
        if (dot == std::string::npos) break;
        start = dot + 1;
    }
    return labels;
}

// "_raop._tcp" → {"_raop", "_tcp", "local"}
Name TypeFqdn(const std::string &type) {
    Name labels = SplitDotted(type);
    labels.push_back("local");
    return labels;
}

// 实例名整体作为**一个** label（含其中的点号）。
Name InstanceFqdn(const std::string &instance, const std::string &type) {
    Name labels;
    labels.push_back(instance);
    const Name tail = TypeFqdn(type);
    labels.insert(labels.end(), tail.begin(), tail.end());
    return labels;
}

Name HostFqdn(const std::string &host_label) {
    return Name{host_label, "local"};
}

bool SameName(const Name &left, const Name &right) {
    if (left.size() != right.size()) return false;
    for (std::size_t i = 0; i < left.size(); ++i) {
        if (ToLower(left[i]) != ToLower(right[i])) return false;
    }
    return true;
}

// iOS 在重新查询实例时，可能按 RFC 1035 把实例名里的空格转义成 "\032"
// （四个字面字符），而我们注册的实例名用的是真空格（0x20）。两者直接字节比对
// 会对不上，导致实例 SRV/TXT 查询永远答不出——这正是"已应答 N 次却搜不到"的
// 元凶之一（原型把 SRV/TXT/A 全塞进 answer 段，iOS 直接采用、从不重查实例，
// 所以原型能被搜到；我们放 additional 段，iOS 重查实例就撞上这个差异）。
// 归一化：把 "\032" 还原成空格，其余原样返回。
std::string NormalizeLabel(const std::string &label) {
    std::string out;
    out.reserve(label.size());
    for (std::size_t i = 0; i < label.size(); ++i) {
        if (label.size() - i >= 4 && label[i] == '\\' &&
            label[i + 1] == '0' && label[i + 2] == '3' && label[i + 3] == '2') {
            out.push_back(' ');
            i += 3;
        } else {
            out.push_back(label[i]);
        }
    }
    return out;
}

// 实例查询匹配：首段是实例名、尾段是 "<type>.local"，逐 label 比对（大小写不敏感，
// 并把 "\032" 当空格），容错 iOS 对实例名里空格的转义。类型后缀必须对齐，避免
// 把 _raop 实例查询错答成 _airplay 的数据。
bool MatchInstanceQuery(const Name &qname, const std::string &instance,
    const std::string &type) {
    const Name instance_labels = {instance};
    const Name type_tail = TypeFqdn(type);
    if (qname.size() != instance_labels.size() + type_tail.size()) return false;
    for (std::size_t i = 0; i < instance_labels.size(); ++i) {
        if (NormalizeLabel(ToLower(qname[i])) !=
            ToLower(NormalizeLabel(instance_labels[i])))
            return false;
    }
    for (std::size_t i = 0; i < type_tail.size(); ++i) {
        if (ToLower(qname[instance_labels.size() + i]) != ToLower(type_tail[i]))
            return false;
    }
    return true;
}

// ── 查询描述（只给人看，不参与协议） ──

// 类型码转可读文本。认不出来就报数字，别假装认识。
std::string TypeText(std::uint16_t type) {
    switch (type) {
        case kTypeA: return "A";
        case kTypePtr: return "PTR";
        case kTypeTxt: return "TXT";
        case kTypeAaaa: return "AAAA";
        case kTypeSrv: return "SRV";
        case kTypeAny: return "ANY";
        default: break;
    }
    return "type" + std::to_string(type);
}

// label 序列还原成点分 FQDN（末尾补点，和 mDNS 日志的写法一致）。
std::string DescribeName(const Name &name) {
    std::string text;
    for (const std::string &label : name) {
        text += label;
        text += '.';
    }
    return text.empty() ? std::string("(空名字)") : text;
}

// 查询归类：只看第一级标签。
//   _airplay  → 「屏幕镜像」列表会列出设备的**唯一**依据
//   _raop     → 找音频目标时也会问，会答，但不代表屏幕镜像能看见我们
//   _services → 通用服务枚举（_services._dns-sd._udp.local）
//   其他      → 主机名 A 查询等
enum QueryKind { kQueryAirplay = 0, kQueryRaop = 1, kQueryServices = 2, kQueryOther = 3 };

int ClassifyQuery(const Name &name) {
    if (name.empty()) return kQueryOther;
    const std::string first = ToLower(name.front());
    if (first == "_airplay") return kQueryAirplay;
    if (first == "_raop") return kQueryRaop;
    if (first == "_services") return kQueryServices;
    return kQueryOther;
}

const char *QueryKindText(int kind) {
    switch (kind) {
        case kQueryAirplay: return "_airplay";
        case kQueryRaop: return "_raop";
        case kQueryServices: return "服务枚举";
        default: break;
    }
    return "其他";
}

bool ParseName(const std::uint8_t *packet, std::size_t length, std::size_t &offset,
    Name &out) {
    out.clear();
    std::size_t position = offset;
    bool jumped = false;
    std::size_t guard = 0;
    while (true) {
        if (position >= length || ++guard > 128) return false;
        const std::uint8_t size = packet[position];
        if (size == 0) {
            ++position;
            break;
        }
        if ((size & 0xC0) == 0xC0) {
            if (position + 1 >= length) return false;
            const std::size_t target =
                (static_cast<std::size_t>(size & 0x3F) << 8) | packet[position + 1];
            if (!jumped) offset = position + 2;
            jumped = true;
            position = target;
            continue;
        }
        if (size > 63 || position + 1 + size > length) return false;
        out.emplace_back(
            reinterpret_cast<const char *>(packet + position + 1), size);
        position += 1 + size;
    }
    if (!jumped) offset = position;
    return true;
}

std::vector<std::uint8_t> EncodeNameRdlength(const Name &name) {
    Writer writer;
    writer.put_name(name);
    return std::move(writer.data);
}

std::vector<std::uint8_t> EncodeSrv(const Name &target, std::uint16_t port,
    bool goodbye) {
    Writer writer;
    writer.put16(0);                              // priority
    writer.put16(0);                              // weight
    writer.put16(goodbye ? 0 : port);             // 注销时端口按 RFC 6762 §10.1 置 0
    if (goodbye) {
        writer.put8(0);                           // 目标写成根节点
    } else {
        writer.put_name(target);
    }
    return std::move(writer.data);
}

// A 记录的唯一出口：地址不合法（组播/回环/0.0.0.0 …）就**不写这条记录**。
// 宁可不宣告地址，也不能宣告一个错的——后者会让 iPhone 把设备列出来却连不上，
// 或者干脆判定记录非法而不显示设备。
bool EncodeAddress(const std::string &ip, std::vector<std::uint8_t> &out) {
    if (!IsUsableUnicastIpv4(ip)) return false;
    out.assign(4, 0);
    return ::inet_pton(AF_INET, ip.c_str(), out.data()) == 1;
}

struct RecordSet {
    std::vector<std::uint8_t> data;
    int count{0};

    void add(const Name &name, std::uint16_t type, std::uint32_t ttl,
        bool cache_flush, const std::vector<std::uint8_t> &rdata) {
        Writer writer;
        writer.put_name(name);
        writer.put16(type);
        writer.put16(static_cast<std::uint16_t>(0x0001 | (cache_flush ? 0x8000 : 0)));
        writer.put32(ttl);
        writer.put16(static_cast<std::uint16_t>(rdata.size()));
        writer.put_bytes(rdata);
        data.insert(data.end(), writer.data.begin(), writer.data.end());
        ++count;
    }

    [[nodiscard]] bool empty() const { return count == 0; }
};

struct Question {
    Name name;
    std::uint16_t type{0};
    std::uint16_t klass{1};
};

std::vector<std::uint8_t> BuildMessage(const Question *question,
    const RecordSet &answers, const RecordSet &additionals) {
    Writer writer;
    writer.put16(0);                     // ID：mDNS 恒为 0
    writer.put16(kFlagsResponse);
    writer.put16(question != nullptr ? 1 : 0);
    writer.put16(static_cast<std::uint16_t>(answers.count));
    writer.put16(0);                     // NSCOUNT
    writer.put16(static_cast<std::uint16_t>(additionals.count));
    if (question != nullptr) {
        writer.put_name(question->name);
        writer.put16(question->type);
        writer.put16(static_cast<std::uint16_t>(question->klass & 0x7FFF));
    }
    writer.put_bytes(answers.data);
    writer.put_bytes(additionals.data);
    return std::move(writer.data);
}

// ─────────────────────────── 状态 ───────────────────────────

struct ServiceEntry {
    int id{0};
    std::string instance;               // RAID/RAOP 实例名（RAOP 含 "<hwaddr>@" 前缀）
    std::string type;                   // "_raop._tcp" / "_airplay._tcp"
    std::uint16_t port{0};
    std::vector<std::uint8_t> txt;      // 已编码好的 DNS-SD TXT
};

std::mutex g_lifecycle_lock;            // 串行化 start/stop
std::mutex g_state_lock;                // 保护下面这些字段
std::vector<ServiceEntry> g_services;
std::string g_local_ip;
std::string g_learned_ip;               // 来自 IP_PKTINFO，优先于枚举结果
std::string g_host_label = "iPhoneMirror";
std::string g_error;

int g_socket = -1;
std::atomic<bool> g_active{false};
std::atomic<bool> g_stop_requested{false};
std::atomic<std::uint64_t> g_answered{0};

// ── 应答诊断记账（2026-09-19 13:01 真机"已应答 4 次、iPhone 搜不到"）──
//
// 为什么必须记账、而不能靠抓包：本机开着 IP_MULTICAST_LOOP=0（防自反馈环的必需
// 措施），**我们自己发出的组播包不会回环到本机**；而来源为本机的包又会被主动丢弃
// （见收包循环第一道闸）。两条加在一起 ⇒ 任何从本机跑的探针都看不见我们的出包，
// `tools/airplay_responder_probe.py --unicast` 敲出 0 应答就属于**探针被自家规则
// 挡住**，不代表响应器死了。想回答"到底回给了谁、回的什么"，只能在进程内记账。
std::atomic<std::uint64_t> g_dropped_self{0};      // 被自环闸丢弃的包数
std::atomic<std::uint64_t> g_announce_sent{0};     // 宣告 sendto 成功次数
std::atomic<std::uint64_t> g_announce_failed{0};   // 宣告 sendto 失败次数
std::mutex g_diag_lock;
std::string g_last_answer_from;    // 最近一次被应答的查询来源 IP
std::string g_last_answer_ip;      // 该次应答里 A 记录用的 IP
std::string g_outbound_iface;      // IP_MULTICAST_IF 当前实际生效的地址
// ── "问了什么 / 我们手里有什么"（见 OhosMdnsResponder.h 的判读说明）──
//
// 为什么必须记账：iPhone 的「屏幕镜像」只认 `_airplay._tcp` 的 PTR，但它同时
// 会问 `_raop._tcp`（找音频目标），两条我们都会答，`g_answered` 照样往上涨。
// 于是"注册环节丢了 _airplay 服务"和"宣告没出去、iPhone 压根没问 _airplay"
// 这两种完全不同的病，在旧界面上长得一模一样。
std::string g_last_query;          // 最近收到的一条查询（含"未应答"原因）
std::string g_query_counts;        // 查询分类计数的可读文本
std::uint64_t g_query_kind[4] = {0, 0, 0, 0};           // 收到：0=_airplay 1=_raop 2=服务枚举 3=其他
std::uint64_t g_query_answered_kind[4] = {0, 0, 0, 0};  // 其中真的答出来的条数
// 最近几条"我们答不上来"的精确查询（名字 + 类型），环形保留 6 条。
// 这是定位"iPhone 到底问了什么我们答不上"的唯一可靠手段——ClassifyQuery 把
// 实例解析查询（首 label 是实例名而非 _airplay/_raop）和主机名查询都塞进"其他"
// 桶，单看那个桶根本分不清。这里把原始名记下来。
std::vector<std::string> g_unanswered_ring;
// 本机**另一个**响应器在宣告同名服务的证据（判据见 LooksLikeConflictingLocalResponse）。
// 记累计包数 + 一段说明文本；说明文本在每次重建"查询分类"行时都会重新附上，
// 否则 NoteQuery 每收到一条查询就把那行覆盖掉，警告会瞬间消失。
std::uint64_t g_conflicting_responder = 0;
std::string g_conflict_note;
// worker 心跳：WorkerMain 每次 poll 后写一次"现在时间(ms)"。
// is_active() 检查"now - last_tick"判定 worker 是否还被系统调度。
// 这是 OHOS 后台冻结判定唯一可信的信号——g_active 只能反映"启动过"，不能反映
// "现在还在跑"。直接用 std::chrono::steady_clock 的内部 epoch，只在同进程内
// 比较，跨进程没有意义。
std::atomic<std::int64_t> g_worker_last_tick_ms{0};
std::thread g_worker;

// 记一条收到的查询。
//
// 特别地，**答不出来也要记**：iPhone 问 `_airplay._tcp.local` 而 g_services 里
// 没有这个服务时，BuildAnswerFor 返回 false，老实现里连计数都不加，界面上
// 看起来跟"根本没人来问"完全一样 —— 这恰恰是最需要被看见的一种故障。
void NoteQuery(const Name &name, std::uint16_t type,
    const struct sockaddr_in &source, bool answered) {
    const int kind = ClassifyQuery(name);
    std::string text = DescribeName(name) + " " + TypeText(type) + " ← ";
    {
        char origin[INET_ADDRSTRLEN] = {0};
        if (::inet_ntop(AF_INET, &source.sin_addr, origin, sizeof(origin)) != nullptr) {
            text += origin;
        } else {
            text += "?";
        }
    }
    if (!answered) {
        text += "  ⚠未应答：查询名不在我们注册的服务里";
        // 环形保留最近几条未应答的精确名，定位"iPhone 问了什么我们答不上"。
        const std::string entry = DescribeName(name) + " " + TypeText(type);
        g_unanswered_ring.push_back(entry);
        if (g_unanswered_ring.size() > 6) {
            g_unanswered_ring.erase(g_unanswered_ring.begin());
        }
    }

    std::lock_guard<std::mutex> lock(g_diag_lock);
    ++g_query_kind[kind];
    if (answered) ++g_query_answered_kind[kind];
    g_last_query = text;
    std::string counts =
        "_airplay " + std::to_string(g_query_kind[0]) + "(答 " +
            std::to_string(g_query_answered_kind[0]) + ") / "
        "_raop " + std::to_string(g_query_kind[1]) + "(答 " +
            std::to_string(g_query_answered_kind[1]) + ") / "
        "服务枚举 " + std::to_string(g_query_kind[2]) + " / "
        "其他 " + std::to_string(g_query_kind[3]) + "(答 " +
            std::to_string(g_query_answered_kind[3]) + ")";
    if (!g_unanswered_ring.empty()) {
        counts += " · 未应答明细:";
        for (const std::string &u : g_unanswered_ring) {
            counts += " [" + u + "]";
        }
    }
    // 冲突响应器的警告必须在这里重贴：本函数每次都会整行重建 g_query_counts。
    if (!g_conflict_note.empty()) {
        counts += g_conflict_note;
    }
    g_query_counts = counts;
}

// 从一条已编码的 DNS-SD TXT 字节里取指定 key 的 value。找不到或编码畸形返回空串。
// 格式：<len><"key[=value]">…<len>…，每条 <len> ≤ 255，整体 ≤ 1024。
std::string DecodeTxtField(const std::vector<std::uint8_t> &txt,
                            const char *key) {
    if (txt.empty() || key == nullptr || key[0] == '\0') return {};
    const size_t klen = std::strlen(key);
    size_t i = 0;
    while (i < txt.size()) {
        const uint8_t entry_len = txt[i];
        if (entry_len == 0 || i + 1 + entry_len > txt.size()) break;
        const std::string entry(reinterpret_cast<const char *>(&txt[i + 1]),
                                 entry_len);
        if (entry.compare(0, klen, key) == 0 &&
            entry.size() > klen && entry[klen] == '=') {
            return entry.substr(klen + 1);
        }
        if (entry == key) {
            // 只有 key 没 value（DNS-SD 合法）
            return {};
        }
        i += 1 + entry_len;
    }
    return {};
}

// 把当前持有的服务摊成一行文本。空串 = 一条都没注册上（宣告必然无效）。
std::string BuildServiceListText() {
    std::lock_guard<std::mutex> lock(g_state_lock);
    std::string text;
    for (const ServiceEntry &service : g_services) {
        if (!text.empty()) text += " · ";
        text += service.type;
        text += ":";
        text += std::to_string(service.port);
        text += " (";
        text += service.instance;
        text += ")";
        // 09-19 加：把 TXT 里关键字段打出来。下一行「txt_size=N head=...」永远打印，
        // 让"DecodeTxtField 没找到"和"service.txt 本身就空"这两种**最常见的失败**
        // 一眼能分开。head 是 TXT 前 24 字节的可打印表示（不可打印用 .）。
        text += " [txt_size=";
        text += std::to_string(service.txt.size());
        text += " head=";
        const std::size_t preview = std::min<std::size_t>(service.txt.size(), 24);
        for (std::size_t i = 0; i < preview; ++i) {
            const unsigned char c = service.txt[i];
            text += (c >= 32 && c < 127) ? static_cast<char>(c) : '.';
        }
        text += "]";
        // 把 TXT 里关键字段打出来：model / deviceid。解码失败 / 字段缺失就安静地
        // 不显示，不污染布局。"txt_size=0 head=" 是空的 ⇒ service.txt 真的没数据，
        // 排查方向是 dnssd_register_* 那侧；若 head 有内容但 model 没出来 ⇒
        // 排查 DecodeTxtField。
        for (const char *key : {"model", "deviceid"}) {
            std::string value = DecodeTxtField(service.txt, key);
            if (!value.empty()) {
                text += " ";
                text += key;
                text += "=";
                text += value;
            }
        }
    }
    return text;
}

// 取 steady_clock ms 计数。单独成函数是因为 WorkerMain 和 is_active() 都要用。
std::int64_t SteadyNowMs() {
    const auto now = std::chrono::steady_clock::now();
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        now.time_since_epoch()).count();
}

std::string DescribeErrno(const char *what) {
    char buffer[256];
    std::snprintf(buffer, sizeof(buffer), "%s 失败：%s（errno=%d）", what,
        std::strerror(errno), errno);
    return std::string(buffer);
}

// ─────────────────────────── 记录构造 ───────────────────────────

// 一个服务的完整宣告：PTR（服务类型）+ SRV + TXT + A（主机地址）。
void AppendServiceRecords(const ServiceEntry &service, const std::string &host_label,
    const std::string &ip, bool goodbye, RecordSet &records) {
    const Name type_name = TypeFqdn(service.type);
    const Name instance_name = InstanceFqdn(service.instance, service.type);
    const Name host_name = HostFqdn(host_label);
    const std::uint32_t ttl = goodbye ? 0 : kTtlShared;

    records.add(type_name, kTypePtr, ttl, false, EncodeNameRdlength(instance_name));
    records.add(instance_name, kTypeSrv, ttl, true,
        EncodeSrv(host_name, service.port, goodbye));
    records.add(instance_name, kTypeTxt, ttl, true, service.txt);
    std::vector<std::uint8_t> address;
    if (!ip.empty() && EncodeAddress(ip, address)) {
        records.add(host_name, kTypeA, goodbye ? 0 : kTtlAddress, true, address);
    }
}

struct Snapshot {
    std::vector<ServiceEntry> services;
    std::string ip;
    std::string host_label;
};

Snapshot TakeSnapshot() {
    std::lock_guard<std::mutex> lock(g_state_lock);
    Snapshot snapshot;
    snapshot.services = g_services;
    snapshot.ip = g_local_ip;
    snapshot.host_label = g_host_label;
    return snapshot;
}

// 本机当前有没有"能写进 A 记录"的地址。
//
// 这是对外发言的总开关：没有可用地址时，**一个包都不发**。理由见 EncodeAddress
// 上方那段说明——只送 PTR/SRV 而缺 A（或送个组播地址当 A）会让 iPhone 把设备
// 列出来却连不上，比"暂时不出现"更糟：前者把问题伪装成连接失败，后者至少是诚实的。
//
// 但"一个包都不发"对外表现为**彻底沉默**：App 状态行仍挂着历史累计的
// "已应答 N 次"，看起来一切正常，实际已经哑了。所以这里必须把原因写进
// g_error，让 UI 如实说"我没在发包，因为 XXX"，而不是假装还在广播。
// 调用点（AnnounceAll / HandleQueryPacket）都不持有 g_state_lock，可安全加锁。
constexpr const char *kNoAddressPrefix = "本机没有可宣告的 IPv4";

bool HasUsableAddress() {
    std::lock_guard<std::mutex> lock(g_state_lock);
    std::vector<std::uint8_t> address;
    const bool usable = EncodeAddress(g_local_ip, address);
    if (usable) {
        // 只清除"本函数自己写的那条"，别覆盖 bind 失败等真实错误。
        if (g_error.compare(0, std::strlen(kNoAddressPrefix),
                kNoAddressPrefix) == 0) {
            g_error.clear();
        }
        return true;
    }
    char text[160];
    std::snprintf(text, sizeof(text),
        "%s（当前\"%s\"），已停止应答与宣告；"
        "请检查 Wi-Fi 是否已连接并拿到 IP",
        kNoAddressPrefix, g_local_ip.empty() ? "空" : g_local_ip.c_str());
    g_error = text;
    return false;
}

// ─────────────────────────── 收发 ───────────────────────────

// 返回 true = sendto 真的把包交给内核了。返回值必须留住：宣告发不出去时，
// 界面上"已在局域网广播"那句话就是假的（见 g_announce_failed 的说明）。
bool SendPacket(const std::vector<std::uint8_t> &packet,
    const struct sockaddr_in &destination) {
    if (packet.empty() || g_socket < 0) return false;
    const ssize_t sent = ::sendto(g_socket, packet.data(), packet.size(), 0,
        reinterpret_cast<const struct sockaddr *>(&destination), sizeof(destination));
    return sent == static_cast<ssize_t>(packet.size());
}

struct sockaddr_in MulticastAddress() {
    struct sockaddr_in address;
    std::memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(kMdnsPort);
    ::inet_pton(AF_INET, kMulticastGroup, &address.sin_addr);
    return address;
}

// 问内核："往这个目的地发单播，你会拿哪个本地地址当源？"
//
// 为什么必须问：这台设备是策略路由、**没有默认路由**。`sendto` 返回成功只说明
// 内核把包收下了，**不代表它挑对了出口网卡** —— 它完全可能把应答从
// WVMBr14204819 / ancowlan0 这类虚拟网卡发出去，iPhone 永远收不到，而界面上
// "已应答 N 次"照涨。connect()+getsockname() 是唯一能在进程内把内核的选择
// 明确说出来的办法：如果它不是我们宣告的那张 Wi-Fi 地址，这条诊断就直接把
// "单播应答走错网卡"这个假成功钉死。
std::string ProbeUnicastSource(const struct sockaddr_in &destination) {
    const int descriptor = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (descriptor < 0) return std::string();
    std::string text;
    if (::connect(descriptor,
            reinterpret_cast<const struct sockaddr *>(&destination),
            sizeof(destination)) == 0) {
        struct sockaddr_in bound;
        std::memset(&bound, 0, sizeof(bound));
        socklen_t length = sizeof(bound);
        char buffer[INET_ADDRSTRLEN] = {0};
        if (::getsockname(descriptor, reinterpret_cast<struct sockaddr *>(&bound),
                &length) == 0 &&
            ::inet_ntop(AF_INET, &bound.sin_addr, buffer, sizeof(buffer)) != nullptr) {
            text = buffer;
        }
    }
    ::close(descriptor);
    return text;
}

bool ContainsAscii(const std::uint8_t *data, std::size_t length,
    const std::string &needle) {
    if (needle.empty() || length < needle.size()) return false;
    const std::size_t last = length - needle.size();
    for (std::size_t i = 0; i <= last; ++i) {
        if (std::memcmp(data + i, needle.data(), needle.size()) == 0) return true;
    }
    return false;
}

// 这个"来源=本机"的包，是不是**另一个进程**在宣告跟我们同名的服务？
//
// 判据：它是应答/宣告（QR=1），且报文里出现了我们某个服务的实例名。
// 我们自己的出向组播开着 IP_MULTICAST_LOOP=0，**不会**回环到本机 socket；
// 所以"来源=本机 + QR=1 + 带我们的实例名"只可能来自本机另一个响应器。
//
// 为什么这件事至关重要：iPhone 会同时看到两份指向同一实例名、却给出不同
// host/端口的 SRV/TXT，mDNS 把它们判成**记录冲突**，于是干脆不显示这台设备 ——
// 而界面上是"注册正常、宣告成功、已应答 N 次"，假成功得毫无破绽。
// 本工程真踩过这一坑：诊断用的 mdns_responder_proto.py 被留在后台，与 App
// 抢同一个 "iPhoneMirror AirPlay"。
bool LooksLikeConflictingLocalResponse(const std::uint8_t *packet,
    std::size_t length) {
    if (length < 12) return false;
    if ((packet[2] & 0x80) == 0) return false;    // QR=0：这是查询，不是宣告
    std::vector<std::string> instances;
    {
        std::lock_guard<std::mutex> lock(g_state_lock);
        for (const ServiceEntry &service : g_services) {
            if (!service.instance.empty()) instances.push_back(service.instance);
        }
    }
    for (const std::string &instance : instances) {
        if (ContainsAscii(packet, length, instance)) return true;
    }
    return false;
}

// 把组播**收发**都显式绑到某张网卡：出向 IP_MULTICAST_IF + 入向加入组播组。
//
// 为什么必须显式绑：这台设备是策略路由、**没有默认路由**，光靠路由表选不出
// "该从哪张网卡发组播"——内核会挑它自己认为合适的那张（实测可能是
// WVMBr14204819 / ancowlan0 这类虚拟接口）。那种情况下宣告包根本没进 Wi-Fi
// 空口，iPhone 永远收不到，但**单播应答仍然正常**（sendto 到 iPhone 的地址会
// 按目的地址选对网卡）——症状就是极其迷惑人的"已应答 N 次查询、iPhone 却搜不到"。
void ApplyMulticastInterface(const std::string &ip) {
    if (ip.empty() || g_socket < 0) return;
    struct in_addr local;
    if (::inet_pton(AF_INET, ip.c_str(), &local) != 1) return;
    // 把内核**实际认下**的值读回来存进诊断。前面那段注释预言的那个症状
    // （"宣告包没进 Wi-Fi 空口、但单播应答正常 ⇒ 已应答 N 次却搜不到"）只有在
    // 这里才能被证实或排除：单看 g_local_ip 是"我们想用哪张网卡"，而从这里读回的
    // 才是"内核真的会用哪张网卡发组播"。两者不一致时 IP_MULTICAST_IF 根本没生效。
    if (::setsockopt(g_socket, IPPROTO_IP, IP_MULTICAST_IF, &local, sizeof(local)) != 0) {
        std::lock_guard<std::mutex> lock(g_diag_lock);
        g_outbound_iface = std::string("设置失败: ") + DescribeErrno("IP_MULTICAST_IF");
    } else {
        struct in_addr actual;
        std::memset(&actual, 0, sizeof(actual));
        socklen_t length = sizeof(actual);
        char text[INET_ADDRSTRLEN] = {0};
        if (::getsockopt(g_socket, IPPROTO_IP, IP_MULTICAST_IF, &actual, &length) == 0 &&
            ::inet_ntop(AF_INET, &actual, text, sizeof(text)) != nullptr) {
            std::lock_guard<std::mutex> lock(g_diag_lock);
            g_outbound_iface = text;
        }
    }
    // 顺手在这张网卡上（再）加入组播组。重复加入是安全的（内核按
    // (组, 网卡) 计数），但它保证了"换网之后新网卡上也收得到别人的查询"——
    // 换网时若只改出口不补加入，我们就会"能发不能收"。
    struct ip_mreq request;
    std::memset(&request, 0, sizeof(request));
    ::inet_pton(AF_INET, kMulticastGroup, &request.imr_multiaddr);
    request.imr_interface = local;
    ::setsockopt(g_socket, IPPROTO_IP, IP_ADD_MEMBERSHIP, &request,
        sizeof(request));
}

// 对外发言的第二道闸：宣告频率熔断。
//
// 真出过事：本机一度以 **204 包/秒** 反复重播同一批记录（反馈环导致，见
// IsLocalInterfaceAddress 的说明），而且每次 A 记录都换张网卡。那种风暴的后果比
// "不广播"严重得多 —— 局域网被刷爆，iPhone 看到同一实例对应三个互相打架的 IP，
// 于是判定记录不可信，设备干脆消失。
//
// 所以这里留一道保险：5 秒内超过 kAnnounceCeiling 次就不再发。宁可暂停广播并把
// 原因写在 mdns_error 里让人看见，也不能把邻居们的网络吃掉。
std::mutex g_announce_lock;
std::deque<std::chrono::steady_clock::time_point> g_announce_stamps;
constexpr std::size_t kAnnounceCeiling = 12;             // 5 秒内最多宣告次数
constexpr auto kAnnounceWindow = std::chrono::seconds(5);

bool AnnounceThrottleAllowed() {
    const auto now = std::chrono::steady_clock::now();
    std::lock_guard<std::mutex> lock(g_announce_lock);
    g_announce_stamps.push_back(now);
    while (!g_announce_stamps.empty() &&
           now - g_announce_stamps.front() >= kAnnounceWindow) {
        g_announce_stamps.pop_front();
    }
    if (g_announce_stamps.size() <= kAnnounceCeiling) return true;
    std::lock_guard<std::mutex> state(g_state_lock);
    g_error = "检测到宣告风暴（5 秒内 >" + std::to_string(kAnnounceCeiling) +
        " 次），已暂停广播以免刷爆局域网。请停止后重新启动接收端；"
        "若反复出现，多半是本机还有另一个 mDNS 响应器在抢同一个服务名。";
    return false;
}

void AnnounceAll(bool goodbye) {
    const Snapshot snapshot = TakeSnapshot();
    if (snapshot.services.empty()) return;
    // 没有可用地址就别宣告：宣告出去必然缺 A 记录（或带个错地址）。
    if (!goodbye && !HasUsableAddress()) return;
    if (!goodbye && !AnnounceThrottleAllowed()) return;
    RecordSet records;
    for (const ServiceEntry &service : snapshot.services) {
        AppendServiceRecords(service, snapshot.host_label, snapshot.ip, goodbye, records);
    }
    const RecordSet none;
    const std::vector<std::uint8_t> packet = BuildMessage(nullptr, records, none);
    const struct sockaddr_in destination = MulticastAddress();
    // 宣告必须报成败：这是"iPhone 到底有没有机会看到我们"的唯一出路
    // （组播包不回环，本机抓不到，只能靠 sendto 的返回值 + 出向网卡推断）。
    if (SendPacket(packet, destination)) {
        g_announce_sent.fetch_add(1, std::memory_order_relaxed);
    } else {
        g_announce_failed.fetch_add(1, std::memory_order_relaxed);
    }
}

void SendGoodbyeFor(const ServiceEntry &service) {
    RecordSet records;
    std::string host_label;
    std::string ip;
    {
        std::lock_guard<std::mutex> lock(g_state_lock);
        host_label = g_host_label;
        ip = g_local_ip;
    }
    AppendServiceRecords(service, host_label, ip, true, records);
    const RecordSet none;
    const std::vector<std::uint8_t> packet = BuildMessage(nullptr, records, none);
    const struct sockaddr_in destination = MulticastAddress();
    SendPacket(packet, destination);
}

// 应答一条查询。返回 false 表示"这不是问我们的"（不回应答）。
//
// ⚠️ 本函数的行为**刻意对齐 tools/mdns_responder_proto.py 原型**，而不是
// 严格遵循 RFC 6762/6763。原因：原型实测能被 iPhone「屏幕镜像」发现，而
// 之前"更合规"的写法（AAAA 回空 NODATA、SRV/TXT/A 放 additional 段）在
// 同一台设备上 iPhone 完全搜不到。差异点见下面每段注释。
bool BuildAnswerFor(const Name &qname, std::uint16_t qtype, RecordSet &answers,
    RecordSet &additionals) {
    Snapshot snapshot;
    {
        std::lock_guard<std::mutex> lock(g_state_lock);
        snapshot.services = g_services;
        snapshot.ip = g_local_ip;
        snapshot.host_label = g_host_label;
    }
    const Name host_name = HostFqdn(snapshot.host_label);

    // 1) 主机名查询：A / AAAA / ANY 一律把 A 记录塞进 answer 段。
    //
    // 关键修复：**AAAA 也要回 A 记录**。之前这里对 AAAA 只 return true 而
    // answers 为空 —— 等于回了个空 NODATA，iPhone 拿不到地址，「屏幕镜像」
    // 列表永远空。旧注释曾说"回 NODATA 让它立刻用 A 记录"，但 iPhone 不会
    // 主动再问一次 A —— 它只问 AAAA 拿不到就放弃了。
    //
    // RFC 6762 上"AAAA 问、A 答"确实不合规，但 iOS 的 DNS-SD 客户端接受
    // 这种回应（原型验证过），合规的空 NODATA 反而让它放弃。
    if (SameName(qname, host_name)) {
        if (qtype == kTypeA || qtype == kTypeAaaa || qtype == kTypeAny) {
            std::vector<std::uint8_t> address;
            if (!snapshot.ip.empty() && EncodeAddress(snapshot.ip, address)) {
                answers.add(host_name, kTypeA, kTtlAddress, true, address);
            }
            return true;
        }
        return false;
    }

    // 2) 服务类型 PTR 查询（"屏幕镜像"列表就是这么来的）。
    //
    // 关键修复：PTR + SRV + TXT + A **全部塞进 answer 段**，与原型一致。
    // RFC 6763 允许把 SRV/TXT/A 作为 glue 放 additional 段，但实测 iOS 的
    // 屏幕镜像浏览器对 answer 段更敏感 —— 原型全塞 answer 段能稳定被发现，
    // 挪到 additional 之后就搜不到了。
    bool matched_type = false;
    for (const ServiceEntry &service : snapshot.services) {
        const Name type_name = TypeFqdn(service.type);
        if (!SameName(qname, type_name)) continue;
        matched_type = true;
        const Name instance_name = InstanceFqdn(service.instance, service.type);
        answers.add(type_name, kTypePtr, kTtlShared, false,
            EncodeNameRdlength(instance_name));
        answers.add(instance_name, kTypeSrv, kTtlShared, true,
            EncodeSrv(host_name, service.port, false));
        answers.add(instance_name, kTypeTxt, kTtlShared, true, service.txt);
        std::vector<std::uint8_t> address;
        if (!snapshot.ip.empty() && EncodeAddress(snapshot.ip, address)) {
            answers.add(host_name, kTypeA, kTtlAddress, true, address);
        }
    }
    if (matched_type) return true;

    // 3) 具体实例的 SRV / TXT 查询。A 记录同样塞 answer 段（原型行为）。
    for (const ServiceEntry &service : snapshot.services) {
        const Name instance_name = InstanceFqdn(service.instance, service.type);
        // 用容错匹配（见 MatchInstanceQuery）：iOS 可能把实例名里的空格转义成
        // "\032"，直接 SameName 会对不上，实例 SRV/TXT 查询就答不出。
        if (!MatchInstanceQuery(qname, service.instance, service.type)) continue;
        answers.add(instance_name, kTypeSrv, kTtlShared, true,
            EncodeSrv(host_name, service.port, false));
        answers.add(instance_name, kTypeTxt, kTtlShared, true, service.txt);
        std::vector<std::uint8_t> address;
        if (!snapshot.ip.empty() && EncodeAddress(snapshot.ip, address)) {
            answers.add(host_name, kTypeA, kTtlAddress, true, address);
        }
        return true;
    }

    // 4) 通用服务枚举（_services._dns-sd._udp.local），给通用浏览器用。
    const Name services_name = {"_services", "_dns-sd", "_udp", "local"};
    if (SameName(qname, services_name)) {
        for (const ServiceEntry &service : snapshot.services) {
            answers.add(services_name, kTypePtr, kTtlShared, false,
                EncodeNameRdlength(TypeFqdn(service.type)));
        }
        return true;
    }
    return false;
}

void HandleQueryPacket(const std::uint8_t *packet, std::size_t length,
    const struct sockaddr_in &source) {
    if (length < 12) return;
    const std::uint16_t flags =
        static_cast<std::uint16_t>((packet[2] << 8) | packet[3]);
    if ((flags & 0x8000) != 0) return;              // 别人的应答，忽略
    const std::uint16_t question_count =
        static_cast<std::uint16_t>((packet[4] << 8) | packet[5]);
    if (question_count == 0) return;                // 别人的宣告，不是问我们
    // 本机地址不可用就不应答：任何一条能在"屏幕镜像"列表里出现的记录组合，
    // 都要求我们把服务宣告成可达的，而当前做不到（见 HasUsableAddress）。
    if (!HasUsableAddress()) return;

    std::size_t offset = 12;
    for (std::uint16_t i = 0; i < question_count; ++i) {
        Question question;
        if (!ParseName(packet, length, offset, question.name)) return;
        if (offset + 4 > length) return;
        question.type = static_cast<std::uint16_t>((packet[offset] << 8) | packet[offset + 1]);
        question.klass = static_cast<std::uint16_t>((packet[offset + 2] << 8) | packet[offset + 3]);
        offset += 4;

        RecordSet answers;
        RecordSet additionals;
        if (!BuildAnswerFor(question.name, question.type, answers, additionals)) {
            // 答不出来也要记账（见 NoteQuery 的说明）：iPhone 问 _airplay、
            // 而我们手里没有这个服务，是最需要被看见的一种故障，不能默默 continue。
            NoteQuery(question.name, question.type, source, false);
            continue;
        }
        const std::vector<std::uint8_t> packet =
            BuildMessage(&question, answers, additionals);
        // 应答**同时**发两路：
        //   ① 组播 —— mDNS 的常规形态，也是唯一能绕开"AP 客户端隔离"
        //      （专挡客户端之间的单播）和本机策略路由的路子；
        //   ② 单播回查询来源 —— QU 位查询要求的形态，也覆盖"组播被 IGMP
        //      snooping 剪掉"的网络。
        // 为什么必须双发：以前只发单播，而 `sendto` 成功只说明内核收下了包，
        // 不代表它真的进了 Wi-Fi 空口。"已应答 N 次、iPhone 仍搜不到"里就有
        // 这一整类假成功。两路都发之后，任一路可达都能让 iPhone 看到我们。
        const bool sent_multicast = SendPacket(packet, MulticastAddress());
        const bool sent_unicast = SendPacket(packet, source);
        const bool delivered = sent_multicast || sent_unicast;
        // 单播"会从哪个本地地址出去"由内核决定。策略路由/无默认路由的环境里它
        // 可能不是我们宣告的那张 Wi-Fi 网卡 —— 那样单播应答等于发进了别的网卡，
        // iPhone 永远收不到。把内核的选择记下来，让这件事可见。
        const std::string unicast_source = ProbeUnicastSource(source);
        NoteQuery(question.name, question.type, source, delivered);

        // 记账：谁问的 + 我们回的 A 记录是什么地址。这两个值合起来就能判定
        // "iPhone 搜不到"是"它压根没问"还是"我们回的地址它不认"。
        char origin_text[INET_ADDRSTRLEN] = {0};
        if (::inet_ntop(AF_INET, &source.sin_addr, origin_text,
                sizeof(origin_text)) == nullptr) {
            origin_text[0] = '\0';
        }
        std::string answer_ip;
        {
            std::lock_guard<std::mutex> lock(g_state_lock);
            answer_ip = g_local_ip;
        }
        {
            std::lock_guard<std::mutex> lock(g_diag_lock);
            g_last_answer_from = origin_text;
            g_last_answer_ip = answer_ip;
            // 把"应答从哪两路出、单播被内核判成哪个源地址"直接贴在这条查询后面：
            // 这是判定"应答到底有没有机会到 iPhone"的唯一进程内证据。
            g_last_query += " · 应答出包 组播";
            g_last_query += (sent_multicast ? "✓" : "✗");
            g_last_query += " 单播";
            g_last_query += (sent_unicast ? "✓" : "✗");
            g_last_query += " 单播源=";
            g_last_query += unicast_source.empty() ? std::string("?") : unicast_source;
        }

        // sendto 失败不计入"已应答" —— 计数只记真的送出去的，不记"我们试过"。
        if (delivered) {
            g_answered.fetch_add(1, std::memory_order_relaxed);
        }
    }
}

// 从收到的包反推「本机是哪个地址」，用于自我纠正 A 记录。
//
// 三个候选来源，按可信度从高到低：
//   ① **ifindex**（包从哪张网卡进来）→ 查那张网卡的真实 IPv4。首选：单播、组播
//      进来都成立，换网后也能自愈；
//   ② 目的地址（ipi_addr）—— 仅当它本身是合法单播地址时才可用。这只在 iPhone
//      把查询直接单播发到我们的 IP:5353 时才成立；
//   ③ 路由选出的本地地址（ipi_spec_dst）—— 不少内核在组播接收路径上给它填 0，
//      所以只当兜底。
//
// 切记：组播查询的 ipi_addr **恒等于 224.0.0.251**，拿它当本机地址就会把
// A 记录写成组播组地址（这就是"能搜到连不上 / 干脆搜不到"的根因）。
void LearnLocalIpFromPacket(int ifindex, const std::string &spec_dst,
    const std::string &destination) {
    const std::vector<IfaceEntry> entries = CachedInterfaces();

    std::string candidate;
    if (ifindex > 0) {
        for (const IfaceEntry &entry : entries) {
            if (entry.index != ifindex || entry.virtual_iface) continue;
            candidate = entry.ip;   // ReadInterfaceIpv4 已保证是合法单播地址
            break;
        }
    }
    if (candidate.empty() && IsUsableUnicastIpv4(spec_dst)) candidate = spec_dst;
    if (candidate.empty() && IsUsableUnicastIpv4(destination)) candidate = destination;
    if (candidate.empty()) return;
    if (IpBelongsToVirtualInterface(entries, candidate)) return;

    bool changed = false;
    {
        std::lock_guard<std::mutex> lock(g_state_lock);
        g_learned_ip = candidate;
        if (g_local_ip != candidate) {
            g_local_ip = candidate;
            changed = true;
        }
    }
    if (changed) {
        ApplyMulticastInterface(candidate);   // 换了网卡就换出口，否则宣告发不出去
        AnnounceAll(false);                  // 立刻用新地址重播，纠正别人的缓存
    }
}

// 周期性重算地址：网卡换了 IP、Wi-Fi 重连都能跟上。
void RefreshLocalAddress() {
    const std::vector<IfaceEntry> entries = CollectInterfaces();
    std::string learned;
    {
        std::lock_guard<std::mutex> lock(g_state_lock);
        if (!g_learned_ip.empty()) learned = g_learned_ip;
    }
    // 学到的地址如果已经不在本机了（换网），就丢掉重新按优先级挑。
    if (!learned.empty()) {
        bool still_ours = false;
        for (const IfaceEntry &entry : entries) {
            if (entry.ip == learned) still_ours = true;
        }
        if (!still_ours) {
            std::lock_guard<std::mutex> lock(g_state_lock);
            g_learned_ip.clear();
            learned.clear();
        }
    }
    const std::string picked = learned.empty() ? PickBestIpv4(entries) : learned;
    if (picked.empty()) return;

    bool changed = false;
    {
        std::lock_guard<std::mutex> lock(g_state_lock);
        if (g_local_ip != picked) {
            g_local_ip = picked;
            changed = true;
        }
    }
    if (changed) {
        ApplyMulticastInterface(picked);   // 换网（家庭 Wi-Fi ↔ 手机热点）后出口要跟着换
        AnnounceAll(false);
    }
}

// 消费队列里的待办：取走 → 真广播 → 回报。返回"是否新增/更新了服务"
// （调用方据此补几次重播，防单包丢失——原型就是连发 3 次才稳定被发现的）。
bool ConsumeDnssdQueue() {
    std::vector<int> published;
    im_dnssd_service_t incoming{};
    while (im_dnssd_queue_take_service_internal(&incoming)) {
        ServiceEntry entry;
        entry.id = incoming.id;
        entry.instance = incoming.name;
        entry.type = incoming.type;
        entry.port = incoming.port;
        entry.txt.assign(incoming.txt, incoming.txt + incoming.txt_length);
        {
            std::lock_guard<std::mutex> lock(g_state_lock);
            // 同一实例重复注册（重启接收端）就覆盖，别堆重复记录。
            bool replaced = false;
            for (ServiceEntry &existing : g_services) {
                if (existing.type == entry.type && existing.instance == entry.instance) {
                    existing = entry;
                    replaced = true;
                    break;
                }
            }
            if (!replaced) g_services.push_back(entry);
        }
        published.push_back(entry.id);
    }

    if (!published.empty()) {
        // 一次广播把这批服务全宣告出去（而不是每条一个包）。
        AnnounceAll(false);
        // 真发出去之后才回报成功 —— 队列统计因此反映真实广播状态。
        for (const int id : published) {
            im_dnssd_queue_report(id, 1, "");
        }
    }

    int removal_id = 0;
    while (im_dnssd_queue_take_removal_internal(&removal_id)) {
        ServiceEntry removed;
        bool found = false;
        {
            std::lock_guard<std::mutex> lock(g_state_lock);
            for (auto it = g_services.begin(); it != g_services.end(); ++it) {
                if (it->id == removal_id) {
                    removed = *it;
                    g_services.erase(it);
                    found = true;
                    break;
                }
            }
        }
        if (found) SendGoodbyeFor(removed);
    }

    return !published.empty();
}

// worker 线程：实际干活的循环放 WorkerMainLoop；WorkerMain 套 try/catch 兜底。
// 为什么拆函数：std::thread 的入口要求所调函数 noexcept，否则抛异常会 std::terminate。
// 拆开后我们对 WorkerMainLoop() 加常规 try/catch，把"抛异常"也写进 g_error。
// WorkerMainLoop 在同 namespace 后部定义，需前向声明。
void WorkerMainLoop();

void WorkerMain() {
    // std::thread 包装的函数没异常处理会 std::terminate，必须自己接住。
    // 现实里 OhosMdnsResponder 几乎不会抛异常，但万一某天改了 sendto/recvmsg
    // 改了 vector/类成员发生 move 异常，没这道兜底会**静默把进程戳死**，UI
    // 看不到任何输出，g_active 永远 true——和今天"假活"现象一样的盲区。
    try {
    WorkerMainLoop();
    } catch (const std::exception &e) {
        const std::int64_t last =
            g_worker_last_tick_ms.load(std::memory_order_relaxed);
        char buffer[256];
        if (last > 0) {
            const std::int64_t now = SteadyNowMs();
            const int seconds = static_cast<int>((now - last) / 1000);
            std::snprintf(buffer, sizeof(buffer),
                "原生 mDNS 工作线程抛异常退出（最后心跳 %d 秒前）：%s",
                seconds, e.what());
        } else {
            std::snprintf(buffer, sizeof(buffer),
                "原生 mDNS 工作线程抛异常退出：%s", e.what());
        }
        std::lock_guard<std::mutex> lock(g_state_lock);
        g_error = buffer;
        g_worker_last_tick_ms.store(0, std::memory_order_relaxed);
        if (!g_stop_requested.load(std::memory_order_acquire)) {
            g_active.store(false, std::memory_order_release);
        }
    } catch (...) {
        std::lock_guard<std::mutex> lock(g_state_lock);
        g_error = "原生 mDNS 工作线程抛未知异常退出";
        g_worker_last_tick_ms.store(0, std::memory_order_relaxed);
        if (!g_stop_requested.load(std::memory_order_acquire)) {
            g_active.store(false, std::memory_order_release);
        }
    }
}

void WorkerMainLoop() {
    auto last_announce = std::chrono::steady_clock::now();
    auto next_burst = last_announce;
    int burst_remaining = 0;
    // 进入循环即把心跳置一次，避免启动到第一次 poll 之间被 is_active() 误判。
    g_worker_last_tick_ms.store(SteadyNowMs(), std::memory_order_relaxed);
    while (!g_stop_requested.load(std::memory_order_acquire)) {
        if (ConsumeDnssdQueue()) {
            // 刚注册：上面已宣告过一次，再补 kRegistrationBurst-1 次。
            burst_remaining = kRegistrationBurst - 1;
            next_burst = std::chrono::steady_clock::now() +
                std::chrono::milliseconds(kBurstSpacingMs);
        }

        struct pollfd polled;
        polled.fd = g_socket;
        polled.events = POLLIN;
        polled.revents = 0;
        const int ready = ::poll(&polled, 1, kPollTimeoutMs);
        // 不论 ready 是 >0 =0 还是 -1，都得刷新心跳。否则健康检查永远显示"已 N 秒未 tick"。
        g_worker_last_tick_ms.store(SteadyNowMs(), std::memory_order_relaxed);
        if (ready > 0 && (polled.revents & POLLIN) != 0) {
            std::uint8_t buffer[4096];
            struct sockaddr_in source;
            std::memset(&source, 0, sizeof(source));
            struct iovec vector;
            vector.iov_base = buffer;
            vector.iov_len = sizeof(buffer);

            std::uint8_t control[256];
            struct msghdr message;
            std::memset(&message, 0, sizeof(message));
            message.msg_name = &source;
            message.msg_namelen = sizeof(source);
            message.msg_iov = &vector;
            message.msg_iovlen = 1;
            message.msg_control = control;
            message.msg_controllen = sizeof(control);

            const ssize_t received = ::recvmsg(g_socket, &message, 0);
            if (received > 0) {
                // 第一道自我过滤：来源是本机的包直接丢。
                // 为什么必须丢：这类包几乎都是我们自己发出的宣告被组播环回回来的，
                // 拿它去"学"本机地址就会形成「学 → 地址变了 → 重播 → 再被学」的
                // 反馈环 —— 实测就是 204 包/秒、同一实例三个 IP 的那次事故。
                // 顺便：我们也绝不应当回答自己。
                char origin[INET_ADDRSTRLEN] = {0};
                if (::inet_ntop(AF_INET, &source.sin_addr, origin, sizeof(origin)) != nullptr &&
                    IsLocalInterfaceAddress(std::string(origin))) {
                    // 计数留着，别默默丢。本机跑的任何探针（含
                    // tools/airplay_responder_probe.py --unicast）来源都是本机地址，
                    // 一律会走到这里被丢 —— 那个工具报的"0 应答"因此在
                    // g_dropped_self > 0 时**不能**用来判"响应器死了"。
                    g_dropped_self.fetch_add(1, std::memory_order_relaxed);
                    // 但"来源=本机"还有第二种解释，而且它比探针严重得多：
                    // 本机另有一个响应器在宣告同名服务，iPhone 会因记录冲突而
                    // 完全不显示设备。这条判据把它变成可见的（见函数注释）。
                    if (LooksLikeConflictingLocalResponse(buffer,
                            static_cast<std::size_t>(received))) {
                        std::lock_guard<std::mutex> lock(g_diag_lock);
                        ++g_conflicting_responder;
                        if (g_conflict_note.empty()) {
                            g_conflict_note =
                                " · ⚠ 检测到本机**另一个** mDNS 响应器在宣告同名服务"
                                "（它发来的包已被丢弃计数）——iPhone 会因记录冲突而"
                                "干脆不显示设备。请检查是否有残留的 "
                                "tools/mdns_responder_proto.py 或第二个 App 实例在跑";
                        }
                        g_query_counts += g_conflict_note;
                    }
                    continue;
                }
#ifdef IP_PKTINFO
                // **先学地址、再应答**。顺序反了的话，第一个查询会在 g_local_ip
                // 还不可用时被丢掉，得等 iPhone 下一次浏览才发现我们（数秒延迟）。
                // 现在首包就能用刚学到的真实地址回。
                for (struct cmsghdr *header = CMSG_FIRSTHDR(&message);
                     header != nullptr; header = CMSG_NXTHDR(&message, header)) {
                    if (header->cmsg_level != IPPROTO_IP ||
                        header->cmsg_type != IP_PKTINFO) {
                        continue;
                    }
                    struct in_pktinfo info;
                    std::memcpy(&info, CMSG_DATA(header), sizeof(info));
                    char spec_text[INET_ADDRSTRLEN] = {0};
                    char dest_text[INET_ADDRSTRLEN] = {0};
                    ::inet_ntop(AF_INET, &info.ipi_spec_dst, spec_text,
                        sizeof(spec_text));
                    ::inet_ntop(AF_INET, &info.ipi_addr, dest_text,
                        sizeof(dest_text));
                    // 主要靠 ipi_ifindex 反查网卡地址；组播包的 ipi_addr 是
                    // 224.0.0.251，只有 LearnLocalIpFromPacket 内部会把它
                    // 当"合法单播才采纳"，不能在这里直接当本机地址用。
                    LearnLocalIpFromPacket(info.ipi_ifindex,
                        std::string(spec_text), std::string(dest_text));
                }
#endif
                HandleQueryPacket(buffer, static_cast<std::size_t>(received), source);
            }
        }

        const auto now = std::chrono::steady_clock::now();
        if (burst_remaining > 0 && now >= next_burst) {
            AnnounceAll(false);
            --burst_remaining;
            next_burst = now + std::chrono::milliseconds(kBurstSpacingMs);
        }
        if (std::chrono::duration_cast<std::chrono::seconds>(now - last_announce).count() >=
            kAnnounceIntervalSeconds) {
            RefreshLocalAddress();
            AnnounceAll(false);
            last_announce = now;
        }
    }

    // 退出前撤销宣告：iPhone 的列表里会立刻消失，而不是等缓存过期。
    {
        const Snapshot snapshot = TakeSnapshot();
        for (const ServiceEntry &service : snapshot.services) {
            SendGoodbyeFor(service);
        }
    }

    // 分两种退出原因：
    //   a) 外部显式 stop_requested=true —— stop() 那边已经收 join、清 g_active。
    //   b) 循环内被异常/中断/recvmsg errno 等带走 —— g_active 没人动，会假活。
    // 对 b)，我们把 g_active 强行置 false、把 last_tick 清掉、并把"非预期退出
    // 原因 + 时间"写进 g_error，让 UI 自动跳到 "mDNS 广播未生效：xxx" 分支。
    if (!g_stop_requested.load(std::memory_order_acquire)) {
        const std::int64_t last = g_worker_last_tick_ms.load(std::memory_order_relaxed);
        char buffer[200];
        if (last > 0) {
            const std::int64_t now = SteadyNowMs();
            const int seconds = static_cast<int>((now - last) / 1000);
            std::snprintf(buffer, sizeof(buffer),
                "原生 mDNS 工作线程非预期退出（最后一次心跳 %d 秒前；通常是 App 被系统冻结）",
                seconds);
        } else {
            std::snprintf(buffer, sizeof(buffer),
                "原生 mDNS 工作线程非预期退出（启动后从未到过 poll 阶段）");
        }
        std::lock_guard<std::mutex> lock(g_state_lock);
        g_error = buffer;
        g_worker_last_tick_ms.store(0, std::memory_order_relaxed);
        g_active.store(false, std::memory_order_release);
    }
}

std::string BuildHostLabel() {
    char mac[32] = {0};
    if (im_ohos_primary_mac(mac, sizeof(mac)) == 0) {
        const std::string text(mac);
        std::string digits;
        for (char character : text) {
            if (character != ':') digits.push_back(character);
        }
        if (digits.size() >= 6) {
            // mDNS 主机名 SHOULD 小写（RFC 6762 §3）。原型用纯小写
            // "iphonemirror.local" 能被 iPhone 发现；混合大小写可能在 iOS
            // 的 DNS-SD 缓存一致性校验中出问题。MAC 后缀也转小写。
            std::string suffix = digits.substr(digits.size() - 6);
            for (char &c : suffix) {
                if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
            }
            return "iphonemirror-" + suffix;
        }
    }
    return "iphonemirror";
}

} // namespace

// ─────────────────────────── C ABI ───────────────────────────

int im_ohos_primary_mac(char *out, unsigned int capacity) {
    if (out == nullptr || capacity < 18) return -1;
    const std::vector<IfaceEntry> entries = CollectInterfaces();
    // 优先挑"我们正在广播其 IP 的那张网卡"，保证 deviceid / mDNS 主机名
    // 与 A 记录同源——三者若来自不同网卡，iPhone 解析出来的地址就会串台。
    const std::string best_ip = PickBestIpv4(entries);
    const IfaceEntry *chosen = nullptr;
    for (const IfaceEntry &entry : entries) {
        if (!entry.virtual_iface && !entry.mac.empty() && entry.ip == best_ip) {
            chosen = &entry;
            break;
        }
    }
    if (chosen == nullptr) {
        for (const IfaceEntry &entry : entries) {
            if (!entry.virtual_iface && !entry.mac.empty()) {
                chosen = &entry;
                break;
            }
        }
    }
    if (chosen == nullptr) {
        for (const IfaceEntry &entry : entries) {
            if (!entry.mac.empty()) {
                chosen = &entry;
                break;
            }
        }
    }
    if (chosen == nullptr) return -1;
    std::snprintf(out, capacity, "%s", chosen->mac.c_str());
    return 0;
}

int im_mdns_responder_start(void) {
    std::lock_guard<std::mutex> lifecycle_lock(g_lifecycle_lock);
    if (g_active.load(std::memory_order_acquire)) return 0;

    {
        std::lock_guard<std::mutex> lock(g_state_lock);
        g_services.clear();
        g_learned_ip.clear();
        g_local_ip.clear();
        g_host_label = BuildHostLabel();
        g_error.clear();
    }
    g_answered.store(0, std::memory_order_relaxed);
    // 查询账本也要跟着归零：否则"已应答 4 次"是上一轮留下的、而这一轮其实
    // 一条都没收到——那是这个工程反复踩的累计值假成功。
    {
        std::lock_guard<std::mutex> lock(g_diag_lock);
        g_last_query.clear();
        g_query_counts.clear();
        g_unanswered_ring.clear();
        g_conflicting_responder = 0;
        g_conflict_note.clear();
        for (int index = 0; index < 4; ++index) {
            g_query_kind[index] = 0;
            g_query_answered_kind[index] = 0;
        }
    }

    const int descriptor = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (descriptor < 0) {
        std::lock_guard<std::mutex> lock(g_state_lock);
        g_error = DescribeErrno("socket(AF_INET)");
        return -1;
    }
    int enable = 1;
    ::setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &enable, sizeof(enable));
    // SO_REUSEPORT 让本响应器与系统/调试工具共享 5353 而不互相 bind 失败；
    // 本机已确认该选项可用。
    ::setsockopt(descriptor, SOL_SOCKET, SO_REUSEPORT, &enable, sizeof(enable));

    struct sockaddr_in bind_address;
    std::memset(&bind_address, 0, sizeof(bind_address));
    bind_address.sin_family = AF_INET;
    bind_address.sin_addr.s_addr = htonl(INADDR_ANY);
    bind_address.sin_port = htons(kMdnsPort);
    if (::bind(descriptor,
            reinterpret_cast<const struct sockaddr *>(&bind_address),
            sizeof(bind_address)) < 0) {
        std::lock_guard<std::mutex> lock(g_state_lock);
        g_error = DescribeErrno("绑定 UDP 5353");
        ::close(descriptor);
        return -1;
    }

    // 加入组播：先按 INADDR_ANY（内核选出口），再按最佳网卡各加一次，
    // 多宿主环境下两边的查询都能收到。
    const std::vector<IfaceEntry> entries = CollectInterfaces();
    const std::string best_ip = PickBestIpv4(entries);
    // 一个可用地址都拿不到 → **直接失败**，不"假成功"启动。响应器起来了却宣告不出
    // 可达地址，iPhone 只会看到一台连不上的设备（或干脆看不到），而 UI 却会显示
    // "已在局域网广播"，把真正的病根藏起来。返回 -1 后失败原因会经 mdns_error
    // 显示到状态行（通常是 Wi-Fi 没连上）。
    {
        std::vector<std::uint8_t> probe;
        if (best_ip.empty() || !EncodeAddress(best_ip, probe)) {
            std::lock_guard<std::mutex> lock(g_state_lock);
            g_error = "无法确定本机局域网 IPv4（网卡未连接或地址不可用）";
            ::close(descriptor);
            return -1;
        }
    }
    for (const std::string &iface_ip : {std::string("0.0.0.0"), best_ip}) {
        if (iface_ip.empty()) continue;
        struct ip_mreq request;
        std::memset(&request, 0, sizeof(request));
        ::inet_pton(AF_INET, kMulticastGroup, &request.imr_multiaddr);
        ::inet_pton(AF_INET, iface_ip.c_str(), &request.imr_interface);
        ::setsockopt(descriptor, IPPROTO_IP, IP_ADD_MEMBERSHIP, &request,
            sizeof(request));
    }

    unsigned char ttl = 255;
    ::setsockopt(descriptor, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof(ttl));
    // **必须关掉组播环回**。开着的话我们自己发出的每一份宣告都会被送回自己的
    // socket；历史上就是靠这些包"学"本机地址，形成了 204 包/秒的宣告风暴，
    // 把同一实例宣告成三个不同 IP。我们没有任何需要听见自己的场景，关掉最干净。
    const int no_loop = 0;
    ::setsockopt(descriptor, IPPROTO_IP, IP_MULTICAST_LOOP, &no_loop, sizeof(no_loop));
#ifdef IP_PKTINFO
    // 打开后才拿得到"包是发往本机哪个地址的"，用于自我纠正 A 记录。
    ::setsockopt(descriptor, IPPROTO_IP, IP_PKTINFO, &enable, sizeof(enable));
#endif

    {
        std::lock_guard<std::mutex> lock(g_state_lock);
        g_local_ip = best_ip;
    }

    g_socket = descriptor;
    // 出向组播绑到最佳网卡（见 ApplyMulticastInterface 的说明）。
    ApplyMulticastInterface(best_ip);
    g_stop_requested.store(false, std::memory_order_release);
    g_worker = std::thread(WorkerMain);
    g_active.store(true, std::memory_order_release);
    // 队列交给原生响应器消费：ArkTS 的 take_service/take_removal 从此返回空，
    // 避免两个消费者抢同一条待办。
    im_dnssd_queue_set_native_backend(1);
    return 0;
}

void im_mdns_responder_stop(void) {
    std::lock_guard<std::mutex> lifecycle_lock(g_lifecycle_lock);
    if (!g_active.load(std::memory_order_acquire)) {
        im_dnssd_queue_set_native_backend(0);
        return;
    }
    g_stop_requested.store(true, std::memory_order_release);
    if (g_worker.joinable()) g_worker.join();

    if (g_socket >= 0) {
        ::close(g_socket);
        g_socket = -1;
    }
    {
        std::lock_guard<std::mutex> lock(g_state_lock);
        g_services.clear();
        g_learned_ip.clear();
        g_local_ip.clear();
    }
    g_active.store(false, std::memory_order_release);
    im_dnssd_queue_set_native_backend(0);
}

int im_mdns_responder_is_active(void) {
    // "启动过" 不等于 "现在活着"。g_active 只在 start()/stop() 时被改，对
    // OHOS 后台冻结、socket 被系统接管、worker 抛异常自然结束等场景全不感知。
    // 必须用 worker 心跳时间戳校验：超过 5 秒没轮询即认为已被冻结/已死。
    // 写一次性的 g_error，让 UI 端无线卡片的 mdnsError 分支显示出来。
    if (!g_active.load(std::memory_order_acquire)) return 0;
    const std::int64_t last =
        g_worker_last_tick_ms.load(std::memory_order_acquire);
    if (last == 0) return 0;        // worker 还没进第一次 poll 就要被问
    const std::int64_t now = SteadyNowMs();
    const std::int64_t gap = now - last;
    if (gap > 5000) {
        static std::atomic<int> warned{0};
        if (warned.exchange(1) == 0) {
            char buffer[200];
            std::snprintf(buffer, sizeof(buffer),
                "原生 mDNS 工作线程已 %lld 秒未轮询（最近 %lldms），通常是被系统冻结"
                "；请确认 App 的「后台长时任务」已申请成功且 App 切到后台后能保活",
                static_cast<long long>(gap / 1000), static_cast<long long>(gap));
            std::lock_guard<std::mutex> lock(g_state_lock);
            g_error = buffer;
        }
        return 0;
    }
    return 1;
}

// 最近一次 worker tick 时间（ms，steady_clock 内部 epoch，仅同进程内可比）。
// UI 层用「now - last_tick_ms」给用户报心跳新鲜度，比单一 active bit 强得多。
std::int64_t im_mdns_responder_last_tick_ms(void) {
    return g_worker_last_tick_ms.load(std::memory_order_acquire);
}

// 清掉"心跳超时"那种一次性的告警，让用户重新点应用/停用后状态可重置。
// 不清的话下一次即便正常也仍处于"广播异常"分支。
void im_mdns_responder_clear_health_warning(void) {
    static std::atomic<int> warned{0};
    warned.store(0, std::memory_order_release);
    // 不要清 g_error —— 那个字段是给 UI 看原因的，应该等用户看见后再清。
    // 但其实同步清掉"心跳超时"那段也行，让 UI 能立即切换到正常分支。
}

const char *im_mdns_responder_error(void) {
    static thread_local std::string buffer;
    std::lock_guard<std::mutex> lock(g_state_lock);
    buffer = g_error;
    return buffer.c_str();
}

const char *im_mdns_responder_local_ip(void) {
    static thread_local std::string buffer;
    std::lock_guard<std::mutex> lock(g_state_lock);
    // 最后一道闸：对外只报"可路由的单播地址"。历史上这里曾把 IP_PKTINFO 的
    // ipi_addr（组播查询下恒为 224.0.0.251）当本机 IP 报出去，UI 于是显示
    // "本机 224.0.0.251"、A 记录指向组播组，iPhone 先"搜到连不上"再"搜不到"。
    // 现在只要不满足单播条件，一律报空 —— UI 会走"A 记录为空"那条明确提示。
    buffer = IsUsableUnicastIpv4(g_local_ip) ? g_local_ip : std::string();
    return buffer.c_str();
}

const char *im_mdns_responder_hostname(void) {
    static thread_local std::string buffer;
    std::lock_guard<std::mutex> lock(g_state_lock);
    buffer = g_host_label + ".local";
    return buffer.c_str();
}

uint64_t im_mdns_responder_answered_queries(void) {
    return g_answered.load(std::memory_order_relaxed);
}

// ── 诊断出口（2026-09-19：真机"已应答 4 次、iPhone 搜不到"）──
//
// 这五个值合起来能一次判定故障落在哪一段，不需要抓包（也抓不到：组播不回环）：
//   dropped_self > 0        ⇒ 本机探针的 0 应答是自家闸门造成的，不代表响应器死了
//   announce_sent 一直为 0   ⇒ 压根没往外宣告（服务没注册上 / 节流掐了）
//   announce_failed > 0     ⇒ 宣告 sendto 就失败了（网卡/路由问题）
//   outbound_iface 不是 Wi-Fi 地址 ⇒ 注释里预言的那个症状成立：宣告走虚拟网卡出不去，
//                                    而单播应答照常 ⇒ "已应答 N 次却搜不到"
//   last_answer_from        ⇒ 到底是谁在问我们。若是 iPhone 的地址，说明它问过、
//                              我们也答了，问题在**应答内容**（A 记录/端口/TXT/model）
uint64_t im_mdns_responder_dropped_self(void) {
    return g_dropped_self.load(std::memory_order_relaxed);
}

uint64_t im_mdns_responder_announce_sent(void) {
    return g_announce_sent.load(std::memory_order_relaxed);
}

uint64_t im_mdns_responder_announce_failed(void) {
    return g_announce_failed.load(std::memory_order_relaxed);
}

const char *im_mdns_responder_outbound_iface(void) {
    static thread_local std::string buffer;
    std::lock_guard<std::mutex> lock(g_diag_lock);
    buffer = g_outbound_iface;
    return buffer.c_str();
}

const char *im_mdns_responder_last_answer_from(void) {
    static thread_local std::string buffer;
    std::lock_guard<std::mutex> lock(g_diag_lock);
    buffer = g_last_answer_from;
    return buffer.c_str();
}

const char *im_mdns_responder_last_answer_ip(void) {
    static thread_local std::string buffer;
    std::lock_guard<std::mutex> lock(g_diag_lock);
    buffer = g_last_answer_ip;
    return buffer.c_str();
}

// ── "问了什么 / 我们手里有什么"（判读见 OhosMdnsResponder.h）──

const char *im_mdns_responder_last_query(void) {
    static thread_local std::string buffer;
    std::lock_guard<std::mutex> lock(g_diag_lock);
    buffer = g_last_query.empty()
        ? std::string("（本次运行还没收到任何查询）")
        : g_last_query;
    return buffer.c_str();
}

const char *im_mdns_responder_query_counts(void) {
    static thread_local std::string buffer;
    std::lock_guard<std::mutex> lock(g_diag_lock);
    buffer = g_query_counts.empty() ? std::string("（0）") : g_query_counts;
    return buffer.c_str();
}

const char *im_mdns_responder_service_list(void) {
    static thread_local std::string buffer;
    const std::string services = BuildServiceListText();
    buffer = services.empty()
        ? std::string("（空的：一条服务都没注册上，宣告必然无效）")
        : services;
    return buffer.c_str();
}
