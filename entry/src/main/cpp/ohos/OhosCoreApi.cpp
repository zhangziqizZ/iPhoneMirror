// SPDX-License-Identifier: GPL-3.0-only
//
// 鸿蒙版 Core C ABI 实现。
//
// 与上游 Linux 版 src/LinuxCoreApi.cpp 同构：**新写一个文件**，而不是去改
// CoreApi.cpp —— 后者整体是围绕 Windows 的会话、预览 HWND、虚拟摄像头与
// AirPlay 管线写的。
//
// 诚实性规则（沿用上游 Linux 版写死在注释里的那条）：
// **任何导出都不会在没做事的情况下返回 Ok**。调用方拿到 im_start_capture 的
// Ok 就会一直等帧，所以没实现的入口一律返回明确失败，并在错误串里点名原因。
//
// 本文件里"真实现"的范围：初始化/日志、环境报告、设备枚举、有线采集会话的
// 启停与状态、最新帧时间戳、预览挂载（surfaceId → NativeWindow）、BGRA 帧拷贝、
// 渲染偏好与音频开关，以及预览侧的图像调节/圆角裁剪/旋转（直接推给 GLES 预览
// 渲染器）。其余（多设备会话、AirPlay/URL 接收端）返回明确失败。

#include "iPhoneMirror/CoreApi.h"

#include "Capture/CaptureSession.h"
#include "Device/DeviceManager.h"
#include "Logging.h"
#include "Media/VideoFormats.h"
#include "OhosCaptureBridge.h"
#include "OhosInputBridge.h"
#include "OhosPreviewRenderer.h"
#include "OhosUsbDiagnostics.h"
#include "Text/Utf.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <format>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace {

std::mutex state_mutex;
bool initialized{};
std::mutex capture_mutex;
std::condition_variable capture_frame_cv;
/**
 * 帧可用标志**单独一把锁**。
 *
 * ★ 为什么不能借用 capture_mutex：解码线程在输出回调里调 notify_frame_available()，
 *   而 im_stop_capture() 的锁序是「持 capture_mutex → 析构会话 → 析构解码器 →
 *   OH_VideoDecoder_Destroy（等在途回调返回）」。回调卡在 capture_mutex 上、
 *   Destroy 等回调返回 ⇒ 教科书式 ABBA 死锁（点"停止投屏"时正好有一帧在跑就中）。
 *   帧标志与"会话句柄"没有任何数据关系，本就该分开。
 */
std::mutex capture_frame_mutex;
bool capture_frame_available{false};
std::unique_ptr<iPhoneMirror::capture::CaptureSession> capture_session;
std::wstring last_error;
iPhoneMirror::device::DeviceManager device_manager;

std::int32_t fail(iPhoneMirror::Result result, std::wstring message) {
    last_error = std::move(message);
    return static_cast<std::int32_t>(result);
}

// 报一个鸿蒙版尚未实现的导出，消息里点明由谁负责，避免调用方只看到一个
// 光秃秃的错误码。
std::int32_t not_implemented(std::wstring_view feature, std::wstring_view owner) {
    last_error = std::wstring(feature) + L" 在鸿蒙版尚未实现（归属：" +
        std::wstring(owner) + L"）";
    return static_cast<std::int32_t>(iPhoneMirror::Result::CaptureBackendUnavailable);
}

template <std::size_t Capacity>
void copy_text(wchar_t (&destination)[Capacity], std::wstring_view source) {
    const auto length = std::min(source.size(), Capacity - 1);
    std::copy_n(source.begin(), length, destination);
    destination[length] = L'\0';
}

// 与上游 Core/src/CoreApi.cpp 的校验/映射逐条对齐（那不是本工程编译单元，
// 这里把它在鸿蒙侧需要的那份语义原样补上，避免两处口径漂移）。
bool valid_video_preferences(std::uint32_t width, std::uint32_t height,
    std::uint32_t target_fps) noexcept {
    if ((width == 0) != (height == 0)) return false;
    if (width != 0 && (width < 16 || height < 16 || width > 8192 || height > 8192)) {
        return false;
    }
    return target_fps <= 120;
}

bool valid_capture_option_extensions(
    const iPhoneMirror::CaptureOptions& options) noexcept {
    return options.reserved[2] <= 2 && options.reserved[3] <= 2 &&
        options.reserved[4] <= 2 &&
        valid_video_preferences(options.reserved[0], options.reserved[1], 0);
}

iPhoneMirror::capture::CapturePreferences preferences_from_options(
    const iPhoneMirror::CaptureOptions& options) noexcept {
    return {
        .render_max_width = options.requested_width,
        .render_max_height = options.requested_height,
        .target_fps = options.target_fps,
        .play_audio = options.play_audio != 0,
        .audio_volume = options.audio_volume,
        .usb_requested_width = options.reserved[0],
        .usb_requested_height = options.reserved[1],
        .usb_projection_mode =
            static_cast<iPhoneMirror::capture::UsbProjectionMode>(options.reserved[2]),
        .decoder_preference =
            static_cast<iPhoneMirror::media::DecoderPreference>(options.reserved[3]),
        .color_output_preference =
            static_cast<iPhoneMirror::media::ColorOutputPreference>(options.reserved[4]),
    };
}

