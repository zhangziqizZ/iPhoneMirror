// SPDX-License-Identifier: GPL-3.0-only
//
// Platform-neutral decoder seam for the capture session. The Windows Media
// Foundation decoder and the future Linux FFmpeg decoder both implement this
// interface, and CaptureSession drives whichever one the platform build
// selected through Media/ActiveVideoDecoder.h. The method set is exactly the
// public surface MediaFoundationVideoDecoder already had, so inheriting it is
// a source-level formality: no call site changes its behaviour.

#pragma once

#include "Media/VideoFormats.h"

#include <cstdint>
#include <span>
#include <string_view>
#include <vector>

namespace iPhoneMirror::media {

class IVideoDecoder {
public:
    virtual ~IVideoDecoder() = default;

    virtual void configure(const coremedia::FormatDescription& format,
        std::uint32_t fps_numerator = 60, std::uint32_t fps_denominator = 1) = 0;
    [[nodiscard]] virtual std::vector<DecodedFrame> decode(
        std::span<const std::uint8_t> length_prefixed_sample,
        std::int64_t timestamp_100ns, std::int64_t duration_100ns) = 0;
    // 直接接收 Annex-B 样本（含 00 00 00 01 起始码的 NAL）的解码入口，
    // 跳过 AVCC 长度前缀转换。默认实现为空（平台不支持时），OHOS 的
    // OhosVideoDecoder 真正支持。AirPlay 镜像的 raop 回调给的正是 Annex-B。
    [[nodiscard]] virtual std::vector<DecodedFrame> decode_annex_b(
        std::span<const std::uint8_t> annex_b_sample, std::int64_t timestamp_100ns) {
        (void)annex_b_sample;
        (void)timestamp_100ns;
        return {};
    }
    // 直接用 Annex-B 形式的参数集（SPS/PPS，含起始码）配置解码器。
    // width/height 通常为提示值，真实分辨率由解码器后续上报（OnStreamChanged）。
    // 默认实现为空（平台不支持时）。
    virtual void configure_annex_b(std::span<const std::uint8_t> annex_b_codec_config,
        std::uint32_t width, std::uint32_t height, bool hevc = false) {
        (void)annex_b_codec_config;
        (void)width;
        (void)height;
        (void)hevc;
    }
    [[nodiscard]] virtual std::vector<DecodedFrame> drain() = 0;
    virtual void flush() = 0;

    [[nodiscard]] virtual DecoderPreference preference() const noexcept = 0;
    [[nodiscard]] virtual std::string_view selected_decoder_name() const noexcept = 0;
    [[nodiscard]] virtual DecoderAcceleration decoder_acceleration() const noexcept = 0;
    [[nodiscard]] virtual bool selected_decoder_is_hardware() const noexcept = 0;
    [[nodiscard]] virtual PixelFormat output_pixel_format() const noexcept = 0;
};

} // namespace iPhoneMirror::media
