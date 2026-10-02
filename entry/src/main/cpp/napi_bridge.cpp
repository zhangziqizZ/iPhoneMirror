// SPDX-License-Identifier: GPL-3.0-only
//
// napi_bridge.cpp —— ArkTS（XComponent）↔ iPhoneMirror Core 的 NAPI 桥。
//
// 这一层是**鸿蒙独有的新增文件**：上游 Windows 版的壳是 WPF/Avalonia 直接
// P/Invoke CoreApi.h 的 C ABI，Linux 版另有一个 LinuxPreviewApi.h 把渲染结果
// 导出成 Vulkan 镜像给 Avalonia 导入；鸿蒙上壳是 ArkTS，所以需要一段 NAPI。
//
// 三条纪律：
//  1) 桥只做"翻译"，不掺业务。所有判断都在 C ABI 里，桥不替它决定成功与否。
//  2) wchar_t 编组必须走 Text/Utf.h 的 utf8_to_wide / wide_to_utf8。
//     ABI 是 wide 的（上游 D2 决策：Linux 与鸿蒙的 wchar_t 都是 4 字节，
//     所以宽字符 ABI 原样保留），而 NAPI 的字符串是 UTF-8。
//     直接把 char* 递给 const wchar_t* 参数是编译错误，不是警告。
//  3) 缓冲长度按 NAPI 的约定算：napi_get_value_string_utf8 写入 len + 1 字节
//     （含结尾 NUL），所以 std::string 必须留出那一个字节。
//
// 预览 surface：上游 ABI 的入口是 im_attach_preview_window(void* hwnd)，
// 语义为"一个可供渲染的原生窗口句柄"。鸿蒙上该句柄就是 XComponent 的
// surfaceId（getXComponentSurfaceId() 返回的十进制字符串），转成 uint64
// 再当 void* 传下去，因此 CoreApi.h 的声明一个字都不用改。

#include "iPhoneMirror/CoreApi.h"
#include "Text/Utf.h"

// AirPlay 接收端（鸿蒙宿主）与它的 mDNS 待办队列。
#include "im_dnssd_queue.h"
#include "ohos/OhosAirPlayReceiver.h"
#include "ohos/OhosVideoDecoder.h"
#include "ohos/OhosPreviewRenderer.h"
// 有线链路的诊断尾巴（C ABI 定义在 ohos/OhosUsbTransport.cpp）。
#include "ohos/OhosUsbDiagnostics.h"

#include "napi/native_api.h"

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

using iPhoneMirror::text::utf8_to_wide;
using iPhoneMirror::text::wide_to_utf8;
using iPhoneMirror::media::im_video_decoder_diag;

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

void set_utf8(napi_env env, napi_value object, const char* key,
    const char* value) {
    napi_value out = nullptr;
    napi_create_string_utf8(env, value != nullptr ? value : "",
        NAPI_AUTO_LENGTH, &out);
    napi_set_named_property(env, object, key, out);
}

void set_u32(napi_env env, napi_value object, const char* key,
    std::uint32_t value) {
    napi_value out = nullptr;
    napi_create_uint32(env, value, &out);
    napi_set_named_property(env, object, key, out);
}

void set_i32(napi_env env, napi_value object, const char* key,
    std::int32_t value) {
    napi_value out = nullptr;
    napi_create_int32(env, value, &out);
    napi_set_named_property(env, object, key, out);
}

void set_f64(napi_env env, napi_value object, const char* key, double value) {
    napi_value out = nullptr;
    napi_create_double(env, value, &out);
    napi_set_named_property(env, object, key, out);
}

napi_value int32_result(napi_env env, std::int32_t value) {
    napi_value out = nullptr;
    napi_create_int32(env, value, &out);
    return out;
}

// 取第 0 个字符串参数；失败时返回 false 而不是抛异常，让调用点自己决定
// 报 InvalidArgument 还是别的。
bool value_string(napi_env env, napi_value value, std::string& out) {
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_string) {
        return false;
    }
    std::size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
        return false;
    }
    // NAPI 会写 length + 1 个字节（含结尾 NUL），缓冲区必须够。
    out.assign(length + 1, '\0');
    std::size_t written = 0;
    if (napi_get_value_string_utf8(env, value, out.data(), out.size(),
            &written) != napi_ok) {
        return false;
    }
    out.resize(written);
    return true;
}

bool arg_string(napi_env env, napi_callback_info info, std::string& out) {
    std::size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
        argc < 1) {
        return false;
    }
    return value_string(env, args[0], out);
}

// 从 ArkTS 对象里读一个数字字段。字段缺失或类型不对都返回 false，由调用点报
// InvalidArgument —— 不按 0 处理：那会把"调用方忘了传"变成"调用方传了 0"。
bool object_number(napi_env env, napi_value object, const char* key,
    double& out) {
    napi_value value = nullptr;
    if (napi_get_named_property(env, object, key, &value) != napi_ok) {
        return false;
    }
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_number) {
        return false;
    }
    return napi_get_value_double(env, value, &out) == napi_ok;
}

// 同上，但要求非负整数（宽度 / 尺寸 / 枚举值）。负数与 NaN 一律拒绝。
bool object_u32(napi_env env, napi_value object, const char* key,
    std::uint32_t& out) {
    double value = 0.0;
    if (!object_number(env, object, key, value)) {
        return false;
    }
    if (!(value >= 0.0)) {
        return false;
    }
    out = static_cast<std::uint32_t>(value);
    return true;
}

