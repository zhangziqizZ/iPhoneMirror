// SPDX-License-Identifier: GPL-3.0-only
//
// 鸿蒙实现：Transport/QtUsbTransport.h 声明的 USB 传输层。
//
// 上游在 Windows 与 Linux 上都用 libusb-1.0 实现这一层（Windows 走 libusb-win32
// 过滤驱动 + libusb-1.0，Linux 走系统 libusb-1.0）。鸿蒙没有 libusb-1.0：应用
// 访问 USB 的唯一通道是 USB DDK（usb/usb_ddk_api.h，库 libusb_ndk.z.so）。
//
// 因此本文件不编译上游的 Transport/QtUsbTransport.cpp，而是用 USB DDK 实现
// **同一个已声明的接口**（QtUsbContext / QtUsbConnection / UsbError /
// probe_usb_runtime），这样上层共享的 CaptureSession.cpp 一行都不用改——与
// Linux 版用 Transport/LinuxUsbConfiguration.cpp 顶替 Transport/Libusb0Transport
// 是同一手法。
//
// 头部没有成员可以扩展（QtUsbTransport.h 属上游，不能改），所以 DDK 侧的
// 上下文（deviceId / interfaceHandle / 缓冲映射）挂在堆上，用 handle_ 与
// context_ 这两个不透明指针承载。这是刻意的取舍，不是疏忽。
//
// DDK 与 libusb 的能力差异（决定了下面几处"注定做不到"）：
//  * DDK 的数据结构里没有 bConfigurationValue，但 GET_CONFIGURATION 是标准设备
//    请求（bRequest=8）。所以 active_configuration 由本文件自己发一次控制读请求
//    补上，而不是恒为 false——上游 CaptureSession 的三处 quicktime_active() 判定
//    都依赖它，恒 false 会让 USB 重枚举必然超时失败。读不到时才回落为"未知"。
//  * DDK 不暴露端口链，topology_id 只能用 deviceId 构造，跨重枚举不保证稳定；
//    Linux 版用 devpath 末段做稳定身份，鸿蒙做不到。
//  * 切采集配置**不是**标准 SET_CONFIGURATION，而是厂商请求 0x40/0x52
//    （wIndex=2 进采集、0 退回）。详见 AppleConfigurationVendorRequest 处的说明：
//    这一点写错过一次，代价是有线采集永远进不去。
//  * CLEAR_FEATURE(ENDPOINT_HALT) 与厂商 0x40/0x40 踢动都是普通控制请求，DDK
//    能发，所以 clear_halt / recover_handshake 都是**真的把请求发出去**，
//    不是空动作。只有 cancel_pending_io 那对确实无事可做（同步传输没有在途 URB）。

#include "Transport/QtUsbTransport.h"

