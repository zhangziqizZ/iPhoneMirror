// SPDX-License-Identifier: GPL-3.0-only
//
// OhosUsbFdDevice 的实现。语义与理由见同名头文件。
//
// 本文件全部走**控制传输**（device recipient 的标准请求 + Apple 厂商请求），
// 内核对这两类请求都免认领接口（check_ctrlrecip()：vendor 直接放行、
// standard+device 不触发 checkintf），所以读描述符不需要先认领任何东西。
// 唯一改设备状态的动作是 SET_CONFIGURATION（仅当活动配置里没有 usbmux
// 接口时）。

#include "OhosUsbFdDevice.h"

#include "Logging.h"
#include "OhosUsbDiagnostics.h"
#include "OhosUsbFdTransport.h"

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <format>
#include <string>
#include <vector>

#include <linux/usbdevice_fs.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <unistd.h>

namespace iPhoneMirror::ohos {
namespace {

constexpr std::uint8_t ReqGetDescriptor = 6;      // GET_DESCRIPTOR
constexpr std::uint8_t ReqGetConfiguration = 8;   // GET_CONFIGURATION
constexpr std::uint8_t DescConfiguration = 2;     // 配置描述符类型
constexpr std::uint8_t DescInterface = 4;         // 接口描述符类型
constexpr std::uint8_t DescEndpoint = 5;          // 端点描述符类型
constexpr std::uint16_t LangIdEnUs = 0x0409;      // 英语（美国），DDK 路径同款

// usbmux 接口的匹配口径 —— 上游 usbmuxd 的 **OR** 规则
// （src/usb.c set_valid_configuration()：三个条件任一命中即候选）。
constexpr std::uint8_t VendorInterfaceClass = 0xFF;
constexpr std::uint8_t UsbMuxSubclass = 0xFE;
constexpr std::uint8_t UsbMuxProtocol = 2;

// 一个候选：某个配置里"凑齐了 bulk IN + bulk OUT"的 usbmux 接口。
struct MuxCandidate {
    std::uint8_t config_value{0};
    std::uint8_t interface_number{0};
    std::uint8_t alternate_setting{0};
    std::uint8_t bulk_in{0};
    std::uint8_t bulk_out{0};
    std::uint16_t packet_size{0};
};

// 读一份完整的配置描述符（先读 9 字节头拿 wTotalLength，再读全文）。
[[nodiscard]] bool read_full_config_descriptor(OhosUsbFdTransport& transport,
    std::uint8_t index, std::vector<std::uint8_t>& out, int& err) {
    std::uint8_t header[9] = {};
    if (transport.control_read(0x80, ReqGetDescriptor,
            static_cast<std::uint16_t>(0x0200U | index), 0,
            header, 9, 1000) < 9) {
        err = transport.last_error();
        return false;
    }
    // wTotalLength 在偏移 2（小端 16 位）。
    const std::uint16_t total =
        static_cast<std::uint16_t>(header[2] | (header[3] << 8U));
    if (total < 9 || total > 4096) {
        err = EINVAL;
        return false;
    }
    out.assign(total, 0);
    if (transport.control_read(0x80, ReqGetDescriptor,
            static_cast<std::uint16_t>(0x0200U | index), 0,
            out.data(), total, 1000) < total) {
        err = transport.last_error();
        return false;
    }
    return true;
}

// 在一份配置描述符字节流里就地收集 usbmux 候选。
//
// 布局规则（USB 规范）：接口描述符后面紧跟着它自己的全部端点描述符，
// 直到下一个接口/配置描述符为止。所以扫到接口描述符就向后收集端点。
void collect_mux_candidates(const std::vector<std::uint8_t>& config,
    std::uint8_t config_value, std::vector<MuxCandidate>& out) {
    std::size_t pos = 0;
    while (pos + 2 <= config.size()) {
        const std::uint8_t length = config[pos];
        if (length < 2 || pos + length > config.size()) break;
        const std::uint8_t type = config[pos + 1];

        if (type == DescInterface && length >= 9) {
            // 接口描述符布局：bLength(0) bDescriptorType(1)
            //   bInterfaceNumber(2) bAlternateSetting(3) bNumEndpoints(4)
            //   bInterfaceClass(5) bInterfaceSubClass(6) bInterfaceProtocol(7)
            const std::uint8_t* d = config.data() + pos;
            const std::uint8_t interface_class = d[5];
            const std::uint8_t interface_subclass = d[6];
            const std::uint8_t interface_protocol = d[7];
            if (interface_class == VendorInterfaceClass ||
                interface_subclass == UsbMuxSubclass ||
                interface_protocol == UsbMuxProtocol) {
                MuxCandidate candidate;
                candidate.config_value = config_value;
                candidate.interface_number = d[2];
                candidate.alternate_setting = d[3];

                // 收集该 altsetting 名下的端点（直到下一个接口/配置描述符）。
                std::size_t endpoint_pos = pos + length;
                while (endpoint_pos + 2 <= config.size()) {
                    const std::uint8_t endpoint_length = config[endpoint_pos];
                    if (endpoint_length < 2 ||
                        endpoint_pos + endpoint_length > config.size()) break;
                    const std::uint8_t endpoint_type = config[endpoint_pos + 1];
                    if (endpoint_type == DescInterface ||
                        endpoint_type == DescConfiguration) break;
                    if (endpoint_type == DescEndpoint && endpoint_length >= 7) {
                        // 端点描述符布局：bLength(0) bDescriptorType(1)
                        //   bEndpointAddress(2) bmAttributes(3)
                        //   wMaxPacketSize(4,5 小端) bInterval(6)
                        const std::uint8_t* e = config.data() + endpoint_pos;
                        const std::uint8_t address = e[2];
                        const std::uint8_t attributes = e[3];
                        const std::uint16_t max_packet =
                            static_cast<std::uint16_t>(
                                e[4] | (static_cast<std::uint16_t>(e[5]) << 8U));
                        if ((attributes & 0x03U) == 0x02U) {   // bulk
                            if ((address & 0x80U) != 0) {
                                candidate.bulk_in = address;
                            } else {
                                candidate.bulk_out = address;
                            }
                            if (max_packet > candidate.packet_size) {
                                candidate.packet_size = max_packet;
                            }
                        }
                    }
                    endpoint_pos += endpoint_length;
                }
                if (candidate.bulk_in != 0 && candidate.bulk_out != 0) {
                    out.push_back(candidate);
                }
            }
        }
        pos += length;
    }
}

// 从候选里挑最好的：活动配置优先；同配置内 alt 0 优先
// （alt 0 是上电默认设置，切 alt 是全设备可见动作，能不切就不切）。
[[nodiscard]] const MuxCandidate* pick_candidate(
    const std::vector<MuxCandidate>& all, std::uint8_t active_config) {
    const MuxCandidate* best = nullptr;
    for (const auto& candidate : all) {
        if (best == nullptr) {
            best = &candidate;
            continue;
        }
        const bool candidate_active =
            candidate.config_value == active_config;
        const bool best_active = best->config_value == active_config;
        if (candidate_active != best_active) {
            if (candidate_active) best = &candidate;
            continue;
        }
        if (best->alternate_setting != 0 && candidate.alternate_setting == 0) {
            best = &candidate;
        }
    }
    return best;
}

// UTF-16LE → UTF-8（字符串描述符载荷就是它）。
// UDID 全是 ASCII，但转换器按规范写全，避免将来读 iProduct 之类的丢字。
std::string utf16le_to_utf8(const std::uint8_t* data, std::size_t bytes) {
    std::string out;
    out.reserve(bytes / 2);
    for (std::size_t i = 0; i + 1 < bytes; i += 2) {
        const std::uint32_t unit = static_cast<std::uint32_t>(data[i]) |
            (static_cast<std::uint32_t>(data[i + 1]) << 8U);
        if (unit < 0x80U) {
            out.push_back(static_cast<char>(unit));
        } else if (unit < 0x800U) {
            out.push_back(static_cast<char>(0xC0U | (unit >> 6U)));
            out.push_back(static_cast<char>(0x80U | (unit & 0x3FU)));
        } else {
            out.push_back(static_cast<char>(0xE0U | (unit >> 12U)));
            out.push_back(static_cast<char>(0x80U | ((unit >> 6U) & 0x3FU)));
            out.push_back(static_cast<char>(0x80U | (unit & 0x3FU)));
        }
    }
    return out;
}

// 读一个字符串描述符（两步：先拿 bLength，再读全文）。
// 两步而不是一步读 255：部分设备对超长字符串请求会 STALL。
[[nodiscard]] bool read_string_descriptor(OhosUsbFdTransport& transport,
    std::uint8_t index, std::string& out) {
    std::uint8_t header[2] = {};
    if (transport.control_read(0x80, ReqGetDescriptor,
            static_cast<std::uint16_t>(0x0300U | index), LangIdEnUs,
            header, 2, 1000) < 2) {
        return false;
    }
    const std::uint8_t length = header[0];
    if (length < 2 || length > 255) return false;

    std::vector<std::uint8_t> buffer(length, 0);
    if (transport.control_read(0x80, ReqGetDescriptor,
            static_cast<std::uint16_t>(0x0300U | index), LangIdEnUs,
            buffer.data(), length, 1000) < length) {
        return false;
    }
    // 载荷从偏移 2 开始（前 2 字节是 bLength + bDescriptorType）。
    out = utf16le_to_utf8(buffer.data() + 2, length - 2);
    return true;
}

} // namespace

bool discover_usb_fd_mux(OhosUsbFdTransport& transport,
    OhosUsbFdMuxInfo& info, std::string& error) {
    // ① 设备描述符：拿 bNumConfigurations（偏移 17）与 iSerialNumber（偏移 16）。
    std::uint8_t device[18] = {};
    if (transport.control_read(0x80, ReqGetDescriptor, 0x0100, 0,
            device, 18, 1000) < 18) {
        error = std::format("读设备描述符失败：{}", transport.last_error_text());
        return false;
    }
    const std::uint8_t num_configurations = device[17];
    const std::uint8_t serial_index = device[16];
    if (num_configurations == 0) {
        error = "设备没有配置描述符";
        return false;
    }

    // ② 活动配置（GET_CONFIGURATION，bRequest=8，device recipient 免认领）。
    std::uint8_t active_config = 0;
    if (transport.control_read(0x80, ReqGetConfiguration, 0, 0,
            &active_config, 1, 1000) < 1) {
        error = std::format("读活动配置失败：{}", transport.last_error_text());
        return false;
    }

    // ③ 逐个配置收集 usbmux 候选。
    std::vector<MuxCandidate> all;
    for (std::uint8_t index = 0; index < num_configurations; ++index) {
        std::vector<std::uint8_t> config;
        int err = 0;
        if (!read_full_config_descriptor(transport, index, config, err)) {
            ohos_usb_diag::note(std::format(
                "fd 通道：配置 {} 描述符读取失败（{}）", index,
                err == ETIMEDOUT ? "超时" : "错误"));
            continue;
        }
        // 配置描述符的 bConfigurationValue 在偏移 5。
        collect_mux_candidates(config, config[5], all);
    }
    if (all.empty()) {
        error = "所有配置里都没有带 bulk IN/OUT 对的 usbmux 接口"
            "（0xFF/0xFE/2 任一命中）";
        return false;
    }

    // ④ 选候选；活动配置里没有就切配置（主机选定配置是 USB 规范职责）。
    const MuxCandidate* chosen = pick_candidate(all, active_config);
    if (chosen == nullptr) {   // 理论上到不了（all 非空）
        error = "内部错误：候选挑选失败";
        return false;
    }
    if (chosen->config_value != active_config) {
        logging::write(logging::Level::Info, "usbmux", std::format(
            "fd 通道：活动配置 {} 没有 usbmux 接口，切换到配置 {}",
            active_config, chosen->config_value));
        if (transport.set_configuration(chosen->config_value, 1000) != 0) {
            error = std::format("切换 USB 配置到 {} 失败：{}（若设备接口已被"
                "其它进程认领，内核会拒绝切配置）", chosen->config_value,
                transport.last_error_text());
            return false;
        }
        // 切完再读一次确认，设备拒绝切换时能如实报出来。
        std::uint8_t confirmed = 0;
        if (transport.control_read(0x80, ReqGetConfiguration, 0, 0,
                &confirmed, 1, 1000) == 1) {
            active_config = confirmed;
        } else {
            active_config = chosen->config_value;
        }
    }

    // ⑤ 序列号（iPhone 上就是 UDID）。读不到不致命：诊断里记一笔即可。
    std::string serial;
    if (serial_index != 0) {
        if (!read_string_descriptor(transport, serial_index, serial)) {
            ohos_usb_diag::note(std::format(
                "fd 通道：序列号（iSerialNumber={}）读取失败：{}",
                serial_index, transport.last_error_text()));
        }
    } else {
        ohos_usb_diag::note("fd 通道：设备没有提供序列号字符串");
    }

    info.serial = serial;
    info.active_config = active_config;
    info.interface_number = chosen->interface_number;
    info.alternate_setting = chosen->alternate_setting;
    info.bulk_in = chosen->bulk_in;
    info.bulk_out = chosen->bulk_out;
    info.config_value = chosen->config_value;
    info.packet_size = chosen->packet_size;

    ohos_usb_diag::note(std::format(
        "fd 通道定位完成：UDID={} 活动配置={} 接口={} alt={} "
        "in=0x{:02x} out=0x{:02x} 包长={}",
        serial.empty() ? "(无)" : serial, active_config,
        chosen->interface_number, chosen->alternate_setting,
        chosen->bulk_in, chosen->bulk_out, chosen->packet_size));
    return true;
}

bool read_usb_fd_serial(OhosUsbFdTransport& transport, std::string& serial,
    std::string& error) {
    std::uint8_t device[18] = {};
    if (transport.control_read(0x80, ReqGetDescriptor, 0x0100, 0,
            device, 18, 1000) < 18) {
        error = std::format("读设备描述符失败：{}", transport.last_error_text());
        return false;
    }
    const std::uint8_t serial_index = device[16];
    if (serial_index == 0) {
        error = "设备没有提供序列号字符串";
        return false;
    }
    if (!read_string_descriptor(transport, serial_index, serial)) {
        error = std::format("读序列号描述符失败：{}",
            transport.last_error_text());
        return false;
    }
    return true;
}

bool probe_usb_fd_alive(OhosUsbFdTransport& transport) {
    // 一次 GET_DESCRIPTOR（device recipient，免认领）就是完整的探活：
    // 设备重枚举后旧 fd 的 ioctl 全部 ENODEV，控制传输也不例外。
    std::uint8_t device[18] = {};
    return transport.control_read(0x80, ReqGetDescriptor, 0x0100, 0,
        device, 18, 1000) >= 18;
}

bool diagnose_usb_fd_access(OhosUsbFdTransport& transport,
    unsigned interface_number, std::uint8_t bulk_in_endpoint,
    std::string& report) {
    report.clear();
    const int fd = transport.fd();
    if (fd < 0) {
        report = "fd 无效";
        return false;
    }

    // 逐步落账：每条 ioctl 前后各发一条诊断。之前把四步结果拼成一行，
    // 某步阻塞时连"卡在哪"都看不见（真机出现过停在定位完成之后的悬置，
    // 嫌疑就是这里某条 ioctl 不返回）。

    struct usbdevfs_connectinfo ci{};
    if (ioctl(fd, USBDEVFS_CONNECTINFO, &ci) == 0) {
        ohos_usb_diag::note(std::format("fd 探针 CONNECTINFO=ok dev#{}{}",
            ci.devnum, ci.slow ? " lowspeed" : ""));
    } else {
        ohos_usb_diag::note(std::format("fd 探针 CONNECTINFO={}",
            usb_errno_text(errno)));
    }

    struct usbdevfs_getdriver gd{};
    gd.interface = interface_number;
    if (ioctl(fd, USBDEVFS_GETDRIVER, &gd) == 0) {
        ohos_usb_diag::note(std::format("fd 探针 if{} driver={}",
            interface_number, gd.driver));
    } else {
        // ENODATA = 没有驱动占用（正常，我们要的态）。
        ohos_usb_diag::note(std::format("fd 探针 if{} GETDRIVER={}",
            interface_number,
            errno == ENODATA ? "无占用" : usb_errno_text(errno)));
    }

    ohos_usb_diag::note("fd 探针 CLAIM 发出");
    unsigned int ifnum = interface_number;
    if (ioctl(fd, USBDEVFS_CLAIMINTERFACE, &ifnum) == 0) {
        ohos_usb_diag::note(std::format("fd 探针 if{} CLAIM=ok",
            interface_number));
    } else {
        ohos_usb_diag::note(std::format("fd 探针 if{} CLAIM={}",
            interface_number, usb_errno_text(errno)));
    }

    // SUBMITURB 探针：libusb 在 Linux 上**从不用同步的 USBDEVFS_BULK**，
    // 全部走 SUBMITURB / REAPURB / DISCARDURB。若系统白名单是按 libusb 的
    // 需求定的，同步 BULK 命令缺席而 URB 三件套在场完全可能 —— 同步路径
    // 报 access denied 而这条探针放行的话，把 bulk 换成 URB 路径就是正解。
    // 读 1 字节 bulk IN、50ms 无数据就丢弃：此刻没有任何会话在跑，丢一个包
    // 没有影响（bulk IN 上本来就没有待收数据）。
    ohos_usb_diag::note("fd 探针 SUBMITURB 发出");
    std::uint8_t urb_buffer[1] = {};
    struct usbdevfs_urb urb{};
    urb.type = USBDEVFS_URB_TYPE_BULK;
    urb.endpoint = bulk_in_endpoint;
    urb.buffer = urb_buffer;
    urb.buffer_length = sizeof(urb_buffer);

    if (ioctl(fd, USBDEVFS_SUBMITURB, &urb) != 0) {
        ohos_usb_diag::note(std::format("fd 探针 SUBMITURB={}",
            usb_errno_text(errno)));
    } else {
        // 等 50ms：有数据就 reap 看结果；没有就丢弃（丢弃后必须 reap，
        // 内核要完成取消并把 urb 归还，多次短轮询避免永久阻塞）。
        struct pollfd pfd {fd, POLLIN, 0};
        const int pr = poll(&pfd, 1, 50);
        ohos_usb_diag::note(pr > 0 ? "fd 探针 poll=有事件"
                                   : "fd 探针 poll=超时50ms");
        if (pr > 0) {
            struct usbdevfs_urb* reaped = nullptr;
            if (ioctl(fd, USBDEVFS_REAPURBNDELAY, &reaped) == 0 &&
                reaped != nullptr) {
                ohos_usb_diag::note(std::format(
                    "fd 探针 SUBMITURB=ok status={} len={}",
                    reaped->status, reaped->actual_length));
            } else {
                ohos_usb_diag::note(std::format("fd 探针 REAPURB={}",
                    usb_errno_text(errno)));
            }
        } else {
            // 丢弃后必须把 urb 完整收回再继续：遗留的 urb 会蹲在端点队列
            // 里，把设备的握手响应字节吃进我们的探针缓冲 —— 后续协议
            // 全乱。内核对已 discard 的 urb 完成取消是毫秒级的；这里给
            // 2 秒余量，实在收不回就如实记一笔（本轮握手注定失败）。
            (void)ioctl(fd, USBDEVFS_DISCARDURB, &urb);
            ohos_usb_diag::note("fd 探针 DISCARDURB 发出");
            bool reaped_ok = false;
            for (int i = 0; i < 200; ++i) {
                struct usbdevfs_urb* reaped = nullptr;
                if (ioctl(fd, USBDEVFS_REAPURBNDELAY, &reaped) == 0 &&
                    reaped != nullptr) {
                    reaped_ok = true;
                    break;
                }
                usleep(10000);
            }
            ohos_usb_diag::note(reaped_ok
                ? "fd 探针 SUBMITURB=ok（50ms 无数据，命令放行）"
                : "fd 探针 SUBMITURB=ok 但 urb 未收回（本轮握手会失败）");
        }
    }

    report = "探针已逐步落账";
    return true;
}

} // namespace iPhoneMirror::ohos