// 取前 expected 个参数；不足返回 false。
bool args_get(napi_env env, napi_callback_info info, std::size_t expected,
    napi_value* out) {
    std::size_t argc = expected;
    if (napi_get_cb_info(env, info, &argc, out, nullptr, nullptr) != napi_ok ||
        argc < expected) {
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// 生命周期 / 版本
// ---------------------------------------------------------------------------

napi_value JsInitialize(napi_env env, napi_callback_info /*info*/) {
    return int32_result(env, im_initialize());
}

napi_value JsShutdown(napi_env env, napi_callback_info /*info*/) {
    im_shutdown();
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value JsApiVersion(napi_env env, napi_callback_info /*info*/) {
    napi_value out = nullptr;
    napi_create_uint32(env, im_api_version(), &out);
    return out;
}

napi_value JsLastError(napi_env env, napi_callback_info /*info*/) {
    const wchar_t* message = im_last_error();
    const std::string utf8 = message != nullptr ? wide_to_utf8(message) : "";
    napi_value out = nullptr;
    napi_create_string_utf8(env, utf8.c_str(), NAPI_AUTO_LENGTH, &out);
    return out;
}

// 有线（USB）链路最近几步的原话，按时间顺序拼成一行。
//
// 为什么不让界面去读日志文件：Core 的日志落在应用沙箱里，进程外读不到，用户也
// 打不开。有线采集失败时，屏幕上只有一句概括性的异常文案，而这串记录里是
// 「认领接口成没成 / 0x52 返回什么 / 重枚举后有没有 0x2A 接口 / 端点是多少」。
// 没有记录时返回空串，界面据此决定显不显示这一行（不假成功）。
napi_value JsUsbDiagnostics(napi_env env, napi_callback_info /*info*/) {
    const char* text = im_usb_diagnostics();
    napi_value out = nullptr;
    napi_create_string_utf8(env, text != nullptr ? text : "",
        NAPI_AUTO_LENGTH, &out);
    return out;
}

// 环境诊断：DDK 能不能用、看得到几台 Apple 设备、usbmux 在不在。
//
// 为什么必须补这条桥：im_get_environment 在鸿蒙侧**已经真做事**
// （OhosCoreApi.cpp → OhosDeviceManager → ohos_probe::probe()），它给出的
// diagnostic 里写着三种截然不同的结论——
//   · "USB DDK 可用，可见 N 台 Apple 设备"（正常）
//   · "USB DDK 可用但看不到 Apple 设备：驱动配置信息里需要包含 VID 0x05AC"
//     （缺扩展外设驱动声明，见 module.json5 的 extensionAbilities）
//   · "USB DDK 初始化失败：…"（多半是 ACCESS_DDK_USB 没在签名 profile 的
//     allowed-acls 里放行，OH_Usb_Init 返回 201）
// 但此前**没有任何 NAPI 把它带出来**，界面上只剩"未发现设备"一句，用户和开发者
// 都只能猜。三者的处置方式完全不同，所以这里把原话如实交给界面。
napi_value JsGetEnvironment(napi_env env, napi_callback_info /*info*/) {
    iPhoneMirror::EnvironmentInfo info{};
    info.struct_size = sizeof(iPhoneMirror::EnvironmentInfo);
    info.api_version = iPhoneMirror::ApiVersion;
    const std::int32_t status = im_get_environment(&info);

    napi_value object = nullptr;
    napi_create_object(env, &object);
    set_i32(env, object, "status", status);
    // 失败时 diagnostic 是空的（im_get_environment 只在成功路径上填它），
    // 界面据此显示 lastError()，不把空串当成"没有问题"。
    // 先落到具名变量再取 c_str()：避免在实参位置构造临时对象，
    // 那种写法虽然在本条语句内是有效的，却容易被后来者误读成悬垂指针。
    const std::string diagnostic =
        status == 0 ? wide_to_utf8(info.diagnostic) : std::string();
    set_utf8(env, object, "diagnostic", diagnostic.c_str());
    set_u32(env, object, "appleDevices", info.physical_apple_usb_devices);
    set_i32(env, object, "serviceInstalled",
        info.apple_mobile_device_service_installed);
    set_i32(env, object, "serviceRunning",
        info.apple_mobile_device_service_running);
    set_i32(env, object, "standardUsbmuxAvailable",
        info.standard_usbmux_available);
    return object;
}

// ---------------------------------------------------------------------------
// 设备
// ---------------------------------------------------------------------------

// 返回 [{ udid, name, productType, osVersion, state, connectionType, status,
//         usbConnected, deviceId, muxPort }, ...]
//
// im_refresh_devices 的语义：*count 进为容量、出为实际台数；devices 传 null
// 是只查数量。这里先做一次数量查询再按需要分配，避免固定上限把列表截断。
//
// 失败时返回**空数组**而不是 Result 码：ArkTS 严格模式不喜欢联合返回类型，
// 而且"一台都没发现"与"查询失败"的区分由 lastError() 负责——C ABI 失败时
// 已经写了 last_error，桥不重复一遍。
napi_value JsRefreshDevices(napi_env env, napi_callback_info /*info*/) {
    napi_value array = nullptr;

    std::uint32_t count = 0;
    std::int32_t status = im_refresh_devices(nullptr, &count);
    if (status != static_cast<std::int32_t>(iPhoneMirror::Result::Ok)) {
        napi_create_array_with_length(env, 0, &array);
        return array;
    }

    std::vector<iPhoneMirror::DeviceInfo> devices(count);
    if (count > 0) {
        std::uint32_t capacity = count;
        status = im_refresh_devices(devices.data(), &capacity);
        if (status != static_cast<std::int32_t>(iPhoneMirror::Result::Ok)) {
            napi_create_array_with_length(env, 0, &array);
            return array;
        }
        count = capacity; // 出参才是实际台数
    }

    napi_create_array_with_length(env, count, &array);
    for (std::uint32_t i = 0; i < count; ++i) {
        const auto& device = devices[i];
        const std::string udid = wide_to_utf8(device.udid);
        const std::string name = wide_to_utf8(device.name);
        const std::string product_type = wide_to_utf8(device.product_type);
        const std::string os_version = wide_to_utf8(device.os_version);
        const std::string connection_type = wide_to_utf8(device.connection_type);
        const std::string device_status = wide_to_utf8(device.status);

        napi_value object = nullptr;
        napi_create_object(env, &object);
        set_utf8(env, object, "udid", udid.c_str());
        set_utf8(env, object, "name", name.c_str());
        set_utf8(env, object, "productType", product_type.c_str());
        set_utf8(env, object, "osVersion", os_version.c_str());
        set_utf8(env, object, "connectionType", connection_type.c_str());
        set_utf8(env, object, "status", device_status.c_str());
        set_u32(env, object, "state", static_cast<std::uint32_t>(device.state));
        set_u32(env, object, "deviceId", device.device_id);
        set_u32(env, object, "muxPort", device.mux_port);
        set_u32(env, object, "usbConnected",
            static_cast<std::uint32_t>(device.usb_connected));
        napi_set_element(env, array, i, object);
    }
    return array;
}

// ---------------------------------------------------------------------------
// 采集
// ---------------------------------------------------------------------------

napi_value JsStartCapture(napi_env env, napi_callback_info info) {
    std::string udid;
    if (!arg_string(env, info, udid)) {
        return int32_result(env,
            static_cast<std::int32_t>(iPhoneMirror::Result::InvalidArgument));
    }
    const std::wstring wide = utf8_to_wide(udid);
    return int32_result(env, im_start_capture(wide.c_str()));
}

// ArkTS: startCaptureWithOptions(udid, options)
//
// 走 im_start_capture_with_options 而不是 im_start_capture：有线投屏模式（演示 /
// AirPlay / 爱思）、解码器偏好、色彩输出偏好这三项在 C ABI 里**只有这一条入口**
// （CaptureOptions.reserved[2..4]），没有任何对应的 setter。
//
// 副作用要记住：这条会把 Core 里的采集偏好**整份替换**（CoreApi.cpp:983 的
// preferences_from_options），不会与上一次的设置合并 —— 所以 ArkTS 侧必须把当前
// 所有设置都带齐，缺字段这里就报 InvalidArgument 而不是悄悄补 0。
napi_value JsStartCaptureWithOptions(napi_env env, napi_callback_info info) {
    const std::int32_t invalid =
        static_cast<std::int32_t>(iPhoneMirror::Result::InvalidArgument);
    std::size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
        argc < 2) {
        return int32_result(env, invalid);
    }
    std::string udid;
    if (!value_string(env, args[0], udid)) {
        return int32_result(env, invalid);
    }

    iPhoneMirror::CaptureOptions options{};
    options.struct_size = sizeof(iPhoneMirror::CaptureOptions);
    options.api_version = iPhoneMirror::ApiVersion;
    double volume = 0.0;
    std::uint32_t play_audio = 1;
    std::uint32_t advanced_width = 0;
    std::uint32_t advanced_height = 0;
    if (!object_u32(env, args[1], "requestedWidth", options.requested_width) ||
        !object_u32(env, args[1], "requestedHeight", options.requested_height) ||
        !object_u32(env, args[1], "targetFps", options.target_fps) ||
        !object_u32(env, args[1], "playAudio", play_audio) ||
        !object_number(env, args[1], "audioVolume", volume) ||
        !object_u32(env, args[1], "usbWidth", advanced_width) ||
        !object_u32(env, args[1], "usbHeight", advanced_height) ||
        !object_u32(env, args[1], "usbProjectionMode", options.reserved[2]) ||
        !object_u32(env, args[1], "decoderPreference", options.reserved[3]) ||
        !object_u32(env, args[1], "colorOutputPreference", options.reserved[4])) {
        return int32_result(env, invalid);
    }
    options.play_audio = play_audio != 0 ? 1 : 0;
    options.audio_volume = static_cast<float>(volume);
    // 高级模式的自定义 HPD1 尺寸；0/0 = 不使用（C ABI 要求两者同为 0 或同为有效值）。
    options.reserved[0] = advanced_width;
    options.reserved[1] = advanced_height;

    const std::wstring wide = utf8_to_wide(udid);
    return int32_result(env, im_start_capture_with_options(wide.c_str(), &options));
}

napi_value JsStopCapture(napi_env env, napi_callback_info /*info*/) {
    return int32_result(env, im_stop_capture());
}

// 返回 { state, width, height, fps, latencyMs, videoFrames, audioPackets,
//        message }。state 与 ABI 的 CaptureState 同值（Idle=0 …
//        Streaming=4 … Error=7），C ABI 失败时返回 { state: -1, message }。
napi_value JsGetCaptureStatus(napi_env env, napi_callback_info /*info*/) {
    iPhoneMirror::CaptureStatus status{};
    const std::int32_t result = im_get_capture_status(&status);
    const std::string message = wide_to_utf8(status.message);

    napi_value object = nullptr;
    napi_create_object(env, &object);
    if (result != static_cast<std::int32_t>(iPhoneMirror::Result::Ok)) {
        // 状态查询本身失败：如实给一个 -1，而不是伪造 Idle。
        napi_value state = nullptr;
        napi_create_int32(env, -1, &state);
        napi_set_named_property(env, object, "state", state);
        set_utf8(env, object, "message", message.c_str());
        return object;
    }
    set_u32(env, object, "state", static_cast<std::uint32_t>(status.state));
    set_u32(env, object, "width", status.width);
    set_u32(env, object, "height", status.height);
    set_f64(env, object, "fps", status.fps);
    set_f64(env, object, "latencyMs", status.latency_ms);
    set_f64(env, object, "videoFrames",
        static_cast<double>(status.video_frames));
    set_f64(env, object, "audioPackets",
        static_cast<double>(status.audio_packets));
    set_utf8(env, object, "message", message.c_str());
    return object;
}

// ---------------------------------------------------------------------------
// 预览
// ---------------------------------------------------------------------------

// ArkTS: attachPreview(surfaceId) —— surfaceId 来自
// XComponentController.getXComponentSurfaceId()，是十进制字符串。
napi_value JsAttachPreview(napi_env env, napi_callback_info info) {
    std::string surface_id;
    if (!arg_string(env, info, surface_id)) {
        return int32_result(env,
            static_cast<std::int32_t>(iPhoneMirror::Result::InvalidArgument));
    }
    const std::uint64_t id = std::strtoull(surface_id.c_str(), nullptr, 10);
    if (id == 0) {
        return int32_result(env,
            static_cast<std::int32_t>(iPhoneMirror::Result::InvalidArgument));
    }
    return int32_result(env,
        im_attach_preview_window(reinterpret_cast<void*>(id)));
}

napi_value JsDetachPreview(napi_env env, napi_callback_info /*info*/) {
    im_detach_preview_window();
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ArkTS: forcePreviewRefresh() —— 工具条「刷新画面」。
// 返回 ABI 的真实结果码（0 = Ok；未挂载 surface 时返回非 0，错误串用 lastError() 取）。
// 为什么要真调一次：以前 ArkTS 侧只写一句"预览渲染器已刷新"，不论渲染器死活都报成功。
napi_value JsForcePreviewRefresh(napi_env env, napi_callback_info /*info*/) {
    return int32_result(env, im_force_preview_refresh());
}

// ---------------------------------------------------------------------------
// 音频
// ---------------------------------------------------------------------------

napi_value JsSetAudioEnabled(napi_env env, napi_callback_info info) {
    std::size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
        argc < 1) {
        return int32_result(env,
            static_cast<std::int32_t>(iPhoneMirror::Result::InvalidArgument));
    }
    bool enabled = false;
    if (napi_get_value_bool(env, args[0], &enabled) != napi_ok) {
        return int32_result(env,
            static_cast<std::int32_t>(iPhoneMirror::Result::InvalidArgument));
    }
    return int32_result(env, im_set_audio_enabled(enabled ? 1 : 0));
}

napi_value JsSetAudioVolume(napi_env env, napi_callback_info info) {
    std::size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
        argc < 1) {
        return int32_result(env,
            static_cast<std::int32_t>(iPhoneMirror::Result::InvalidArgument));
    }
    double volume = 0.0;
    if (napi_get_value_double(env, args[0], &volume) != napi_ok) {
        return int32_result(env,
            static_cast<std::int32_t>(iPhoneMirror::Result::InvalidArgument));
    }
    return int32_result(env, im_set_audio_volume(static_cast<float>(volume)));
}

// ArkTS: setVideoPreferences(maxWidth, maxHeight, maxFps)
//
// 只改本地渲染尺寸与帧率上限。与 startCaptureWithOptions 不同，这条对**正在
// 进行的会话立即生效**（CoreApi.cpp:1303：会同时改会话 target fps 与预览渲染器
// 的上限），所以界面上的「应用画面设置」用它 —— 与上游 ApplyVideoSettings 的
// 语义一致（会话活着就立即应用，否则留给下次开始采集）。
napi_value JsSetVideoPreferences(napi_env env, napi_callback_info info) {
    std::size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
        argc < 3) {
        return int32_result(env,
            static_cast<std::int32_t>(iPhoneMirror::Result::InvalidArgument));
    }
    std::uint32_t values[3] = {0, 0, 0};
    for (std::size_t i = 0; i < 3; ++i) {
        double value = 0.0;
        if (napi_get_value_double(env, args[i], &value) != napi_ok) {
            return int32_result(env,
                static_cast<std::int32_t>(iPhoneMirror::Result::InvalidArgument));
        }
        // 负数与 NaN 交给 C ABI 的 valid_video_preferences 判，不在这里猜。
        values[i] = value >= 0.0 ? static_cast<std::uint32_t>(value) : UINT32_MAX;
    }
    return int32_result(env,
        im_set_video_preferences(values[0], values[1], values[2]));
}

