// SPDX-License-Identifier: GPL-3.0-only
//
// 基于 usbfs fd 的 USB 传输层（usbManager 备用通道的 native 半边）。
//
// ★ 为什么需要这一层 ★
//
// 鸿蒙上应用访问 USB 有两条完全不同的路：
//
//   A. USB DDK（ohos.permission.ACCESS_DDK_USB）
//      · 权限是 system_basic + provisionEnable=true ⇒ 必须进签名 profile 的
//        allowed-acls。本工程的 profile 由 AGC 签发、本地改不了 ⇒ 装包被拒
//        （9568289）。**这条���上不了**。
//      · 设备按 VID/PID 过滤后才出现在 OH_Usb_GetDevices() 里 ⇒ 还依赖驱动
//        扩展被 bind，绑定失败同样枚举为空。
//
//   B. @ohos.usbManager（设备级授权）
//      · 权限存在**设备的 DB 记录**里（UsbRightManager），由
//        requestRight() 弹一次系统授权窗换来；授权一次长期有效
//        （validPeriod = USB_RIGHT_VALID_PERIOD_SET），不查签名 ACL。
//      · getDevices() **不按 VID 过滤**，所以不需要驱动扩展。
//
// ★ 本文件实现 B 通道的 native 半边 ★
//
// ArkTS 侧用 usbManager.getFileDescriptor(pipe) 拿到的 fd，服务端是这么开的：
//
//     fd = open("/dev/bus/usb/%03u/%03u", O_RDWR);   ← libusb_adapter.cpp
//
// 也就是**标准 Linux usbfs 节点**。内核 usbfs 的 bulk 传输原语是
// USBDEVFS_BULK ioctl，本文件封装它；控制传输原语是 USBDEVFS_CONTROL。
//
// ── 内核语义（逐条核对 openharmony/kernel_linux 的 drivers/usb/core/devio.c）──
//
// ★ 1. bulk 的端点参数传的是**完整端点地址**（含 0x80 方向位）★
//
//     proc_bulk():
//         copy_from_user(&bulk, arg, sizeof(bulk));
//         ret = findintfep(ps->dev, bulk.ep);
//
//     findintfep() 里的比对是：
//         if (endpt->bEndpointAddress == ep)      ← bEndpointAddress 是含方向位的
//             return alts->desc.bInterfaceNumber;
//
//     所以 bulk.ep = 0x81（IN）/ 0x02（OUT）这样的**地址**，不是端点号。
//
// ★ 2. bulk 传输会**自动为这个 fd 认领接口** ★
//
//     proc_bulk() → checkintf(ps, ifnum) → claimintf(ps, ifnum)
//
//     而 claimintf() 里认领前先看本 fd 自己的账：
//         if (test_bit(ifnum, &ps->ifclaimed))
//             return 0;                          ← 本 fd 已认领过，直接放行
//
//     ps 是**这个 open 文件描述符私有**的 usb_dev_state，所以每个 fd 各记各的。
//     ⇒ 我们自己 open 出来的 fd 与 USB 服务侧 libusb 的 fd **互不冲突**。
//
// ★ 3. claim 失败只可能来自"别的内核驱动占了这个接口" ★
//
//     usb_driver_claim_interface() 里只有一处判据：
//         dev = &iface->dev;
//         if (dev->driver)
//             return -EBUSY;
//     dev->driver 是**内核驱动模型**里绑在接口上的驱动（usbhid/cdc_acm 之类）。
//     usbfs 自己不是内核驱动，它的认领走 usbfs_driver，**不占 dev->driver**。
//     ⇒ 只要没有别的内核驱动抢这个接口，认领就一定成功。
//
// ★ 4. vendor 控制传输**不需要认领接口** ★
//
//     check_ctrlrecip() 第一条判断：
//         if (USB_TYPE_VENDOR == (USB_TYPE_MASK & requesttype))
//             return 0;
//     ⇒ 像 Apple 的 GET_MODE(0x45, bmRequestType=0xC0) 这种厂商请求，
//       直接就能发，不用先认领接口。
//
// ★ 5. 标准控制传输（GET_CONFIGURATION 等）走 device recipient，也免认领 ★
//
//     check_ctrlrecip() 对 USB_RECIP_DEVICE 的标准请求同样直接返回 0。
//
// ── 因此本文件的取舍 ──
//
// · **不主动调 USBDEVFS_CLAIMINTERFACE**：bulk 传输自己会 claim（见第 2 条），
//   而 claim 是**按 fd 记账**的，多此一举反而多一个失败点。控制传输也不需要
//   （见第 3、4、5 条）。真要显式认领，那是 USBDEVFS_CLAIMINTERFACE，但本
//   文件不依赖它。
// · **传输用同步 ioctl 而不是异步 URB**：usbmux 是"一问一答"的请求/响应协议，
//   同步 ioctl 的语义（阻塞到传输完成或超时）正好对上；异步 URB 还要自己
//    reap，等于把内核已经做好的事重做一遍。
// · 超时值透传给内核（usbdevfs_bulktransfer.timeout，单位毫秒），由内核负责
//   等待；本文件不自己轮询。

