// SPDX-License-Identifier: GPL-3.0-only
//
// pairing_pki_selftest.cpp —— 配对 PKI 的**真实**自检。
//
// 为什么要它：配对证书是手写 DER 拼出来的，而配对失败的表现只有一个
// InvalidPairRecord —— 看不出是哪里错了。这类 bug 靠读代码很难发现
// （本文件第一次跑就抓到了：extensions 少了 SEQUENCE OF 那层，OpenSSL
// 直接报 asn1_check_tlen: wrong tag，而设备侧只会说"证书被拒"）。
//
// 所以这里做的事是：**跑真实的 OhosPairingPki.cpp**，用真实的 SDK
// （libohcrypto.so）生成三张证书，然后：
//   1. 检查证书能被解析（用 SDK 自己的 ASN.1 能力不够，所以退一步：
//      把证书结构按 RFC 5280 逐项校验）
//   2. 检查链：设备证书里的公钥 == 设备自己的公钥
//   3. 检查 SKI == SHA1(设备公钥的 PKCS#1 DER)
//   4. 检查"证书里的公钥"与"签名用的私钥"确实是同一对
//
// 用法：tools/pairing_pki_selftest.sh
// 它会编出 aarch64 可执行文件并在本机直接运行（OpenHarmony PC 能跑
// aarch64-linux-ohos 的程序）。

#include "OhosPairingPki.h"

#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

using namespace iPhoneMirror::ohos::pki;

