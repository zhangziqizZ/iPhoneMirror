#pragma once

#include <cstdint>
#include <optional>
#include <span>
#include <vector>

namespace iPhoneMirror::h264 {

struct SampleFormat {
    std::uint8_t chroma_format{1};
    std::uint8_t bit_depth_luma{8};
    std::uint8_t bit_depth_chroma{8};
};
[[nodiscard]] std::optional<SampleFormat> sample_format_from_sps(
    std::span<const std::uint8_t> sps) noexcept;

// QuickTime CMSampleBuffer block data is AVCC: each NAL unit has a big-endian
// length prefix. Media Foundation/streaming outputs commonly accept Annex-B.
[[nodiscard]] std::vector<std::uint8_t> avcc_to_annex_b(
    std::span<const std::uint8_t> sample,
    std::uint8_t length_field_bytes = 4);

[[nodiscard]] bool is_keyframe_avcc(
    std::span<const std::uint8_t> sample,
    std::uint8_t length_field_bytes = 4);

} // namespace iPhoneMirror::h264