#include "Device/AppleUsbDiscovery.h"
#include "Logging.h"
#include "OhosUsbDdk.h"
#include "OhosUsbDiagnostics.h"
#include "Transport/AppleUsbIdentityCache.h"
#include "Transport/AppleUsbSerial.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <format>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace iPhoneMirror::transport {
namespace {

constexpr std::uint16_t AppleVendorId = 0x05AC;
constexpr std::uint8_t VendorInterfaceClass = 0xFF;
constexpr std::uint8_t UsbMuxSubclass = 0xFE;
constexpr std::uint8_t QuickTimeSubclass = 0x2A;
constexpr unsigned DefaultTimeoutMs = 1000;
constexpr std::size_t TransferBufferBytes = 1U << 20; // 1 MiB，够一帧 bulk IN
constexpr std::uint8_t NormalConfigurationValue = 1;

// handle_（libusb_device_handle*）在鸿蒙上承载的对象。
struct OhosDeviceState {
    std::uint64_t device_id{};
    std::uint64_t interface_handle{};
    std::uint64_t endpoint_quicktime_interface_handle{};
    void* transfer_map{};   // UsbDeviceMemMap*
    std::size_t transfer_size{};
    std::uint8_t claimed_interface{};
    bool claimed{};
    std::uint8_t quicktime_configuration_value{};
    std::uint8_t normal_configuration_value{NormalConfigurationValue};
};

// context_（libusb_context*）在鸿蒙上承载的对象。
struct OhosContextState {
    ohos_usb::DdkSession session;
};

OhosDeviceState* state_of(libusb_device_handle* handle) noexcept {
    return reinterpret_cast<OhosDeviceState*>(handle);
}

libusb_device_handle* handle_of(OhosDeviceState* state) noexcept {
    return reinterpret_cast<libusb_device_handle*>(state);
}

std::string topology_for_device_id(std::uint64_t device_id) {
    return std::format("ohos-dev-{:016X}", device_id);
}

// topology_for_device_id() 的逆运算。
//
// 为什么需要它：DDK 的每个调用都吃 deviceId，而 AppleUsbDevice 里唯一能跨函数
// 带住 deviceId 的字段就是 topology_id（结构体是上游的，不能加成员）。把编解码
// 写成一对，就不会出现两处各写一遍 substr(9) 的漂移。
std::uint64_t device_id_of(const AppleUsbDevice& device) noexcept {
    constexpr std::size_t PrefixLength = 9; // "ohos-dev-" 的字符数
    if (!device.topology_id.starts_with("ohos-dev-")) return 0;
    try {
        return std::stoull(device.topology_id.substr(PrefixLength), nullptr, 16);
    } catch (...) {
        return 0;
    }
}

#if IM_OHOS_USB_DDK_AVAILABLE

// 读字符串描述符（UTF-16LE → UTF-8）。失败返回空串，与上游"serial 可能读不到"
// 的处理一致（AppleUsbSerial 会对空串做归一化前的判空）。
std::string read_string_descriptor(std::uint64_t interface_handle,
    std::uint8_t descriptor_index, std::uint16_t language_id) {
    if (descriptor_index == 0) return {};
    UsbControlRequestSetup setup{};
    setup.bmRequestType = 0x80; // 设备到主机 / 标准 / 设备
    setup.bRequest = 6;         // GET_DESCRIPTOR
    setup.wValue = static_cast<std::uint16_t>((3U << 8) | descriptor_index);
    setup.wIndex = language_id;
    setup.wLength = 255;

    std::array<std::uint8_t, 255> buffer{};
    std::uint32_t length = static_cast<std::uint32_t>(buffer.size());
    if (OH_Usb_SendControlReadRequest(interface_handle, &setup, DefaultTimeoutMs,
            buffer.data(), &length) != 0) {
        return {};
    }
    if (length < 2) return {};
    std::string utf8;
    // 描述符前两字节是长度与类型，其后是 UTF-16LE 码元。
    for (std::uint32_t offset = 2; offset + 1 < length; offset += 2) {
        const std::uint32_t code_unit =
            static_cast<std::uint32_t>(buffer[offset]) |
            (static_cast<std::uint32_t>(buffer[offset + 1]) << 8);
        if (code_unit == 0) break;
        if (code_unit < 0x80) {
            utf8.push_back(static_cast<char>(code_unit));
        } else if (code_unit < 0x800) {
            utf8.push_back(static_cast<char>(0xC0 | (code_unit >> 6)));
            utf8.push_back(static_cast<char>(0x80 | (code_unit & 0x3F)));
        } else {
            utf8.push_back(static_cast<char>(0xE0 | (code_unit >> 12)));
            utf8.push_back(static_cast<char>(0x80 | ((code_unit >> 6) & 0x3F)));
            utf8.push_back(static_cast<char>(0x80 | (code_unit & 0x3F)));
        }
    }
    return utf8;
}

// 从配置描述符里挑出 (class 0xff, subclass 0x2a / 0xfe) 的接口与它的两个 bulk
// 端点。
//
// DDK 的描述符是**两层**的，不能像 libusb 那样直接把接口当端点数组用：
//   UsbDdkConfigDescriptor.interface[i]        → UsbDdkInterface
//   UsbDdkInterface.altsetting[j]              → UsbDdkInterfaceDescriptor
//   UsbDdkInterfaceDescriptor.endPoint[k]      → UsbDdkEndpointDescriptor
//   UsbDdkEndpointDescriptor.endpointDescriptor → UsbEndpointDescriptor（规范字段）
// Apple 把采集端点放在备用设置 1 上，所以 altsetting 这一层必须逐个看。
UsbEndpointSet endpoints_for_interface(
    const UsbDdkInterfaceDescriptor& interface,
    std::uint8_t configuration_value) {
    UsbEndpointSet set;
    set.configuration = configuration_value;
    set.interface_number = interface.interfaceDescriptor.bInterfaceNumber;
    set.alternate_setting = interface.interfaceDescriptor.bAlternateSetting;
    for (std::uint8_t index = 0;
         index < interface.interfaceDescriptor.bNumEndpoints; ++index) {
        const UsbEndpointDescriptor& endpoint =
            interface.endPoint[index].endpointDescriptor;
        const bool is_bulk = (endpoint.bmAttributes & 0x03U) == 0x02U;
        if (!is_bulk) continue;
        const bool is_in = (endpoint.bEndpointAddress & 0x80U) != 0;
        if (is_in) {
            set.bulk_in = endpoint.bEndpointAddress;
            set.bulk_in_packet_size = endpoint.wMaxPacketSize;
        } else {
            set.bulk_out = endpoint.bEndpointAddress;
            set.bulk_out_packet_size = endpoint.wMaxPacketSize;
        }
    }
    return set;
}

struct EnumeratedDescriptors {
    std::uint8_t configuration_count{};
    std::uint8_t highest_configuration_value{};
    std::optional<UsbEndpointSet> mux_endpoints;
    std::optional<UsbEndpointSet> quicktime_endpoints;
};

// 逐个索引取配置描述符。
//
// ★ 能不能取到**第一个**配置，决定这台设备"列得出来却开不了采集"，所以口径要
//   经得起两种实现：
//   · USB 标准的 GET_DESCRIPTOR 用 **0 基索引**（index 从 0 开始）；
//   · 鸿蒙 SDK 头文件却把 configIndex 注为 "corresponds to bConfigurationValue"。
//   两者不一致时，"index 0 失败"既可能是"设备此刻不可读"，也可能只是"实现想要
//   bConfigurationValue"。真机上（2026-09-19 09:51，绑好驱动扩展之后）第一台
//   Apple 设备的 index=0 就是失败，系统日志记为
//   `usb_ddk_proxy: GetConfigDescriptor_ failed, error code is -1`。
//   ⇒ index 0 失败时必须**再试 index 1** 才能下"读不到"的结论；而一旦某个索引
//   成功，就按标准索引一路扫到第一个失败为止（多配置设备要有完整的配置数）。
EnumeratedDescriptors read_configurations(std::uint64_t device_id) {
    EnumeratedDescriptors summary;
    std::uint8_t consecutive_failures = 0;
    int last_error = 0;
    for (std::uint8_t index = 0; index < 8; ++index) {
        UsbDdkConfigDescriptor* config = nullptr;
        const int code = OH_Usb_GetConfigDescriptor(device_id, index, &config);
        if (code != 0 || config == nullptr) {
            if (config != nullptr) OH_Usb_FreeConfigDescriptor(config);
            last_error = code;
            ++consecutive_failures;
            // 开头连着两次失败（index 0 与 1）才算"读不到"；之后的单次失败就是
            // "没有更多配置了"。失败的返回码留着写进日志，别只写一句"取不到"。
            if (consecutive_failures >= 2) break;
            continue;
        }
        consecutive_failures = 0;
        ++summary.configuration_count;
        const std::uint8_t value = config->configDescriptor.bConfigurationValue;
        summary.highest_configuration_value = std::max(summary.highest_configuration_value, value);
        for (std::uint8_t interface_index = 0;
             interface_index < config->configDescriptor.bNumInterfaces; ++interface_index) {
            const UsbDdkInterface& interface = config->interface[interface_index];
            for (std::uint8_t alt = 0; alt < interface.numAltsetting; ++alt) {
                const UsbDdkInterfaceDescriptor& descriptor =
                    interface.altsetting[alt];
                if (descriptor.interfaceDescriptor.bInterfaceClass !=
                    VendorInterfaceClass) {
                    continue;
                }
                const std::uint8_t subclass =
                    descriptor.interfaceDescriptor.bInterfaceSubClass;
                if (subclass == UsbMuxSubclass) {
                    summary.mux_endpoints =
                        endpoints_for_interface(descriptor, value);
                } else if (subclass == QuickTimeSubclass) {
                    summary.quicktime_endpoints =
                        endpoints_for_interface(descriptor, value);
                }
            }
        }
        OH_Usb_FreeConfigDescriptor(config);
    }
    if (summary.configuration_count == 0 && last_error != 0) {
        // 一个配置都读不到 ⇒ 拿不到端点 ⇒ 设备能在列表里出现，但"开始投屏"
        // 必然失败。这条日志是唯一的现场证据，必须带上返回码。
        logging::write(logging::Level::Warning, "usb", std::format(
            "ohos config descriptor unavailable device_id={:016X} "
            "OH_Usb_GetConfigDescriptor 返回 {}：{}",
            device_id, last_error, ohos_usb::error_text(last_error)));
    }
    return summary;
}

// 读设备当前激活的配置值（标准请求 GET_CONFIGURATION，bRequest=8）。
//
// 为什么必须补这一个字段：上游 CaptureSession 的 quicktime_active() 有三处判定
// （初判 / 重枚举轮询 break / 终判）都要求 active_configuration_known 为真，
// 恒 false 会让重枚举必然等满 20 秒后抛
// "did not expose a stable QuickTime USB interface" —— 与真机、权限、驱动无关。
//
// DDK 不直接暴露 bConfigurationValue，但 SET_CONFIGURATION 能写就说明
// GET_CONFIGURATION 也能读：它们是同一条标准设备请求，只是方向相反，
// 走的都是 OH_Usb_SendControlReadRequest/WriteRequest 这一对控制通道。
// 所以这里自己发一次控制读请求把字段补上，上游 Core 一行都不用改。
//
// 读不到时返回 nullopt，调用方保持 known=false —— 宁可如实报"未知"，
// 也不猜一个值制造假成功。
std::optional<std::uint8_t> read_active_configuration(
    std::uint64_t interface_handle) {
    UsbControlRequestSetup setup{};
    setup.bmRequestType = 0x80; // 设备到主机 / 标准 / 设备
    setup.bRequest = 8;         // GET_CONFIGURATION
    setup.wValue = 0;
    setup.wIndex = 0;
    setup.wLength = 1;

    std::uint8_t value = 0;
    std::uint32_t length = 1;
    if (OH_Usb_SendControlReadRequest(interface_handle, &setup,
            DefaultTimeoutMs, &value, &length) != 0) {
        return std::nullopt;
    }
    if (length < 1 || value == 0) {
        // 0 不是合法的配置值（配置值从 1 起），拿到就是这次请求没真读回来。
        return std::nullopt;
    }
    return value;
}

int set_configuration(std::uint64_t interface_handle, std::uint8_t value) {
    // SET_CONFIGURATION 是一条标准设备请求。鸿蒙的 DDK 没有 libusb_set_configuration，
    // 但这条请求本身能发。注意它**不是**"进入采集配置"的那条请求：让设备暴露
    // Valeria（QuickTime）配置靠的是下面的厂商 0x52，这个只负责在描述符已经出现
    // 之后把某个配置选成当前配置。
    UsbControlRequestSetup setup{};
    setup.bmRequestType = 0x00; // 主机到设备 / 标准 / 设备
    setup.bRequest = 9;         // SET_CONFIGURATION
    setup.wValue = value;
    setup.wIndex = 0;
    setup.wLength = 0;
    return OH_Usb_SendControlWriteRequest(interface_handle, &setup, DefaultTimeoutMs,
        nullptr, 0);
}

// ───────────────── Apple QuickTime(Valeria) 配置的开关 ─────────────────
//
// 上游四个后端切采集配置用的**不是**标准 SET_CONFIGURATION，而是一条厂商请求：
//
//     bmRequestType = 0x40   (主机到设备 | 厂商 | 设备)
//     bRequest      = 0x52
//     wValue        = 0
//     wIndex        = 2 → 进入采集配置;  0 → 退回普通配置
//     无数据阶段
//
// 参照实现（本工程内同目录的上游源码，四处逐字节一致）：
//   Core/src/Transport/QtUsbTransport.cpp:373        开，wIndex=2
//   Core/src/Transport/QtUsbTransport.cpp:451/515    关，wIndex=0
//   Core/src/Transport/LibUsb0Transport.cpp:987       关
//   Core/src/Transport/LinuxUsbConfiguration.cpp:315  关
//   Core/tools/LibUsb0Probe.cpp:109/115               开/关
//
// 语义（实测记录见 Core/src/Capture/UsbReenumerationPolicy.h 文件头）：发完这条
// 请求后设备**重新枚举**，并多出一个配置（"PTP + Apple Mobile Device + Valeria"），
// 0x2A 的 QuickTime 接口就在那个配置里；其值等于"请求前最高配置值 + 1"。也就是
// 说：**在 0x52 之前，描述符里根本没有 QuickTime 接口**，所以任何"先把描述符拿到
// 手再谈激活哪个配置"的做法都必须以这条请求为起点。
//
// 这里曾经写成标准 SET_CONFIGURATION(highest_configuration_value)。那条请求既不会
// 让 Valeria 配置出现，也没有"开/关"的语义区分，后果是设备永远不暴露 0x2A 接口，
// CaptureSession 的重枚举循环必然等满 20 秒后抛
// "did not expose a stable QuickTime USB interface after activation" —— 有线采集
// 根本进不去，而且失败点看起来像设备/驱动问题，实际是这条请求用错了。
constexpr std::uint8_t AppleConfigurationVendorRequest = 0x52;
constexpr std::uint16_t AppleConfigurationEnableIndex = 2;
constexpr std::uint16_t AppleConfigurationDisableIndex = 0;

// 上游 recover_handshake()：刚激活的端点迟迟不说话时，参照客户端补的这一脚。
//     bmRequestType = 0x40, bRequest = 0x40, wValue = 0x6400, wIndex = 0x6400
constexpr std::uint8_t AppleHandshakeKickRequest = 0x40;
constexpr std::uint16_t AppleHandshakeKickMagic = 0x6400;

int send_vendor_device_request(std::uint64_t interface_handle,
    std::uint8_t request, std::uint16_t value, std::uint16_t index) {
    UsbControlRequestSetup setup{};
    setup.bmRequestType = 0x40; // 主机到设备 / 厂商 / 设备
    setup.bRequest = request;
    setup.wValue = value;
    setup.wIndex = index;
    setup.wLength = 0;
    return OH_Usb_SendControlWriteRequest(interface_handle, &setup, DefaultTimeoutMs,
        nullptr, 0);
}

// 轮询等待设备以 QuickTime 配置重新出现，并在描述符已出现但配置未选中时显式选一次。
//
// 为什么这一步必须在这里做：CaptureSession 的重枚举循环只调用**只读**的
// find_apple_device()，它自己不会发 SET_CONFIGURATION。上游 Windows 靠 AppleUsbFilter
// 保持 0x52 选中的配置、Linux 另有 udev/usbmuxd 之外的路径设定；鸿蒙两者都没有，
// 设备重枚举后停在哪一个配置上是不可假设的。所以由"启用"这一步把配置真正落上去。
//
// 超时 8 秒刻意短于外层 20 秒：这里没成功时外层还有余量继续观察，并给出它自己的
// 诊断（谁先给出结论由外层的错误信息决定，这里只负责尽力把配置落到位）。
bool wait_for_quicktime_configuration(const AppleUsbIdentity& identity) {
    constexpr auto PollInterval = std::chrono::milliseconds(250);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(8);
    bool descriptor_seen = false;
    bool identity_mismatch = false;
    std::string last_observation;
    do {
        try {
            QtUsbContext context(false);
            const auto devices = context.enumerate();
            // 把三种情况分开看：设备不在 / 设备在但没有 QuickTime 描述符 /
            // 描述符在但按身份匹配不到。三者的修法完全不同，混成一句话等于没有诊断。
            bool any_quicktime_descriptor = false;
            for (const auto& candidate : devices) {
                if (candidate.quicktime_configuration) {
                    any_quicktime_descriptor = true;
                    break;
                }
            }
            if (any_quicktime_descriptor) descriptor_seen = true;
            const auto selection = select_apple_usb_device(devices, identity, true);
            if (!selection.index && any_quicktime_descriptor) identity_mismatch = true;
            std::optional<AppleUsbDevice> device;
            if (selection.index) device = devices[*selection.index];
            if (device) {
                if (device->active_configuration_known &&
                    device->active_configuration ==
                        device->quicktime_endpoints.configuration) {
                    logging::write(std::format(
                        "ohos_quicktime_configuration_ready config={} interface={}",
                        device->quicktime_endpoints.configuration,
                        device->quicktime_endpoints.interface_number));
                    ohos_usb_diag::note(std::format(
                        "已进入采集配置(config={} 接口={} alt={} in=0x{:02x} out=0x{:02x})",
                        device->quicktime_endpoints.configuration,
                        device->quicktime_endpoints.interface_number,
                        device->quicktime_endpoints.alternate_setting,
                        device->quicktime_endpoints.bulk_in,
                        device->quicktime_endpoints.bulk_out));
                    return true;
                }
                // 只在观测真的变化时记一条：这个循环每 250ms 跑一轮，逐轮记会把
                // 窗口冲掉（窗口只有几行）。
                const auto observation = std::format("qt_config={} active={} known={}",
                    device->quicktime_endpoints.configuration,
                    device->active_configuration,
                    device->active_configuration_known);
                if (observation != last_observation) {
                    last_observation = observation;
                    ohos_usb_diag::note(std::format(
                        "已见到 QuickTime 描述符({} 接口={})，当前配置={}",
                        observation, device->quicktime_endpoints.interface_number,
                        device->active_configuration_known
                            ? std::to_string(device->active_configuration)
                            : std::string("未知")));
                }
                // 描述符有了但当前配置不是它：选一次。返回值可能一次不生效
                // （设备刚重枚举完），下一轮 poll 再确认，所以不因单次失败提前返回。
                const std::uint64_t device_id = device_id_of(*device);
                if (device_id != 0) {
                    std::uint64_t handle = 0;
                    if (OH_Usb_ClaimInterface(device_id, 0, &handle) == 0) {
                        const int result = set_configuration(handle,
                            device->quicktime_endpoints.configuration);
                        OH_Usb_ReleaseInterface(handle);
                        logging::write(std::format(
                            "ohos_quicktime_select_configuration request={} active_known={} "
                            "active={} result={}",
                            device->quicktime_endpoints.configuration,
                            device->active_configuration_known,
                            device->active_configuration, result));
                    }
                }
            }
        } catch (const std::exception& error) {
            logging::write(logging::Level::Warning, "usb", std::format(
                "ohos_quicktime_configuration_wait error={}", error.what()));
        } catch (...) {
        }
        std::this_thread::sleep_for(PollInterval);
    } while (std::chrono::steady_clock::now() < deadline);

    logging::write(logging::Level::Warning, "usb", std::format(
        "ohos_quicktime_configuration_timeout descriptor_seen={} expected_config={} "
        "identity_mismatch={}",
        descriptor_seen, identity.expected_quicktime_configuration, identity_mismatch));
    if (identity_mismatch) {
        // 这一条与"设备没带出采集配置"是两回事：描述符已经在，只是按 serial/topology
        // 都匹配不到它。鸿蒙的 topology_id 由 deviceId 构造、重枚举后会变，所以
        // 真正的含义是"serial 没读到"——修法是查串号描述符，不是查 0x52。
        ohos_usb_diag::note("超时：设备已带出 QuickTime 配置，但按身份匹配不到"
            "（多半是串号没读到，topology 重枚举后会变）");
    } else if (descriptor_seen) {
        ohos_usb_diag::note(std::format(
            "超时：设备带出了 QuickTime 描述符，但配置始终没被选中（期望 {}）",
            identity.expected_quicktime_configuration));
    } else {
        ohos_usb_diag::note("超时：厂商 0x52 之后设备仍没有 QuickTime(0x2A) 接口"
            "（请求可能未被设备接受）");
    }
    return false;
}

// CLEAR_FEATURE(ENDPOINT_HALT)：标准请求，bmRequestType 0x02（主机到设备 | 标准 |
// 端点）、bRequest 0x01、wValue 0x0000（ENDPOINT_HALT）、wIndex = 端点地址。
void clear_endpoint_halt(std::uint64_t interface_handle, std::uint8_t endpoint,
    const char* direction) {
    UsbControlRequestSetup setup{};
    setup.bmRequestType = 0x02;
    setup.bRequest = 0x01;
    setup.wValue = 0x0000;
    setup.wIndex = endpoint;
    setup.wLength = 0;
    const int result = OH_Usb_SendControlWriteRequest(interface_handle, &setup,
        DefaultTimeoutMs, nullptr, 0);
    if (result != 0) {
        // 不抛：调用点（CaptureSession 开流前）把这里当尽力而为，失败也不该
        // 阻断开流。但必须留下记录，否则"端点不同步"这种问题会完全没有线索。
        logging::write(logging::Level::Warning, "usb", std::format(
            "ohos_clear_halt endpoint=0x{:02x} direction={} result={} ({})",
            endpoint, direction, result, ohos_usb::error_text(result)));
        ohos_usb_diag::note(std::format("清端点停顿失败({} 0x{:02x}) result={}",
            direction, endpoint, result));
    }
}

#endif // IM_OHOS_USB_DDK_AVAILABLE

} // namespace

