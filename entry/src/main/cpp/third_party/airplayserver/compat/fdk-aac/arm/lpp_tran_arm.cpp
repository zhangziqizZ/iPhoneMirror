/*
 * compat/fdk-aac/arm/lpp_tran_arm.cpp
 *
 * vendored fdk-aac 缺 ARM 架构实现目录（只有 mips/），而 libSBRdec/src/lpp_tran.cpp 在
 * `defined(__arm__)` 时会 #include "arm/lpp_tran_arm.cpp"。鸿蒙设备是 aarch64，
 * FDK_archdef.h 又会主动 #define __arm__，所以必然走到这一支。
 *
 * 这里**故意留空**：libSBRdec/src/lpp_tran.cpp 在 include 之后用 `#ifndef FUNCTION_xxx`
 * 提供了可移植 C 实现，空存根即等价于"使用通用实现"。
 * 正确性优先于性能（SBR 低通/高通变换）；后续若要提速再补 NEON intrinsics。
 */
