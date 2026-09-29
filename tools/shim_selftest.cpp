// SPDX-License-Identifier: GPL-3.0-only
//
// shim_selftest.cpp —— 构建层垫片的自检。
//
// 为什么需要它：整套"上游一行不改"的方案压在 ohos/compat/ 上，而其中的
// std::format 解析器、std::jthread/stop_token、<semaphore> 都是本项目手写的。
// 编译通过只说明签名对得上，说明不了行为对。
//
// 这个自检用真实 NDK 编成 aarch64-linux-ohos 可执行文件，**在鸿蒙 PC 上直接运行**
// （本机就是 OpenHarmony，能跑 aarch64-ohos ELF），逐条断言等价语义。
//
// 运行：
//   tools/shim_selftest.sh

#include "Text/Utf.h"

#include "Media/VideoFormats.h"

// 强制走垫片：把工具链提供的 feature-test 宏按下去，让 ohos_cxx_compat.h 里
// 的 #if !defined(__cpp_lib_*) 分支真的生效。
// （编译脚本用 -include 先塞入这些 #undef，见 shim_selftest.sh。）
#include <format>
#include <semaphore>
#include <thread>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdint>
#include <string>
#include <vector>

namespace {

int failures = 0;
int checks = 0;

void check(bool condition, const char* what) {
    ++checks;
    if (condition) {
        std::printf("  ok   %s\n", what);
    } else {
        ++failures;
        std::printf("  FAIL %s\n", what);
    }
}

void check_eq(const std::string& actual, const std::string& expected,
    const char* what) {
    ++checks;
    if (actual == expected) {
        std::printf("  ok   %s  ->  \"%s\"\n", what, actual.c_str());
    } else {
        ++failures;
        std::printf("  FAIL %s  期望 \"%s\"，实得 \"%s\"\n", what,
            expected.c_str(), actual.c_str());
    }
}

// ---------------------------------------------------------------------------
// std::format —— 上游实际用到的每一种格式说明符
// ---------------------------------------------------------------------------
void test_format() {
    std::printf("[std::format]\n");
    check_eq(std::format("{}", 42), "42", "{} 整数");
    check_eq(std::format("{}", "abc"), "abc", "{} 字符串");
    check_eq(std::format("{:X}", 0xABCDEF), "ABCDEF", "{:X} 大写十六进制");
    check_eq(std::format("{:x}", 0xABCDEF), "abcdef", "{:x} 小写十六进制");
    check_eq(std::format("{:08X}", 0x1234), "00001234", "{:08X} 补零");
    check_eq(std::format("{:016X}", 0x1234), "0000000000001234",
        "{:016X} 16 位补零（topology_id 用）");
    check_eq(std::format("{:04X}", 0x5AC), "05AC", "{:04X} 4 位补零");
    check_eq(std::format("{:02x}", 0x5), "05", "{:02x}");
    check_eq(std::format("{:08x}", 0xDEADBEEF), "deadbeef", "{:08x}");
    check_eq(std::format("{:.3f}", 1.5), "1.500", "{:.3f}");
    check_eq(std::format("{:.2f}", 59.996), "60.00", "{:.2f} 进位");
    check_eq(std::format("{:.0f}", 2.5), "2", "{:.0f} 银行家舍入（同 printf %.0f）");
    check_eq(std::format("[{}:{}]", 1, 2), "[1:2]", "多个占位符");
    check_eq(std::format("no placeholder"), "no placeholder", "无占位符");
    check_eq(std::format("{{literal}}"), "{literal}", "转义花括号");
    check_eq(std::format("{}", std::string_view("sv")), "sv", "string_view 实参");
    check_eq(std::format("{}", static_cast<std::uint64_t>(123456789012345ULL)),
        "123456789012345", "uint64");
    check_eq(std::format("{}", -7), "-7", "负整数");
    // 上游 Logging.cpp 的真实形态：混排字符串、数字、十六进制
    check_eq(
        std::format("usb_identity device_fp={} pid={:04x} configs={}/{} active_config={}",
            "abcd1234", 0x12A8, 5, 6, 5),
        "usb_identity device_fp=abcd1234 pid=12a8 configs=5/6 active_config=5",
        "Logging.cpp 风格的混排");
}

// ---------------------------------------------------------------------------
// std::jthread / std::stop_token —— 上游 CaptureSession / Logging 用它跑线程
// ---------------------------------------------------------------------------
void test_jthread() {
    std::printf("[std::jthread / stop_token]\n");
    std::atomic<int> ticks{0};
    {
        std::jthread worker([&](std::stop_token token) {
            while (!token.stop_requested()) {
                ticks.fetch_add(1);
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
        });
        std::this_thread::sleep_for(std::chrono::milliseconds(30));
        check(ticks.load() > 0, "线程首参拿到 stop_token 并且真的在跑");
        check(worker.joinable(), "joinable()");
        check(worker.request_stop(), "request_stop() 首次返回 true");
        check(!worker.request_stop(), "request_stop() 二次返回 false");
        check(worker.get_stop_token().stop_requested(), "stop_requested() 已置位");
    }
    const int settled = ticks.load();
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
    check(ticks.load() == settled, "析构自动 join：线程已停，计数不再增长");

    // 上游不传 stop_token 的用法也要能编能跑。
    std::atomic<bool> ran{false};
    {
        std::jthread plain([&] { ran = true; });
    }
    check(ran.load(), "无参 lambda 的 jthread");

    // 移构后原对象不再 joinable。
    std::jthread a([]{});
    std::jthread b(std::move(a));
    check(!a.joinable(), "移构后源对象不 joinable");
    check(b.joinable(), "移构后目标对象 joinable");
}

// ---------------------------------------------------------------------------
// std::counting_semaphore
// ---------------------------------------------------------------------------
void test_semaphore() {
    std::printf("[std::counting_semaphore]\n");
    std::counting_semaphore<4> sem(0);
    check(!sem.try_acquire(), "初值 0 时 try_acquire 失败");
    sem.release(2);
    check(sem.try_acquire(), "release(2) 后可 acquire");
    check(sem.try_acquire(), "第二次也能 acquire");
    check(!sem.try_acquire(), "用完即空");
    sem.release();
    sem.acquire();
    check(true, "acquire() 在已 release 时不阻塞");

    std::atomic<bool> acquired{false};
    std::jthread waiter([&] {
        sem.acquire();
        acquired = true;
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    check(!acquired.load(), "无令牌时 acquire 真的阻塞");
    sem.release();
    waiter.join();
    check(acquired.load(), "release 后阻塞方被唤醒");

    std::binary_semaphore bin(1);
    check(bin.try_acquire(), "binary_semaphore 初值 1");
}

// ---------------------------------------------------------------------------
// Text/Utf —— 上游文件，直接编进来跑，验证 wchar_t 4 字节前提
// ---------------------------------------------------------------------------
void test_utf() {
    std::printf("[Text/Utf（上游可移植文件）]\n");
    check(sizeof(wchar_t) == 4, "本平台 wchar_t 是 4 字节（ABI 沿用宽字符的前提）");

    const std::string utf8 = "iPhone \xE6\x8A\x95\xE5\xB1\x8F \xF0\x9F\x93\xB1";
    const std::wstring wide = iPhoneMirror::text::utf8_to_wide(utf8);
    check_eq(iPhoneMirror::text::wide_to_utf8(wide), utf8, "UTF-8 → wide → UTF-8 往返");

    // 码点级校验：中文"投"= U+6295，"屏"= U+5C4F，emoji = U+1F4F1
    check(wide.size() == 11, "wide 长度按码点计（含 emoji 单码点）");
    check(wide[7] == 0x6295, "中文码点 U+6295 正确");
    check(wide[8] == 0x5C4F, "中文码点 U+5C4F 正确");
    check(wide[10] == 0x1F4F1, "emoji U+1F4F1 落在 BMP 之外也正确");
    check_eq(iPhoneMirror::text::wide_to_utf8(L""), "", "空串往返");
}

// ---------------------------------------------------------------------------
// Media/VideoFormats —— 上游可移植文件的纯函数
// ---------------------------------------------------------------------------
void test_video_formats() {
    std::printf("[Media/VideoFormats（上游可移植文件）]\n");
    using namespace iPhoneMirror::media;
    using iPhoneMirror::coremedia::VideoCodec;
    using iPhoneMirror::coremedia::ColorRange;
    check_eq(std::string(pixel_format_name(PixelFormat::Nv12)), "nv12", "pixel_format_name(Nv12)");
    check_eq(std::string(pixel_format_name(PixelFormat::P010)), "p010", "pixel_format_name(P010)");
    check_eq(std::string(decoder_preference_name(DecoderPreference::Auto)), "auto",
        "decoder_preference_name(Auto)");
    check_eq(std::string(codec_name(VideoCodec::Hevc)), "hevc", "codec_name(Hevc)");
    check_eq(std::string(color_range_name(ColorRange::Limited)), "limited",
        "color_range_name(Limited)");

    const auto nv12 = detail::checked_nv12_buffer_size(1920, 1080);
    check(nv12.has_value() && *nv12 == 1920 * 1080 + 1920 * 540,
        "checked_nv12_buffer_size 1920x1080");
    check(!detail::checked_nv12_buffer_size(0, 1080).has_value(), "宽度 0 被拒");

    // 上游洪蒙侧唯一要提供的那一个平台钩子。
    DecodedFrame empty;
    check(!detail::materialize_gpu_frame(empty), "nv12 为空时 materialize_gpu_frame 如实返回 false");
    DecodedFrame filled;
    filled.nv12.resize(4);
    check(detail::materialize_gpu_frame(filled), "nv12 已在时返回 true");
}

} // namespace

int main() {
    std::printf("=== iPhoneMirror 鸿蒙移植 · 构建层垫片自检 ===\n\n");
    test_format();
    test_jthread();
    test_semaphore();
    test_utf();
    test_video_formats();
    std::printf("\n%d 项检查，%d 项失败\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