#pragma once

#include <cstddef>
#include <cstdint>

namespace iPhoneMirror::ohos {

// errno → 稳定短词（不随 libc/locale 变）。EPERM 与 EACCES 分开返回：
// 内核 usbfs 的自主检查走 EPERM，SELinux 的拒绝走 EACCES，处置方向不同。
[[nodiscard]] const char* usb_errno_text(int code) noexcept;

// 一个"打开着的 usbfs 设备 fd"上的传输器。
//
// 生命周期：fd 由构造者传入，本对象**不接管所有权**也不负责 close ——
// fd 的来源是 ArkTS 侧 usbManager.getFileDescriptor()，它属于 USB 服务那次
// open 的结果，跨进程传来后在本进程里是独立的一份。关不关由上层决定
// （本工程的调用链上没人关它：usbManager.closePipe() 关的是服务侧的 pipe，
// 不是这个 fd）。
class OhosUsbFdTransport {
public:
    explicit OhosUsbFdTransport(int fd) noexcept : fd_(fd) {}

    OhosUsbFdTransport(const OhosUsbFdTransport&) = delete;
    OhosUsbFdTransport& operator=(const OhosUsbFdTransport&) = delete;

    [[nodiscard]] bool valid() const noexcept { return fd_ >= 0; }
    [[nodiscard]] int fd() const noexcept { return fd_; }

    // 一次 bulk 读：把设备发来的数据搬进 buffer。
    //
    // endpoint 是**完整端点地址**（0x81 这类，含方向位）—— 见文件头第 1 条。
    // timeout_ms 是内核等待的上限；超时内核返回 -ETIMEDOUT。
    //
    // 返回读到的字节数；失败返回 -1，errno 里是具体原因（ETIMEDOUT / ENODEV …）。
    int bulk_read(std::uint8_t endpoint, void* buffer, std::size_t length,
        std::uint32_t timeout_ms);

    // 一次 bulk 写：把 buffer 里的数据发给设备。
    //
    // ★ length == 0 是合法的（发零长包 ZLP）★
    //   USB bulk 传输"一包数据是否发完"是由短包/零长包告诉对方的。当载荷
    //   恰好是端点包长的整数倍时，设备侧的 bulk IN 读会一直等下一包 ——
    //   这时必须补一个零长包。上游 usbmuxd 的 usb_send() 就是这么做的。
    //   返回写出的字节数（0 = 成功发出零长包）；失败返回 -1。
    int bulk_write(std::uint8_t endpoint, const void* buffer,
        std::size_t length, std::uint32_t timeout_ms);

    // 一次控制传输（读）。
    //
    // bmRequestType / bRequest / wValue / wIndex / wLength 与 USB 规范一致。
    // 返回读到的字节数；失败返回 -1。
    int control_read(std::uint8_t bm_request_type, std::uint8_t b_request,
        std::uint16_t w_value, std::uint16_t w_index, void* buffer,
        std::uint16_t w_length, std::uint32_t timeout_ms);