// ArkTS: setImageAdjustments(brightness, contrast, saturation, gamma)
napi_value JsSetImageAdjustments(napi_env env, napi_callback_info info) {
    std::size_t argc = 4;
    napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
        argc < 4) {
        return int32_result(env,
            static_cast<std::int32_t>(iPhoneMirror::Result::InvalidArgument));
    }
    float values[4] = {0.0F, 0.0F, 0.0F, 0.0F};
    for (std::size_t i = 0; i < 4; ++i) {
        double v = 0.0;
        if (napi_get_value_double(env, args[i], &v) != napi_ok) {
            return int32_result(env,
                static_cast<std::int32_t>(iPhoneMirror::Result::InvalidArgument));
        }
        values[i] = static_cast<float>(v);
    }
    return int32_result(env,
        im_set_image_adjustments(values[0], values[1], values[2], values[3]));
}

// ArkTS: setPreviewCornerProfile(normalizedRadius, curveExponent)
napi_value JsSetPreviewCornerProfile(napi_env env, napi_callback_info info) {
    std::size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
        argc < 2) {
        return int32_result(env,
            static_cast<std::int32_t>(iPhoneMirror::Result::InvalidArgument));
    }
    double radius = 0.0;
    double exponent = 0.0;
    if (napi_get_value_double(env, args[0], &radius) != napi_ok ||
        napi_get_value_double(env, args[1], &exponent) != napi_ok) {
        return int32_result(env,
            static_cast<std::int32_t>(iPhoneMirror::Result::InvalidArgument));
    }
    return int32_result(env, im_set_preview_corner_profile(
        static_cast<float>(radius), static_cast<float>(exponent)));
}

