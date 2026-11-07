// SPDX-License-Identifier: GPL-3.0-only
//
// 配对（"信任此电脑"）的**用户可见状态**。
//
// 为什么单独一个通道，而不复用 OhosUsbDiagnostics 的诊断尾巴：
//
//   诊断尾巴记的是**已经发生的事实**（请求发出去了、返回值多少、看到什么
//   描述符），是给排障的人看的，而且只在开发者模式下显示。
//
//   配对状态是**要用户动手的指令**："请解锁 iPhone 并点「信任」"。它必须在
//   普通界面就看得见 —— 否则弹窗弹出来了，用户在手机上看到了，但界面上
//   什么提示都没有，他不知道还要不要等；而弹窗超时之后界面也没有任何
//   交代，用户只会以为"这软件没反应"。
//
// 两者混用会互相伤害：把"请点信任"塞进诊断尾巴，它就只在开发者模式下可见；
// 把诊断事实塞进状态位，它就会变成一句自相矛盾的流水账。
//
// 状态位的生命周期：配对开始时清空，每一步推进时覆盖成最新的一句，
// 配对结束后保留最终结论（成功/被拒/超时），让用户知道结果。

#pragma once

#include <mutex>
#include <string>
#include <string_view>

namespace iPhoneMirror::ohos::pairing_status {
namespace detail {

inline std::mutex& status_mutex() {
    static std::mutex value;
    return value;
}

inline std::string& status_text() {
    static std::string value;
    return value;
}

} // namespace detail

// 覆盖当前状态。空串表示"没有配对在进行，也没有结论"。
inline void set(std::string_view text) noexcept {
    try {
        std::scoped_lock lock(detail::status_mutex());
        detail::status_text().assign(text);
    } catch (...) {
    }
}

// 读当前状态。没有内容时返回空串。
[[nodiscard]] inline std::string get() {
    try {
        std::scoped_lock lock(detail::status_mutex());
        return detail::status_text();
    } catch (...) {
        return {};
    }
}

// 清空（新一轮配对开始、或用户主动重试前调用）。
inline void clear() noexcept {
    try {
        std::scoped_lock lock(detail::status_mutex());
        detail::status_text().clear();
    } catch (...) {
    }
}

} // namespace iPhoneMirror::ohos::pairing_status

extern "C" {

// 配对的用户可见状态（中文一句话）。没有内容时返回空串。
//
// 与 im_usb_diagnostics() 一样返回进程内静态缓冲，调用方不要释放。
const char *im_pairing_status(void);

}
