// SPDX-License-Identifier: GPL-3.0-only
//
// OhosAirPlayReceiver.cpp —— 鸿蒙侧 AirPlay 接收端宿主实现
//
// 详见同目录 OhosAirPlayReceiver.h 的设计说明。这里补充三条容易踩的点：
//
// 1. raop_init() 会检查 callbacks->audio_process 非空，为 NULL 直接返回 NULL
//    （lib/lib/raop.c 的 "Validate the callbacks structure"）。audio_process
//    和 video_process 即使暂时不解码也必须先给实现，否则收端根本起不来。
//
// 2. airplay_init() 的 pemkey 参数在这版里**没被使用**（RSA 那几行被作者
//    注释掉了），pairing 走 pairing_init_generate() 随机生成。所以鸿蒙侧
//    不需要准备钥匙文件；代价是每次重启配对凭据会变（TODO: 持久化 seed，
//    用 pairing_init_seed() 固定）。
//
// 3. 注册顺序必须是 start → 拿到端口 → 再 dnssd_register_*；RAOP 的服务名
//    是 "<hwaddr>@<name>"，两者都由库内部拼好，宿主只传原始 name。

#include "OhosAirPlayReceiver.h"

#include "Audio/IAudioRenderer.h"
#include "Audio/PcmBufferPolicy.h"
#include "Media/CoreMedia.h"
#include "Media/IVideoDecoder.h"
#include "OhosAudioRenderer.h"
#include "OhosPreviewRenderer.h"
#include "OhosVideoDecoder.h"

#include "airplay.h"

#include "airplay.h"
#include "dnssd.h"
#include "im_dnssd_queue.h"
#include "OhosMdnsResponder.h"
#include "raop.h"
#include "stream.h"

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <random>
#include <span>
#include <string>
#include <thread>
#include <vector>

