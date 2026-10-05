/**
 *  Copyright (C) 2011-2012  Juho Vähä-Herttua
 *
 *  This library is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU Lesser General Public
 *  License as published by the Free Software Foundation; either
 *  version 2.1 of the License, or (at your option) any later version.
 *
 *  This library is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  Lesser General Public License for more details.
 */

#ifndef RAOP_BUFFER_H
#define RAOP_BUFFER_H

#include "logger.h"
#include "raop_rtp.h"

typedef struct raop_buffer_s raop_buffer_t;

typedef int (*raop_resend_cb_t)(void *opaque, unsigned short seqno, unsigned short count);

/* ★ 2026-10-05：整头用 extern "C" 包起来。
 * 本头描述的是 C 库（raop_buffer.c 编译出的目标文件里符号是**未修饰**的），
 * 而 1.0.54 起它被 C++ 侧（OhosAirPlayReceiver.cpp）包含。少了这个包裹，
 * C++ 会按名字修饰去找 raop_audio_decode_errors_total(int) 之类，链接期直接
 * `undefined symbol` —— 编译期完全不报错，只有最终链 .so 时才炸（用户那边
 * 就是这一步挂的 00308018）。放在 include 之后：只为函数声明生效，
 * logger.h / raop_rtp.h 自己已有各自的链接规格处理，不需要被包进来。 */
#ifdef __cplusplus
extern "C" {
#endif

raop_buffer_t *raop_buffer_init(logger_t *logger,
                                const unsigned char *aeskey,
                                const unsigned char *aesiv,
								const unsigned char *ecdh_secret);

int raop_buffer_queue(raop_buffer_t *raop_buffer, unsigned char *data, unsigned short datalen, raop_callbacks_t *callbacks);
const void *raop_buffer_dequeue(raop_buffer_t *raop_buffer, int *length, unsigned int* pts, int no_resend, 
    uint32_t* sample_rate, uint16_t* channels, uint16_t* bits_per_sample);
void raop_buffer_handle_resends(raop_buffer_t *raop_buffer, raop_resend_cb_t resend_cb, void *opaque);
void raop_buffer_flush(raop_buffer_t *raop_buffer, int next_seq);
void raop_buffer_destroy(raop_buffer_t *raop_buffer);

/* ★ 2026-10-04（1.0.54）：AAC 解码失败次数的进程级累计。
 * 「静默丢弃路径必须配计数器」——解码失败的包现在按定长补静音（保持时间轴），
 * 听感是"那一下没声"，但若没有这个计数，排查时根本分不清"解码总失败"
 * 和"几乎没失败"。跨会话不归零：宿主在会话开始时自己记差分。 */
unsigned long long raop_audio_decode_errors_total(void);

#ifdef __cplusplus
}
#endif

#endif
