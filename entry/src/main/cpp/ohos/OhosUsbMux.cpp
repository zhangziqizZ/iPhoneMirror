// SPDX-License-Identifier: GPL-3.0-only
//
// 鸿蒙上的 usbmux 设备侧协议栈（直连 iPhone，不经过 usbmuxd 守护进程）。
//
// ★ 为什么需要它：iOS 的「信任此电脑」弹窗只在一个时刻出现 —— 主机通过
//   usbmux 隧道连到设备的 lockdownd(62078) 后**主动发 Pair 请求**。上游
//   Windows/Linux 版靠系统里的 usbmuxd 守护进程发这个请求；鸿蒙系统不带
//   usbmuxd，所以本工程必须自己当"usbmuxd"，直接用 USB DDK 讲 iPhone 侧的
//   usbmux 协议，才能把弹窗逼出来。详见 OhosDeviceManager.cpp 里的说明。
//
// ── 协议分层（本文件实现的是最下面两层）────────────────────────────
//
//   [lockdownd 报文]  4 字节大端长度 + XML plist          （Core/DeviceManager.cpp）
//   [伪 TCP 隧道]    mux_header + tcphdr + 载荷
//   [usbmux over USB] mux_header + 版本握手
//
// ── 字节序（最容易搞错的一处）────────────────────────────────────
//
// USB 侧的 mux_header 与 tcphdr **全部是网络序（大端）**，与"客户端 ↔
// usbmuxd 守护进程"那一层的小端 usbmuxd_header 正好相反。两层混用是这类
// 协议最经典的坑，所以这里在代码里显式用 htonl/htons 标注每一个字段。
//
// 依据：usbmuxd 的 src/device.c（上游实现）。关键片段：
//
//   struct mux_header {
//       uint32_t protocol;   // htonl
//       uint32_t length;     // htonl，**含 mux_header 自身**的总长
//       uint32_t magic;      // htonl，0xfeedface（仅 v2）
//       uint16_t tx_seq;     // htons
//       uint16_t rx_seq;     // htons
//   };
//
//   int mux_header_size = ((dev->version < 2) ? 8 : sizeof(struct mux_header));
//
//   // 首包用 8 字节头（只有 protocol+length），收到设备的版本包后
//   // 若 major>=2 才切到 16 字节头并补发 SETUP(0x07)。
//
// ── 一个反直觉但重要的细节 ───────────────────────────────────────
//
// **主机先发 VERSION**，而不是等设备先发。usbmuxd 的 device_add() 里
// vh.major=2 / vh.minor=0 是主机主动发出的版本请求；设备回一个版本包，
// 主机据此决定后续用 8 字节还是 16 字节头。
//
// ── 伪 TCP ───────────────────────────────────────────────────────
//
// 隧道里跑的是标准 20 字节 tcphdr（网络序），但只用了 SEQ/ACK/窗口/标志，
// 没有校验和、没有重传。握手固定为 SYN → SYN|ACK → ACK：
//
//   * th_dport = htons(62078)  ← lockdownd 端口，注意是**网络序**
//   * th_off   = (20/4) << 4 = 0x50
//     ★ th_off 占字节的**高 4 位**（低 4 位是保留位）★
//     写成 5（0x05）会让设备把头长算成 0 → 报文错位 → 判为坏包 → RST。
//   * th_win   = htons(tx_win >> 8)   ← 窗口按 8 位缩放，usbmuxd 固定 131072
//   * 收到 SYN|ACK 后主机补一个纯 ACK，并把 tx_seq/tx_ack 各推进 1
//
// 与真 TCP 不同的是：这个"TCP"不会重传也不会乱序确认，序号错了设备侧
// 会直接丢包，所以下面 send_tcp() 的序号推进必须与 usbmuxd 完全一致。
//
// ── 收发分片 ─────────────────────────────────────────────────────
//
// 一个 mux 报文可能大于一次 bulk IN 的返回量。usbmuxd 用 DEV_MRU(64KB)
// 缓冲拼包，判断依据是 mux_header.length 字段：**length 含头**，所以
// 收到多少字节都不够时按 length 继续攒。下面 rxBuffer_ 就是干这个的。

#include "OhosUsbMux.h"

#include "Logging.h"
#include "OhosUsbDiagnostics.h"
#include "OhosUsbFdDevice.h"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <format>
#include <optional>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include <arpa/inet.h>

#if IM_OHOS_USB_DDK_AVAILABLE
#  include <usb/usb_ddk_types.h>
#endif

