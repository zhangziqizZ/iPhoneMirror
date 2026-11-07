// SPDX-License-Identifier: GPL-3.0-only
//
// 配对记录（pair record）的持久化：插一次，长期免弹窗。
//
// ── 配对记录是什么 ───────────────────────────────────────────────
//
// 它是"这台电脑被这台 iPhone 信任了"的凭据，里面有：
//   HostID / SystemBUID      本机身份（决定设备认不认这台电脑）
//   RootCertificate/…        根 CA 与主机证书（设备侧存着对应的公钥）
//   RootPrivateKey/…         **私钥**（用来跟设备做 SSL 会话）
//   EscrowBag                设备回赠的托管密钥袋
//   WiFiMACAddress           设备的 Wi-Fi MAC（设备侧校验用）
//
// ★ 为什么必须存到沙箱而不是每次重新生成 ★
//
// ① 设备侧记的是"HostID + 根 CA 公钥"。HostID 每次随机 ⇒ 设备会当成新电脑
//    ⇒ **每次插线都弹窗**，这正是"插一次就长期免弹窗"要避免的。
// ② 后续要用这个记录跟设备开 SSL 会话（StartSession），那需要**私钥**。
//    私钥丢了就再也不能开加密会话，只能重新配对（又要弹窗）。
//
// 所以配对记录是**一次生成、长期复用**的东西，必须落盘。
//
// ── 存在哪 ───────────────────────────────────────────────────────
//
// 应用沙箱（ArkTS 侧 context.filesDir 传进来的路径）。理由：
//   * 别的应用读不到（配对记录含私钥）；
//   * 卸载应用即清除（符合"信任关系随应用一起消失"的直觉）；
//   * 不用申请任何额外权限。
//
// 目录不存在时自己创建（与 Core 的 Logging.cpp 同一手法）。

#pragma once

#include <string>

namespace iPhoneMirror::ohos::pairing_store {

// 配对记录的存放目录（由 ArkTS 传入的沙箱路径派生）。
//
// 传空串表示"不持久化"——此时配对仍然能完成（弹窗照样出来），只是下次插线
// 又要重新信任。这在"沙箱路径拿不到"的极端情况下是合理的降级。
void set_storage_directory(const std::string& directory);

// 当前使用的存放目录。空串表示未设置。
//
// ★ 返回值而不是引用 ★：目录可以被 set_storage_directory() 在另一线程改写，
//   返回内部引用会让调用方在解锁后拿到可能已被替换/销毁的对象（数据竞争 +
//   悬空引用）。值拷贝给出的是调用时刻的快照，后续如何变化都不影响调用方。
[[nodiscard]] std::string storage_directory();

// 是否存在某台设备（按 UDID）的配对记录。
[[nodiscard]] bool has_record(const std::string& udid);

// 读出某台设备的配对记录（plist::Value 形式的字典）。
//
// 没有记录时返回 false。读失败（文件损坏等）也返回 false —— 但那与"没有记录"
// 是两回事：前者说明记录该重建，后者说明一切正常。
[[nodiscard]] bool load_record(const std::string& udid, std::string& xml);

// 写入某台设备的配对记录。
//
// 写入采用"先写临时文件再改名"的原子做法：中途掉电不会留下半截文件，
// 而半截的配对记录会让设备侧报一个毫无线索的错误。
bool save_record(const std::string& udid, const std::string& xml);

// 删除某台设备的配对记录（用于"解除信任"）。
bool remove_record(const std::string& udid);

} // namespace iPhoneMirror::ohos::pairing_store

extern "C" {

// 设置配对记录的存放目录（应用沙箱路径，由 ArkTS 侧传入）。
//
// 为什么由 ArkTS 传：原生侧拿不到应用的 filesDir（那是 ArkTS 的
// context.filesDir），这与 im_set_log_file 的做法一致 —— 日志路径也是
// ArkTS 传进来的。
//
// 传空串表示不持久化（配对仍能完成，只是下次插线要重新信任）。
void im_set_pairing_store_directory(const char* directory);

}
