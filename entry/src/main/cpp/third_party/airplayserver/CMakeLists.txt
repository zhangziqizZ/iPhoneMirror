# SPDX-License-Identifier: GPL-3.0-only
#
# third_party/airplayserver/CMakeLists.txt
#
# AirPlay 接收端协议库（vendored）。来源：
#   https://github.com/xenos1337/AirPlayServer v1.1.2（commit 34ba6cfd…）
#   上游 iPhoneMirror 用它做 AirPlay 接收，本质上是 RPiPlay 那套 lib/
#   （raop / raop_rtp / raop_rtp_mirror / httpd / pairing / fairplay …
#   以及内置的 crypto / curve25519 / ed25519 / playfair / plist）。
#
# 上游 Windows 版是「独立进程 iPhoneMirror.WirelessHost.exe + 预编译
# airplay2dll.dll(x64) + Apple dnssd.dll」。鸿蒙上这三者都不存在，所以：
#   * 只取**协议库**（本目录 lib/），它本来就有 POSIX 分支（compat.h 的
#     #else 走 <sys/socket.h> + <pthread.h>），鸿蒙（Linux 内核 + musl）可用；
#   * 不编译 lib/dnssd.c —— 它 #include <dns_sd.h>（Apple Bonjour），
#     鸿蒙没有。改由同目录的 dnssd_ohos.c 实现 dnssd.h 的全部 6 个函数，
#     真正的广播交给 ArkTS 的 @ohos.net.mdns（见 im_dnssd_bridge.h）；
#   * fdk-aac **要编** —— raop_buffer.c 里有 10 处 aacDecoder_* 调用。
#     不能省的原因：AirPlay 屏幕镜像的音频是 AAC-ELD，而鸿蒙
#     OH_AudioDecoder 只支持 LC / HE / HE-V2，没有 ELD。
#     （曾经误判"lib/*.c 不引用 fdk-aac"，是因为 raop_buffer.c 是 UTF-16
#      存盘，grep 搜不到里面的 ASCII —— 详见下方"踩过的坑"。）
#
# 纪律：vendored 代码一行不改，平台相关一律新增文件 + 构建层排除。

cmake_minimum_required(VERSION 3.16)

set(AP_ROOT ${CMAKE_CURRENT_SOURCE_DIR})
set(AP_LIB ${AP_ROOT}/lib/lib)

add_library(airplay_receiver STATIC
    # ── 协议核心（vendored，逐字未改） ──
    ${AP_LIB}/aes2.c
    ${AP_LIB}/aes_ctr.c
    ${AP_LIB}/airplay.c
    ${AP_LIB}/base64.c
    ${AP_LIB}/byteutils.c
    ${AP_LIB}/digest.c
    ${AP_LIB}/fairplay_playfair.c
    ${AP_LIB}/http_parser.c
    ${AP_LIB}/http_request.c
    ${AP_LIB}/http_response.c
    ${AP_LIB}/httpd.c
    ${AP_LIB}/logger.c
    ${AP_LIB}/mirror_buffer.c
    ${AP_LIB}/netutils.c
    ${AP_LIB}/pairing.c
    ${AP_LIB}/plist.c
    ${AP_LIB}/raop.c
    ${AP_LIB}/raop_buffer.c
    ${AP_LIB}/raop_rtp.c
    ${AP_LIB}/raop_rtp_mirror.c
    ${AP_LIB}/rsakey.c
    ${AP_LIB}/rsapem.c
    ${AP_LIB}/sdp.c
    ${AP_LIB}/utils.c
    # 注意：${AP_LIB}/dnssd.c 有意排除，理由见文件头。

    # ── 内置第三方（全部自带源码，不需要 OpenSSL / 系统库） ──
    ${AP_LIB}/crypto/aes.c
    ${AP_LIB}/crypto/bigint.c
    ${AP_LIB}/crypto/hmac.c
    ${AP_LIB}/crypto/md5.c
    ${AP_LIB}/crypto/rc4.c
    ${AP_LIB}/crypto/sha1.c
    ${AP_LIB}/curve25519/curve25519-donna.c
    ${AP_LIB}/ed25519/add_scalar.c
    ${AP_LIB}/ed25519/fe.c
    ${AP_LIB}/ed25519/ge.c
    ${AP_LIB}/ed25519/key_exchange.c
    ${AP_LIB}/ed25519/keypair.c
    ${AP_LIB}/ed25519/sc.c
    ${AP_LIB}/ed25519/seed.c
    ${AP_LIB}/ed25519/sha512.c
    ${AP_LIB}/ed25519/sign.c
    ${AP_LIB}/ed25519/verify.c
    ${AP_LIB}/playfair/hand_garble.c
    ${AP_LIB}/playfair/modified_md5.c
    ${AP_LIB}/playfair/omg_hax.c
    ${AP_LIB}/playfair/playfair.c
    ${AP_LIB}/playfair/sap_hash.c
    ${AP_LIB}/plist/base64.c
    ${AP_LIB}/plist/bplist.c
    ${AP_LIB}/plist/bytearray.c
    ${AP_LIB}/plist/cnary.c
    ${AP_LIB}/plist/hashtable.c
    ${AP_LIB}/plist/list.c
    ${AP_LIB}/plist/node.c
    ${AP_LIB}/plist/node_list.c
    ${AP_LIB}/plist/plist.c
    ${AP_LIB}/plist/ptrarray.c
    ${AP_LIB}/plist/time64.c
    ${AP_LIB}/plist/xplist.c

    # ── 鸿蒙后端（新增文件） ──
    ${AP_ROOT}/dnssd_ohos.c
)

