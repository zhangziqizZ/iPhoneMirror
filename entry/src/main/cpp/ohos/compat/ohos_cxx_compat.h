// SPDX-License-Identifier: GPL-3.0-only
//
// 鸿蒙（OpenHarmony / HarmonyOS NEXT）NDK 的 libc++ 兼容垫片。
//
// 背景：上游 iPhoneMirror 是按「MSVC + libstdc++/libc++（桌面发行版）」写的，
// 用到了 C++20 的 P0660（std::jthread / std::stop_token）与 P0645（std::format）。
// OHOS NDK 自带的 libc++ 版本尚未提供这两组设施，而本工程的原则是
// **上游文件一行都不改**（见 docs/移植说明.md 的硬规则），因此这里把缺口补在
// 构建层：
//
//   * 由 CMake 以 `-include .../ohos_cxx_compat.h` 强制预包含本文件；
//   * OHOS 侧缺失的设施在此提供等价实现；
//   * `ohos/compat/format`、`ohos/compat/semaphore` 两个无扩展名头文件放在
//     include 搜索路径最前面，用于接住上游源码里字面写死的 `#include <format>`
//     / `#include <semaphore>`，能 `include_next` 到系统头时就原样让路。
//
// 因此：一旦用户侧工具链补齐了这些设施（__cpp_lib_jthread / __cpp_lib_format
// / __cpp_lib_semaphore 出现），本文件对应的分支会自动失效，上游代码无需任何
// 改动即可切换到标准实现。

#pragma once

#if defined(__has_include)
#  if __has_include(<version>)
#    include <version>
#  endif
#endif

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <type_traits>
#include <utility>

// ===========================================================================
// 平台头文件补齐（不是语言设施，是头文件可见性差异）
// ===========================================================================
// OHOS 用的是 musl 头文件，它不像 glibc 那样由 <sys/socket.h> 顺带把
// <sys/select.h> 拉进来。后果是上游 Transport/Socket.cpp 里裸用的
// fd_set / timeval / ::select 全部找不到声明：
//
//     Core/src/Transport/Socket.cpp:209: error: unknown type name 'fd_set'
//     Core/src/Transport/Socket.cpp:212: error: unknown type name 'timeval'
//     Core/src/Transport/Socket.cpp:213: error: no member named 'select' in the global namespace
//
// 上游文件不能改，所以在这里补上——"平台差异补在构建层"就是这个用法。
// 这里只是把本就存在于 sysroot 的 <sys/select.h> 引进来，没有任何自制声明，
// 因此不会与系统头冲突；glibc 环境下这个 include 是冗余但无害的。
#if defined(__has_include)
#  if __has_include(<sys/select.h>)
#    include <sys/select.h>
#  endif
#endif

// ===========================================================================
// P0645 std::format —— 仅在工具链缺少 <format> / 未启用 std::format 时提供
// ===========================================================================
#if !defined(__cpp_lib_format) || __cpp_lib_format < 201907L

#include <array>
#include <iomanip>
#include <sstream>
#include <tuple>
#include <vector>

