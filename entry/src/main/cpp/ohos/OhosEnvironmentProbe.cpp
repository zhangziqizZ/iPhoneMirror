// SPDX-License-Identifier: GPL-3.0-only
//
// 鸿蒙 USB DDK 封装与环境探测实现。

#include "OhosEnvironmentProbe.h"
#include "OhosUsbDdk.h"

#include "Device/AppleUsbDiscovery.h"
#include "Text/Utf.h"
#include "Transport/UsbMuxClient.h"

#include <cstring>
#include <string>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <vector>

// ohos_usb::{acquire,release,available,to_libusb_style_error,error_text} 的
// **唯一实现在 OhosUsbDdk.cpp**，本文件只使用（见下面 probe() 里的调用）。
//
// 这里原先还有一份"进程级引用计数"的实现，与 OhosUsbDdk.cpp 那份同签名、
// 同 namespace —— 静态库链接**不会**报 duplicate symbol（链接器只拉取第一个
// 满足符号的 .o），所以错误一直藏着没暴露，但生效的是哪一份是不确定的：
// 那份用的是无锁计数 + 每次重试 OH_Usb_Init() + API10 旧名 OH_Usb_Release()，
// 而 OhosUsbDdk.cpp 的引用计数版才是目标 API 的写法（OH_Usb_ReleaseResource）。
//
// 教训：凡「同一 namespace + 同签名 + 非 inline」的函数，新增前先全局搜一遍；
// 静态库里的重复定义不报错，只会静默地让非预期的那份生效。
// 声明与「无 DDK 头时的 inline 失败版」都在 OhosUsbDdk.h。

