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
#include "OhosPairing.h"
#include "OhosUsbDeviceId.h"
#include "OhosUsbDiagnostics.h"
#include "Text/Utf.h"
#include "Transport/AppleUsbSerial.h"
#include "Transport/QtUsbTransport.h"
#include "Transport/UsbMuxClient.h"

#include <format>
#include <map>
#include <mutex>
#include <set>
#include <string>
#include <thread>
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

// ── 自动配对的去重状态 ───────────────────────────────────────────
//
// 为什么需要它：refresh() 是**周期性**被调用的（界面上有心跳轮询），而
// 一次配对最多要等用户 60 秒。如果每次 refresh 都发起一次配对，就会：
//   · 同一台设备上并发发起多个 Pair 请求 → 设备侧收到重复请求，弹窗可能
//     反复出现或状态错乱；
//   · 每次都新起一个线程等 60 秒 → 线程堆积。
//
// 所以这里按 deviceId 记住"已经发起过配对"这件事。**只在本次进程内**
// 去重：跨进程的持久化（"插一次就长期免弹窗"）要靠配对记录落盘，那是
// 完整配对那一步的事。
std::mutex& pairing_guard() noexcept {
    static std::mutex value;
    return value;
}

std::set<std::uint64_t>& pairing_attempted() noexcept {
    static std::set<std::uint64_t> value;
    return value;
}

// 对一台设备发起配对（后台线程）。
//
// 为什么放后台：request_device_trust() 最多阻塞 60 秒（等用户点「信任」），
// 而 refresh() 是 UI 心跳路径，阻塞它等于冻结界面。
//
// udid 一起带过去：配对记录要按 udid 存进沙箱，"插一次长期免弹窗"靠它。
//
// 为什么捕获异常：后台线程里未捕获的异常会直接 std::terminate 把整个应用
// 打死，而配对链路上的异常（DDK 报错、内存分配失败）都不该有这种威力。
void start_pairing_in_background(std::uint64_t deviceId,
    const std::string& udid) {
    std::thread([deviceId, udid]() {
        try {
            const ohos::PairingOutcome outcome =
                ohos::request_device_trust(deviceId, udid, 60);
            ohos_usb_diag::note(std::format("配对结果：{}",
                ohos::describe_pairing_outcome(outcome)));
        } catch (...) {
            ohos_usb_diag::note("配对过程抛出异常，已忽略");
        }
    }).detach();
}

// 见到一台还没发起过配对的设备就自动发起一次。
void maybe_start_pairing(std::uint64_t deviceId, const std::string& udid) {
    if (deviceId == 0) return;
    // ★ fd 配对在跑就让路 ★：fd 通道（usbManager 备用路）不依赖驱动扩展，
    // 插线后第一条心跳就能把 Pair 发出去，是先发梯队；DDK 的扩展冷启动
    // 慢 3~5 秒。两路同时对同一台设备发 Pair 会在 bulk 管道上互相偷报文。
    // fd 结束后（无论成败）下一轮 refresh 会走到这里：fd 成功过的话设备
    // 侧已有记录，DDK 的 Pair 静默成功、不再弹窗。
    if (ohos::fd_pairing_active()) return;
    {
        std::scoped_lock lock(pairing_guard());
        if (!pairing_attempted().insert(deviceId).second) {
            // 已经发起过：本次进程内不再重复（避免 refresh 心跳反复触发）。
            return;
        }
    }
    ohos_usb_diag::note(std::format(
        "检测到未配对设备（deviceId={:016X}），自动发起配对", deviceId));
    start_pairing_in_background(deviceId, udid);
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
    // ★ 2026-10-23：原始读数**必须**和结论分开写。
    //
    // describe() 给的是给人读的一句话，它已经把 201 / 27400002 合并成了
    // "初始化失败"。而我们下一步要做的判断恰恰依赖**没被合并的那个整数**：
    //   201      USB_DDK_NO_PERM           → 去补 allowed-acls（闸门一）
    //   27400002 USB_DDK_INVALID_OPERATION → 去查调用方生命周期（闸门二）
    //   0        成功                       → 权限根本不是问题，看后面的台数
    // 合并成一句话之后，这两个数字只能靠翻日志找，而现场要的是截图就能读出来。
    //
    // 顺带回答一个此前只能猜的问题：**在没有 ACL 的情况下 OH_Usb_Init 到底返回什么**。
    // 它决定"闸门一"是硬阻塞还是纸老虎 —— 若实测返回 0，说明权限检查发生在后续
    // 调用上，那 OH_Usb_GetDevices 那一步的返回值才是真正要看的东西。
    result.diagnostic += L" ｜DDK 原始读数: init=" + std::to_wstring(probe.ddk_init_result)
        + L" 设备总数=" + std::to_wstring(probe.usb_devices_total)
        + L" Apple=" + std::to_wstring(probe.apple_usb_devices)
        + L" config可读=" + (probe.apple_config_readable ? L"是" : L"否")
        + L"(结果=" + std::to_wstring(probe.apple_config_result)
        + L" 索引=" + std::to_wstring(probe.apple_config_index) + L")";
    return result;
}

