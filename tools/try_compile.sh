#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# try_compile.sh —— 用真实 OHOS NDK 工具链编译本工程的全部翻译单元。
#
# 目的：hvigor 只会在 DevEco 里跑，但"能不能编过"这件事没必要等到那时才知道。
# 这个脚本按 entry/src/main/cpp/CMakeLists.txt 的源列表逐条编译（-c，不链接），
# 因此能抓出全部语法/类型/头文件错误。
#
# 用法：
#   tools/try_compile.sh              # 编译全部
#   tools/try_compile.sh Core/src/Logging.cpp   # 只编一个（相对 entry/src/main/cpp）
#
# SDK 路径可用 OHOS_SDK 环境变量覆盖。

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/.." && pwd)"
CPP="$PROJ/entry/src/main/cpp"

SDK="${OHOS_SDK:-$HOME/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_1}"
if [ ! -x "$SDK/bin/clang++" ]; then
    echo "找不到 clang++：$SDK/bin/clang++" >&2
    echo "请设置 OHOS_SDK 指向包含 bin/clang++ 的 OHOS SDK 目录。" >&2
    exit 2
fi

CXX="$SDK/bin/clang++"
SYSROOT="$SDK/native/sysroot"
OUT="$PROJ/.build-check"
mkdir -p "$OUT"

# 逐条对齐 CMakeLists 的 IPHONEMIRROR_CORE_PORTABLE_SOURCES
PORTABLE=(
    Core/src/Protocol/Plist.cpp
    Core/src/Protocol/QuickTimePacket.cpp
    Core/src/Protocol/QuickTimeSession.cpp
    Core/src/Media/H264.cpp
    Core/src/Media/CoreMedia.cpp
    Core/src/Media/VideoFrameCopy.cpp
    Core/src/Audio/PcmBufferPolicy.cpp
    Core/src/Text/Utf.cpp
    Core/src/Logging.cpp
    Core/src/Transport/Socket.cpp
    Core/src/Transport/AppleUsbSerial.cpp
    Core/src/Transport/AppleUsbSelection.cpp
    Core/src/Transport/UsbMuxClient.cpp
    Core/src/Capture/CaptureSession.cpp
)
OHOS=(
    # AirPlay 接收端宿主（驱动 vendored 协议库，见 third_party/airplayserver）
    ohos/OhosAirPlayReceiver.cpp
    # 原生 mDNS 响应器（取代 @ohos.net.mdns，见 OhosMdnsResponder.h）
    ohos/OhosMdnsResponder.cpp
    ohos/OhosAppleUsbDiscovery.cpp
    ohos/OhosAudioRenderer.cpp
    ohos/OhosCoreApi.cpp
    ohos/OhosDeviceManager.cpp
    ohos/OhosEnvironmentProbe.cpp
    ohos/OhosMediaBackends.cpp
    ohos/OhosPreviewRenderer.cpp
    ohos/OhosSharedGpuFrame.cpp
    # OhosUsbDdk.cpp 必须与 CMakeLists 保持一致：它是 ohos_usb::acquire/release
    # 等共用函数的唯一实现。之前这里漏了它，自检覆盖不到——它与
    # OhosEnvironmentProbe.cpp 的重复定义问题也因此一直没被发现。
    ohos/OhosUsbDdk.cpp
    ohos/OhosUsbTransport.cpp
    ohos/OhosVideoDecoder.cpp
)
EXTRA=(
    napi_bridge.cpp
)

COMMON_FLAGS=(
    --target=aarch64-linux-ohos
    --sysroot="$SYSROOT"
    -std=c++20
    -fPIC
    -DIM_PLATFORM_OHOS
    -finput-charset=UTF-8
    -fexec-charset=UTF-8
    -Wno-unknown-pragmas
    # compat 必须排在最前：它用 __has_include_next 的让路方式接住
    # <format> / <semaphore> / <libusb.h> / <openssl/evp.h>。
    -I"$CPP/ohos/compat"
    -I"$CPP/Core/include"
    -I"$CPP/Core/src"
    -I"$CPP/ohos"
    # AirPlay 接收端协议库的公开头（raop.h / airplay.h / stream.h / dnssd.h /
    # im_dnssd_queue.h）。与 CMakeLists 的 iPhoneMirrorCore PRIVATE include 对齐。
    -I"$CPP/third_party/airplayserver/lib/include"
    -I"$CPP/third_party/airplayserver"
    # 强制预包含语言/库垫片，等价于 CMake 里的 -include。
    -include "$CPP/ohos/compat/ohos_cxx_compat.h"
)

if [ "$#" -gt 0 ]; then
    FILES=("$@")
else
    FILES=("${PORTABLE[@]}" "${OHOS[@]}" "${EXTRA[@]}")
fi

PASS=0
FAIL=0
FAILED_LIST=()