// ArkTS: setWindowRotation(quarterTurns) —— 鸿蒙只有一个全局预览窗口，旋转直接走它。
napi_value JsSetWindowRotation(napi_env env, napi_callback_info info) {
    std::size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
        argc < 1) {
        return int32_result(env,
            static_cast<std::int32_t>(iPhoneMirror::Result::InvalidArgument));
    }
    std::int32_t turns = 0;
    if (napi_get_value_int32(env, args[0], &turns) != napi_ok) {
        return int32_result(env,
            static_cast<std::int32_t>(iPhoneMirror::Result::InvalidArgument));
    }
    return int32_result(env, im_session_set_window_rotation(0, nullptr, turns));
}

// ---------------------------------------------------------------------------
// AirPlay 接收端 + mDNS 广播
// ---------------------------------------------------------------------------
//
// 这一组接口与 Core 的 USB 采集链路是**两条独立的路**：Core（CoreApi.h）
// 目前对无线只返回 not_implemented，所以无线由本文件的宿主直接驱动 vendored
// 协议库（third_party/airplayserver），不经过 Core。
//
// mDNS 为什么要"取走—广播—回报"三步：
//   库在 raop_start()/airplay_start() 之后同步调用 dnssd_register_*()，
//   而鸿蒙 @ohos.net.mdns 的 addLocalService() 是异步 Promise，在同步 NAPI
//   调用里没法 await。所以原生侧只负责把"要广播的服务"排进队列，ArkTS 在
//   事件循环里取走、真正广播、再把成败回报回来（airplayReportService）。
//   只有回报成功才算 mdns_registered，失败会记进 lastError —— 不假成功。