UsbError::UsbError(std::string operation, int code)
    : std::runtime_error(std::format("{} failed (usb error {})", operation, code)),
      code_(code) {}

QtUsbContext::QtUsbContext(bool use_usbdk) {
    // UsbDk 是 Windows 后端；鸿蒙上只有 USB DDK（等价于 libusb1 通道）。
    using_usbdk_ = false;
    (void)use_usbdk;
    auto* state = new OhosContextState();
    if (!state->session.ok()) {
        // 初始化失败时仍然构造成功，让 enumerate() 返回空列表并把原因记进日志，
        // 而不是在环境探测阶段抛异常。
        logging::write(logging::Level::Warning, "usb",
            "USB DDK 初始化失败：设备枚举将为空");
    }
    context_ = reinterpret_cast<libusb_context*>(state);
}

QtUsbContext::~QtUsbContext() {
    delete reinterpret_cast<OhosContextState*>(context_);
    context_ = nullptr;
}

std::vector<AppleUsbDevice> QtUsbContext::enumerate() const {
    std::vector<AppleUsbDevice> devices;
#if IM_OHOS_USB_DDK_AVAILABLE
    auto* state = reinterpret_cast<OhosContextState*>(context_);
    if (state == nullptr || !state->session.ok()) return devices;

    // ★ deviceIds **必须由调用方先申请**，OH_Usb_GetDevices 只负责往这块内存里填。
    //
    // 官方文档对 Usb_DeviceArray::deviceIds 的原话：
    //   "Pointer to the start address of the device ID array that **you have
    //    applied for**. ... the recommended maximum size ... is generally 128."
    // 官方示例也是先 `deviceArray.deviceIds = new uint64_t[MAX_USB_DEVICE_NUM]`
    // 再调用。传一个 deviceIds == nullptr 的结构进去，等于让 SDK 往没申请的内存
    // 里写 ⇒ 段错误。
    //
    // 本工程 2026-09-19 09:34 的三条 cppcrash 就出在这：改成 `Usb_DeviceArray
    // array{}` 后 deviceIds 是 nullptr，而那次驱动配置终于生效、num 终于 > 0，
    // 于是第一行就写进了空指针（先前 num 恒为 0 时侥幸不触发）。
    //
    // 用栈数组：函数返回即自动回收，不需要配对 free，也就没有"该不该 free"的歧义。
    constexpr std::uint32_t MAX_USB_DEVICE_NUM = 128;
    std::uint64_t device_ids[MAX_USB_DEVICE_NUM] = {};
    Usb_DeviceArray array{};
    array.deviceIds = device_ids;
    array.num = MAX_USB_DEVICE_NUM;   // 容量；返回时被改写成实际设备数
    if (OH_Usb_GetDevices(&array) != 0) return devices;

    const std::uint32_t device_count =
        array.num < MAX_USB_DEVICE_NUM ? array.num : MAX_USB_DEVICE_NUM;
    for (std::uint32_t index = 0; index < device_count; ++index) {
        const std::uint64_t device_id = array.deviceIds[index];
        UsbDeviceDescriptor descriptor{};
        if (OH_Usb_GetDeviceDescriptor(device_id, &descriptor) != 0) continue;
        if (descriptor.idVendor != AppleVendorId) continue;
        if (descriptor.idProduct == 0x110A) continue; // USB-C 转 3.5mm 耳机转接头
        if (!device::is_apple_mobile_capture_product_id(descriptor.idProduct)) continue;

        AppleUsbDevice device;
        device.vendor_id = descriptor.idVendor;
        device.product_id = descriptor.idProduct;
        // 鸿蒙拿不到总线号与端口链，bus/address 保留 DDK 的低位标识，仅作显示。
        device.bus = static_cast<std::uint8_t>((device_id >> 8) & 0xFFU);
        device.address = static_cast<std::uint8_t>(device_id & 0xFFU);
        device.topology_id = topology_for_device_id(device_id);

        const auto summary = read_configurations(device_id);
        device.configuration_count = summary.configuration_count;
        device.highest_configuration_value = summary.highest_configuration_value;
        device.mux_configuration = summary.mux_endpoints.has_value();
        device.quicktime_configuration = summary.quicktime_endpoints.has_value();
        if (summary.mux_endpoints) device.mux_endpoints = *summary.mux_endpoints;
        if (summary.quicktime_endpoints) {
            device.quicktime_endpoints = *summary.quicktime_endpoints;
        }
        // 默认值：DDK 的数据结构里没有 bConfigurationValue 这个字段，下面若能用
        // GET_CONFIGURATION 读到真值就会被覆盖；读不到就如实保持"未知"。
        device.active_configuration_known = false;
        device.active_configuration = 0;

        // 读序列号需要先认领一个接口（控制传输挂在接口句柄上），读完立刻释放。
        // 同一个句柄顺带把当前配置值读出来（GET_CONFIGURATION，见上方注释）。
        std::uint64_t probe_handle = 0;
        if (OH_Usb_ClaimInterface(device_id, 0, &probe_handle) == 0) {
            device.serial = read_string_descriptor(probe_handle, descriptor.iSerialNumber, 0x0409);
            device.can_open = true;
            if (const auto active = read_active_configuration(probe_handle)) {
                device.active_configuration = *active;
                device.active_configuration_known = true;
            } else {
                logging::write(logging::Level::Warning, "usb", std::format(
                    "ohos active_configuration unavailable device_id={:016X} "
                    "（GET_CONFIGURATION 失败，重枚举判定可能超时）", device_id));
            }
            OH_Usb_ReleaseInterface(probe_handle);
        } else {
            device.can_open = false;
        }
        devices.push_back(std::move(device));
    }
#endif
    return devices;
}

