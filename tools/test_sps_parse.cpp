// SPS 解析器独立测试（从 OhosVideoDecoder.cpp 同步复制的算法）。
// 测试向量由 tools/gen_sps_test_vectors.py 按 H.264 spec 7.3.2.1.1 精确构造，
// 覆盖：emulation prevention 转义、frame_cropping、竖屏、非 16 倍数显示尺寸。
// 编译：g++ -std=c++20 tools/test_sps_parse.cpp -o /tmp/test_sps && /tmp/test_sps
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <span>
#include <string>
#include <vector>

static int g_failures = 0;
#define CHECK(cond, msg) do { \
    if (cond) { std::printf("  PASS: %s\n", msg); } \
    else { std::printf("  FAIL: %s\n", msg); ++g_failures; } \
} while (0)

// ── 以下与 OhosVideoDecoder.cpp 保持一致 ──────────────────────────────
std::vector<std::uint8_t> unescape_rbsp(std::span<const std::uint8_t> ebsp) {
    std::vector<std::uint8_t> out;
    out.reserve(ebsp.size());
    for (std::size_t i = 0; i < ebsp.size(); ++i) {
        if (i + 2 < ebsp.size() && ebsp[i] == 0x00 && ebsp[i + 1] == 0x00 &&
            ebsp[i + 2] == 0x03) {
            out.push_back(0x00);
            out.push_back(0x00);
            i += 2;
        } else {
            out.push_back(ebsp[i]);
        }
    }
    return out;
}

class BitReader {
public:
    explicit BitReader(const std::uint8_t *data, std::size_t size)
        : data_(data), size_(size) {}
    std::uint32_t read_bits(int n) {
        std::uint32_t v = 0;
        for (int i = 0; i < n; ++i) {
            if (pos_ >= size_ * 8) return v;
            const std::uint32_t byte = data_[pos_ / 8];
            const std::uint32_t bit = (byte >> (7 - (pos_ % 8))) & 1;
            v = (v << 1) | bit;
            ++pos_;
        }
        return v;
    }
    std::uint32_t read_ue() {
        int zeros = 0;
        while (pos_ < size_ * 8) {
            const std::uint32_t byte = data_[pos_ / 8];
            if (((byte >> (7 - (pos_ % 8))) & 1) != 0) break;
            ++zeros;
            ++pos_;
        }
        if (pos_ < size_ * 8) ++pos_;
        if (zeros > 32) return 0;
        const std::uint32_t suffix = read_bits(zeros);
        return (1u << zeros) - 1u + suffix;
    }
    std::int32_t read_se() {
        const std::uint32_t k = read_ue();
        return (k & 1u) != 0 ? static_cast<std::int32_t>((k + 1) >> 1)
                             : -static_cast<std::int32_t>(k >> 1);
    }
private:
    const std::uint8_t *data_;
    const std::size_t size_;
    std::size_t pos_{0};
};

struct SpsSize {
    std::uint32_t width{0};
    std::uint32_t height{0};
    std::uint32_t display_width{0};
    std::uint32_t display_height{0};
    bool ok{false};
};

SpsSize ParseH264Sps(std::span<const std::uint8_t> annex_b) {
    SpsSize out{};
    std::size_t i = 0;
    while (i + 3 < annex_b.size()) {
        if (annex_b[i] == 0 && annex_b[i + 1] == 0) {
            std::size_t sc_len = 0;
            if (annex_b[i + 2] == 1) sc_len = 3;
            else if (i + 3 < annex_b.size() && annex_b[i + 2] == 0 && annex_b[i + 3] == 1) sc_len = 4;
            else { ++i; continue; }
            const std::size_t nalu_start = i + sc_len;
            if (nalu_start >= annex_b.size()) break;
            const std::uint8_t nal_type = annex_b[nalu_start] & 0x1F;
            if (nal_type != 7) { i = nalu_start; continue; }
            const std::vector<std::uint8_t> rbsp =
                unescape_rbsp(annex_b.subspan(nalu_start + 1));
            BitReader br(rbsp.data(), rbsp.size());
            const std::uint32_t profile_idc = br.read_bits(8);
            br.read_bits(8);
            br.read_bits(8);
            br.read_ue();
            std::uint32_t chroma_format_idc = 1;
            std::uint32_t chroma_array_type = 1;
            static constexpr std::uint32_t kHighProfiles[] = {
                100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135
            };
            bool is_high = false;
            for (auto p : kHighProfiles) if (p == profile_idc) is_high = true;
            if (!is_high && profile_idc != 66 && profile_idc != 77 &&
                profile_idc != 88) {
                return out;
            }
            if (is_high) {
                chroma_format_idc = br.read_ue();
                if (chroma_format_idc > 3) return out;
                if (chroma_format_idc == 3) {
                    if (br.read_bits(1) != 0) chroma_array_type = 0;
                    else chroma_array_type = 0;
                } else {
                    chroma_array_type = chroma_format_idc;
                }
                br.read_ue();
                br.read_ue();
                br.read_bits(1);
                if (br.read_bits(1) != 0) return out;
            }
            br.read_ue();
            const std::uint32_t pic_order_cnt_type = br.read_ue();
            if (pic_order_cnt_type == 0) {
                br.read_ue();
            } else if (pic_order_cnt_type == 1) {
                br.read_bits(1);
                br.read_se();
                br.read_se();
                const std::uint32_t cycle_len = br.read_ue();
                if (cycle_len > 255) return out;
                for (std::uint32_t k = 0; k < cycle_len; ++k) br.read_se();
            } else if (pic_order_cnt_type > 2) {
                return out;
            }
            br.read_ue();
            br.read_bits(1);
            const std::uint32_t pic_w_mbs = br.read_ue();
            const std::uint32_t pic_h_map = br.read_ue();
            const std::uint32_t frame_mbs_only = br.read_bits(1);
            if (!frame_mbs_only) br.read_bits(1);
            br.read_bits(1);
            out.width = (pic_w_mbs + 1) * 16;
            out.height = (pic_h_map + 1) * 16 * (frame_mbs_only ? 1u : 2u);
            out.display_width = out.width;
            out.display_height = out.height;
            if (br.read_bits(1) != 0) {
                const std::uint32_t crop_left = br.read_ue();
                const std::uint32_t crop_right = br.read_ue();
                const std::uint32_t crop_top = br.read_ue();
                const std::uint32_t crop_bottom = br.read_ue();
                std::uint32_t sub_w = 1;
                std::uint32_t sub_h = 1;
                if (chroma_array_type == 1) { sub_w = 2; sub_h = 2; }
                else if (chroma_array_type == 2) { sub_w = 2; sub_h = 1; }
                const std::uint32_t crop_unit_x =
                    chroma_array_type == 0 ? 1u : sub_w;
                const std::uint32_t crop_unit_y = chroma_array_type == 0
                    ? (2u - frame_mbs_only)
                    : sub_h * (2u - frame_mbs_only);
                const std::uint32_t cut_w = (crop_left + crop_right) * crop_unit_x;
                const std::uint32_t cut_h = (crop_top + crop_bottom) * crop_unit_y;
                if (out.width > cut_w) out.display_width = out.width - cut_w;
                if (out.height > cut_h) out.display_height = out.height - cut_h;
            }
            if (out.width == 0 || out.height == 0 || out.width % 16 != 0 ||
                out.height % 16 != 0 || out.width > 8192 || out.height > 8192 ||
                out.display_width == 0 || out.display_height == 0) {
                return out;
            }
            out.ok = true;
            return out;
        } else {
            ++i;
        }
    }
    return out;
}
// ── 以上与 OhosVideoDecoder.cpp 保持一致 ──────────────────────────────