napi_value JsAirPlayStart(napi_env env, napi_callback_info info) {
    napi_value args[2] = {nullptr, nullptr};
    if (!args_get(env, info, 2, args)) {
        return int32_result(env,
            static_cast<std::int32_t>(iPhoneMirror::Result::InvalidArgument));
    }
    std::string name;
    std::string password;
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, args[0], &type) == napi_ok && type == napi_string) {
        std::size_t length = 0;
        if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &length) ==
            napi_ok) {
            name.assign(length + 1, '\0');
            std::size_t written = 0;
            napi_get_value_string_utf8(env, args[0], name.data(), name.size(),
                &written);
            name.resize(written);
        }
    }
    if (napi_typeof(env, args[1], &type) == napi_ok && type == napi_string) {
        std::size_t length = 0;
        if (napi_get_value_string_utf8(env, args[1], nullptr, 0, &length) ==
            napi_ok) {
            password.assign(length + 1, '\0');
            std::size_t written = 0;
            napi_get_value_string_utf8(env, args[1], password.data(),
                password.size(), &written);
            password.resize(written);
        }
    }
    return int32_result(env, im_airplay_start(name.c_str(), password.c_str()));
}

napi_value JsAirPlayStop(napi_env env, napi_callback_info /*info*/) {
    im_airplay_stop();
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// 返回 { running, raopPort, airplayPort, mdnsPending, mdnsRegistered,
//        mdnsFailed, mdnsPendingRemoval, mdnsActive, mdnsAnswered, mdnsLocalIp,
//        mdnsError, mdnsDroppedSelf, mdnsAnnounceSent, mdnsAnnounceFailed,
//        mdnsOutIface, mdnsLastFrom, mdnsLastAnswerIp, mdnsLastQuery,
//        mdnsQueryCounts, mdnsServices, audioPackets, videoFrames, clients,
//        name, hwaddr, lastError, lastLog }
napi_value JsAirPlayGetStatus(napi_env env, napi_callback_info /*info*/) {
    ImAirPlayStats stats{};
    im_airplay_get_stats(&stats);

    napi_value object = nullptr;
    napi_create_object(env, &object);
    napi_value running = nullptr;
    napi_create_int32(env, stats.running, &running);
    napi_set_named_property(env, object, "running", running);
    set_u32(env, object, "raopPort", static_cast<std::uint32_t>(stats.raop_port));
    set_u32(env, object, "airplayPort",
        static_cast<std::uint32_t>(stats.airplay_port));
    set_u32(env, object, "mdnsPending",
        static_cast<std::uint32_t>(stats.mdns_pending));
    set_u32(env, object, "mdnsRegistered",
        static_cast<std::uint32_t>(stats.mdns_registered));
    set_u32(env, object, "mdnsFailed",
        static_cast<std::uint32_t>(stats.mdns_failed));
    set_u32(env, object, "mdnsPendingRemoval",
        static_cast<std::uint32_t>(stats.mdns_pending_removal));
    set_u32(env, object, "mdnsActive",
        static_cast<std::uint32_t>(stats.mdns_active));
    set_f64(env, object, "mdnsAnswered",
        static_cast<double>(stats.mdns_answered));
    set_utf8(env, object, "mdnsLocalIp", stats.mdns_local_ip);
    set_utf8(env, object, "mdnsError", stats.mdns_error);
    // "已应答 N 次、iPhone 却搜不到" 专用诊断（组播不回环，本机抓不到包，
    // 只能由进程内记账导出 —— 详见 OhosMdnsResponder.h 里的判读说明）。
    set_f64(env, object, "mdnsDroppedSelf",
        static_cast<double>(stats.mdns_dropped_self));
    set_f64(env, object, "mdnsAnnounceSent",
        static_cast<double>(stats.mdns_announce_sent));
    set_f64(env, object, "mdnsAnnounceFailed",
        static_cast<double>(stats.mdns_announce_failed));
    set_utf8(env, object, "mdnsOutIface", stats.mdns_out_iface);
    set_utf8(env, object, "mdnsLastFrom", stats.mdns_last_from);
    set_utf8(env, object, "mdnsLastAnswerIp", stats.mdns_last_answer_ip);
    // "问了什么 / 我们手里有什么"。iPhone 的「屏幕镜像」只认 _airplay._tcp，
    // 但它顺手也会问 _raop._tcp，两者都答得上 —— 不摊开名字就分不清
    // "注册环节丢了 _airplay" 和 "宣告没出去、iPhone 压根没问 _airplay"。
    set_utf8(env, object, "mdnsLastQuery", stats.mdns_last_query);
    set_utf8(env, object, "mdnsQueryCounts", stats.mdns_query_counts);
    set_utf8(env, object, "mdnsServices", stats.mdns_services);
    set_f64(env, object, "audioPackets",
        static_cast<double>(stats.audio_packets));
    // ── 音频是否真出声：判据必须成对 ──────────────────────────────────────
    // audioPackets 只说明 raop 把 PCM 交给我们了；真正出声的判据是渲染器写回调
    // 实际取走的帧数（audioFramesPlayed）。两者一起看才分得开
    //   「数据进来了但没人取」(packets 涨 / played 不涨) 与
    //   「raop 侧就没有音频数据」(packets 也不涨)。
    set_f64(env, object, "audioFramesPlayed",
        static_cast<double>(stats.audio_frames_played));
    set_f64(env, object, "audioBytesFed",
        static_cast<double>(stats.audio_bytes_fed));
    set_f64(env, object, "audioUnderruns",
        static_cast<double>(stats.audio_underruns));
    set_f64(env, object, "audioDroppedFrames",
        static_cast<double>(stats.audio_dropped_frames));
    set_f64(env, object, "audioFlushes",
        static_cast<double>(stats.audio_flushes));
    set_f64(env, object, "audioOpenFailures",
        static_cast<double>(stats.audio_open_failures));
    set_f64(env, object, "audioRendererActive", stats.audio_renderer_active);
    set_utf8(env, object, "audioFormat", stats.audio_format);
    set_utf8(env, object, "audioError", stats.audio_error);
    set_f64(env, object, "videoFrames", static_cast<double>(stats.video_frames));
    // 区分"RaopVideoProcess 被调用 N 次"和"OH_VideoDecoder 真解出 N 帧"。
    // 这两个数若长期一致、且 N 稳定上涨，说明解码链路 OK、画面应该出；
    // decodedFrames 长时间停在 0 / 比 videoFrames 小一个量级，说明解码链某段
    // 不通（典型：解码器 OnError、超时丢帧、SPS/PPS 没配上、surface 没拿到）。
    set_f64(env, object, "decodedFrames",
        static_cast<double>(stats.decoded_frames));
    // "解码跟不上收包"的直接证据：收包线程只入队（不阻塞 TCP 接收），解码线程消费；
    // 队列有上界，超了就丢最旧的**数据**包并在这里 +1（参数集永不丢弃）。
    set_f64(env, object, "videoQueueDropped",
        static_cast<double>(stats.video_queue_dropped));
    // 参数集包数：videoFrames 涨而它为 0 ⇒ 解码器从未被配置（SPS/PPS 没来）。
    set_f64(env, object, "videoConfigPackets",
        static_cast<double>(stats.video_config_packets));
    // 参数集自愈账：分离"配置包可信"与"参数集是从数据帧里补来的"。
    set_f64(env, object, "videoParamFromConfig",
        static_cast<double>(stats.video_param_from_config));
    set_f64(env, object, "videoParamFromFrames",
        static_cast<double>(stats.video_param_from_frames));
    set_f64(env, object, "videoParamReconfigures",
        static_cast<double>(stats.video_param_reconfigures));
    set_f64(env, object, "videoWaitingParam",
        static_cast<double>(stats.video_waiting_param));
    // NAL 账本：判断"流本身是不是 H.264、有没有关键帧"。
    set_f64(env, object, "videoNalSlice", static_cast<double>(stats.video_nal_slice));
    set_f64(env, object, "videoNalIdr", static_cast<double>(stats.video_nal_idr));
    set_f64(env, object, "videoNalSps", static_cast<double>(stats.video_nal_sps));
    set_f64(env, object, "videoNalPps", static_cast<double>(stats.video_nal_pps));
    set_f64(env, object, "videoNalNone", static_cast<double>(stats.video_nal_none));
    // 端到端延迟实测（收包入队 → 解码出帧，EMA；0 = 尚无出帧样本）
    set_f64(env, object, "videoLatencyMs", static_cast<double>(stats.video_latency_ms));
    set_f64(env, object, "videoDecodeErrors",
        static_cast<double>(stats.video_decode_errors));
    set_utf8(env, object, "videoDecoderLastError",
        stats.video_decoder_last_error);
    // 解码链断点定位：单看 decoded_frames=0 不够，要看 pushed / callbacks / size。
    napi_value decoderDiag = nullptr;
    napi_create_object(env, &decoderDiag);
    iPhoneMirror::media::DecoderDiagSnapshot diag;
    im_video_decoder_diag(&diag);
    auto set_u64 = [&](const char *k, uint64_t v) {
        napi_value n = nullptr;
        napi_create_int64(env, static_cast<int64_t>(v), &n);
        napi_set_named_property(env, decoderDiag, k, n);
    };
    auto set_i32 = [&](const char *k, int32_t v) {
        napi_value n = nullptr;
        napi_create_int32(env, v, &n);
        napi_set_named_property(env, decoderDiag, k, n);
    };
    auto set_u32 = [&](const char *k, uint32_t v) {
        napi_value n = nullptr;
        napi_create_int32(env, static_cast<int32_t>(v), &n);
        napi_set_named_property(env, decoderDiag, k, n);
    };
    set_u64("pushedInputs", diag.pushed_inputs);
    set_u64("outputCallbacks", diag.output_callbacks);
    set_u64("outputWithPixels", diag.output_with_pixels);
    set_u64("outputNoPixels", diag.output_no_pixels);
    set_u64("outputTooSmall", diag.output_too_small);
    set_u64("inputTooLarge", diag.input_too_large);
    set_u32("spsParseFailures", diag.sps_parse_failures);
    set_i32("lastAttrSize", diag.last_attr_size);
    set_u32("lastOutputWidth", diag.last_out_width);
    set_u32("lastOutputHeight", diag.last_out_height);
    set_u32("lastConfigWidth", diag.last_cfg_width);
    set_u32("lastConfigHeight", diag.last_cfg_height);
    set_u32("lastSpsEncWidth", diag.last_sps_enc_width);
    set_u32("lastSpsEncHeight", diag.last_sps_enc_height);
    set_u32("lastSpsDispWidth", diag.last_sps_disp_width);
    set_u32("lastSpsDispHeight", diag.last_sps_disp_height);
    set_u32("lastStreamWidth", diag.last_stream_width);
    set_u32("lastStreamHeight", diag.last_stream_height);
    set_u32("firstInputB03", diag.first_input_b0_3);
    set_u32("firstInputB47", diag.first_input_b4_7);
    set_u32("strategy", diag.strategy);
    set_u32("strategySwitches", diag.strategy_switches);
    // 喂帧方式诊断（四档全挂后新增）：区分"push 假成功"与"解码器不认流"。
    set_u64("idrFrames", diag.idr_frames);
    set_u64("syncFlagged", diag.sync_flagged);
    set_u64("inbandParamSets", diag.inband_param_sets);
    set_u64("pushFailures", diag.push_failures);
    set_u64("setattrFailures", diag.setattr_failures);
    set_i32("lastPushError", diag.last_push_error);
    set_i32("lastInputSize", diag.last_input_size);
    set_i32("inputCapacity", diag.input_capacity);
    // 参数集本体（和 first_input_* 分开：前者是"参数集 + 首帧"拼好的结果，
    // 而这里只看 Configure 用的那段 Codec Config —— 判断 SPS 在不在）。
    set_u32("configHeadB03", diag.config_head_b0_3);
    set_u32("configHeadB47", diag.config_head_b4_7);
    set_u64("configures", diag.configures);
    set_utf8(env, decoderDiag, "decoderName", diag.decoder_name);
    napi_set_named_property(env, object, "decoderDiag", decoderDiag);

    // 渲染链断点定位：解码器已解出帧却仍黑屏时，这里能一眼区分
    // "根本没 attach 上 surface" 与 "attach 了但每一帧都被丢弃"。
    // 字段含义见 ohos/OhosPreviewRenderer.h 的 PreviewRendererDiag。
    napi_value previewDiag = nullptr;
    napi_create_object(env, &previewDiag);
    iPhoneMirror::media::PreviewRendererDiag pdiag;
    iPhoneMirror::media::im_preview_renderer_diag(&pdiag);
    auto pset_u64 = [&](const char *k, uint64_t v) {
        napi_value n = nullptr;
        napi_create_int64(env, static_cast<int64_t>(v), &n);
        napi_set_named_property(env, previewDiag, k, n);
    };
    auto pset_u32 = [&](const char *k, uint32_t v) {
        napi_value n = nullptr;
        napi_create_int32(env, static_cast<int32_t>(v), &n);
        napi_set_named_property(env, previewDiag, k, n);
    };
    pset_u32("attached", pdiag.attached);
    pset_u64("attachCalls", pdiag.attach_calls);
    pset_u64("attachFailures", pdiag.attach_failures);
    pset_u64("presentCalls", pdiag.present_calls);
    pset_u64("pumpFrames", pdiag.pump_frames);
    pset_u64("drawCalls", pdiag.draw_calls);
    pset_u64("drawOk", pdiag.draw_ok);
    pset_u64("dropNoDisplay", pdiag.drop_no_display);
    pset_u64("dropNotNv12", pdiag.drop_not_nv12);
    pset_u64("dropEmpty", pdiag.drop_empty);
    pset_u64("dropZeroDim", pdiag.drop_zero_dim);
    pset_u64("dropTooSmall", pdiag.drop_too_small);
    pset_u64("swapFailures", pdiag.swap_failures);
    pset_u64("makeCurrentFailures", pdiag.make_current_failures);
    pset_u64("reattachAttempts", pdiag.reattach_attempts);
    pset_u32("lastGlError", static_cast<uint32_t>(pdiag.last_gl_error));
    pset_u32("lastEglError", static_cast<uint32_t>(pdiag.last_egl_error));
    pset_u32("surfaceWidth", pdiag.surface_width);
    pset_u32("surfaceHeight", pdiag.surface_height);
    pset_u32("lastFrameWidth", pdiag.last_frame_w);
    pset_u32("lastFrameHeight", pdiag.last_frame_h);
    pset_u32("lastFrameBytes", pdiag.last_frame_bytes);
    pset_u32("lastFrameFormat", pdiag.last_frame_format);
    pset_u32("lastFrameStride", pdiag.last_frame_stride);
    set_utf8(env, previewDiag, "lastError", pdiag.last_error);
    napi_set_named_property(env, object, "previewDiag", previewDiag);
    napi_value clients = nullptr;
    napi_create_int32(env, stats.clients, &clients);
    napi_set_named_property(env, object, "clients", clients);
    set_utf8(env, object, "name", stats.name);
    set_utf8(env, object, "hwaddr", stats.hwaddr);
    set_utf8(env, object, "lastError", stats.last_error);
    set_utf8(env, object, "lastLog", stats.last_log);
    return object;
}

// 取走一个待广播服务；队列空返回 null。
// 返回 { id, name, type, port, txt: Uint8Array }，txt 是已编码好的 DNS-SD
// TXT 记录（一串 [长度][key 或 key=value]），ArkTS 按字节解析即可。
napi_value JsAirPlayTakeService(napi_env env, napi_callback_info /*info*/) {
    im_dnssd_service_t service{};
    if (!im_dnssd_queue_take_service(&service)) {
        napi_value null_value = nullptr;
        napi_get_null(env, &null_value);
        return null_value;
    }

    napi_value object = nullptr;
    napi_create_object(env, &object);
    napi_value id = nullptr;
    napi_create_int32(env, service.id, &id);
    napi_set_named_property(env, object, "id", id);
    set_utf8(env, object, "name", service.name);
    set_utf8(env, object, "type", service.type);
    set_u32(env, object, "port", service.port);

    void* data = nullptr;
    napi_value buffer = nullptr;
    napi_create_arraybuffer(env, service.txt_length, &data, &buffer);
    if (service.txt_length > 0 && data != nullptr) {
        std::memcpy(data, service.txt, service.txt_length);
    }
    napi_value typed = nullptr;
    napi_create_typedarray(env, napi_uint8_array, service.txt_length, buffer, 0,
        &typed);
    napi_set_named_property(env, object, "txt", typed);
    return object;
}

// 取走一个待注销的服务 id；队列空返回 0。
napi_value JsAirPlayTakeRemoval(napi_env env, napi_callback_info /*info*/) {
    int id = 0;
    if (im_dnssd_queue_take_removal(&id)) {
        return int32_result(env, id);
    }
    return int32_result(env, 0);
}

// ArkTS 回报广播结果：reportService(id, ok, reason)
napi_value JsAirPlayReportService(napi_env env, napi_callback_info info) {
    napi_value args[3] = {nullptr, nullptr, nullptr};
    if (!args_get(env, info, 3, args)) {
        return int32_result(env,
            static_cast<std::int32_t>(iPhoneMirror::Result::InvalidArgument));
    }
    std::int32_t id = 0;
    bool ok = false;
    if (napi_get_value_int32(env, args[0], &id) != napi_ok ||
        napi_get_value_bool(env, args[1], &ok) != napi_ok) {
        return int32_result(env,
            static_cast<std::int32_t>(iPhoneMirror::Result::InvalidArgument));
    }
    std::string reason;
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, args[2], &type) == napi_ok && type == napi_string) {
        std::size_t length = 0;
        if (napi_get_value_string_utf8(env, args[2], nullptr, 0, &length) ==
            napi_ok) {
            reason.assign(length + 1, '\0');
            std::size_t written = 0;
            napi_get_value_string_utf8(env, args[2], reason.data(),
                reason.size(), &written);
            reason.resize(written);
        }
    }
    im_dnssd_queue_report(id, ok ? 1 : 0, reason.c_str());
    return int32_result(env,
        static_cast<std::int32_t>(iPhoneMirror::Result::Ok));
}

