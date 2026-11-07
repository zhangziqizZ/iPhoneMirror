// SPDX-License-Identifier: GPL-3.0-only
//
// 通过 usbfs fd 读设备描述符，定位 usbmux 接口与它的 bulk 端点。
//
// ★ 为什么需要自己解析描述符，而不是让 ArkTS 侧把端点信息传下来 ★
//
// ArkTS 侧的 usbManager.getDevices() 确实会带回 configs/interfaces/endpoints，
// 但那里面缺两样决定成败的东西：
//
//   1. **哪个配置是当前活动的**。usbfs 的 bulk 传输只在**活动配置**里找端点
//      （内核的 findintfep() 遍历的是 dev->config，不是全部配置）。iPhone 的
//      usbmux 接口（0xFF/0xFE）在若干配置里都有，但活动配置未必是它。
//   2. **序列号**。非系统应用的 getDevices() 把 serial 清空了（服务侧
//      UsbHostManager::GetDevices() 对非系统应用 dev.SetmSerial("")），
//      而配对记录要用 UDID 当键。
//
// @ohos.usbManager 的 d.ts 其实写明了这一点：
//   "Third-party applications are not allowed to obtain the device serial
//    number from the serial field. They need to request permission using
//    requestRight and then initiate a control transfer to obtain it."
// —— 官方给的路子就是**授权后自己发控制传输**。本文件走的就是这条。
//
// ── 控制传输为什么不需要先认领接口 ──
//
// 内核的 check_ctrlrecip()：
//   · vendor 请求（USB_TYPE_VENDOR）→ 直接 return 0
//   · standard + device recipient（GET_DESCRIPTOR 就是）→ 也不需要认领
// 只有 standard + interface recipient 才走 checkintf()（要认领）。
// 我们要发的全是 device recipient 的标准请求 ⇒ 一次都不必认领。

#pragma once

#include "OhosUsbFdTransport.h"

#include <cstdint>
#include <string>
#include <vector>

namespace iPhoneMirror::ohos {

// 一个 usbfs 设备上与 usbmux 相关的事实。
struct OhosUsbFdMuxInfo {
    // 设备的 USB 序列号字符串（iPhone 上就是 UDID，形如
    // "00008030-001234567890ABCD"）。读不到时为空串。
    std::string serial;
    // 当前活动配置的 bConfigurationValue（0 = 设备未配置）。
    std::uint8_t active_config{0};
    // usbmux 接口的接口号。
    std::uint8_t interface_number{0};
    // usbmux 接口的备用设置号（alternate setting）。
    std::uint8_t alternate_setting{0};
    // usbmux 接口的 bulk 端点**完整地址**（含 0x80 方向位）：
    //   bulk_in  的 0x80 位是 1（设备→主机）
    //   bulk_out 的 0x80 位是 0（主机→设备）
    //
    // ★ 必须传完整地址而不是端点号 ★
    //   内核的 findintfep() 是拿 bEndpointAddress 逐个比对的
    //   （"if (endpt->bEndpointAddress == ep)"），传端点号会找不到接口。
    std::uint8_t bulk_in{0};
    std::uint8_t bulk_out{0};
    // 该配置在设备上的 bConfigurationValue（用来 set_configuration）。
    std::uint8_t config_value{0};
    // 端点最大包长（wMaxPacketSize，取 IN/OUT 里较大的那个）。
    //
    // 两个用途：
    //   1. 读 bulk 必须按包长请求 —— 内核 usb_bulk_msg 超时会 kill URB 并
    //      **丢弃已收的部分数据**（usb_start_wait_urb → usb_kill_urb），按
    //      49KB 请求一旦数据流不凑满就会整块丢。按包长请求则"一包即返回"。
    //   2. 写 bulk 时长度恰好是包长整数倍要补零长包（ZLP）。
    std::uint16_t packet_size{0};
};

// 读描述符并定位 usbmux 接口。
//
// 失败原因写进 error（中文，可直接进诊断行）。
//
// ★ 定位规则与 DDK 路径一致（上游 usbmuxd 的 OR 口径）★
//   class == 0xFF || subclass == 0xFE || protocol == 2
//   且该接口必须有**成对**的 bulk IN / bulk OUT。
//
// ★ 会改设备状态吗 ★
//   只有当设备当前的活动配置里**没有** usbmux 接口时，才会发
//   SET_CONFIGURATION 切到有 usbmux 接口的那个配置。这是主机必须做的事
//   （USB 规范里配置由主机选定），不是"擅自改设备"。切完会再读一次
//   GET_CONFIGURATION 确认。
[[nodiscard]] bool discover_usb_fd_mux(OhosUsbFdTransport& transport,
    OhosUsbFdMuxInfo& info, std::string& error);

// 只读地读设备序列号（iPhone 上是 UDID）。
//
// 单独暴露是因为配对记录需要它，而调用方可能已经拿到了 mux 信息。
[[nodiscard]] bool read_usb_fd_serial(OhosUsbFdTransport& transport,
    std::string& serial, std::string& error);

// 探活：这个 fd 背后的设备还活着吗？
//
// ★ 为什么需要它 ★ fd 是 ArkTS 侧缓存复用的（同一次 open 的描述符）。iPhone
// 重枚举（拔插、信任切换后重连）时内核会**销毁旧的 usbfs 节点**，缓存里那份
// fd 立刻变成死描述符 —— 之后所有 ioctl 都返回 ENODEV（"no such device"）。
// 而缓存的键是 device.name（"busNum-devAddr"），重插后地址相同就判不出新旧。
//
// 做法：GET_DESCRIPTOR 是 device-recipient 的标准请求（免认领，见文件头），
// 一次控制传输足够分辨生死，代价毫秒级。调用方拿到 false 就该丢弃缓存重开。
[[nodiscard]] bool probe_usb_fd_alive(OhosUsbFdTransport& transport);

// fd 权限探针：对 fd 依次发 CONNECTINFO / GETDRIVER / CLAIMINTERFACE 三条
// ioctl，把各自的 errno 拼成一行报告。bulk 传输被拒（EPERM/EACCES）时，
// 这一行能分辨拒绝发生在哪一层：
//   · CONNECTINFO 失败            ⇒ fd/节点层面已断，探活没覆盖到的异常；
//   · GETDRIVER 显示被内核驱动占用 ⇒ bulk 的 claimintf 会 EBUSY；
//   · CLAIM 被拒（EPERM/EACCES）  ⇒ 命令级沙箱限制，认领都做不到；
//   · CLAIM ok 但 bulk 仍被拒     ⇒ 拒绝在提交路径或 allowxperm 白名单。
// 侦查专用，不改设备状态（claim 会保留 —— 对后续 bulk 反而有利）。
[[nodiscard]] bool diagnose_usb_fd_access(OhosUsbFdTransport& transport,
    unsigned interface_number, std::uint8_t bulk_in_endpoint,
    std::string& report);

} // namespace iPhoneMirror::ohos