std::optional<AppleUsbDevice> QtUsbContext::find_apple_device(
    const AppleUsbIdentity& identity, bool require_quicktime) const {
    const auto devices = enumerate();
    const auto selection = select_apple_usb_device(devices, identity, require_quicktime);
    if (!selection.index || selection.ambiguous) return std::nullopt;
    return devices[*selection.index];
}

QtUsbConnection::~QtUsbConnection() { close(); }

QtUsbConnection::QtUsbConnection(QtUsbConnection&& other) noexcept
    : handle_(other.handle_), endpoints_(other.endpoints_), claimed_(other.claimed_),
      active_identity_retained_(other.active_identity_retained_),
      active_topology_(std::move(other.active_topology_)),
      active_serial_(std::move(other.active_serial_)) {
    other.handle_ = nullptr;
    other.claimed_ = false;
    other.active_identity_retained_ = false;
}

QtUsbConnection& QtUsbConnection::operator=(QtUsbConnection&& other) noexcept {
    if (this != &other) {
        close();
        handle_ = other.handle_;
        endpoints_ = other.endpoints_;
        claimed_ = other.claimed_;
        active_identity_retained_ = other.active_identity_retained_;
        active_topology_ = std::move(other.active_topology_);
        active_serial_ = std::move(other.active_serial_);
        other.handle_ = nullptr;
        other.claimed_ = false;
        other.active_identity_retained_ = false;
    }
    return *this;
}