namespace std {
namespace im_compat {

// 一个替换域（{} 里的内容）解析结果。上游实际只用到：
//   {}  {:X}  {:08X}  {:016X}  {:04X}  {:x}  {:02x}  {:08x}  {:.3f}  {:.2f}
struct FieldSpec {
    bool zero_pad{};
    std::size_t width{};
    bool has_precision{};
    std::size_t precision{};
    char type{};
};

inline FieldSpec parse_field_spec(std::string_view raw) {
    FieldSpec spec;
    std::size_t index = 0;
    // 上游写法是 "{:...}"，所以冒号会作为第一个字符出现。
    if (index < raw.size() && raw[index] == ':') ++index;
    if (index < raw.size() && raw[index] == '0') {
        spec.zero_pad = true;
        ++index;
    }
    while (index < raw.size() && raw[index] >= '0' && raw[index] <= '9') {
        spec.width = spec.width * 10 + static_cast<std::size_t>(raw[index] - '0');
        ++index;
    }
    if (index < raw.size() && raw[index] == '.') {
        ++index;
        spec.has_precision = true;
        while (index < raw.size() && raw[index] >= '0' && raw[index] <= '9') {
            spec.precision = spec.precision * 10 + static_cast<std::size_t>(raw[index] - '0');
            ++index;
        }
    }
    if (index < raw.size()) spec.type = raw[index];
    return spec;
}

// 按宽度补位；零填充时把符号（-、+、0x）留在最前面。
inline std::string pad(std::string text, bool zero_pad, std::size_t width) {
    if (text.size() >= width) return text;
    const std::size_t missing = width - text.size();
    if (!zero_pad) return std::string(missing, ' ') + text;
    std::size_t prefix = 0;
    if (!text.empty() && (text[0] == '-' || text[0] == '+')) {
        prefix = 1;
    } else if (text.size() >= 2 && text[0] == '0' &&
        (text[1] == 'x' || text[1] == 'X' || text[1] == 'b' || text[1] == 'B')) {
        prefix = 2;
    }
    return text.substr(0, prefix) + std::string(missing, '0') + text.substr(prefix);
}

template <typename T>
inline std::string integral_to_text(T value, const FieldSpec& spec) {
    const bool hexadecimal = spec.type == 'x' || spec.type == 'X';
    const bool octal = spec.type == 'o';
    const bool binary = spec.type == 'b' || spec.type == 'B';
    const bool uppercase = spec.type == 'X' || spec.type == 'B';

    bool negative = false;
    unsigned long long magnitude = 0;
    if constexpr (std::is_signed_v<T>) {
        if (value < 0) {
            negative = true;
            magnitude = static_cast<unsigned long long>(-(value + 1)) + 1ULL;
        } else {
            magnitude = static_cast<unsigned long long>(value);
        }
    } else {
        magnitude = static_cast<unsigned long long>(value);
    }

    std::string digits;
    if (hexadecimal || octal || binary) {
        const unsigned base = hexadecimal ? 16U : (octal ? 8U : 2U);
        const char* alphabet = uppercase ? "0123456789ABCDEF" : "0123456789abcdef";
        unsigned long long remaining = magnitude;
        do {
            digits.insert(digits.begin(), alphabet[remaining % base]);
            remaining /= base;
        } while (remaining != 0);
    } else {
        digits = std::to_string(magnitude);
    }

    // 十六/八/二进制按标准是按位解释，不输出负号。
    std::string text;
    if (negative && !hexadecimal && !octal && !binary) text.push_back('-');
    text += digits;
    return pad(std::move(text), spec.zero_pad, spec.width);
}

template <typename T>
inline std::string floating_to_text(T value, const FieldSpec& spec) {
    std::ostringstream stream;
    const int precision = spec.has_precision ? static_cast<int>(spec.precision) : 6;
    if (spec.type == 'f' || spec.type == 'F') {
        stream << std::fixed << std::setprecision(precision) << value;
    } else if (spec.type == 'e' || spec.type == 'E') {
        stream << std::scientific << std::setprecision(precision) << value;
    } else if (spec.type == 'g' || spec.type == 'G') {
        stream << std::setprecision(precision) << value;
    } else {
        stream << value;
    }
    return pad(stream.str(), spec.zero_pad, spec.width);
}

inline std::string text_to_text(std::string_view value, const FieldSpec& spec) {
    // 字符串的宽度域按左对齐补空格（上游未用到，补上避免静默错位）。
    if (value.size() >= spec.width) return std::string(value);
    return std::string(value) + std::string(spec.width - value.size(), ' ');
}

inline std::string pointer_to_text(const void* value, const FieldSpec& spec) {
    std::ostringstream stream;
    stream << "0x" << std::hex << std::nouppercase
           << reinterpret_cast<std::uintptr_t>(value);
    return pad(stream.str(), spec.zero_pad, spec.width);
}

// 宽字符仅用于日志/错误串，上游可移植文件里不会有；这里做 ASCII 降级而不是
// 直接编译失败，转换损失在注释中明确（非 ASCII 码位置为 '?'）。
inline std::string wide_to_text(std::wstring_view value) {
    std::string result;
    result.reserve(value.size());
    for (const wchar_t character : value) {
        result.push_back(character >= 0 && character < 0x80
            ? static_cast<char>(character) : '?');
    }
    return result;
}

template <typename T>
inline std::string format_one(const T& value, const FieldSpec& spec) {
    using Decayed = std::decay_t<T>;
    if constexpr (std::is_same_v<Decayed, bool>) {
        return pad(value ? "true" : "false", spec.zero_pad, spec.width);
    } else if constexpr (std::is_same_v<Decayed, char>) {
        return std::string(1, value);
    } else if constexpr (std::is_integral_v<Decayed>) {
        return integral_to_text(value, spec);
    } else if constexpr (std::is_floating_point_v<Decayed>) {
        return floating_to_text(value, spec);
    } else if constexpr (std::is_same_v<Decayed, std::string> ||
                         std::is_same_v<Decayed, std::string_view>) {
        return text_to_text(std::string_view(value), spec);
    } else if constexpr (std::is_same_v<Decayed, const char*> ||
                         std::is_same_v<Decayed, char*>) {
        return text_to_text(value ? std::string_view(value) : std::string_view{}, spec);
    } else if constexpr (std::is_same_v<Decayed, std::wstring> ||
                         std::is_same_v<Decayed, std::wstring_view> ||
                         std::is_same_v<Decayed, const wchar_t*> ||
                         std::is_same_v<Decayed, wchar_t*>) {
        return text_to_text(value ? wide_to_text(std::wstring_view(value)) : std::string{}, spec);
    } else if constexpr (std::is_pointer_v<Decayed>) {
        return pointer_to_text(static_cast<const void*>(value), spec);
    } else if constexpr (std::is_enum_v<Decayed>) {
        return integral_to_text(static_cast<std::underlying_type_t<Decayed>>(value), spec);
    } else {
        // 兜底：任何可流式输出的类型（std::filesystem::path 等）。
        std::ostringstream stream;
        stream << value;
        return pad(stream.str(), spec.zero_pad, spec.width);
    }
}

template <std::size_t Index = 0, typename Tuple>
inline std::string render_argument(const Tuple& arguments, std::size_t wanted,
    std::string_view spec) {
    if constexpr (Index < std::tuple_size_v<Tuple>) {
        if (wanted == Index) {
            return format_one(std::get<Index>(arguments), parse_field_spec(spec));
        }
        return render_argument<Index + 1>(arguments, wanted, spec);
    } else {
        return std::string{};
    }
}

} // namespace im_compat

// 上游的 std::format 调用点全部使用字面量格式串，因此这里按 string_view 取参，
// 不做编译期格式串校验（那正是标准库 P2216 才提供的能力）。
//
// 实参的存放方式有两个踩过的坑，都在自检 tools/shim_selftest.cpp 里有对应用例：
//  1) **按值存 decay 后的实参，不存引用**。实参若是字符串字面量，类型是
//     const char[N]，转成 const char* 会产生一个临时指针；存引用会绑定到这个
//     临时量上，整条语句结束即悬空。
//  2) 形参要写**转发引用**而不是 const Args&。const Args& 会把数组元素类型上的
//     const 吃在形参上，使 Args 退化成 char[N]，decay 出来就成了 char*，
//     与实参的 const char* 对不上，构造 tuple 直接编译失败。
template <typename... Args>
inline std::string format(std::string_view pattern, Args&&... arguments) {
    const auto bound = std::make_tuple(std::forward<Args>(arguments)...);
    std::string output;
    output.reserve(pattern.size() + 64);
    std::size_t next_argument = 0;
    for (std::size_t index = 0; index < pattern.size(); ++index) {
        const char character = pattern[index];
        if (character == '{') {
            if (index + 1 < pattern.size() && pattern[index + 1] == '{') {
                output.push_back('{');
                ++index;
                continue;
            }
            const auto close = pattern.find('}', index + 1);
            if (close == std::string_view::npos) {
                output.append(pattern.substr(index));
                break;
            }
            const std::string_view spec(pattern.data() + index + 1, close - index - 1);
            output += im_compat::render_argument(bound, next_argument, spec);
            ++next_argument;
            index = close;
            continue;
        }
        if (character == '}' && index + 1 < pattern.size() && pattern[index + 1] == '}') {
            output.push_back('}');
            ++index;
            continue;
        }
        output.push_back(character);
    }
    return output;
}

} // namespace std

