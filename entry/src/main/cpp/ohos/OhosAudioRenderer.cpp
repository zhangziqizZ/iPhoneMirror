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

class OhosAudioRenderer final : public IAudioRenderer {
public:
    OhosAudioRenderer(const coremedia::AudioStreamBasicDescription& format,
        bool playback_enabled, float volume)
        : format_(format), playback_enabled_(playback_enabled) {
        validate_format(format);
        const auto layout = detail::checked_wasapi_buffer_layout(format,
            /*minimum_capacity_frames=*/4096);
        if (!layout) {
            throw std::invalid_argument("ohos audio: 缓冲区布局计算失败");
        }
        layout_ = *layout;
        thresholds_ = detail::wasapi_queue_thresholds(
            /*maximum_packet_frames=*/layout_.capacity_frames / 4,
            layout_.capacity_frames);
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