void QtUsbConnection::remember_active_identity(const AppleUsbIdentity& identity) noexcept {
    if (identity.serial.empty() || identity.topology_id.empty()) return;
    active_topology_ = identity.topology_id;
    active_serial_ = identity.serial;
    active_identity_retained_ = retain_active_apple_usb_identity(identity);
}

bool QtUsbConnection::enable_quicktime_configuration(QtUsbContext& context,
    const std::string& serial) {
    AppleUsbIdentity identity;
    identity.serial = serial;
    return enable_quicktime_configuration(context, identity);
}

bool QtUsbConnection::enable_quicktime_configuration(QtUsbContext& context,
    const AppleUsbIdentity& identity) {
#if IM_OHOS_USB_DDK_AVAILABLE
    const auto device = context.find_apple_device(identity, false);
    if (!device) {
        ohos_usb_diag::note("启用采集配置失败：按身份找不到设备（可能已断开）");
        return false;
    }
    if (!device->can_open) {
        ohos_usb_diag::note("启用采集配置失败：设备看得见但认领接口 0 失败");
        return false;
    }
    if (device->quicktime_configuration) return true; // 已在采集配置上

    const std::uint64_t device_id = device_id_of(*device);
    if (device_id == 0) {
        ohos_usb_diag::note("启用采集配置失败：无法从拓扑串还原 deviceId");
        return false;
    }

    std::uint64_t interface_handle = 0;
    if (OH_Usb_ClaimInterface(device_id, 0, &interface_handle) != 0) {
        // 认不到接口 0 就发不出这条请求。常见原因是接口已被别的进程占住，
        // 这里必须把话说清楚，否则上层只会看到"设备没暴露 QuickTime 接口"。
        logging::write(logging::Level::Warning, "usb", std::format(
            "ohos_quicktime_enable_claim_failed device_id={:016X}", device_id));
        ohos_usb_diag::note("启用采集配置失败：认领接口 0 被拒（可能被其他进程占用）");
        return false;
    }
    const int result = send_vendor_device_request(interface_handle,
        AppleConfigurationVendorRequest, 0, AppleConfigurationEnableIndex);
    // 这条请求会让设备**断开重连**，所以负的返回值不代表被拒绝
    // （上游 QtUsbTransport.cpp:378 的注释同义：权威判定是重枚举）。
    OH_Usb_ReleaseInterface(interface_handle);
    logging::write(std::format(
        "ohos_quicktime_enable_request device_id={:016X} result={}",
        device_id, result));
    ohos_usb_diag::note(std::format("已发厂商 0x52(wIndex=2) 切采集配置 result={}"
        "（负值可能是设备断开导致，不代表被拒）", result));

    // 设备现在该以新的 deviceId 出现，并且只有这时描述符里才带 0x2A 接口。
    // 把它等出来并保证该配置是当前配置（细节见 wait_for_quicktime_configuration）。
    return wait_for_quicktime_configuration(identity);
#else
    (void)context;
    (void)identity;
    ohos_usb_diag::note("本 SDK 未提供 USB DDK，有线采集不可用");
    return false;
#endif
}