#endif // __cpp_lib_format

// ===========================================================================
// P0660 std::stop_token / std::stop_source / std::jthread
// ===========================================================================
#if !defined(__cpp_lib_jthread) || __cpp_lib_jthread < 201911L

#include <atomic>
#include <memory>
#include <thread>
#include <tuple>

namespace std {

namespace im_compat {

struct StopState {
    std::atomic<bool> requested{false};
};

} // namespace im_compat

class stop_token {
public:
    stop_token() noexcept = default;
    explicit stop_token(std::weak_ptr<im_compat::StopState> state) noexcept
        : state_(std::move(state)) {}

    [[nodiscard]] bool stop_requested() const noexcept {
        const auto state = state_.lock();
        return state && state->requested.load(std::memory_order_acquire);
    }
    [[nodiscard]] bool stop_possible() const noexcept { return !state_.expired(); }

private:
    std::weak_ptr<im_compat::StopState> state_;
};

class stop_source {
public:
    stop_source() : state_(std::make_shared<im_compat::StopState>()) {}

    // 刻意**不加** [[nodiscard]]：标准里 std::stop_source::request_stop() 与
    // std::jthread::request_stop() 都只是返回 bool，并未标 nodiscard。
    // 标上会让上游 Logging.cpp / CaptureSession.cpp 里那些"确实不关心返回值"
    // 的调用点凭空冒出 -Wunused-result 警告——而垫片的职责是复现标准行为，
    // 不是比标准更严。
    bool request_stop() noexcept {
        if (!state_) return false;
        bool expected = false;
        return state_->requested.compare_exchange_strong(expected, true,
            std::memory_order_acq_rel, std::memory_order_relaxed);
    }
    [[nodiscard]] bool stop_requested() const noexcept {
        return state_ && state_->requested.load(std::memory_order_acquire);
    }
    [[nodiscard]] bool stop_possible() const noexcept { return static_cast<bool>(state_); }
    [[nodiscard]] stop_token get_token() const noexcept {
        return stop_token(std::weak_ptr<im_compat::StopState>(state_));
    }

private:
    std::shared_ptr<im_compat::StopState> state_;
};

// 语义与 std::jthread 一致的最小实现：析构时自动 request_stop() 再 join()，
// 可调用对象若接受 std::stop_token 作为首参就传入本线程的 token。
class jthread {
public:
    jthread() noexcept = default;