for rel in "${FILES[@]}"; do
    src="$CPP/$rel"
    obj="$OUT/$(echo "$rel" | tr '/' '_').o"
    if [ ! -f "$src" ]; then
        printf '  缺文件  %s\n' "$rel"
        FAIL=$((FAIL + 1))
        FAILED_LIST+=("$rel")
        continue
    fi
    # 日志落到 .build-check/ 而不是 /tmp：鸿蒙工作区的 /tmp 是只读的。
    log="$OUT/$(echo "$rel" | tr '/' '_').log"
    if "$CXX" "${COMMON_FLAGS[@]}" -c "$src" -o "$obj" > "$log" 2>&1; then
        printf '  OK      %s\n' "$rel"
        PASS=$((PASS + 1))
    else
        printf '  失败    %s\n' "$rel"
        FAIL=$((FAIL + 1))
        FAILED_LIST+=("$rel")
    fi
done

echo
echo "通过 $PASS / 失败 $FAIL"

# ---------------------------------------------------------------------------
# 可选：AirPlay 接收端（vendored 第三方库）编译自检。
# 它是 C/C++ 混合、160 个翻译单元，跑一遍要几分钟，所以默认关闭，
# 设 IM_AIRPLAY=1 打开。改了 third_party/airplayserver/ 或它的编译选项后请跑。
#
# 注意：这里的编译选项必须与 third_party/airplayserver/CMakeLists.txt 保持一致，
# 否则"脚本过了但真构建挂了"。特别是：
#   * -D__int64=int64_t        （airplay.c 用了 MSVC 的 __int64）
#   * -Icompat                 （plist/include/plist.h 转发头）
#   * -Icompat/fdk-aac         （arm/*_arm.cpp 空存根）
#   * -Icompat/fdk-aac/libFDK/include （arm/clz_arm.h 等架构头）
#   * mips/ 必须排除
#
# 【踩过的坑，别再犯】fdk-aac 的 include 目录**绝不能手写清单**。
# 曾经这里列了 13 个、CMakeLists 只列了 9 个（漏 libArithCoding/libDRCdec/
# libSACdec），结果自检 160/160 全过、DevEco 真构建却在
# libAACdec/src/channelinfo.h:127 #include "ac_arith_coder.h" 处整库挂掉。
# 现在两边都用 GLOB 收全部 fdk-aac/*/include，天然不会漂移。
# ---------------------------------------------------------------------------
if [ "${IM_AIRPLAY:-0}" = "1" ]; then
    echo
    echo "--- AirPlay 接收端（vendored） ---"
    AP="$CPP/third_party/airplayserver"
    AP_LIB="$AP/lib/lib"
    FDK="$AP_LIB/fdk-aac"
    # fdk-aac 的 include 目录用 GLOB 收全（与 CMakeLists 的
    # file(GLOB IM_FDK_AAC_INCLUDE_DIRS ${AP_LIB}/fdk-aac/*/include) 对齐）。
    # 手写清单会和 CMakeLists 漂移 —— 见上面"踩过的坑"。
    AP_FDK_INCLUDES=()
    while IFS= read -r d; do
        AP_FDK_INCLUDES+=("-I$d")
    done < <(find "$FDK" -mindepth 2 -maxdepth 2 -type d -name include | sort)
    if [ "${#AP_FDK_INCLUDES[@]}" -lt 10 ]; then
        echo "  警告：fdk-aac include 目录只找到 ${#AP_FDK_INCLUDES[@]} 个，vendor 可能不完整" >&2
    fi
    AP_C_FLAGS=(
        --target=aarch64-linux-ohos --sysroot="$SYSROOT" -fPIC
        -I"$AP" -I"$AP/compat" -I"$AP/compat/fdk-aac"
        -I"$AP_LIB" -I"$AP_LIB/crypto" -I"$AP_LIB/curve25519" -I"$AP_LIB/ed25519"
        -I"$AP_LIB/playfair" -I"$AP_LIB/plist" -I"$AP_LIB/plist/plist"
        "${AP_FDK_INCLUDES[@]}"
        -I"$AP/compat/fdk-aac/libFDK/include"
        -D__int64=int64_t -DHAVE_CONFIG_H=0
        -Wno-unused-parameter -Wno-sign-compare -Wno-int-conversion
        # 补 min/max 宏：Windows 上由 <windows.h> 提供，鸿蒙没有，
        # 否则链接期报 undefined symbol: min。头文件内部按
        # `#if !defined(__cplusplus)` 自限，C++（fdk-aac）不受影响。
        # 与 CMakeLists 的 target_compile_options(-include ...) 对齐。
        -include "$AP/compat/im_airplay_compat.h"
    )
    AP_PASS=0; AP_FAIL=0
    # C 部分：协议核心（dnssd.c 有意排除 —— 它 #include <dns_sd.h>，
    # 鸿蒙没有 Bonjour，改由 dnssd_ohos.c 实现同样的一组函数）
    for src in $(find "$AP/lib/lib" -maxdepth 1 -name '*.c' ! -name 'dnssd.c' | sort) \
               $(find "$AP/lib/lib/crypto" "$AP/lib/lib/curve25519" "$AP/lib/lib/ed25519" \
                     "$AP/lib/lib/playfair" "$AP/lib/lib/plist" -maxdepth 1 -name '*.c' | sort) \
               "$AP/dnssd_ohos.c"; do
        # 目标文件名必须带路径信息：vendored 里有同名文件
        # （lib/lib/base64.c 与 lib/lib/plist/base64.c、lib/lib/plist.c 与
        #  lib/lib/plist/plist.c），用 basename 会互相覆盖 → 链接期报
        # "undefined symbol: base64_init" 这类假故障。
        slug="ap_$(echo "${src#"$AP"/}" | tr '/' '_')"
        rel="airplay:${src#"$AP"/}"
        obj="$OUT/$slug.o"
        log="$OUT/$slug.log"
        if "$SDK/bin/clang" "${AP_C_FLAGS[@]}" -c "$src" -o "$obj" > "$log" 2>&1; then
            printf '  OK      %s\n' "$rel"; AP_PASS=$((AP_PASS + 1))
        else
            printf '  失败    %s\n' "$rel"; AP_FAIL=$((AP_FAIL + 1))
        fi
    done
    # C++ 部分：fdk-aac 解码器（编码器与 mips/ 分支排除）
    AP_CXX_FLAGS=(--target=aarch64-linux-ohos --sysroot="$SYSROOT" -fPIC -std=c++14 -O1 -w)
    for src in $(find "$FDK/libAACdec/src" "$FDK/libPCMutils/src" "$FDK/libFDK/src" \
                      "$FDK/libSYS/src" "$FDK/libMpegTPDec/src" "$FDK/libSBRdec/src" \
                      "$FDK/libArithCoding/src" "$FDK/libDRCdec/src" "$FDK/libSACdec/src" \
                      -name '*.cpp' | grep -v '/mips/' | sort); do
        slug="fdk_$(echo "${src#"$FDK"/}" | tr '/' '_')"
        rel="fdk-aac:${src#"$FDK"/}"
        obj="$OUT/$slug.o"
        log="$OUT/$slug.log"
        if "$SDK/bin/clang++" "${AP_CXX_FLAGS[@]}" "${AP_C_FLAGS[@]}" -c "$src" -o "$obj" > "$log" 2>&1; then
            AP_PASS=$((AP_PASS + 1))
        else
            printf '  失败    %s\n' "$rel"; AP_FAIL=$((AP_FAIL + 1))
        fi
    done
    echo "AirPlay 接收端：通过 $AP_PASS / 失败 $AP_FAIL"
    FAIL=$((FAIL + AP_FAIL))
fi

# ---------------------------------------------------------------------------
# 可选的真实链接：编译只证明"每个翻译单元自己没问题"，证明不了"合起来符号齐"。
# 上游的架构把平台实现拆到不同文件里，最容易出的错就是某个符号只在
# Windows/Linux 的实现里有、新平台漏了 —— 那要到链接期才报 undefined。
# 设 IM_LINK=1 打开这一步。
# ---------------------------------------------------------------------------
if [ "$FAIL" -eq 0 ] && [ "${IM_LINK:-0}" = "1" ]; then
    echo
    echo "--- 链接成 libim_core.so（--no-undefined） ---"
    NDK_LIBS=(
        ace_napi.z
        hilog_ndk.z
        native_window
        EGL
        GLESv3
        native_media_core
        native_media_codecbase
        native_media_vdec
        ohaudio
        usb_ndk.z
    )
    LINK_ARGS=()
    for lib in "${NDK_LIBS[@]}"; do
        LINK_ARGS+=("-l$lib")
    done
    SHARED_OUT="$OUT/libim_core.so"
    if "$CXX" --target=aarch64-linux-ohos --sysroot="$SYSROOT" \
        -shared -fPIC \
        -Wl,--no-undefined \
        -o "$SHARED_OUT" "$OUT"/*.o \
        "${LINK_ARGS[@]}" > "$OUT/link.log" 2>&1; then
        echo "  链接成功：$SHARED_OUT"
        if [ -x "$SDK/bin/llvm-nm" ]; then
            EXPORTED="$("$SDK/bin/llvm-nm" -D --defined-only "$SHARED_OUT" \
                | grep -c ' T im_' || true)"
            echo "  动态符号表里导出的 im_* 导出数：$EXPORTED"
        fi
    else
        echo "  链接失败，未定义/缺失符号如下："
        grep -E "undefined|error:" "$OUT/link.log" | head -40
        exit 1
    fi
fi

if [ "$FAIL" -gt 0 ]; then
    echo
    echo "失败文件的诊断（前 40 行）："
    for rel in "${FAILED_LIST[@]}"; do
        echo "=================================================================="
        echo "### $rel"
        head -40 "$OUT/$(echo "$rel" | tr '/' '_').log"
    done
    exit 1
fi
exit 0
