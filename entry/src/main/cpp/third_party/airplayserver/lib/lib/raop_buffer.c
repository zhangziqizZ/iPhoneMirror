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
#ifdef WIN32
#include <stdio.h>
#endif // WIN32

#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <math.h>

#include "raop_buffer.h"
#include "raop_rtp.h"

#include <stdint.h>
#include <sha512.h>
#include "crypto/crypto.h"
#include "aes.h"
#include "compat.h"
#include "fdk-aac/libAACdec/include/aacdecoder_lib.h"
#ifndef FIXP_SGL
typedef SHORT FIXP_SGL;
#endif // !FIXP_SGL

#include "fdk-aac/libFDK/include/clz.h"
#include "fdk-aac/libSYS/include/FDK_audio.h"
#include "stream.h"


#define RAOP_BUFFER_LENGTH 64  // Reduced from 512 to minimize latency (5.12s -> 640ms max buffer)

typedef struct {
	/* Packet available */
	int available;

	/* RTP header */
	unsigned char flags;
	unsigned char type;
	unsigned short seqnum;
	unsigned int timestamp;
	unsigned int ssrc;

	uint32_t sample_rate;
	uint16_t channels;
	uint16_t bits_per_sample;

	/* memory size */
	int audio_buffer_size;
	/* decoded length */
	int audio_buffer_len;
	void *audio_buffer;
} raop_buffer_entry_t;

struct raop_buffer_s {
    logger_t *logger;
	/* key and IV for decryption */
	unsigned char aeskey[RAOP_AESKEY_LEN];
	unsigned char aesiv[RAOP_AESIV_LEN];

    HANDLE_AACDECODER phandle;

	/* First and last seqnum */
	int is_empty;
	// playback sequence number
	unsigned short first_seqnum;
	// received sequence number
	unsigned short last_seqnum;

	/* RTP buffer entries */
	raop_buffer_entry_t entries[RAOP_BUFFER_LENGTH];

	/* Buffer of all audio buffers */
	int buffer_size;
	void *buffer;
};

static int fdk_flags = 0;

/* ★ 2026-10-04（1.0.54）：AAC 解码失败计数（进程级累计），经
 * raop_audio_decode_errors_total() 暴露给宿主摊到诊断里。 */
static unsigned long long g_raop_audio_decode_errors = 0;

/* period size 480 samples */
#define N_SAMPLE 480

static int pcm_pkt_size = 4 * N_SAMPLE;

/* ★ 2026-10-04（1.0.54）：每个 entry 的 PCM 缓冲从 480×2×2=1920 字节放大到
 * 4096 字节（可容纳 frameSize 最大 1024×2ch×16bit）。1920 的来历是"ELD 一律
 * 480 帧"这个不成立的假设——FDK 明写 ELD/LD 是 512 或 480。frameSize=512 时
 * 每帧要写 512×2×2=2048 字节，FDK 末尾的整块 memcpy 会越过 1920 字节的边界
 * 写坏**下一个 entry** 的前 128 字节；decode 出错时 FDK 的 memclear 按
 * timeDataSize 个单位清零，越界清得更远（把后面多个 entry 一起抹掉）。
 * 这类越界在会话里是持续发生的，正是「电音/炸」的主要来源之一。 */
static int audio_entry_bytes = 4096;

/* 每个成功解码帧的实际字节数（缺包/失败时补静音用这个长度，保持时间轴对齐）。
 * 初始值按 480 帧兜底，第一次成功解码后被真值覆盖。 */
static int last_frame_bytes = 4 * N_SAMPLE;

HANDLE_AACDECODER
create_fdk_aac_decoder(logger_t *logger)
{
    int ret = 0;
    UINT nrOfLayers = 1;
	HANDLE_AACDECODER phandle = aacDecoder_Open(TT_MP4_RAW, nrOfLayers);
    if (phandle == NULL) {
        logger_log(logger, LOGGER_DEBUG, "aacDecoder open faild!\n");
        return NULL;
    }
    /* ASC config binary data */
	UCHAR eld_conf[] = { 0xF8, 0xE8, 0x50, 0x00 };
	UCHAR *conf[] = { eld_conf };
	static UINT conf_len = sizeof(eld_conf);
    ret = aacDecoder_ConfigRaw(phandle, conf, &conf_len);
    if (ret != AAC_DEC_OK) {
        logger_log(logger, LOGGER_DEBUG, "Unable to set configRaw\n");
        return NULL;
    }
    CStreamInfo *aac_stream_info = aacDecoder_GetStreamInfo(phandle);
    if (aac_stream_info == NULL) {
        logger_log(logger, LOGGER_DEBUG, "aacDecoder_GetStreamInfo failed!\n");
        return NULL;
    }
    logger_log(logger, LOGGER_DEBUG, "> stream info: channel = %d\tsample_rate = %d\tframe_size = %d\taot = %d\tbitrate = %d\n",   \
            aac_stream_info->channelConfig, aac_stream_info->aacSampleRate,
           aac_stream_info->aacSamplesPerFrame, aac_stream_info->aot, aac_stream_info->bitRate);
    return phandle;
}