    template <typename Callable, typename... Args,
        typename = std::enable_if_t<!std::is_same_v<std::decay_t<Callable>, jthread>>>
    explicit jthread(Callable&& callable, Args&&... args)
        : state_(std::make_shared<im_compat::StopState>()) {
        const auto state = state_;
        auto body = [state,
                     function = std::decay_t<Callable>(std::forward<Callable>(callable)),
                     bound = std::make_tuple(std::forward<Args>(args)...)]() mutable {
            std::apply([&](auto&... unpacked) {
                if constexpr (std::is_invocable_v<std::decay_t<Callable>&, stop_token,
                                  decltype(unpacked)...>) {
                    std::invoke(function,
                        stop_token(std::weak_ptr<im_compat::StopState>(state)), unpacked...);
                } else {
                    std::invoke(function, unpacked...);
                }
            }, bound);
        };
        thread_ = std::thread(std::move(body));
    }

    ~jthread() {
        if (thread_.joinable()) {
            // 与标准 std::jthread 析构同语义：先请求停止，再 join。
            request_stop();
            thread_.join();
        }
    }

    jthread(jthread&& other) noexcept
        : thread_(std::move(other.thread_)), state_(std::move(other.state_)) {}

    jthread& operator=(jthread&& other) noexcept {
        if (this != &other) {
            if (thread_.joinable()) {
                request_stop();
                thread_.join();
            }
            thread_ = std::move(other.thread_);
            state_ = std::move(other.state_);
        }
        return *this;
    }

