// SPDX-License-Identifier: GPL-3.0-only
//
// 可移植文件 Media/VideoFrameCopy.cpp 唯一需要平台提供的那一个钩子。
//
// 为什么单独占一个翻译单元：VideoFrameCopy.cpp 会被每个目标链接（解码探测、
// 渲染探测都会拉上它），而"谁提供 materialize_gpu_frame"只跟平台有关。
// 上游 Linux 版把它放在 Media/LinuxSharedGpuFrame.cpp 并且给了理由——
// 折进平台工厂文件会把 PipeWire/libplacebo 拖进根本不放音的工装程序里。
// 鸿蒙这边同理：折进 OhosMediaBackends.cpp 会把 AVCodec 的 OHAudio/OH_VideoDecoder
// 依赖带进任何只想做颜色换算的目标。
//
// 语义（与上游 Windows/Linux 两版逐字对齐）：
//   Windows: 打开 D3D11 共享纹理并读回，把像素填进 frame.nv12。
//   Linux:   没有任何解码器会发布跨设备共享 GPU 帧，所以永远没有东西可实体化。
//   鸿蒙:    与 Linux 同因——OhosVideoDecoder 走 OH_VideoDecoder，
//            输出缓冲由本进程的 OHNativeWindow 承接，并在解码回调里就地拷成
//            紧打包 NV12 存进 frame.nv12；frame.gpu_frame 从不被置位。
//            因此这个函数在鸿蒙上只会被调用到"nv12 已经在了"的分支。
//
// 绝不假成功：调用点（copy_nv12_frame_letterboxed）只在 nv12 为空且 gpu_frame
// 非空时才进来，那时这里如实返回 false，让上层把这一帧判为取不到，而不是
// 返回一张黑图。

#include "Media/VideoFormats.h"

namespace iPhoneMirror::media::detail {

bool materialize_gpu_frame(DecodedFrame& frame) noexcept {
    // 鸿蒙没有"D3D11 共享纹理"这种要按需实体化的东西：解码输出已经在
    // frame.nv12 里。nv12 为空就说明这帧真的拿不到像素，如实回报失败。
    return !frame.nv12.empty();
}

} // namespace iPhoneMirror::media::detail