bool QtUsbConnection::disable_quicktime_configuration(QtUsbContext& context,
    const AppleUsbIdentity& identity) {
#if IM_OHOS_USB_DDK_AVAILABLE
    const auto device = context.find_apple_device(identity, false);
    if (!device || !device->can_open) return false;
    const std::uint64_t device_id = device_id_of(*device);
    if (device_id == 0) return false;

    std::uint64_t interface_handle = 0;
    if (OH_Usb_ClaimInterface(device_id, 0, &interface_handle) != 0) return false;
    // 与启用同一条请求、只是 wIndex=0：让 iOS 把 Valeria 配置丢回去。
    const int result = send_vendor_device_request(interface_handle,
        AppleConfigurationVendorRequest, 0, AppleConfigurationDisableIndex);
    OH_Usb_ReleaseInterface(interface_handle);
    // 同样：断开导致的失败不等于被拒绝，由重枚举判定。
    return result == 0;
#else
    (void)context;
    (void)identity;
    return false;
#endif
}

QtUsbConnection QtUsbConnection::open_quicktime(QtUsbContext& context,
    const std::string& serial) {
    AppleUsbIdentity identity;
    identity.serial = serial;
    return open_quicktime(context, identity, true);
}

QtUsbConnection QtUsbConnection::open_quicktime(QtUsbContext& context,
    const AppleUsbIdentity& identity, bool allow_conventional_fallback) {
    QtUsbConnection connection;
#if IM_OHOS_USB_DDK_AVAILABLE
    auto device = context.find_apple_device(identity, true);
    if (!device && allow_conventional_fallback) {
        // 有些设备在采集配置尚未生效时不暴露 QuickTime 描述符，此时先用身份匹配
        // 拿到设备，再走 conventional 端点集合。
        device = context.find_apple_device(identity, false);
    }
    if (!device) {
        throw UsbError("open_quicktime/find_device", -2);
    }
    if (!device->can_open) {
        throw UsbError("open_quicktime/claim_interface", -3);
    }

    const std::uint64_t device_id = device_id_of(*device);
    if (device_id == 0) throw UsbError("open_quicktime/device_id", -4);

    auto* state = new OhosDeviceState();
    state->device_id = device_id;
    state->quicktime_configuration_value = device->highest_configuration_value;
    state->normal_configuration_value = NormalConfigurationValue;

    const std::uint8_t interface_index =
        device->quicktime_configuration ? device->quicktime_endpoints.interface_number : 0;
    if (OH_Usb_ClaimInterface(device_id, interface_index, &state->interface_handle) != 0) {
        delete state;
        throw UsbError("open_quicktime/claim_quicktime_interface", -5);
    }
    state->claimed = true;
    state->claimed_interface = interface_index;

    // 激活 bulk 端点所在的备用设置（Apple 把采集端点放在 alternatesetting 1 上）。
    const std::uint8_t alternate = device->quicktime_configuration
        ? device->quicktime_endpoints.alternate_setting : 0;
    if (alternate != 0) {
        // 备用设置切换失败不是致命错误：部分设备只有一个设置。
        (void)OH_Usb_SelectInterfaceSetting(state->interface_handle, alternate);
    }

    // OH_Usb_CreateDeviceMemMap 的出参类型是 UsbDeviceMemMap**，不能递 void**。
    UsbDeviceMemMap* transfer_map = nullptr;
    if (OH_Usb_CreateDeviceMemMap(device_id, TransferBufferBytes, &transfer_map) != 0) {
        OH_Usb_ReleaseInterface(state->interface_handle);
        delete state;
        throw UsbError("open_quicktime/create_device_mem_map", -6);
    }
    state->transfer_map = transfer_map;
    state->transfer_size = TransferBufferBytes;

    connection.handle_ = handle_of(state);
    connection.claimed_ = true;
    connection.endpoints_ = device->quicktime_configuration
        ? device->quicktime_endpoints
        : conventional_quicktime_endpoints(identity);
    connection.remember_active_identity(identity);
    ohos_usb_diag::note(std::format(
        "已打开采集端点(config={} 接口={} alt={} in=0x{:02x} out=0x{:02x} 包大小={}/{})",
        connection.endpoints_.configuration,
        connection.endpoints_.interface_number,
        connection.endpoints_.alternate_setting,
        connection.endpoints_.bulk_in, connection.endpoints_.bulk_out,
        connection.endpoints_.bulk_in_packet_size,
        connection.endpoints_.bulk_out_packet_size));
#endif
    return connection;
}