void
raop_buffer_init_key_iv(raop_buffer_t *raop_buffer,
                     const unsigned char *aeskey,
                     const unsigned char *aesiv,
                     const unsigned char *ecdh_secret)
{
    // initialize key
    unsigned char eaeskey[64];
    memcpy(eaeskey, aeskey, 16);
    sha512_context ctx;
    sha512_init(&ctx);
    sha512_update(&ctx, eaeskey, 16);
    sha512_update(&ctx, ecdh_secret, 32);
    sha512_final(&ctx, eaeskey);
    memcpy(raop_buffer->aeskey, eaeskey, 16);
    memcpy(raop_buffer->aesiv, aesiv, RAOP_AESIV_LEN);
#ifdef DUMP_AUDIO
    if (file_keyiv != NULL) {
        fwrite(raop_buffer->aeskey, 16, 1, file_keyiv);
        fwrite(raop_buffer->aesiv, 16, 1, file_keyiv);
        fclose(file_keyiv);
    }
#endif
}

raop_buffer_t *
raop_buffer_init(logger_t *logger,
                 const unsigned char *aeskey,
                 const unsigned char *aesiv,
                 const unsigned char *ecdh_secret)
{
	raop_buffer_t *raop_buffer;
	int audio_buffer_size;
	assert(aeskey);
    assert(aesiv);
    assert(ecdh_secret);
	raop_buffer = calloc(1, sizeof(raop_buffer_t));
	if (!raop_buffer) {
		return NULL;
	}
    raop_buffer->logger = logger;

	/* Allocate the output audio buffers */
    audio_buffer_size = audio_entry_bytes;
    raop_buffer->phandle = create_fdk_aac_decoder(logger);
    if (!raop_buffer->phandle) {
        free(raop_buffer);
        return NULL;
    }
	raop_buffer->buffer_size = audio_buffer_size * RAOP_BUFFER_LENGTH;
	raop_buffer->buffer = malloc(raop_buffer->buffer_size);
	if (!raop_buffer->buffer) {
        if (raop_buffer->phandle) {
            free(raop_buffer->phandle);
        }
		free(raop_buffer);
		return NULL;
	}
	for (int i=0; i<RAOP_BUFFER_LENGTH; i++) {
		raop_buffer_entry_t *entry = &raop_buffer->entries[i];
		entry->audio_buffer_size = audio_buffer_size;
		entry->audio_buffer_len = 0;
		entry->audio_buffer = (char *)raop_buffer->buffer+i*audio_buffer_size;
	}
    raop_buffer_init_key_iv(raop_buffer, aeskey, aesiv, ecdh_secret);
	/* Mark buffer as empty */
	raop_buffer->is_empty = 1;

	return raop_buffer;
}

unsigned long long
raop_audio_decode_errors_total(void)
{
	return g_raop_audio_decode_errors;
}

void
raop_buffer_destroy(raop_buffer_t *raop_buffer)
{
	if (raop_buffer) {
	    aacDecoder_Close(raop_buffer->phandle);
		free(raop_buffer->buffer);
		free(raop_buffer);
	}
#ifdef DUMP_AUDIO
    if (file_aac != NULL) {
        fclose(file_aac);
    }
    if (file_source != NULL) {
        fclose(file_source);
    }
    if (file_pcm != NULL) {
        fclose(file_pcm);
    }
#endif

}

static short
seqnum_cmp(unsigned short s1, unsigned short s2)
{
	return (s1 - s2);
}

short dithered_vol(int sample, int v) {
    int out = sample * v;
/*    if (v < 65536) {
        out = (out + rand_a) - rand_b;
    }*/
    return (short) (out >> 16);
}

int
stuff_buffer(short* input, short* output, int vol) {
    int i;
    int i2;
    int l;
    int stuffsamp = 480;
    int l2 = 0;
    int j = 0;
    for (i = 0; i < stuffsamp; i++) {
        i2 = j + 1;
        l = l2 + 1;
        output[j] = dithered_vol(input[l2], vol);
        j = i2 + 1;
        l2 = l + 1;
        output[i2] = dithered_vol(input[l], vol);
    }
    return 480;
}

