// SPDX-License-Identifier: GPL-3.0-only
//
// 鸿蒙 IAudioRenderer 接缝实现（OHAudio）。
//
// 队列策略与 Windows/Linux 共用 Audio/PcmBufferPolicy.{h,cpp}：本文件只负责
// 环形缓冲与"往 OHAudio 写回调里送数据"，阈值算术一律调那份共享代码。

#include "OhosAudioRenderer.h"

#include "Audio/PcmBufferPolicy.h"
#include "Logging.h"

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstring>
#include <format>
#include <mutex>
#include <stdexcept>
#include <vector>

#if defined(__has_include)
#  if __has_include(<ohaudio/native_audiostreambuilder.h>) && \
      __has_include(<ohaudio/native_audiorenderer.h>)
#    include <ohaudio/native_audiostreambuilder.h>
#    include <ohaudio/native_audiorenderer.h>
#    define IM_HAVE_OHOS_OHAUDIO 1
#  endif
#endif

#ifndef IM_HAVE_OHOS_OHAUDIO
#  define IM_HAVE_OHOS_OHAUDIO 0
#endif

namespace iPhoneMirror::audio {
namespace {

using detail::PcmIsBigEndian;
using detail::PcmIsFloat;
using detail::PcmIsNonInterleaved;
using detail::PcmIsSignedInteger;
using detail::LinearPcm;

// 采集路径给的是交错有符号 16 位小端 PCM。不是这个格式就明确拒绝，而不是
// 换个说法接着播（上游 Linux 版同样是抛 std::invalid_argument）。
void validate_format(const coremedia::AudioStreamBasicDescription& format) {
    if (format.format_id != LinearPcm) {
        throw std::invalid_argument(
            std::format("ohos audio: 只接受 'lpcm'，收到 format_id=0x{:08X}",
                format.format_id));
    }
    const std::uint32_t unsupported =
        PcmIsFloat | PcmIsBigEndian | PcmIsNonInterleaved;
    if ((format.format_flags & unsupported) != 0) {
        throw std::invalid_argument(
            std::format("ohos audio: 只接受交错有符号整数 PCM，format_flags=0x{:08X}",
                format.format_flags));
    }
    if ((format.format_flags & PcmIsSignedInteger) == 0) {
        throw std::invalid_argument("ohos audio: PCM 必须是有符号整数");
    }
    if (format.bits_per_channel != 16) {
        throw std::invalid_argument(
            std::format("ohos audio: 只接受 16 bit 样本，收到 {} bit",
                format.bits_per_channel));
    }
    if (format.channels_per_frame == 0 || format.bytes_per_frame == 0) {
        throw std::invalid_argument("ohos audio: 声道数/帧字节数不合法");
    }
}

// raop 交给我们的一块 PCM 有多大（**帧**数，不是字节）。
//
// 上游 raop_buffer.c 的 pcm_pkt_size 是 4 * N_SAMPLE(480) = 3840 字节，但那是
// **缓冲区容量上限**，不是"每包实际帧数"—— 实际帧数由 AAC-ELD 解码器给出，
// 而 FDK 文档明写 "512 or 480 for AAC-LD and AAC-ELD"（aacdecoder_lib.h:823），
// 取决于 ELD downscale 因子。
//
// ★ 2026-10-02 修正：此前这里写的是"无论采样率是 44100 还是 48000，一包永远是
//   480 帧"，那句是**我自己推的**（上游只给了容量，没有这个保证）。按它把回调
//   粒度写死 480，包长变 512 时就重新出现"每次回调差一截、尾部补零"的规律噪声
//   ——用户报的「声音是炸的」。现在包长以实测为准（observed_packet_frames_）。
constexpr std::size_t kPacketFrames = 480;
// 包长上限（AAC-ELD 512 帧 + 余量），用于按包折算门限，避免包长变大时起播/高水位
// 实际比标称短一截（够不着门槛 ⇒ 一直不起播 ⇒ 没声音）。
constexpr std::size_t kMaxPacketFrames = 576;
// 起播前预缓冲几个包。★ 2026-10-04（1.0.54）4→8：实测（欠载 362 次/26s）
// 43ms 的预缓冲在 Wi-Fi 抖动下远远不够，欠载就是"那次回调没数据、补静音"
// ——听感为断续/卡顿。8 包 @44.1kHz ≈ 87ms。
// ★ 2026-10-05（1.0.57）：门限口径整体换成**对照上游**（WasapiRenderer.cpp 的
// NetworkJitter 档：容量 500ms、起播 180ms、高水位 400ms）。此前是我们自己一轮轮
// 试出来的值（87ms / 208ms / 371ms），比上游浅一半 —— 而 AirPlay 音频是 UDP +
// 重传，缓冲浅就意味着抖动窗口一破就拿静音补包，听感就是断续和电音。
// 代价要说清：音频起播延迟从 ~90ms 涨到 ~190ms；上游没有做音视频同步（我们也
// 没有），这是用 ~100ms 的音画偏移换能听。
constexpr std::size_t kStartupPackets = 16;    // ≈ 190ms @44.1k（上游 180ms）
constexpr std::size_t kHighWaterPackets = 32;  // ≈ 380ms（上游 400ms）
// 环形缓冲容量（帧）。上游 500ms；@48kHz = 24000，取 24576（2 的幂便于取模）。
constexpr std::size_t kRingCapacityFrames = 24576;

class OhosAudioRenderer final : public IAudioRenderer {
public:
    OhosAudioRenderer(const coremedia::AudioStreamBasicDescription& format,
        bool playback_enabled, float volume)
        : format_(format), playback_enabled_(playback_enabled) {
        validate_format(format);
        const auto layout = detail::checked_wasapi_buffer_layout(format,
            /*minimum_capacity_frames=*/kRingCapacityFrames);
        if (!layout) {
            throw std::invalid_argument("ohos audio: 缓冲区布局计算失败");
        }
        layout_ = *layout;
        // 门限按**最大**包长折算：包长是 480 还是 512 由解码器决定，我们不能假定。
        // 用 480 折算而实际来 512，起播门限实际就比标称短一截（够不着 ⇒ 迟迟不
        // 起播 ⇒ 没声音）；用上限折算则两边都不会够不着，代价只是门限略保守
        // （多几 ms 预缓冲），这个方向的误差远小于前一个。
        thresholds_ = detail::wasapi_queue_thresholds(
            /*maximum_packet_frames=*/kMaxPacketFrames,
            layout_.capacity_frames,
            /*endpoint_buffer_frames=*/0,
            /*base_startup_frames=*/kMaxPacketFrames * kStartupPackets,
            /*base_high_water_frames=*/kMaxPacketFrames * kHighWaterPackets);
        ring_.assign(layout_.capacity_bytes, 0);
        if (playback_enabled_) {
            open_stream(volume);
        } else {
            volume_ = volume;
        }
    }