std::int32_t refresh_devices_locked(iPhoneMirror::DeviceInfo* devices,
    std::uint32_t* count, bool refresh_metadata) {
    if (!count) {
        return fail(iPhoneMirror::Result::InvalidArgument, L"count 不能为空");
    }
    std::scoped_lock lock(state_mutex);
    if (!initialized) {
        return fail(iPhoneMirror::Result::NotInitialized, L"核心尚未初始化");
    }
    try {
        const auto records = device_manager.refresh(refresh_metadata);
        const auto capacity = *count;
        *count = static_cast<std::uint32_t>(records.size());
        if (!devices) {
            last_error.clear();
            return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
        }
        if (capacity < records.size()) {
            return fail(iPhoneMirror::Result::BufferTooSmall,
                L"DeviceInfo 缓冲区容量不足");
        }
        for (std::size_t index = 0; index < records.size(); ++index) {
            const auto& record = records[index];
            auto& info = devices[index];
            info.struct_size = sizeof(iPhoneMirror::DeviceInfo);
            info.api_version = iPhoneMirror::ApiVersion;
            info.device_id = record.device_id;
            info.mux_port = record.mux_port;
            info.state = record.state;
            info.usb_connected = record.usb_connected ? 1 : 0;
            info.pair_record_present = record.pair_record_present ? 1 : 0;
            info.lockdown_accessible = record.lockdown_accessible ? 1 : 0;
            copy_text(info.udid, record.udid);
            copy_text(info.name, record.name);
            copy_text(info.product_type, record.product_type);
            copy_text(info.os_version, record.os_version);
            copy_text(info.connection_type, record.connection_type);
            copy_text(info.status, record.status);
        }
        last_error.clear();
        return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
    } catch (const std::exception& error) {
        return fail(iPhoneMirror::Result::InternalError,
            L"枚举设备失败：" + iPhoneMirror::text::utf8_to_wide(error.what()));
    } catch (...) {
        return fail(iPhoneMirror::Result::InternalError, L"枚举设备时发生异常");
    }
}

// NV12 → 紧致 BGRA8，与上游 VideoFormats.h 里那份 CPU 色彩数学同一套
// （convert_yuv_to_sdr），所以预览窗口与导出帧看起来是一致的。
bool copy_bgra_from_nv12(const iPhoneMirror::media::DecodedFrame& frame,
    std::uint8_t* destination, std::uint32_t destination_stride,
    std::uint32_t output_width, std::uint32_t output_height) {
    if (frame.pixel_format != iPhoneMirror::media::PixelFormat::Nv12) return false;
    if (frame.width == 0 || frame.height == 0) return false;
    const std::size_t luma_bytes =
        static_cast<std::size_t>(frame.width) * frame.height;
    if (frame.nv12.size() < luma_bytes + luma_bytes / 2) return false;

    // 等比缩放采样：把输出像素均匀映射回源帧（最近邻，覆盖整幅画面），而不是
    // 只取左上角一块。修复前 source_x/source_y 直接用 column/row，等于裁剪。
    for (std::uint32_t row = 0; row < output_height; ++row) {
        const std::uint32_t source_y = output_height <= 1
            ? 0U
            : static_cast<std::uint32_t>(
                (static_cast<std::uint64_t>(row) * (frame.height - 1)) /
                (output_height - 1));
        const std::uint32_t chroma_row = source_y / 2;
        for (std::uint32_t column = 0; column < output_width; ++column) {
            const std::uint32_t source_x = output_width <= 1
                ? 0U
                : static_cast<std::uint32_t>(
                    (static_cast<std::uint64_t>(column) * (frame.width - 1)) /
                    (output_width - 1));
            const std::size_t luma_index = static_cast<std::size_t>(source_y) * frame.width + source_x;
            const std::size_t chroma_index = luma_bytes +
                static_cast<std::size_t>(chroma_row) * frame.width + (source_x / 2) * 2;
            const double y = frame.nv12[luma_index] / 255.0;
            const double cb = frame.nv12[chroma_index] / 255.0;
            const double cr = frame.nv12[chroma_index + 1] / 255.0;
            const auto rgb = iPhoneMirror::media::detail::convert_yuv_to_sdr(
                y, cb, cr, frame.color, frame.pixel_format);
            const std::size_t offset =
                static_cast<std::size_t>(row) * destination_stride + column * 4;
            destination[offset + 0] = static_cast<std::uint8_t>(
                std::clamp(rgb.blue, 0.0, 1.0) * 255.0);
            destination[offset + 1] = static_cast<std::uint8_t>(
                std::clamp(rgb.green, 0.0, 1.0) * 255.0);
            destination[offset + 2] = static_cast<std::uint8_t>(
                std::clamp(rgb.red, 0.0, 1.0) * 255.0);
            destination[offset + 3] = 255;
        }
    }
    return true;
}