namespace {

using iPhoneMirror::media::DecoderPreference;
using iPhoneMirror::media::IVideoDecoder;
using iPhoneMirror::media::make_ohos_video_decoder;
using iPhoneMirror::media::OhosPreviewRenderer;

// 前向声明：SetError 的定义在文件后部，RaopVideoProcess 等回调会提前用到。
void SetError(const char* message);

struct ReceiverContext {
    raop_t *raop = nullptr;
    airplay_t *airplay = nullptr;
    dnssd_t *dnssd = nullptr;
    int running = 0;
    int raop_port = 0;
    int airplay_port = 0;
    std::string name;
    std::string password;
    unsigned char hwaddr[6] = {0, 0, 0, 0, 0, 0};
};

ReceiverContext g_context;
std::mutex g_mutex;

std::atomic<uint64_t> g_audio_packets{0};
std::atomic<uint64_t> g_video_frames{0};
// AirPlay 镜像视频真正走通的帧数：RaopVideoProcess 收到帧后送 OH_VideoDecoder，
// 解码成功后由本文件的 present() 路径推进；只要 present() 真拿到了非空 nv12 就 +1。
// 区分它和 g_video_frames（仅"收到"，不论解码成败）是排查"连上了但黑屏"的关键。
std::atomic<uint64_t> g_decoded_frames{0};
std::atomic<int> g_clients{0};

// OhosVideoDecoder 的错误计数通过 OhosVideoDecoder.cpp 暴露的 im_video_decoder_errors()
// C 函数读：这里只缓存"最后一次错误文本"给 UI 看。每次 get_stats 都重新拼一遍。
std::atomic<uint64_t> g_video_decode_errors{0};
std::mutex g_video_decoder_error_lock;
std::string g_video_decoder_last_error;

// AirPlay 镜像视频解码器（Annex-B 直推）。**只有镜像解码线程碰它**：
// 收包回调不再直接解码，改由 VideoDecodeLoop 独占访问（见下面"视频：收包线程
// 只入队"一节）。im_airplay_stop 会先 join 那条线程再 reset，所以不需要额外的锁。
std::shared_ptr<IVideoDecoder> g_video_decoder;
bool g_video_configured{false};

// ──────────────────── 视频：收包线程只入队，解码交给专属线程 ────────────────────
//
// 为什么要解耦（2026-09-21，用户报"打开视频软件画面很不流畅"）：
//
// raop 的镜像视频回调不是"事件通知"，而是**内联在 TCP 收包循环里**的普通函数调用 ——
// raop_rtp_mirror.c:412 收完一个包就地调 video_process()，返回后才继续收下一个。
// 而我们的处理链里有三处重活：等解码器出帧（OhosVideoDecoder.cpp:476，最多 50ms）、
// 每帧拷一份 ~3MB 的 NV12（:947-957）、以及 present() 的一次互斥。
//
// 于是**解码只要慢于收包，收包就被按住**：TCP 的接收窗口不再腾出空间，iPhone 推流
// 被反压（拥塞窗口收缩）→ 后续帧整体延后 → 画面表现为一顿一顿。而且它是自放大的：
// 越卡 → 积压越多 → 越卡。打开视频软件时码率和运动量都上一个台阶，这条路径就撑不住。
//
// 改法：回调只做一次内存拷贝（raop 在回调返回后立刻 free(data->data)，见
// raop_rtp_mirror.c:413-414/479-481，所以这拷贝不能省），把包塞进有界队列就返回；
// 解码 + 上屏由 g_video_thread 消费。收包线程从此与解码速率无关。
struct MirrorPacket {
    std::vector<std::uint8_t> bytes;
    std::int64_t pts{};
    bool is_config{false};   // true = SPS/PPS 参数集
};

// 队列上界（按包计）。超过就丢**最旧的数据包**（参数集永不丢弃）——
// 宁可掉帧也不能让延迟无限累积，那正是"越播越卡"的成因。
constexpr std::size_t kMirrorQueueLimit = 12;

std::mutex g_video_queue_mutex;
std::condition_variable g_video_queue_cv;
std::deque<MirrorPacket> g_video_queue;
std::thread g_video_thread;
bool g_video_thread_running{false};
bool g_video_thread_stop{false};
// 因积压被丢弃的视频包数。>0 = 解码跟不上收包（会掉帧，但延迟不累积）。
std::atomic<uint64_t> g_video_queue_dropped{0};

std::mutex g_log_mutex;
std::string g_last_log;
std::string g_last_error;

// ─────────────────────── AirPlay 音频（Task 27） ───────────────────────
// 上游 Windows 的无线音频走 WirelessReceiverHub → WasapiRenderer；鸿蒙侧没有
// 那个 hub（WirelessReceiverHub.cpp 是 Windows 专属源文件，OHOS 构建不含它），
// 所以 raop 的 audio_process 必须自己接到 OhosAudioRenderer 上。
//
// ★ 这里**绝不取 g_mutex**：音频回调跑在 raop 的 RTP 线程上，而 im_airplay_stop()
//   是"持 g_mutex 调用 raop_stop()"的 —— 音频线程若去抢 g_mutex 就会跟停机流程
//   互等。音频只用下面这把专属锁。
std::unique_ptr<iPhoneMirror::audio::IAudioRenderer> g_audio_renderer;
std::mutex g_audio_mutex;
// 上一次成功建流用的格式。raop_buffer 在"该序号的包没到"时会返回一段静音，
// 而那条分支**不填** sample_rate/channels/bits（见 raop_buffer.c 的
// `if (!entry->available)`），所以必须记住上一份有效格式，否则静音包会把
// 格式冲成 0。
iPhoneMirror::coremedia::AudioStreamBasicDescription g_audio_format{};
bool g_audio_format_known{false};
// 格式指纹（"44100/2/16"）：iPhone 切换采样率或声道数时要重建音频流。
std::string g_audio_format_key;
// 已经喂进去的 PCM 字节数。渲染器自己报 rendered_frames，两者互为佐证：
// bytes 涨而 rendered 不涨 = 数据进来了但端点没在取。
std::atomic<uint64_t> g_audio_bytes_fed{0};
std::atomic<uint64_t> g_audio_flushes{0};
std::atomic<uint64_t> g_audio_open_failures{0};
// iPhone 侧音量（raop 的 audio_set_volume）。建新流时沿用它。
std::atomic<float> g_audio_volume{1.0F};
// 建流失败后置位，避免每包重试（44100 包/秒全在抛异常刷日志）；
// 格式变化时清掉，允许再试一次。
bool g_audio_open_failed{false};
std::mutex g_audio_error_lock;
std::string g_audio_last_error;

// ─────────────────────────── 库日志 ───────────────────────────
// 库的 logger 回调来自工作线程，只留最后一条给 UI 显示（够定位"卡在哪一步"）。

// 这条日志是"纯传输噪音"吗？
//
// 为什么必须滤掉：httpd 的读循环每轮都先打一条 "Receiving on socket N" 再去
// recv()（阻塞）。于是任何有意义的日志——尤其是 iPhone 的
// "Handling request %s with URL %s"——都会在几微秒内被这条覆盖，
// 界面上永远只看到 "Receiving on socket"。而排查"搜得到、连不上"要的恰恰是
// 最后一条**有语义**的消息：iPhone 走到 /info、/pair-setup 还是 /pair-verify。
// 连接被对端 RST 时的 "Error receiving data / Connection closed" 同理：
// 它只会顶掉真正有用的那行，所以一并丢弃。真正的协议错误（LOGGER_ERR，
// 例如 "Incorrect pair-verify signature"）不受影响，照常显示。
//
// 第二类：rtp/时间线程的**每包/周期性** DEBUG。连接健康时它们也在刷，
// 同样会把语义行顶掉——2026-09-19 实测：镜像建立后 UI 的「原生：」位恒显示
// "[7] raop_rtp_mirror_thread_time receive time packetlen = 48"（这是 iPhone
// 周期性 NTP 对时包，出现它反而说明连接活着）。注意不能整级丢 LOGGER_DEBUG(7)：
// 最有用的 "Handling request %s with URL %s" 也是 DEBUG 级，只能按前缀滤。
bool IsTransportNoise(const char *msg) {
    static const char *const kNoisePrefixes[] = {
        "Receiving on socket ",
        "Connection closed for socket ",
        "Error receiving data on socket ",
        // 视频 NTP 时间线程：send time 48 bytes / sendlen / receive time packetlen，周期性
        "raop_rtp_mirror_thread_time ",
        // 音频 NTP 时间线程：send time 32 bytes / sendlen / receive time type_t，周期性
        "raop_rtp_thread_time ",
        // 音频每包一条；同线程的 "raop_rtp_thread_udp unknown packet" 罕见且有语义，保留
        "raop_rtp_thread_udp type_c",
    };
    for (const char *prefix : kNoisePrefixes) {
        if (std::strncmp(msg, prefix, std::strlen(prefix)) == 0) return true;
    }
    return false;
}

void StoreLog(int level, const char *msg) {
    if (msg == nullptr) return;
    if (IsTransportNoise(msg)) return;
    std::lock_guard<std::mutex> lock(g_log_mutex);
    char buffer[IM_AIRPLAY_TEXT_MAX];
    std::snprintf(buffer, sizeof(buffer), "[%d] %s", level, msg);
    g_last_log = buffer;
}

void RaopLogCallback(void * /*cls*/, int level, const char *msg) {
    StoreLog(level, msg);
}

void AirPlayLogCallback(void * /*cls*/, int level, const char *msg) {
    StoreLog(level, msg);
}

// ─────────────────────── 音频：格式 / 建流 / 喂数 ───────────────────────

// 格式指纹：只取"采样率/声道/位深"，用于判断要不要重建音频流。
std::string FormatAudioKey(const iPhoneMirror::coremedia::AudioStreamBasicDescription &format) {
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "%.0f/%u/%u",
        format.sample_rate, format.channels_per_frame, format.bits_per_channel);
    return buffer;
}