    ~OhosAudioRenderer() override { stop(); }

    void enqueue(std::span<const std::uint8_t> pcm) override {
        if (pcm.empty()) return;
        const std::size_t frames = pcm.size() / layout_.block_align;
        if (frames == 0) {
            std::scoped_lock lock(mutex_);
            ++dropped_frames_;
            return;
        }
        // ★ 记住实测包长：AAC-ELD 可能是 480 也可能是 512（见 observed_packet_frames_
        //   的说明）。建流发生在第一个包到达**之前**，那时只能先用 480 兜底；
        //   拿到真值后，下一次建流（格式变化会重建流）就能用对的粒度。
        //   这里只记不阻塞，且只取首包的确定值 —— 静音填充包长度相同，不必区分。
        if (observed_packet_frames_ == 0 && frames > 0) {
            observed_packet_frames_ = frames;
        }
        std::size_t dropped = 0;
        {
            std::scoped_lock lock(mutex_);
            const auto plan = detail::plan_wasapi_enqueue(
                queued_frames_, frames, layout_.capacity_frames, thresholds_);
            if (plan.drop_existing_frames != 0) {
                // 丢弃最旧的数据以给新数据腾位：与 WASAPI/PipeWire 后端同策略。
                read_frame_ = (read_frame_ + plan.drop_existing_frames) % layout_.capacity_frames;
                queued_frames_ -= plan.drop_existing_frames;
                dropped = plan.drop_existing_frames;
                dropped_frames_ += dropped;
            }
            if (plan.final_frames > layout_.capacity_frames) {
                // 单包就超过容量：只保留尾部，避免永久落后。
                const std::size_t keep = layout_.capacity_frames;
                const std::size_t skip = frames - keep;
                push_bytes(pcm.subspan(skip * layout_.block_align));
                queued_frames_ = keep;
                dropped_frames_ += skip;
            } else {
                push_bytes(pcm);
                queued_frames_ += frames;
            }
        }
        if (dropped != 0) {
            logging::write(logging::Level::Debug, "audio",
                std::format("ohos audio drop stale frames={}", dropped));
        }
        ready_.notify_all();
    }

