// SPDX-License-Identifier: GPL-3.0-only
//
// 鸿蒙平台选择：把接缝的实现交给 CaptureSession。
//
// 与上游 Linux 版 Media/LinuxMediaBackends.cpp 一一对应（那里选的是
// LinuxFFmpegVideoDecoder + LinuxPipeWireAudioRenderer，这里选
// OhosVideoDecoder + OhosAudioRenderer）。后端本体在各自文件里，本文件只做选择。

#include "Media/ActiveVideoDecoder.h"

#include "OhosAudioRenderer.h"
#include "Media/CoreMedia.h"
#include "OhosVideoDecoder.h"

namespace iPhoneMirror::media {

std::unique_ptr<IVideoDecoder> make_platform_video_decoder(
    DecoderPreference preference) {
    return make_ohos_video_decoder(preference);
}

} // namespace iPhoneMirror::media

namespace iPhoneMirror::audio {

std::unique_ptr<IAudioRenderer> make_platform_audio_renderer(
    const coremedia::AudioStreamBasicDescription& format,
    bool playback_enabled, float volume) {
    return make_ohos_audio_renderer(format, playback_enabled, volume);
}

} // namespace iPhoneMirror::audio
