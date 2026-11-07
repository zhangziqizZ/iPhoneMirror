// SPDX-License-Identifier: GPL-3.0-only
//
// 配对用的 X.509 证书生成（根 CA + 主机证书 + 设备证书）。
//
// ── 为什么这里要自己写 DER 编码 ─────────────────────────────────────
//
// 鸿蒙 SDK 提供 CryptoArchitectureKit（libohcrypto.so）：RSA 密钥生成、
// RSA|PKCS1|SHA1 签名、公私钥的 DER/PEM 编码。**但它没有 X.509 证书的
// 构造 API**（头文件里没有任何 X509/Certificate 相关符号）。而 iOS 的配对
// 协议要求给设备三张**成链的 X.509 证书**，光有密钥和签名能力不够。
//
// 所以这一层要自己拼 DER：
//
//   Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signature }
//   TBSCertificate ::= SEQUENCE { version, serialNumber, signature, issuer,
//                                 validity, subject, subjectPublicKeyInfo,
//                                 [3] extensions }
//
// ── 设备对证书链的具体要求（这是能不能配成对的关卡）──────────────
//
// 参照 libimobiledevice 的 idevicepair 与 pymobiledevice3 的 ca.py：
//
//   * 三张证书都是**空 subject/issuer**（x509.Name([])）、序列号 1。
//   * 有效期：now-1min 到 now+10 年。
//   * 根 CA 自签；主机证书与设备证书都由根 CA 签发。
//   * **设备证书里嵌的是设备自己的公钥**（从 lockdownd 的
//     GetValue("DevicePublicKey") 拿到的原文），不是我们生成的公钥。
//     这是"设备证书"的含义：证明"这台设备就是这把钥匙的主人"。
//   * 设备证书额外带 **SubjectKeyIdentifier** 扩展，其值是**公钥 DER 里的
//     BIT STRING 部分**（即 RSAPublicKey 的 DER）做 SHA1。这一点最容易搞错：
//     算整个 SubjectPublicKeyInfo 的 SHA1 会被设备拒绝，而且**不给任何有用的
//     错误信息**（iosctl 的作者为此对过很久的抓包）。
//   * 签名算法：iOS 7+ 用 SHA1WithRSA，新设备用 SHA256WithRSA。
//     pymobiledevice3 按设备固件版本二选一。
//
// ── 摘要算法与 SHA1 的取舍 ─────────────────────────────────────────
//
// iosctl 的文章说"这套配对协议至今仍在使用 SHA1WithRSA"，而 pymobiledevice3
// 则按设备版本在 SHA1/SHA256 之间切换。本工程的做法与 pymobiledevice3 一致：
// **优先 SHA256，遇到设备拒收再退回 SHA1**。理由是 SHA256 在新系统上被接受
// 的概率更高（iOS 17+ 已经拒绝纯 SHA1 签名的配对证书），而 SHA1 只在老设备上
// 才是必需的。实现上由调用方决定用哪个摘要。
//
// ── 私钥为什么不能只存 PEM 字符串 ─────────────────────────────────
//
// CryptoArchitectureKit **没有"用 PEM 字符串直接签名"的入口**：签名要的是
// OH_CryptoPrivKey* 对象，而它只能从 OH_CryptoKeyPair 里取。所以：
//
//   * 生成阶段：持有 KeyPair 对象，用它签三张证书。
//   * 持久化阶段：把私钥导出成 PKCS#8 PEM 存到沙箱（配对记录要长期保存）。
//   * 复用阶段：把 PEM **重新导入**成 KeyPair 再签（只有根 CA 需要复用）。
//
// 因此本模块的接口是"先生成整套材料，再落盘"，而不是"每次签名前自己导入"。

#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace iPhoneMirror::ohos::pki {

// 证书摘要算法。设备按固件版本只接受其中一种。
enum class DigestAlgorithm {
    // SHA1WithRSA：iOS 4 之前的配对协议用这个（现在已无设备）。
    Sha1,
    // SHA256WithRSA：iOS 4 及以后用这个。
    Sha256,
};

