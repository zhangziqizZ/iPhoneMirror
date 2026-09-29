// SPDX-License-Identifier: GPL-3.0-only
//
// 鸿蒙 DeviceManager。
//
// 对照上游：Windows 版读 SetupAPI PnP 状态并经回环 TCP 连 Apple 的 usbmux 服务；
// Linux 版把同一份记录从"usbmuxd over AF_UNIX + libusb 枚举"填出来。鸿蒙上用
// "usbmuxd 端点（若有）+ USB DDK 枚举"填同一份记录。
//
// 字段映射里三处没有简单对应：
//  - apple_mobile_device_service_* 借位到 usbmuxd：installed 表示发现端点，
//    running 表示端点可连接。鸿蒙系统不带 usbmuxd，所以常态是两者皆 false。
//  - capture_usbmux 是 Windows 才有的第二条 mux（采集用），恒为 false。
//  - usbdk_backend 报"已知且不可用"：UsbDk 是 Windows 内核过滤驱动，鸿蒙上
//    确实没有，把这点说清楚比留着"未探测"更诚实。
//
// 关键差异：**设备身份来自 USB DDK 而不是 mux**。鸿蒙上哪怕一台设备都没被
// mux 认领，只要 USB DDK 看得到，它就该出现在列表里——这正是隐藏采集配置
// 留下的状态（设备在 USB 上可见而 mux 未认领）。

#include "Device/DeviceManager.h"

#include "OhosEnvironmentProbe.h"
#include "Text/Utf.h"
#include "Transport/AppleUsbSerial.h"
#include "Transport/QtUsbTransport.h"
#include "Transport/UsbMuxClient.h"

#include <format>
#include <map>
#include <utility>
#include <vector>

namespace iPhoneMirror::device {
namespace {

std::vector<transport::MuxDevice> list_usbmux_devices() noexcept {
    try {
        transport::UsbMuxClient mux{std::string(transport::UsbMuxUnixSocketPath)};
        return mux.list_devices();
    } catch (...) {
        return {};
    }
}

std::vector<transport::AppleUsbDevice> enumerate_apple_usb_devices() noexcept {
    try {
        transport::QtUsbContext context(false);
        return context.enumerate();
    } catch (...) {
        return {};
    }
}

} // namespace

EnvironmentRecord DeviceManager::environment() const {
    EnvironmentRecord result;

    const auto probe = ohos_probe::probe();
    result.service_installed = probe.usbmuxd != ohos_probe::UsbmuxdAvailability::NotInstalled;
    result.service_running = probe.usbmuxd == ohos_probe::UsbmuxdAvailability::Connected;
    result.standard_mux = result.service_running;
    result.capture_mux = false;
    result.physical_device_count = probe.apple_usb_devices;

    const auto usb_runtime = transport::probe_usb_runtime();
    result.libusb_runtime = usb_runtime.runtime_available;
    result.libusb_version = text::utf8_to_wide(usb_runtime.version);
    // 上面的探测已经数过一遍 Apple 设备，这里不再枚举。
    result.libusb_apple_devices_known = true;
    result.libusb_apple_devices = probe.apple_usb_devices;
    result.usbdk_backend_known = true;
    result.usbdk_backend = false;
    result.libusb0_available = false;
    result.libusb0_apple_devices_known = true;
    result.libusb0_apple_devices = 0;

    result.diagnostic = ohos_probe::describe(probe);
    if (!ohos_probe::wired_capture_ready(probe)) {
        result.diagnostic += L" 有线采集尚不可用。";
    }
    return result;
}

std::vector<DeviceRecord> DeviceManager::refresh(bool refresh_metadata) {
    // Lockdown 元数据（设备名、机型、iOS 版本）需要一条已配对的 lockdownd
    // 会话，本移植尚未打通；usbmuxd / USB 描述符仍能提供身份与连接类型。
    //
    // ★ 为什么用户的 iPhone 从来不出「信任此电脑」弹窗（2026-09-19）：
    //   iOS 只在一个时刻弹它 —— 主机通过 usbmux 连到 lockdownd(62078) 后**主动发
    //   `Pair` 请求**。插线、枚举设备、读序列号、切采集配置、连 usbmux 读
    //   ListDevices / ReadPairRecord 全都不弹。
    //   上游 Windows「插上就弹」是因为 AppleMobileDeviceService、Linux 是因为
    //   udev 拉起的 usbmuxd —— **是那个守护进程发的 Pair，不是应用发的**。
    //   本工程的配对相关代码只有一处：UsbMuxClient::has_pair_record() 发
    //   `ReadPairRecord`（只读、不弹框），且它还得先有一个 usbmuxd 可连。
    //   鸿蒙既没有 usbmuxd、我们也没有 Pair 实现 ⇒ 没有任何组件会去请求配对，
    //   弹窗永远不会出现。这不是设备/线材问题，别让用户去重启 iPhone。
    (void)refresh_metadata;

    std::map<std::string, DeviceRecord, std::less<>> records;
    for (const auto& mux_device : list_usbmux_devices()) {
        const auto serial = transport::normalize_apple_usb_serial(mux_device.serial);
        if (serial.empty()) continue;
        DeviceRecord record;
        record.device_id = mux_device.device_id;
        record.mux_port = 0; // AF_UNIX 端点，没有 TCP 端口
        record.usb_connected = mux_device.connection_type == "USB";
        record.pair_record_present = false;
        record.lockdown_accessible = false;
        record.state = record.usb_connected ? ConnectionState::Connected
                                            : ConnectionState::Disconnected;
        record.udid = text::utf8_to_wide(mux_device.serial);
        record.connection_type = text::utf8_to_wide(mux_device.connection_type);
        record.status = L"mux 已识别设备；配对与 Lockdown 元数据尚未实现。";
        records.emplace(serial, std::move(record));
    }

    for (const auto& usb_device : enumerate_apple_usb_devices()) {
        const auto serial = transport::normalize_apple_usb_serial(usb_device.serial);
        if (serial.empty()) continue;
        const auto found = records.find(serial);
        if (found != records.end()) {
            found->second.usb_connected = true;
            continue;
        }
        DeviceRecord record;
        record.mux_port = 0;
        record.usb_connected = true;
        record.state = ConnectionState::UsbPresentNoMux;
        record.udid = text::utf8_to_wide(usb_device.serial);
        record.connection_type = L"USB";
        record.status = usb_device.quicktime_configuration
            ? L"设备 USB 可见且已切到采集配置；但鸿蒙不带 usbmuxd，"
              L"没有组件会主动发起配对（iOS 的「信任此电脑」弹窗不会自己出现）。"
            : L"设备 USB 可见，但没有 usbmux 会话：鸿蒙不带 usbmuxd，"
              L"「信任此电脑」弹窗只能由应用自己发 Pair 请求才出现，本移植尚未实现。";
        records.emplace(serial, std::move(record));
    }

    std::vector<DeviceRecord> result;
    result.reserve(records.size());
    for (auto& [serial, record] : records) {
        (void)serial;
        result.push_back(std::move(record));
    }
    return result;
}

} // namespace iPhoneMirror::device
