// SPDX-License-Identifier: GPL-3.0-only
//
// OhosUsbDdk.h 的实现。DDK 是**进程级**资源：OH_Usb_Init() 一次、退出前释放一次。
// 本文件用引用计数把它包成可安全多次构造/析构的 DdkSession。
//
// 为什么单独一个翻译单元：DDK 的初始化与错误码映射是纯粹的平台设施，
// 环境自检（OhosEnvironmentProbe.cpp）和传输层（OhosUsbTransport.cpp）都要用，
// 但两者不该因为共用这点东西而互相依赖。

#include "OhosUsbDdk.h"

#if IM_OHOS_USB_DDK_AVAILABLE

#include <mutex>

namespace iPhoneMirror::ohos_usb {
namespace {

// 引用计数与互斥量都放在函数内静态变量里：避免静态初始化顺序问题，
// 也避免为一个平台设施引入全局构造。
std::mutex& init_mutex() noexcept {
    static std::mutex value;
    return value;
}

int& init_references() noexcept {
    static int value = 0;
    return value;
}

// ★ 本进程是否已经**成功** Init 过一次 DDK（会话常驻，不再 Release）。
// 与下面的 init_references() 是两件事：refs 管"当前有几个持有者"（可归零），
// 这个标志管"DDK 会话还在不在"（一旦成功就一直是 true）。
bool& session_alive() noexcept {
    static bool value = false;
    return value;
}

// OH_Usb_Init() 最近一次的返回值。**只给诊断用**，不参与"要不要再试一次"的判断
// （见 acquire() 里那段注释：拿它当闩锁判据正是上一版的事故根因）。
int& last_init_result() noexcept {
    static int value = 0;
    return value;
}

} // namespace

bool acquire() noexcept {
    try {
        std::scoped_lock lock(init_mutex());
        if (session_alive()) {
            ++init_references();
            return true;
        }
        // ★ 这里有两个"不要"，都是现场事故换来的，**别按直觉改回去**：
        //
        // 【一】不要缓存"已经试过一次"。
        // 最早那版用一个 init_attempted 布尔把"试过了"钉死，本意是"失败不重试"，
        // 却把**成功**也一起钉死 ⇒ 第二次 acquire() 起恒返回 false ⇒
        // DdkSession.ok() 为假 ⇒ enumerate() 第一行就 `return devices;` ⇒
        // 设备列表恒空（症状正是"软件识别不到 iPhone"）。更隐蔽的是
        // last_init_result() 里还留着上次的 0，probe() 于是打出
        // "USB DDK 初始化失败：OH_Usb_Init 返回 0：成功" —— 把唯一的线索抹掉。
        //
        // 【二】也不要"refs 归零就 Release、下次再 Init"。
        // 修掉【一】之后那样写了，结果是每 2 秒（UI 心跳）产生 2 轮
        // OH_Usb_Init/OH_Usb_ReleaseResource。而只 Init 一次的版本运行是稳的
        // ⇒ 2026-09-19 09:34 的三条 cppcrash。DDK 服务是本进程的**常驻**资源，
        // 用完就 Release、下次再 Init 不是它的用法。详见 release()。
        //
        // 失败**不**闩死：Init 失败时 session_alive() 保持 false，下个 tick 会重试。
        // 所以"权限补好之后还得重启应用"那个老毛病不会回来。
        last_init_result() = OH_Usb_Init();
        if (last_init_result() != USB_DDK_SUCCESS) {
            return false;
        }
        session_alive() = true;
        init_references() = 1;
        return true;
    } catch (...) {
        return false;
    }
}

void release() noexcept {
    try {
        std::scoped_lock lock(init_mutex());
        // ★ 只还引用计数，**故意不调用 OH_Usb_ReleaseResource()**。
        //
        // 为什么（2026-09-19 09:34 的 cppcrash，三条）：上一版在这里调
        // `OH_Usb_ReleaseResource()`，使 refs 归零后 DDK 会话被真的销毁，
        // 下个 tick 再 `OH_Usb_Init()` 重建 —— 于是每 2 秒 2 轮 Init/Release。
        // 而那个"只 Init 过一次"的版本运行是稳的，两者唯一的差别就是这段反复
        // Init/Release ⇒ 会话必须先销毁再重建这条路被证明会让进程崩。
        //
        // 语义上也该如此：本应用在运行期间**一直**要用 USB（预览是持续采集），
        // DDK 会话就该活到进程结束，而不是每 2 秒掐一次。进程退出时由系统回收。
        //
        // 注意这**不是**把"失败闩死"换个形式复活：这里只影响"成功之后要不要
        // 释放"，而"还没成功时要不要重试"由 acquire() 里的 session_alive() 管
        // —— Init 失败时它保持 false，下个 tick 照常重试。
        if (init_references() > 0) {
            --init_references();
        }
    } catch (...) {
    }
}

bool available() noexcept {
    // 编译期事实：本次构建的 SDK 有没有 usb_ddk_api.h。
    // "运行时能不能用"由 acquire() 的返回值回答。
    return true;
}

int last_init_error() noexcept {
    return last_init_result();
}

int to_libusb_style_error(int ddk_code) noexcept {
    // 上游 UsbError(operation, code) 只在日志与诊断里用这个值，所以取
    // "与 errno 同号同义"的负值：libusb 本身就是这么做的，读日志的人不会误判。
    switch (ddk_code) {
    case USB_DDK_SUCCESS: return 0;
    case USB_DDK_NO_PERM: return -13;              // EACCES：ACCESS_DDK_USB 没申下来
    case USB_DDK_INVALID_PARAMETER: return -22;    // EINVAL
    case USB_DDK_MEMORY_ERROR: return -12;         // ENOMEM
    case USB_DDK_NULL_PTR: return -22;             // EINVAL
    case USB_DDK_DEVICE_BUSY: return -16;          // EBUSY：接口已被占用
    case USB_DDK_INVALID_OPERATION: return -19;    // ENODEV：连不上 DDK 服务
    case USB_DDK_IO_FAILED: return -5;             // EIO
    case USB_DDK_TIMEOUT: return -110;             // ETIMEDOUT
    default: return ddk_code > 0 ? -1 : ddk_code;  // 已是否负数就沿用
    }
}

const char* error_text(int ddk_code) noexcept {
    switch (ddk_code) {
    case USB_DDK_SUCCESS: return "成功";
    case USB_DDK_FAILED: return "通用失败";
    case USB_DDK_NO_PERM:
        return "权限不足（201 USB_DDK_NO_PERM）：需要在 module.json5 声明 "
               "ohos.permission.ACCESS_DDK_USB，并在签名 profile 的 allowed-acls 里放行";
    case USB_DDK_INVALID_PARAMETER: return "参数不合法";
    case USB_DDK_MEMORY_ERROR: return "内存申请失败";
    case USB_DDK_NULL_PTR: return "传入了空指针";
    case USB_DDK_DEVICE_BUSY: return "设备忙：接口已被其他进程或本进程其他句柄占用";
    case USB_DDK_INVALID_OPERATION:
        // 字面意思是"连接 USB DDK 服务失败"，但最常见的成因**不是**服务挂了，而是
        // 调用方不在 DriverExtensionAbility 的生命周期里 —— 官方头文件给这一族 API
        // 标的 syscap 是 SystemCapability.Driver.USB.Extension，且文档明确"USB DDK
        // 开放 API 仅允许 DriverExtensionAbility 生命周期内使用"。从入口 Ability
        // 直接调就会拿到这个码。提示语必须把这条写出来，否则读的人会跑去查权限。
        return "连接 USB DDK 服务失败（27400002 USB_DDK_INVALID_OPERATION）："
               "最常见成因是调用方不在 DriverExtensionAbility 生命周期内 —— "
               "USB DDK 只能在驱动扩展里使用，从入口 Ability 直接调用会得到这个码";
    case USB_DDK_IO_FAILED: return "USB 传输失败";
    case USB_DDK_TIMEOUT: return "USB 传输超时";
    default: return "未知的 USB DDK 错误";
    }
}

} // namespace iPhoneMirror::ohos_usb

#else // !IM_OHOS_USB_DDK_AVAILABLE

// 没有 DDK 头时，头文件里的 inline 版本已经够用，这里不需要额外定义。

#endif // IM_OHOS_USB_DDK_AVAILABLE
