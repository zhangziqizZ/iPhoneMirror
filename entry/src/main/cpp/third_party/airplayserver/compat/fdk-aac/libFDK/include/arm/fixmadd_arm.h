/*
 * compat/fdk-aac/libFDK/include/arm/fixmadd_arm.h
 *
 * vendored fdk-aac 缺 ARM 架构目录（只有 mips/ppc/x86），本文件补齐。
 *
 * 说明：这里**故意不定义任何 FUNCTION_* 宏**，让 fixmadd.h 自带的
 * 可移植 C 兜底实现生效（乘加（fixmadd.h））。
 * 正确性优先于性能：先跑通，后续若要优化再补 NEON intrinsics。
 * （clz_arm.h 例外——那个提供了基于 __builtin_clz 的真实现。）
 */

#if !defined(FIXMADD_ARM_H_)
#define FIXMADD_ARM_H_
/* 不定义 FUNCTION_* —— 走通用 C 兜底 */
#endif