namespace iPhoneMirror::device::ohos_probe {
namespace {

// 鸿蒙系统不带 usbmuxd。这几个路径是"将来随包带一个 mux 端点"时最可能的落点，
// 探测它们只为把「确实有端点但连不上」与「根本没有」区分开。
const std::vector<std::string>& usbmuxd_candidates() {
    static const std::vector<std::string> candidates{
        std::string(transport::UsbMuxUnixSocketPath),
        "/data/service/el1/public/usbmuxd/usbmuxd.sock",
        "/data/service/el1/public/usbmuxd.socket",
    };
    return candidates;
}

bool can_connect_unix(const std::string& path) noexcept {
    const int handle = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (handle < 0) return false;
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    if (path.size() >= sizeof(address.sun_path)) {
        ::close(handle);
        return false;
    }
    std::memcpy(address.sun_path, path.c_str(), path.size());
    address.sun_path[path.size()] = '\0';
    const bool connected =
        ::connect(handle, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0;
    ::close(handle);
    return connected;
}

bool socket_exists(const std::string& path) noexcept {
    return ::access(path.c_str(), F_OK) == 0;
}

void probe_usbmuxd(Report& report) noexcept {
    for (const auto& candidate : usbmuxd_candidates()) {
        if (can_connect_unix(candidate)) {
            report.usbmuxd = UsbmuxdAvailability::Connected;
            report.usbmuxd_socket_path = candidate;
            return;
        }
    }
    for (const auto& candidate : usbmuxd_candidates()) {
        if (socket_exists(candidate)) {
            report.usbmuxd = UsbmuxdAvailability::SocketPresentNotAccepting;
            report.usbmuxd_socket_path = candidate;
            return;
        }
    }
    report.usbmuxd = UsbmuxdAvailability::NotInstalled;
}

#if IM_OHOS_USB_DDK_AVAILABLE
// 枚举结果。**total 与 apple 必须一起带出去**：只知道"没有 Apple 设备"是没法
// 下判断的，因为 OH_Usb_GetDevices 会按 module.json5 里的 vid 过滤 ——
// total==0 说明过滤把所有设备都挡了（驱动配置没生效），total>0 说明过滤在起作用
// 而只是没有 Apple 的（线/型号问题）。两条路的修法完全不同。
struct Enumeration {
    std::uint32_t total{};
    std::uint32_t apple{};
    // 第一台 Apple 设备的配置描述符读取情况（见 Report::apple_config_* 的注释）。
    bool config_checked{};
    bool config_readable{};
    int config_result{};
    int config_index{-1};
};

// 试两个 configIndex：0 是 USB 标准的 0 基索引，1 对应头文件注释所说的
// bConfigurationValue 口径。返回实际读到的那个 index，失败返回 -1。
int try_read_config(std::uint64_t device_id, int& failure_code) noexcept {
    for (std::uint8_t index = 0; index < 2; ++index) {
        UsbDdkConfigDescriptor* config = nullptr;
        const int code = OH_Usb_GetConfigDescriptor(device_id, index, &config);
        if (config != nullptr) {
            OH_Usb_FreeConfigDescriptor(config);
            return static_cast<int>(index);
        }
        failure_code = code;
    }
    return -1;
}

// 只用 DDK 的枚举与设备描述符，不 claim 任何接口、不做任何配置变更，
// 因此这一步是只读的。
Enumeration enumerate_devices() noexcept {
    Enumeration result;
    // ★ deviceIds **必须由调用方先申请**（官方文档："the device ID array that you
    // have applied for"，上限建议 128；官方示例是 `new uint64_t[128]`）。
    // 传 `Usb_DeviceArray devices{}`（deviceIds == nullptr）进去，就是让 SDK 往
    // 一块没申请的内存里写 —— 一旦驱动配置生效、num 终于 > 0，立刻段错误。
    // 本工程 09:34 的三条 cppcrash 正是这么来的（详见 OhosUsbTransport.cpp 同处注释）。
    // 用栈数组，返回时自动回收，不需要 free。
    constexpr std::uint32_t MAX_USB_DEVICE_NUM = 128;
    std::uint64_t device_ids[MAX_USB_DEVICE_NUM] = {};
    Usb_DeviceArray devices{};
    devices.deviceIds = device_ids;
    devices.num = MAX_USB_DEVICE_NUM;   // 容量；返回时被改写成实际设备数
    if (OH_Usb_GetDevices(&devices) != 0) return result;
    const std::uint32_t device_count =
        devices.num < MAX_USB_DEVICE_NUM ? devices.num : MAX_USB_DEVICE_NUM;
    result.total = device_count;
    for (std::uint32_t device_index = 0; device_index < device_count; ++device_index) {
        UsbDeviceDescriptor descriptor{};
        if (OH_Usb_GetDeviceDescriptor(devices.deviceIds[device_index], &descriptor) != 0) {
            continue;
        }
        if (descriptor.idVendor != 0x05AC) continue;
        if (!is_apple_mobile_capture_product_id(descriptor.idProduct) &&
            !is_apple_audio_adapter_product_id(descriptor.idProduct)) {
            continue;
        }
        if (!result.config_checked) {
            // 只探第一台：多台设备的结论通常一致，而每多一次调用就多一次 IPC。
            result.config_checked = true;
            int failure_code = 0;
            const int config_index =
                try_read_config(devices.deviceIds[device_index], failure_code);
            result.config_index = config_index;
            result.config_readable = config_index >= 0;
            result.config_result = config_index >= 0 ? 0 : failure_code;
        }
        ++result.apple;
    }
    return result;
}
#endif

} // namespace

Report probe() noexcept {
    Report report;
    report.usbmuxd_candidate_paths = usbmuxd_candidates();
    probe_usbmuxd(report);

#if IM_OHOS_USB_DDK_AVAILABLE
    if (!ohos_usb::acquire()) {
        // 用**真实**返回码，不要写死 -1。这个数字是整条链路上信息量最大的一个：
        //   201      USB_DDK_NO_PERM          → 权限没下来，去补 allowed-acls
        //   27400002 USB_DDK_INVALID_OPERATION → 连不上 DDK 服务，多半是调用方不在
        //                                        DriverExtensionAbility 生命周期里
        // 写死 -1 会把这两条路并成同一句"检查权限"，方向直接错（现场已被带偏一次）。
        const int code = ohos_usb::last_init_error();
        if (code == USB_DDK_SUCCESS) {
            // 走到这里就意味着本封装自己的状态机坏了（Init 自身成功，却拿不到
            // 句柄）。这种"初始化失败：返回 0：成功"的话**绝不能**送到界面上 ——
            // 它自相矛盾，读的人只会被带到权限那条错路上去（现场已经被坑过一次）。
            // 宁可说"状态异常"，也不要给一句看着有信息量、其实把人引偏的话。
            report.usb_ddk = UsbDdkAccess::Unknown;
            report.ddk_init_result = code;
            report.ddk_diagnostic =
                "USB DDK 句柄获取失败，但 OH_Usb_Init 自身返回成功（封装状态异常）";
            return report;
        }
        report.usb_ddk = UsbDdkAccess::InitFailed;
        report.ddk_init_result = code;
        report.ddk_diagnostic =
            "OH_Usb_Init 返回 " + std::to_string(code) + "：" +
            ohos_usb::error_text(code);
        return report;
    }
    report.ddk_init_result = 0;
    const Enumeration found = enumerate_devices();
    report.usb_devices_total = found.total;
    report.apple_usb_devices = found.apple;
    report.apple_config_readable = found.config_readable;
    report.apple_config_result = found.config_result;
    report.apple_config_index = found.config_index;
    ohos_usb::release();
    if (found.apple > 0) {
        report.usb_ddk = UsbDdkAccess::Ready;
        report.ddk_diagnostic = "USB DDK 可用，且枚举到 Apple 设备";
        if (!found.config_readable) {
            // 看得见 ≠ 能采集。把这个数字送到界面上，省一轮来回。
            report.ddk_diagnostic +=
                "；但配置描述符读不到（OH_Usb_GetConfigDescriptor 返回 " +
                std::to_string(found.config_result) + "：" +
                ohos_usb::error_text(found.config_result) + "）";
        } else if (found.config_index > 0) {
            report.ddk_diagnostic +=
                "（配置描述符仅在第 " + std::to_string(found.config_index) +
                " 个 configIndex 上读得到，与 USB 标准的 0 基索引口径不一致）";
        }
    } else {
        report.usb_ddk = UsbDdkAccess::NoAppleDeviceVisible;
        // 措辞分两种（原因见 OhosEnvironmentProbe.h 里 NoAppleDeviceVisible 的
        // 注释）。describe() 会在这句前面加"USB DDK 可用但看不到 Apple 设备："，
        // 所以这里只写差异部分。
        report.ddk_diagnostic = found.total == 0
            ? "一台设备都没枚举到 —— OH_Usb_GetDevices 按 driver 配置的 vid 过滤后"
              "什么都不剩，说明那份驱动配置信息（module.json5 里 driver 扩展的 "
              "vid/pid）尚未生效，需要驱动扩展先被 bind"
            : "枚举到 " + std::to_string(found.total) +
              " 台设备但没有 Apple 的（VID 0x05AC）—— 过滤已生效，"
              "该查线材或机型是否在白名单里";
    }
#else
    report.usb_ddk = UsbDdkAccess::DdkUnavailable;
    report.ddk_init_result = -1;
    report.ddk_diagnostic = ohos_usb::error_text(-1);
#endif
    return report;
}

std::wstring describe(const Report& report) {
    std::wstring text;
    switch (report.usbmuxd) {
    case UsbmuxdAvailability::Connected:
        text = L"usbmuxd 端点可连接：" + text::utf8_to_wide(report.usbmuxd_socket_path);
        break;
    case UsbmuxdAvailability::SocketPresentNotAccepting:
        text = L"usbmuxd 套接字存在但拒绝连接：" +
            text::utf8_to_wide(report.usbmuxd_socket_path);
        break;
    case UsbmuxdAvailability::NotInstalled:
    default:
        // 鸿蒙系统不带 usbmuxd，这是正常状态而非故障：设备身份改由 USB DDK
        // 枚举提供（见 OhosDeviceManager）。
        text = L"未发现 usbmuxd 服务端点（鸿蒙的正常状态；设备身份改由 "
               L"USB DDK 枚举提供）";
        break;
    }

    text += L" ";
    switch (report.usb_ddk) {
    case UsbDdkAccess::Ready:
        text += L"USB DDK 可用，可见 " + std::to_wstring(report.apple_usb_devices) +
            L" 台 Apple 设备。";
        // "看得见"和"能采集"是两件事：枚举到设备不等于拿得到端点。
        // 配置描述符读不到时，UI 只显示前一句会让人以为万事俱备。
        if (report.apple_usb_devices > 0) {
            text += report.apple_config_readable
                ? L"配置描述符可读（configIndex=" +
                      std::to_wstring(report.apple_config_index) + L"）。"
                : L"但配置描述符读不到（OH_Usb_GetConfigDescriptor 返回 " +
                      std::to_wstring(report.apple_config_result) + L"：" +
                      text::utf8_to_wide(ohos_usb::error_text(report.apple_config_result)) +
                      L"）——没有接口与端点，列表里看得见也开不了采集。";
        }
        break;
    case UsbDdkAccess::NoAppleDeviceVisible:
        // ddk_diagnostic 里已经把两种成因分开写了（0 台 vs N 台但无 Apple，见
        // probe()）。这里原样带出去，**别**再拼一句笼统的"驱动配置需要包含
        // VID 0x05AC"盖掉它 —— 那句话对"过滤已生效只是没插对线"的情形是误导。
        text += L"USB DDK 可用但看不到 Apple 设备：" +
            text::utf8_to_wide(report.ddk_diagnostic) + L"。";
        break;
    case UsbDdkAccess::InitFailed:
        text += L"USB DDK 初始化失败：" + text::utf8_to_wide(report.ddk_diagnostic) +
            L"。";
        break;
    case UsbDdkAccess::DdkUnavailable:
        text += L"当前 SDK 未提供 USB DDK，无法访问 USB 设备。";
        break;
    case UsbDdkAccess::Unknown:
    default:
        // Unknown 目前只有一种来源：DDK 句柄拿不到、但 Init 自己返回成功
        // （封装状态异常，见 probe()）。这种时候 ddk_diagnostic 里有话要说，
        // 不能吞掉它换成一句"状态未知"。
        text += report.ddk_diagnostic.empty()
            ? std::wstring(L"USB DDK 状态未知。")
            : L"USB DDK 状态异常：" + text::utf8_to_wide(report.ddk_diagnostic) + L"。";
        break;
    }
    return text;
}

bool wired_capture_ready(const Report& report) noexcept {
    return report.usb_ddk == UsbDdkAccess::Ready;
}

} // namespace iPhoneMirror::device::ohos_probe