// 给人看的格式描述，例 "44100Hz/2ch/16bit"。UI 直接显示它。
std::string DescribeAudioFormat(const iPhoneMirror::coremedia::AudioStreamBasicDescription &format) {
    char buffer[96];
    std::snprintf(buffer, sizeof(buffer), "%.0fHz/%uch/%ubit",
        format.sample_rate, format.channels_per_frame, format.bits_per_channel);
    return buffer;
}

void SetAudioError(const std::string &text) {
    std::lock_guard<std::mutex> lock(g_audio_error_lock);
    g_audio_last_error = text;
}

std::string AudioErrorText() {
    std::lock_guard<std::mutex> lock(g_audio_error_lock);
    return g_audio_last_error;
}

// raop 给的 PCM 描述 → 上游 ASBD。返回 false 表示这包没带格式信息
// （raop_buffer 的静音填充分支不填这些字段）。
bool BuildAudioFormat(const pcm_data_struct &data,
    iPhoneMirror::coremedia::AudioStreamBasicDescription &out) {
    if (data.sample_rate == 0 || data.channels == 0 || data.bits_per_sample == 0) {
        return false;
    }
    out = iPhoneMirror::coremedia::AudioStreamBasicDescription{};
    out.sample_rate = static_cast<double>(data.sample_rate);
    out.format_id = iPhoneMirror::audio::detail::LinearPcm;
    out.format_flags = iPhoneMirror::audio::detail::PcmIsSignedInteger;
    out.bits_per_channel = data.bits_per_sample;
    out.channels_per_frame = data.channels;
    out.frames_per_packet = 1;
    out.bytes_per_frame =
        static_cast<std::uint32_t>(data.bits_per_sample / 8U) * data.channels;
    out.bytes_per_packet = out.bytes_per_frame;
    return true;
}

// 建流。调用者必须已持 g_audio_mutex。失败时把确切原因写进 audio_error
// —— "没声音"和"建流失败"必须分得开，这是本工程一贯的要求。
bool OpenAudioRendererLocked(const iPhoneMirror::coremedia::AudioStreamBasicDescription &format) {
    try {
        g_audio_renderer = iPhoneMirror::audio::make_ohos_audio_renderer(
            format, /*playback_enabled=*/true, g_audio_volume.load());
        SetAudioError("");
        return true;
    } catch (const std::exception &e) {
        g_audio_renderer.reset();
        g_audio_open_failures.fetch_add(1, std::memory_order_relaxed);
        SetAudioError(e.what());
        return false;
    }
}

// ─────────────────────────── raop 回调 ───────────────────────────
// 视频：Task 26 已接入——raop 给的 H.264 是 Annex-B，frame_type==0 用 SPS/PPS
// 配置 OH_VideoDecoder，frame_type==1 解码后送 OhosPreviewRenderer 上屏。
// 音频：Task 27 已接入——raop 已经把 AirPlay 音频（ALAC/AAC-ELD）解成
// 交错 PCM16，这里把它喂给 OhosAudioRenderer（OHAudio 播放）。