//#define DUMP_AUDIO

#ifdef DUMP_AUDIO
static FILE* file_aac = NULL;
static FILE* file_source = NULL;
static FILE* file_keyiv = NULL;
static FILE* file_pcm = NULL;
#endif


int
raop_buffer_queue(raop_buffer_t *raop_buffer, unsigned char *data, unsigned short datalen, raop_callbacks_t *callbacks)
{
    assert(raop_buffer);
    int encryptedlen;
    raop_buffer_entry_t *entry;
#ifdef DUMP_AUDIO
    if (file_aac == NULL) {
        file_aac = fopen("demo-audio.aac", "wb");
        file_source = fopen("demo-audio.source", "wb");
        file_keyiv = fopen("demo-audio.keyiv", "wb");
        file_pcm = fopen("demo-audio.pcm", "wb");
    }
#endif

    /* Check packet data length is valid */
    if (datalen < 12 || datalen > RAOP_PACKET_LEN) {
        return -1;
    }
    unsigned short seqnum = (data[2] << 8) | data[3];
    if (datalen == 16 && data[12] == 0x0 && data[13] == 0x68 && data[14] == 0x34 && data[15] == 0x0) {
        return 0;
    }
    int payloadsize = datalen - 12;
#ifdef DUMP_AUDIO
    // unencrypted file
    if (file_source != NULL) {
        fwrite(&data[12], payloadsize, 1, file_source);
    }
#endif
    //logger_log(raop_buffer->logger, LOGGER_DEBUG, "seqnum = %d payloadsize = %d", seqnum, payloadsize);


	if (!raop_buffer->is_empty && seqnum_cmp(seqnum, raop_buffer->first_seqnum) < 0) {
		return 0;
	}
	/* Check that there is always space in the buffer, otherwise flush */
	if (seqnum_cmp(seqnum, raop_buffer->first_seqnum+RAOP_BUFFER_LENGTH) >= 0) {
		raop_buffer_flush(raop_buffer, seqnum);
	}
	entry = &raop_buffer->entries[seqnum % RAOP_BUFFER_LENGTH];
	if (entry->available && seqnum_cmp(entry->seqnum, seqnum) == 0) {
		/* Packet resend, we can safely ignore */
		return 0;
	}
    entry->flags = data[0];
    entry->type = data[1];
    entry->seqnum = seqnum;
    // pts starts from byte 4
    entry->timestamp = (data[4] << 24) | (data[5] << 16) |
                       (data[6] << 8) | data[7];
    entry->ssrc = (data[8] << 24) | (data[9] << 16) |
                  (data[10] << 8) | data[11];
    entry->available = 1;

    encryptedlen = payloadsize/16*16;
    unsigned char* packetbuf = malloc(payloadsize);
    memset(packetbuf, 0, payloadsize);
	// needs to be initialized internally
    AES_CTX aes_ctx_audio;
	AES_set_key(&aes_ctx_audio, raop_buffer->aeskey, raop_buffer->aesiv, AES_MODE_128);
	AES_convert_key(&aes_ctx_audio);
    AES_cbc_decrypt(&aes_ctx_audio, &data[12], packetbuf, encryptedlen);
    memcpy(packetbuf+encryptedlen, &data[12+encryptedlen], payloadsize-encryptedlen);
#ifdef DUMP_AUDIO
    // decrypted file
    if (file_aac != NULL) {
        fwrite(packetbuf, payloadsize, 1, file_aac);
    }
#endif
	// aac decode to pcm
    int ret = 0;
    int pkt_size = payloadsize;
    UINT valid_size = payloadsize;
    UCHAR *input_buf[1] = {packetbuf};
    ret = aacDecoder_Fill(raop_buffer->phandle, input_buf, &pkt_size, &valid_size);
    if (ret != AAC_DEC_OK) {
        logger_log(raop_buffer->logger, LOGGER_ERR, "aacDecoder_Fill error : %x", ret);
    }
	// ★ 2026-10-04（1.0.54）：timeDataSize 的单位是 **INT_PCM 元素**（采样点×声道，
	//   FDK 源码 aacdecoder_lib.cpp 末尾的检查是
	//   `timeDataSize_extern < numChannels * frameSize`）。原来这里传
	//   pcm_pkt_size（=1920）——恰好等于旧缓冲的**字节数**，被当成 1920 个元素用
	//   才一直没触发 TOO_SMALL；frameSize=512 的包需要 1024 单位=2048 字节，
	//   FDK 末尾整块 memcpy 就越过 1920 字节的 entry 缓冲越界写。
	//   现在缓冲已放大（audio_entry_bytes=4096），按单位数传参。
	ret = aacDecoder_DecodeFrame(raop_buffer->phandle, entry->audio_buffer,
	    audio_entry_bytes / 2, fdk_flags);

	// ★ 2026-10-02 修复「声音是炸的」（爆音）。
	//
	//   AAC-ELD 的输出帧长**不是恒定 480** —— FDK 文档明写
	//   "512 or 480 for AAC-LD and AAC-ELD"（aacdecoder_lib.h:823），取决于 ELD
	//   的 downscale 因子：960/2=480、1024/2=512。而这里把 audio_buffer_len
	//   **无条件**写成 pcm_pkt_size（= 4*480 帧 = 3840 字节），于是解码器实际只写
	//   了 512*2ch*2byte*4 = 8192… 取不足时，后面一段是**上一包留在缓冲里的
	//   残留**，被当成当前音频继续播放 ⇒ 周期性炸（爆音/断裂）。
	//   抖音这类高码率内容最容易触发：码率高 ⇒ 两种包长在会话里交替出现。
	//
	//   注意下面用 streamInfo->frameSize 算 bits_per_sample 那行说明原作者知道
	//   frameSize 会变，只是漏了"帧数/字节数"本身没跟着变。
	//
	//   修法（1.0.50）：以 frameSize × numChannels × 2 为准算真实字节数。
	//
	//   ★ 2026-10-04（1.0.54）两条追加：
	//   1) 上限从 pcm_pkt_size 改成 entry->audio_buffer_size（4096）——
	//      pcm_pkt_size=1920 比真实帧长（512 帧=2048 字节）还小，条件恒不成立
	//      时会退回旧值；真实上限应该是缓冲本身。
	//   2) 解码失败的包**不再把缓冲里的旧内容当 PCM 播**。原来无论 ret 是什么都
	//      写 audio_buffer_len（失败时退回 pcm_pkt_size），把上一包的残留或
	//      未初始化内存当成当前帧播出去——听感就是周期性的「电音/炸」。现在
	//      IS_OUTPUT_VALID 不成立 ⇒ 按最近一次的真实帧长补静音（时间轴不塌）
	//      并计数；decoded_bytes 算不出来（streamInfo 为 NULL/异常）同理。
	int decoded_bytes = 0;
	CStreamInfo* streamInfo = aacDecoder_GetStreamInfo(raop_buffer->phandle);
	if (streamInfo != NULL) {
		entry->sample_rate = streamInfo->sampleRate;
		entry->channels = streamInfo->numChannels;
		if (streamInfo->frameSize > 0 && streamInfo->numChannels > 0) {
			// 每帧字节 = 帧长 × 声道 × 2（16bit）。本链路 ELD 一律 16bit。
			const int bytes_per_frame =
			    streamInfo->frameSize * streamInfo->numChannels * 2;
			if (bytes_per_frame > 0 && bytes_per_frame <= entry->audio_buffer_size) {
				decoded_bytes = bytes_per_frame;
			}
		}
		if (decoded_bytes > 0 && entry->channels != 0 && streamInfo->frameSize != 0) {
			entry->bits_per_sample =
			    decoded_bytes * 8 / (streamInfo->frameSize * entry->channels);
		}
	}
	if (!IS_OUTPUT_VALID(ret) || decoded_bytes <= 0) {
		if (!IS_OUTPUT_VALID(ret)) {
			g_raop_audio_decode_errors += 1;
			logger_log(raop_buffer->logger, LOGGER_ERR, "aacDecoder_DecodeFrame error : 0x%x", ret);
		}
		decoded_bytes = last_frame_bytes;
		if (decoded_bytes > entry->audio_buffer_size) {
			decoded_bytes = entry->audio_buffer_size;
		}
		memset(entry->audio_buffer, 0, decoded_bytes);
	} else {
		last_frame_bytes = decoded_bytes;
	}
	entry->audio_buffer_len = decoded_bytes;
#ifdef DUMP_AUDIO
    if (file_pcm != NULL) {
        fwrite(entry->audio_buffer, entry->audio_buffer_len, 1, file_pcm);
    }
#endif

	/* Update the raop_buffer seqnums */
	if (raop_buffer->is_empty) {
		raop_buffer->first_seqnum = seqnum;
		raop_buffer->last_seqnum = seqnum;
		raop_buffer->is_empty = 0;
	}
	if (seqnum_cmp(seqnum, raop_buffer->last_seqnum) > 0) {
		raop_buffer->last_seqnum = seqnum;
	}
	free(packetbuf);

    return 1;
}