    // 一次控制传输（写）。
    // 返回写出的字节数；失败返回 -1。
    int control_write(std::uint8_t bm_request_type, std::uint8_t b_request,
        std::uint16_t w_value, std::uint16_t w_index, const void* buffer,
        std::uint16_t w_length, std::uint32_t timeout_ms);

    // 切换接口的备用设置（标准请求 SET_INTERFACE）。
    //
    // 仅当 usbmux 接口的 alt != 0 时才需要（绝大多数设备 usbmux 就在 alt 0）。
    // 切换是**全设备可见**的动作，会重置该接口的端点状态。
    // 返回 0 表示成功；失败返回 -1。
    int set_interface(std::uint8_t interface_number,
        std::uint8_t alternate_setting);

    // 切换设备的 USB 配置（标准请求 SET_CONFIGURATION）。
    //
    // ★ 语义与风险 ★
    //   · wValue 是**配置值**（bConfigurationValue），不是配置描述符的 0 基
    //     索引。这两者对 iPhone 恰好常常相等（bConfigurationValue 从 1 开始，
    //     索引从 0 开始，所以索引 = 值 - 1），但语义上必须按"值"传 ——
    //     内核 usb_set_configuration() 是 find_config() 按**值**找的。
    //   · 这是**全设备可见**的动作：切配置会让设备重新枚举接口，正在用
    //     其它配置的传输（比如本工程的采集链路）会被打断。
    //   · 内核 proc_setconfig() 会先查**当前活动配置**里有没有接口被认领，
    //     有就返回 -EBUSY ⇒ **必须先定位好端点、再切配置、再做 bulk**。
    //     顺序反了就会自己把自己锁死。
    //
    // 返回 0 表示成功；失败返回 -1，errno 见 last_error()。
    int set_configuration(std::uint16_t configuration_value,
        std::uint32_t timeout_ms);

    // 清除端点的 halt 状态，并**重置主机侧的 DATA toggle**。
    //
    // ★ 为什么需要 ★
    // USB 的 bulk 端点有一个 DATA toggle（每包翻转）。设备被复位/重新枚举
    // 后，主机侧如果还留着旧的 toggle 值，发出去的第一个包 toggle 不匹配，
    // 设备会静默丢弃（不报错、不回 RST）—— 表现就是"连上了但收不到任何
    // 数据"，极难定位。
    //
    // 上游 tools/iostouch/qt/usbmux_usb.py 的 _initialize_claimed_interface()
    // 在认领接口后对 IN/OUT 两个端点各调一次 clear_halt，注释写得很清楚：
    //   "Reset the host pipe's DATA toggle as well as the device's.
    //    A raw CLEAR_FEATURE resets only the phone; on reopen Windows
    //    can retain the old toggle and silently drop the next packet."
    //
    // endpoint 传**完整端点地址**（0x81 / 0x02 这类，含方向位）。
    // 返回 0 表示成功；失败返回 -1，errno 见 last_error()。
    int clear_halt(std::uint8_t endpoint);

    // 最近一次失败的 errno（成功时为 0）。
    //
    // 为什么单独暴露：这些失败分别对应完全不同的处置（超时=设备没响应、
    // ENODEV=接口/端点不对、EPERM=SELinux 拦了），合并成一句"传输失败"
    // 会让排障只能靠猜。
    [[nodiscard]] int last_error() const noexcept { return last_error_; }

    // 最近一次失败的可读原因（"timeout" / "no such device" …）。
    [[nodiscard]] const char* last_error_text() const noexcept;

private:
    // bulk 收发的公共实现（URB 异步路径，读/写共用；见实现文件头注释）。
    // 返回实际传输字节数；失败返回 -1，errno 见 last_error()。
    int urb_bulk(std::uint8_t endpoint, void* buffer, std::size_t length,
        std::uint32_t timeout_ms);

    int fd_{-1};
    int last_error_{0};
};

} // namespace iPhoneMirror::ohos
