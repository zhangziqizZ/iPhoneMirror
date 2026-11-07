// SPDX-License-Identifier: GPL-3.0-only
//
// OhosUsbFdTransport 的实现。语义与理由见同名头文件。

#include "OhosUsbFdTransport.h"

#include <cerrno>
#include <cstring>

#include <linux/usbdevice_fs.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <unistd.h>

namespace iPhoneMirror::ohos {

// errno → 一句能直接贴进诊断行的话。
//
// 为什么自己映射而不用 strerror：strerror 的文案随 libc 变，不同语言环境下
// 还会变成本地化文案，混进日志就不好比对了。这里自己定一套稳定的短词。
// ★ EPERM 与 EACCES 必须分开 ★：内核 usbfs 的自主检查（设备 unauthorized、
// 显式限制）返回 EPERM；SELinux 的 ioctl 拒绝返回 EACCES。两者处置方向
// 完全不同（内核策略 vs 沙箱策略）。
const char* usb_errno_text(int code) noexcept {
    switch (code) {
    case 0:
        return "ok";
    case ETIMEDOUT:
        return "timeout";
    case ENODEV:
        return "no such device";
    case EPIPE:
        return "endpoint stalled";
    case EIO:
        return "io error";
    case EPERM:
        return "operation not permitted";
    case EACCES:
        return "access denied (selinux?)";
    case EBUSY:
        return "busy";
    case EINVAL:
        return "invalid argument";
    case ENOMEM:
        return "out of memory";
    case ENOBUFS:
        return "no buffer";
    case EINTR:
        return "interrupted";
    default:
        return "unknown error";
    }
}

const char* OhosUsbFdTransport::last_error_text() const noexcept {
    return usb_errno_text(last_error_);
}

namespace {

// 在 discard 后等内核把 urb 交回来。usbfs 保证 discard 过的 urb 必有
// 完成事件；REAPURBNDELAY 拿不到就短睡重试（上限 drain_ms）。本 fd 同时
// 只有一个 urb 在飞，reap 到哪个都是它。
bool reap_submitted(int fd, int drain_ms) noexcept {
    const int rounds = drain_ms / 5;
    for (int i = 0; i < rounds; ++i) {
        struct usbdevfs_urb* reaped = nullptr;
        if (ioctl(fd, USBDEVFS_REAPURBNDELAY, &reaped) == 0 &&
            reaped != nullptr) {
            return true;
        }
        if (errno == EINTR) {
            --i;
            continue;
        }
        usleep(5000);
    }
    return false;
}

} // namespace

// ── bulk 传输：URB 异步路径 ─────────────────────────────────────
//
// ★ 为什么不走同步的 USBDEVFS_BULK ★（2026-10-31 真机探针确证）
//
// 同步 BULK ioctl 被 SELinux 在命令级拒绝（EACCES），而
// CLAIMINTERFACE / SUBMITURB / DISCARDURB / REAPURBNDELAY 全部放行 ——
// 白名单是按 libusb 的 ioctl 需求定的，libusb 在 Linux 上从不使用同步
// BULK，恰好把它漏掉了。所以 bulk 收发改走 libusb 同款：
//   SUBMITURB 提交 → poll(fd, 超时) → REAPURBNDELAY 收割。
//
// 语义与同步路径的对齐：
//   · 超时：同步路径内核会 kill URB 并丢掉已收部分；这里对应
//     DISCARDURB。区别：已收的部分数据会随 -ECONNRESET 交回，有就如实
//     带回（读按端点包长请求，残余最多一包，调用方能处理）。
//   · endpoint 传完整端点地址（含 0x80 方向位），与 libusb 一致。
//   · length == 0 合法（零长包 ZLP）：内核会提交一个零长 URB。
int OhosUsbFdTransport::urb_bulk(std::uint8_t endpoint, void* buffer,
    std::size_t length, std::uint32_t timeout_ms) {
    std::uint8_t dummy = 0;
    if (buffer == nullptr) {
        buffer = &dummy;   // 零长包也要给内核一个合法指针
    }

    struct usbdevfs_urb urb{};
    urb.type = USBDEVFS_URB_TYPE_BULK;
    urb.endpoint = endpoint;
    urb.buffer = buffer;
    urb.buffer_length = static_cast<unsigned int>(length);

    if (ioctl(fd_, USBDEVFS_SUBMITURB, &urb) != 0) {
        last_error_ = errno;
        return -1;
    }

    struct pollfd pfd {fd_, POLLIN | POLLERR, 0};
    int pr;
    do {
        pr = poll(&pfd, 1,
            timeout_ms > 0 ? static_cast<int>(timeout_ms) : 1000);
    } while (pr < 0 && errno == EINTR);

    if (pr == 0) {
        // 超时：丢弃并回收。部分数据随 -ECONNRESET 交回时有就带回。
        (void)ioctl(fd_, USBDEVFS_DISCARDURB, &urb);
        if (reap_submitted(fd_, 1000) && urb.actual_length > 0) {
            last_error_ = 0;
            return static_cast<int>(urb.actual_length);
        }
        last_error_ = ETIMEDOUT;
        return -1;
    }
    if (pr < 0) {
        last_error_ = errno;
        (void)ioctl(fd_, USBDEVFS_DISCARDURB, &urb);
        (void)reap_submitted(fd_, 100);
        return -1;
    }

    // 完成事件：REAPURBNDELAY 收割（poll 已报告事件，正常一轮就中）。
    for (int round = 0; round < 100; ++round) {
        struct usbdevfs_urb* reaped = nullptr;
        if (ioctl(fd_, USBDEVFS_REAPURBNDELAY, &reaped) == 0 &&
            reaped != nullptr) {
            if (reaped->status == 0) {
                last_error_ = 0;
                return static_cast<int>(reaped->actual_length);
            }
            // status 是负 errno：-EPIPE = 端点 stall，-ENODEV/-EPROTO = 链路层。
            last_error_ = -reaped->status;
            return -1;
        }
        if (errno == EINTR) {
            --round;
            continue;
        }
        if (errno == EAGAIN) {
            usleep(1000);
            continue;
        }
        last_error_ = errno;
        return -1;
    }
    last_error_ = EIO;
    return -1;
}

int OhosUsbFdTransport::bulk_read(std::uint8_t endpoint, void* buffer,
    std::size_t length, std::uint32_t timeout_ms) {
    if (!valid() || buffer == nullptr || length == 0) {
        last_error_ = EINVAL;
        return -1;
    }
    return urb_bulk(endpoint, buffer, length, timeout_ms);
}

int OhosUsbFdTransport::bulk_write(std::uint8_t endpoint, const void* buffer,
    std::size_t length, std::uint32_t timeout_ms) {
    // ★ length == 0 合法（零长包 ZLP）★，buffer 在 len=0 时不解引用。
    if (!valid() || (buffer == nullptr && length > 0)) {
        last_error_ = EINVAL;
        return -1;
    }
    return urb_bulk(endpoint, const_cast<void*>(buffer), length, timeout_ms);
}

int OhosUsbFdTransport::control_read(std::uint8_t bm_request_type,
    std::uint8_t b_request, std::uint16_t w_value, std::uint16_t w_index,
    void* buffer, std::uint16_t w_length, std::uint32_t timeout_ms) {
    if (!valid() || (buffer == nullptr && w_length > 0)) {
        last_error_ = EINVAL;
        return -1;
    }

    struct usbdevfs_ctrltransfer ctrl{};
    ctrl.bRequestType = bm_request_type;
    ctrl.bRequest = b_request;
    ctrl.wValue = w_value;
    ctrl.wIndex = w_index;
    ctrl.wLength = w_length;
    ctrl.timeout = timeout_ms;
    ctrl.data = buffer;

    const int result = ioctl(fd_, USBDEVFS_CONTROL, &ctrl);
    if (result < 0) {
        last_error_ = errno;
        return -1;
    }
    last_error_ = 0;
    // USBDEVFS_CONTROL 成功时 ioctl 返回值就是**实际传输的字节数**
    // （devio.c: proc_control() → copy_to_user 后 return ctrl.wLength 之前的
    //  实际值；短包时小于 wLength）。
    return result;
}

int OhosUsbFdTransport::control_write(std::uint8_t bm_request_type,
    std::uint8_t b_request, std::uint16_t w_value, std::uint16_t w_index,
    const void* buffer, std::uint16_t w_length, std::uint32_t timeout_ms) {
    if (!valid() || (buffer == nullptr && w_length > 0)) {
        last_error_ = EINVAL;
        return -1;
    }

    struct usbdevfs_ctrltransfer ctrl{};
    ctrl.bRequestType = bm_request_type;
    ctrl.bRequest = b_request;
    ctrl.wValue = w_value;
    ctrl.wIndex = w_index;
    ctrl.wLength = w_length;
    ctrl.timeout = timeout_ms;
    ctrl.data = const_cast<void*>(buffer);

    const int result = ioctl(fd_, USBDEVFS_CONTROL, &ctrl);
    if (result < 0) {
        last_error_ = errno;
        return -1;
    }
    last_error_ = 0;
    return result;
}

int OhosUsbFdTransport::set_interface(std::uint8_t interface_number,
    std::uint8_t alternate_setting) {
    if (!valid()) {
        last_error_ = EINVAL;
        return -1;
    }

    // USBDEVFS_SETINTERFACE 的参数是 struct usbdevfs_setinterface
    // （接口号 + 备用设置号），两者都是 0 基的值，与描述符一致。
    struct usbdevfs_setinterface setting{};
    setting.interface = interface_number;
    setting.altsetting = alternate_setting;
    if (ioctl(fd_, USBDEVFS_SETINTERFACE, &setting) < 0) {
        last_error_ = errno;
        return -1;
    }
    last_error_ = 0;
    return 0;
}

int OhosUsbFdTransport::set_configuration(std::uint16_t configuration_value,
    std::uint32_t timeout_ms) {
    if (!valid()) {
        last_error_ = EINVAL;
        return -1;
    }

    // 内核 usbfs 的 USBDEVFS_SETCONFIGURATION 参数是**配置值**
    // （usbdevfs_setconfiguration 直接把 unsigned int 交给
    //  usb_set_configuration()，后者用 find_config() 按 bConfigurationValue
    //  匹配），不是 0 基索引。
    //
    // 这个 ioctl 本身不传超时（内核在这一步是同步的），timeout_ms 只是为了
    // 与本类其它方法的签名保持一致，忽略即可。
    (void)timeout_ms;
    unsigned int value = configuration_value;
    if (ioctl(fd_, USBDEVFS_SETCONFIGURATION, &value) < 0) {
        last_error_ = errno;
        return -1;
    }
    last_error_ = 0;
    return 0;
}

int OhosUsbFdTransport::clear_halt(std::uint8_t endpoint) {
    if (!valid()) {
        last_error_ = EINVAL;
        return -1;
    }

    // USBDEVFS_CLEAR_HALT 的参数是**完整端点地址**（含方向位）。
    //
    // 内核 usb_clear_halt() 做两件事：向设备发 CLEAR_FEATURE(ENDPOINT_HALT)，
    // 并把主机侧该管道的 toggle 复位到 DATA0。设备复位/重新枚举之后
    // 主机侧的旧 toggle 会与设备不一致 → 第一个包被静默丢弃。
    unsigned int value = endpoint;
    if (ioctl(fd_, USBDEVFS_CLEAR_HALT, &value) < 0) {
        last_error_ = errno;
        return -1;
    }
    last_error_ = 0;
    return 0;
}

} // namespace iPhoneMirror::ohos