const void *
raop_buffer_dequeue(raop_buffer_t *raop_buffer, int *length, unsigned int* pts, int no_resend,
	uint32_t* sample_rate, uint16_t* channels, uint16_t* bits_per_sample)
{
	short buflen;
	raop_buffer_entry_t *entry;

	/* Calculate number of entries in the current buffer */
	buflen = seqnum_cmp(raop_buffer->last_seqnum, raop_buffer->first_seqnum) + 1;

	/* Cannot dequeue from empty buffer */
	if (raop_buffer->is_empty || buflen <= 0) {
		return NULL;
	}

	/* Get the first buffer entry for inspection */
	entry = &raop_buffer->entries[raop_buffer->first_seqnum % RAOP_BUFFER_LENGTH];
	if (no_resend) {
		/* If we do no resends, always return the first entry */
	} else if (!entry->available) {
		/* Check how much we have space left in the buffer */
		/* ★ 2026-10-05（1.0.57，对照上游）：4 → 16，与上游一致
		 * （third_party/airplay-server/patches/Apply-AudioCodecPatch.ps1 里
		 *  把 RAOP_BUFFER_LENGTH 改成 16）。
		 * 这里是**重传等待窗**：已排到的包还没到时，只要积压没超过这个值就
		 * 返回 NULL 等重传递上来，而不是立刻拿静音顶替。窗口只有 4 包（≈44ms）
		 * 时，Wi-Fi 上一个几十毫秒的抖动就会让大量包被静音替代 —— 那正是反复
		 * 出现的"电音/炸"。16 包（≈175ms @44.1k）足够覆盖一次重传往返。
		 * 注意它自我限流：后续包持续到达 ⇒ buflen 迟早 ≥ 16 ⇒ 真丢了也会在
		 * ~175ms 内换成静音，不会永久卡住。
		 */
		if (buflen < 16) {
			/* Return nothing and hope resend gets on time */
			return NULL;
		}
		/* Risk of buffer overrun, return empty buffer */
	}

	/* Update buffer and validate entry */
	raop_buffer->first_seqnum += 1;
	if (!entry->available) {
		/* Return a silence buffer to skip audio.
		 * ★ 2026-10-04（1.0.54）：静音长度用最近一次真实帧长，不再用
		 * entry->audio_buffer_size —— 缓冲放大后那是 4096 字节（=1024 帧），
		 * 而一个丢包只欠 480/512 帧的时间；按缓冲尺寸补会凭空多出一段
		 * 时间轴，每丢一包音频就往前赶一截，积起来就是持续掉帧/走音。 */
		*length = last_frame_bytes;
		if (*length > entry->audio_buffer_size) {
			*length = entry->audio_buffer_size;
		}
		memset(entry->audio_buffer, 0, *length);
		return entry->audio_buffer;
	}
	entry->available = 0;

	/* Return entry audio buffer */
	*length = entry->audio_buffer_len;
	*pts = entry->timestamp;
	*sample_rate = entry->sample_rate;
	*channels = entry->channels;
	*bits_per_sample = entry->bits_per_sample;

	entry->audio_buffer_len = 0;
	return entry->audio_buffer;
}

