// SPDX-License-Identifier: GPL-3.0-only
//
// 鸿蒙 IVideoDecoder 接缝实现（AVCodec 的 OH_VideoDecoder）。
//
// 与上游两处关键语义对齐：
//  1) 输入是 length-prefixed（AVCC）样本，OH_VideoDecoder 要的是 Annex-B，
//     因此这里按 format.nalu_length_size 逐 NALU 换起始码；
//  2) 接缝是同步的，OH_VideoDecoder 是回调式的，用输入/输出队列把两边桥起来。
//
// 输出只接受 NV12。AVCodec 给出的像素格式不是 NV12 时**明确失败**，不把别的
// 格式冒充"半平面 Y + 交错 UV"——上游 DecodedFrame 的约定就是 NV12/P010。

#include "OhosVideoDecoder.h"

#include "Logging.h"
#include "Media/VideoFormats.h"

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <format>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

#if defined(__has_include)
#  if __has_include(<multimedia/player_framework/native_avcodec_videodecoder.h>)
#    include <multimedia/player_framework/native_avcodec_videodecoder.h>
#    include <multimedia/player_framework/native_avcodec_base.h>
#    include <multimedia/player_framework/native_avcapability.h>
#    include <multimedia/player_framework/native_avbuffer.h>
#    include <multimedia/player_framework/native_avformat.h>
#    define IM_HAVE_OHOS_AVCODEC 1
#  endif
#endif

#ifndef IM_HAVE_OHOS_AVCODEC
#  define IM_HAVE_OHOS_AVCODEC 0
#endif

// 鸿蒙 OH_VideoDecoder::OnError 累计触发次数（at file scope, NOT inside the
// OhosVideoDecoder class definition below — static methods defined inside the
// class body can't see names declared later in the same TU, and putting this
// above the class avoids that footgun）。
namespace {
// 解码链诊断（导出给 UI 看）：下一步能精确定位断点。
//   pushed_inputs           — 已成功调用 OH_VideoDecoder_PushInputBuffer 的次数
//   output_callbacks        — OnNewOutputBuffer 被调用的次数
//   output_with_pixels      — 其中解码成功、像素非空的次数
//   output_no_pixels        — 其中 pixels 为空的次数（要么 EOS、要么 attr.size 太小、
//                              要么宽高未确定）
//   output_too_small        — pixels 空的子集：attr.size < checked_nv12_buffer_size(w,h)
//   last_output_attr_size     — 最近一次 OnNewOutputBuffer 的 attr.size（字节）
//   last_output_width/height— 最近一次 OnNewOutputBuffer 用的 width/height
//   last_config_width/height— 最近一次 Configure 用的 width/height（create_locked 写入）
//   last_onstream_width/height—最近一次 OnStreamChanged 上报的 width/height（0 = 没回调过）
struct DecoderDiag {
    std::atomic<std::uint64_t> pushed_inputs{0};
    std::atomic<std::uint64_t> output_callbacks{0};
    std::atomic<std::uint64_t> output_with_pixels{0};
    std::atomic<std::uint64_t> output_no_pixels{0};
    std::atomic<std::uint64_t> output_too_small{0};
    std::atomic<std::uint64_t> input_too_large{0};   // 输入缓冲容量不够而整帧丢弃
    std::atomic<std::uint32_t> sps_parse_failures{0}; // SPS 解析失败次数（回退提示值）
    std::atomic<std::int32_t> last_output_attr_size{0};
    std::atomic<std::uint32_t> last_output_width{0};
    std::atomic<std::uint32_t> last_output_height{0};
    std::atomic<std::uint32_t> last_config_width{0};
    std::atomic<std::uint32_t> last_config_height{0};
    std::atomic<std::uint32_t> last_sps_enc_width{0};   // SPS 解析：编码宽（crop 前）
    std::atomic<std::uint32_t> last_sps_enc_height{0};
    std::atomic<std::uint32_t> last_sps_disp_width{0};  // SPS 解析：显示宽（crop 后）
    std::atomic<std::uint32_t> last_sps_disp_height{0};
    std::atomic<std::uint32_t> last_onstream_width{0};
    std::atomic<std::uint32_t> last_onstream_height{0};
    std::atomic<std::uint32_t> first_input_b0_3{0};   // 首个推入帧的前 4 字节（大端打包）
    std::atomic<std::uint32_t> first_input_b4_7{0};   // 首个推入帧的第 5-8 字节
    std::atomic<bool> first_input_recorded{false};
    std::atomic<std::uint32_t> strategy{0};           // 当前解码策略（0..3，见 DecoderStrategy）
    std::atomic<std::uint32_t> strategy_switches{0};  // 自动切换次数
    // ── 喂帧方式诊断（2026-09-19 四档全挂后新增）───────────────────────────
    // 上面所有字段都指向"解码器不吐输出"。四档（硬/软 × 编码/显示尺寸）全试完
    // 仍 callback=0，说明根因不在宽高口径，而在四档**共用**的喂帧方式本身。
    // 这三个计数把喂帧方式的三个可疑点分别量化：
    std::atomic<std::uint64_t> idr_frames{0};         // 扫描识别为 IDR（nal_type=5）的输入帧数
    std::atomic<std::uint64_t> sync_flagged{0};       // 实际标了 SYNC_FRAME 的帧数
    std::atomic<std::uint64_t> inband_param_sets{0};  // 在帧前拼接 SPS/PPS 的次数
    std::atomic<std::uint64_t> push_failures{0};      // PushInputBuffer 返回非 AV_ERR_OK 的次数
    std::atomic<std::int32_t> last_push_error{0};     // 最近一次 push 失败的错误码（AV_AVErrCode）
    std::atomic<std::uint64_t> setattr_failures{0};   // OH_AVBuffer_SetBufferAttr 失败次数
    std::atomic<std::int32_t> last_input_size{0};     // 最近一次实际交给解码器的字节数（含 in-band）
    std::atomic<std::int32_t> input_capacity{0};      // 解码器分配的输入缓冲容量（首次观测值）
    // ── 参数集本体诊断（2026-10-02 加）────────────────────────────────────
    // 之前只看得到"推给解码器的第一帧前 8 字节"，而那 8 字节是「参数集 + 首帧」
    // 拼好的结果，看不出**参数集本身**长什么样。而这次黑屏的根离线里最要紧的
    // 一格恰恰是它：00 00 00 01 67… = SPS 开头（正常），00 00 00 01 28… = PPS
    // 开头（SPS 缺席，解码器永远解不出画面）。所以单独把 Configure 用的那段
    // Codec Config 的头记下来，和 first_input_* 分开看。
    std::atomic<std::uint32_t> config_head_b0_3{0};   // 参数集前 4 字节（大端打包）
    std::atomic<std::uint32_t> config_head_b4_7{0};   // 参数集第 5-8 字节
    std::atomic<std::uint64_t> configures{0};         // configure_annex_b 被调用的次数
};
// 解码器组件名（CreateByName 用的名字）。原子存不了字符串，用互斥锁保护的
// 全局串——只在 create 时写、snapshot 时读，竞争概率可忽略。
std::mutex g_decoder_name_mutex;
std::string g_decoder_name;
DecoderDiag &Diag() {
    static DecoderDiag d;
    return d;
}
std::atomic<std::uint64_t> g_video_decoder_error_total{0};
}

