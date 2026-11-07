// SPDX-License-Identifier: GPL-3.0-only
//
// 鸿蒙上的"请求 iPhone 信任本机"（配对 / Pair）实现。
//
// ★ 这个文件解决的问题 ★
//
// 用户插上 iPhone 后，屏幕上从来不弹「信任此电脑」。原因不是线材也不是设备：
// iOS 只在**一个时刻**弹这个框 —— 主机通过 usbmux 隧道连到设备的
// lockdownd(62078) 后**主动发一个 Pair 请求**。上游 Windows 版靠系统里的
// AppleMobileDeviceService 发，Linux 靠 udev 拉起的 usbmuxd 发；**鸿蒙系统
// 两者都没有**，所以本工程必须自己当这个"usbmuxd"：用 USB DDK 直连 iPhone 的
// usbmux 接口 → 建伪 TCP 隧道 → 在隧道上发 lockdownd 的 Pair 请求。
//
// ── 弹窗时序（最容易做错的一处）────────────────────────────────
//
// 发一次 Pair **不会**立刻配对成功。设备会：
//
//   1. 收到 Pair → **弹出「信任此电脑」** → 立刻回一个错误
//      Error: PairingDialogResponsePending
//   2. 用户点「信任」/「不信任」之后，设备才处理完这次配对
//
// 所以主机必须**重复发送同一个请求**直到答复变化（pymobiledevice3 每秒重试，
// iosctl 每 1.2 秒重试）。收到 PairingDialogResponsePending 就重发，收到
// 成功/被拒才算完。**只发一次就判定失败是最常见的错法** —— 用户还没来得及
// 看手机，程序就报"配对失败"。
//
// 另外必须带上：
//
//   PairingOptions: { ExtendedPairingErrors: true }
//
// 没有这个开关，设备只回一句笼统的失败，用户看到的是弹窗却不知道哪一步错了；
// 带上之后错误串能一一对应到真实原因（见下面的错误码对照表）。
//
// ── 错误码 → 真实含义（ExtendedPairingErrors 打开后才有）────────
//
//   PasswordProtected            手机有密码锁，请先解锁
//   PairingDialogResponsePending 弹窗正在等用户点「信任」（**不是失败**）
//   UserDeniedPairing            用户点了「不信任」
//   InvalidHostID                设备不认这个 HostID（配对记录失效/被清）
//   InvalidPairRecord            配对记录被设备拒绝（证书链不合法等）
//
// ── 本文件的分工 ─────────────────────────────────────────────────
//
// 第一步（本文件做的事）：把弹窗**逼出来**，并把设备的真实答复如实报出来。
//   配对记录（PairRecord）先用最小可用形式，设备侧的证书校验发生在用户
//   点「信任」之后，所以弹窗不依赖证书是否完美。
//
// 第二步（OhosPairingCrypto.h 那条线）：补完整 PKI（根 CA + 主机证书 +
//   设备证书）与配对记录的持久化，让"插一次长期免弹窗"成立。
//
// 这条分界不是偷懒，而是**先把不确定的东西变成确定的**：弹窗能不能弹出来
// 与证书是否被接受是两个独立的失败点，混在一起做，出了问题无法定位是哪
// 一环。而第一步的产物（弹窗 + 设备答复）恰恰是第二步的输入。

#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace iPhoneMirror::ohos {

// 配对结果。
enum class PairingOutcome {
    // 设备接受了配对。
    Trusted,
    // 设备还在等用户点「信任」（弹窗已弹出，重试窗口耗尽）。
    AwaitingUser,
    // 用户点了「不信任」。
    DeniedByUser,
    // 手机有密码锁，需先解锁。
    PasswordProtected,
    // 设备不认这个 HostID：配对记录失效或被清。
    InvalidHostId,
    // 设备拒绝了配对记录本身（证书链等不合规）。
    InvalidPairRecord,
    // 链路层失败：没找到 usbmux 接口 / 隧道建不起来 / 读超时。
    LinkFailed,
};

// 把配对结果翻译成一句给用户看的话（中文，带下一步动作）。
//
// 为什么不用错误码糊弄用户：这几种失败的处置完全不同 —— 有的要解锁手机，
// 有的要重新插拔，有的要重试。工具软件的价值往往就在这里。
[[nodiscard]] std::string describe_pairing_outcome(PairingOutcome outcome);

// 发起配对：连上设备的 lockdownd 并请求「信任此电脑」。
//
// deviceId 来自 USB DDK 枚举（见 OhosUsbTransport.cpp 的 enumerate()）。
// timeoutSeconds 是"用户点信任"的最长等待时间；期间设备一直回
// PairingDialogResponsePending 就一直重发。
//
// udid 是设备的唯一标识（序列号），用来索引已保存的配对记录。传空串表示
// 不使用持久化（每次都当新电脑配对）。
//
// 本函数是**阻塞**的（最长 timeoutSeconds），必须放到后台线程调用。
[[nodiscard]] PairingOutcome request_device_trust(std::uint64_t deviceId,
    const std::string& udid, int timeoutSeconds);

// 同一件事，走 usbManager 备用通道（fd 由 ArkTS 侧 getFileDescriptor 拿来）。
//
// ★ UDID 不由调用方提供 ★
//   非系统应用从 getDevices() 拿不到 serial（系统清空），所以 fd 路径的
//   UDID 由 native 自己读：connect_fd() 在定位端点时会读设备描述符与
//   序列号字符串描述符（与 DDK 路径读到的是同一个字符串，两条路径的
//   配对记录因此互认），从这里取出来当配对记录的键。
//
// 其余语义（阻塞、必须放后台线程、轮询弹窗）与 request_device_trust 一致。
[[nodiscard]] PairingOutcome request_device_trust_fd(int fd,
    int timeoutSeconds);

// fd 路径的配对是否正在进行（进程内原子标志）。
//
// DDK 自动配对（OhosDeviceManager 的 maybe_start_pairing）在发起前查它：
// fd 配对一跑就是最长 60 秒，期间 DDK 路径再对同一台设备发 Pair，两条
// 通道会在同一组 bulk 管道上互相偷报文。fd 是先发梯队（不依赖驱动扩展，
// 插线即弹窗），DDK 让路；fd 结束（无论成败）后 DDK 下一轮 refresh 照常
// 发起 —— 若 fd 已配对成功，设备侧已有记录，DDK 的 Pair 会静默成功。
[[nodiscard]] bool fd_pairing_active() noexcept;

} // namespace iPhoneMirror::ohos
