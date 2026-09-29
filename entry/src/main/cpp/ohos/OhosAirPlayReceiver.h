// SPDX-License-Identifier: GPL-3.0-only
//
// OhosAirPlayReceiver.h —— 鸿蒙侧的 AirPlay 接收端宿主（新增文件）
//
// 上游 Windows 版的无线链路是：
//     WPF → 命名管道 → iPhoneMirror.WirelessHost.exe → airplay2dll.dll（预编译 x64）
// 这三个环节在鸿蒙上一个都不存在，所以这里直接驱动 vendored 的协议库
// （third_party/airplayserver，RPiPlay 血统）：raop（RTSP/RTP + 镜像）
// + airplay（HTTP 控制面）+ dnssd（服务发现，鸿蒙走 @ohos.net.mdns）。
//
// 职责边界：
//   * 只做**宿主的启停与状态**，不做音视频解码本身 —— 音视频各自的解码/渲染由
//     本文件把数据转交给 OhosVideoDecoder / OhosAudioRenderer（Task 26/27 已接入）；
//   * 状态结构里必须同时给出"收到多少"和"真正播出去多少"两组数字，UI 才分得开
//     「没数据」「有数据没人取」「在播」三种情形（遵守不许假成功）。
//
// 全部接口都是同步的，且**必须只在 JS 线程调用**（库内部 start/stop 会
// 建/收线程，但调用本身很快；dnssd 注册走队列，不阻塞）。

#ifndef IPHONEMIRROR_OHOS_AIRPLAY_RECEIVER_H
#define IPHONEMIRROR_OHOS_AIRPLAY_RECEIVER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define IM_AIRPLAY_NAME_MAX 128
#define IM_AIRPLAY_TEXT_MAX 256

typedef struct ImAirPlayStats {
    int running;                 // 1 = 接收端已启动
    int raop_port;               // RTSP 端口（0 = 未启动）
    int airplay_port;            // AirPlay HTTP 端口
    int mdns_pending;            // 待广播
    int mdns_registered;         // 已确认广播
    int mdns_failed;             // 广播失败
    int mdns_pending_removal;    // 待注销
    int mdns_active;             // 1 = 原生 mDNS 响应器正在广播
    uint64_t mdns_answered;      // 已应答的 mDNS 查询数（>0 说明 iPhone 真来问过）
    char mdns_local_ip[IM_AIRPLAY_TEXT_MAX]; // 应答里 A 记录用的本机 IP
    char mdns_error[IM_AIRPLAY_TEXT_MAX];     // 原生响应器最近一次启动失败原因
    // ── "已应答 N 次、iPhone 却搜不到" 专用诊断（见 OhosMdnsResponder.h 同名字段）──
    uint64_t mdns_dropped_self;               // 被"来源为本机"闸门丢弃的包数
    uint64_t mdns_announce_sent;              // 主动宣告 sendto 成功次数
    uint64_t mdns_announce_failed;            // 主动宣告 sendto 失败次数
    char mdns_out_iface[IM_AIRPLAY_TEXT_MAX]; // IP_MULTICAST_IF 内核实际生效值
    char mdns_last_from[IM_AIRPLAY_TEXT_MAX]; // 最近被应答的查询来源 IP
    char mdns_last_answer_ip[IM_AIRPLAY_TEXT_MAX]; // 该次应答里 A 记录用的 IP
    // ── "问了什么 / 我们手里有什么"（判读见 OhosMdnsResponder.h）──
    // 没有这三项就分不清"iPhone 只问了 _raop"和"我们手里没有 _airplay 服务"，
    // 而这两种病的处置方式完全不同。
    char mdns_last_query[IM_AIRPLAY_TEXT_MAX];   // 最近收到的一条查询（含未应答原因）
    char mdns_query_counts[IM_AIRPLAY_TEXT_MAX]; // 按 _airplay/_raop/枚举/其他 分类计数
    char mdns_services[IM_AIRPLAY_TEXT_MAX];     // 当前真正持有并已宣告的服务清单
    uint64_t audio_packets;      // 已收到的音频包数（raop 给我们的次数）
    // ── 音频是否真出声（判据成对，缺一分不开"没数据"与"没出端点"）──
    //   audio_packets 涨 + audio_frames_played 不涨 → 数据进来了，但没人取
    //   audio_packets 不涨                        → raop 那侧就没有音频数据
    uint64_t audio_frames_played;   // 渲染器真正送给系统端点并播放的帧数
    uint64_t audio_bytes_fed;       // 已喂进渲染器的 PCM 字节数
    uint64_t audio_underruns;       // 欠载次数（>0 = 供数跟不上，听感断续）
    uint64_t audio_dropped_frames;  // 因积压被丢弃的旧帧
    uint64_t audio_flushes;         // iPhone 下发的 flush 次数（暂停/切歌/seek）
    uint64_t audio_open_failures;   // 建流失败次数（>0 时看 audio_error）
    int audio_renderer_active;      // 1 = 音频流已建立且处于播放态
    char audio_format[IM_AIRPLAY_TEXT_MAX]; // 当前音频格式，例 "44100Hz/2ch/16bit"
    char audio_error[IM_AIRPLAY_TEXT_MAX];  // 最近一次建流/播放失败原因
    uint64_t video_frames;       // 已收到的视频帧数（尚未解码）
    // 已成功解码并真正推到预览的帧数（≠ video_frames：后者只算 RaopVideoProcess 被
    // 调用次数，前者要求 OH_VideoDecoder 真交出非空 NV12 才 +1）。两者一致说明
    // 解码器工作正常、画面应该出；不一致说明解码链某段不通。
    uint64_t decoded_frames;
    // 因"收包快于解码"被丢弃的旧视频包数（参数集不计入、也永不被丢弃）。
    // 判读：>0 说明解码跟不上收包 —— 会掉帧，但延迟不累积（队列有上界）；
    //       它和 decoded_frames 一起看才分得开"解码器坏了"和"解码器只是不够快"。
    uint64_t video_queue_dropped;
    // OH_VideoDecoder OnError 回调累计次数。>0 说明解码器主动失败、UI 必须报。
    uint64_t video_decode_errors;
    // 最后一次 OnError 的错误码文本，例 "ohos avcodec error=14"。
    char video_decoder_last_error[IM_AIRPLAY_TEXT_MAX];
    int clients;                 // 当前连接数
    char name[IM_AIRPLAY_NAME_MAX];
    char hwaddr[IM_AIRPLAY_TEXT_MAX];
    char last_error[IM_AIRPLAY_TEXT_MAX];
    char last_log[IM_AIRPLAY_TEXT_MAX];
} ImAirPlayStats;

// 启动接收端。name 为空时用 "iPhoneMirror"。password 为 NULL/空表示不设密码。
// 返回 0 成功，非 0 失败（失败原因写入 stats.last_error，可用
// im_airplay_get_stats 读出）。
int im_airplay_start(const char *name, const char *password);

// 停止接收端并把 mDNS 服务排入注销队列。
void im_airplay_stop(void);

int im_airplay_is_running(void);

// 取出统计快照。out 不能为 NULL。
void im_airplay_get_stats(ImAirPlayStats *out);

#ifdef __cplusplus
}
#endif

#endif