namespace iPhoneMirror::ohos {
namespace {

// usbmux 设备侧协议常量（依据 usbmuxd src/device.c）。
enum : std::uint32_t {
    MuxProtoVersion = 0,
    MuxProtoControl = 1,
    MuxProtoSetup = 2,
    MuxProtoTcp = 6,
};

// usbmuxd 的 USB_MTU。单个 mux 报文不得超过它。
constexpr std::uint32_t UsbMtu = 49152;
// usbmuxd 的 DEV_MRU：拼包缓冲上限。
constexpr std::size_t DevMru = 65536;

// 伪 TCP 固定窗口。usbmuxd 用 131072 字节，写进 tcphdr 时右移 8 位。
constexpr std::uint32_t TcpTxWindow = 131072;

// 伪 TCP 头长（字节）。标准 tcphdr 固定 20 字节。
constexpr std::size_t TcpHeaderLength = 20;

// ★ th_off 的线缆编码值 ★
//
// th_off 是 4 bit 的数据偏移，**占字节的高 4 位**（低 4 位是保留位）。
// 20 字节头 → 偏移 5 → 编码值 5 << 4 = 0x50。
//
// 写 5（0x05）会让设备按高 4 位解析出"头长 0"，整条报文错位 → RST。
// 上游 tools/iostouch/qt/usbmux_usb.py 用的就是这个值：
//   (TCP_HDR_LEN // 4) << 4
constexpr std::uint8_t TcpHeaderOffset =
    static_cast<std::uint8_t>((TcpHeaderLength / 4) << 4);

// ★ 编译期锁定这个不变量 ★
//
// 这个值一旦被改回 5，症状是"设备拒绝连接端口 62078（RST）"——
// 与网络、权限、锁定状态都无关，纯粹是线缆编码错误，极难从现象反推。
// 用 static_assert 把正确值钉死，改错了直接编译不过。
static_assert(TcpHeaderOffset == 0x50,
    "usbmux 伪 TCP 的 th_off 必须编码在高 4 位（0x50），"
    "写成 5（0x05）会让设备把头长算成 0 → SYN 被判为坏包 → 回 RST");

// usbmuxd 的最大载荷 = USB_MTU - sizeof(mux_header) - sizeof(tcphdr)。
constexpr std::size_t MaxTcpPayload = UsbMtu - 16 - 20;

// TCP 标志位（与 netinet/tcp.h 一致）。
enum : std::uint8_t {
    ThFin = 0x01,
    ThSyn = 0x02,
    ThRst = 0x04,
    ThPsh = 0x08,
    ThAck = 0x10,
};

// 大端写入工具。全部走 htonl/htons，避免手写移位时把字节序搞反。
// ★ 协议层与后端无关，必须无条件编译（fd 后端也要用）★
void put_u32be(std::vector<std::uint8_t>& out, std::uint32_t value) {
    const std::uint32_t net = htonl(value);
    out.push_back(static_cast<std::uint8_t>(net & 0xFFU));
    out.push_back(static_cast<std::uint8_t>((net >> 8U) & 0xFFU));
    out.push_back(static_cast<std::uint8_t>((net >> 16U) & 0xFFU));
    out.push_back(static_cast<std::uint8_t>((net >> 24U) & 0xFFU));
}

void put_u16be(std::vector<std::uint8_t>& out, std::uint16_t value) {
    const std::uint16_t net = htons(value);
    out.push_back(static_cast<std::uint8_t>(net & 0xFFU));
    out.push_back(static_cast<std::uint8_t>((net >> 8U) & 0xFFU));
}

std::uint32_t get_u32be(const std::uint8_t* bytes) noexcept {
    return ntohl(static_cast<std::uint32_t>(bytes[0]) |
        (static_cast<std::uint32_t>(bytes[1]) << 8U) |
        (static_cast<std::uint32_t>(bytes[2]) << 16U) |
        (static_cast<std::uint32_t>(bytes[3]) << 24U));
}

std::uint16_t get_u16be(const std::uint8_t* bytes) noexcept {
    return ntohs(static_cast<std::uint16_t>(
        static_cast<std::uint16_t>(bytes[0]) |
        (static_cast<std::uint16_t>(bytes[1]) << 8U)));
}

// DDK 专属的枚举/认领/诊断助手从这里开始。fd 后端不依赖它们。
#if IM_OHOS_USB_DDK_AVAILABLE

// 从配置描述符里找出 usbmux 接口及其 bulk 端点。
//
// ★ 匹配规则用上游的 OR 口径 ★（详见下面 find_mux_endpoints 里的说明）：
//   class==0xFF || subclass==0xFE || protocol==2
//
// 为什么要自己找：OhosUsbTransport.cpp 已经识别过这个接口（0xFF/0xFE），但
// 那是为**采集**（0x2A）准备的，两者是同一设备上的不同接口，不能复用句柄。
// 配对走的是 usbmux 接口本身，必须单独认领。
//
// 返回**候选列表**而不是单个结果，理由是配置归属：
//   · 一台 iPhone 有多个配置，"PTP + Apple Mobile Device"、"…+ Vale"（采集）
//     等每个配置里都可能出现 0xFF/0xFE 接口，而**端点地址不一定相同**；
//   · DDK 的 OH_Usb_ClaimInterface 认领的是**当前活动配置**下的接口，
//     拿另一个配置的端点去认，认到的可能是错的端点甚至认不到；
//   · 采集路径发过厂商 0x52 之后，设备已经切到采集配置，这时"描述符里
//     第一个 0xFF/0xFE"未必就是活动配置里的那一个。
//
// 所以做法是：把各配置里的候选都收集起来，活动配置里的排最前，认领失败
// 就退到下一个候选。宁可多认几次，也不要拿错端点。
struct MuxEndpoints {
    std::uint8_t configuration{};
    std::uint8_t interface_number{};
    std::uint8_t alternate_setting{};
    std::uint8_t bulk_in{};
    std::uint8_t bulk_out{};
};

std::vector<MuxEndpoints> find_mux_endpoints(std::uint64_t device_id,
    std::uint8_t active_configuration) {
    // ★★★ 接口匹配用上游的 **OR** 规则，不是 AND ★★★
    //
    // 上游 usbmuxd 的 src/usb.c set_valid_configuration()：
    //   if(intf->bInterfaceClass == INTERFACE_CLASS ||
    //      intf->bInterfaceSubClass == INTERFACE_SUBCLASS ||
    //      intf->bInterfaceProtocol == INTERFACE_PROTOCOL) {
    // 而 src/usb.h 里：
    //   #define INTERFACE_CLASS    255   // 0xFF
    //   #define INTERFACE_SUBCLASS 254   // 0xFE
    //   #define INTERFACE_PROTOCOL 2
    //
    // ★ 三个条件是「或」关系，任一命中就算候选 ★
    //   本工程原先用的是 AND（class==0xFF && subclass==0xFE），比上游严格：
    //   一旦设备把 usbmux 接口报成别的 class/subclass 组合（比如只设了
    //   protocol=2 而 class/subclass 不同），AND 就一个都匹配不上，
    //   find_mux_endpoints 返回空 → connect() 直接失败并报
    //   「设备没有暴露 usbmux 接口」—— 表现正是"插线没反应"。
    //
    // ★ 上游还额外要求端点恰好是 2 个，且方向是 OUT+IN（顺序可交换）★★
    //   本工程用「必须同时有 bulk IN 和 bulk OUT」来表达同一件事，
    //   语义等价且不依赖端点在描述符里的排列顺序。
    constexpr std::uint8_t VendorInterfaceClass = 0xFF;
    constexpr std::uint8_t UsbMuxSubclass = 0xFE;
    constexpr std::uint8_t UsbMuxProtocol = 2;
    std::vector<MuxEndpoints> found;
    for (std::uint8_t index = 0; index < 8; ++index) {
        UsbDdkConfigDescriptor* config = nullptr;
        if (OH_Usb_GetConfigDescriptor(device_id, index, &config) != 0 ||
            config == nullptr) {
            if (config != nullptr) OH_Usb_FreeConfigDescriptor(config);
            if (index == 0) {
                // index 0 失败时再试 index 1（与 OhosUsbTransport.cpp 同一口径：
                // SDK 头文件把 configIndex 注为 bConfigurationValue，与标准的
                // 0 基索引不一致，两者都要试）。
                continue;
            }
            break;
        }
        const std::uint8_t configuration = config->configDescriptor.bConfigurationValue;
        for (std::uint8_t interface_index = 0;
             interface_index < config->configDescriptor.bNumInterfaces;
             ++interface_index) {
            const UsbDdkInterface& interface = config->interface[interface_index];
            for (std::uint8_t alt = 0; alt < interface.numAltsetting; ++alt) {
                const UsbDdkInterfaceDescriptor& descriptor =
                    interface.altsetting[alt];
                const std::uint8_t interface_class =
                    descriptor.interfaceDescriptor.bInterfaceClass;
                const std::uint8_t interface_subclass =
                    descriptor.interfaceDescriptor.bInterfaceSubClass;
                const std::uint8_t interface_protocol =
                    descriptor.interfaceDescriptor.bInterfaceProtocol;
                if (interface_class != VendorInterfaceClass &&
                    interface_subclass != UsbMuxSubclass &&
                    interface_protocol != UsbMuxProtocol) {
                    continue;
                }
                MuxEndpoints endpoints;
                endpoints.configuration = configuration;
                endpoints.interface_number =
                    descriptor.interfaceDescriptor.bInterfaceNumber;
                endpoints.alternate_setting =
                    descriptor.interfaceDescriptor.bAlternateSetting;
                for (std::uint8_t ep = 0;
                     ep < descriptor.interfaceDescriptor.bNumEndpoints; ++ep) {
                    const UsbEndpointDescriptor& endpoint =
                        descriptor.endPoint[ep].endpointDescriptor;
                    if ((endpoint.bmAttributes & 0x03U) != 0x02U) continue;
                    if ((endpoint.bEndpointAddress & 0x80U) != 0) {
                        endpoints.bulk_in = endpoint.bEndpointAddress;
                    } else {
                        endpoints.bulk_out = endpoint.bEndpointAddress;
                    }
                }
                // 一个 IN 一个 OUT 齐全才算可用。usbmuxd 的 usb.c 也是这么筛的
                // （"Endpoint type mismatch for interface"）。
                if (endpoints.bulk_in != 0 && endpoints.bulk_out != 0) {
                    found.push_back(endpoints);
                }
            }
        }
        OH_Usb_FreeConfigDescriptor(config);
    }
    // 活动配置里的候选排前面：DDK 认领的是活动配置下的接口，先试它。
    std::stable_sort(found.begin(), found.end(),
        [active_configuration](const MuxEndpoints& left, const MuxEndpoints& right) {
            const bool left_active = left.configuration == active_configuration;
            const bool right_active = right.configuration == active_configuration;
            if (left_active != right_active) return left_active;
            return false;
        });
    return found;
}

// 把设备描述符里的所有接口列进诊断日志。
//
// 用途：find_mux_endpoints() 返回空时，光说"没找到 usbmux 接口"是不够的 ——
// 真机排障需要知道**设备到底暴露了什么**，才能分辨是：
//   · 接口形态与预期不同（class/subclass/protocol 三者都不匹配）
//   · 接口匹配但端点不成对（缺 bulk IN 或 bulk OUT）
//   · 描述符根本读不到（索引口径不对 / 设备没响应）
//
// 只读，不认领任何接口。
void describe_interfaces(std::uint64_t device_id) {
    for (std::uint8_t index = 0; index < 8; ++index) {
        UsbDdkConfigDescriptor* config = nullptr;
        const int code = OH_Usb_GetConfigDescriptor(device_id, index, &config);
        if (code != 0 || config == nullptr) {
            if (config != nullptr) OH_Usb_FreeConfigDescriptor(config);
            if (index == 0) continue;   // 与 find_mux_endpoints 同一口径
            break;
        }
        const std::uint8_t configuration =
            config->configDescriptor.bConfigurationValue;
        for (std::uint8_t interface_index = 0;
             interface_index < config->configDescriptor.bNumInterfaces;
             ++interface_index) {
            const UsbDdkInterface& interface = config->interface[interface_index];
            for (std::uint8_t alt = 0; alt < interface.numAltsetting; ++alt) {
                const UsbDdkInterfaceDescriptor& descriptor =
                    interface.altsetting[alt];
                const std::uint8_t in = descriptor.interfaceDescriptor.bInterfaceClass;
                const std::uint8_t sub =
                    descriptor.interfaceDescriptor.bInterfaceSubClass;
                const std::uint8_t proto =
                    descriptor.interfaceDescriptor.bInterfaceProtocol;
                std::string endpoints;
                for (std::uint8_t ep = 0;
                     ep < descriptor.interfaceDescriptor.bNumEndpoints; ++ep) {
                    const UsbEndpointDescriptor& endpoint =
                        descriptor.endPoint[ep].endpointDescriptor;
                    endpoints += std::format(" [0x{:02x} attr=0x{:02x}]",
                        endpoint.bEndpointAddress, endpoint.bmAttributes);
                }
                ohos_usb_diag::note(std::format(
                    "  配置={} 接口={} alt={} class=0x{:02x} subclass=0x{:02x} "
                    "protocol={} 端点:{}",
                    configuration,
                    descriptor.interfaceDescriptor.bInterfaceNumber, alt,
                    in, sub, proto,
                    endpoints.empty() ? "(无)" : endpoints));
            }
        }
        OH_Usb_FreeConfigDescriptor(config);
    }
}

// 读设备当前激活的配置值（标准请求 GET_CONFIGURATION，bRequest=8）。
//
// 需要一个已认领的接口句柄才能发控制请求，所以这里临时认领接口 0（借用
// OhosUsbTransport.cpp 的同一手法），读完立刻释放。读不到时返回 nullopt ——
// 调用方据此走"不排序、按认领成败回退"的路径，而不是假装知道。
std::optional<std::uint8_t> read_active_configuration(std::uint64_t device_id) {
    std::uint64_t handle = 0;
    if (OH_Usb_ClaimInterface(device_id, 0, &handle) != 0) return std::nullopt;

    UsbControlRequestSetup setup{};
    setup.bmRequestType = 0x80; // 设备到主机 / 标准 / 设备
    setup.bRequest = 8;         // GET_CONFIGURATION
    setup.wValue = 0;
    setup.wIndex = 0;
    setup.wLength = 1;

    std::uint8_t value = 0;
    std::uint32_t length = 1;
    const int result = OH_Usb_SendControlReadRequest(handle, &setup, 1000,
        &value, &length);
    OH_Usb_ReleaseInterface(handle);
    if (result != 0 || length < 1 || value == 0) return std::nullopt;
    return value;
}

// 读设备当前的 USB "mode"（Apple 的厂商私有概念）。
//
// 依据：usbmuxd 的 src/usb.h
//   #define APPLE_VEND_SPECIFIC_GET_MODE 0x45
//   #define APPLE_VEND_SPECIFIC_SET_MODE 0x52
// 上游 usb.c usb_device_add() 发 GET_MODE（bmRequestType=0xC0, wLength=4），
// 设备回 4 字节 "3:3:3:0"（initial mode）或 "5:3:3:0"（其它 mode）。
//
// ★ 这里只做**只读探测**，不做 mode 切换 ★
//   上游 usbmuxd 探测完会按需 SET_MODE(0x52) 切回 initial mode（默认 mode 1），
//   因为它**独占**设备、只做 usbmux。本工程的采集链路依赖 mode 2 的 Valeria
//   配置（0x2A 接口），配对期间把它切走会打断正在进行的采集 ——
//   取舍是产品决策，不是协议问题，所以这里不代劳。
//
// ★ 探测的价值在排查 ★
//   mode 值能一眼说明「设备此刻处在哪个模式、采集配置有没有生效」。
//   特别是：若设备在采集链路发过 0x52(wIndex=2) 之后停在 mode 2，
//   我们就知道 usbmux 接口此时是在哪个配置下被找到的。
//
// 读不到时返回 nullopt（老设备不支持 / 接口 0 认领不上）——不视为错误。
std::optional<std::string> read_device_mode(std::uint64_t device_id) {
    std::uint64_t handle = 0;
    if (OH_Usb_ClaimInterface(device_id, 0, &handle) != 0) return std::nullopt;

    UsbControlRequestSetup setup{};
    setup.bmRequestType = 0xC0; // 设备到主机 / 厂商 / 设备
    setup.bRequest = 0x45;       // APPLE_VEND_SPECIFIC_GET_MODE
    setup.wValue = 0;
    setup.wIndex = 0;
    setup.wLength = 4;

    std::uint8_t value[4] = {0, 0, 0, 0};
    std::uint32_t length = 4;
    const int result = OH_Usb_SendControlReadRequest(handle, &setup, 1000,
        value, &length);
    OH_Usb_ReleaseInterface(handle);
    if (result != 0 || length < 4) return std::nullopt;
    // 设备回的是 4 个可打印字符（形如 "3:3:3:0"），按原样记下来。
    return std::string(reinterpret_cast<const char*>(value), 4);
}

#endif // IM_OHOS_USB_DDK_AVAILABLE

} // namespace

// 伪 TCP 隧道的源端口分配器（进程内递增）。
//
// ★ 对齐上游 usbmuxd 的 find_sport() ★
// 上游 device.c 的 find_sport() 从 dev->next_sport = 1 开始，逐个递增，
// 跳过已被占用的口（device_add() 里 next_sport 初值为 1）。本实现原先
// 用随机起点，理由是「撞上设备侧残留的半开连接」——但上游真机跑的就是
// 1,2,3…，设备侧显然接受小整数递增。改成与上游一致，把「设备为什么
// RST」这个变量从怀疑名单里划掉。
std::uint16_t next_tunnel_sport() noexcept {
    static std::atomic<std::uint32_t> counter{0};
    const std::uint32_t raw = counter.fetch_add(1);
    // 0 无效；65535 保留。回绕时跳过 0。
    std::uint32_t value = 1 + (raw % 0xFFFEU);
    return static_cast<std::uint16_t>(value);
}

// 把设备侧 CONTROL 报文解码成可读文本。
//
// 依据：上游 usbmuxd 的 device_control_input()（src/device.c）——
// MUX_PROTO_CONTROL 的 payload[0] 是子类型：
//   3 = 设备侧错误（后跟错误文本，上游打 "ERROR (on device): ..."）
//   7 = 设备侧信息（后跟文本，上游打 "%s: %s"）
// 其它类型上游只记一条 "unhandled payload type"。
std::string describe_control_payload(const std::vector<std::uint8_t>& payload) {
    if (payload.empty()) {
        return "(空载荷)";
    }
    const std::uint8_t kind = payload[0];
    std::string text(payload.begin() + 1, payload.end());
    while (!text.empty() &&
        (text.back() == '\0' || text.back() == '\n' || text.back() == '\r')) {
        text.pop_back();
    }
    if (kind == 3) {
        return "设备错误: " + text;
    }
    if (kind == 7) {
        return "设备消息: " + text;
    }
    return "未知子类型 " + std::to_string(kind) + ": " + text;
}

// 把任意字节串转成可打印的十六进制摘要（诊断用）。
std::string hex_summary(const std::vector<std::uint8_t>& data, std::size_t max_bytes) {
    static const char* kHex = "0123456789abcdef";
    std::string out;
    const std::size_t n = std::min(data.size(), max_bytes);
    out.reserve(n * 3);
    for (std::size_t i = 0; i < n; ++i) {
        if (i > 0) {
            out.push_back(' ');
        }
        out.push_back(kHex[data[i] >> 4]);
        out.push_back(kHex[data[i] & 0x0FU]);
    }
    if (data.size() > n) {
        out += " …";
    }
    return out;
}

OhosUsbMux::OhosUsbMux() {
    // 源端口每实例递增（理由见头文件 tunnelSport_ 的注释）。
    // 计数器静态：进程生命周期内所有 mux 实例（DDK 路径、fd 路径、各轮
    // 配对）取到的 sport 都不同，天然互不踩踏。
    tunnelSport_ = next_tunnel_sport();
}

OhosUsbMux::~OhosUsbMux() {
    disconnect();
}

bool OhosUsbMux::connect(std::uint64_t deviceId) {
    if (connected_) return false;
    if (!ddkSession_.ok()) {
        logging::write(logging::Level::Warning, "usbmux",
            "USB DDK 不可用，无法建立 usbmux 连接");
        return false;
    }
#if IM_OHOS_USB_DDK_AVAILABLE
    deviceId_ = deviceId;

    // 读活动配置，让候选端点按"当前配置优先"排序（理由见 find_mux_endpoints）。
    // 读不到不算失败：下面还有"逐个认领尝试"的回退。
    std::uint8_t active_configuration = 0;
    if (const auto active = read_active_configuration(deviceId_)) {
        active_configuration = *active;
    }

    // 读设备当前的 USB mode（只读探测，不切换）。
    //
    // 用途是**排查**：mode 值能说明设备此刻处在哪个模式、采集配置有没有生效。
    // 读不到不算失败（老设备不支持这个厂商请求）。
    if (const auto mode = read_device_mode(deviceId_)) {
        ohos_usb_diag::note(std::format("设备 USB mode={}（只读探测，未切换）",
            *mode));
    }

    const auto candidates = find_mux_endpoints(deviceId_, active_configuration);
    if (candidates.empty()) {
        logging::write(logging::Level::Warning, "usbmux",
            "设备没有暴露 usbmux 接口（class 0xFF / subclass 0xFE / protocol 2）");
        // ★ 诊断：把描述符里实际看到的接口列出来 ★
        //   "没找到"有两种截然不同的原因：
        //     · 描述符里根本没有 class/subclass/protocol 匹配的接口
        //       （设备形态或固件差异）
        //     · 有匹配的接口，但它的端点不成对（缺 bulk IN 或 bulk OUT）
        //   把看到的都列出来，真机一次插线就能分辨，不用靠猜。
        ohos_usb_diag::note(std::format(
            "未找到 usbmux 接口（0xFF/0xFE/2）：活动配置={}，"
            "描述符里的接口如下", active_configuration));
        describe_interfaces(deviceId_);
        return false;
    }

    // 逐个尝试认领。第一个成功的就用它。
    //
    // 为什么不能只认第一个：DDK 认领的是**活动配置**下的接口，而候选是按
    // 描述符扫出来的，可能来自别的配置。认领失败就换下一个候选，总比死磕
    // 一个拿错的端点强。
    //
    // ★ 诊断粒度 ★：把**每个候选**的认领结果单独记下来。
    //   "没找到接口"与"找到了但认领不上"是两种完全不同的失败 ——
    //   前者说明描述符里没有匹配的接口（设备形态/固件差异），
    //   后者说明接口在但 DDK 认领被拒（被别的进程占用、或不在活动配置里）。
    //   合成一句"认领失败"会把两者混起来，排查就得靠猜。
    const MuxEndpoints* chosen = nullptr;
    std::size_t claimed_count = 0;
    for (const auto& candidate : candidates) {
        std::uint64_t handle = 0;
        const int claim_result = OH_Usb_ClaimInterface(deviceId_,
            candidate.interface_number, &handle);
        if (claim_result != 0) {
            ohos_usb_diag::note(std::format(
                "认领候选失败：配置={} 接口={} alt={} in=0x{:02x} out=0x{:02x} "
                "返回={}",
                candidate.configuration, candidate.interface_number,
                candidate.alternate_setting, candidate.bulk_in,
                candidate.bulk_out, claim_result));
            continue;
        }
        ++claimed_count;
        interfaceHandle_ = handle;
        chosen = &candidate;
        break;
    }
    if (chosen == nullptr) {
        logging::write(logging::Level::Warning, "usbmux", std::format(
            "认领 usbmux 接口失败（试了 {} 个候选）", candidates.size()));
        ohos_usb_diag::note(std::format(
            "认领 usbmux 接口被拒：共 {} 个候选全部失败（可能不在活动配置里，"
            "或被其他进程占用）", candidates.size()));
        interfaceHandle_ = 0;
        return false;
    }
    bulkIn_ = chosen->bulk_in;
    bulkOut_ = chosen->bulk_out;
    claimed_ = true;

    logging::write(std::format(
        "usbmux 接口 {} 已认领（配置 {} alt {} in=0x{:02x} out=0x{:02x}）",
        chosen->interface_number, chosen->configuration,
        chosen->alternate_setting, bulkIn_, bulkOut_));
    ohos_usb_diag::note(std::format(
        "已认领 usbmux 接口：配置={} 接口={} alt={} in=0x{:02x} out=0x{:02x}"
        "（候选 {}/{}，活动配置={}）",
        chosen->configuration, chosen->interface_number,
        chosen->alternate_setting, bulkIn_, bulkOut_,
        claimed_count, candidates.size(), active_configuration));

    if (chosen->alternate_setting != 0) {
        // 备用设置切换失败不是致命的：部分设备只有一个设置。
        (void)OH_Usb_SelectInterfaceSetting(interfaceHandle_,
            chosen->alternate_setting);
    }

    UsbDeviceMemMap* transfer_map = nullptr;
    if (OH_Usb_CreateDeviceMemMap(deviceId_, UsbMtu, &transfer_map) != 0) {
        OH_Usb_ReleaseInterface(interfaceHandle_);
        interfaceHandle_ = 0;
        claimed_ = false;
        logging::write(logging::Level::Warning, "usbmux",
            "为 usbmux 接口申请 DMA 缓冲失败");
        return false;
    }
    transferMap_ = transfer_map;
    transferSize_ = UsbMtu;

    // ── 版本握手（与 fd 后端共用同一段协议代码）──
    return do_version_handshake();
#else
    (void)deviceId;
    logging::write(logging::Level::Warning, "usbmux",
        "本 SDK 未提供 USB DDK，无法建立 usbmux 连接");
    return false;
#endif
}

std::string OhosUsbMux::backend_error_text() const {
    if (fdTransport_ && fdTransport_->valid()) {
        return std::string(fdTransport_->last_error_text());
    }
    return "(ddk)";
}

bool OhosUsbMux::connect_fd(int fd) {
    if (connected_) return false;
    if (fd < 0) {
        logging::write(logging::Level::Warning, "usbmux",
            "fd 通道：传入的 fd 无效");
        return false;
    }

    auto transport = std::make_unique<OhosUsbFdTransport>(fd);

    // ① 定位 usbmux 接口（读描述符 + 必要时切配置 + 读 UDID）。
    //    全程控制传输、免认领；具体语义见 OhosUsbFdDevice.h。
    OhosUsbFdMuxInfo info;
    std::string error;
    if (!discover_usb_fd_mux(*transport, info, error)) {
        logging::write(logging::Level::Warning, "usbmux",
            std::format("fd 通道：定位 usbmux 接口失败：{}", error));
        ohos_usb_diag::note(std::format("fd 通道定位失败：{}", error));
        return false;
    }
    // 没拿到 UDID 也继续：配对阶段还会再读一次（read_usb_fd_serial），
    // 这里失败多半是瞬时问题，不该把整条通道判死。
    if (info.serial.empty()) {
        std::string serial_error;
        (void)read_usb_fd_serial(*transport, info.serial, serial_error);
    }

    // ② Apple mode 只读探测（厂商请求 0x45，免认领），诊断用。
    //    之前这里静默 —— 悬置在「定位完成」之后时，分不清是卡在 mode 探测
    //    还是探针块；加一行前置账本。
    ohos_usb_diag::note("fd 通道：读 USB mode（0xC0/0x45）");
    {
        std::uint8_t mode[4] = {};
        if (transport->control_read(0xC0, 0x45, 0, 0, mode, 4, 500) >= 4) {
            ohos_usb_diag::note(std::format(
                "fd 通道：设备 USB mode={}（只读探测，未切换）",
                std::string(reinterpret_cast<const char*>(mode), 4)));
        }
    }

    // ③ 备用设置：usbmux 几乎总在 alt 0；真有 alt != 0 就切过去。
    if (info.alternate_setting != 0) {
        if (transport->set_interface(info.interface_number,
                info.alternate_setting) != 0) {
            logging::write(logging::Level::Warning, "usbmux", std::format(
                "fd 通道：切换接口 {} 到 alt {} 失败：{}",
                info.interface_number, info.alternate_setting,
                transport->last_error_text()));
            return false;
        }
    }

    // ④ 记下端点与通道，后面 read_bulk/write_bulk 走 fd 分派。
    fdTransport_ = std::move(transport);
    bulkIn_ = info.bulk_in;
    bulkOut_ = info.bulk_out;
    // 包长取 0（描述符异常）时退回 HS 常见值 512：按包长读的前提不能破。
    fd_packet_size_ = info.packet_size > 0 ? info.packet_size : 512;
    fd_serial_ = info.serial;
    deviceId_ = 0;   // fd 通道没有 DDK deviceId

    // ④½ 清端点 halt 并复位主机侧 DATA toggle。
    //
    // 上游 tools/iostouch/qt/usbmux_usb.py 在认领接口后对 IN/OUT 各调一次
    // clear_halt，注释说明：单发 CLEAR_FEATURE 只能复位手机侧，主机侧
    // 可能还留着旧 toggle，重开链路时第一个包会被静默丢弃。
    //
    // 我们这里是"重开 fd 通道"（每次配对轮次都可能重新拿 fd），正好命中
    // 这个场景：设备复位过而主机 toggle 没复位 → 握手 VERSION 都收不到，
    // 表现是"完全没回应"，与 th_off 那种"回 RST"的现象不同。
    //
    // 失败只告警不中断：clear_halt 在部分内核/端点组合上会返回 ENOTTY
    // 或 EPIPE，但那不影响本轮通信（toggle 本来就一致）。
    for (const std::uint8_t ep : {bulkIn_, bulkOut_}) {
        if (ep == 0) continue;
        if (fdTransport_->clear_halt(ep) != 0) {
            logging::write(logging::Level::Warning, "usbmux", std::format(
                "fd 通道：清除端点 0x{:02x} 的 halt 失败：{}（继续）",
                ep, fdTransport_->last_error_text()));
        }
    }

    // ④½ 权限探针已移除：2026-10-31 真机探针已确证（CLAIM/SUBMITURB 放行、
    // 同步 BULK 被拒），bulk 已改走 URB 路径 —— 探针使命完成，不再每轮
    // 白白占 7 行诊断窗口。诊断函数保留（diagnose_usb_fd_access），需要时
    // 可手动恢复调用。

    logging::write(logging::Level::Info, "usbmux", std::format(
        "fd 通道就绪：UDID={} 活动配置={} 接口={} alt={} in=0x{:02x} "
        "out=0x{:02x} 包长={}",
        info.serial.empty() ? "(无)" : info.serial, info.active_config,
        info.interface_number, info.alternate_setting, bulkIn_, bulkOut_,
        fd_packet_size_));
    // 握手前把端点事实写进诊断行：bulk 收发一旦失败，配合下一行的
    // errno 文本能直接分辨"设备没回（ETIMEDOUT）"还是"被拒（EBUSY 等）"。
    ohos_usb_diag::note(std::format(
        "fd 通道：开始握手 in=0x{:02x} out=0x{:02x} 包长={}",
        bulkIn_, bulkOut_, fd_packet_size_));

    // ⑤ 版本握手（与 DDK 路径共用同一段协议代码）。
    if (!do_version_handshake()) {
        disconnect();
        return false;
    }
    ohos_usb_diag::note("fd 通道：usbmux 握手完成，连接 lockdownd 端口");
    connected_ = true;
    return true;
}

bool OhosUsbMux::do_version_handshake() {
    // 主机先发 VERSION（major=2, minor=0），且**首包用 8 字节头** ——
    // 因为此刻还不知道设备支持哪个版本，usbmuxd 也是这么做的
    // （dev->version 初始为 0 → mux_header_size = 8）。
    version_ = 0;
    std::vector<std::uint8_t> version_payload;
    put_u32be(version_payload, 2);  // major
    put_u32be(version_payload, 0);  // minor
    put_u32be(version_payload, 0);  // padding

    if (!send_mux_packet(MuxProtoVersion, {}, version_payload)) {
        ohos_usb_diag::note(std::format(
            "usbmux 版本请求发送失败（backend={}）", backend_error_text()));
        return false;
    }

    // 等设备的版本包。
    std::uint32_t protocol = 0;
    std::vector<std::uint8_t> tcp_header;
    std::vector<std::uint8_t> payload;
    if (!receive_mux_packet(protocol, tcp_header, payload, 3000)) {
        logging::write(logging::Level::Warning, "usbmux",
            "等待设备的 usbmux 版本包超时");
        // backend 文本区分"真超时"与"读被拒"：ETIMEDOUT = 设备没回；
        // EBUSY/ENODEV/EIO = 根本没读到设备上。
        ohos_usb_diag::note(std::format(
            "usbmux 版本握手无回应（backend={}）", backend_error_text()));
        return false;
    }
    if (protocol != MuxProtoVersion || payload.size() < 12) {
        logging::write(logging::Level::Warning, "usbmux", std::format(
            "usbmux 版本握手收到意外报文 protocol={} len={}",
            protocol, payload.size()));
        ohos_usb_diag::note("usbmux 版本握手收到非版本包");
        return false;
    }

    const std::uint32_t major = get_u32be(payload.data());
    const std::uint32_t minor = get_u32be(payload.data() + 4);
    if (major != 1 && major != 2) {
        logging::write(logging::Level::Warning, "usbmux", std::format(
            "设备报告了未知的 usbmux 版本 {}.{}", major, minor));
        ohos_usb_diag::note(std::format("设备报告未知 usbmux 版本 {}.{}",
            major, minor));
        return false;
    }
    version_ = static_cast<int>(major);

    if (version_ >= 2) {
        // v2 要补发 SETUP(0x07)。usbmuxd 里这一包特殊处理：tx_seq 归 0、
        // rx_seq 置 0xFFFF，然后才开始递增 tx_seq。
        tx_seq_ = 0;
        rx_seq_ = 0xFFFF;
        if (!send_mux_packet(MuxProtoSetup, {}, std::vector<std::uint8_t>{0x07})) {
            return false;
        }
        // ★ 设备对 SETUP 会回一包应答（protocol = SETUP / CONTROL）★
        //
        // 2026-11-03 真机确证：这包应答会排在接收队列的头上，被后面
        // open_port() 的第一次 receive 当成"隧道应答"读走，于是报
        // 「usbmux 隧道收到非 TCP 报文」→ 配对永远停在握手之后。
        // 这里就地把它读掉（超时无应答也无妨：SETUP 本来就是单向的）。
        std::uint32_t setup_protocol = 0;
        std::vector<std::uint8_t> setup_header;
        std::vector<std::uint8_t> setup_payload;
        if (receive_mux_packet(setup_protocol, setup_header, setup_payload, 500)) {
            if (setup_protocol == MuxProtoControl) {
                ohos_usb_diag::note(std::format(
                    "usbmux 设备 CONTROL 报文：{}",
                    describe_control_payload(setup_payload)));
            } else {
                ohos_usb_diag::note(std::format(
                    "usbmux SETUP 应答已读走（protocol={} 载荷={} 字节 [{}]）",
                    setup_protocol, setup_payload.size(),
                    hex_summary(setup_payload, 16)));
            }
        }
    }

    logging::write(std::format(
        "usbmux 版本握手完成 v{}.{}（头长 {} 字节）", major, minor,
        version_ >= 2 ? 16 : 8));
    ohos_usb_diag::note(std::format("usbmux 握手完成（协议 v{}.{}）",
        major, minor));
    return true;
}

// 向设备发 RST 拆除伪 TCP 连接（尽力而为）。
//
// 依据：usbmuxd 的 device_tcp_input() 收到 RST 就把连接置 DYING 并
// teardown —— 所以一个 RST 足以让设备侧立刻释放 (sport, dport) 这条
// 连接。发送失败不重试不报错：链路都断了的话，设备侧的连接会随 USB
// 断开自然回收。
void OhosUsbMux::abort_tunnel_rst() {
    if (tunnelPort_ == 0) return;
    const std::uint16_t sport = tunnelSport_;
    const std::uint16_t port = tunnelPort_;
    (void)send_tcp({}, ThRst);
    logging::write(logging::Level::Info, "usbmux", std::format(
        "已向设备发送 RST 拆除隧道（sport={} 端口={}）", sport, port));
}

void OhosUsbMux::disconnect() {
    // ★ 拆隧道前先告诉设备（发 RST）★
    //
    // 2026-10-31 真机诊断确证的失败链：配对失败后直接断开 → 设备侧
    // (sport, 62078) 的连接还挂着 → 下一轮 SYN（同 sport）被设备 RST
    // 拒绝（"设备拒绝连接端口 62078（RST）"），之后每一轮全部如此，
    // 配对永远无法进入 lockdownd 对话。发 RST 让设备立即 teardown；
    // 源端口轮换是第二重保险（进程被杀等发不出 RST 的场景）。
    if (connected_ && tunnel_open_) {
        abort_tunnel_rst();
    }
    connected_ = false;
    tunnel_open_ = false;
    rxBuffer_.clear();
    version_ = 0;
    tx_seq_ = 0;
    rx_seq_ = 0;
    tcp_tx_seq_ = 0;
    tcp_tx_ack_ = 0;
    tcp_rx_seq_ = 0;
#if IM_OHOS_USB_DDK_AVAILABLE
    if (transferMap_ != nullptr) {
        OH_Usb_DestroyDeviceMemMap(
            static_cast<UsbDeviceMemMap*>(transferMap_));
        transferMap_ = nullptr;
    }
    if (claimed_) {
        OH_Usb_ReleaseInterface(interfaceHandle_);
        claimed_ = false;
    }
#endif
    // fd 后端：丢掉传输器即可。fd 本身不 close（它的所有权在 ArkTS 侧
    // —— 是 usbManager.getFileDescriptor() 那次 open 的产物，本进程里
    // 这份 fd 的生命周期跟随 pipe，由上层决定何时让系统回收）。
    fdTransport_.reset();
    fd_packet_size_ = 512;
    fd_serial_.clear();
    interfaceHandle_ = 0;
    transferSize_ = 0;
    bulkIn_ = 0;
    bulkOut_ = 0;
    deviceId_ = 0;
}

bool OhosUsbMux::open_port(std::uint16_t port) {
    if (!connected_) return false;
    // 伪 TCP 三次握手的第 1 步：发 SYN。
    //
    // sport 由构造函数从递增计数器分配（usbmuxd 用 dev->next_sport 从 1
    // 递增分配，设备侧只按 sport/dport 配对，不校验取值范围）。不再固定
    // 用 1 —— 固定值会撞上上一轮残留的半开连接（见头文件注释）。
    //
    // ★ 字节序只有一次翻转 ★
    // put_u16be() 内部已经调用 htons()，把主机序转成网络序。所以这里
    // **必须直接传主机序的数值**。曾经写成 put_u16be(header, htons(port))，
    // 那样等于翻转两次 —— 62078 被写成 0x7ef2(=32506)，设备按 dport 找不到
    // 62078 这个服务，连接永远建不起来（表现就是"弹窗不出现"）。
    // 同理 th_win 传的是 (tx_win >> 8) 的主机序值 = 512。
    tcp_tx_seq_ = 0;
    tcp_tx_ack_ = 0;
    tcp_rx_seq_ = 0;
    tunnelPort_ = port;

    // SYN → SYN|ACK，带「RST 换源端口重试」。
    //
    // 设备对同 (sport,dport) 上残留的半开连接会用 RST 拒绝我们的 SYN
    // （2026-10-31 真机确证）。换一个 sport 立即重试 —— 一次 RST 往返在
    // 毫秒级，最多换 5 次口，正常链路下零成本。
    std::uint32_t protocol = 0;
    std::vector<std::uint8_t> reply_header;
    std::vector<std::uint8_t> reply_payload;
    std::uint8_t flags = 0;
    for (int syn_attempt = 1;; ++syn_attempt) {
        reply_header.clear();
        reply_payload.clear();

        std::vector<std::uint8_t> header;
        put_u16be(header, tunnelSport_);          // th_sport
        put_u16be(header, port);                  // th_dport（网络序）
        put_u32be(header, tcp_tx_seq_);           // th_seq
        put_u32be(header, tcp_tx_ack_);           // th_ack
        header.push_back(TcpHeaderOffset);        // th_off = (20/4)<<4 = 0x50
        header.push_back(ThSyn);                  // th_flags
        put_u16be(header, TcpTxWindow >> 8);      // th_win（窗口按 8 位缩放）
        put_u16be(header, 0);                     // th_sum（不用）
        put_u16be(header, 0);                     // th_urp（不用）

        if (!send_mux_packet(MuxProtoTcp, header, {})) {
            ohos_usb_diag::note(std::format(
                "usbmux SYN 发送失败（backend={}）", backend_error_text()));
            return false;
        }

        // 第 2 步：等设备的 SYN|ACK。
        //
        // ★ 允许跳过中间的非 TCP 报文 ★
        //   设备在 v2 握手后会先回一包 SETUP/CONTROL 应答（见上），它可能
        //   在隧道应答之前到达。旧代码拿到非 TCP 报文就直接判失败，于是
        //   「握手成功 → 连不上 62078」（2026-11-03 真机现象）。现在改成
        //   跳过并继续等 SYN|ACK，最多跳 8 包。
        bool got_tcp_reply = false;
        for (int skip = 0; skip < 8; ++skip) {
            if (!receive_mux_packet(protocol, reply_header, reply_payload, 3000)) {
                logging::write(logging::Level::Warning, "usbmux",
                    "等待设备的 SYN|ACK 超时");
                ohos_usb_diag::note("usbmux 隧道打开超时：设备没有回应 SYN");
                return false;
            }
            if (protocol != MuxProtoTcp || reply_header.size() < 20) {
                // 设备侧的非 TCP 报文分两类：CONTROL（设备自己的消息/
                // 错误，上游会打印原文）与其它（只记类型）。都写进诊断，
                // 下一轮就能看到设备到底在抱怨什么。
                if (protocol == MuxProtoControl) {
                    ohos_usb_diag::note(std::format(
                        "usbmux 设备 CONTROL 报文：{}",
                        describe_control_payload(reply_payload)));
                } else {
                    ohos_usb_diag::note(std::format(
                        "usbmux 隧道跳过非 TCP 报文（protocol={} 载荷={} 字节 [{}]）",
                        protocol, reply_payload.size(),
                        hex_summary(reply_payload, 16)));
                }
                continue;
            }
            got_tcp_reply = true;
            break;
        }
        if (!got_tcp_reply) {
            ohos_usb_diag::note("usbmux 隧道：连续收到非 TCP 报文，放弃");
            return false;
        }
        flags = reply_header[13];
        // ★ 校验这是"我们这条连接"的包 ★
        //
        // 设备侧可能还有别的连接的报文在流（比如上一轮没拆干净的连接、
        // 设备自己主动发起的连接）。上游 usbmux_usb.py 的 _handle_packet()
        // 严格按端口配对：
        //   conn = self._conns.get(seg.dport)
        //   if conn is None or conn.sport != seg.dport or conn.dport != seg.sport:
        //       # 不是我们的连接 → 回 RST 忽略
        //
        // 设备的 SYN|ACK 里：th_sport = 我们的目标端口（62078），
        // th_dport = 我们的源端口。端口不匹配就说明这包是别人的 ——
        // 之前我们不校验，会把陌生连接的 SYN|ACK 当成自己的，
        // 于是把序号/确认号推进到一个不存在的连接上，后续全乱。
        const std::uint16_t reply_sport = get_u16be(reply_header.data());
        const std::uint16_t reply_dport = get_u16be(reply_header.data() + 2);
        if (reply_sport != port || reply_dport != tunnelSport_) {
            ohos_usb_diag::note(std::format(
                "usbmux 忽略非本连接的 TCP 报文（flags=0x{:02x} sport={} dport={}，"
                "期望 sport={} dport={}）",
                flags, reply_sport, reply_dport, port, tunnelSport_));
            // 这包不属于我们，但按上游做法应回 RST 让对方释放。
            (void)send_tcp({}, ThRst);
            return false;
        }
        if ((flags & ThRst) != 0) {
            // ★ RST 的载荷里往往带着设备给的原因文本 ★
            // 上游 usbmuxd 在 device_tcp_input() 里就把 RST 的 payload 当
            // 文本打出来（"RST reason: %s"）。我们过去把它丢了，只剩一句
            // 「设备拒绝连接」，看不到原因 —— 现在原样记进诊断。
            std::string reason(reply_payload.begin(), reply_payload.end());
            while (!reason.empty() &&
                (reason.back() == '\0' || reason.back() == '\n' ||
                 reason.back() == '\r')) {
                reason.pop_back();
            }
            logging::write(logging::Level::Warning, "usbmux", std::format(
                "设备拒绝了到端口 {} 的连接（RST，sport={}，原因={}）",
                port, tunnelSport_, reason.empty() ? "(无)" : reason));
            ohos_usb_diag::note(std::format(
                "设备拒绝连接端口 {}（RST，sport={}，原因={}）", port, tunnelSport_,
                reason.empty() ? "(无)" : reason));
            // ★ 只换 1 次源端口 ★：设备每次拒一个 SYN 都会真的去连一次
            //   62078，连打 5 次既没意义（不是端口冲突，是设备在拒绝），
            //   又会骚扰设备。把节奏放慢，把时间留给用户解锁手机。
            if (syn_attempt >= 2) {
                ohos_usb_diag::note(std::format(
                    "设备拒绝连接端口 {}（RST，换过源端口仍被拒）", port));
                ohos_usb_diag::note(
                    "提示：设备侧 RST 多为锁屏或未信任；请解锁 iPhone 并在"
                    "弹窗里点「信任此电脑」后重试");
                return false;
            }
            // 半开连接毒化：换下一个源端口立即重试。
            tunnelSport_ = next_tunnel_sport();
            continue;
        }
        break;
    }
    if ((flags & (ThSyn | ThAck)) != (ThSyn | ThAck)) {
        logging::write(logging::Level::Warning, "usbmux", std::format(
            "设备对端口 {} 的连接回应了非 SYN|ACK（flags=0x{:02x}）",
            port, flags));
        ohos_usb_diag::note(std::format(
            "usbmux SYN|ACK 意外回应 flags=0x{:02x}", flags));
        return false;
    }

    // 记下设备侧的序号，并按上游的做法推进自己的序号。
    //
    // ★ tx_ack 必须等于「设备的 seq + 1」，不是「我们自己的 ack + 1」 ★
    //
    // 设备在 SYN|ACK 里带的 seq 是**它自己**的发送序号，可能不是 0
    // （上游 usbmux_usb.py 的注释明确按随机值处理）。确认号的语义是
    // "我下一个期望收到的字节序号"，所以必须以设备的 seq 为基准。
    // 之前写 `tcp_tx_ack_ += 1`（从 0 加到 1），只有设备 seq 恰好为 0
    // 时才对 —— 设备 seq 非 0 时，设备会把我们的 ACK 当成"重复/过期"
    // 而丢弃后续数据。
    //
    // 上游： self.tx_seq += 1; self.tx_ack = seg.seq + 1;
    tcp_rx_seq_ = get_u32be(reply_header.data() + 4);
    tcp_tx_seq_ += 1;
    tcp_tx_ack_ = tcp_rx_seq_ + 1;

    // 第 3 步：回一个纯 ACK。
    if (!send_tcp({}, ThAck)) {
        ohos_usb_diag::note(std::format(
            "usbmux ACK 发送失败（backend={}）", backend_error_text()));
        // 设备侧这条连接此刻已经建立（它确认过我们的 SYN）。ACK 发不出去
        // 多半是链路问题，但只要链路还活着就要发 RST 拆掉它，别留下半开
        // 连接毒化下一次同 sport 的 SYN。
        (void)send_tcp({}, ThRst);
        return false;
    }
    tunnel_open_ = true;
    logging::write(std::format("usbmux 隧道已打开：设备端口 {}", port));
    ohos_usb_diag::note(std::format("已连上设备端口 {}", port));
    return true;
}

int OhosUsbMux::send(const std::vector<std::uint8_t>& data) {
    if (!connected_ || !tunnel_open_) return -1;
    std::size_t offset = 0;
    while (offset < data.size()) {
        const std::size_t chunk = std::min(data.size() - offset, MaxTcpPayload);
        const std::vector<std::uint8_t> payload(
            data.begin() + static_cast<std::ptrdiff_t>(offset),
            data.begin() + static_cast<std::ptrdiff_t>(offset + chunk));
        // ★ 标志位只放 TH_ACK，不放 TH_PSH ★
        //
        // usbmuxd 的 README 明确写着："all normal packets need to have flags
        // set to ACK (and only ACK)"。设备侧把这个协议实现得比真 TCP 还死板，
        // 多带一个 PSH 位就可能被当成非法包丢掉（表现为"发出去没回音"）。
        // usbmuxd 自己发数据时用的也是纯 TH_ACK。
        if (!send_tcp(payload, ThAck)) {
            return -1;
        }
        offset += chunk;
    }
    return static_cast<int>(data.size());
}

std::vector<std::uint8_t> OhosUsbMux::receive(int timeoutMs) {
    if (!connected_ || !tunnel_open_) return {};
    // ★ 隧道数据与设备消息可能交错 ★：设备侧随时会插 CONTROL 报文
    //   （消息/错误），旧代码遇到非 TCP 报文直接丢弃 —— 那一条如果是
    //   设备的错误说明就永远看不到了。现在跳过并记录，继续等隧道数据，
    //   整体受同一个超时约束。
    const auto deadline = std::chrono::steady_clock::now() +
        std::chrono::milliseconds(timeoutMs > 0 ? timeoutMs : 1000);
    for (;;) {
        std::uint32_t protocol = 0;
        std::vector<std::uint8_t> header;
        std::vector<std::uint8_t> payload;
        const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(
            deadline - std::chrono::steady_clock::now()).count();
        if (left <= 0) {
            return {};
        }
        if (!receive_mux_packet(protocol, header, payload, static_cast<int>(left))) {
            return {};
        }
        if (protocol != MuxProtoTcp || header.size() < 20) {
            if (protocol == MuxProtoControl) {
                ohos_usb_diag::note(std::format(
                    "usbmux 设备 CONTROL 报文：{}",
                    describe_control_payload(payload)));
            } else {
                ohos_usb_diag::note(std::format(
                    "usbmux 隧道收到非 TCP 报文（protocol={} 载荷={} 字节 [{}]）",
                    protocol, payload.size(), hex_summary(payload, 16)));
            }
            continue;
        }

        // 设备用 RST 断开隧道：后续再读也只是白等，立即作废这条连接。
        //
        // usbmuxd 的 device_tcp_input() 里，收到 RST 就把连接置为 DYING 并
        // teardown。我们没有连接池，直接把隧道标记为不可用即可。
        //
        // ★ 先校验端口配对 ★：设备可能还开着别的连接，它们的报文不该
        // 被当成本隧道的 RST —— 否则会误判"隧道被重置"并把整条链路作废。
        // 上游按 (sport, dport) 精确配对，我们照做。
        const std::uint16_t seg_sport = get_u16be(header.data());
        const std::uint16_t seg_dport = get_u16be(header.data() + 2);
        if (seg_sport != tunnelPort_ || seg_dport != tunnelSport_) {
            ohos_usb_diag::note(std::format(
                "usbmux 隧道忽略非本连接的 TCP 报文（flags=0x{:02x} sport={} "
                "dport={}，期望 sport={} dport={}）",
                header[13], seg_sport, seg_dport, tunnelPort_, tunnelSport_));
            continue;
        }
        const std::uint8_t flags = header[13];
        if ((flags & ThRst) != 0) {
            tunnel_open_ = false;
            std::string reason(payload.begin(), payload.end());
            while (!reason.empty() &&
                (reason.back() == '\0' || reason.back() == '\n' ||
                 reason.back() == '\r')) {
                reason.pop_back();
            }
            logging::write(logging::Level::Warning, "usbmux",
                "设备重置了 usbmux 隧道（RST）");
            ohos_usb_diag::note(std::format(
                "设备重置了 usbmux 隧道（RST，原因={}）",
                reason.empty() ? "(无)" : reason));
            return {};
        }

        // 收到设备的数据后**必须回 ACK**，并且推进我们发给设备的确认号。
        //
        // ★ 为什么这是必须的 ★
        // 设备侧按"确认号 + 窗口"决定还能不能继续发数据。我们不回 ACK，它就认为
        // 数据没被接收，窗口耗尽后**停止发数据** —— 表现是"配对请求发出去了，
        // 读回来一半就没下文了"，而且没有任何错误码可查。
        //
        // usbmuxd 的等价做法：device_tcp_input() 里 connection_device_input()
        // 之后立刻 send_tcp_ack(conn)。
        //
        // ★ 确认号必须以「设备本包的 seq」为基准 ★
        //
        // 上游 usbmux_usb.py 的 _on_segment()：
        //     self.tx_ack = seg.seq + len(seg.payload)
        // 也就是"下一个期望收到的字节序号 = 设备这包的 seq + 载荷长度"。
        // 我们此前写的是 `tcp_tx_ack_ += payload.size()` —— 那是相对推进，
        // 只有在设备每包 seq 连续递增时才碰巧对得上；一旦设备重传、
        // 或我们的 ack 起点偏了，相对推进就会永久性错位，设备会丢弃
        // 后续数据（"读回来一半就没下文"）。
        //
        // 顺带把设备这包的 seq 记进 tcp_rx_seq_，便于诊断时对齐两边的序号。
        //
        // 注意只发**纯 ACK**（无载荷）：ACK 不消耗序号，所以这个包不带载荷。
        const std::uint32_t seg_seq = get_u32be(header.data() + 4);
        tcp_rx_seq_ = seg_seq;
        if (!payload.empty()) {
            tcp_tx_ack_ = seg_seq + static_cast<std::uint32_t>(payload.size());
            if (!send_tcp({}, ThAck)) {
                logging::write(logging::Level::Warning, "usbmux",
                    "向设备回 ACK 失败");
                return {};
            }
        }
        return payload;
    }
}

int OhosUsbMux::read_bulk(std::vector<std::uint8_t>& buffer, int timeoutMs) {
    // ── fd 后端 ──
    if (fdTransport_ && fdTransport_->valid()) {
        // ★ 按端点包长请求，一次一包 ★
        // 内核 usb_bulk_msg 超时会 kill URB 并**丢弃已收的部分数据**
        // （usb_start_wait_urb → usb_kill_urb）。若按 48KB 请求，数据流
        // 凑不满时这一读会白等到超时且一无所获；按包长请求则
        // "一个包到齐（或短包）即返回"，拼包由 receive_mux_packet 的
        // rxBuffer_ 负责。
        buffer.resize(fd_packet_size_);
        const int received = fdTransport_->bulk_read(bulkIn_,
            buffer.data(), fd_packet_size_,
            timeoutMs > 0 ? static_cast<std::uint32_t>(timeoutMs) : 1000U);
        if (received < 0) {
            // 超时是轮询节奏里的正常事件（receive_mux_packet 每 200ms
            // 试一次），返回 0 让上层继续等；其它错误才算链路故障。
            const bool timed_out = fdTransport_->last_error() == ETIMEDOUT;
            buffer.clear();
            return timed_out ? 0 : -1;
        }
        buffer.resize(static_cast<std::size_t>(received));
        return received;
    }

    // ── DDK 后端 ──
#if IM_OHOS_USB_DDK_AVAILABLE
    if (transferMap_ == nullptr) return -1;
    auto* map = static_cast<UsbDeviceMemMap*>(transferMap_);

    // UsbDeviceMemMap 的三个长度字段语义（与 OhosUsbTransport.cpp 相同）：
    //   offset        本次传输的缓冲区起始偏移（默认 0）
    //   bufferLength  本次传输可用的字节数（默认等于 size）
    //   transferedLength 本次实际传输的字节数（传输后才有意义）
    // 每次 bulk IN 之前都要重置前两个，否则上一帧的残留会成为这一帧的起点。
    map->offset = 0;
    map->bufferLength = static_cast<std::uint32_t>(transferSize_);
    map->transferedLength = 0;

    UsbRequestPipe pipe{};
    pipe.interfaceHandle = interfaceHandle_;
    pipe.timeout = timeoutMs > 0 ? static_cast<std::uint32_t>(timeoutMs) : 1000;
    pipe.endpoint = bulkIn_;
    if (OH_Usb_SendPipeRequest(&pipe, map) != 0) return -1;

    const std::size_t received = std::min<std::size_t>({
        static_cast<std::size_t>(map->transferedLength),
        static_cast<std::size_t>(transferSize_)});
    if (received == 0) return 0;
    buffer.assign(map->address + map->offset,
        map->address + map->offset + received);
    return static_cast<int>(received);
#else
    (void)timeoutMs;
    return -1;
#endif
}

bool OhosUsbMux::write_bulk(const std::vector<std::uint8_t>& data) {
    // ── fd 后端 ──
    if (fdTransport_ && fdTransport_->valid()) {
        if (data.size() > UsbMtu) return false;
        if (!data.empty()) {
            // ★ 短写检测 ★：urb_bulk 返回的是**实际传输字节数**。少发
            // 字节会让设备侧看到一个被截断的 mux 报文（长度字段与实际
            // 不符）——设备侧的解析器会把它当成坏包，最典型的表现就是
            // 回一个 RST。所以这里把短写当失败，并写进诊断。
            const int written = fdTransport_->bulk_write(bulkOut_, data.data(),
                data.size(), 1000);
            if (written < 0) {
                return false;
            }
            if (static_cast<std::size_t>(written) != data.size()) {
                ohos_usb_diag::note(std::format(
                    "usbmux 短写：请求 {} 字节，实发 {} 字节", data.size(),
                    written));
                return false;
            }
            // ★ ZLP ★：载荷恰好是端点包长整数倍时必须补一个零长包，
            // 否则设备侧的 bulk IN 会一直等"包尾"。上游 usbmuxd 的
            // usb_send() 同样处理（length % wMaxPacketSize == 0 时发
            // 零长传输）。
            if (fd_packet_size_ > 0 && data.size() % fd_packet_size_ == 0) {
                (void)fdTransport_->bulk_write(bulkOut_, nullptr, 0, 1000);
            }
        }
        return true;
    }

    // ── DDK 后端 ──
#if IM_OHOS_USB_DDK_AVAILABLE
    if (transferMap_ == nullptr || data.empty()) return false;
    if (data.size() > transferSize_) return false;
    auto* map = static_cast<UsbDeviceMemMap*>(transferMap_);
    std::memcpy(map->address, data.data(), data.size());
    map->offset = 0;
    map->bufferLength = static_cast<std::uint32_t>(data.size());
    map->transferedLength = 0;

    UsbRequestPipe pipe{};
    pipe.interfaceHandle = interfaceHandle_;
    pipe.timeout = 1000;
    pipe.endpoint = bulkOut_;
    return OH_Usb_SendPipeRequest(&pipe, map) == 0;
#else
    (void)data;
    return false;
#endif
}

bool OhosUsbMux::send_mux_packet(std::uint32_t protocol,
    const std::vector<std::uint8_t>& tcp_header,
    const std::vector<std::uint8_t>& payload) {
    const std::size_t header_size = version_ >= 2 ? 16 : 8;
    const std::size_t total = header_size + tcp_header.size() + payload.size();
    if (total > UsbMtu) {
        logging::write(logging::Level::Warning, "usbmux", std::format(
            "mux 报文超出 USB_MTU：{} > {}", total, UsbMtu));
        return false;
    }

    std::vector<std::uint8_t> packet;
    packet.reserve(total);
    put_u32be(packet, protocol);
    put_u32be(packet, static_cast<std::uint32_t>(total));
    if (version_ >= 2) {
        put_u32be(packet, 0xFEEDFACEU);
        put_u16be(packet, tx_seq_);
        put_u16be(packet, rx_seq_);
        ++tx_seq_;
    }
    packet.insert(packet.end(), tcp_header.begin(), tcp_header.end());
    packet.insert(packet.end(), payload.begin(), payload.end());
    return write_bulk(packet);
}

bool OhosUsbMux::send_tcp(const std::vector<std::uint8_t>& payload,
    std::uint8_t flags) {
    std::vector<std::uint8_t> header;
    // 端口取 open_port() 打开的那一个，不能写死 62078 ——
    // th_dport 是每包都要填的字段，写错设备就认不出这条连接。
    put_u16be(header, tunnelSport_);           // th_sport
    put_u16be(header, tunnelPort_);            // th_dport（网络序）
    put_u32be(header, tcp_tx_seq_);
    put_u32be(header, tcp_tx_ack_);
    // ★ th_off 必须写 0x50，不能写 5 ★
    //
    // TCP 头的 th_off 字段是 4 bit 的**数据偏移**，占字节的**高 4 位**
    // （低 4 位是保留位 x2）。RFC 793 / Linux netinet/tcp.h 的
    // `th_off:4` 位域都定义在高 4 位，所以 20 字节头的正确编码是
    // 0x50 = (20/4) << 4。
    //
    // ★ 我们此前写的是 5（0x05），等于把偏移量塞进了保留位 ★
    // 设备侧按高 4 位解析：0x05 >> 4 == 0 → 头长算成 0 字节 →
    // 后续字段（flags/win/载荷）整体错位 → SYN 被判为坏包 → 设备回 RST。
    // 这与 2026-11-03/06 真机「设备拒绝连接端口 62078（RST）」的现象
    // 完全吻合：mux 头、magic、序号、窗口全都对，唯独 th_off 错位。
    //
    // 依据：上游 tools/iostouch/qt/usbmux_usb.py 的 build_tcp()：
    //   _TCPHDR.pack(sport, dport, seq, ack, (TCP_HDR_LEN // 4) << 4, ...)
    header.push_back(TcpHeaderOffset);              // th_off = (20/4) << 4
    header.push_back(flags);
    put_u16be(header, TcpTxWindow >> 8);        // th_win（8 位缩放）
    put_u16be(header, 0);
    put_u16be(header, 0);

    if (!send_mux_packet(MuxProtoTcp, header, payload)) return false;
    // 载荷消耗序号。SYN/ACK 这类纯控制包不消耗（已在调用处单独推进）。
    tcp_tx_seq_ += static_cast<std::uint32_t>(payload.size());
    return true;
}

bool OhosUsbMux::receive_mux_packet(std::uint32_t& protocol,
    std::vector<std::uint8_t>& tcp_header,
    std::vector<std::uint8_t>& payload, int timeoutMs) {
    const auto deadline = std::chrono::steady_clock::now() +
        std::chrono::milliseconds(timeoutMs > 0 ? timeoutMs : 1000);

    for (;;) {
        // 缓冲里若已有完整报文，直接切出来。
        if (rxBuffer_.size() >= 8) {
            const std::uint32_t length = get_u32be(rxBuffer_.data() + 4);
            if (length >= 8 && length <= DevMru &&
                rxBuffer_.size() >= length) {
                const std::size_t header_size = version_ >= 2 ? 16 : 8;
                protocol = get_u32be(rxBuffer_.data());
                std::vector<std::uint8_t> packet(
                    rxBuffer_.begin(), rxBuffer_.begin() + static_cast<std::ptrdiff_t>(length));
                rxBuffer_.erase(rxBuffer_.begin(),
                    rxBuffer_.begin() + static_cast<std::ptrdiff_t>(length));
                if (packet.size() < header_size) return false;
                // v2 的 mux_header 带 rx_seq：usbmuxd 在 device_data_input()
                // 里做 `dev->rx_seq = ntohs(mhdr->rx_seq)`，把设备报的对端
                // 序号记下来，后续发包时原样带回去。缺了这一步，设备会认为
                // 我们的序号对不上而丢包。
                if (version_ >= 2 && packet.size() >= 16) {
                    rx_seq_ = get_u16be(packet.data() + 14);
                }
                const std::size_t body = packet.size() - header_size;
                if (body >= TcpHeaderLength && protocol == MuxProtoTcp) {
                    // ★ 按设备报的头长切载荷，不要写死 20 ★
                    //
                    // th_off 的高 4 位是数据偏移（单位 4 字节），头长 =
                    // (th_off >> 4) * 4。上游 usbmux_usb.py 的 parse_tcp()
                    // 就是这么切的：`hdr_len = (off >> 4) * 4`。
                    //
                    // 设备正常只发 20 字节的标准头（th_off = 0x50），但写死
                    // 20 会让"设备带了选项"或"编码风格不同"的报文整段错位
                    // —— 错位后载荷里会混进头部字节，AFC/锁定域解析直接失败，
                    // 而且报错完全不指向真因。
                    //
                    // 越界时回退到 20（标准头长）：th_off 全 0 或用了低位
                    // 风格的设备都不会因此让我们把报文整个当载荷。
                    const std::uint8_t off = packet[header_size + 12];
                    std::size_t hdr_len = static_cast<std::size_t>(off >> 4) * 4;
                    if (hdr_len < TcpHeaderLength || hdr_len > body) {
                        hdr_len = TcpHeaderLength;
                    }
                    // tcp_header 始终保留前 20 字节（调用方按固定偏移取
                    // seq/flags），载荷从真实头长之后开始切。
                    tcp_header.assign(
                        packet.begin() + static_cast<std::ptrdiff_t>(header_size),
                        packet.begin() + static_cast<std::ptrdiff_t>(
                            header_size + TcpHeaderLength));
                    payload.assign(
                        packet.begin() + static_cast<std::ptrdiff_t>(header_size + hdr_len),
                        packet.end());
                } else {
                    tcp_header.clear();
                    payload.assign(packet.begin() + static_cast<std::ptrdiff_t>(header_size),
                        packet.end());
                }
                return true;
            }
        }

        if (std::chrono::steady_clock::now() >= deadline) return false;

        std::vector<std::uint8_t> chunk;
        const int received = read_bulk(chunk, 200);
        if (received < 0) return false;
        if (received == 0) continue;
        rxBuffer_.insert(rxBuffer_.end(), chunk.begin(), chunk.end());
        if (rxBuffer_.size() > DevMru) {
            // 缓冲溢出说明报文长度判断出了问题，丢掉重来。
            rxBuffer_.clear();
            return false;
        }
    }
}

} // namespace iPhoneMirror::ohos