void RaopAudioProcess(void * /*cls*/, pcm_data_struct *data,
    const char * /*remoteName*/, const char * /*remoteDeviceId*/) {
    g_audio_packets.fetch_add(1, std::memory_order_relaxed);
    if (data == nullptr || data->data == nullptr || data->data_len <= 0) return;

    // ① 格式：有效就刷新并记住；无效（静音填充包）沿用上一份。
    iPhoneMirror::coremedia::AudioStreamBasicDescription packet_format{};
    const bool has_format = BuildAudioFormat(*data, packet_format);

    std::lock_guard<std::mutex> lock(g_audio_mutex);
    if (has_format) {
        const std::string key = FormatAudioKey(packet_format);
        if (g_audio_format_known && key != g_audio_format_key) {
            // 格式变了（iPhone 换采样率/声道）：旧流按旧格式开着，必须重建，
            // 并清掉"建流失败"的闩锁给新格式一次机会。
            if (g_audio_renderer) {
                g_audio_renderer->stop();
                g_audio_renderer.reset();
            }
            g_audio_open_failed = false;
        }
        g_audio_format = packet_format;
        g_audio_format_key = key;
        g_audio_format_known = true;
    }
    if (!g_audio_format_known) return;   // 还没见过任何带格式信息的包

    if (!g_audio_renderer) {
        if (g_audio_open_failed) return; // 已失败过，等格式变化再试
        if (!OpenAudioRendererLocked(g_audio_format)) {
            g_audio_open_failed = true;
            return;
        }
    }

    const std::span<const std::uint8_t> bytes(
        reinterpret_cast<const std::uint8_t *>(data->data),
        static_cast<std::size_t>(data->data_len));
    try {
        g_audio_renderer->enqueue(bytes);
    } catch (const std::exception &e) {
        SetAudioError(e.what());
        return;
    }
    g_audio_bytes_fed.fetch_add(bytes.size(), std::memory_order_relaxed);
}

void RaopAudioFlush(void * /*cls*/, void * /*session*/,
    const char * /*remoteName*/, const char * /*remoteDeviceId*/) {
    // iPhone 在暂停/切歌/seek 时会要我们丢弃已排队的音频。IAudioRenderer 没有
    // flush 接口（Windows/Linux 后端同样没有），所以这里只记账；连续性由渲染器
    // 内部的"积压就丢最旧帧"策略兜底。
    g_audio_flushes.fetch_add(1, std::memory_order_relaxed);
}

void RaopAudioSetVolume(void * /*cls*/, void * /*session*/, float volume,
    const char * /*remoteName*/, const char * /*remoteDeviceId*/) {
    const float clamped = std::clamp(volume, 0.0F, 1.0F);
    g_audio_volume.store(clamped, std::memory_order_relaxed);
    std::lock_guard<std::mutex> lock(g_audio_mutex);
    if (g_audio_renderer) {
        g_audio_renderer->set_volume(clamped);
    }
}

// 真正干活的一步：解码 + 上屏。**只在 g_video_thread 上跑**（见上面"视频：收包
// 线程只入队"一节的说明）。因此它绝不取 g_mutex —— im_airplay_stop 是持 g_mutex
// join 本线程的，取锁就会互等。
void ProcessMirrorPacket(const MirrorPacket &packet) {
    if (packet.is_config) {
        // SPS/PPS 参数集（raop 已拼成 Annex-B：00 00 00 01 SPS 00 00 00 01 PPS）。
        // 宽高给提示值，真实分辨率由 OH_VideoDecoder 的 OnStreamChanged 上报后自动纠正。
        if (!g_video_decoder) {
            g_video_decoder = make_ohos_video_decoder(DecoderPreference::Auto);
        }
        try {
            g_video_decoder->configure_annex_b(
                std::span<const std::uint8_t>(packet.bytes.data(), packet.bytes.size()),
                1920, 1080, false);
            g_video_configured = true;
        } catch (const std::exception &e) {
            SetError(e.what());
            g_video_configured = false;
        }
        return;
    }

    // 尚未完成 SPS/PPS 配置的帧直接丢，避免解码器因缺少参数集而一帧都解不出。
    if (!g_video_configured || !g_video_decoder) return;
    std::vector<iPhoneMirror::media::DecodedFrame> frames;
    try {
        frames = g_video_decoder->decode_annex_b(
            std::span<const std::uint8_t>(packet.bytes.data(), packet.bytes.size()),
            packet.pts);
    } catch (const std::exception &e) {
        SetError(e.what());
        return;
    }
    for (auto &frame : frames) {
        // present() 只是把帧投递给渲染线程（move 进去，避免每帧 1.7MB 拷贝），
        // 所以"有没有像素"要在 move 之前问。
        const bool has_pixels = !frame.nv12.empty();
        OhosPreviewRenderer::instance().present(std::move(frame));
        // 只有解码器真正交出像素才算"通了"：空帧（OnError 后、缺参考帧等）不计。
        if (has_pixels) {
            g_decoded_frames.fetch_add(1, std::memory_order_relaxed);
        }
    }
}

// 镜像解码线程主体：等队列 → 取一个包 → 解码上屏。
void VideoDecodeLoop() {
    for (;;) {
        MirrorPacket packet;
        {
            std::unique_lock<std::mutex> lock(g_video_queue_mutex);
            g_video_queue_cv.wait(lock, [] {
                return g_video_thread_stop || !g_video_queue.empty();
            });
            // 停机时把队列排干再退：已经收下的帧没必要白扔（参数集也一起排掉）。
            if (g_video_queue.empty()) {
                if (g_video_thread_stop) return;
                continue;
            }
            packet = std::move(g_video_queue.front());
            g_video_queue.pop_front();
        }
        ProcessMirrorPacket(packet);
    }
}

/** 启动解码线程。调用者必须已持 g_mutex（im_airplay_start）。 */
void StartVideoDecodeThread() {
    std::lock_guard<std::mutex> lock(g_video_queue_mutex);
    if (g_video_thread_running) return;
    g_video_queue.clear();
    g_video_thread_stop = false;
    try {
        g_video_thread = std::thread(VideoDecodeLoop);
    } catch (const std::exception &e) {
        SetError(e.what());
        return;
    }
    g_video_thread_running = true;
}

