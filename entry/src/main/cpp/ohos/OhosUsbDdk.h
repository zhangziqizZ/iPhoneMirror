// SPDX-License-Identifier: GPL-3.0-only
//
// OHOS USB DDK 的最小封装。
//
// 鸿蒙上应用访问 USB 的唯一通道是 USB DDK（"扩展外设驱动"），不是 libusb-1.0。
// 相关头文件在不同 SDK 版本里的落点不完全一致（usb/usb_ddk_api.h 与平铺的
// usb_ddk_api.h 都出现过），这里用 __has_include 两种都认，避免为一个 include
// 路径反复折腾。库名是 libusb_ndk.z.so（见 CMakeLists.txt）。
//
// 权限：ohos.permission.ACCESS_DDK_USB（见 entry/src/main/module.json5）。
// 另外 OH_Usb_GetDevices 只会返回「驱动配置信息里按 vid 过滤过」的设备，所以
// 应用侧需要把 Apple 的 VID 0x05ac 配进 driver 配置，否则列表恒为空。

#pragma once

#include <cstdint>

#if defined(__has_include)
#  if __has_include(<usb/usb_ddk_api.h>)
#    include <usb/usb_ddk_api.h>
#    include <usb/usb_ddk_types.h>
#    define IM_HAVE_OHOS_USB_DDK 1
#  elif __has_include(<usb_ddk_api.h>)
#    include <usb_ddk_api.h>
#    include <usb_ddk_types.h>
#    define IM_HAVE_OHOS_USB_DDK 1
#  endif
#endif

#ifndef IM_HAVE_OHOS_USB_DDK
// 没有 USB DDK 头时仍要让整个翻译单元可编译，好让上层给出明确失败而不是编译
// 中断。此时 IM_OHOS_USB_DDK_AVAILABLE 保持 0，所有调用点走失败分支。
#  define IM_OHOS_USB_DDK_AVAILABLE 0
#else
#  define IM_OHOS_USB_DDK_AVAILABLE 1
#endif

namespace iPhoneMirror::ohos_usb {

#if IM_OHOS_USB_DDK_AVAILABLE

// DDK 是**进程级常驻**资源：Init 只在第一次 acquire 时发生（且只在成功后才算数），
// 之后所有 acquire 都只是加引用计数；release 只还计数，**不会**销毁会话。
//
// 也就是说 acquire/release 不是"开/关 DDK"，而是"用/用完这条已经开着的连接"。
// 这一点与本文件最早那版（Init/Release 严格配对）不同，原因是实测：
// 反复 Init/Release 会让进程崩溃（2026-09-19 09:34 的三条 cppcrash），
// 而只 Init 一次是稳的。细节见 OhosUsbDdk.cpp 里 acquire()/release() 的注释。
[[nodiscard]] bool acquire() noexcept;
void release() noexcept;
[[nodiscard]] bool available() noexcept;

// OH_Usb_Init() 最近一次的**原始**返回值。
//
// 必须原样传出去，不要压成 -1：USB_DDK_NO_PERM(201) 与
// USB_DDK_INVALID_OPERATION(27400002) 是两条完全不同的处置路径 ——
// 前者去补 ACCESS_DDK_USB 的 ACL，后者多半是"调用方不在 DriverExtensionAbility
// 生命周期里"。把两者合并成一句"检查权限"，方向就全错了。
[[nodiscard]] int last_init_error() noexcept;

struct DdkSession {
    bool held{};
    DdkSession() : held(acquire()) {}
    ~DdkSession() { if (held) release(); }
    DdkSession(const DdkSession&) = delete;
    DdkSession& operator=(const DdkSession&) = delete;
    [[nodiscard]] bool ok() const noexcept { return held; }
};

// DDK 的错误码是负值（USB_DDK_SUCCESS 为 0），这里压成 libusb 风格的负值，
// 以便复用上游 UsbError(operation, code) 的表达方式。
[[nodiscard]] int to_libusb_style_error(int ddk_code) noexcept;
[[nodiscard]] const char* error_text(int ddk_code) noexcept;

#else

[[nodiscard]] inline bool acquire() noexcept { return false; }
inline void release() noexcept {}
[[nodiscard]] inline bool available() noexcept { return false; }
[[nodiscard]] inline int last_init_error() noexcept { return -1; }

struct DdkSession {
    bool held{};
    [[nodiscard]] bool ok() const noexcept { return false; }
};

[[nodiscard]] inline int to_libusb_style_error(int ddk_code) noexcept {
    return ddk_code == 0 ? 0 : -1;
}
[[nodiscard]] inline const char* error_text(int) noexcept {
    return "OHOS USB DDK 不可用（缺少 usb_ddk_api.h）";
}

#endif

} // namespace iPhoneMirror::ohos_usb