static std::vector<std::uint8_t> HexToBytes(const char *hex) {
    std::vector<std::uint8_t> out;
    const std::size_t n = std::strlen(hex);
    for (std::size_t i = 0; i + 1 < n; i += 2) {
        out.push_back(static_cast<std::uint8_t>(std::strtoul(std::string(hex + i, 2).c_str(), nullptr, 16)));
    }
    return out;
}

int main() {
    std::printf("== unescape_rbsp 单元测试 ==\n");
    {
        const std::vector<std::uint8_t> in = {0x00, 0x00, 0x03, 0x05, 0x00, 0x00, 0x03, 0x01, 0xFF};
        const auto out = unescape_rbsp(in);
        const std::vector<std::uint8_t> expect = {0x00, 0x00, 0x05, 0x00, 0x00, 0x01, 0xFF};
        CHECK(out == expect, "00 00 03 -> 00 00（连续两处 + 尾字节保留）");
        const std::vector<std::uint8_t> in2 = {0x00, 0x00, 0x01};
        const auto out2 = unescape_rbsp(in2);
        CHECK(out2 == in2, "00 00 01（起始码形态）不被误剥");
    }

    // 向量 A：1920×1088 编码、crop right/bottom 各 2 单位（4:2:0 → 4px）→ 显示 1916×1084。
    // 由 gen_sps_test_vectors.py 生成，escape 后含 4 个 00 00 03 转义字节。
    std::printf("== SPS A：1080p 带 crop + emulation prevention ==\n");
    {
        const auto bytes = HexToBytes("000000016742c028965603c0113dda");
        const SpsSize s = ParseH264Sps(bytes);
        std::printf("  enc=%ux%u disp=%ux%u ok=%d\n", s.width, s.height,
            s.display_width, s.display_height, s.ok ? 1 : 0);
        CHECK(s.ok, "解析成功");
        CHECK(s.width == 1920 && s.height == 1088, "编码尺寸 1920×1088（1088=16 对齐）");
        CHECK(s.display_width == 1916 && s.display_height == 1084,
            "crop 后显示 1916×1084");
    }

    // 向量 B：896×1920 竖屏无 crop（iPhone 竖屏 mirroring 常见形态）。
    std::printf("== SPS B：896×1920 竖屏无 crop ==\n");
    {
        const auto bytes = HexToBytes("000000016742c01e9656070078c8");
        const SpsSize s = ParseH264Sps(bytes);
        std::printf("  enc=%ux%u disp=%ux%u ok=%d\n", s.width, s.height,
            s.display_width, s.display_height, s.ok ? 1 : 0);
        CHECK(s.ok, "解析成功");
        CHECK(s.width == 896 && s.height == 1920, "编码尺寸 896×1920");
        CHECK(s.display_width == 896 && s.display_height == 1920, "无 crop，显示=编码");
    }

    // 向量 C：非法位流（纯垃圾）→ 必须失败回退，不能给出假尺寸。
    std::printf("== SPS C：垃圾数据安全回退 ==\n");
    {
        const auto bytes = HexToBytes("0000000167" "deadbeefcafebabe0102030405");
        const SpsSize s = ParseH264Sps(bytes);
        std::printf("  enc=%ux%u ok=%d\n", s.width, s.height, s.ok ? 1 : 0);
        CHECK(!s.ok, "垃圾输入解析失败（回退提示值）");
    }

    if (g_failures == 0) {
        std::printf("\nALL PASS\n");
        return 0;
    }
    std::printf("\n%d FAILURES\n", g_failures);
    return 1;
}