std::vector<DeviceRecord> DeviceManager::refresh(bool refresh_metadata) {
    // Lockdown 元数据（设备名、机型、iOS 版本）需要一条已配对的 lockdownd
    // 会话；本移植的配对链路刚打通，元数据读取还不在本次范围内。
    //
    // ★ 为什么用户的 iPhone 从来不出「信任此电脑」弹窗（2026-09-19）：
    //   iOS 只在一个时刻弹它 —— 主机通过 usbmux 连到 lockdownd(62078) 后**主动发
    //   `Pair` 请求**。插线、枚举设备、读序列号、切采集配置、连 usbmux 读
    //   ListDevices / ReadPairRecord 全都不弹。
    //   上游 Windows「插上就弹」是因为 AppleMobileDeviceService、Linux 是因为
    //   udev 拉起的 usbmuxd —— **是那个守护进程发的 Pair，不是应用发的**。
    //   本工程的配对相关代码只有一处：UsbMuxClient::has_pair_record() 发
    //   `ReadPairRecord`（只读、不弹框），且它还得先有一个 usbmuxd 可连。
    //   鸿蒙既没有 usbmuxd ⇒ 没有任何组件会去请求配对，弹窗永远不会出现。
    //   这不是设备/线材问题，别让用户去重启 iPhone。
    //
    // ★ 现在（2026-10-30）这件事由本工程自己做 ★
    //   鸿蒙系统没有 usbmuxd 守护进程，所以本工程自己当 usbmuxd：用 USB DDK
    //   直连 iPhone 的 usbmux 接口（class 0xFF / subclass 0xFE），讲 iPhone
    //   侧的 usbmux 协议（见 ohos/OhosUsbMux.cpp），在隧道上连 lockdownd 的
    //   62078 端口，然后发 Pair 请求（见 ohos/OhosPairing.cpp）。
    //   用户选了「检测到设备就自动发起」，所以下面枚举到设备就自动触发。
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
        // 见到还没配对过的设备就自动发起一次配对（用户选的触发方式）。
        //
        // 注意放在这里而不是"仅当设备在采集配置下"：配对走的是 usbmux 接口，
        // 与采集（QuickTime 0x2A）是**两个不同的 USB 接口**，互相不冲突。
        //
        // udid 用归一化后的 serial：配对记录按它存进沙箱，换台设备插上时
        // 各自一份，互不串味。
        maybe_start_pairing(ohos::usb_device_id_of(usb_device), serial);
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
            ? L"设备 USB 可见且已切到采集配置；已自动发起配对请求，"
              L"请在 iPhone 上点「信任」。"
            : L"设备 USB 可见；已自动发起配对请求，请解锁 iPhone 并点「信任」。";
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