// 按设备版本选摘要算法。
//
// 依据：pymobiledevice3 的 select_hash_algorithm() 明确写着
// "Choose hash algorithm to match libimobiledevice (idevicepair) logic"，
// 判据是版本 < 4.0.0 用 SHA-1、否则用 SHA-256。
//
// ★ 注意与 libimobiledevice idevicepair 的差异 ★
//   idevicepair 的 userpref.c 里写死了 EVP_sha1()，但那是老代码；
//   pymobiledevice3 的判据（<4.0.0 才 SHA1）才是当前设备实际接受的：
//   现代 iOS（4.0 以后）一律 SHA256WithRSA。
//
// version_string 是设备的 ProductVersion（形如 "17.4.1"）；拿不到时按
// 现代设备处理（SHA256）。
[[nodiscard]] DigestAlgorithm select_digest_algorithm(
    const std::string& version_string);

// 一份 X.509 证书（DER 字节）与它的 PEM 形式。
struct Certificate {
    std::vector<std::uint8_t> der;
    std::string pem;
};

// 一套配对用的密钥材料。
//
// root_* 是根 CA（自签 + 签发另外两张）；host_* 是主机自己的（自用）。
//
// ★ root_private_key_pem 可能来自"已保存的配对记录" ★
//   复用一个根 CA 是"插一次就长期免弹窗"的必要条件（设备记着根 CA 的公钥，
//   换一把根 CA 就等于换了一台电脑）。所以这份材料有两个来源：
//     · 新生成（首次配对）
//     · 从配对记录里恢复（后续配对）
//   两种来源在这里是同一份数据，区别只在"私钥从哪来"。
struct PairingMaterial {
    // 根 CA 的公钥（SubjectPublicKeyInfo DER）与私钥（PKCS#8 PEM）。
    std::vector<std::uint8_t> root_public_key_der;
    std::string root_private_key_pem;
    // 主机的公钥与私钥。
    std::vector<std::uint8_t> host_public_key_der;
    std::string host_private_key_pem;
    // 设备的公钥（SubjectPublicKeyInfo DER）。
    //
    // 注意：这是**转换后**的形态。设备的 DevicePublicKey 原本是 PEM 文本
    // （"RSA PUBLIC KEY" = PKCS#1），这里已经包成了证书里要用的 SPKI。
    std::vector<std::uint8_t> device_public_key_der;
};

// 生成根 CA 与主机的 RSA-2048 密钥对，并转换设备的公钥。
//
// device_public_key 是设备给的公钥**原文**（字节）：
//   · PEM 文本（"RSA PUBLIC KEY" 标签 = PKCS#1 的 RSAPublicKey）—— 实际形态
//   · 或已经是 DER（SPKI / PKCS#1 都能认）
//
// 为什么是 PEM 而不是 DER：libimobiledevice 的
// lockdownd_get_device_public_key_as_key_data() 拿到的是 key_data_t（裸 PEM
// 字节），随后用 d2i_PUBKEY 之类读成公钥；pymobiledevice3 更直白 ——
// load_pem_public_key(device_public_key_pem)，参数名就叫 _pem。
[[nodiscard]] bool generate_pairing_material(
    const std::vector<std::uint8_t>& device_public_key,
    PairingMaterial& out);

// 从**已保存的根 CA 私钥**恢复材料（复用同一个根 CA）。
//
// root_private_key_pem 是 PKCS#8 PEM。恢复时要把私钥重新导入成密钥对象，
// 并从中重新导出公钥（公钥是私钥的函数，证书里那份不能直接拿来当
// SubjectPublicKeyInfo 的输入）。
//
// 主机密钥**重新生成**：主机的私钥不参与设备侧的信任判定，设备只关心
// HostID 与根 CA。换一把主机密钥不影响"免弹窗"。
[[nodiscard]] bool restore_pairing_material(
    const std::string& root_private_key_pem,
    const std::vector<std::uint8_t>& device_public_key,
    PairingMaterial& out);

// 用配对材料签发三张证书。
//
// 一次签完，因为三张证书共用同一个根 CA 私钥；分开调用反而要反复导入私钥。
[[nodiscard]] bool issue_pairing_certificates(const PairingMaterial& material,
    DigestAlgorithm digest, Certificate& root, Certificate& host,
    Certificate& device);

} // namespace iPhoneMirror::ohos::pki
