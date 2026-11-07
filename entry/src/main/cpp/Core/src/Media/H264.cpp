#include "Media/H264.h"

#include <limits>
#include <stdexcept>

namespace iPhoneMirror::h264 {
namespace {

std::uint32_t read_length(std::span<const std::uint8_t> bytes, std::uint8_t width) {
    std::uint32_t result{};
    for (std::uint8_t index = 0; index < width; ++index) result = (result << 8U) | bytes[index];
    return result;
}

template <typename Visitor>
void visit_nalus(std::span<const std::uint8_t> sample, std::uint8_t width, Visitor&& visitor) {
    if (width < 1 || width > 4) throw std::invalid_argument("AVCC length field must be 1..4 bytes");
    std::size_t offset{};
    while (offset < sample.size()) {
        if (sample.size() - offset < width) throw std::runtime_error("truncated AVCC NAL length");
        const auto length = read_length(sample.subspan(offset, width), width);
        offset += width;
        if (length == 0 || length > sample.size() - offset) throw std::runtime_error("invalid AVCC NAL length");
        visitor(sample.subspan(offset, length));
        offset += length;
    }
}

} // namespace

std::optional<SampleFormat> sample_format_from_sps(std::span<const std::uint8_t> sps) noexcept {
    try {
        if (sps.size() < 4 || (sps[0] & 31U) != 7) return std::nullopt;
        const auto profile = sps[1];
        if (profile != 100 && profile != 110 && profile != 122 && profile != 244 &&
            profile != 44 && profile != 83 && profile != 86 && profile != 118 &&
            profile != 128 && profile != 138 && profile != 139 && profile != 134 && profile != 135)
            return SampleFormat{};
        std::vector<std::uint8_t> rbsp;
        for (std::size_t i = 4; i < sps.size(); ++i) {
            if (sps[i] == 3 && i >= 2 && sps[i - 1] == 0 && sps[i - 2] == 0) continue;
            rbsp.push_back(sps[i]);
        }
        std::size_t position{};
        const auto bit = [&]() -> unsigned {
            if (position >= rbsp.size() * 8) throw std::runtime_error("truncated SPS");
            const auto value = (rbsp[position / 8] >> (7 - position % 8)) & 1U;
            ++position;
            return value;
        };
        const auto ue = [&]() -> unsigned {
            unsigned zeros{};
            while (!bit()) if (++zeros > 16) throw std::runtime_error("oversized SPS value");
            unsigned value = 1;
            for (unsigned n = 0; n < zeros; ++n) value = (value << 1U) | bit();
            return value - 1;
        };
        (void)ue(); // seq_parameter_set_id
        const auto chroma = ue();
        if (chroma > 3) return std::nullopt;
        if (chroma == 3) (void)bit(); // separate_colour_plane_flag
        const auto luma = ue(), color = ue();
        if (luma > 6 || color > 6) return std::nullopt;
        return SampleFormat{static_cast<std::uint8_t>(chroma),
            static_cast<std::uint8_t>(8 + luma), static_cast<std::uint8_t>(8 + color)};
    } catch (...) {
        return std::nullopt;
    }
}


std::vector<std::uint8_t> avcc_to_annex_b(std::span<const std::uint8_t> sample, std::uint8_t length_field_bytes) {
    std::vector<std::uint8_t> output;
    output.reserve(sample.size() + 32);
    visit_nalus(sample, length_field_bytes, [&output](std::span<const std::uint8_t> nalu) {
        output.insert(output.end(), {0, 0, 0, 1});
        output.insert(output.end(), nalu.begin(), nalu.end());
    });
    return output;
}

bool is_keyframe_avcc(std::span<const std::uint8_t> sample, std::uint8_t length_field_bytes) {
    bool keyframe{};
    visit_nalus(sample, length_field_bytes, [&keyframe](std::span<const std::uint8_t> nalu) {
        const auto type = nalu.front() & 0x1fU;
        if (type == 5) keyframe = true;
    });
    return keyframe;
}

} // namespace iPhoneMirror::h264