void
raop_buffer_handle_resends(raop_buffer_t *raop_buffer, raop_resend_cb_t resend_cb, void *opaque)
{
	raop_buffer_entry_t *entry;

	assert(raop_buffer);
	assert(resend_cb);

	if (seqnum_cmp(raop_buffer->first_seqnum, raop_buffer->last_seqnum) < 0) {
		int seqnum, count;

		for (seqnum=raop_buffer->first_seqnum; seqnum_cmp(seqnum, raop_buffer->last_seqnum)<0; seqnum++) {
			entry = &raop_buffer->entries[seqnum % RAOP_BUFFER_LENGTH];
			if (entry->available) {
				break;
			}
		}
		if (seqnum_cmp(seqnum, raop_buffer->first_seqnum) == 0) {
			return;
		}
		count = seqnum_cmp(seqnum, raop_buffer->first_seqnum);
		resend_cb(opaque, raop_buffer->first_seqnum, count);
	}
}

void
raop_buffer_flush(raop_buffer_t *raop_buffer, int next_seq)
{
	int i;
	assert(raop_buffer);
	for (i=0; i<RAOP_BUFFER_LENGTH; i++) {
		raop_buffer->entries[i].available = 0;
		raop_buffer->entries[i].audio_buffer_len = 0;
	}
	if (next_seq < 0 || next_seq > 0xffff) {
		raop_buffer->is_empty = 1;
	} else {
		raop_buffer->first_seqnum = next_seq;
		raop_buffer->last_seqnum = next_seq-1;
	}
}