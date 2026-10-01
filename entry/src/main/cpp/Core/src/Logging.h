#pragma once

#include <filesystem>
#include <string>
#include <string_view>

namespace iPhoneMirror::logging {

// Log levels and categories are kept at the native boundary so every
// subsystem can add structured context without duplicating timestamp/thread
// formatting. The legacy write(message) overload remains the default path.
enum class Level {
    Trace,
    Debug,
    Info,
    Warning,
    Error,
};

void initialize();
void write(std::string_view message) noexcept;
void write(Level level, std::string_view category, std::string_view message) noexcept;
void write_event(Level level, std::string_view category, std::string_view event,
    std::string_view details = {}) noexcept;
// Produces a process-stable, salted SHA-256 label. The random salt changes on
// every launch so identifiers can be correlated within one diagnostic session
// without making logs a cross-session device tracking record.
[[nodiscard]] std::string fingerprint(std::string_view value) noexcept;
// 把诊断日志重定向到显式路径（例如应用沙箱 filesDir/iPhoneMirror/Logs/startup.log），
// 并关闭当前已打开的日志文件，使下一次写入落到新路径。鸿蒙侧用它把原生日志从系统
// temp 目录挪进应用沙箱——否则 ArkTS 的 UI 读不到（沙箱隔离），实时日志会一直空白。
void set_log_file_override(const std::filesystem::path& path) noexcept;
void shutdown();

} // namespace iPhoneMirror::logging
