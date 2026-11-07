// SPDX-License-Identifier: GPL-3.0-only
//
// 有线（USB）链路的原生诊断尾巴。
//
// 为什么需要单独一个通道：Core 的 logging::write() 落在一个**沙箱内的文件**里
// （temp_directory_path()/iPhoneMirror-capture.log），应用进程以外读不到，
// 界面也够不着。结果就是"有线采集失败"时，用户屏幕上只剩一句概括性的异常文案，
// 而真正决定成败的几步——认领接口成没成、厂商 0x52 请求返回什么、设备重枚举后
// 有没有带出 0x2A 接口、哪个配置被选中——全写在那个读不到的文件里。
//
// 这与 AirPlay 侧的处理方式一致（见 OhosAirPlayReceiver.cpp 的 StoreLog）：把
// 关键判断的**原话**留在进程内，由 C ABI 交给界面显示。区别是这里刻意不用
// "只留最后一条"——有线这条链路上连续几步都可能是失败点，覆盖式存储会把前一步
// 的失败原因冲掉，所以留一个固定长度的窗口。
//
// 纪律：这里只记录**已经发生的事实**（请求发出去了、返回值是多少、看到的描述符
// 是什么），不写"应该没问题"这类推断。诊断串本身不能假成功，否则它就是在
// 制造下一个"已应答 18 次"。

#pragma once

#include <cstddef>
#include <deque>
#include <mutex>
#include <string>
#include <string_view>

namespace iPhoneMirror::ohos_usb_diag {
namespace detail {

// 与 AppleUsbIdentityCache.h 同一手法：函数内静态变量，避开静态初始化顺序问题。
inline std::mutex& usb_diag_mutex() {
    static std::mutex value;
    return value;
}

inline std::deque<std::string>& usb_diag_lines() {
    static std::deque<std::string> value;
    return value;
}

// 保留条数：原 20 条按 iPhone fd 配对链路估的；实测一轮配对（含接口
// 发现、握手、隧道、lockdown 对话）就能刷掉十几条，提到 60 才装得下
// 一整轮现场。
inline constexpr std::size_t UsbDiagCapacity = 60;

} // namespace detail

// 追加一条事实。空串忽略；永不抛（诊断不能改变产品行为）。
inline void note(std::string_view line) noexcept {
    if (line.empty()) return;
    try {
        std::scoped_lock lock(detail::usb_diag_mutex());
        auto& lines = detail::usb_diag_lines();
        lines.emplace_back(line);
        while (lines.size() > detail::UsbDiagCapacity) lines.pop_front();
    } catch (...) {
    }
}

// 按时间顺序拼成多行（每条一行）。没有记录时返回空串——界面据此决定是否显示。
//
// ★ 为什么用换行而不是 " | " ★：fd 配对链路一步一条、一条比一条关键，单行
// 拼接 + 定长截断会把最早被推出来、但往往正是失败发生处的条目整个吞掉。
// 换行后 UI 按行显示，截断也按行丢，每条记录的完整性有保障。
[[nodiscard]] inline std::string tail() {
    try {
        std::scoped_lock lock(detail::usb_diag_mutex());
        const auto& lines = detail::usb_diag_lines();
        std::string result;
        for (const auto& line : lines) {
            if (!result.empty()) result += '\n';
            result += line;
        }
        return result;
    } catch (...) {
        return {};
    }
}

// 采集重新开始时清空，避免上一轮的失败记录被当成这一轮的结果。
inline void clear() noexcept {
    try {
        std::scoped_lock lock(detail::usb_diag_mutex());
        detail::usb_diag_lines().clear();
    } catch (...) {
    }
}

} // namespace iPhoneMirror::ohos_usb_diag

extern "C" {

// 有线链路的诊断尾巴。返回进程内静态缓冲，调用方**不要**释放，也不要跨线程长期持有。
// 没有记录时返回空串。
const char *im_usb_diagnostics(void);

}