// 把最新解码帧按给定上限等比缩放到 BGRA 画布并写入调用方缓冲。
std::int32_t copy_latest_frame_locked(iPhoneMirror::VideoFrameInfo* info,
    std::uint8_t* buffer, std::uint32_t* buffer_size, std::uint32_t max_width,
    std::uint32_t max_height) {
    if (!info || !buffer_size) {
        return fail(iPhoneMirror::Result::InvalidArgument, L"info / buffer_size 不能为空");
    }
    std::scoped_lock lock(capture_mutex);
    if (!capture_session) {
        return fail(iPhoneMirror::Result::CaptureBackendUnavailable, L"没有正在运行的采集会话");
    }
    const auto frame = capture_session->latest_frame();
    if (!frame) {
        return fail(iPhoneMirror::Result::CaptureBackendUnavailable, L"尚未收到解码帧");
    }

    std::uint32_t output_width = frame->width;
    std::uint32_t output_height = frame->height;
    if (max_width != 0 && max_height != 0 && output_width != 0 && output_height != 0) {
        // 等比缩放，且不放大：与上游 im_copy_latest_video_frame_scaled 的约定一致。
        const double width_ratio = static_cast<double>(max_width) / output_width;
        const double height_ratio = static_cast<double>(max_height) / output_height;
        const double ratio = std::min({width_ratio, height_ratio, 1.0});
        output_width = std::max<std::uint32_t>(1, static_cast<std::uint32_t>(output_width * ratio));
        output_height = std::max<std::uint32_t>(1, static_cast<std::uint32_t>(output_height * ratio));
    }
    const std::uint32_t stride = output_width * 4;
    const std::uint32_t required = stride * output_height;
    if (*buffer_size < required) {
        *buffer_size = required;
        return fail(iPhoneMirror::Result::BufferTooSmall, L"BGRA 缓冲区容量不足");
    }

    info->struct_size = sizeof(iPhoneMirror::VideoFrameInfo);
    info->api_version = iPhoneMirror::ApiVersion;
    info->width = output_width;
    info->height = output_height;
    info->stride = stride;
    info->pixel_format = 1; // 1 = BGRA8
    info->timestamp_100ns = frame->timestamp_100ns;
    if (buffer == nullptr) {
        *buffer_size = required;
        last_error.clear();
        return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
    }
    if (!copy_bgra_from_nv12(*frame, buffer, stride, output_width, output_height)) {
        return fail(iPhoneMirror::Result::InternalError,
            L"帧不是 NV12 / 数据不完整，无法转成 BGRA8");
    }
    *buffer_size = required;
    last_error.clear();
    return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
}

} // namespace

std::int32_t IM_CALL im_initialize() {
    std::scoped_lock lock(state_mutex);
    iPhoneMirror::logging::initialize();
    initialized = true;
    last_error.clear();
    iPhoneMirror::logging::write("core initialize platform=ohos");
    return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
}

void IM_CALL im_shutdown() {
    std::scoped_lock lock(state_mutex);
    if (!initialized) return;
    initialized = false;
    iPhoneMirror::logging::write("core shutdown platform=ohos");
    iPhoneMirror::logging::shutdown();
}

std::uint32_t IM_CALL im_api_version() { return iPhoneMirror::ApiVersion; }

std::int32_t IM_CALL im_log_message(const wchar_t* message) {
    if (!message || !*message) {
        return fail(iPhoneMirror::Result::InvalidArgument, L"日志消息不能为空");
    }
    constexpr std::size_t MaxLogMessage = 4096;
    const std::wstring_view text(message);
    if (text.size() > MaxLogMessage) {
        return fail(iPhoneMirror::Result::InvalidArgument, L"日志消息过长");
    }
    iPhoneMirror::logging::write(iPhoneMirror::text::wide_to_utf8(text));
    last_error.clear();
    return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
}

std::int32_t IM_CALL im_set_log_file(const char* path) {
    if (!path || !*path) {
        return fail(iPhoneMirror::Result::InvalidArgument, L"日志路径不能为空");
    }
    // 把原生诊断日志重定向进应用沙箱（filesDir/iPhoneMirror/Logs/startup.log），
    // 否则默认写系统 temp 目录，ArkTS 的「实时日志」因沙箱隔离读不到、永远空白。
    iPhoneMirror::logging::set_log_file_override(std::filesystem::path(path));
    last_error.clear();
    return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
}

std::int32_t IM_CALL im_get_environment(iPhoneMirror::EnvironmentInfo* environment) {
    if (!environment ||
        environment->struct_size != sizeof(iPhoneMirror::EnvironmentInfo)) {
        return fail(iPhoneMirror::Result::InvalidArgument,
            L"EnvironmentInfo 结构版本不匹配");
    }
    std::scoped_lock lock(state_mutex);
    if (!initialized) {
        return fail(iPhoneMirror::Result::NotInitialized, L"核心尚未初始化");
    }
    try {
        const auto info = device_manager.environment();
        environment->api_version = iPhoneMirror::ApiVersion;
        environment->apple_mobile_device_service_installed = info.service_installed;
        environment->apple_mobile_device_service_running = info.service_running;
        environment->standard_usbmux_available = info.standard_mux;
        environment->capture_usbmux_available = info.capture_mux;
        environment->physical_apple_usb_devices = info.physical_device_count;
        copy_text(environment->diagnostic, info.diagnostic);
        environment->libusb_runtime_available = info.libusb_runtime;
        environment->usbdk_backend_available = info.usbdk_backend;
        environment->libusb_apple_devices = info.libusb_apple_devices;
        copy_text(environment->libusb_version, info.libusb_version);
        environment->usbdk_backend_known = info.usbdk_backend_known;
        environment->libusb_apple_devices_known = info.libusb_apple_devices_known;
        last_error.clear();
        return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
    } catch (...) {
        return fail(iPhoneMirror::Result::InternalError, L"读取 USB 环境时发生异常");
    }
}

