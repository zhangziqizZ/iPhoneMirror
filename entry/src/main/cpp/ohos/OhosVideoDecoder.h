// SPDX-License-Identifier: GPL-3.0-only
//
// 鸿蒙实现 IVideoDecoder 接缝，基于 AVCodec 的 OH_VideoDecoder。
//
// 对照上游：Windows 是 Media Foundation（MediaFoundationDecoder.cpp），
// Linux 是 libavcodec（LinuxFFmpegVideoDecoder.cpp），鸿蒙是 AVCodec Kit 的
// OH_VideoDecoder（库 libnative_media_vdec.so）。
//
// 接缝的形状差异是这里最需要注意的一点：上游 IVideoDecoder::decode() 是
// **同步**调用（喂一个 length-prefixed 样本，返回若干 DecodedFrame），而
// OH_VideoDecoder 是**异步回调**模型（输入/输出缓冲靠索引流转）。本实现用
// 输入队列 + 输出队列 + 条件变量把异步桥成同步，语义对齐上游：
//  * decode() 把样本拷进一个空闲输入缓冲推给解码器，然后等待输出；
//  * 输出回调把解码结果拷成 NV12 的 DecodedFrame 入队并唤醒等待者；
//  * drain() 冲刷解码器并返回剩余帧（EOS 之后的重排帧）。
//
// 像素格式：只接受 AVCodec 输出的 NV12（H.264 的常见硬件/软件输出格式）。
// 若输出描述里的像素格式不是 NV12，本解码器**明确报错**而不是把别的格式
// 冒充 NV12 —— 上游 DecodedFrame 的约定是"半平面 Y + 交错 UV"。

#pragma once

#include "Media/IVideoDecoder.h"

#include <memory>

namespace iPhoneMirror::media {

// libavcodec 版对应 make_ffmpeg_video_decoder；鸿蒙这里对应
// make_ohos_video_decoder。单独暴露工厂是为了让测试与验收工具能绕过
// 平台选择直接构造解码器。
[[nodiscard]] std::unique_ptr<IVideoDecoder> make_ohos_video_decoder(
    DecoderPreference preference);

// 鸿蒙 OH_VideoDecoder::OnError 累计触发次数（详见 .cpp 的实现）。C 接口是
// 因为宿主（C 实现的 OhosAirPlayReceiver）要直接读、而 IVideoDecoder 抽象层不
// 暴露错误计数。值在 OnError 触发时递增，原子 relaxed 就够。
extern "C" std::uint64_t im_video_decoder_errors();

// 解码链诊断快照（字段语义见 .cpp 的 DecoderDiag 注释）。所有计数/尺寸从
// 解码器内部原子读出；first_input_b0_3/b4_7 是首个推入帧的前 8 字节（大端
// 打包），hex 展开即可判断 Annex-B 结构（00 00 00 01 67 = SPS 开头）。
struct DecoderDiagSnapshot {
    std::uint64_t pushed_inputs{0};
    std::uint64_t output_callbacks{0};
    std::uint64_t output_with_pixels{0};
    std::uint64_t output_no_pixels{0};
    std::uint64_t output_too_small{0};
    std::uint64_t input_too_large{0};
    std::uint32_t sps_parse_failures{0};
    std::int32_t last_attr_size{0};
    std::uint32_t last_out_width{0};
    std::uint32_t last_out_height{0};
    std::uint32_t last_cfg_width{0};
    std::uint32_t last_cfg_height{0};
    std::uint32_t last_sps_enc_width{0};
    std::uint32_t last_sps_enc_height{0};
    std::uint32_t last_sps_disp_width{0};
    std::uint32_t last_sps_disp_height{0};
    std::uint32_t last_stream_width{0};
    std::uint32_t last_stream_height{0};
    std::uint32_t first_input_b0_3{0};
    std::uint32_t first_input_b4_7{0};
    std::uint32_t strategy{0};           // 当前解码策略档位（0..3）
    std::uint32_t strategy_switches{0};  // 自动切换次数（>0 = 前面档位无输出已换）
    // ── 喂帧方式诊断（2026-09-19 四档全挂后新增）─────────────────────────
    // 四档（硬/软 × 编码/显示尺寸）全试完仍 callback=0 ⇒ 根因在四档共用的喂帧
    // 方式，不在宽高口径。这几个计数把喂帧方式的每个可疑点单独量化：
    //   idr_frames        — 输入里被识别为 IDR（nal_type=5）的帧数（0 说明流里没有关键帧）
    //   sync_flagged      — 真正标了 AVCODEC_BUFFER_FLAGS_SYNC_FRAME 的帧数
    //   inband_param_sets — 在帧前拼接 SPS/PPS 的次数（裸流通用做法，不依赖
    //                       OH_MD_KEY_CODEC_CONFIG 是否被采纳）
    //   push_failures     — PushInputBuffer 返回非 OK 的次数（>0 = 之前的"已推 N 帧"
    //                       是假成功）
    //   last_push_error   — 最近一次 push 失败的 OH_AVErrCode
    //   setattr_failures  — SetBufferAttr 失败次数
    //   last_input_size   — 最近一次真正交给解码器的字节数（含 in-band 参数集）
    //   input_capacity    — 解码器分配的输入缓冲容量（0 = 从未拿到过缓冲）
    std::uint64_t idr_frames{0};
    std::uint64_t sync_flagged{0};
    std::uint64_t inband_param_sets{0};
    std::uint64_t push_failures{0};
    std::int32_t last_push_error{0};
    std::uint64_t setattr_failures{0};
    std::int32_t last_input_size{0};
    std::int32_t input_capacity{0};
    char decoder_name[96]{0};            // 实际创建的解码器组件名（含 hw/sw 标记）
};

// 解码链诊断（详见 .cpp 的实现）。out 为 null 时无操作。原子 relaxed 读。
extern "C" void im_video_decoder_diag(DecoderDiagSnapshot* out);

} // namespace iPhoneMirror::media