    void set_enabled(bool enabled) noexcept override {
        playback_enabled_.store(enabled);
#if IM_HAVE_OHOS_OHAUDIO
        if (renderer_ != nullptr) {
            if (enabled) {
                OH_AudioRenderer_Start(renderer_);
            } else {
                OH_AudioRenderer_Pause(renderer_);
            }
        }
#endif
    }

    void set_volume(float volume) noexcept override {
        volume_.store(volume);
#if IM_HAVE_OHOS_OHAUDIO
        if (renderer_ != nullptr) {
            OH_AudioRenderer_SetVolume(renderer_, volume);
        }
#endif
    }

    void stop() noexcept override {
        {
            std::scoped_lock lock(mutex_);
            if (stopped_) return;
            stopped_ = true;
        }
        // 释放音频对象时必须放开 mutex_：OHAudio 的写回调会去抢同一把锁，
        // 持锁 Stop/Release 会和回调线程互等。
#if IM_HAVE_OHOS_OHAUDIO
        if (renderer_ != nullptr) {
            OH_AudioRenderer_Stop(renderer_);
            OH_AudioRenderer_Release(renderer_);
            renderer_ = nullptr;
        }
        if (builder_ != nullptr) {
            OH_AudioStreamBuilder_Destroy(builder_);
            builder_ = nullptr;
        }
#endif
    }

    [[nodiscard]] PlaybackStats stats() const override {
        std::scoped_lock lock(mutex_);
        PlaybackStats result;
        result.active = playback_enabled_.load() && !stopped_;
        result.queued_frames = queued_frames_;
        result.rendered_frames = rendered_frames_;
        result.dropped_frames = dropped_frames_;
        result.underruns = underruns_;
        return result;
    }

private:
    void push_bytes(std::span<const std::uint8_t> bytes) {
        std::size_t remaining = bytes.size();
        std::size_t offset = 0;
        while (remaining > 0) {
            const std::size_t write_frame = (read_frame_ + queued_frames_) % layout_.capacity_frames;
            const std::size_t contiguity = std::min(
                remaining, (layout_.capacity_frames - write_frame) * layout_.block_align);
            std::memcpy(ring_.data() + write_frame * layout_.block_align,
                bytes.data() + offset, contiguity);
            offset += contiguity;
            remaining -= contiguity;
            queued_frames_ += contiguity / layout_.block_align;
        }
    }

    // 供 OHAudio 写回调调用：把环形缓冲里的数据填进 audioData。
    //
    // ★ 2026-09-21 修（听感"很怪"的根因）：原实现把"起播门限"当成了**每次**
    //   回调的欠载判据 —— 只要 queued < startup_frames(44100Hz 下 = 3072 帧
    //   ≈ 70ms)，就把整块输出成静音，连手里已经排着的数据一起丢掉。
    //
    //   而这道门限在已知能工作的参考实现里只管一件事：**什么时候开始出声**
    //   （WasapiRenderer.cpp:417-428 的起播等待、:455-477 的重缓冲）。一旦起播，
    //   :382-408 就是"有多少拷多少、尾部补零"，从不因为没攒够门限而整块静音。
    //
    //   原样照搬的后果是数值上可推的：起播后队列在 [3072-块, 3072] 之间来回，
    //   于是"放一块 → 静音一块 → 放一块 → 静音一块"，静音占掉大约一半时间。
    //   听感就是断续、发闷的怪声，而不是"完全没声音"——正是用户报的形态。
    //
    //   现在门限只在**首次起播**拦一次（started_ 置位后不再复位）；此后一律
    //   "有多少放多少"，只有真正没数据的那些帧才补零。欠载仍然照实计数（就地
    //   在下面 `offset < bytes` 的分支里 +1），所以问题有没有复发看得见。
    std::size_t pull(std::uint8_t* destination, std::size_t bytes) {
        std::scoped_lock lock(mutex_);
        const std::size_t frames_wanted = bytes / layout_.block_align;
        if (frames_wanted == 0) return 0;
        if (!started_) {
            if (queued_frames_ < thresholds_.startup_frames) {
                // 起播前的预缓冲：这是设计内的等待，不是欠载，不计入 underruns_。
                std::memset(destination, 0, bytes);
                return 0;
            }
            started_ = true;
        }
        const std::size_t frames_to_copy = std::min(frames_wanted, queued_frames_);
        std::size_t remaining = frames_to_copy * layout_.block_align;
        std::size_t offset = 0;
        while (remaining > 0) {
            const std::size_t contiguity = std::min(remaining,
                (layout_.capacity_frames - read_frame_) * layout_.block_align);
            std::memcpy(destination + offset,
                ring_.data() + read_frame_ * layout_.block_align, contiguity);
            offset += contiguity;
            remaining -= contiguity;
            const std::size_t consumed_frames = contiguity / layout_.block_align;
            read_frame_ = (read_frame_ + consumed_frames) % layout_.capacity_frames;
            queued_frames_ -= consumed_frames;
            rendered_frames_ += consumed_frames;
        }
        if (offset < bytes) {
            // 尾部补静音：给调用方的 buffer 必须整块有效。
            // 只有这里才算欠载 —— 它是"确实没数据了"，与上面起播前的预缓冲不同。
            std::memset(destination + offset, 0, bytes - offset);
            ++underruns_;
        }
        return frames_to_copy;
    }

#if IM_HAVE_OHOS_OHAUDIO
    static std::int32_t OnWriteData(OH_AudioRenderer* renderer, void* user_data,
        void* audio_data, std::int32_t audio_data_size) {
        (void)renderer;
        auto* self = static_cast<OhosAudioRenderer*>(user_data);
        if (self == nullptr || audio_data == nullptr || audio_data_size <= 0) return 0;
        self->pull(static_cast<std::uint8_t*>(audio_data),
            static_cast<std::size_t>(audio_data_size));
        return 0;
    }