std::int32_t IM_CALL im_refresh_devices(iPhoneMirror::DeviceInfo* devices,
    std::uint32_t* count) {
    return refresh_devices_locked(devices, count, false);
}

std::int32_t IM_CALL im_refresh_devices_ex(iPhoneMirror::DeviceInfo* devices,
    std::uint32_t* count, std::int32_t refresh_metadata) {
    return refresh_devices_locked(devices, count, refresh_metadata != 0);
}

const wchar_t* IM_CALL im_last_error() { return last_error.c_str(); }

// 有线 USB 采集。共享状态机、USB DDK 传输、AVCodec 解码器与 OHAudio 播放器
// 在鸿蒙这一侧都已就位，所以这里跑的是真链路。use_usbdk 恒为 false：UsbDk 是
// Windows 后端，CaptureSession 在鸿蒙上只会选到 LibUsb1 那一支。
std::int32_t start_capture_locked(const wchar_t* serial,
    const iPhoneMirror::capture::CapturePreferences& preferences) {
    if (serial == nullptr || *serial == L'\0') {
        return fail(iPhoneMirror::Result::InvalidArgument, L"serial 不能为空");
    }
    std::scoped_lock lock(capture_mutex);
    if (capture_session) {
        return fail(iPhoneMirror::Result::SessionAlreadyExists, L"已有采集会话在运行");
    }
    // 清掉上一轮的有线诊断尾巴。不清的话，这一轮还没来得及记录时，界面会把
    // 上一次失败的记录当作本次结果显示——那正是这个通道最不该犯的错。
    iPhoneMirror::ohos_usb_diag::clear();
    try {
        auto session = std::make_unique<iPhoneMirror::capture::CaptureSession>(
            iPhoneMirror::text::wide_to_utf8(serial), preferences);
        session->start(false);
        capture_session = std::move(session);
        last_error.clear();
        return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
    } catch (const std::exception& error) {
        capture_session.reset();
        last_error = iPhoneMirror::text::utf8_to_wide(error.what());
        return static_cast<std::int32_t>(
            iPhoneMirror::Result::CaptureBackendUnavailable);
    } catch (...) {
        capture_session.reset();
        return fail(iPhoneMirror::Result::CaptureBackendUnavailable,
            L"启动采集时发生未知异常");
    }
}

std::int32_t start_capture_locked(const wchar_t* serial, bool play_audio) {
    iPhoneMirror::capture::CapturePreferences preferences;
    preferences.play_audio = play_audio;
    return start_capture_locked(serial, preferences);
}

std::int32_t IM_CALL im_start_capture(const wchar_t* serial) {
    return start_capture_locked(serial, true);
}

std::int32_t IM_CALL im_start_capture_ex(const wchar_t* serial,
    std::int32_t play_audio) {
    return start_capture_locked(serial, play_audio != 0);
}

// 带选项的启动：与上游 CoreApi.cpp 的 im_start_capture_with_options 同一套校验与
// 字段映射。修复前这里是 not_implemented，而 ArkTS 主入口 start() 只走这一条，
// 导致有线投屏永远点不起来。
std::int32_t IM_CALL im_start_capture_with_options(const wchar_t* serial,
    const iPhoneMirror::CaptureOptions* options) {
    if (serial == nullptr || options == nullptr) {
        return fail(iPhoneMirror::Result::InvalidArgument, L"参数不能为空");
    }
    if (options->struct_size != sizeof(iPhoneMirror::CaptureOptions) ||
        !valid_video_preferences(options->requested_width,
            options->requested_height, options->target_fps) ||
        !std::isfinite(options->audio_volume) ||
        options->audio_volume < 0.0F || options->audio_volume > 1.0F ||
        !valid_capture_option_extensions(*options)) {
        return fail(iPhoneMirror::Result::InvalidArgument,
            L"CaptureOptions 参数无效");
    }
    return start_capture_locked(serial, preferences_from_options(*options));
}

std::int32_t IM_CALL im_stop_capture() {
    std::scoped_lock lock(capture_mutex);
    if (!capture_session) {
        last_error.clear();
        return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
    }
    // ★ 必须接住异常：im_start_capture* 是有 try/catch 的，这里不对称的话，
    //   stop()（含析构解码器/释放 USB 会话）抛出的异常会穿过 C ABI 边界
    //   ⇒ std::terminate()，表现为"点停止就闪退"，且没有任何日志。
    try {
        capture_session->stop();
    } catch (const std::exception& e) {
        // 会话已经停不干净了，但句柄必须放掉：留着一个半死的会话会让下一次
        // im_start_capture 直接返回 SessionAlreadyExists。
        capture_session.reset();
        last_error = L"停止采集失败：";
        const std::string what = e.what();
        last_error.append(what.begin(), what.end());
        return static_cast<std::int32_t>(iPhoneMirror::Result::SessionTeardownFailed);
    } catch (...) {
        capture_session.reset();
        last_error = L"停止采集失败：未知异常";
        return static_cast<std::int32_t>(iPhoneMirror::Result::SessionTeardownFailed);
    }
    capture_session.reset();
    last_error.clear();
    return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
}

