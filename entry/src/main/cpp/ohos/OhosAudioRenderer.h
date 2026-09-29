// SPDX-License-Identifier: GPL-3.0-only
//
// 鸿蒙 IAudioRenderer 接缝实现，基于 OHAudio（libohaudio.so）。
//
// 对照上游：Windows 的 WasapiRenderer 与 Linux 的 LinuxPipeWireAudioRenderer
// 都复用 Audio/PcmBufferPolicy.{h,cpp} 的环形缓冲与队列阈值策略。本实现同样
// 复用那份策略，只是把"往系统端点送数据"这一段换成 OHAudio 的写回调：
//  * enqueue() 把 PCM 推进 PcmBufferPolicy 的环形缓冲；
//  * OHAudio 的 OnWriteData 回调从环形缓冲取数据填满 audioData。
// 队列策略因此在三平台上是一份代码，这也正是上游把 PcmBufferPolicy 抽出来的
// 原因。

#pragma once

#include "Audio/IAudioRenderer.h"
#include "Media/CoreMedia.h"

#include <memory>

namespace iPhoneMirror::audio {

// 上游 Linux 版对应 make_pipewire_audio_renderer。参数与语义一致：
//  * format 必须是 QuickTime 采集出的交错有符号 PCM16；
//  * playback_enabled 为 false 时不创建系统流，只记账（用于"只要统计不出声"）；
//  * 格式不合法抛 std::invalid_argument，OHAudio 建流失败抛 std::runtime_error。
// 永不返回 null。
[[nodiscard]] std::unique_ptr<IAudioRenderer> make_ohos_audio_renderer(
    const coremedia::AudioStreamBasicDescription& format,
    bool playback_enabled, float volume);

} // namespace iPhoneMirror::audio
