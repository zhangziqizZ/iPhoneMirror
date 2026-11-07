// SPDX-License-Identifier: GPL-3.0-only
//
// 配对/枚举链路的 Apple 设备 PID 判定。
//
// ── 为什么不能直接用 Core 的 is_apple_mobile_capture_product_id() ──────
//
// Core（上游逐字拷贝，**不可改**）里的 `is_apple_mobile_capture_product_id()`
// 是一张**采集**白名单：24 项稀疏列表，语义是"这台设备**能做投屏采集**"。
// 依据是 `config/apple-mobile-capture-pids.txt` 与 Apple iPhone USB 驱动条目，
// 明确排除 Apple TV / Watch / HomePod。
//
// 但**配对**需要的判定宽得多：只要设备在 USB 上可见、暴露 usbmux 接口、
// 跑着 lockdownd，就该能被配对。这两件事不是一回事：
//
//   · iPhone 16e 之类新机型的 PID 不在 Core 的 24 项名单里
//     → 被 Core 的白名单过滤掉
//     → **OH_Usb_GetDevices() 的结果里根本没有这台设备**
//     → 枚举为空 → 不触发配对 → 界面毫无动静（就是"插线没反应"）
//
//   · 而上游 usbmuxd 用的是**区间**，不是白名单：
//       src/usb.h:
//         #define PID_RANGE_LOW 0x1290
//         #define PID_RANGE_MAX 0x12af
//       udev 规则 39-usbmuxd.rules:
//         SUBSYSTEM=="usb", ATTR{idVendor}=="05ac", ATTR{idProduct}=="12[9a][0-9a-f]*"
//
//     区间写法天然覆盖新机型，不需要每出一代 iPhone 就补一次表。
//
// ★ 所以这里按上游的区间口径另立一条判定 ★
//   —— 它只用于**枚举与配对**这条链路，不参与"能不能采集"的判断。
//   采集链路由 QuickTime(0xFF/0x2A) 接口的存在性把关
//   （`AppleUsbDevice::quicktime_configuration`），Apple TV/Watch/HomePod
//   本来就不暴露那个接口，天然进不了采集。
//
// ── 与 Core 白名单的关系 ──────────────────────────────────────────────
//
// 本判定是**Core 白名单的超集**（覆盖 0x1290..0x12AF 整个区间）。
// 两者同时成立时结论一致；只在 Core 名单之外的 PID 上，本判定更宽松 ——
// 那正是需要放行的"新机型"。Core 的采集白名单本身一个字都没动。

#pragma once

#include <cstdint>

namespace iPhoneMirror::ohos {

// 上游 usbmuxd src/usb.h 的 PID_RANGE_LOW / PID_RANGE_MAX。
inline constexpr std::uint32_t AppleMobilePidRangeLow = 0x1290;
inline constexpr std::uint32_t AppleMobilePidRangeHigh = 0x12AF;

// 05AC:110A —— USB-C 转 3.5mm 耳机转接头。它是 Apple 的 VID，但不是 iOS 设备。
inline constexpr std::uint32_t AppleAudioAdapterProductId = 0x110A;

// 这台设备是否**可能**是一台需要配对的 iOS 设备。
//
// 判据 = 上游 usbmuxd 的区间 ∪ 耳机转接头的排除项。
//
// 为什么把耳机转接头单独排除而不是靠区间自然排除：它的 PID 是 0x110A，
// 落在 0x1290..0x12AF 之外，本来就被区间排除掉了。但显式写出来是为了
// 表达"这是有意为之"，而不是"碰巧不在区间里" —— 免得后人看到区间
// 改动时顺手把它放进来。
[[nodiscard]] inline bool is_apple_pairable_product_id(
    std::uint32_t product_id) noexcept {
    if (product_id == AppleAudioAdapterProductId) return false;
    return product_id >= AppleMobilePidRangeLow &&
           product_id <= AppleMobilePidRangeHigh;
}

} // namespace iPhoneMirror::ohos
