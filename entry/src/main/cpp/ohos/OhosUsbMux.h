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
//   * th_off   = sizeof(tcphdr)/4 = 5
//   * th_win   = htons(tx_win >> 8)   ← 窗口按 8 位缩放，usbmuxd 固定 131072
//   * 收到 SYN|ACK 后主机补一个纯 ACK，并把 tx_seq/tx_ack 各推进 1
//
// 与真 TCP 不同的是：这个"TCP"不会重传也不会乱序确认，序号错了设备侧
// 会直接丢包，所以下面 send_tcp() 的序号推进必须与 usbmuxd 完全一致。

#pragma once

#include "OhosUsbDdk.h"
#include "OhosUsbFdTransport.h"

#include <cstdint>
#include <memory>
#include <vector>

namespace iPhoneMirror::ohos {

// 设备的 lockdownd 端口（USB 侧 usbmux 隧道要连的就是它）。
inline constexpr std::uint16_t LockdowndPort = 62078;

// usbmux 设备侧协议栈：把 iPhone 当"设备"，本进程当"守护进程"，
// 直接在其 bulk 端点上讲 usbmux 协议。
//
// 生命周期：connect() → （可选 open_port()）→ send()/receive() → disconnect()。
// 其中 open_port() 建立到设备某个 TCP 端口（本工程只用于 62078）的伪 TCP 隧道；
// 不调用 open_port() 的话 send()/receive() 直接在 mux 层收发（用于版本探测）。
class OhosUsbMux {
public:
    OhosUsbMux();
    ~OhosUsbMux();

    OhosUsbMux(const OhosUsbMux&) = delete;
    OhosUsbMux& operator=(const OhosUsbMux&) = delete;

    // 认领 iPhone 的 usbmux 接口（class 0xFF / subclass 0xFE）并完成版本握手。
    // 成功后才能收发 mux 报文。
    [[nodiscard]] bool connect(std::uint64_t deviceId);

    // ★ 走 usbManager 备用通道的连法 ★
    //
    // 与 connect() 的区别只在"怎么拿到一条能收发 bulk 的通道"，协议部分
    // （版本握手、伪 TCP 隧道、lockdownd 对话）完全共用。
    //
    // fd 来自 ArkTS 侧 usbManager.getFileDescriptor(pipe)，那是系统 USB 服务
    // open("/dev/bus/usb/BBB/DDD", O_RDWR) 出来的标准 usbfs 节点。
    //
    // ★ 端点在 native 侧自己定位（内部调 discover_usb_fd_mux）★
    //   不让 ArkTS 把 getDevices() 里的端点传下来，原因：
    //   1. 内核 findintfep() 只认**活动配置**里的端点，而 getDevices() 带回
    //      的是全部配置，ArkTS 侧无法知道哪个配置当前活动；
    //   2. 序列号（配对记录的键）也被系统对非系统应用清空，只能在授权后
    //      自己发控制传输取 —— 反正都要控制传输，描述符就一并读了。
    //   活动配置里没有 usbmux 接口时，发现层会 SET_CONFIGURATION 切过去。
    //
    // ★ 为什么不需要显式 claim 接口 ★
    //   内核的 proc_bulk() 会先 checkintf() → claimintf()，而 claimintf()
    //   是**按 fd 记账**的（ps->ifclaimed 位图，每个 open fd 各有一份）。
    //   ⇒ 我们这个 fd 与 USB 服务侧 libusb 的 fd 互不干扰，也不需要抢
    //     intf->dev.driver。
    [[nodiscard]] bool connect_fd(int fd);

    void disconnect();

    // 在已建立的 mux 链路上打开到设备某端口的伪 TCP 隧道。
    [[nodiscard]] bool open_port(std::uint16_t port);

    // 经隧道发送一段原始字节（lockdownd 报文就靠它发）。
    // 返回写入的字节数，失败返回 -1。
    int send(const std::vector<std::uint8_t>& data);

    // 经隧道接收一段原始字节。timeoutMs<=0 表示使用默认超时。
    // 超时或链路断开返回空向量。
    [[nodiscard]] std::vector<std::uint8_t> receive(int timeoutMs);

    [[nodiscard]] bool connected() const noexcept { return connected_; }
    [[nodiscard]] bool tunnel_open() const noexcept { return tunnel_open_; }

    // fd 通道发现的设备序列号（iPhone 上就是 UDID）。
    //
    // 只在 connect_fd() 成功后有值。非系统应用拿不到 getDevices() 的
    // serial 字段（系统清空），而配对记录的键就是它 —— 所以 fd 路径的
    // UDID 由 native 在定位端点时一并读出（读字符串描述符，免认领），
    // 配对入口从这里取。DDK 通道不走它（那边的 UDID 来自 DDK 枚举）。
    [[nodiscard]] const std::string& fd_serial() const noexcept { return fd_serial_; }

private:
    // fd 后端最近一次传输错误的可读文本（errno 的 strerror 形式）。
    // DDK 后端没有对应语义，返回 "(ddk)"。诊断行用它区分
    // "真超时（ETIMEDOUT）"与"链路故障（EBUSY/ENODEV/…）"。
    [[nodiscard]] std::string backend_error_text() const;

