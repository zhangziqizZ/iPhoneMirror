// SPDX-License-Identifier: GPL-3.0-only
//
// iOS 文件浏览（AFC，Apple File Conduit）的鸿蒙实现。
//
// ── AFC 是什么 ─────────────────────────────────────────────────────
//
// iPhone 被信任后，访达/资源管理器能浏览它的文件（照片在 DCIM、应用沙箱在
// AppContainers…），背后就是 lockdownd 的 com.apple.afc 服务。本工程已经
// 自建了 usbmux 协议栈与配对（OhosUsbMux / OhosPairing），这里补上最后一环：
//
//   ① 在 62078 隧道上发 lockdown StartSession（用配对记录的 HostID）
//   ② 会话建立后整条隧道**切到 TLS**（客户端证书 = 配对记录里的主机证书）
//   ③ 在 TLS 里发 StartService("com.apple.afc")，设备回一个新端口号
//   ④ 重新开一条隧道连那个端口，这条隧道**同样先做 TLS 握手**
//   ⑤ 之后隧道里就是 AFC 帧（magic "CFA6LPAA" + 小端 u64 头）
//
// ── 为什么必须有 OpenSSL ──────────────────────────────────────────
//
// lockdownd 在 StartSession 成功后强制 TLS（iOS 4 之后的规矩），AFC 端口
// 也一样。鸿蒙 NDK 不带 OpenSSL（sysroot 里没有 libssl），但本机 python hnp
// 环境带了完整的 OpenSSL 3（libssloh.so.3 / libcryptooh.so.3，aarch64 OHOS
// 目标）—— 这两个库只依赖 libc，直接拷进 HAP 的 libs 目录随应用分发，
// CMake 以 IMPORTED 方式链接。头文件来自 OpenHarmony 的
// third_party_openssl 仓库（OpenSSL 3.x ABI 兼容，任一 3.x 头都可用）。
//
// ── TLS over 伪 TCP 的实现方式 ────────────────────────────────────
//
// OpenSSL 需要一个"字节流"，而我们只有 mux 的 send()/receive()。标准做法
// 是两个内存 BIO 当缓冲：
//
//   · rbio（读方向）：mux.receive() 收到的密文先灌进 rbio，SSL_read /
//     SSL_do_handshake 从里面消化
//   · wbio（写方向）：SSL_write / 握手产生的密文先攒在 wbio，泵给 mux.send
//
// 每次调用 SSL_* 之后都要 flush_wbio()：OpenSSL 可能只把密文"写进"wbio
// 而没有真正发出。 WANT_READ 时继续从 mux 收、灌 rbio、重试 —— TLS 状态机
// 自己推进，不需要注册任何回调。
//
// 证书验证：与 libimobiledevice 一致 SSL_VERIFY_NONE。libimobiledevice 虽然
// 把设备证书放进了信任链，但 verify 回调恒返回 1 —— 配对记录本身（存在
// 本机沙箱、由用户点"信任"换来）就是这条连接的信任根，校验对端证书对
// 安全没有增益，只会因为 iOS 证书的种种怪癖白白断连。

#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace iPhoneMirror::ohos {

// 文件列表条目（napi 桥负责转成 JS 对象数组）。
struct AfcEntry {
    std::string name;
    bool is_dir{false};
    std::int64_t size{0};
    std::int64_t mtime{0};   // 设备侧的 st_mtime（epoch 秒）
};

// AFC 会话。
//
// 生命周期：open_fd() 一次打开（lockdown + TLS + StartService + AFC 隧道 +
// AFC TLS），之后 list/read/write/... 可反复调用；出错后调用方应丢弃本
// 会话重新 open（设备拔线、锁屏超时都会断隧道）。
//
// ★ 本类不是线程安全的 ★ 调用方（napi 异步工作队列）保证同一时刻只有
// 一个操作在跑（全局互斥，见 OhosIosAfc.cpp 的 manager）。
class OhosIosAfc {
public:
    OhosIosAfc();
    ~OhosIosAfc();
    OhosIosAfc(const OhosIosAfc&) = delete;
    OhosIosAfc& operator=(const OhosIosAfc&) = delete;