std::int32_t IM_CALL im_get_capture_status(iPhoneMirror::CaptureStatus* status) {
    if (!status || status->struct_size != sizeof(iPhoneMirror::CaptureStatus)) {
        return fail(iPhoneMirror::Result::InvalidArgument,
            L"CaptureStatus 结构版本不匹配");
    }
    status->api_version = iPhoneMirror::ApiVersion;
    std::scoped_lock lock(capture_mutex);
    if (!capture_session) {
        // 一个格式正确的空闲状态，不是失败：确实没有会话在跑。
        status->state = iPhoneMirror::CaptureState::Idle;
        status->width = 0;
        status->height = 0;
        status->fps = 0.0;
        status->latency_ms = 0.0;
        status->video_frames = 0;
        status->audio_packets = 0;
        status->audio_sample_rate = 0;
        status->audio_channels = 0;
        status->failure_kind = iPhoneMirror::CaptureFailureKind::None;
        status->failure_stage = iPhoneMirror::CaptureFailureStage::None;
        status->error_code = 0;
        copy_text(status->message, L"Idle");
        last_error.clear();
        return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
    }
    const auto snapshot = capture_session->snapshot();
    status->state = static_cast<iPhoneMirror::CaptureState>(snapshot.state);
    status->width = snapshot.width;
    status->height = snapshot.height;
    status->fps = snapshot.fps;
    status->latency_ms = snapshot.latency_ms;
    status->video_frames = snapshot.video_frames;
    status->audio_packets = snapshot.audio_packets;
    status->audio_sample_rate = snapshot.audio_sample_rate;
    status->audio_channels = snapshot.audio_channels;
    status->failure_kind =
        static_cast<iPhoneMirror::CaptureFailureKind>(snapshot.failure_kind);
    status->failure_stage =
        static_cast<iPhoneMirror::CaptureFailureStage>(snapshot.failure_stage);
    status->error_code = snapshot.error_code;
    copy_text(status->message, snapshot.message);
    last_error.clear();
    return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
}

std::int32_t IM_CALL im_get_latest_video_timestamp(std::int64_t* timestamp_100ns) {
    if (!timestamp_100ns) {
        return fail(iPhoneMirror::Result::InvalidArgument, L"timestamp 不能为空");
    }
    std::scoped_lock lock(capture_mutex);
    *timestamp_100ns = capture_session ? capture_session->latest_frame_timestamp() : 0;
    last_error.clear();
    return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
}

std::int32_t IM_CALL im_copy_latest_video_frame(iPhoneMirror::VideoFrameInfo* info,
    std::uint8_t* buffer, std::uint32_t* buffer_size) {
    return copy_latest_frame_locked(info, buffer, buffer_size, 0, 0);
}

std::int32_t IM_CALL im_copy_latest_video_frame_scaled(
    iPhoneMirror::VideoFrameInfo* info, std::uint8_t* buffer,
    std::uint32_t* buffer_size, std::uint32_t max_width, std::uint32_t max_height) {
    return copy_latest_frame_locked(info, buffer, buffer_size, max_width, max_height);
}

// 预览宿主。上游 ABI 收的是"原生窗口句柄"，鸿蒙上这个句柄就是 XComponent 的
// surfaceId（NAPI 桥把字符串转成整数再当 void* 传下来），因此 ABI 声明不用改。
std::int32_t IM_CALL im_attach_preview_window(void* hwnd) {
    if (hwnd == nullptr) {
        return fail(iPhoneMirror::Result::InvalidArgument, L"surfaceId 句柄不能为空");
    }
    const auto surface_id = reinterpret_cast<std::uint64_t>(hwnd);
    auto& renderer = iPhoneMirror::media::OhosPreviewRenderer::instance();
    if (!renderer.attach(surface_id)) {
        return fail(iPhoneMirror::Result::CaptureBackendUnavailable,
            iPhoneMirror::text::utf8_to_wide(renderer.last_error()));
    }
    last_error.clear();
    return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
}

void IM_CALL im_detach_preview_window() {
    iPhoneMirror::media::OhosPreviewRenderer::instance().detach();
}

std::int32_t IM_CALL im_force_preview_refresh() {
    // 预览泵每 4 ms 取一次最新帧，不存在"需要单独请求一次重画"的场景。
    if (!iPhoneMirror::media::OhosPreviewRenderer::instance().attached()) {
        return fail(iPhoneMirror::Result::CaptureBackendUnavailable, L"尚未挂载预览 surface");
    }
    last_error.clear();
    return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
}