    static std::int32_t OnStreamEvent(OH_AudioRenderer*, void*, OH_AudioStream_Event) {
        return 0;
    }

    static std::int32_t OnInterruptEvent(OH_AudioRenderer*, void*,
        OH_AudioInterrupt_ForceType, OH_AudioInterrupt_Hint) {
        return 0;
    }

    static std::int32_t OnError(OH_AudioRenderer*, void*, OH_AudioStream_Result error) {
        // 出错只记账：音频失败不应该把视频预览一起带走。
        logging::write(logging::Level::Warning, "audio",
            std::format("ohos audio stream error={}", static_cast<int>(error)));
        return 0;
    }

    void open_stream(float volume) {
        if (OH_AudioStreamBuilder_Create(&builder_, AUDIOSTREAM_TYPE_RENDERER) !=
            AUDIOSTREAM_SUCCESS) {
            builder_ = nullptr;
            throw std::runtime_error("OH_AudioStreamBuilder_Create 失败");
        }
        OH_AudioStreamBuilder_SetSamplingRate(builder_,
            static_cast<std::int32_t>(format_.sample_rate));
        OH_AudioStreamBuilder_SetChannelCount(builder_,
            static_cast<std::int32_t>(format_.channels_per_frame));
        OH_AudioStreamBuilder_SetSampleFormat(builder_, AUDIOSTREAM_SAMPLE_S16LE);
        OH_AudioStreamBuilder_SetEncodingType(builder_, AUDIOSTREAM_ENCODING_TYPE_RAW);
        // 投屏音频要跟画面同步，用普通通路而不是低时延通路。
        OH_AudioStreamBuilder_SetLatencyMode(builder_, AUDIOSTREAM_LATENCY_MODE_NORMAL);
        OH_AudioStreamBuilder_SetRendererInfo(builder_, AUDIOSTREAM_USAGE_MUSIC);
        // ★ 让"取"和"喂"同拍：回调开口要多少帧，由我们自己定。不设的话 OHAudio 按
        //   自己的默认粒度开口（通常远大于一包），每回调都差一截、只能在尾部补
        //   静音 —— 那是有规律的可闻噪声，不是偶发欠载。
        //
        //   ★ 2026-10-02：AAC-ELD 的包长**不是恒定 480**，FDK 文档明写
        //   "512 or 480 for AAC-LD and AAC-ELD"（aacdecoder_lib.h:823），
        //   取决于 ELD downscale 因子。硬写 480 会在包长变 512 时重新制造
        //   "每次回调差一截、尾部补零"的规律噪声（用户报的「炸」）。
        //   这里取首次 enqueue 实测到的包长，并对 512 留余量；首包之前的建流
        //   阶段用 480 兜底（多数会话就是 480）。
        OH_AudioStreamBuilder_SetFrameSizeInCallback(builder_,
            static_cast<std::int32_t>(observed_packet_frames_ != 0
                ? observed_packet_frames_ : kPacketFrames));

        OH_AudioRenderer_Callbacks callbacks{};
        callbacks.OH_AudioRenderer_OnWriteData = &OhosAudioRenderer::OnWriteData;
        callbacks.OH_AudioRenderer_OnStreamEvent = &OhosAudioRenderer::OnStreamEvent;
        callbacks.OH_AudioRenderer_OnInterruptEvent = &OhosAudioRenderer::OnInterruptEvent;
        callbacks.OH_AudioRenderer_OnError = &OhosAudioRenderer::OnError;
        OH_AudioStreamBuilder_SetRendererCallback(builder_, callbacks, this);

        if (OH_AudioStreamBuilder_GenerateRenderer(builder_, &renderer_) !=
            AUDIOSTREAM_SUCCESS) {
            OH_AudioStreamBuilder_Destroy(builder_);
            builder_ = nullptr;
            renderer_ = nullptr;
            throw std::runtime_error("OH_AudioStreamBuilder_GenerateRenderer 失败");
        }
        volume_ = volume;
        OH_AudioRenderer_SetVolume(renderer_, volume);
        OH_AudioRenderer_Start(renderer_);

        // ── 把真值记进日志：这几个数决定了"声音为什么是现在这样" ────────
        // 请求的和实际拿到的常常不是一回事（设备有最小粒度、采样率可能被端点
        // 改），不回读就只能靠猜。诊断页读不到日志时，这几行也是定位的抓手。
        std::int32_t granted_frames = 0;
        std::int32_t granted_rate = 0;
        std::int32_t latency_ms = 0;
        // 三个回读都可能失败（接口版本/设备能力不支持），失败就记 -1 —— 宁可看到
        // 一个明确的 -1，也不要拿一个 0 当成"延迟为零"。
        if (OH_AudioRenderer_GetFrameSizeInCallback(renderer_, &granted_frames) !=
            AUDIOSTREAM_SUCCESS) {
            granted_frames = -1;
        }
        if (OH_AudioRenderer_GetSamplingRate(renderer_, &granted_rate) !=
            AUDIOSTREAM_SUCCESS) {
            granted_rate = -1;
        }
        // AUDIOSTREAM_LATENCY_TYPE_ALL = 软件 + 硬件全链路延迟（毫秒），@since 23。
        if (OH_AudioRenderer_GetLatency(renderer_, AUDIOSTREAM_LATENCY_TYPE_ALL,
                &latency_ms) != AUDIOSTREAM_SUCCESS) {
            latency_ms = -1;
        }
        logging::write(logging::Level::Info, "audio",
            std::format("ohos audio opened: 请求 {:.0f}Hz/{}ch 回调{}帧；"
                "实际 {:.0f}Hz 回调{}帧 端点延迟{}ms；"
                "起播门限{}帧 高水位{}帧 环容{}帧",
                format_.sample_rate, format_.channels_per_frame,
                (observed_packet_frames_ != 0 ? observed_packet_frames_ : kPacketFrames),
                static_cast<double>(granted_rate), granted_frames, latency_ms,
                thresholds_.startup_frames, thresholds_.high_water_frames,
                layout_.capacity_frames));
    }