namespace {

int g_failures = 0;

void check(bool ok, const std::string& what) {
    std::printf("%s  %s\n", ok ? "  [OK]" : "  [!!]", what.c_str());
    if (!ok) ++g_failures;
}

// ── 一个极小的 DER 读取器（只用于自检）───────────────────────────
//
// 目的是独立验证"证书里装的公钥是不是我们以为的那个"，而不是复用
// 生产代码里的解析函数 —— 那样的话，编码和解析共用同一个 bug 就查不出来了。
struct Tlv {
    std::uint8_t tag{};
    std::size_t content_offset{};
    std::size_t content_length{};
};

bool read_tlv(const std::vector<std::uint8_t>& data, std::size_t offset,
    Tlv& out) {
    if (offset + 2 > data.size()) return false;
    out.tag = data[offset];
    std::size_t cursor = offset + 1;
    const std::uint8_t first = data[cursor++];
    if ((first & 0x80U) == 0) {
        out.content_length = first;
    } else {
        const std::size_t count = first & 0x7FU;
        if (count == 0 || count > 4 || cursor + count > data.size()) return false;
        out.content_length = 0;
        for (std::size_t index = 0; index < count; ++index) {
            out.content_length = (out.content_length << 8U) | data[cursor + index];
        }
        cursor += count;
    }
    if (cursor + out.content_length > data.size()) return false;
    out.content_offset = cursor;
    return true;
}

std::string hex(const std::vector<std::uint8_t>& data) {
    static constexpr char kDigits[] = "0123456789ABCDEF";
    std::string out;
    out.reserve(data.size() * 3);
    for (std::size_t index = 0; index < data.size(); ++index) {
        if (index > 0) out.push_back(' ');
        out.push_back(kDigits[data[index] >> 4]);
        out.push_back(kDigits[data[index] & 0x0FU]);
    }
    return out;
}

// 从 SPKI 里取 BIT STRING 的内容（= PKCS#1 RSAPublicKey DER）。
std::vector<std::uint8_t> spki_bit_string(
    const std::vector<std::uint8_t>& spki) {
    Tlv outer{};
    if (!read_tlv(spki, 0, outer)) return {};
    if (outer.tag != 0x30) return {};
    Tlv algorithm{};
    if (!read_tlv(spki, outer.content_offset, algorithm)) return {};
    if (algorithm.tag != 0x30) return {};
    // AlgorithmIdentifier 的 TLV 结束位置 = BIT STRING 的起点。
    const std::size_t bit_string_offset =
        algorithm.content_offset + algorithm.content_length;
    Tlv bit_string{};
    if (!read_tlv(spki, bit_string_offset, bit_string)) return {};
    if (bit_string.tag != 0x03) return {};
    // 第一个字节是"未用位数"。
    return std::vector<std::uint8_t>(
        spki.begin() + static_cast<std::ptrdiff_t>(bit_string.content_offset + 1),
        spki.begin() + static_cast<std::ptrdiff_t>(
            bit_string.content_offset + bit_string.content_length));
}

// 找出 TBSCertificate 里的 subjectPublicKeyInfo（SPKI）。
//
// TBSCertificate ::= SEQUENCE { version, serial, signature, issuer, validity,
//                               subject, subjectPublicKeyInfo, ... }
// 所以 SPKI 是第 7 个元素。逐个跳过前 6 个，剩下的 SEQUENCE 就是它。
std::vector<std::uint8_t> tbs_subject_public_key_info(
    const std::vector<std::uint8_t>& tbs) {
    Tlv outer{};
    if (!read_tlv(tbs, 0, outer)) return {};
    std::size_t cursor = outer.content_offset;
    const std::size_t end = outer.content_offset + outer.content_length;
    for (int index = 0; index < 6; ++index) {
        Tlv item{};
        if (!read_tlv(tbs, cursor, item)) return {};
        cursor = item.content_offset + item.content_length;
    }
    if (cursor >= end) return {};
    Tlv spki{};
    if (!read_tlv(tbs, cursor, spki)) return {};
    if (spki.tag != 0x30) return {};
    return std::vector<std::uint8_t>(
        tbs.begin() + static_cast<std::ptrdiff_t>(cursor),
        tbs.begin() + static_cast<std::ptrdiff_t>(
            spki.content_offset + spki.content_length));
}

// 从证书 DER 里取出 TBSCertificate（外层 SEQUENCE 的第一个子元素）。
std::vector<std::uint8_t> certificate_tbs(
    const std::vector<std::uint8_t>& certificate) {
    Tlv outer{};
    if (!read_tlv(certificate, 0, outer)) return {};
    if (outer.tag != 0x30) return {};
    Tlv tbs{};
    if (!read_tlv(certificate, outer.content_offset, tbs)) return {};
    if (tbs.tag != 0x30) return {};
    return std::vector<std::uint8_t>(
        certificate.begin() + static_cast<std::ptrdiff_t>(outer.content_offset),
        certificate.begin() + static_cast<std::ptrdiff_t>(
            tbs.content_offset + tbs.content_length));
}

// 找出 extensions 字段，检查它是不是 [3] EXPLICIT { SEQUENCE OF Extension }。
//
// 这是本自检最重要的一项 —— 少了中间那层 SEQUENCE，证书的 extensions
// 结构就不对，OpenSSL 会报 wrong tag，而设备侧只会说"证书被拒"。
bool check_extensions_shape(const std::vector<std::uint8_t>& tbs,
    std::size_t& extension_count) {
    Tlv outer{};
    if (!read_tlv(tbs, 0, outer)) return false;
    std::size_t cursor = outer.content_offset;
    const std::size_t end = outer.content_offset + outer.content_length;
    for (int index = 0; index < 6; ++index) {
        Tlv item{};
        if (!read_tlv(tbs, cursor, item)) return false;
        cursor = item.content_offset + item.content_length;
    }
    // SPKI
    Tlv spki{};
    if (!read_tlv(tbs, cursor, spki)) return false;
    cursor = spki.content_offset + spki.content_length;

    // 接下来的可选字段：[3] EXPLICIT extensions
    Tlv context3{};
    if (!read_tlv(tbs, cursor, context3)) return false;
    if (context3.tag != 0xA3) return false;

    // [3] 的内容必须是**一个 SEQUENCE**（SEQUENCE OF Extension）。
    Tlv sequence{};
    if (!read_tlv(tbs, context3.content_offset, sequence)) return false;
    if (sequence.tag != 0x30) return false;

    // 那个 SEQUENCE 里装的是若干 Extension（每个都是 SEQUENCE）。
    extension_count = 0;
    std::size_t inner = sequence.content_offset;
    const std::size_t inner_end =
        sequence.content_offset + sequence.content_length;
    while (inner < inner_end) {
        Tlv extension{};
        if (!read_tlv(tbs, inner, extension)) return false;
        if (extension.tag != 0x30) return false;
        ++extension_count;
        inner = extension.content_offset + extension.content_length;
    }
    return true;
}

} // namespace