std::int32_t IM_CALL im_set_video_preferences(std::uint32_t max_width,
    std::uint32_t max_height, std::uint32_t max_fps) {
    // 与上游 im_set_video_preferences 对齐：先做参数校验，拒绝编组层把负数强转
    // 成的 UINT32_MAX 等非法值，避免其进入 set_target_fps。
    if (!valid_video_preferences(max_width, max_height, max_fps)) {
        return fail(iPhoneMirror::Result::InvalidArgument,
            L"本地渲染尺寸或帧率参数无效");
    }
    std::scoped_lock lock(capture_mutex);
    if (!capture_session) {
        return fail(iPhoneMirror::Result::CaptureBackendUnavailable, L"没有正在运行的采集会话");
    }
    if (max_fps != 0) capture_session->set_target_fps(max_fps);
    (void)max_width;
    (void)max_height;
    // 渲染尺寸上限由预览侧在 attach 时决定（XComponent 的尺寸即目标尺寸），
    // 这里只落实帧率上限，避免接受一个不会生效的尺寸参数。
    last_error.clear();
    return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
}

std::int32_t IM_CALL im_set_image_adjustments(float brightness, float contrast,
    float saturation, float gamma) {
    // GLES 预览着色器现在已接亮度/对比度/饱和度/gamma 通路，直接推给渲染器。
    iPhoneMirror::media::OhosPreviewRenderer::instance().set_image_adjustments(
        brightness, contrast, saturation, gamma);
    last_error.clear();
    return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
}

std::int32_t IM_CALL im_set_audio_enabled(std::int32_t enabled) {
    std::scoped_lock lock(capture_mutex);
    if (!capture_session) {
        return fail(iPhoneMirror::Result::CaptureBackendUnavailable, L"没有正在运行的采集会话");
    }
    capture_session->set_audio_enabled(enabled != 0);
    last_error.clear();
    return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
}

std::int32_t IM_CALL im_set_audio_volume(float volume) {
    std::scoped_lock lock(capture_mutex);
    if (!capture_session) {
        return fail(iPhoneMirror::Result::CaptureBackendUnavailable, L"没有正在运行的采集会话");
    }
    capture_session->set_audio_volume(volume);
    last_error.clear();
    return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
}

std::int32_t IM_CALL im_is_libusb0_device_available(const wchar_t*,
    std::int32_t* available) {
    if (!available) {
        return fail(iPhoneMirror::Result::InvalidArgument, L"available 不能为空");
    }
    // libusb0 是 Windows 的 libusb-win32 过滤后端；鸿蒙上与 Linux 一样不存在它，
    // 所以答案是确定的"否"，而不是一次失败。
    *available = 0;
    last_error.clear();
    return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
}

// ---- 多设备会话：共享状态机已经就绪，但"每会话一个句柄 + 独立预览挂载"的
//      句柄管理还没做，因此明确失败而不是返回一个不可用的句柄。
std::int32_t IM_CALL im_session_create(const wchar_t*,
    const iPhoneMirror::CaptureOptions*, iPhoneMirror::SessionHandle* handle) {
    if (handle) *handle = 0;
    return not_implemented(L"多设备有线采集会话", L"阶段 P2");
}

std::int32_t IM_CALL im_session_stop(iPhoneMirror::SessionHandle) {
    return not_implemented(L"多设备有线采集会话", L"阶段 P2");
}

void IM_CALL im_session_destroy(iPhoneMirror::SessionHandle) {}

std::int32_t IM_CALL im_session_get_status(iPhoneMirror::SessionHandle,
    iPhoneMirror::CaptureStatus*) {
    return not_implemented(L"会话状态查询", L"阶段 P2");
}

std::int32_t IM_CALL im_session_get_video_output_status(
    iPhoneMirror::SessionHandle, void*, iPhoneMirror::VideoOutputStatus*) {
    return not_implemented(L"视频输出诊断", L"阶段 P2");
}

std::int32_t IM_CALL im_session_attach_preview(iPhoneMirror::SessionHandle, void*) {
    return not_implemented(L"每会话预览挂载", L"阶段 P2");
}

void IM_CALL im_session_detach_preview(iPhoneMirror::SessionHandle, void*) {}

std::int32_t IM_CALL im_session_set_video_preferences(iPhoneMirror::SessionHandle,
    std::uint32_t, std::uint32_t, std::uint32_t) {
    return not_implemented(L"会话渲染偏好", L"阶段 P2");
}

std::int32_t IM_CALL im_session_set_image_adjustments(iPhoneMirror::SessionHandle,
    float, float, float, float) {
    return not_implemented(L"会话图像调节", L"阶段 P2");
}

std::int32_t IM_CALL im_session_set_pipeline_preferences(
    iPhoneMirror::SessionHandle, std::uint32_t, std::uint32_t) {
    return not_implemented(L"解码/色彩策略", L"阶段 P2");
}

std::int32_t IM_CALL im_session_set_audio_enabled(iPhoneMirror::SessionHandle,
    std::int32_t) {
    return not_implemented(L"会话音频开关", L"阶段 P2");
}

std::int32_t IM_CALL im_session_set_audio_volume(iPhoneMirror::SessionHandle, float) {
    return not_implemented(L"会话音量", L"阶段 P2");
}

std::int32_t IM_CALL im_session_set_corner_profile(iPhoneMirror::SessionHandle,
    float, float) {
    return not_implemented(L"圆角裁剪", L"阶段 P2");
}

std::int32_t IM_CALL im_session_get_latest_video_timestamp(
    iPhoneMirror::SessionHandle, std::int64_t*) {
    return not_implemented(L"会话视频时间戳", L"阶段 P2");
}

