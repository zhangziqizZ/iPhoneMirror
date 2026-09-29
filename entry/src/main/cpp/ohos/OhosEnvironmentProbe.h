// SPDX-License-Identifier: GPL-3.0-only
//
// 鸿蒙环境就绪探测。
//
// 对照上游：Windows 版问的是"Apple Mobile Device Support 装没装、跑没跑，USB
// 后端看不看得见手机"；Linux 版换成 usbmuxd 的 unix socket + udev 对
// /dev/bus/usb 的授权。
//
// 鸿蒙上只有第一半有对应物，而且答案不同：
//  - 系统**没有** usbmuxd 服务。udid/Lockdown 元数据要么随包自带 usbmuxd，
//    要么改用 Lockdown 协议直连，两者都还没有。所以「未安装」是诚实结论，
//    不是一个需要修的故障。
//  - USB 访问不是 udev 授权模型，而是 USB DDK + ACCESS_DDK_USB 权限 +
//    driver 配置里按 VID 过滤。因此判定方式变成"OH_Usb_Init 能不能成功、
//    OH_Usb_GetDevices 里有没有 Apple 设备"。
//
// 采集是否可行，最终取决于「USB DDK 能看到这台 iPhone」——这比 Linux 的
// udev/usbmuxd 组合更简单，也更硬。

#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace iPhoneMirror::device::ohos_probe {

enum class UsbmuxdAvailability {
    // 系统里没有 usbmuxd 服务，也没有随包提供的替代端点。鸿蒙的正常状态。
    NotInstalled,
    // 套接字存在但连不上：确实有端点，但守护进程有问题。
    SocketPresentNotAccepting,
    Connected,
};

// USB DDK 这一侧的三种结论，对应三种不同的修法。
enum class UsbDdkAccess {
    Unknown,
    // Init 成功且枚举到 Apple 设备：采集的 USB 前提已满足。
    Ready,
    // Init 成功但没有 Apple 设备。**必须分两种**（靠 usb_devices_total 区分，
    // 两者的修法完全不同）：
    //   total == 0 → OH_Usb_GetDevices 把**全部**设备都过滤掉了：module.json5 里
    //               driver 扩展的 vid/pid「驱动配置信息」还没生效（驱动没被 bind，
    //               或 pid 不在白名单里）；
    //   total > 0  → 过滤在起作用，只是这批设备里没有 VID 0x05AC 的（线没插好，
    //               或插的是别的 Apple 设备）。
    // 只报"看不到 Apple 设备"会把这两条路并成一句，读的人不知道该去查驱动配置
    // 还是去查线 —— 现场已经被这种合并过一次。
    NoAppleDeviceVisible,
    // Init 失败：权限没申下来（ACCESS_DDK_USB），或 DDK 服务不可达。
    InitFailed,
    // 连 usb_ddk_api.h 都没有：该 SDK 未提供 USB DDK。
    DdkUnavailable,
};

struct Report {
    UsbmuxdAvailability usbmuxd{UsbmuxdAvailability::NotInstalled};
    std::string usbmuxd_socket_path;
    UsbDdkAccess usb_ddk{UsbDdkAccess::Unknown};
    int ddk_init_result{};
    std::string ddk_diagnostic;
    // OH_Usb_GetDevices 实际返回的设备台数（**未**按 Apple 身份过滤）。
    // 与 apple_usb_devices 一起读才能定位失败方式，见 UsbDdkAccess 的注释。
    std::uint32_t usb_devices_total{};
    std::uint32_t apple_usb_devices{};
    // 第一台 Apple 设备的**配置描述符**读取结果。
    //
    // 为什么单独记这一项：OH_Usb_GetDevices + OH_Usb_GetDeviceDescriptor 成功，
    // 只说明"系统允许我们看见这台 iPhone"；真正决定能不能采集的是
    // OH_Usb_GetConfigDescriptor —— 读不到配置就沒有接口與端点，
    // 设备会出现在列表里，但按下「开始投屏」必然失败。
    // 真机上（2026-09-19 09:51，驱动扩展 bind 成功之后）正是卡在这一步：
    // 系统日志给出 `GetConfigDescriptor_ failed, error code is -1`。
    bool apple_config_readable{};
    int apple_config_result{};
    // 该设备的配置是通过哪个 configIndex 读到的（0 = 标准 0 基索引，
    // 1 = 头文件注释所说的 bConfigurationValue 口径）。两者都试过才知道。
    int apple_config_index{};
    std::vector<std::string> usbmuxd_candidate_paths;
};

// 全程只读：不打开设备做配置变更、不启动任何服务。
[[nodiscard]] Report probe() noexcept;

// 人类可读的诊断串，纯函数，便于在没有真机时测试。
[[nodiscard]] std::wstring describe(const Report& report);

// 有线采集的 USB 前提是否满足。纯函数。
[[nodiscard]] bool wired_capture_ready(const Report& report) noexcept;

} // namespace iPhoneMirror::device::ohos_probe
