/*
 * compat/im_airplay_compat.h
 *
 * 对 vendored AirPlay 协议库（third_party/airplayserver/lib）的**编译期**补齐，
 * 通过 `-include` 强制预包含，不修改 vendored 源码。
 *
 * 为什么需要：
 *   raop_rtp.c:170/173 与 raop_rtp_mirror.c:136/139 用了 `min(128, strlen(...))`。
 *   在 Windows 上 `min` 来自 <windows.h>（windef.h，未定义 NOMINMAX 时提供）；
 *   鸿蒙不定义 WIN32，走不到那支，`min` 就成了未定义符号 —— 编译能过
 *   （C89 隐式函数声明，只是告警），**链接期才报 undefined symbol: min**。
 *
 * 为什么用 #ifndef 且替换文本与 crypto/bigint_impl.h:125-126 完全一致：
 *   bigint_impl.h 在 `#ifndef WIN32` 分支里也定义了 min/max，bigint.c 靠它。
 *   文本一致 → 重复定义是良性的，不会产生 -Wmacro-redefined 告警。
 *
 * 为什么用 `#if !defined(__cplusplus)` 把定义限制在 C：
 *   同一个 target 里还编 fdk-aac（C++）。裸宏名 `min` 会把
 *   `std::min(a, b)` 展开成 `std::(((a) < (b) ? (a) : (b)))` 这种非法表达式。
 *   在头文件里按语言自限，比在 CMake 里写
 *   `$<$<COMPILE_LANGUAGE:C>:-include <path>>` 更稳妥 —— 后者生成的
 *   "-include /path" 会不会被当成**单个** argv 传给 clang 取决于 CMake 版本，
 *   没必要赌。
 */

#ifndef IM_AIRPLAY_COMPAT_H
#define IM_AIRPLAY_COMPAT_H

#if !defined(__cplusplus)

#ifndef min
#define min(a, b) ((a) < (b) ? (a) : (b))
#endif

#ifndef max
#define max(a, b) ((a) > (b) ? (a) : (b))
#endif

#endif /* !defined(__cplusplus) */

#endif /* IM_AIRPLAY_COMPAT_H */