std::int32_t IM_CALL im_session_copy_latest_video_frame(iPhoneMirror::SessionHandle,
    iPhoneMirror::VideoFrameInfo*, std::uint8_t*, std::uint32_t*,
    std::uint32_t, std::uint32_t) {
    return not_implemented(L"会话视频帧拷贝", L"阶段 P2");
}

std::int32_t IM_CALL im_session_copy_latest_video_frame_nv12(
    iPhoneMirror::SessionHandle, iPhoneMirror::VideoFrameInfo*, std::uint8_t*,
    std::uint32_t*, std::uint32_t, std::uint32_t) {
    return not_implemented(L"NV12 帧拷贝", L"阶段 P2");
}

std::int32_t IM_CALL im_session_copy_next_audio_packet(iPhoneMirror::SessionHandle,
    std::uint64_t, iPhoneMirror::AudioPacketInfo*, std::uint8_t*, std::uint32_t*) {
    return not_implemented(L"PCM 包拷贝", L"阶段 P2");
}

std::int32_t IM_CALL im_session_force_preview_refresh(iPhoneMirror::SessionHandle) {
    return not_implemented(L"会话预览刷新", L"阶段 P2");
}

std::int32_t IM_CALL im_session_set_window_corner_profile(
    iPhoneMirror::SessionHandle, void*, float normalized_radius, float curve_exponent) {
    // 鸿蒙侧只有一个全局预览窗口，圆角直接推给该预览渲染器。
    iPhoneMirror::media::OhosPreviewRenderer::instance().set_corner_profile(
        normalized_radius, curve_exponent);
    last_error.clear();
    return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
}

std::int32_t IM_CALL im_session_set_window_rotation(iPhoneMirror::SessionHandle,
    void*, std::int32_t quarter_turns) {
    // 鸿蒙侧只有一个全局预览窗口，旋转直接推给该预览渲染器。
    iPhoneMirror::media::OhosPreviewRenderer::instance().set_rotation(quarter_turns);
    last_error.clear();
    return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
}

std::int32_t IM_CALL im_set_preview_corner_profile(float normalized_radius,
    float curve_exponent) {
    iPhoneMirror::media::OhosPreviewRenderer::instance().set_corner_profile(
        normalized_radius, curve_exponent);
    last_error.clear();
    return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
}

// ---- AirPlay / URL 视频接收端：上游 Windows 侧是内置的 AirPlayServer 运行时，
//      Linux 侧改用 UxPlay 源码，鸿蒙这一侧两者都没有落地。
std::int32_t IM_CALL im_wireless_receiver_start(const wchar_t*, const wchar_t*) {
    return not_implemented(L"AirPlay 接收端", L"阶段 P3（需随包移植 UxPlay）");
}

std::int32_t IM_CALL im_wireless_receiver_start_ex(const wchar_t*, const wchar_t*,
    std::uint32_t, std::uint32_t, std::uint32_t) {
    return not_implemented(L"AirPlay 接收端", L"阶段 P3（需随包移植 UxPlay）");
}

void IM_CALL im_wireless_receiver_stop() {}

std::int32_t IM_CALL im_wireless_receiver_get_status(std::int32_t* running,
    std::int32_t* ready) {
    if (running) *running = 0;
    if (ready) *ready = 0;
    last_error.clear();
    return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
}

std::int32_t IM_CALL im_refresh_wireless_devices(iPhoneMirror::DeviceInfo*,
    std::uint32_t* count) {
    // 没有接收端在跑，空列表就是正确答案。
    if (!count) {
        return fail(iPhoneMirror::Result::InvalidArgument, L"count 不能为空");
    }
    *count = 0;
    last_error.clear();
    return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
}

std::int32_t IM_CALL im_wireless_session_create(const wchar_t*,
    const iPhoneMirror::CaptureOptions*, iPhoneMirror::SessionHandle* handle) {
    if (handle) *handle = 0;
    return not_implemented(L"AirPlay 采集会话", L"阶段 P3");
}

std::int32_t IM_CALL im_media_cast_receiver_start(const wchar_t*, const wchar_t*) {
    return not_implemented(L"URL 视频接收端", L"阶段 P3");
}

void IM_CALL im_media_cast_receiver_stop() {}

std::int32_t IM_CALL im_media_cast_receiver_get_status(std::int32_t* running,
    std::int32_t* ready) {
    if (running) *running = 0;
    if (ready) *ready = 0;
    last_error.clear();
    return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
}

std::int32_t IM_CALL im_media_cast_get_request(iPhoneMirror::MediaCastRequest*) {
    return not_implemented(L"URL 视频请求", L"阶段 P3");
}

std::int32_t IM_CALL im_media_cast_set_playback_state(std::uint64_t, double,
    double, double) {
    return not_implemented(L"URL 视频播放状态", L"阶段 P3");
}

std::int32_t IM_CALL im_media_cast_request_stop() {
    return not_implemented(L"URL 视频停止", L"阶段 P3");
}