/**
 * 停解码线程并排干队列。调用者必须已持 g_mutex（ShutdownLocked）。
 *
 * ★ 必须在 g_video_decoder.reset() **之前**调用：解码器归那条线程独占使用，
 *   不 join 就 reset 就是 use-after-free。
 */
void StopVideoDecodeThread() {
    {
        std::lock_guard<std::mutex> lock(g_video_queue_mutex);
        if (!g_video_thread_running) {
            g_video_queue.clear();
            return;
        }
        g_video_thread_stop = true;
    }
    g_video_queue_cv.notify_all();
    if (g_video_thread.joinable()) g_video_thread.join();
    std::lock_guard<std::mutex> lock(g_video_queue_mutex);
    g_video_thread_running = false;
    g_video_queue.clear();
}

// 收包回调：只拷贝 + 入队，立刻返回（见上面"视频：收包线程只入队"一节的说明）。
// 这是全局唯一的镜像视频入口，无法再往下做别的重活 —— 每多花一毫秒，收包就晚一毫秒。
void RaopVideoProcess(void * /*cls*/, h264_decode_struct *data,
    const char * /*remoteName*/, const char * /*remoteDeviceId*/) {
    if (data == nullptr || data->data == nullptr || data->data_len <= 0) return;
    g_video_frames.fetch_add(1, std::memory_order_relaxed);

    MirrorPacket packet;
    packet.is_config = data->frame_type == 0;
    packet.pts = static_cast<std::int64_t>(data->pts);
    // 这行拷贝不能省：raop 的收包循环在回调返回后**立刻** free(data->data)
    // （raop_rtp_mirror.c:413-414 与 479-481），而解码在另一个线程上。
    const std::uint8_t *first = reinterpret_cast<const std::uint8_t *>(data->data);
    packet.bytes.assign(first, first + static_cast<std::size_t>(data->data_len));

    {
        std::lock_guard<std::mutex> lock(g_video_queue_mutex);
        if (!packet.is_config && g_video_queue.size() >= kMirrorQueueLimit) {
            for (auto it = g_video_queue.begin(); it != g_video_queue.end(); ++it) {
                if (!it->is_config) {
                    g_video_queue.erase(it);
                    g_video_queue_dropped.fetch_add(1, std::memory_order_relaxed);
                    break;
                }
            }
        }
        g_video_queue.push_back(std::move(packet));
    }
    g_video_queue_cv.notify_one();
}

void RaopConnected(void * /*cls*/, const char * /*remoteName*/,
    const char * /*remoteDeviceId*/) {
    g_clients.fetch_add(1, std::memory_order_relaxed);
}

void RaopDisconnected(void * /*cls*/, const char * /*remoteName*/,
    const char * /*remoteDeviceId*/) {
    g_clients.fetch_sub(1, std::memory_order_relaxed);
}

// ─────────────────────────── airplay 回调 ───────────────────────────
// 视频 URL 播放（照片/视频 App 投屏）本工程不做，如实什么都不播。

void AirPlayVideoPlay(void * /*cls*/, char * /*url*/, double /*volume*/,
    double /*start_pos*/) {
}

void AirPlayVideoGetPlayInfo(void * /*cls*/, double *duration, double *position,
    double *rate) {
    if (duration != nullptr) *duration = 0.0;
    if (position != nullptr) *position = 0.0;
    if (rate != nullptr) *rate = 0.0;
}

// 取本机身份用的 MAC。优先用真实主网卡 MAC（im_ohos_primary_mac），这样
// AirPlay 的 deviceid 与 mDNS 主机名稳定，iPhone 重启 App 后还能认出同一台
// 设备、不必重新配对。拿不到真实 MAC 才回退到随机（置本地管理位避免与真实
// 网卡撞车）—— 这是兜底，不是常态。
void AcquireHwaddr(unsigned char hwaddr[6]) {
    char mac_text[32] = {0};
    unsigned int bytes[6] = {0};
    if (im_ohos_primary_mac(mac_text, sizeof(mac_text)) == 0 &&
        std::sscanf(mac_text, "%02X:%02X:%02X:%02X:%02X:%02X",
            &bytes[0], &bytes[1], &bytes[2], &bytes[3], &bytes[4], &bytes[5]) == 6) {
        for (int i = 0; i < 6; ++i) {
            hwaddr[i] = static_cast<unsigned char>(bytes[i]);
        }
        return;
    }
    std::random_device device;
    for (int i = 0; i < 6; ++i) {
        hwaddr[i] = static_cast<unsigned char>(device() & 0xFF);
    }
    // 置 locally-administered + unicast 位，避免与真实网卡 MAC 撞车。
    hwaddr[0] = static_cast<unsigned char>((hwaddr[0] | 0x02) & 0xFE);
}

std::string FormatHwaddr(const unsigned char hwaddr[6]) {
    char buffer[32];
    std::snprintf(buffer, sizeof(buffer), "%02X:%02X:%02X:%02X:%02X:%02X",
        hwaddr[0], hwaddr[1], hwaddr[2], hwaddr[3], hwaddr[4], hwaddr[5]);
    return std::string(buffer);
}