    // 读一次 USB bulk IN，返回读到的字节数；失败返回 -1。
    int read_bulk(std::vector<std::uint8_t>& buffer, int timeoutMs);
    // 写一次 USB bulk OUT。
    bool write_bulk(const std::vector<std::uint8_t>& data);

    // 组包并发送一个 mux 报文（protocol + 可选 tcphdr + 载荷）。
    bool send_mux_packet(std::uint32_t protocol,
        const std::vector<std::uint8_t>& tcp_header,
        const std::vector<std::uint8_t>& payload);

    // 收一个 mux 报文，剥掉 mux_header 后把 tcphdr 与载荷分别交出。
    // 返回 false 表示超时/链路错误。
    bool receive_mux_packet(std::uint32_t& protocol,
        std::vector<std::uint8_t>& tcp_header,
        std::vector<std::uint8_t>& payload, int timeoutMs);

    // 发一个只带载荷的 mux TCP 包（自动补 tcphdr 与序号）。
    bool send_tcp(const std::vector<std::uint8_t>& payload, std::uint8_t flags);

    // 隧道拆除：向设备发一个尽力而为的 TCP RST（理由见 disconnect()）。
    void abort_tunnel_rst();

    // 版本握手（connect() 与 connect_fd() 共用的协议段）。
    // 成功后 version_/tx_seq_/rx_seq_ 就绪，但 connected_ 由调用方置位。
    [[nodiscard]] bool do_version_handshake();

    ohos_usb::DdkSession ddkSession_;
    // fd 后端（非 DDK 通道）。为空表示当前走的是 DDK 通道。
    std::unique_ptr<OhosUsbFdTransport> fdTransport_;
    std::uint64_t deviceId_{0};
    std::uint64_t interfaceHandle_{0};
    void* transferMap_{nullptr};   // UsbDeviceMemMap*
    std::size_t transferSize_{0};
    std::uint8_t bulkIn_{0};
    std::uint8_t bulkOut_{0};
    bool claimed_{false};
    bool connected_{false};
    bool tunnel_open_{false};

    // 设备侧协议版本：0=还没握手，1=v1（8 字节头），2=v2（16 字节头）。
    int version_{0};
    // mux 层序号（仅 v2 有效）。
    std::uint16_t tx_seq_{0};
    std::uint16_t rx_seq_{0};
    // 伪 TCP 序号。
    std::uint32_t tcp_tx_seq_{0};
    std::uint32_t tcp_tx_ack_{0};
    std::uint32_t tcp_rx_seq_{0};
    // 收数据时先攒在缓冲里，等凑够一个完整 mux 报文再交出去。
    std::vector<std::uint8_t> rxBuffer_;
    // fd 后端的端点最大包长。读按包长请求（超时丢数据的内核语义，见
    // OhosUsbFdDevice.h），写按包长判断要不要补 ZLP。DDK 后端不用它。
    std::size_t fd_packet_size_{512};
    // fd 通道发现的设备序列号（UDID），配对记录的键。
    std::string fd_serial_;
    // 隧道对端端口。open_port() 设定，send_tcp() 用它填 th_dport。
    //
    // 为什么必须存下来而不是在 send_tcp() 里写死 62078：th_dport 是**每包
    // 都要填**的字段，设备侧按 (sport, dport) 配对连接。写死端口的话，
    // 一旦开了别的端口，收发的包就对不上这条连接，设备直接丢弃。
    std::uint16_t tunnelPort_{0};
    // 本端源端口。构造时从递增计数器取值（usbmuxd 用 dev->next_sport
    // 递增分配，设备侧只按 (sport,dport) 配对，不校验取值范围）。
    //
    // ★ 为什么不能固定用 1 ★：隧道断开时若没来得及向设备发 RST（进程被杀、
    // 链路先断、上一轮配对失败直接断开等），设备侧 (sport, 62078) 的半开
    // 连接会一直挂着。下一轮配对若还用同一个 sport，SYN 会被设备直接 RST
    // 拒绝 —— 2026-10-31 真机诊断确证（"设备拒绝连接端口 62078（RST）"，
    // 每一轮都如此）。每个实例换一个 sport，就永远不会撞上之前轮次留下的
    // 半开连接；正常路径 disconnect() 也会补发 RST 主动拆除（双保险）。
    std::uint16_t tunnelSport_{1};
};

} // namespace iPhoneMirror::ohos
