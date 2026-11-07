// SPDX-License-Identifier: GPL-3.0-only
//
// OhosPairingStore.h 的实现：把配对记录写到应用沙箱。
//
// 文件格式说明（见头文件）：
//   * 每台设备一个文件，文件名用 UDID（UDID 只含字母数字与连字符，可直接
//     做文件名，不会带来路径穿越风险）。
//   * 文件内容就是配对记录的 XML plist 文本 —— 与设备侧、libimobiledevice
//     的 pair record 同一形态，将来要用现成工具排查时能直接看。

#include "OhosPairingStore.h"

#include "Logging.h"

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>

namespace iPhoneMirror::ohos::pairing_store {
namespace {

std::mutex& store_mutex() {
    static std::mutex value;
    return value;
}

std::string& store_directory() {
    static std::string value;
    return value;
}

// 配对记录的文件名。
//
// UDID 是 iPhone 的唯一标识（40 位十六进制 + 连字符）。这里仍然做一次
// 白名单过滤：万一调用方传了带斜杠的串，拼接出来的路径就跑到目录外面去了。
// 沙箱里多写一个文件不算大事，但把文件写到别处是另一回事。
std::string record_file_name(const std::string& udid) {
    std::string safe;
    safe.reserve(udid.size());
    for (const char raw : udid) {
        const unsigned char byte = static_cast<unsigned char>(raw);
        const bool allowed = (byte >= '0' && byte <= '9') ||
            (byte >= 'A' && byte <= 'Z') ||
            (byte >= 'a' && byte <= 'z') || byte == '-';
        if (allowed) {
            safe.push_back(raw);
        }
    }
    if (safe.empty()) return {};
    return safe + ".plist";
}

} // namespace

void set_storage_directory(const std::string& directory) {
    std::scoped_lock lock(store_mutex());
    store_directory() = directory;
}

std::string storage_directory() {
    std::scoped_lock lock(store_mutex());
    return store_directory();
}

bool has_record(const std::string& udid) {
    const std::string file_name = record_file_name(udid);
    if (file_name.empty()) return false;
    std::scoped_lock lock(store_mutex());
    const std::string& directory = store_directory();
    if (directory.empty()) return false;
    std::error_code error;
    return std::filesystem::exists(
        std::filesystem::path(directory) / file_name, error);
}

bool load_record(const std::string& udid, std::string& xml) {
    const std::string file_name = record_file_name(udid);
    if (file_name.empty()) return false;
    std::scoped_lock lock(store_mutex());
    const std::string& directory = store_directory();
    if (directory.empty()) return false;
    std::ifstream stream(
        std::filesystem::path(directory) / file_name, std::ios::binary);
    if (!stream) return false;
    xml.assign(std::istreambuf_iterator<char>(stream),
        std::istreambuf_iterator<char>());
    return !xml.empty();
}

bool save_record(const std::string& udid, const std::string& xml) {
    const std::string file_name = record_file_name(udid);
    if (file_name.empty()) return false;
    std::scoped_lock lock(store_mutex());
    const std::string& directory = store_directory();
    if (directory.empty()) return false;

    std::error_code error;
    std::filesystem::create_directories(directory, error);
    if (error) {
        logging::write(logging::Level::Warning, "pairing-store", std::format(
            "创建配对记录目录失败：{}", error.message()));
        return false;
    }

    const auto target = std::filesystem::path(directory) / file_name;
    // 先写临时文件再改名：中途掉电不会留下半截记录。
    const auto temporary = std::filesystem::path(directory) /
        (file_name + ".tmp");
    {
        std::ofstream stream(temporary, std::ios::binary | std::ios::trunc);
        if (!stream) return false;
        stream << xml;
        stream.flush();
        if (!stream) return false;
    }
    std::filesystem::rename(temporary, target, error);
    if (error) {
        // 某些文件系统上 rename 不覆盖已有文件，先删再改名。
        std::error_code remove_error;
        std::filesystem::remove(target, remove_error);
        std::filesystem::rename(temporary, target, error);
        if (error) {
            logging::write(logging::Level::Warning, "pairing-store",
                std::format("写入配对记录失败：{}", error.message()));
            return false;
        }
    }
    return true;
}

bool remove_record(const std::string& udid) {
    const std::string file_name = record_file_name(udid);
    if (file_name.empty()) return false;
    std::scoped_lock lock(store_mutex());
    const std::string& directory = store_directory();
    if (directory.empty()) return false;
    std::error_code error;
    return std::filesystem::remove(
        std::filesystem::path(directory) / file_name, error);
}

} // namespace iPhoneMirror::ohos::pairing_store

// ───────────────────────── C ABI：设置存放目录 ─────────────────────────
//
// 由 ArkTS 侧把 context.filesDir 传进来（原生侧拿不到它）。这与
// im_set_log_file 的做法一致 —— 日志路径也是 ArkTS 传进来的。
void im_set_pairing_store_directory(const char* directory) {
    iPhoneMirror::ohos::pairing_store::set_storage_directory(
        directory != nullptr ? std::string(directory) : std::string());
}