    jthread(const jthread&) = delete;
    jthread& operator=(const jthread&) = delete;

    [[nodiscard]] bool joinable() const noexcept { return thread_.joinable(); }
    void join() { thread_.join(); }
    void detach() { thread_.detach(); }

    // 同 stop_source：标准未标 [[nodiscard]]，垫片也不标。
    bool request_stop() noexcept {
        if (!state_) return false;
        bool expected = false;
        return state_->requested.compare_exchange_strong(expected, true,
            std::memory_order_acq_rel, std::memory_order_relaxed);
    }
    [[nodiscard]] stop_token get_stop_token() const noexcept {
        return stop_token(std::weak_ptr<im_compat::StopState>(state_));
    }
    [[nodiscard]] static unsigned int hardware_concurrency() noexcept {
        return std::thread::hardware_concurrency();
    }
    [[nodiscard]] std::thread::native_handle_type native_handle() {
        return thread_.native_handle();
    }
    void swap(jthread& other) noexcept {
        thread_.swap(other.thread_);
        state_.swap(other.state_);
    }

private:
    std::thread thread_;
    std::shared_ptr<im_compat::StopState> state_;
};

} // namespace std

#endif // __cpp_lib_jthread

// ===========================================================================
// P1135 std::counting_semaphore / std::binary_semaphore
// 上游只有 CaptureSession.cpp 里的 libusb0 恢复闸门用到，且仅 Windows 分支实际
// 执行；补上是为了让 `#include <semaphore>` 与声明处都能编过。
// ===========================================================================
#if !defined(__cpp_lib_semaphore) || __cpp_lib_semaphore < 201907L

#include <chrono>
#include <condition_variable>
#include <mutex>

namespace std {

template <std::ptrdiff_t LeastMaxValue = 1>
class counting_semaphore {
public:
    static constexpr std::ptrdiff_t max() noexcept { return LeastMaxValue; }

    explicit counting_semaphore(std::ptrdiff_t desired) : counter_(desired) {}

    counting_semaphore(const counting_semaphore&) = delete;
    counting_semaphore& operator=(const counting_semaphore&) = delete;

    void release(std::ptrdiff_t update = 1) {
        {
            std::scoped_lock lock(mutex_);
            counter_ += update;
        }
        condition_.notify_all();
    }

    void acquire() {
        std::unique_lock lock(mutex_);
        condition_.wait(lock, [this] { return counter_ > 0; });
        --counter_;
    }

    [[nodiscard]] bool try_acquire() noexcept {
        std::scoped_lock lock(mutex_);
        if (counter_ <= 0) return false;
        --counter_;
        return true;
    }

    template <typename Rep, typename Period>
    [[nodiscard]] bool try_acquire_for(const std::chrono::duration<Rep, Period>& timeout) {
        std::unique_lock lock(mutex_);
        if (!condition_.wait_for(lock, timeout, [this] { return counter_ > 0; })) {
            return false;
        }
        --counter_;
        return true;
    }

private:
    std::mutex mutex_;
    std::condition_variable condition_;
    std::ptrdiff_t counter_{};
};

using binary_semaphore = counting_semaphore<1>;

} // namespace std

#endif // __cpp_lib_semaphore
