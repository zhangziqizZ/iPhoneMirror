# SPDX-License-Identifier: GPL-3.0-only
#
# entry/src/main/cpp/CMakeLists.txt —— iPhoneMirror 鸿蒙 PC 原生构建入口
#
# 设计原则（与上游 Linux 移植分支 docs/LINUX_PORT.md 同一套纪律）：
#   * Core/ 目录是上游 src/Core 的**逐字拷贝**，本工程一行都不改；
#     它自带的 CMakeLists.txt 只作对照留存，不参与构建。
#   * 平台相关的东西一律**新增文件**：OHOS 后端全部放 ohos/ 下。
#   * 源列表沿用上游 IPHONEMIRROR_CORE_PORTABLE_SOURCES 的结构，
#     只把 Windows/Linux 共用的 libusb-1.0 传输层换成 USB DDK 实现。
#   * 上游文件用到而 OHOS libc++ 尚未提供的语言设施（std::jthread /
#     std::stop_token / std::format / <semaphore>）与库（OpenSSL EVP），
#     全部由 ohos/compat/ 下的垫片在构建层补齐，不改上游一行。
#
# 产物：iPhoneMirrorCore（静态库）+ im_core（NAPI 共享库，ArkTS 侧
#       import ... from 'libim_core.so'）。