std::size_t QtUsbConnection::read(std::span<std::uint8_t> destination, unsigned timeout_ms) {
#if IM_OHOS_USB_DDK_AVAILABLE
    auto* state = state_of(handle_);
    if (state == nullptr || state->transfer_map == nullptr) return 0;
    if (endpoints_.bulk_in == 0) return 0;
    auto* map = static_cast<UsbDeviceMemMap*>(state->transfer_map);

    // UsbDeviceMemMap 的三个长度字段语义（见 usb_ddk_types.h）：
    //   offset        —— 本次传输使用的缓冲区起始偏移，默认 0
    //   bufferLength  —— 本次传输可用的字节数，默认等于 size
    //   transferedLength —— 本次实际传输的字节数（**传输后**才有意义）
    // 每次批量 IN 之前都要把前两个重置，否则上一帧的残留会成为这一帧的起点。
    map->offset = 0;
    map->bufferLength = static_cast<std::uint32_t>(state->transfer_size);
    map->transferedLength = 0;

    UsbRequestPipe pipe{};
    pipe.interfaceHandle = state->interface_handle;
    pipe.timeout = timeout_ms == 0 ? DefaultTimeoutMs : timeout_ms;
    pipe.endpoint = endpoints_.bulk_in;
    if (OH_Usb_SendPipeRequest(&pipe, map) != 0) return 0;

    const std::size_t received = std::min<std::size_t>(
        map->transferedLength, destination.size());
    std::memcpy(destination.data(), map->address + map->offset, received);
    return received;
#else
    (void)destination;
    (void)timeout_ms;
    return 0;
#endif
}

void QtUsbConnection::write(std::span<const std::uint8_t> source, unsigned timeout_ms) {
#if IM_OHOS_USB_DDK_AVAILABLE
    auto* state = state_of(handle_);
    if (state == nullptr || state->transfer_map == nullptr) {
        throw UsbError("write/no_transfer_buffer", -7);
    }
    if (source.size() > state->transfer_size) {
        throw UsbError("write/buffer_too_small", -8);
    }
    auto* map = static_cast<UsbDeviceMemMap*>(state->transfer_map);
    std::memcpy(map->address, source.data(), source.size());
    // 与 read() 同理：发之前显式声明本次用多少字节。
    map->offset = 0;
    map->bufferLength = static_cast<std::uint32_t>(source.size());
    map->transferedLength = 0;

    UsbRequestPipe pipe{};
    pipe.interfaceHandle = state->interface_handle;
    pipe.timeout = timeout_ms == 0 ? DefaultTimeoutMs : timeout_ms;
    pipe.endpoint = endpoints_.bulk_out;
    const int result = OH_Usb_SendPipeRequest(&pipe, map);
    if (result != 0) {
        throw UsbError("write/bulk_out", result);
    }
#else
    (void)source;
    (void)timeout_ms;
    throw UsbError("write/ddk_unavailable", -1);
#endif
}

void QtUsbConnection::clear_halt() {
#if IM_OHOS_USB_DDK_AVAILABLE
    auto* state = state_of(handle_);
    if (state == nullptr) return;
    if (endpoints_.bulk_in == 0 || endpoints_.bulk_out == 0) return;
    // 上游把这个动作算作"开始流之前唯一的一串控制流量"（见
    // Core/src/Transport/LinuxUsbConfiguration.h 的 clear_halt 注释）：它不只是
    // 清停顿，还把两端的 DATA toggle 同时归到 DATA0 —— 而主机读不到设备的 toggle，
    // 这是唯一能对齐它的手段。所以它属于**协议启动序列**，不是可选项。
    //
    // 这里以前写成空动作，理由是"DDK 的批量传输是同步的、没有悬空 URB 要取消"。
    // 那是把"没法取消在途请求"和"不需要清 halt"混为一谈：前者确实做不到，
    // 后者却是一条普通的标准控制请求，DDK 能发。
    clear_endpoint_halt(state->interface_handle, endpoints_.bulk_in, "in");
    clear_endpoint_halt(state->interface_handle, endpoints_.bulk_out, "out");
#endif
}