napi_value JsSetLogFile(napi_env env, napi_callback_info info) {
    std::string path;
    if (!arg_string(env, info, path)) {
        return int32_result(env,
            static_cast<std::int32_t>(iPhoneMirror::Result::InvalidArgument));
    }
    const std::int32_t result = im_set_log_file(path.c_str());
    return int32_result(env, result);
}

} // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"initialize",       nullptr, JsInitialize,       nullptr, nullptr, nullptr, napi_default, nullptr},
        {"shutdown",         nullptr, JsShutdown,         nullptr, nullptr, nullptr, napi_default, nullptr},
        {"apiVersion",       nullptr, JsApiVersion,       nullptr, nullptr, nullptr, napi_default, nullptr},
        {"refreshDevices",   nullptr, JsRefreshDevices,   nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startCapture",     nullptr, JsStartCapture,     nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startCaptureWithOptions", nullptr, JsStartCaptureWithOptions, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopCapture",      nullptr, JsStopCapture,      nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getCaptureStatus", nullptr, JsGetCaptureStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"attachPreview",    nullptr, JsAttachPreview,    nullptr, nullptr, nullptr, napi_default, nullptr},
        {"detachPreview",    nullptr, JsDetachPreview,    nullptr, nullptr, nullptr, napi_default, nullptr},
        {"forcePreviewRefresh", nullptr, JsForcePreviewRefresh, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setAudioEnabled",  nullptr, JsSetAudioEnabled,  nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setAudioVolume",   nullptr, JsSetAudioVolume,   nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setImageAdjustments",  nullptr, JsSetImageAdjustments,  nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setVideoPreferences",  nullptr, JsSetVideoPreferences,  nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setPreviewCornerProfile", nullptr, JsSetPreviewCornerProfile, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setWindowRotation", nullptr, JsSetWindowRotation, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"airplayStart",     nullptr, JsAirPlayStart,     nullptr, nullptr, nullptr, napi_default, nullptr},
        {"airplayStop",      nullptr, JsAirPlayStop,      nullptr, nullptr, nullptr, napi_default, nullptr},
        {"airplayGetStatus", nullptr, JsAirPlayGetStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"airplayTakeService", nullptr, JsAirPlayTakeService, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"airplayTakeRemoval", nullptr, JsAirPlayTakeRemoval, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"airplayReportService", nullptr, JsAirPlayReportService, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"lastError",        nullptr, JsLastError,        nullptr, nullptr, nullptr, napi_default, nullptr},
        {"usbDiagnostics",   nullptr, JsUsbDiagnostics,   nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getEnvironment",   nullptr, JsGetEnvironment,   nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setLogFile",       nullptr, JsSetLogFile,       nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

// nm_modname 必须与产物 .so 的基名一致：libim_core.so → "im_core"。
static napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "im_core",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterLibimCore() {
    napi_module_register(&g_module);
}