cmake_minimum_required(VERSION 3.16)
# C 是必需的：AirPlay 接收端协议库（vendored AirPlayServer v1.1.2 的 lib/）
# 全部是 C 源码，用 C 编译器编；工程其余部分是 C++。
project(im_core C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(IM_CPP_DIR ${CMAKE_CURRENT_SOURCE_DIR})
set(IM_CORE_DIR ${IM_CPP_DIR}/Core)
set(IM_OHOS_DIR ${IM_CPP_DIR}/ohos)
set(IM_COMPAT_DIR ${IM_OHOS_DIR}/compat)

# ---------------------------------------------------------------------------
# 可移植源：逐条对齐上游 src/Core/CMakeLists.txt 的
# IPHONEMIRROR_CORE_PORTABLE_SOURCES（"平台中性协议、容器、码流、传输与解码帧"
# 那一组），唯一例外是 Transport/QtUsbTransport.cpp —— 它直接依赖 libusb-1.0，
# 而 OHOS 只提供 USB DDK，故替换为 ohos/OhosUsbTransport.cpp。
# ---------------------------------------------------------------------------
set(IPHONEMIRROR_CORE_PORTABLE_SOURCES
    ${IM_CORE_DIR}/src/Protocol/Plist.cpp
    ${IM_CORE_DIR}/src/Protocol/QuickTimePacket.cpp
    ${IM_CORE_DIR}/src/Protocol/QuickTimeSession.cpp
    ${IM_CORE_DIR}/src/Media/H264.cpp
    ${IM_CORE_DIR}/src/Media/CoreMedia.cpp
    ${IM_CORE_DIR}/src/Media/VideoFrameCopy.cpp
    ${IM_CORE_DIR}/src/Audio/PcmBufferPolicy.cpp
    ${IM_CORE_DIR}/src/Text/Utf.cpp
    ${IM_CORE_DIR}/src/Logging.cpp
    ${IM_CORE_DIR}/src/Transport/Socket.cpp
    ${IM_CORE_DIR}/src/Transport/AppleUsbSerial.cpp
    ${IM_CORE_DIR}/src/Transport/AppleUsbSelection.cpp
    ${IM_CORE_DIR}/src/Transport/UsbMuxClient.cpp
    ${IM_CORE_DIR}/src/Capture/CaptureSession.cpp
)

# ---------------------------------------------------------------------------
# OHOS 后端：上游 Windows 侧的 CoreApi.cpp / DeviceManager.cpp /
# AppleUsbDiscovery.cpp / MediaFoundationDecoder.cpp / WasapiRenderer.cpp /
# D3D11PreviewRenderer.cpp，在 Linux 上分别由 LinuxCoreApi.cpp /
# LinuxDeviceManager.cpp / LinuxAppleUsbDiscovery.cpp /
# LinuxFFmpegVideoDecoder.cpp / LinuxPipeWireAudioRenderer.cpp /
# LinuxPlaceboRenderer.cpp 承担；鸿蒙对应为下面这一组。
# ---------------------------------------------------------------------------
set(IPHONEMIRROR_CORE_OHOS_SOURCES
    ${IM_OHOS_DIR}/OhosAirPlayReceiver.cpp
    ${IM_OHOS_DIR}/OhosMdnsResponder.cpp
    ${IM_OHOS_DIR}/OhosAppleUsbDiscovery.cpp
    ${IM_OHOS_DIR}/OhosAudioRenderer.cpp
    ${IM_OHOS_DIR}/OhosCoreApi.cpp
    ${IM_OHOS_DIR}/OhosDeviceManager.cpp
    ${IM_OHOS_DIR}/OhosEnvironmentProbe.cpp
    ${IM_OHOS_DIR}/OhosMediaBackends.cpp
    ${IM_OHOS_DIR}/OhosPreviewRenderer.cpp
    ${IM_OHOS_DIR}/OhosSharedGpuFrame.cpp
    ${IM_OHOS_DIR}/OhosUsbDdk.cpp
    ${IM_OHOS_DIR}/OhosUsbTransport.cpp
    ${IM_OHOS_DIR}/OhosVideoDecoder.cpp
)

# ---------------------------------------------------------------------------
# AirPlay 接收端（vendored 第三方协议库 + 鸿蒙后端）。
# 上游在 Windows 上靠「独立进程 WirelessHost.exe + 预编译 airplay2dll.dll
# + Apple dnssd.dll」实现；鸿蒙上这三者都不存在，改为把协议库直接编进本工程，
# mDNS 广播交给 ArkTS 的 @ohos.net.mdns（见 third_party/airplayserver/）。
# ---------------------------------------------------------------------------
add_subdirectory(third_party/airplayserver)

add_library(iPhoneMirrorCore STATIC
    ${IPHONEMIRROR_CORE_PORTABLE_SOURCES}
    ${IPHONEMIRROR_CORE_OHOS_SOURCES}
)

target_include_directories(iPhoneMirrorCore
    PUBLIC  ${IM_CORE_DIR}/include
    PRIVATE
        # AirPlay 接收端协议库的公开头（raop.h / airplay.h / stream.h）；
        # OhosAirPlayReceiver.cpp 要驱动它，NAPI 桥只读它导出的状态。
        ${IM_CPP_DIR}/third_party/airplayserver/lib/include
        ${IM_CPP_DIR}/third_party/airplayserver
        # compat 必须排在最前：它用 include_next 的让路方式接住
        # <format> / <semaphore> / <libusb.h> / <openssl/evp.h>。
        ${IM_COMPAT_DIR}
        ${IM_CORE_DIR}/src
        ${IM_OHOS_DIR}
)

target_compile_options(iPhoneMirrorCore PRIVATE
    # 强制预包含语言/库垫片；上游工具链补齐后垫片自动失效。
    -include ${IM_OHOS_DIR}/compat/ohos_cxx_compat.h
    -finput-charset=UTF-8 -fexec-charset=UTF-8
    -Wno-unknown-pragmas
)

target_compile_definitions(iPhoneMirrorCore PRIVATE
    IM_PLATFORM_OHOS
)

# OhosAirPlayReceiver.cpp 在这个库里，它调用 vendored 协议库的 raop_* /
# airplay_* / dnssd_*。显式声明依赖，CMake 才能保证最终链接顺序正确
# （静态库从左到右解析符号，不声明的话顺序只能靠 target 书写次序碰运气）。
target_link_libraries(iPhoneMirrorCore PUBLIC airplay_receiver)

# ---------------------------------------------------------------------------
# NAPI 桥：导出 libim_core.so。ArkTS 侧 import ... from 'libim_core.so'。
# ---------------------------------------------------------------------------
add_library(im_core SHARED ${IM_CPP_DIR}/napi_bridge.cpp)

target_include_directories(im_core PRIVATE
    ${IM_COMPAT_DIR}
    ${IM_CORE_DIR}/include
    # 桥要用 Text/Utf.h 的 utf8_to_wide / wide_to_utf8 做 wchar_t 编组；
    # Core 的私有头按 "#include "Subdir/File.h"" 约定放在 src/ 下。
    ${IM_CORE_DIR}/src
    ${IM_OHOS_DIR}
    ${IM_CPP_DIR}/third_party/airplayserver
    ${NATIVE_APP_DIR}/include
)

target_compile_options(im_core PRIVATE
    -finput-charset=UTF-8 -fexec-charset=UTF-8
)

target_link_libraries(im_core
    iPhoneMirrorCore
    airplay_receiver
    # OHOS NDK 的库 soname 与普通 Unix 命名不同，直接给完整 .so 文件名，
    # 避免 -lxxx 找不到。带 .z 后缀的一律是 NDK 稳定 ABI 版本。
    ace_napi.z            # NAPI 运行时
    libhilog_ndk.z.so     # 日志（Logging.cpp 走 OH_LOG_Print）
    libnative_window.so   # XComponent surface → OHNativeWindow
    libEGL.so             # 预览 GL 上下文
    libGLESv3.so
    libnative_media_core.so      # AVCodec 公共类型
    libnative_media_codecbase.so # OH_AVCodec 基类
    libnative_media_vdec.so      # OH_VideoDecoder（H.264/HEVC 解码）
    libohaudio.so                # OHAudio 播放
    libusb_ndk.z.so              # USB DDK（usb/usb_ddk_api.h）
)

# 说明：OHOS 上应用访问 USB 走 USB DDK，需要 ohos.permission.ACCESS_DDK_USB
# （见 entry/src/main/module.json5）；该权限与 macOS/USB 时代的 USB_MANAGER
# 不是同一个，且设备按 VID 过滤后才出现在 OH_Usb_GetDevices 的结果里。