target_include_directories(airplay_receiver
    PUBLIC
        ${AP_ROOT}            # dnssd.h / airplay.h / raop.h / stream.h / im_dnssd_bridge.h
        ${AP_ROOT}/compat     # vendored 布局补齐（plist/include/plist.h 转发头）
        ${AP_LIB}             # 库内部头（global.h / dnssdint.h / compat.h …）
    PRIVATE
        ${AP_LIB}/crypto
        ${AP_LIB}/curve25519
        ${AP_LIB}/ed25519
        ${AP_LIB}/playfair
        ${AP_LIB}/plist
        ${AP_LIB}/plist/plist
)

target_compile_definitions(airplay_receiver PRIVATE
    # vendored 代码用 WIN32 判定走哪套系统头；鸿蒙不定义它，自动落到
    # compat.h / threads.h 的 POSIX 分支。这里显式说明意图，避免误加。
    HAVE_CONFIG_H=0
    # airplay.c:31 用了 MSVC 的 __int64。用编译期宏映射掉，不改 vendored 代码。
    __int64=int64_t
)

target_compile_options(airplay_receiver PRIVATE
    # vendored 的 C 代码年代较久，告警很多但不致命；只压掉噪音，不改代码。
    -Wno-unused-parameter
    -Wno-sign-compare
    -Wno-int-conversion
    -finput-charset=UTF-8 -fexec-charset=UTF-8
    # raop_rtp.c / raop_rtp_mirror.c 用了 min()，它在 Windows 上由 <windows.h>
    # 提供，鸿蒙没有 → 编译只是隐式声明告警、**链接期才报 undefined symbol: min**。
    # 用 -include 补宏，不改 vendored 源码。头文件内部用 `#if !defined(__cplusplus)`
    # 自限，所以同一 target 里的 fdk-aac（C++）不受影响。
    -include ${AP_ROOT}/compat/im_airplay_compat.h
)

# ── fdk-aac（AAC-ELD 解码器） ──
# raop_buffer.c 里 10 处 aacDecoder_* 调用要用它。为什么不能省：
# AirPlay 屏幕镜像的音频是 AAC-ELD，而鸿蒙 OH_AudioDecoder 只支持
# LC / HE / HE-V2（见 SDK native_avcodec_base.h 的 OH_AACProfile），没有 ELD。
# 只编**解码**需要的模块；编码器（libAACenc / libSBRenc / libSACenc / libMpegTPEnc）不编。
# mips/ 分支是 MIPS 专用实现，aarch64 上排除。
file(GLOB IM_FDK_AAC_DEC_SOURCES
    ${AP_LIB}/fdk-aac/libAACdec/src/*.cpp
    ${AP_LIB}/fdk-aac/libPCMutils/src/*.cpp
    ${AP_LIB}/fdk-aac/libFDK/src/*.cpp
    ${AP_LIB}/fdk-aac/libSYS/src/*.cpp
    ${AP_LIB}/fdk-aac/libMpegTPDec/src/*.cpp
    ${AP_LIB}/fdk-aac/libSBRdec/src/*.cpp
    ${AP_LIB}/fdk-aac/libArithCoding/src/*.cpp
    ${AP_LIB}/fdk-aac/libDRCdec/src/*.cpp
    ${AP_LIB}/fdk-aac/libSACdec/src/*.cpp
)
list(FILTER IM_FDK_AAC_DEC_SOURCES EXCLUDE REGEX "/mips/")
target_sources(airplay_receiver PRIVATE ${IM_FDK_AAC_DEC_SOURCES})

# fdk-aac 是老代码，按 C++14 编；主工程是 C++20，这里单独降级避免语法冲突。
set_target_properties(airplay_receiver PROPERTIES CXX_STANDARD 14)

# ── fdk-aac 头文件路径 ──
# raop_buffer.c 直接 #include "fdk-aac/libAACdec/include/aacdecoder_lib.h"
# （AAC-ELD 解码：AirPlay 屏幕镜像的音频就是 AAC-ELD，而鸿蒙原生
# OH_AudioDecoder 只支持 LC / HE / HE-V2，没有 ELD，所以必须用 fdk-aac）。
# aacdecoder_lib.h 内部又 #include "machine_type.h"，那个在 libSYS/include。
# 注意：这里**用 GLOB 收全部 fdk-aac 子模块的 include**，不要逐个手写。
# 之前手写只列了 9 个，漏掉 libArithCoding/libDRCdec/libSACdec，导致
# libAACdec 的 channelinfo.h:127 #include "ac_arith_coder.h" 找不到而整库编译失败
# （自检脚本 try_compile.sh 里列全了所以没复现 → 两份清单漂移，见 tools/try_compile.sh）。
file(GLOB IM_FDK_AAC_INCLUDE_DIRS ${AP_LIB}/fdk-aac/*/include)

target_include_directories(airplay_receiver PRIVATE
    ${IM_FDK_AAC_INCLUDE_DIRS}
    # vendored fdk-aac 缺 arm/ 这一支（只有 mips/ppc/x86），而 FDK_archdef.h
    # 在 aarch64 上会 #define __arm__ 并要求 arm/clz_arm.h 等。补齐文件放这里。
    ${AP_ROOT}/compat/fdk-aac/libFDK/include
    # arm/*_arm.cpp 是各模块 #include "arm/xxx_arm.cpp" 的实现存根（空文件，
    # 目的是让各 .cpp 自带的可移植 C 兜底生效）。
    ${AP_ROOT}/compat/fdk-aac
)