void SetError(const char *message) {
    std::lock_guard<std::mutex> lock(g_log_mutex);
    g_last_error = message != nullptr ? message : "";
}

void ShutdownLocked() {
    if (g_context.dnssd != nullptr) {
        dnssd_unregister_raop(g_context.dnssd);
        dnssd_unregister_airplay(g_context.dnssd);
        dnssd_destroy(g_context.dnssd);
        g_context.dnssd = nullptr;
    }
    if (g_context.raop != nullptr) {
        raop_stop(g_context.raop);
        raop_destroy(g_context.raop);
        g_context.raop = nullptr;
    }
    if (g_context.airplay != nullptr) {
        airplay_stop(g_context.airplay);
        airplay_destroy(g_context.airplay);
        g_context.airplay = nullptr;
    }
    g_context.running = 0;
    g_context.raop_port = 0;
    g_context.airplay_port = 0;
    g_clients.store(0);
    // ★ 顺序要紧：先停解码线程，再放解码器。解码器归那条线程独占使用
    //   （见"视频：收包线程只入队"一节），不 join 就 reset 就是 use-after-free。
    StopVideoDecodeThread();
    g_video_decoder.reset();
    g_video_configured = false;

    // 音频流也要收掉：OHAudio 的音轨是系统资源，留着会在下次启动时占着端点。
    // 注意此时已持 g_mutex，而音频回调只用 g_audio_mutex ⇒ 不会互等。
    {
        std::lock_guard<std::mutex> audio_lock(g_audio_mutex);
        if (g_audio_renderer) {
            g_audio_renderer->stop();
            g_audio_renderer.reset();
        }
        g_audio_format_known = false;
        g_audio_format_key.clear();
        g_audio_open_failed = false;
    }
}

} // namespace

