/*
 * compat/fdk-aac/libFDK/include/arm/clz_arm.h
 *
 * vendored fdk-aac 缺了 ARM 这一支，本文件补齐（新增文件，不改 vendored 代码）。
 *
 * 背景：
 *   AirPlayServer v1.1.2 带的 fdk-aac 快照只有 mips/ ppc/ x86/ 三个架构目录，
 *   没有 arm/。而 libFDK/include/FDK_archdef.h:117-118 会在 __aarch64__
 *   （或 _M_ARM / _M_ARM64）上主动 `#define __arm__`，于是 clz.h:110 就去
 *   include "arm/clz_arm.h" —— 鸿蒙设备是 aarch64，必然走到这一支并缺文件。
 *
 * 语义对齐：
 *   照 x86/clz_x86.h 的 GCC 分支写。注意 FDK 的 LONG 在 LP64（aarch64 / x86_64）
 *   上是 64 位，但 fixnormz_D / fixnorm_D 是 32 位语义；x86_64 上
 *   `__builtin_clz(long)` 会隐式截断成 32 位，这里显式按 uint32 处理，
 *   与 x86_64 的实际行为一致，避免换平台后行为漂移。
 */

#if !defined(CLZ_ARM_H)
#define CLZ_ARM_H

#if defined(__GNUC__) && (defined(__arm__) || defined(__aarch64__))

#define FUNCTION_fixnormz_D
#define FUNCTION_fixnorm_D

inline INT fixnormz_D(LONG value) {
  /* 只取低 32 位：与 x86_64 上 __builtin_clz(long) 的隐式截断等价。 */
  UINT bits = (UINT)(value & 0xFFFFFFFFu);
  if (bits == 0) {
    return 32;
  }
  return (INT)__builtin_clz(bits);
}

inline INT fixnorm_D(LONG value) {
  UINT bits = (UINT)(value & 0xFFFFFFFFu);
  if (bits == 0) {
    return 0;
  }
  if (value < 0) {
    bits = ~bits;
  }
  return (INT)__builtin_clz(bits) - 1;
}

#endif /* __GNUC__ && ARM */

#endif /* !defined(CLZ_ARM_H) */
