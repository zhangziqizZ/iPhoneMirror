// SPDX-License-Identifier: GPL-3.0-only
//
// USB DDK 的 deviceId ↔ AppleUsbDevice 之间的换算。
//
// 为什么需要单独一个头：deviceId 是鸿蒙 USB DDK 的概念（每次枚举拿到一个
// uint64），而 AppleUsbDevice 是上游 Core 的结构，**不能加字段**（Core/ 是
// 上游逐字拷贝）。于是本工程把 deviceId 编码进 topology_id：
//
//   topology_id = "ohos-dev-" + 16 位十六进制 deviceId
//
// 编码在 OhosUsbTransport.cpp 的 topology_for_device_id()，解码在这里。
// 放在独立头里是因为**两个模块都要用**：传输层要靠它把枚举到的设备还原成
// deviceId 去认领接口，配对层（OhosPairing）要靠它拿到 deviceId 才能开
// usbmux 通道。放任两份实现的话，编码改了而解码没改就是一个只在真机上
// 才暴露的坑。
//
// 之所以不把这套编码塞进 topology_id 之外的别处：topology_id 本来就是
// 上游用来做"跨重枚举稳定身份"的字段，格式由本工程自定，塞 deviceId 进去
// 正好一举两得（详见 Core/src/Transport/QtUsbTransport.h 的注释）。

#pragma once

#include "Transport/QtUsbTransport.h"

#include <cstdint>
#include <string>

namespace iPhoneMirror::ohos {

// topology_id 里承载 deviceId 的前缀（"ohos-dev-" 的字符数）。
inline constexpr std::size_t UsbDeviceIdPrefixLength = 9;

// 从 AppleUsbDevice 的 topology_id 还原 deviceId。
//
// 还原不出来时返回 0 —— 调用方必须把它当成"没有设备"处理，因为 0 不是
// 任何合法的 deviceId（DDK 分配的 id 不会为 0）。
[[nodiscard]] inline std::uint64_t usb_device_id_of(
    const transport::AppleUsbDevice& device) noexcept {
    if (!device.topology_id.starts_with("ohos-dev-")) return 0;
    try {
        return std::stoull(
            device.topology_id.substr(UsbDeviceIdPrefixLength), nullptr, 16);
    } catch (...) {
        return 0;
    }
}

} // namespace iPhoneMirror::ohos