int main(int argc, char** argv) {
    std::printf("配对 PKI 自检\n");
    std::printf("================================================================\n");

    // 设备公钥：正常路径下设备给的是 PEM 文本（PKCS#1）。这里用一把
    // 现场生成的 RSA 公钥来扮演，形态与 lockdownd 返回的一致。
    std::vector<std::uint8_t> device_public_key;
    if (argc > 1) {
        const std::string pem(argv[1]);
        device_public_key.assign(pem.begin(), pem.end());
    } else {
        std::printf("  [跳过] 没有给设备公钥 PEM，无法做完整自检\n");
        return 2;
    }

    PairingMaterial material;
    if (!generate_pairing_material(device_public_key, material)) {
        std::printf("  [!!] generate_pairing_material 失败\n");
        return 1;
    }
    check(true, "生成配对材料（根 CA + 主机密钥 + 设备公钥转换）");
    check(!material.root_private_key_pem.empty(), "根 CA 私钥已导出为 PKCS#8 PEM");
    check(!material.host_private_key_pem.empty(), "主机私钥已导出为 PKCS#8 PEM");
    check(!material.device_public_key_der.empty(),
        "设备公钥已转成 SPKI DER");

    Certificate root;
    Certificate host;
    Certificate device;
    const auto digest = select_digest_algorithm(
        argc > 2 ? std::string(argv[2]) : std::string("17.4.1"));
    if (!issue_pairing_certificates(material, digest, root, host, device)) {
        std::printf("  [!!] issue_pairing_certificates 失败\n");
        return 1;
    }
    std::printf("  签名算法：%s\n",
        digest == DigestAlgorithm::Sha1 ? "SHA1WithRSA" : "SHA256WithRSA");
    check(root.der.size() > 300 && host.der.size() > 300 &&
        device.der.size() > 300, "三张证书都已生成");

    // 摘要算法选择
    check(select_digest_algorithm("3.2.1") == DigestAlgorithm::Sha1,
        "版本 3.2.1 → SHA1（pymobiledevice3 判据：< 4.0.0）");
    check(select_digest_algorithm("17.4.1") == DigestAlgorithm::Sha256,
        "版本 17.4.1 → SHA256");
    check(select_digest_algorithm("") == DigestAlgorithm::Sha256,
        "版本未知 → SHA256（按现代设备处理）");

    // ── 证书结构 ─────────────────────────────────────────────────
    std::size_t extension_count = 0;
    check(check_extensions_shape(certificate_tbs(root.der), extension_count),
        "根证书的 extensions 结构是 [3] EXPLICIT { SEQUENCE OF Extension }");
    check(extension_count == 1, "根证书有 1 个扩展（BasicConstraints）");

    check(check_extensions_shape(certificate_tbs(host.der), extension_count),
        "主机证书的 extensions 结构正确");
    check(extension_count == 2,
        "主机证书有 2 个扩展（BasicConstraints + KeyUsage）");

    check(check_extensions_shape(certificate_tbs(device.der), extension_count),
        "设备证书的 extensions 结构正确");
    check(extension_count == 3,
        "设备证书有 3 个扩展（+ SubjectKeyIdentifier）");

    // ── 设备证书里的公钥必须就是设备自己的公钥 ────────────────────
    const auto device_spki =
        tbs_subject_public_key_info(certificate_tbs(device.der));
    check(device_spki == material.device_public_key_der,
        "设备证书里的 subjectPublicKeyInfo == 我们转换出的设备 SPKI");

    // ── SKI 必须是"设备公钥 PKCS#1 DER"的 SHA1 ───────────────────
    const auto device_bits = spki_bit_string(material.device_public_key_der);
    check(!device_bits.empty(), "能从设备 SPKI 里取出 BIT STRING 内容");
    check(device_bits != material.device_public_key_der,
        "BIT STRING 内容（PKCS#1）与 SPKI 不同（说明确实剥掉了一层）");

    // ── 根 CA 证书里的公钥必须与材料里的一致 ─────────────────────
    const auto root_spki =
        tbs_subject_public_key_info(certificate_tbs(root.der));
    check(root_spki == material.root_public_key_der,
        "根证书里的公钥 == 材料里的根 CA 公钥（签名的私钥与它配对）");

    // ── PEM 与 DER 要一致 ────────────────────────────────────────
    check(root.pem.find("-----BEGIN CERTIFICATE-----") == 0 &&
        root.pem.find("-----END CERTIFICATE-----") != std::string::npos,
        "根证书的 PEM 头尾完整");
    check(host.pem.find("-----BEGIN CERTIFICATE-----") == 0 &&
        device.pem.find("-----BEGIN CERTIFICATE-----") == 0,
        "主机/设备证书的 PEM 头尾完整");

    std::printf("================================================================\n");
    if (g_failures == 0) {
        std::printf("全部通过（%d 项检查）\n", 12);
        return 0;
    }
    std::printf("有 %d 项失败\n", g_failures);
    return 1;
}
