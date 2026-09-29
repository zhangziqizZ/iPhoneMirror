#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# shim_selftest.sh —— 编译并**运行**构建层垫片自检。
#
# 本脚本编出的可执行文件是 aarch64-linux-ohos，而鸿蒙 PC 本身就是
# OpenHarmony，因此可以直接运行（不需要模拟器、不需要真机）。这让
# "自制 std::format / std::jthread 的行为是否与标准一致"这件事可以真的被测，
# 而不是靠读代码相信。
#
# 用法：tools/shim_selftest.sh
# SDK 路径可用 OHOS_SDK 覆盖。

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/.." && pwd)"
CPP="$PROJ/entry/src/main/cpp"

SDK="${OHOS_SDK:-$HOME/.harmonybrew/Cellar/ohos-sdk/26.0.0.18_1}"
CXX="$SDK/bin/clang++"
SYSROOT="$SDK/native/sysroot"
LLVM_LIB="$SDK/native/llvm/lib/aarch64-linux-ohos"
OUT="$PROJ/.build-check"
mkdir -p "$OUT"

if [ ! -x "$CXX" ]; then
    echo "找不到 clang++：$CXX（可用 OHOS_SDK 覆盖）" >&2
    exit 2
fi

BIN="$OUT/shim_selftest"

echo "--- 编译 $BIN ---"
if ! "$CXX" \
    --target=aarch64-linux-ohos \
    --sysroot="$SYSROOT" \
    -std=c++20 \
    -DIM_PLATFORM_OHOS \
    -finput-charset=UTF-8 -fexec-charset=UTF-8 \
    -I"$CPP/ohos/compat" \
    -I"$CPP/Core/include" \
    -I"$CPP/Core/src" \
    -I"$CPP/ohos" \
    -include "$CPP/ohos/compat/ohos_cxx_compat.h" \
    "$HERE/shim_selftest.cpp" \
    "$CPP/Core/src/Text/Utf.cpp" \
    "$CPP/Core/src/Media/VideoFrameCopy.cpp" \
    "$CPP/Core/src/Media/CoreMedia.cpp" \
    "$CPP/Core/src/Media/H264.cpp" \
    "$CPP/Core/src/Protocol/QuickTimePacket.cpp" \
    "$CPP/ohos/OhosSharedGpuFrame.cpp" \
    "$LLVM_LIB/libc++_static.a" "$LLVM_LIB/libc++abi.a" "$LLVM_LIB/libunwind.a" \
    -lpthread -lm -ldl \
    -o "$BIN" > "$OUT/shim_build.log" 2>&1; then
    echo "编译失败：" >&2
    tail -30 "$OUT/shim_build.log" >&2
    exit 1
fi
echo "编译成功"

echo
"$BIN"
STATUS=$?
echo
if [ "$STATUS" -eq 0 ]; then
    echo "垫片自检：全部通过"
else
    echo "垫片自检：有失败项（退出码 $STATUS）"
fi
exit "$STATUS"