void QtUsbConnection::recover_handshake() {
#if IM_OHOS_USB_DDK_AVAILABLE
    auto* state = state_of(handle_);
    if (state == nullptr) return;
    // 上游 recover_handshake() 是参照客户端在"刚激活的端点迟迟不说话"时补的一脚
    // （Core/src/Transport/QtUsbTransport.cpp:489，QtUsbConnection::recover_handshake）。
    //
    // 这个动作在鸿蒙上格外重要：CaptureSession 只在 newly_activated_libusb0 为真时
    // 才补这一脚，而那个标志只在 _WIN32 的 libusb0 分支里被置位——也就是说鸿蒙路径
    // 下这一脚**只有快连重连**才会踢。真正"端点开了但不发 PING"的现场，除了这里
    // 没有任何办法，所以它不能是空动作。
    const int result = send_vendor_device_request(state->interface_handle,
        AppleHandshakeKickRequest, AppleHandshakeKickMagic, AppleHandshakeKickMagic);
    if (result != 0) {
        ohos_usb_diag::note(std::format("握手踢动(0x40/0x40)失败 result={}", result));
        throw UsbError("recover QuickTime handshake",
            ohos_usb::to_libusb_style_error(result));
    }
    ohos_usb_diag::note("已发握手踢动(0x40/0x40, 0x6400)");
#endif
}

bool QtUsbConnection::request_normal_configuration() {
#if IM_OHOS_USB_DDK_AVAILABLE
    auto* state = state_of(handle_);
    if (state == nullptr) return false;
    // 采集结束时把设备退回普通配置——否则依赖普通配置的通道（文件传输之类）
    // 会一直看不到设备。用的是同一条厂商请求的 wIndex=0 那一侧。
    //
    // 顺序与 libusb 版**故意相反**：libusb 要求"先释放接口再发请求"，因为
    // libusb_close 不能再经过一个已被 0x52 断开的句柄去隐式释放接口；而 DDK 的
    // 控制请求必须走一个已认领的接口句柄，先释放就没有句柄可用了，所以只能
    // 先发请求、再由 close() 释放。这是通道语义不同带来的必要差异，不是遗漏。
    const int result = send_vendor_device_request(state->interface_handle,
        AppleConfigurationVendorRequest, 0, AppleConfigurationDisableIndex);
    // 请求成功会让设备断开，所以负值不等于被拒绝；重枚举才是权威。
    logging::write(std::format(
        "ohos_usb_restore_normal_configuration result={}", result));
    ohos_usb_diag::note(std::format("已请求退回普通配置(0x52 wIndex=0) result={}", result));
    return result == 0;
#else
    return false;
#endif
}

void QtUsbConnection::cancel_pending_io() noexcept {
    // 同步传输模型下没有可取消的在途请求。
}

void QtUsbConnection::clear_io_cancellation() noexcept {
    // 与 cancel_pending_io 成对；同样无事可做。
}

void QtUsbConnection::close() noexcept {
#if IM_OHOS_USB_DDK_AVAILABLE
    auto* state = state_of(handle_);
    if (state != nullptr) {
        if (state->transfer_map != nullptr) {
            OH_Usb_DestroyDeviceMemMap(static_cast<UsbDeviceMemMap*>(state->transfer_map));
            state->transfer_map = nullptr;
        }
        if (state->claimed) {
            OH_Usb_ReleaseInterface(state->interface_handle);
            state->claimed = false;
        }
        delete state;
    }
#endif
    handle_ = nullptr;
    if (active_identity_retained_) {
        release_active_apple_usb_identity(active_topology_, active_serial_);
        active_identity_retained_ = false;
    }
    claimed_ = false;
}

// 本文件只参与鸿蒙构建（_WIN32 恒未定义），所以这里给唯一一份定义，
// 不再保留上游 QtUsbTransport.cpp 的 Windows/POSIX 双分支写法。
UsbRuntimeProbe probe_usb_runtime() noexcept {
    UsbRuntimeProbe probe;
#if IM_OHOS_USB_DDK_AVAILABLE
    // 刻意不做 OH_Usb_Init：环境轮询应当只读且无副作用，真正的可用性结论
    // 由 OhosEnvironmentProbe::probe() 给出。
    probe.runtime_available = true;
    probe.version = "OHOS USB DDK";
#else
    probe.runtime_available = false;
    probe.error = "该 SDK 未提供 USB DDK";
#endif
    // UsbDk 是 Windows 内核过滤驱动，鸿蒙上确定没有：报"已探测且不可用"，
    // 而不是留着未探测。
    probe.usbdk_backend_probed = true;
    probe.usbdk_backend_available = false;
    return probe;
}

UsbRuntimeProbe probe_usb_runtime(UsbRuntimeProbeSource& source,
    bool probe_backends) noexcept {
    UsbRuntimeProbe probe;
    try {
        source.read_user_mode_metadata(probe);
        if (probe_backends) {
            source.probe_usb_backends(probe);
        }
    } catch (...) {
        probe.error = "读取 USB 运行库元数据时发生异常";
    }
    return probe;
}

} // namespace iPhoneMirror::transport

// ───────────────────────── C ABI：有线链路诊断尾巴 ─────────────────────────
//
// 返回进程内静态缓冲：调用方（NAPI 桥）用完即走，不要释放、不要跨线程长期持有。
// 每次都重新拷贝一份，是因为 NAPI 的字符串创建本身就是拷贝语义，而这里给出
// 一个稳定生命周期的 const char* 比让调用方管内存更不容易出错。
const char *im_usb_diagnostics(void) {
    static std::mutex buffer_mutex;
    static std::string buffer;
    try {
        std::scoped_lock lock(buffer_mutex);
        buffer = iPhoneMirror::ohos_usb_diag::tail();
        return buffer.c_str();
    } catch (...) {
        return "";
    }
}
