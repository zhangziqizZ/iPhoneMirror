// SPDX-License-Identifier: GPL-3.0-only
//
// 鸿蒙实现：共享采集状态机问到的 Apple USB 设备状态查询。
//
// Windows 版读 SetupAPI / cfgmgr32 的 PnP 证据；Linux 版换成 libusb 枚举；
// 鸿蒙版的答案来自 USB DDK 枚举（经 OhosUsbTransport 提供的 QtUsbContext）。
//
// 只定义共享代码路径真的会走到的两个查询。Device/AppleUsbDiscovery.h 里其余
// 声明描述的是 libusb-win32 过滤驱动栈及其 PnP 接口状态——鸿蒙与 Linux 一样
// 根本没有过滤驱动这一层，那些只在 CaptureSession 的 Windows 分支里被调用。

#include "Device/AppleUsbDiscovery.h"

#include "Transport/QtUsbTransport.h"

namespace iPhoneMirror::device {

bool is_apple_usb_parent_present(std::string_view serial) noexcept {
    if (serial.empty()) return false;
    try {
        transport::QtUsbContext context(false);
        transport::AppleUsbIdentity identity;
        identity.serial = serial;
        return context.find_apple_device(identity).has_value();
    } catch (...) {
        // 枚举失败不等于设备已经离开。
        return false;
    }
}

AppleUsbFilterSafetyResult inspect_apple_usb_filter_stack(
    std::string_view serial) noexcept {
    (void)serial;
    // 这里要防的是 libusb-win32 上层过滤驱动叠在 Apple 的 KMDF 过滤驱动上。
    // 鸿蒙上链路里没有过滤驱动，该风险不存在，所以结论是安全。
    return {
        .safety = AppleUsbFilterSafety::Safe,
        .diagnostic = "ohos: USB DDK 经系统服务直接访问设备，"
                      "链路中没有 Apple USB 过滤驱动",
    };
}

} // namespace iPhoneMirror::device