    // 完整建立 AFC 通道。fd 是 ArkTS 侧 usbManager.getFileDescriptor 给的
    // usbfs 节点（与配对通道同一个来源）。
    //
    // 成功后 udid() 返回设备序列号（来自 fd 探测阶段的字符串描述符）。
    // 任何一步失败返回 false，diagnostic() 里有逐步的原因（中文）。
    bool open_fd(int fd);

    void close() noexcept;
    [[nodiscard]] bool opened() const noexcept;
    [[nodiscard]] const std::string& udid() const noexcept { return udid_; }
    [[nodiscard]] const std::string& device_name() const noexcept { return device_name_; }

    // 最近一次失败的中文原因（空串 = 没有记录）。给 napi 的 reject 用。
    [[nodiscard]] const std::string& diagnostic() const noexcept { return diagnostic_; }

    // ── AFC 操作（都要求 opened()）────────────────────────────────
    // 返回 false 时 diagnostic() 里有原因。

    [[nodiscard]] bool list_dir(const std::string& path,
        std::vector<AfcEntry>& out);
    [[nodiscard]] bool read_file(const std::string& path,
        std::int64_t max_bytes, std::vector<std::uint8_t>& out);
    [[nodiscard]] bool write_file(const std::string& path,
        const std::vector<std::uint8_t>& data);
    [[nodiscard]] bool make_dir(const std::string& path);
    [[nodiscard]] bool remove_path(const std::string& path);
    [[nodiscard]] bool rename_path(const std::string& from,
        const std::string& to);
    // 单个路径的元信息（顶层目录大小显示用）。不存在返回 false。
    [[nodiscard]] bool stat_path(const std::string& path, AfcEntry& out);

private:
    // ── lockdown 阶段（隧道 62078，明文 → TLS）────────────────────
    struct LockdownResult {
        bool ok{false};
        std::uint16_t service_port{0};
    };
    [[nodiscard]] LockdownResult lockdown_start_service(int fd,
        const std::string& service_name);

    // ── TLS ──────────────────────────────────────────────────────
    // 独立的客户端 SSL 上下文（进程内共享一份：证书都是主机自己的）。
    // 返回裸指针由 SSL_free/SSL_CTX_free 管理，这里用 unique_ptr 自定义删除器。
    struct SslCtxDeleter { void operator()(void* ctx) const noexcept; };
    [[nodiscard]] static std::unique_ptr<void, SslCtxDeleter> make_ssl_ctx();

    // 在一条已经 open_port() 的 mux 隧道上做 TLS 客户端握手。
    // ssl_out 带回可用的 SSL*（生命周期随 ssl_ctx_）。
    [[nodiscard]] bool tls_handshake_on_mux(void* mux, void* ssl_out_opaque);

    // ── AFC 帧层 ─────────────────────────────────────────────────
    [[nodiscard]] bool afc_send(std::uint64_t operation,
        const std::vector<std::uint8_t>& payload);
    // 收一帧响应。data_payload 是 AFC_OP_DATA / FILE_OPEN_RES 的载荷；
    // status_code 是 STATUS 帧的 code（0=成功）。两次内部读（数据帧 +
    // STATUS 帧）都处理。
    [[nodiscard]] bool afc_receive(std::uint64_t& status_code,
        std::vector<std::uint8_t>& data_payload);
    // 发请求 + 收响应的完整回合。失败写 diagnostic。
    [[nodiscard]] bool afc_roundtrip(std::uint64_t operation,
        const std::vector<std::uint8_t>& payload,
        std::vector<std::uint8_t>& response_payload);

    void note(const std::string& text);

    // OpenSSL 前置声明用 void*（头文件不暴露 <openssl/ssl.h>，避免所有
    // 包含它的编译单元都要带上 OpenSSL 头）。
    void* ssl_ctx_{nullptr};   // SSL_CTX*
    void* ssl_{nullptr};       // SSL*（当前隧道上的会话）
    void* rbio_{nullptr};      // BIO*
    void* wbio_{nullptr};      // BIO*

    std::unique_ptr<class OhosUsbMux> mux_;   // AFC 隧道所在的 mux
    std::string udid_;
    std::string device_name_;
    std::string diagnostic_;
    std::uint64_t packet_num_{0};
    bool opened_{false};
};

} // namespace iPhoneMirror::ohos