namespace iPhoneMirror::media {
namespace {

// AVCC → Annex-B。上游样本是「每个 NALU 前置 nalu_length_size 字节长度」。
std::vector<std::uint8_t> to_annex_b(std::span<const std::uint8_t> sample,
    std::uint8_t length_size) {
    std::vector<std::uint8_t> output;
    output.reserve(sample.size() + 16);
    std::size_t offset = 0;
    const std::size_t width = length_size == 0 ? 4 : length_size;
    while (offset + width <= sample.size()) {
        std::uint32_t length = 0;
        for (std::size_t index = 0; index < width; ++index) {
            length = (length << 8) | sample[offset + index];
        }
        offset += width;
        if (length == 0) continue;
        if (offset + length > sample.size()) break;
        output.push_back(0x00);
        output.push_back(0x00);
        output.push_back(0x00);
        output.push_back(0x01);
        output.insert(output.end(), sample.begin() + static_cast<std::ptrdiff_t>(offset),
            sample.begin() + static_cast<std::ptrdiff_t>(offset + length));
        offset += length;
    }
    return output;
}

// H.264 SPS 解析（最小版）：从 Annex-B 字节里找 NAL type=7（SPS），按
// 7.3.2.1.1 / Annex E 走 exp-Golomb 解码，取真实 width/height。
// 失败返回 {0, 0}，调用方应回退到提示值。
//
// 实现要点：
//   * 只支持 profile_idc ∈ {66(Baseline), 77(Main), 100(High)} 及其子集；
//     这之外（含 110/122/244/44/83/86/118/128/138/139/134/135）走 chroma_format_idc
//     分支，**只**把 BitDepthLuma/Chroma + scaling_matrix 部分按"全跳过"处理。
//   * Annex-B 字节流可能含 00 00 00 01 或 00 00 01 起始码；本解析器兼容 3/4 字节。
//   * 不解 scaling_list（iPhone 投屏的 SPS 里通常没有），遇 scaling_matrix_present
//     就返错回退。
struct SpsSize {
    std::uint32_t width{0};          // 编码宽（16 对齐，crop 前）
    std::uint32_t height{0};         // 编码高（crop 前）
    std::uint32_t display_width{0};  // crop 后显示宽 —— Configure 应该用的值
    std::uint32_t display_height{0}; // crop 后显示高
    bool ok{false};
};

// 剥 emulation prevention bytes：RBSP 编码会在字节流里把 00 00 00/01/02/03
// 转义成 00 00 03 xx，解码前必须把"00 00 03"还原成"00 00"。
// iPhone 投屏的 SPS 里这个序列非常常见（1080p/竖屏分辨率的 crop 字段附近
// 几乎必出现）；不剥的话 exp-Golomb 位流从这里开始全部错位，解析出的宽高
// 是垃圾值——Configure 拿垃圾值配置硬件解码器，结果是"推帧无输出无错误"。
std::vector<std::uint8_t> unescape_rbsp(std::span<const std::uint8_t> ebsp) {
    std::vector<std::uint8_t> out;
    out.reserve(ebsp.size());
    for (std::size_t i = 0; i < ebsp.size(); ++i) {
        if (i + 2 < ebsp.size() && ebsp[i] == 0x00 && ebsp[i + 1] == 0x00 &&
            ebsp[i + 2] == 0x03) {
            out.push_back(0x00);
            out.push_back(0x00);
            i += 2; // 跳过转义字节 03，后续循环再消费真正的数据字节
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
    // u(n): 读 n 位
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
    // ue(v): unsigned exp-Golomb。
    // 编码规则：M = ceil(log2(codeNum+1))，M-1 个 0 + 1 (end marker) + M-1 bits info
    // 解码时先数前导 0 数 N，遇到 1 后 N 位再读 0 bits 作为 info。
    // value = 2^N - 1 + info。
    std::uint32_t read_ue() {
        int zeros = 0;
        while (pos_ < size_ * 8) {
            const std::uint32_t byte = data_[pos_ / 8];
            if (((byte >> (7 - (pos_ % 8))) & 1) != 0) break;
            ++zeros;
            ++pos_;
        }
        // 跳过 end marker（"1"）。这里必 +1：end marker 永远存在，包括 zeros=0 时
        // 也要消费 1 bit，否则连续 ue=0 会全部读到同一个 bit 上。
        if (pos_ < size_ * 8) ++pos_;
        if (zeros > 32) return 0;
        const std::uint32_t suffix = read_bits(zeros);
        return (1u << zeros) - 1u + suffix;
    }
    // se(v): signed exp-Golomb。码字结构与 ue 相同，值 = 映射表
    // k → k 为奇数取 (k+1)/2 取负、k 为偶数取 k/2。POC 偏移等有符号字段必用；
    // 用 read_ue 读 se 会把 -1/0/1 全读成 0/1/2（位流位置不偏，但值是错的）。
    std::int32_t read_se() {
        const std::uint32_t k = read_ue();
        return (k & 1u) != 0 ? static_cast<std::int32_t>((k + 1) >> 1)
                             : -static_cast<std::int32_t>(k >> 1);
    }
    std::size_t pos() const { return pos_; }
private:
    const std::uint8_t *data_;
    const std::size_t size_;
    std::size_t pos_{0};
};

SpsSize ParseH264Sps(std::span<const std::uint8_t> annex_b) {
    SpsSize out{};
    // 找 NAL type=7（SPS）的起始位置：跳过起始码后第一字节 & 0x1F == 7
    std::size_t i = 0;
    while (i + 3 < annex_b.size()) {
        // 找 00 00 01 起始码（也兼容 00 00 00 01）
        if (annex_b[i] == 0 && annex_b[i + 1] == 0) {
            std::size_t sc_len = 0;
            if (annex_b[i + 2] == 1) sc_len = 3;
            else if (i + 3 < annex_b.size() && annex_b[i + 2] == 0 && annex_b[i + 3] == 1) sc_len = 4;
            else { ++i; continue; }
            const std::size_t nalu_start = i + sc_len;
            if (nalu_start >= annex_b.size()) break;
            const std::uint8_t nal_type = annex_b[nalu_start] & 0x1F;
            if (nal_type != 7) {
                i = nalu_start; // 跳到这个 NALU 之后继续找下一个
                continue;
            }
            // 关键：先剥 emulation prevention 再交给位读取器（见 unescape_rbsp）。
            const std::vector<std::uint8_t> rbsp =
                unescape_rbsp(annex_b.subspan(nalu_start + 1));
            BitReader br(rbsp.data(), rbsp.size());
            const std::uint32_t profile_idc = br.read_bits(8);
            br.read_bits(8); // constraints
            br.read_bits(8); // level_idc
            br.read_ue();    // seq_parameter_set_id
            std::uint32_t chroma_format_idc = 1; // 非 high profile 默认 4:2:0
            std::uint32_t chroma_array_type = 1;
            static constexpr std::uint32_t kHighProfiles[] = {
                100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135
            };
            bool is_high = false;
            for (auto p : kHighProfiles) if (p == profile_idc) is_high = true;
            // profile 白名单：合法值只有 Baseline/Main/Extended(66/77/88) 与
            // high 系。垃圾位流常解出 200+ 的怪 profile —— 直接判失败回退，
            // 不给"看起来像尺寸"的假结果。
            if (!is_high && profile_idc != 66 && profile_idc != 77 &&
                profile_idc != 88) {
                return out;
            }
            if (is_high) {
                chroma_format_idc = br.read_ue();
                if (chroma_format_idc > 3) return out; // 非法，放弃
                if (chroma_format_idc == 3) {
                    if (br.read_bits(1) != 0) chroma_array_type = 0; // separate_colour_plane
                    else chroma_array_type = 0;
                } else {
                    chroma_array_type = chroma_format_idc;
                }
                br.read_ue(); // bit_depth_luma_minus8
                br.read_ue(); // bit_depth_chroma_minus8
                br.read_bits(1); // qpprime_y_zero_transform_bypass
                if (br.read_bits(1) != 0) return out; // scaling_matrix：不解，安全回退
            }
            br.read_ue(); // log2_max_frame_num_minus4
            const std::uint32_t pic_order_cnt_type = br.read_ue();
            if (pic_order_cnt_type == 0) {
                br.read_ue();
            } else if (pic_order_cnt_type == 1) {
                br.read_bits(1); // delta_pic_order_always_zero
                br.read_se();    // offset_for_non_ref_pic
                br.read_se();    // offset_for_top_to_bottom_field
                const std::uint32_t cycle_len = br.read_ue();
                if (cycle_len > 255) return out; // 防御：正常流不会有这种 SPS
                for (std::uint32_t k = 0; k < cycle_len; ++k) br.read_se();
            } else if (pic_order_cnt_type > 2) {
                return out; // 非法
            }
            br.read_ue(); // max_num_ref_frames
            br.read_bits(1); // gaps_in_frame_num_allowed
            const std::uint32_t pic_w_mbs = br.read_ue();
            const std::uint32_t pic_h_map = br.read_ue();
            const std::uint32_t frame_mbs_only = br.read_bits(1);
            if (!frame_mbs_only) br.read_bits(1); // mb_adaptive_frame_field
            br.read_bits(1); // direct_8x8_inference
            out.width = (pic_w_mbs + 1) * 16;
            out.height = (pic_h_map + 1) * 16 * (frame_mbs_only ? 1u : 2u);
            out.display_width = out.width;
            out.display_height = out.height;
            // frame_cropping（Annex E）：显示尺寸 = 编码尺寸 - crop。OHOS/OMX
            // 生态的解码器 Configure 期待的是**显示**宽高（解码器内部自己做
            // 对齐与 crop），配编码尺寸在部分平台会与码流 SPS 校验不一致。
            if (br.read_bits(1) != 0) { // frame_cropping_flag
                const std::uint32_t crop_left = br.read_ue();
                const std::uint32_t crop_right = br.read_ue();
                const std::uint32_t crop_top = br.read_ue();
                const std::uint32_t crop_bottom = br.read_ue();
                // SubWidthC/SubHeightC 按 ChromaArrayType（7.4.2.1.1）：
                //   0(mono/独立平面) 1/1 · 1(4:2:0) 2/2 · 2(4:2:2) 2/1 · 3(4:4:4) 1/1
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
            // sanity：编码尺寸必是 16 的倍数、显示不超过编码、分辨率有上界。
            if (out.width == 0 || out.height == 0 || out.width % 16 != 0 ||
                out.height % 16 != 0 || out.width > 8192 || out.height > 8192 ||
                out.display_width == 0 || out.display_height == 0) {
                return out; // ok=false，调用方回退提示值
            }
            out.ok = true;
            return out;
        } else {
            ++i;
        }
    }
    return out;
}

// 拼 Annex-B 形式的参数集，作为 OH_MD_KEY_CODEC_CONFIG 喂给解码器。
//
// 为什么必须喂：iPhone 送的是 AVCC，SPS/PPS(/VPS) 放在 avcC 也就是
// decoder_configuration_record 里，样本流本身未必再带一遍。而 OH_VideoDecoder
// 只认 Annex-B，to_annex_b() 转换的只是样本里的 NALU——参数集不在样本里时，
// 解码器拿不到编码参数，结果不是"画质差一点"，而是**一帧都解不出来**。
//
// 顺序与 Annex-B 约定一致：VPS（仅 HEVC）→ SPS → PPS。
std::vector<std::uint8_t> build_codec_config(
    const coremedia::FormatDescription& format) {
    const auto append = [](std::vector<std::uint8_t>& target,
                             const std::vector<std::uint8_t>& nal) {
        if (nal.empty()) return;
        target.push_back(0x00);
        target.push_back(0x00);
        target.push_back(0x00);
        target.push_back(0x01);
        target.insert(target.end(), nal.begin(), nal.end());
    };
    std::vector<std::uint8_t> config;
    for (const auto& vps : format.video_parameter_sets) append(config, vps);
    for (const auto& sps : format.sequence_parameter_sets) append(config, sps);
    for (const auto& pps : format.picture_parameter_sets) append(config, pps);
    return config;
}

// 在 Annex-B 码流里找是否存在指定 nal_unit_type 的 NALU。
//
// H.264 关心的是 1（非 IDR slice）与 5（IDR slice）：raop 送来的 mirror 帧里
// **不带参数集**（SPS/PPS 走 codec config），但每一帧必然带一个 slice。
//   * 扫到 5 ⇒ 这是关键帧 ⇒ 输入缓冲必须标 AVCODEC_BUFFER_FLAGS_SYNC_FRAME。
//     之前一律标 NONE，解码器有可能一直在等"标了同步帧的输入"才肯吐输出——
//     这恰好解释「四档策略全挂、push>0 而 callback=0、OnError=0」的形态。
//   * 扫到 1 ⇒ 普通 P 帧，不标 SYNC_FRAME（标错会让解码器把它当随机访问点，
//     造成花屏/参考链错乱）。
bool annex_b_has_nal_type(std::span<const std::uint8_t> data, std::uint8_t want_type) {
    std::size_t i = 0;
    while (i + 3 < data.size()) {
        if (data[i] != 0 || data[i + 1] != 0) {
            ++i;
            continue;
        }
        std::size_t sc_len = 0;
        if (data[i + 2] == 1) {
            sc_len = 3;
        } else if (i + 4 < data.size() && data[i + 2] == 0 && data[i + 3] == 1) {
            sc_len = 4;
        } else {
            ++i;
            continue;
        }
        const std::size_t nalu = i + sc_len;
        if (nalu >= data.size()) break;
        if ((data[nalu] & 0x1F) == want_type) return true;
        i = nalu; // 跳到 NALU 头之后，继续找下一个起始码
    }
    return false;
}

} // namespace

#if IM_HAVE_OHOS_AVCODEC

class OhosVideoDecoder final : public IVideoDecoder {
public:
    explicit OhosVideoDecoder(DecoderPreference preference)
        : preference_(preference) {}

    ~OhosVideoDecoder() override {
        {
            std::scoped_lock lock(mutex_);
            stopping_ = true;
        }
        // 回调可能正阻塞在 mutex_ 上，先置停止位再释放编解码器。
        if (codec_ != nullptr) {
            OH_VideoDecoder_Stop(codec_);
            OH_VideoDecoder_Destroy(codec_);
            codec_ = nullptr;
        }
        format_ = {};
    }

    void configure(const coremedia::FormatDescription& format,
        std::uint32_t fps_numerator = 60,
        std::uint32_t fps_denominator = 1) override {
        std::scoped_lock lock(mutex_);
        format_ = format;
        fps_numerator_ = fps_numerator == 0 ? 60 : fps_numerator;
        fps_denominator_ = fps_denominator == 0 ? 1 : fps_denominator;
        ++generation_;
        create_locked();
    }

    // 关键：必须在锁内。pump_input_locked 读 pending_input_ / input_buffer_，
    // 之前写在锁外是 race —— 锁内调用因为 std::mutex 不可重入而看似会死锁，
    // 但 OnNeedInputBuffer 回调也持同一把锁调 pump_input_locked，
    // 所以**只有**「解码器已就绪 + 有空闲 input_buffer」时这条路径才会真正
    // 走到 push —— 首次 push 时 have_input_buffer_=false，pump 直接返回。
    std::vector<DecodedFrame> decode_common(std::vector<std::uint8_t> bytes,
        std::int64_t timestamp_100ns) {
        {
            std::scoped_lock lock(mutex_);
            // 失败后不再尝试：decode_common 的调用方是 C 回调（raop），C++ 异常
            // 穿越 C 栈是未定义行为——所有异常必须在这层以内消化掉。
            if (failed_ && codec_ == nullptr) {
                pending_input_.clear();
                return {};
            }
            if (codec_ == nullptr) {
                try {
                    create_locked();
                } catch (const std::exception &) {
                    pending_input_.clear();
                    return {};
                }
            }
            pending_input_.push_back(PendingInput{std::move(bytes), timestamp_100ns});
            pump_input_locked();
            // 策略链探帧：配置后推了 N 帧仍零输出回调 → 自动切下一档策略。
            if (strategy_chain_active_) {
                ++frames_since_create_;
                maybe_switch_strategy_locked();
            }
        }
        // 等输出：解码是回调驱动的，给输出回调一点时间把帧交回来。
        // 1080p60 HW 解码冷启动（首 I 帧）常 >8ms，原值会让"解码成功但被超时丢弃"，
        // 表现为 present() 拿不到帧、画面黑。改 50ms 后再慢的解码器也能覆盖到首帧，
        // 后续帧因为解码器已 warm，产出基本在 16ms 内完成。
        std::unique_lock lock(mutex_);
        output_ready_.wait_for(lock, std::chrono::milliseconds(50),
            [this] { return !decoded_.empty() || failed_; });
        return take_decoded_locked();
    }

    std::vector<DecodedFrame> decode(std::span<const std::uint8_t> length_prefixed_sample,
        std::int64_t timestamp_100ns, std::int64_t duration_100ns) override {
        (void)duration_100ns;
        return decode_common(
            to_annex_b(length_prefixed_sample, format_.nalu_length_size), timestamp_100ns);
    }

    // AirPlay raop 镜像回调给的已经是 Annex-B（NAL 前带 00 00 00 01 起始码），
    // 直接喂给 OH_VideoDecoder，无需再做 AVCC→Annex-B 的长度前缀转换。
    std::vector<DecodedFrame> decode_annex_b(std::span<const std::uint8_t> annex_b_sample,
        std::int64_t timestamp_100ns) override {
        return decode_common(
            std::vector<std::uint8_t>(annex_b_sample.begin(), annex_b_sample.end()),
            timestamp_100ns);
    }

    // 直接用整段 Annex-B（SPS/PPS，含起始码）作为 Codec Config 配置解码器。
// 关键：从 SPS 里解析真实 width/height 覆盖外面给的提示值 —— 否则 OH_VideoDecoder
// 收到"配置 1920×1080 / SPS 实际 810×1440"会在硬件解码器上校验失败、静默丢所有帧
// （不调 OnError，看起来像"推到解码器但完全没回调"，正是 16:57/17:08 截图的形态）。
// 同时保存编码尺寸与显示尺寸两套：部分 AVCodec 框架用"内部重解析 SPS 的宽高"校验
// Configure 值，比对口径（编码 16 对齐 vs 显示 crop 后）因版本而异——单押一个口径
// 赌不起，交给策略自动切换链（见 DecoderStrategy）。
    void configure_annex_b(std::span<const std::uint8_t> annex_b_codec_config,
        std::uint32_t width, std::uint32_t height, bool hevc) override {
        std::scoped_lock lock(mutex_);
        codec_config_override_.assign(annex_b_codec_config.begin(),
            annex_b_codec_config.end());
        have_codec_config_override_ = !codec_config_override_.empty();
        Diag().configures.fetch_add(1, std::memory_order_relaxed);
        {
            // 参数集头：一眼看出是 SPS 开头（00 00 00 01 67/64）还是 PPS 开头（28）。
            const auto cb = [&](std::size_t k) -> std::uint32_t {
                return k < codec_config_override_.size()
                    ? codec_config_override_[k] : 0u;
            };
            Diag().config_head_b0_3.store((cb(0) << 24) | (cb(1) << 16) | (cb(2) << 8) | cb(3),
                std::memory_order_relaxed);
            Diag().config_head_b4_7.store((cb(4) << 24) | (cb(5) << 16) | (cb(6) << 8) | cb(7),
                std::memory_order_relaxed);
        }
        // ★ 参数集可能在中途变好（SPS 后来才到）、也可能整个变掉（换分辨率、
        //   会话重连）。
        //   以前这里在 codec_ 已存在时直接复用旧解码器实例，新的参数集只写进
        //   codec_config_override_ 却**从不生效**——create_locked() 里
        //   `if (codec_ != nullptr) return;` 会把它整个跳过去。于是"补到了正确的
        //   SPS/PPS"在 UI 上看起来毫无作用。现在先拆掉旧实例，让新参数集真正生效。
        if (codec_ != nullptr) {
            OH_VideoDecoder_Stop(codec_);
            OH_VideoDecoder_Destroy(codec_);
            codec_ = nullptr;
        }
        decoded_.clear();
        pending_input_.clear();
        have_input_buffer_ = false;
        input_buffer_ = nullptr;
        failed_ = false;
        drain_complete_ = false;
        format_ = coremedia::FormatDescription{};
        format_.codec = static_cast<std::uint32_t>(
            hevc ? coremedia::VideoCodec::Hevc : coremedia::VideoCodec::H264);
        // SPS 解析拿真值：失败回退到调用方给的提示值，并累计失败次数供 UI 诊断。
        const SpsSize sps = ParseH264Sps(annex_b_codec_config);
        if (sps.ok) {
            enc_width_ = sps.width;
            enc_height_ = sps.height;
            disp_width_ = sps.display_width;
            disp_height_ = sps.display_height;
            Diag().last_sps_enc_width.store(sps.width, std::memory_order_relaxed);
            Diag().last_sps_enc_height.store(sps.height, std::memory_order_relaxed);
            Diag().last_sps_disp_width.store(sps.display_width, std::memory_order_relaxed);
            Diag().last_sps_disp_height.store(sps.display_height, std::memory_order_relaxed);
        } else {
            enc_width_ = disp_width_ = width;
            enc_height_ = disp_height_ = height;
            Diag().sps_parse_failures.fetch_add(1, std::memory_order_relaxed);
        }
        // 策略链从第一档（硬件 + 编码尺寸）开始。
        strategy_ = DecoderStrategy::HwEncSize;
        strategy_chain_active_ = true;
        pushed_to_codec_ = 0;
        frames_since_create_ = 0;
        outputs_since_create_ = 0;
        Diag().strategy.store(0, std::memory_order_relaxed);
        ++generation_;
        create_locked();
    }

    std::vector<DecodedFrame> drain() override {
        {
            std::scoped_lock lock(mutex_);
            if (codec_ == nullptr) return {};
            draining_ = true;
            push_eos_locked();
        }
        std::unique_lock lock(mutex_);
        output_ready_.wait_for(lock, std::chrono::milliseconds(60),
            [this] { return drain_complete_ || failed_; });
        draining_ = false;
        return take_decoded_locked();
    }

    void flush() override {
        std::scoped_lock lock(mutex_);
        if (codec_ != nullptr) OH_VideoDecoder_Flush(codec_);
        decoded_.clear();
        pending_input_.clear();
        failed_ = false;
        drain_complete_ = false;
        // Flush 后解码器会重新发输入缓冲，之前持有的那个索引已失效。
        have_input_buffer_ = false;
        input_buffer_ = nullptr;
        pushed_to_codec_ = 0;
    }

    [[nodiscard]] DecoderPreference preference() const noexcept override {
        return preference_;
    }
    [[nodiscard]] std::string_view selected_decoder_name() const noexcept override {
        return "ohos-avcodec";
    }
    [[nodiscard]] DecoderAcceleration decoder_acceleration() const noexcept override {
        return acceleration_;
    }
    [[nodiscard]] bool selected_decoder_is_hardware() const noexcept override {
        return acceleration_ == DecoderAcceleration::Hardware;
    }
    [[nodiscard]] PixelFormat output_pixel_format() const noexcept override {
        return PixelFormat::Nv12;
    }

private:
    struct PendingInput {
        std::vector<std::uint8_t> bytes;
        std::int64_t timestamp_100ns{};
    };

    // 解码策略自动切换链（仅 AirPlay annex_b 路径）。背景：OH_VideoDecoder 对
    // "Configure 宽高 vs 码流 SPS 宽高"的校验口径因硬件/框架版本而异（编码 16
    // 对齐尺寸 vs crop 后显示尺寸），且部分平台硬件解码器在 buffer 模式下兼容
    // 性差。推帧 30 帧（约 1.5 秒）仍零输出回调就换下一档，四档全试完仍无输出
    // 才认输——每档都显式重建解码器，SPS/PPS 重新喂。
    enum class DecoderStrategy {
        HwEncSize = 0,   // 硬件解码器 + 编码尺寸（16 对齐，如 816×1440）
        HwDispSize,      // 硬件解码器 + 显示尺寸（crop 后，如 810×1440）
        SwEncSize,       // 软件解码器 + 编码尺寸
        SwDispSize,      // 软件解码器 + 显示尺寸
        Count
    };
    static constexpr std::uint32_t kStrategyProbeFrames = 30;

    void maybe_switch_strategy_locked() {
        if (!strategy_chain_active_) return;
        if (outputs_since_create_ != 0) return; // 当前策略已有输出，不动
        if (frames_since_create_ < kStrategyProbeFrames) return;
        const int next = static_cast<int>(strategy_) + 1;
        if (next >= static_cast<int>(DecoderStrategy::Count)) return; // 全试完
        if (codec_ != nullptr) {
            OH_VideoDecoder_Stop(codec_);
            OH_VideoDecoder_Destroy(codec_);
            codec_ = nullptr;
        }
        decoded_.clear();
        pending_input_.clear();
        have_input_buffer_ = false;
        input_buffer_ = nullptr;
        pushed_to_codec_ = 0;
        frames_since_create_ = 0;
        outputs_since_create_ = 0;
        strategy_ = static_cast<DecoderStrategy>(next);
        Diag().strategy.store(static_cast<std::uint32_t>(strategy_),
            std::memory_order_relaxed);
        Diag().strategy_switches.fetch_add(1, std::memory_order_relaxed);
        try {
            create_locked();
        } catch (const std::exception &) {
            // 重建失败（如平台没有软件解码器组件）：停用策略链、置失败态，
            // 不让异常穿越 C 回调栈。
            strategy_chain_active_ = false;
            failed_ = true;
        }
    }

    void create_locked() {
        if (codec_ != nullptr) return;
        const auto codec = format_.video_codec();
        const char* mime = codec == coremedia::VideoCodec::Hevc
            ? OH_AVCODEC_MIMETYPE_VIDEO_HEVC
            : OH_AVCODEC_MIMETYPE_VIDEO_AVC;
        // 策略链（仅 AirPlay annex_b 路径启用）：决定硬件/软件解码器与 Configure
        // 宽高口径。USB 的 configure() 路径不参与，保持原有行为。
        bool is_hw = true;
        bool wants_enc_size = false;
        if (strategy_chain_active_) {
            is_hw = strategy_ == DecoderStrategy::HwEncSize ||
                    strategy_ == DecoderStrategy::HwDispSize;
            wants_enc_size = strategy_ == DecoderStrategy::HwEncSize ||
                             strategy_ == DecoderStrategy::SwEncSize;
            format_.width = wants_enc_size ? enc_width_ : disp_width_;
            format_.height = wants_enc_size ? enc_height_ : disp_height_;
        }
        // 优先按能力查询到的组件名创建（能拿到确切名字、可记录到诊断），
        // 查不到再退回 CreateByMime。
        const char* name = nullptr;
        OH_AVCapability* capability = OH_AVCodec_GetCapabilityByCategory(mime,
            false, is_hw ? HARDWARE : SOFTWARE);
        if (capability != nullptr) name = OH_AVCapability_GetName(capability);
        if (name != nullptr) {
            codec_ = OH_VideoDecoder_CreateByName(name);
        } else {
            codec_ = OH_VideoDecoder_CreateByMime(mime);
        }
        {
            std::lock_guard<std::mutex> name_lock(g_decoder_name_mutex);
            g_decoder_name = name != nullptr
                ? std::string(name) + (is_hw ? " (hw)" : " (sw)")
                : std::string("mime:") + mime;
        }
        if (codec_ == nullptr) {
            failed_ = true;
            throw std::runtime_error(std::format(
                "解码器创建失败：{} {}", is_hw ? "hw" : "sw",
                codec == coremedia::VideoCodec::Hevc ? "video/hevc" : "video/avc"));
        }

        OH_AVCodecCallback callback{};
        callback.onError = &OhosVideoDecoder::OnError;
        callback.onStreamChanged = &OhosVideoDecoder::OnStreamChanged;
        callback.onNeedInputBuffer = &OhosVideoDecoder::OnNeedInputBuffer;
        callback.onNewOutputBuffer = &OhosVideoDecoder::OnNewOutputBuffer;
        if (OH_VideoDecoder_RegisterCallback(codec_, callback, this) != AV_ERR_OK) {
            failed_ = true;
            throw std::runtime_error("OH_VideoDecoder_RegisterCallback 失败");
        }

        OH_AVFormat* description = OH_AVFormat_Create();
        OH_AVFormat_SetIntValue(description, OH_MD_KEY_WIDTH,
            static_cast<std::int32_t>(format_.width));
        OH_AVFormat_SetIntValue(description, OH_MD_KEY_HEIGHT,
            static_cast<std::int32_t>(format_.height));
        OH_AVFormat_SetIntValue(description, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
        OH_AVFormat_SetIntValue(description, OH_MD_KEY_FRAME_RATE,
            static_cast<std::int32_t>(fps_numerator_ / fps_denominator_));
        // 参数集（SPS/PPS/VPS）必须在 Configure 之前给进去，否则解码器无从得知
        // 编码参数。AVCC 流的参数集在 avcC 里、样本里未必带，见 build_codec_config。
        const std::vector<std::uint8_t> codec_config = have_codec_config_override_
            ? codec_config_override_ : build_codec_config(format_);
        if (!codec_config.empty()) {
            if (!OH_AVFormat_SetBuffer(description, OH_MD_KEY_CODEC_CONFIG,
                    codec_config.data(), codec_config.size())) {
                logging::write(logging::Level::Warning, "decoder",
                    "OH_MD_KEY_CODEC_CONFIG 写入失败，AVCC 流可能解不出帧");
            }
        } else {
            logging::write(logging::Level::Warning, "decoder",
                "FormatDescription 未携带参数集（VPS/SPS/PPS 全空），解码可能失败");
        }
        const OH_AVErrCode configured = OH_VideoDecoder_Configure(codec_, description);
        OH_AVFormat_Destroy(description);
        if (configured != AV_ERR_OK) {
            failed_ = true;
            throw std::runtime_error("OH_VideoDecoder_Configure 失败");
        }
        if (OH_VideoDecoder_Prepare(codec_) != AV_ERR_OK ||
            OH_VideoDecoder_Start(codec_) != AV_ERR_OK) {
            failed_ = true;
            throw std::runtime_error("OH_VideoDecoder_Prepare/Start 失败");
        }
        acceleration_ = preference_ == DecoderPreference::SoftwareCompatible
            ? DecoderAcceleration::Software
            : DecoderAcceleration::Hardware;
        logging::write(logging::Level::Info, "decoder",
            std::format("ohos avcodec decoder started {}x{} fps={}/{}", format_.width,
                format_.height, fps_numerator_, fps_denominator_));
        Diag().last_config_width.store(format_.width, std::memory_order_relaxed);
        Diag().last_config_height.store(format_.height, std::memory_order_relaxed);
    }

    // 输入缓冲由 OnNeedInputBuffer 交给我们，因此这里只把待发样本往前推一格。
    void pump_input_locked() {
        if (codec_ == nullptr || pending_input_.empty() || !have_input_buffer_) return;
        auto pending = std::move(pending_input_.front());
        pending_input_.pop_front();

        // 诊断：记录首个推入帧的前 8 字节。放这里而不是 decode_common，是因为
        // 只有这里能看到"真正要进解码器的 Annex-B 字节"——头部 00 00 00 01 67/68/65/41
        // 一眼判定参数集/IDR/P 帧结构对不对。
        bool expected = false;
        if (Diag().first_input_recorded.compare_exchange_strong(expected, true,
                std::memory_order_relaxed)) {
            const auto b = [&](std::size_t k) -> std::uint32_t {
                return k < pending.bytes.size() ? pending.bytes[k] : 0u;
            };
            Diag().first_input_b0_3.store((b(0) << 24) | (b(1) << 16) | (b(2) << 8) | b(3),
                std::memory_order_relaxed);
            Diag().first_input_b4_7.store((b(4) << 24) | (b(5) << 16) | (b(6) << 8) | b(7),
                std::memory_order_relaxed);
        }

        // ── 喂帧方式（2026-09-19 修复）────────────────────────────────────────
        // 四档策略（硬/软 × 编码/显示尺寸）全部无输出、callback=0、OnError=0，
        // 说明根因不是"配置宽高口径"，而是四档**共用**的喂帧方式。逐条修：
        //
        // ① 关键帧标记。此前所有帧一律 AVCODEC_BUFFER_FLAGS_NONE；解码器有可能
        //    一直在等"标了同步帧的输入"才肯吐输出（AVCodec 把该 flag 定义为
        //    "Indicates that the Buffer contains keyframes"）。用 NAL 扫描识别
        //    IDR（nal_type=5）后标上。
        const bool has_idr = annex_b_has_nal_type(pending.bytes, 5);
        if (has_idr) Diag().idr_frames.fetch_add(1, std::memory_order_relaxed);

        // ② in-band 参数集。OH_MD_KEY_CODEC_CONFIG 是"配置期"给参数集，各实现
        //    采纳口径不一；而裸 Annex-B 流把 SPS/PPS 自带在关键帧前，是所有解码器
        //    都认的通用做法。给「本解码器实例的首帧」和「每个 IDR」前置拼一份。
        const bool need_param_set =
            have_codec_config_override_ && (pushed_to_codec_ == 0 || has_idr);
        std::vector<std::uint8_t> framed;
        if (need_param_set) {
            framed.reserve(codec_config_override_.size() + pending.bytes.size());
            framed.insert(framed.end(), codec_config_override_.begin(),
                codec_config_override_.end());
            framed.insert(framed.end(), pending.bytes.begin(), pending.bytes.end());
        }
        const std::uint8_t* payload = framed.empty() ? pending.bytes.data() : framed.data();
        std::size_t payload_size = framed.empty() ? pending.bytes.size() : framed.size();

        OH_AVCodecBufferAttr attr{};
        attr.pts = pending.timestamp_100ns / 10; // 100ns → us
        attr.size = static_cast<std::int32_t>(payload_size);
        attr.offset = 0;
        attr.flags = has_idr
            ? static_cast<std::uint32_t>(AVCODEC_BUFFER_FLAGS_SYNC_FRAME)
            : static_cast<std::uint32_t>(AVCODEC_BUFFER_FLAGS_NONE);

        const std::int32_t capacity = OH_AVBuffer_GetCapacity(input_buffer_);
        if (capacity > 0) {
            Diag().input_capacity.store(capacity, std::memory_order_relaxed);
        }
        // 容量闸：I 帧可能远大于解码器分配的输入缓冲。不检查就是 memcpy 堆越界写。
        // 先退掉 in-band 参数集（只多几十字节，退掉常常就装得下），仍超限才整帧丢弃
        // ——丢弃比截断安全（截断的 NALU 解不出还可能破坏参考链）。
        if (capacity > 0 && attr.size > capacity && !framed.empty()) {
            payload = pending.bytes.data();
            payload_size = pending.bytes.size();
            attr.size = static_cast<std::int32_t>(payload_size);
        }
        if (capacity > 0 && attr.size > capacity) {
            Diag().input_too_large.fetch_add(1, std::memory_order_relaxed);
            OH_AVCodecBufferAttr drop{};
            drop.pts = 0;
            drop.size = 0;
            drop.offset = 0;
            drop.flags = AVCODEC_BUFFER_FLAGS_NONE;
            (void)OH_AVBuffer_SetBufferAttr(input_buffer_, &drop);
            (void)OH_VideoDecoder_PushInputBuffer(codec_, input_index_);
            have_input_buffer_ = false;
            input_buffer_ = nullptr;
            return;
        }
        if (OH_AVBuffer_SetBufferAttr(input_buffer_, &attr) != AV_ERR_OK) {
            // 以前这里静默 return：缓冲既不推进也不归还，输入路径会卡死且诊断看不见。
            // 现在至少把空缓冲 push 回去归还槽位，让输入队列继续流转。
            Diag().setattr_failures.fetch_add(1, std::memory_order_relaxed);
            OH_AVCodecBufferAttr empty{};
            empty.pts = 0;
            empty.size = 0;
            empty.offset = 0;
            empty.flags = AVCODEC_BUFFER_FLAGS_NONE;
            (void)OH_AVBuffer_SetBufferAttr(input_buffer_, &empty);
            (void)OH_VideoDecoder_PushInputBuffer(codec_, input_index_);
            have_input_buffer_ = false;
            input_buffer_ = nullptr;
            return;
        }
        std::uint8_t* address = OH_AVBuffer_GetAddr(input_buffer_);
        if (address == nullptr) return;
        std::memcpy(address, payload, payload_size);
        // ★ 不再忽略返回值。以前写 `(void)OH_VideoDecoder_PushInputBuffer(...)` 之后
        //   无条件 pushed_inputs++：push 失败（如 AV_ERR_INVALID_STATE）时计数照涨，
        //   正是"已推 N 帧、callback=0"这类假成功的温床。现在只有真正成功才计入。
        const OH_AVErrCode pushed = OH_VideoDecoder_PushInputBuffer(codec_, input_index_);
        have_input_buffer_ = false;
        input_buffer_ = nullptr;
        if (pushed != AV_ERR_OK) {
            Diag().push_failures.fetch_add(1, std::memory_order_relaxed);
            Diag().last_push_error.store(static_cast<std::int32_t>(pushed),
                std::memory_order_relaxed);
            return;
        }
        ++pushed_to_codec_;
        Diag().last_input_size.store(static_cast<std::int32_t>(payload_size),
            std::memory_order_relaxed);
        if (!framed.empty()) {
            Diag().inband_param_sets.fetch_add(1, std::memory_order_relaxed);
        }
        if (has_idr) Diag().sync_flagged.fetch_add(1, std::memory_order_relaxed);
        Diag().pushed_inputs.fetch_add(1, std::memory_order_relaxed);
    }

    void push_eos_locked() {
        if (codec_ == nullptr || !have_input_buffer_) {
            // 没有空闲输入缓冲时也必须让解码器知道没有更多数据了，
            // 否则 drain 会一直等不到输出。
            return;
        }
        OH_AVCodecBufferAttr attr{};
        attr.pts = 0;
        attr.size = 0;
        attr.offset = 0;
        attr.flags = AVCODEC_BUFFER_FLAGS_EOS;
        (void)OH_AVBuffer_SetBufferAttr(input_buffer_, &attr);
        (void)OH_VideoDecoder_PushInputBuffer(codec_, input_index_);
        have_input_buffer_ = false;
    }

    std::vector<DecodedFrame> take_decoded_locked() {
        std::vector<DecodedFrame> result;
        result.swap(decoded_);
        return result;
    }

    static void OnError(OH_AVCodec*, std::int32_t error_code, void* user_data) {
        auto* self = static_cast<OhosVideoDecoder*>(user_data);
        if (self == nullptr) return;
        std::scoped_lock lock(self->mutex_);
        self->failed_ = true;
        self->output_ready_.notify_all();
        // 给宿主一个总计数，UI 看到 >0 就能立刻指出"OH_VideoDecoder 出错"，不用
        // 去翻库日志。
        g_video_decoder_error_total.fetch_add(1, std::memory_order_relaxed);
        logging::write(logging::Level::Error, "decoder",
            std::format("ohos avcodec error={}", error_code));
    }

    static void OnStreamChanged(OH_AVCodec*, OH_AVFormat* format, void* user_data) {
        auto* self = static_cast<OhosVideoDecoder*>(user_data);
        if (self == nullptr || format == nullptr) return;
        std::int32_t width = 0;
        std::int32_t height = 0;
        OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_PIC_WIDTH, &width);
        OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_PIC_HEIGHT, &height);
        std::scoped_lock lock(self->mutex_);
        if (width > 0) self->decoded_width_ = static_cast<std::uint32_t>(width);
        if (height > 0) self->decoded_height_ = static_cast<std::uint32_t>(height);
        Diag().last_onstream_width.store(static_cast<std::uint32_t>(width > 0 ? width : 0),
            std::memory_order_relaxed);
        Diag().last_onstream_height.store(static_cast<std::uint32_t>(height > 0 ? height : 0),
            std::memory_order_relaxed);
    }

    static void OnNeedInputBuffer(OH_AVCodec*, std::uint32_t index, OH_AVBuffer* buffer,
        void* user_data) {
        auto* self = static_cast<OhosVideoDecoder*>(user_data);
        if (self == nullptr) return;
        {
            std::scoped_lock lock(self->mutex_);
            self->input_index_ = index;
            self->input_buffer_ = buffer;
            self->have_input_buffer_ = true;
            self->pump_input_locked();
        }
        self->output_ready_.notify_all();
    }

    static void OnNewOutputBuffer(OH_AVCodec*, std::uint32_t index, OH_AVBuffer* buffer,
        void* user_data) {
        auto* self = static_cast<OhosVideoDecoder*>(user_data);
        if (self == nullptr || buffer == nullptr) return;

        OH_AVCodecBufferAttr attr{};
        if (OH_AVBuffer_GetBufferAttr(buffer, &attr) != AV_ERR_OK) {
            OH_VideoDecoder_FreeOutputBuffer(self->codec_, index);
            return;
        }
        const bool end_of_stream = (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0;
        const std::uint32_t width = self->decoded_width_ != 0
            ? self->decoded_width_ : self->format_.width;
        const std::uint32_t height = self->decoded_height_ != 0
            ? self->decoded_height_ : self->format_.height;

        std::vector<std::uint8_t> pixels;
        std::int32_t stride = 0;
        if (!end_of_stream && attr.size > 0 && width != 0 && height != 0) {
            const auto needed = detail::checked_nv12_buffer_size(width, height);
            if (needed && static_cast<std::uint32_t>(attr.size) >= *needed) {
                const std::uint8_t* address = OH_AVBuffer_GetAddr(buffer);
                if (address != nullptr) {
                    // 行距推导：硬件解码器的输出缓冲常按 16/32/64 对齐行距
                    // （NV12 size = stride × height × 3/2）。attr.size 紧凑相等时
                    // 直接整块拷；更大时按行拷——不处理的话画面会斜着裂开。
                    std::uint32_t stride_bytes = width;
                    if (static_cast<std::uint32_t>(attr.size) != *needed && height > 0) {
                        const std::uint32_t derived =
                            static_cast<std::uint32_t>(attr.size) * 2u / (3u * height);
                        if (derived >= width) stride_bytes = derived;
                    }

                    // ★ 2026-10-02 延迟专项（两处都在"收包→上屏"的关键路径上）：
                    //
                    //   ① 不再用 resize()。vector<uint8_t>::resize() 是**值初始化**，
                    //      要先 memset 一遍整块（1080p 约 3MB），紧接着又被下面的
                    //      拷贝整体覆盖 —— 等于每帧多写一趟 3MB 内存。改成
                    //      reserve + 直接拷入，一次分配、一次写入。
                    //
                    //   ② stride 与 width 相等时（多数硬件解码器的实际情形）Y/UV
                    //      各**一次**整块 memcpy 就够。原写法无条件逐行拷贝，1080p
                    //      每帧要做 1080 + 540 = 1620 次 memcpy 调用；60fps 下是
                    //      每秒近十万次函数调用，纯属加在这条路上的税。
                    const std::size_t luma_bytes =
                        static_cast<std::size_t>(width) * height;
                    const std::uint8_t* src_y = address;
                    const std::uint8_t* src_uv = address + stride_bytes * height;

                    if (stride_bytes == width) {
                        // 紧致布局：整块搬。UV 是 width × height/2 的交织半平面。
                        pixels.assign(src_y, src_y + luma_bytes);
                        pixels.insert(pixels.end(), src_uv, src_uv + luma_bytes / 2);
                    } else {
                        pixels.reserve(*needed);
                        for (std::uint32_t row = 0; row < height; ++row) {
                            pixels.insert(pixels.end(), src_y + row * stride_bytes,
                                src_y + row * stride_bytes + width);
                        }
                        for (std::uint32_t row = 0; row < height / 2; ++row) {
                            pixels.insert(pixels.end(), src_uv + row * stride_bytes,
                                src_uv + row * stride_bytes + width);
                        }
                    }
                    stride = static_cast<std::int32_t>(width);
                }
            } else {
                Diag().output_too_small.fetch_add(1, std::memory_order_relaxed);
            }
        }
        (void)OH_VideoDecoder_FreeOutputBuffer(self->codec_, index);

        Diag().output_callbacks.fetch_add(1, std::memory_order_relaxed);
        Diag().last_output_attr_size.store(attr.size, std::memory_order_relaxed);
        Diag().last_output_width.store(width, std::memory_order_relaxed);
        Diag().last_output_height.store(height, std::memory_order_relaxed);

        std::scoped_lock lock(self->mutex_);
        ++self->outputs_since_create_; // 任何输出回调都算"解码器有反应"（含空/EOS）
        if (!pixels.empty()) {
            DecodedFrame frame;
            frame.width = width;
            frame.height = height;
            frame.stride = stride;
            frame.timestamp_100ns = attr.pts * 10; // us → 100ns
            frame.received_at = std::chrono::steady_clock::now();
            frame.pixel_format = PixelFormat::Nv12;
            frame.color = self->format_.color;
            frame.nv12 = std::move(pixels);
            self->decoded_.push_back(std::move(frame));
            Diag().output_with_pixels.fetch_add(1, std::memory_order_relaxed);
        } else {
            Diag().output_no_pixels.fetch_add(1, std::memory_order_relaxed);
        }
        if (end_of_stream) self->drain_complete_ = true;
        self->output_ready_.notify_all();
    }

    mutable std::mutex mutex_;
    std::condition_variable output_ready_;

    OH_AVCodec* codec_{};
    OH_AVBuffer* input_buffer_{};
    std::uint32_t input_index_{};
    bool have_input_buffer_{};
    // 当前这个解码器实例已成功推入的帧数。用来判定"本实例的首帧"——首帧必须
    // 带上 in-band 参数集（SPS/PPS），否则解码器无从得知编码参数。
    std::uint64_t pushed_to_codec_{};

    coremedia::FormatDescription format_{};
    // AirPlay 直推入口使用：整段 Annex-B（SPS/PPS 含起始码）作为 Codec Config，
    // 跳过 build_codec_config 的 FormatDescription 解析。
    std::vector<std::uint8_t> codec_config_override_;
    bool have_codec_config_override_{false};
    // SPS 解析出的双套尺寸（编码 16 对齐 / crop 后显示），供策略链按档切换。
    std::uint32_t enc_width_{};
    std::uint32_t enc_height_{};
    std::uint32_t disp_width_{};
    std::uint32_t disp_height_{};
    DecoderStrategy strategy_{DecoderStrategy::HwEncSize};
    bool strategy_chain_active_{false};
    std::uint32_t frames_since_create_{0};
    std::uint32_t outputs_since_create_{0};
    std::uint32_t fps_numerator_{60};
    std::uint32_t fps_denominator_{1};
    std::uint32_t decoded_width_{};
    std::uint32_t decoded_height_{};
    std::uint64_t generation_{};

    std::deque<PendingInput> pending_input_;
    std::vector<DecodedFrame> decoded_;
    bool failed_{};
    bool stopping_{};
    bool draining_{};
    bool drain_complete_{};
    DecoderPreference preference_{DecoderPreference::Auto};
    DecoderAcceleration acceleration_{DecoderAcceleration::Unknown};
};

#else // !IM_HAVE_OHOS_AVCODEC

// 该 SDK 未提供 AVCodec：构造即明确失败，不做"能构造但不能解码"的假象。
class OhosVideoDecoder final : public IVideoDecoder {
public:
    explicit OhosVideoDecoder(DecoderPreference preference) : preference_(preference) {
        throw std::runtime_error(
            "该 SDK 未提供 AVCodec（multimedia/player_framework/native_avcodec_videodecoder.h）");
    }
    void configure(const coremedia::FormatDescription&, std::uint32_t = 60,
        std::uint32_t = 1) override {}
    std::vector<DecodedFrame> decode(std::span<const std::uint8_t>, std::int64_t,
        std::int64_t) override {
        return {};
    }
    std::vector<DecodedFrame> drain() override { return {}; }
    void flush() override {}
    [[nodiscard]] DecoderPreference preference() const noexcept override { return preference_; }
    [[nodiscard]] std::string_view selected_decoder_name() const noexcept override { return "unavailable"; }
    [[nodiscard]] DecoderAcceleration decoder_acceleration() const noexcept override { return DecoderAcceleration::Unknown; }
    [[nodiscard]] bool selected_decoder_is_hardware() const noexcept override { return false; }
    [[nodiscard]] PixelFormat output_pixel_format() const noexcept override { return PixelFormat::Nv12; }

private:
    DecoderPreference preference_;
};

#endif

std::unique_ptr<IVideoDecoder> make_ohos_video_decoder(DecoderPreference preference) {
    return std::make_unique<OhosVideoDecoder>(preference);
}

// ── 给 AirPlay 接收端宿主用的诊断接口 ──────────────────────────────────────
//
// 鸿蒙 OH_VideoDecoder 的错误回调是 static 函数，没法直接注入"通知宿主"的回调。
// 这里把计数暴露成 C 函数，OhosAirPlayReceiver 每次 im_airplay_get_stats 都主动读
// 一次。计数本身由 OnError（同步）推进，原子 relaxed 就够。
//
// 同步性：当 OnError 触发时 g_video_decoder_error_total 已经 +1，但解码器内部的
// failed_/decoded_ 状态也已经在同一把 mutex 下改好。宿主读计数时不一定能
// 看到"对应的 decoded_.empty()"，不过 UI 上只需要"错误数 > 0 ⇒ 立刻报错"，
// 不需要精同步。
extern "C" std::uint64_t im_video_decoder_errors() {
    return g_video_decoder_error_total.load(std::memory_order_relaxed);
}

extern "C" void im_video_decoder_diag(iPhoneMirror::media::DecoderDiagSnapshot* out) {
    if (out == nullptr) return;
    const DecoderDiag &d = Diag();
    out->pushed_inputs        = d.pushed_inputs.load(std::memory_order_relaxed);
    out->output_callbacks     = d.output_callbacks.load(std::memory_order_relaxed);
    out->output_with_pixels   = d.output_with_pixels.load(std::memory_order_relaxed);
    out->output_no_pixels     = d.output_no_pixels.load(std::memory_order_relaxed);
    out->output_too_small     = d.output_too_small.load(std::memory_order_relaxed);
    out->input_too_large      = d.input_too_large.load(std::memory_order_relaxed);
    out->sps_parse_failures   = d.sps_parse_failures.load(std::memory_order_relaxed);
    out->last_attr_size       = d.last_output_attr_size.load(std::memory_order_relaxed);
    out->last_out_width       = d.last_output_width.load(std::memory_order_relaxed);
    out->last_out_height      = d.last_output_height.load(std::memory_order_relaxed);
    out->last_cfg_width       = d.last_config_width.load(std::memory_order_relaxed);
    out->last_cfg_height      = d.last_config_height.load(std::memory_order_relaxed);
    out->last_sps_enc_width   = d.last_sps_enc_width.load(std::memory_order_relaxed);
    out->last_sps_enc_height  = d.last_sps_enc_height.load(std::memory_order_relaxed);
    out->last_sps_disp_width  = d.last_sps_disp_width.load(std::memory_order_relaxed);
    out->last_sps_disp_height = d.last_sps_disp_height.load(std::memory_order_relaxed);
    out->last_stream_width    = d.last_onstream_width.load(std::memory_order_relaxed);
    out->last_stream_height   = d.last_onstream_height.load(std::memory_order_relaxed);
    out->first_input_b0_3     = d.first_input_b0_3.load(std::memory_order_relaxed);
    out->first_input_b4_7     = d.first_input_b4_7.load(std::memory_order_relaxed);
    out->strategy             = d.strategy.load(std::memory_order_relaxed);
    out->strategy_switches    = d.strategy_switches.load(std::memory_order_relaxed);
    out->idr_frames           = d.idr_frames.load(std::memory_order_relaxed);
    out->sync_flagged         = d.sync_flagged.load(std::memory_order_relaxed);
    out->inband_param_sets    = d.inband_param_sets.load(std::memory_order_relaxed);
    out->push_failures        = d.push_failures.load(std::memory_order_relaxed);
    out->last_push_error      = d.last_push_error.load(std::memory_order_relaxed);
    out->setattr_failures     = d.setattr_failures.load(std::memory_order_relaxed);
    out->last_input_size      = d.last_input_size.load(std::memory_order_relaxed);
    out->input_capacity       = d.input_capacity.load(std::memory_order_relaxed);
    out->config_head_b0_3     = d.config_head_b0_3.load(std::memory_order_relaxed);
    out->config_head_b4_7     = d.config_head_b4_7.load(std::memory_order_relaxed);
    out->configures           = d.configures.load(std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> name_lock(g_decoder_name_mutex);
        std::snprintf(out->decoder_name, sizeof(out->decoder_name), "%s",
            g_decoder_name.c_str());
    }
}

} // namespace iPhoneMirror::media