    OH_AudioStreamBuilder* builder_{};
    OH_AudioRenderer* renderer_{};
#else
    void open_stream(float volume) {
        volume_ = volume;
        throw std::runtime_error(
            "该 SDK 未提供 OHAudio（ohaudio/native_audiorenderer.h）");
    }
#endif

    coremedia::AudioStreamBasicDescription format_{};
    detail::WasapiBufferLayout layout_{};
    detail::WasapiQueueThresholds thresholds_{};

    mutable std::mutex mutex_;
    std::condition_variable ready_;
    std::vector<std::uint8_t> ring_;
    std::size_t read_frame_{};
    std::size_t queued_frames_{};
    std::uint64_t rendered_frames_{};
    std::uint64_t dropped_frames_{};
    std::uint64_t underruns_{};
    // ★ 实际观测到的音频包帧数（首包为准）。AAC-ELD 可能是 480 也可能是 512
    //   （aacdecoder_lib.h:823），写死会把回调粒度设错。0 = 还没收到包。
    std::size_t observed_packet_frames_{};
    // 是否已经起播（见 pull() 的说明）：只用来决定"预缓冲门限还要不要拦"，
    // 一旦置位就不再复位 —— 复位它等于把"每块都要攒够 70ms"的毛病放回来。
    bool started_{};
    bool stopped_{};
    std::atomic<bool> playback_enabled_{false};
    std::atomic<float> volume_{1.0F};
};

} // namespace

std::unique_ptr<IAudioRenderer> make_ohos_audio_renderer(
    const coremedia::AudioStreamBasicDescription& format,
    bool playback_enabled, float volume) {
    return std::make_unique<OhosAudioRenderer>(format, playback_enabled, volume);
}

} // namespace iPhoneMirror::audio