namespace iPhoneMirror::ohos_bridge {

std::shared_ptr<const media::DecodedFrame> latest_render_frame() {
    std::scoped_lock lock(capture_mutex);
    return capture_session ? capture_session->next_render_frame() : nullptr;
}

void notify_frame_available() {
    {
        // 见 capture_frame_mutex 的注释：这里**只能**用这把独立的锁，
        // 拿 capture_mutex 会和 im_stop_capture 的"持锁析构解码器"互等。
        std::scoped_lock lock(capture_frame_mutex);
        capture_frame_available = true;
    }
    capture_frame_cv.notify_one();
}

bool wait_frame_available(std::chrono::milliseconds timeout) {
    std::unique_lock<std::mutex> lock(capture_frame_mutex);
    capture_frame_cv.wait_for(lock, timeout, [] { return capture_frame_available; });
    if (capture_frame_available) {
        capture_frame_available = false;
        return true;
    }
    return false;
}

} // namespace iPhoneMirror::ohos_bridge

namespace {
std::mutex input_bridge_mutex;
std::unique_ptr<iPhoneMirror::ohos::OhosInputBridge> input_bridge;
}

std::int32_t IM_CALL im_start_reverse_control(const wchar_t* udid) {
    if (udid == nullptr || *udid == L'\0') {
        return fail(iPhoneMirror::Result::InvalidArgument, L"udid 不能为空");
    }
    std::scoped_lock lock(input_bridge_mutex);
    if (input_bridge) {
        return fail(iPhoneMirror::Result::SessionAlreadyExists, L"反向控制通道已在运行");
    }
    input_bridge = std::make_unique<iPhoneMirror::ohos::OhosInputBridge>();
    const auto result = input_bridge->start(udid);
    if (result != static_cast<std::int32_t>(iPhoneMirror::Result::Ok)) {
        input_bridge.reset();
    }
    return result;
}

std::int32_t IM_CALL im_stop_reverse_control() {
    std::scoped_lock lock(input_bridge_mutex);
    if (!input_bridge) {
        return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
    }
    const auto result = input_bridge->stop();
    input_bridge.reset();
    return result;
}

std::int32_t IM_CALL im_get_reverse_control_status(iPhoneMirror::ReverseControlStatus* status) {
    if (status == nullptr) {
        return fail(iPhoneMirror::Result::InvalidArgument, L"status 不能为空");
    }
    if (status->struct_size != sizeof(iPhoneMirror::ReverseControlStatus)) {
        return fail(iPhoneMirror::Result::InvalidArgument, L"ReverseControlStatus 结构版本不匹配");
    }
    std::scoped_lock lock(input_bridge_mutex);
    if (!input_bridge) {
        status->api_version = iPhoneMirror::ApiVersion;
        status->state = static_cast<std::int32_t>(iPhoneMirror::ReverseControlState::Idle);
        status->lastErrorCode[0] = L'\0';
        status->lastErrorMessage[0] = L'\0';
        return static_cast<std::int32_t>(iPhoneMirror::Result::Ok);
    }
    return input_bridge->getStatus(status);
}

std::int32_t IM_CALL im_send_touch(const iPhoneMirror::TouchPoint* points, std::uint32_t count) {
    if (points == nullptr || count == 0 || count > iPhoneMirror::MaxTouchSlots) {
        return fail(iPhoneMirror::Result::InvalidArgument, L"触摸参数无效");
    }
    std::scoped_lock lock(input_bridge_mutex);
    if (!input_bridge) {
        return static_cast<std::int32_t>(iPhoneMirror::Result::CaptureBackendUnavailable);
    }
    return input_bridge->sendTouch(points, count);
}

std::int32_t IM_CALL im_send_keyboard(const std::uint8_t* usages, std::uint32_t count,
    std::int32_t release_all) {
    // ★ release_all 的语义是"松开所有键"，此时根本没有 usage 数组可传。但
    //   判据不能写成 `usages == nullptr && release_all == 0`：那样
    //   `nullptr + release_all != 0` 会被放行，而 count 仍可以是任意值，
    //   一路传到 formatKeyboardBatch 的 `usages[i]` 就是空指针解引用。
    //   正确的判据是"没给数组 ⇒ count 必须是 0"。
    if (usages == nullptr && count != 0) {
        return fail(iPhoneMirror::Result::InvalidArgument, L"键盘参数无效");
    }
    if (count > iPhoneMirror::MaxKeyboardUsages) {
        return fail(iPhoneMirror::Result::InvalidArgument, L"键盘 usage 数量超限");
    }
    std::scoped_lock lock(input_bridge_mutex);
    if (!input_bridge) {
        return static_cast<std::int32_t>(iPhoneMirror::Result::CaptureBackendUnavailable);
    }
    return input_bridge->sendKeyboard(usages, count, release_all);
}

std::int32_t IM_CALL im_send_button(std::uint16_t usage_page, std::uint16_t usage_code,
    const char* state) {
    if (state == nullptr) {
        return fail(iPhoneMirror::Result::InvalidArgument, L"按钮状态不能为空");
    }
    std::scoped_lock lock(input_bridge_mutex);
    if (!input_bridge) {
        return static_cast<std::int32_t>(iPhoneMirror::Result::CaptureBackendUnavailable);
    }
    return input_bridge->sendButton(usage_page, usage_code, state);
}
