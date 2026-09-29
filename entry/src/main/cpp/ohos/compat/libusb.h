// SPDX-License-Identifier: GPL-3.0-only
//
// libusb-1.0 头文件垫片。
//
// 上游 Transport/QtUsbTransport.h 第一行就是 `#include <libusb.h>`，并把
// `libusb_context*` / `libusb_device_handle*` 作为私有成员暴露在类里。OHOS NDK
// 不提供 libusb-1.0：鸿蒙上应用访问 USB 的唯一通道是 USB DDK
// （usb/usb_ddk_api.h，库 libusb_ndk.z.so），它是一套面向「扩展外设驱动」的
// 接口，不是 libusb 的 API。
//
// 因此本工程的 OHOS 分支不编译上游的 Transport/QtUsbTransport.cpp，改由
// ohos/OhosUsbTransport.cpp 用 USB DDK 实现 QtUsbContext / QtUsbConnection 这套
// 已声明的接口（与 Linux 版用 LinuxUsbConfiguration.cpp 替换 LibUsb0Transport
// 是同一手法）。为了让 QtUsbTransport.h 这个「接口声明」在 OHOS 上仍然可编译，
// 这里只需要补上三个不完整类型声明。
//
// 若工具链恰好自带真正的 libusb.h（例如用户自行引入了 libusb），
// `#include_next` 会让位给真头文件，垫片自动失效。

#pragma once

#if defined(__has_include_next)
#  if __has_include_next(<libusb.h>)
#    include_next <libusb.h>
#    define IM_OHOS_HAVE_REAL_LIBUSB 1
#  endif
#endif

#ifndef IM_OHOS_HAVE_REAL_LIBUSB

struct libusb_context;
struct libusb_device;
struct libusb_device_handle;

#endif // IM_OHOS_HAVE_REAL_LIBUSB