int im_airplay_start(const char *name, const char *password) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_context.running != 0) {
        SetError("AirPlay 接收端已经在运行");
        return -1;
    }

    const std::string device_name =
        (name != nullptr && name[0] != '\0') ? name : "iPhoneMirror";

    if (g_context.hwaddr[0] == 0 && g_context.hwaddr[1] == 0 &&
        g_context.hwaddr[2] == 0) {
        AcquireHwaddr(g_context.hwaddr);
    }

    // ── RAOP（RTSP + RTP + 镜像） ──
    raop_callbacks_t raop_callbacks{};
    raop_callbacks.cls = &g_context;
    raop_callbacks.audio_process = &RaopAudioProcess;
    raop_callbacks.audio_flush = &RaopAudioFlush;
    raop_callbacks.audio_set_volume = &RaopAudioSetVolume;
    raop_callbacks.video_process = &RaopVideoProcess;
    raop_callbacks.connected = &RaopConnected;
    raop_callbacks.disconnected = &RaopDisconnected;

    raop_t *raop = raop_init(1, &raop_callbacks);
    if (raop == nullptr) {
        SetError("raop_init 失败（协议库未初始化成功）");
        return -1;
    }
    raop_set_log_callback(raop, &RaopLogCallback, nullptr);
    // LOGGER_DEBUG(7)：**等级数字越大越啰嗦**（logger.c 里是 `level > logger->level`
    // 就丢弃）。为什么必须开到最大：iPhone 的每一条请求都只在 DEBUG 级打印
    // （raop.c/airplay.c 的 "Handling request %s with URL %s"），而
    // "搜得到、连不上"最需要知道的就是 iPhone 走到哪一步了。设成 5(NOTICE)
    // 会把这些全部滤掉，界面只剩沉默——上一轮排查正是卡在这里。
    // 代价可控：本文件只保留最后一条日志，不打屏也不落盘。
    raop_set_log_level(raop, 7);

    unsigned short raop_port = 0;
    if (raop_start(raop, &raop_port) < 0) {
        raop_destroy(raop);
        SetError("raop_start 失败（RTSP 端口无法监听）");
        return -1;
    }

    // ── AirPlay（HTTP 控制面） ──
    airplay_callbacks_t airplay_callbacks{};
    airplay_callbacks.cls = &g_context;
    airplay_callbacks.video_play = &AirPlayVideoPlay;
    airplay_callbacks.video_get_play_info = &AirPlayVideoGetPlayInfo;

    int airplay_error = 0;
    airplay_t *airplay = airplay_init(1, &airplay_callbacks, nullptr,
        &airplay_error);
    if (airplay == nullptr) {
        raop_stop(raop);
        raop_destroy(raop);
        SetError("airplay_init 失败（HTTP 服务无法创建）");
        return -1;
    }
    airplay_set_log_callback(airplay, &AirPlayLogCallback, nullptr);
    airplay_set_log_level(airplay, 7); // LOGGER_DEBUG，理由同上面的 raop_set_log_level

    const char *password_argument =
        (password != nullptr && password[0] != '\0') ? password : nullptr;
    unsigned short airplay_port = 0;
    if (airplay_start(airplay, &airplay_port,
            reinterpret_cast<const char *>(g_context.hwaddr), 6,
            password_argument) < 0) {
        airplay_destroy(airplay);
        raop_stop(raop);
        raop_destroy(raop);
        SetError("airplay_start 失败（AirPlay 端口无法监听）");
        return -1;
    }

    // ── 服务发现（把要广播的内容排进队列，ArkTS 用 @ohos.net.mdns 发出去） ──
    int dnssd_error = 0;
    dnssd_t *dnssd = dnssd_init(&dnssd_error);
    if (dnssd == nullptr) {
        airplay_stop(airplay);
        airplay_destroy(airplay);
        raop_stop(raop);
        raop_destroy(raop);
        SetError("dnssd_init 失败");
        return -1;
    }

    if (dnssd_register_raop(dnssd, device_name.c_str(), raop_port,
            reinterpret_cast<const char *>(g_context.hwaddr), 6,
            password_argument != nullptr ? 1 : 0) < 0) {
        dnssd_destroy(dnssd);
        airplay_stop(airplay);
        airplay_destroy(airplay);
        raop_stop(raop);
        raop_destroy(raop);
        SetError("RAOP 服务注册入队失败");
        return -1;
    }
    if (dnssd_register_airplay(dnssd, device_name.c_str(), airplay_port,
            reinterpret_cast<const char *>(g_context.hwaddr), 6) < 0) {
        dnssd_destroy(dnssd);
        airplay_stop(airplay);
        airplay_destroy(airplay);
        raop_stop(raop);
        raop_destroy(raop);
        SetError("AirPlay 服务注册入队失败");
        return -1;
    }

    // ── 原生 mDNS 响应器：接管 DNS-SD 队列，真正把记录广播到局域网 ──
    // 实测 @ohos.net.mdns 在这台设备（鸿蒙 PC / 2in1）上不把记录发到网上，
    // 所以只要响应器能绑上 5353 就由它广播。失败也不阻塞接收端启动，只是
    // 退回 ArkTS 回退路径（它多半也不工作，但至少不谎报"已广播成功"）。
    if (im_mdns_responder_start() != 0) {
        StoreLog(2, "原生 mDNS 响应器启动失败，退回 @ohos.net.mdns 回退路径");
        StoreLog(2, im_mdns_responder_error());
    }

    // ── 构建指纹 ──
    // 这个工程反复踩的坑是「源码改了 ≠ 设备上跑的是新版」：.so-only 的改动
    // （global.h / OhosMdnsResponder.cpp / 本文件）**必须重装 HAP** 才生效，而
    // 界面上的状态行在"装的还是旧包"和"新包跑坏了"两种情况下长得一模一样。
    // 所以把本 .so 的**编译时间**打出来当指纹：重装后这行会变，没变就是没装上去。
    // 空闲时它是「原生：」行的最后一条；一旦 iPhone 发来请求，会被请求日志覆盖
    // （那正是排查连接阶段最需要的信息），互不冲突。
    StoreLog(6, "核心构建 " __DATE__ " " __TIME__ "；原生 mDNS 响应器已启动");

    g_context.raop = raop;
    g_context.airplay = airplay;
    g_context.dnssd = dnssd;
    g_context.raop_port = raop_port;
    g_context.airplay_port = airplay_port;
    g_context.name = device_name;
    g_context.password = password_argument != nullptr ? password_argument : "";
    g_context.running = 1;
    SetError("");

    g_audio_packets.store(0);
    g_audio_bytes_fed.store(0);
    g_audio_flushes.store(0);
    g_audio_open_failures.store(0);
    g_audio_volume.store(1.0F);
    {
        // 音频状态必须跟视频一样在新会话开始时清零 —— 否则上一轮的
        // "已播放 N 帧"会挂在那里，正是本工程反复强调的"假成功"温床。
        std::lock_guard<std::mutex> audio_lock(g_audio_mutex);
        g_audio_format_known = false;
        g_audio_format_key.clear();
        g_audio_open_failed = false;
    }
    SetAudioError("");
    g_video_frames.store(0);
    g_decoded_frames.store(0);
    g_video_decode_errors.store(0);
    g_video_queue_dropped.store(0);
    {
        std::lock_guard<std::mutex> err_lock(g_video_decoder_error_lock);
        g_video_decoder_last_error.clear();
    }
    // 解码线程放在最后启动：前面任何一条失败路径 return -1 时都不该留下线程。
    StartVideoDecodeThread();
    return 0;
}

void im_airplay_stop(void) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_context.running == 0) return;
    // 先停原生响应器：它会给仍在播的服务发 TTL=0 的 goodbye，iPhone 列表里立刻消失，
    // 而不是等缓存过期才消失。
    im_mdns_responder_stop();
    ShutdownLocked();
    // 清掉残留的队列状态，避免下次启动时混入上一次的条目。
    im_dnssd_queue_reset();
}

int im_airplay_is_running(void) {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_context.running;
}

void im_airplay_get_stats(ImAirPlayStats *out) {
    if (out == nullptr) return;
    std::memset(out, 0, sizeof(*out));

    std::lock_guard<std::mutex> lock(g_mutex);
    out->running = g_context.running;
    out->raop_port = g_context.raop_port;
    out->airplay_port = g_context.airplay_port;
    out->audio_packets = g_audio_packets.load(std::memory_order_relaxed);
    out->audio_bytes_fed = g_audio_bytes_fed.load(std::memory_order_relaxed);
    out->audio_flushes = g_audio_flushes.load(std::memory_order_relaxed);
    out->audio_open_failures = g_audio_open_failures.load(std::memory_order_relaxed);
    {
        // "有没有声音"必须能自证：audio_packets 只说明 raop 给了数据，
        // 真正出声的判据是渲染器报的 rendered_frames（写回调真把数据取走了）。
        // 两者一起显示，才分得开「数据进来了但没出端点」和「根本没数据」。
        std::lock_guard<std::mutex> audio_lock(g_audio_mutex);
        if (g_audio_renderer) {
            const auto playback = g_audio_renderer->stats();
            out->audio_renderer_active = playback.active ? 1 : 0;
            out->audio_frames_played = playback.rendered_frames;
            out->audio_underruns = playback.underruns;
            out->audio_dropped_frames = playback.dropped_frames;
        }
        if (g_audio_format_known) {
            const std::string described = DescribeAudioFormat(g_audio_format);
            std::snprintf(out->audio_format, sizeof(out->audio_format), "%s",
                described.c_str());
        }
    }
    {
        const std::string audio_error = AudioErrorText();
        std::snprintf(out->audio_error, sizeof(out->audio_error), "%s",
            audio_error.c_str());
    }
    out->video_frames = g_video_frames.load(std::memory_order_relaxed);
    out->decoded_frames = g_decoded_frames.load(std::memory_order_relaxed);
    out->video_queue_dropped = g_video_queue_dropped.load(std::memory_order_relaxed);
    out->video_decode_errors = iPhoneMirror::media::im_video_decoder_errors();
    {
        std::lock_guard<std::mutex> err_lock(g_video_decoder_error_lock);
        std::snprintf(out->video_decoder_last_error, sizeof(out->video_decoder_last_error), "%s",
            g_video_decoder_last_error.c_str());
    }
    out->clients = g_clients.load(std::memory_order_relaxed);
    std::snprintf(out->name, sizeof(out->name), "%s", g_context.name.c_str());
    const std::string hwaddr = FormatHwaddr(g_context.hwaddr);
    std::snprintf(out->hwaddr, sizeof(out->hwaddr), "%s", hwaddr.c_str());

    {
        std::lock_guard<std::mutex> log_lock(g_log_mutex);
        std::snprintf(out->last_error, sizeof(out->last_error), "%s",
            g_last_error.c_str());
        std::snprintf(out->last_log, sizeof(out->last_log), "%s",
            g_last_log.c_str());
    }

    im_dnssd_queue_stats(&out->mdns_pending, &out->mdns_registered,
        &out->mdns_failed, &out->mdns_pending_removal);
    out->mdns_active = im_mdns_responder_is_active();
    out->mdns_answered = im_mdns_responder_answered_queries();
    {
        const char *local_ip = im_mdns_responder_local_ip();
        std::snprintf(out->mdns_local_ip, sizeof(out->mdns_local_ip), "%s",
            local_ip != nullptr ? local_ip : "");
        const char *mdns_error = im_mdns_responder_error();
        std::snprintf(out->mdns_error, sizeof(out->mdns_error), "%s",
            mdns_error != nullptr ? mdns_error : "");
    }
    // 诊断字段：回答"已应答 N 次、iPhone 却搜不到"到底卡在哪一段。
    out->mdns_dropped_self = im_mdns_responder_dropped_self();
    out->mdns_announce_sent = im_mdns_responder_announce_sent();
    out->mdns_announce_failed = im_mdns_responder_announce_failed();
    {
        const char *out_iface = im_mdns_responder_outbound_iface();
        std::snprintf(out->mdns_out_iface, sizeof(out->mdns_out_iface), "%s",
            out_iface != nullptr ? out_iface : "");
        const char *last_from = im_mdns_responder_last_answer_from();
        std::snprintf(out->mdns_last_from, sizeof(out->mdns_last_from), "%s",
            last_from != nullptr ? last_from : "");
        const char *last_ip = im_mdns_responder_last_answer_ip();
        std::snprintf(out->mdns_last_answer_ip, sizeof(out->mdns_last_answer_ip), "%s",
            last_ip != nullptr ? last_ip : "");
    }
    // "问了什么 / 我们手里有什么"：iPhone 的「屏幕镜像」只认 _airplay._tcp，
    // 但它也会问 _raop._tcp，两者我们都会答 —— 必须把名字摊开才分得清。
    {
        const char *last_query = im_mdns_responder_last_query();
        std::snprintf(out->mdns_last_query, sizeof(out->mdns_last_query), "%s",
            last_query != nullptr ? last_query : "");
        const char *counts = im_mdns_responder_query_counts();
        std::snprintf(out->mdns_query_counts, sizeof(out->mdns_query_counts), "%s",
            counts != nullptr ? counts : "");
        const char *services = im_mdns_responder_service_list();
        std::snprintf(out->mdns_services, sizeof(out->mdns_services), "%s",
            services != nullptr ? services : "");
    }
    if (out->mdns_failed > 0 && out->last_error[0] == '\0') {
        const char *mdns_error = im_dnssd_queue_last_error();
        std::snprintf(out->last_error, sizeof(out->last_error), "%s",
            mdns_error != nullptr ? mdns_error : "mDNS 广播失败");
    }
}
