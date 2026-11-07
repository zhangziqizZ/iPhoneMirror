// SPDX-License-Identifier: GPL-3.0-only
//
// OhosPairingPki.h 的实现：X.509 证书的 DER 编码 + CryptoArchitectureKit 调用。
//
// 协议要求与 DER 规则见 OhosPairingPki.h，这里只补实现层面的说明。
//
// ── 与 CryptoArchitectureKit 的对接方式（踩过的坑）────────────────
//
// 1. 生成密钥对有两条路：
//      · OH_CryptoAsymKeyGenerator_Create("RSA2048") + Generate   （API 12）
//      · OH_CryptoAsymKeySpec_Create("RSA", KEY_PAIR_SPEC) + 参数 + GenKeyPair
//        （API 20）
//    这里用**前者**：不需要猜 CRYPTO_RSA_KEY_BITS 这个参数的取值单位，
//    而且 API 12 就能用（本工程 compatibleSdkVersion 是 26，不缺 API 20，
//    但少一个 API 依赖就少一处版本风险）。
//
// 2. 签名要的是 OH_CryptoPrivKey*，而它**只能**从 OH_CryptoKeyPair 里取
//    （没有 OH_CryptoPrivKey_Destroy —— 密钥的生命周期由 keyPair 持有）。
//    所以整个签发过程必须持有 keyPair 对象，不能只留私钥的 PEM 字符串。
//
// 3. 私钥的 PEM（PKCS#8）只用于**落盘**（配对记录要长期保存），以及
//    将来复用根 CA 时重新导入。重新导入走 OH_CryptoAsymKeyGenerator_Convert，
//    它吃的是**密钥材料**（DER/PEM 字节），签名是"私钥材料 + 公钥材料"成对
//    给的 —— 所以重新导入时要一并给出公钥。
//
// 4. 公钥导出用 OH_CryptoPubKey_Encode(key, CRYPTO_DER, "X509", out)：
//    产出的就是 SubjectPublicKeyInfo 的 DER，正是证书里 subjectPublicKeyInfo
//    字段要用的形态。

#include "OhosPairingPki.h"

#include "Logging.h"

#include <array>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <format>
#include <string_view>

#if defined(__has_include)
#  if __has_include(<CryptoArchitectureKit/crypto_architecture_kit.h>)
#    include <CryptoArchitectureKit/crypto_architecture_kit.h>
#    define IM_HAVE_CRYPTO_ARCHITECTURE_KIT 1
#  endif
#endif

namespace iPhoneMirror::ohos::pki {
namespace {

// ── DER 基础编码 ──────────────────────────────────────────────────

constexpr std::uint8_t TagInteger = 0x02;
constexpr std::uint8_t TagBitString = 0x03;
constexpr std::uint8_t TagOctetString = 0x04;
constexpr std::uint8_t TagNull = 0x05;
constexpr std::uint8_t TagOid = 0x06;
constexpr std::uint8_t TagUtcTime = 0x17;
constexpr std::uint8_t TagSequence = 0x30;
constexpr std::uint8_t TagBoolean = 0x01;
constexpr std::uint8_t TagContext0 = 0xA0;   // [0] EXPLICIT version
constexpr std::uint8_t TagContext3 = 0xA3;   // [3] EXPLICIT extensions

// 长度编码（DER 要求用最短形式）。
void encode_length(std::vector<std::uint8_t>& out, std::size_t length) {
    if (length < 0x80) {
        out.push_back(static_cast<std::uint8_t>(length));
        return;
    }
    std::vector<std::uint8_t> bytes;
    while (length > 0) {
        bytes.push_back(static_cast<std::uint8_t>(length & 0xFFU));
        length >>= 8U;
    }
    out.push_back(static_cast<std::uint8_t>(0x80U | bytes.size()));
    for (auto it = bytes.rbegin(); it != bytes.rend(); ++it) {
        out.push_back(*it);
    }
}

// 标签 + 长度 + 内容。
void encode_tlv(std::vector<std::uint8_t>& out, std::uint8_t tag,
    const std::vector<std::uint8_t>& content) {
    out.push_back(tag);
    encode_length(out, content.size());
    out.insert(out.end(), content.begin(), content.end());
}

// INTEGER（只处理小的非负数）。
void encode_integer(std::vector<std::uint8_t>& out, std::uint32_t value) {
    std::vector<std::uint8_t> content;
    bool started = false;
    for (int shift = 24; shift >= 0; shift -= 8) {
        const auto byte = static_cast<std::uint8_t>((value >> shift) & 0xFFU);
        if (byte != 0 || started) {
            content.push_back(byte);
            started = true;
        }
    }
    if (content.empty()) content.push_back(0);
    if ((content.front() & 0x80U) != 0) content.insert(content.begin(), 0);
    encode_tlv(out, TagInteger, content);
}

// BIT STRING（unused bits 固定 0）。
void encode_bit_string(std::vector<std::uint8_t>& out,
    const std::vector<std::uint8_t>& content) {
    std::vector<std::uint8_t> body;
    body.push_back(0x00);
    body.insert(body.end(), content.begin(), content.end());
    encode_tlv(out, TagBitString, body);
}

void encode_oid(std::vector<std::uint8_t>& out,
    const std::vector<std::uint8_t>& content) {
    encode_tlv(out, TagOid, content);
}

// AlgorithmIdentifier：OID + NULL 参数。
std::vector<std::uint8_t> algorithm_identifier(
    const std::vector<std::uint8_t>& oid) {
    std::vector<std::uint8_t> content;
    encode_oid(content, oid);
    content.push_back(TagNull);
    content.push_back(0x00);
    std::vector<std::uint8_t> result;
    encode_tlv(result, TagSequence, content);
    return result;
}

// OID 的编码内容（各家固定字节）。
const std::vector<std::uint8_t>& oid_sha1_with_rsa() {
    static const std::vector<std::uint8_t> value = {
        0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x05};
    return value;
}

const std::vector<std::uint8_t>& oid_sha256_with_rsa() {
    static const std::vector<std::uint8_t> value = {
        0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B};
    return value;
}

const std::vector<std::uint8_t>& oid_subject_key_identifier() {
    static const std::vector<std::uint8_t> value = {0x55, 0x1D, 0x0E};
    return value;
}

// BasicConstraints（2.5.29.19）。
//
// 为什么必须有：pymobiledevice3 的 build_root_certificate /
// build_host_certificate / build_device_certificate 三张证书**都**带
// BasicConstraints（根证书 ca=True，叶子 ca=FALSE，且都是 critical）。
// 少了它，设备的证书链校验可能直接判"签发者不是 CA"从而拒收 ——
// 而报错依然是那个看不出原因的 InvalidPairRecord。
const std::vector<std::uint8_t>& oid_basic_constraints() {
    static const std::vector<std::uint8_t> value = {0x55, 0x1D, 0x13};
    return value;
}

// KeyUsage（2.5.29.15）。
//
// 叶子的 KeyUsage = digitalSignature + keyEncipherment（都是 critical）。
// KeyUsage 的值是一个 BIT STRING，位序从高位起算：
//   bit0 digitalSignature、bit1 nonRepudiation、bit2 keyEncipherment
// 只有 bit0 与 bit2 置位 ⇒ 前 3 位有效、后面 5 位未用
// ⇒ 内容字节 = 0b1010_0000 = 0xA0，未用位数 = 5。
const std::vector<std::uint8_t>& oid_key_usage() {
    static const std::vector<std::uint8_t> value = {0x55, 0x1D, 0x0F};
    return value;
}

// BasicConstraints 的扩展值。
//
// ca=true  → SEQUENCE { BOOLEAN TRUE }（DER 里 TRUE 编成 0xFF）
// ca=false → SEQUENCE { }（空序列；FALSE 是默认值，省略）
std::vector<std::uint8_t> basic_constraints_value(bool is_ca) {
    std::vector<std::uint8_t> content;
    if (is_ca) {
        content.push_back(TagBoolean);
        content.push_back(0x01);
        content.push_back(0xFF);
    }
    std::vector<std::uint8_t> result;
    encode_tlv(result, TagSequence, content);
    return result;
}

// KeyUsage 的扩展值：BIT STRING { 0xA0 }，未用位数 5。
std::vector<std::uint8_t> key_usage_value() {
    std::vector<std::uint8_t> body;
    body.push_back(0x05); // 未用位数
    body.push_back(0xA0); // digitalSignature | keyEncipherment
    std::vector<std::uint8_t> result;
    encode_tlv(result, TagBitString, body);
    return result;
}

// rsaEncryption 的 OID（1.2.840.113549.1.1.1）。
//
// SPKI 的 AlgorithmIdentifier 用它 —— 证书里的 subjectPublicKeyInfo 是
// "算法 + 公钥" 的组合，RSA 的算法标识就是这个 OID。
const std::vector<std::uint8_t>& oid_rsa_encryption() {
    static const std::vector<std::uint8_t> value = {
        0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01};
    return value;
}

// 把一个扩展塞进 extensions 的 SEQUENCE OF。
//
// ★ extnValue 的封装层次是最容易错的地方 ★
//
// Extension ::= SEQUENCE {
//     extnID      OBJECT IDENTIFIER,
//     critical    BOOLEAN DEFAULT FALSE,
//     extnValue   OCTET STRING   -- 装的是"扩展值本身的 DER 编码"
// }
//
// 所以 extnValue 是**双层**：外层 OCTET STRING 装的是内层扩展值 DER。
// 比如 SubjectKeyIdentifier 的扩展值类型是 KeyIdentifier ::= OCTET STRING，
// 于是 extnValue = OCTET STRING { OCTET STRING(20 字节) } —— 两层。
// 少一层的话，设备解析出来的 SKI 就是空的，证书链校验必然失败，
// 而报错只有那个看不出原因的 InvalidPairRecord。
//
// critical 为 true 时要显式写 BOOLEAN TRUE（DER 里 TRUE 编成 0xFF）；
// 为 false 时省略（DEFAULT FALSE）。
void encode_extension(std::vector<std::uint8_t>& extensions,
    const std::vector<std::uint8_t>& oid, bool critical,
    const std::vector<std::uint8_t>& value_der) {
    std::vector<std::uint8_t> extension;
    encode_oid(extension, oid);
    if (critical) {
        extension.push_back(TagBoolean);
        extension.push_back(0x01);
        extension.push_back(0xFF);
    }
    std::vector<std::uint8_t> extn_value;
    encode_tlv(extn_value, TagOctetString, value_der);
    extension.insert(extension.end(), extn_value.begin(), extn_value.end());

    std::vector<std::uint8_t> wrapped;
    encode_tlv(wrapped, TagSequence, extension);
    extensions.insert(extensions.end(), wrapped.begin(), wrapped.end());
}

// 把 PKCS#1 的 RSAPublicKey DER 包成 SubjectPublicKeyInfo DER。
//
// SubjectPublicKeyInfo ::= SEQUENCE {
//     algorithm       AlgorithmIdentifier,
//     subjectPublicKey BIT STRING
// }
//
// AlgorithmIdentifier = SEQUENCE { OID rsaEncryption, NULL }
// BIT STRING 的内容 = 00（未用位数）+ PKCS#1 DER
std::vector<std::uint8_t> spki_from_pkcs1(
    const std::vector<std::uint8_t>& pkcs1_der) {
    std::vector<std::uint8_t> algorithm_content;
    encode_oid(algorithm_content, oid_rsa_encryption());
    algorithm_content.push_back(TagNull);
    algorithm_content.push_back(0x00);
    std::vector<std::uint8_t> algorithm;
    encode_tlv(algorithm, TagSequence, algorithm_content);

    std::vector<std::uint8_t> bit_string_body;
    bit_string_body.push_back(0x00);
    bit_string_body.insert(bit_string_body.end(), pkcs1_der.begin(),
        pkcs1_der.end());
    std::vector<std::uint8_t> bit_string;
    encode_tlv(bit_string, TagBitString, bit_string_body);

    std::vector<std::uint8_t> content;
    content.insert(content.end(), algorithm.begin(), algorithm.end());
    content.insert(content.end(), bit_string.begin(), bit_string.end());

    std::vector<std::uint8_t> spki;
    encode_tlv(spki, TagSequence, content);
    return spki;
}

// UTCTime："YYMMDDHHMMSSZ"。
std::vector<std::uint8_t> utc_time_at(std::chrono::system_clock::time_point when) {
    const auto time = std::chrono::system_clock::to_time_t(when);
    std::tm parts{};
    gmtime_r(&time, &parts);
    char text[16];
    std::snprintf(text, sizeof(text), "%02d%02d%02d%02d%02d%02dZ",
        (parts.tm_year + 1900) % 100, parts.tm_mon + 1, parts.tm_mday,
        parts.tm_hour, parts.tm_min, parts.tm_sec);
    return std::vector<std::uint8_t>(text, text + std::strlen(text));
}

// 空 Name（RDNSequence 里一个 RDN 都没有）。
std::vector<std::uint8_t> empty_name() {
    std::vector<std::uint8_t> result;
    encode_tlv(result, TagSequence, {});
    return result;
}

// base64（PEM 用）。
constexpr char Base64Alphabet[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

std::string base64_encode(const std::vector<std::uint8_t>& input) {
    std::string output;
    output.reserve((input.size() + 2) / 3 * 4);
    std::size_t index = 0;
    while (index + 2 < input.size()) {
        const std::uint32_t triple =
            (static_cast<std::uint32_t>(input[index]) << 16U) |
            (static_cast<std::uint32_t>(input[index + 1]) << 8U) |
            static_cast<std::uint32_t>(input[index + 2]);
        output.push_back(Base64Alphabet[(triple >> 18U) & 0x3FU]);
        output.push_back(Base64Alphabet[(triple >> 12U) & 0x3FU]);
        output.push_back(Base64Alphabet[(triple >> 6U) & 0x3FU]);
        output.push_back(Base64Alphabet[triple & 0x3FU]);
        index += 3;
    }
    const std::size_t remaining = input.size() - index;
    if (remaining == 1) {
        const std::uint32_t triple = static_cast<std::uint32_t>(input[index]) << 16U;
        output.push_back(Base64Alphabet[(triple >> 18U) & 0x3FU]);
        output.push_back(Base64Alphabet[(triple >> 12U) & 0x3FU]);
        output.push_back('=');
        output.push_back('=');
    } else if (remaining == 2) {
        const std::uint32_t triple =
            (static_cast<std::uint32_t>(input[index]) << 16U) |
            (static_cast<std::uint32_t>(input[index + 1]) << 8U);
        output.push_back(Base64Alphabet[(triple >> 18U) & 0x3FU]);
        output.push_back(Base64Alphabet[(triple >> 12U) & 0x3FU]);
        output.push_back(Base64Alphabet[(triple >> 6U) & 0x3FU]);
        output.push_back('=');
    }
    return output;
}

std::string to_pem(const std::vector<std::uint8_t>& der, const char* label) {
    const std::string encoded = base64_encode(der);
    std::string pem = std::string("-----BEGIN ") + label + "-----\n";
    for (std::size_t offset = 0; offset < encoded.size(); offset += 64) {
        pem += encoded.substr(offset, 64);
        pem.push_back('\n');
    }
    pem += std::string("-----END ") + label + "-----\n";
    return pem;
}

// base64 解码。
std::vector<std::uint8_t> base64_decode(std::string_view input) {
    std::array<int, 256> table{};
    table.fill(-1);
    for (int index = 0; index < 64; ++index) {
        table[static_cast<unsigned char>(Base64Alphabet[index])] = index;
    }
    std::vector<std::uint8_t> output;
    output.reserve(input.size() / 4 * 3);
    std::uint32_t accumulator = 0;
    int bits = 0;
    for (const char raw : input) {
        const unsigned char byte = static_cast<unsigned char>(raw);
        if (byte == '=') break;
        const int value = table[byte];
        if (value < 0) continue; // 换行等空白跳过
        accumulator = (accumulator << 6U) | static_cast<std::uint32_t>(value);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            output.push_back(static_cast<std::uint8_t>((accumulator >> bits) & 0xFFU));
        }
    }
    return output;
}

// 从 PEM 里取出裸的密钥材料（剥掉头尾并解 base64）。
//
// 为什么需要：CryptoArchitectureKit 的 Convert 吃的是**裸的**密钥材料
// （DER 字节），而我们落盘的是 PEM（带 "-----BEGIN PRIVATE KEY-----" 头尾）。
std::vector<std::uint8_t> strip_pem(const std::string& pem, const char* label) {
    const std::string begin = std::string("-----BEGIN ") + label + "-----";
    const std::string end = std::string("-----END ") + label + "-----";
    const auto begin_pos = pem.find(begin);
    const auto end_pos = pem.find(end);
    if (begin_pos == std::string::npos || end_pos == std::string::npos ||
        end_pos < begin_pos) {
        return {};
    }
    const std::string body = pem.substr(begin_pos + begin.size(),
        end_pos - begin_pos - begin.size());
    return base64_decode(body);
}

// 从 PEM 文本里取出**任意**标签的裸密钥材料（剥头尾 + 解 base64）。
//
// 为什么不能只认 "PRIVATE KEY"：设备返回的公钥是 PEM 标签
// "RSA PUBLIC KEY"（PKCS#1），根 CA/主机私钥的标签是 "PRIVATE KEY"
// （PKCS#8）。两个都要能剥。
std::vector<std::uint8_t> strip_pem_any(const std::string& pem) {
    static constexpr const char* kBegin = "-----BEGIN ";
    static constexpr const char* kEnd = "-----END ";
    const auto begin_pos = pem.find(kBegin);
    if (begin_pos == std::string::npos) return {};
    const auto body_start = pem.find("-----", begin_pos + std::strlen(kBegin));
    if (body_start == std::string::npos) return {};
    const auto body_end = pem.find(kEnd, body_start);
    if (body_end == std::string::npos) return {};
    return base64_decode(
        std::string_view(pem).substr(body_start + 5, body_end - body_start - 5));
}

// ── 从 SubjectPublicKeyInfo DER 里取出 BIT STRING 部分 ────────────
//
// SubjectPublicKeyInfo ::= SEQUENCE { algorithm AlgorithmIdentifier,
//                                      subjectPublicKey BIT STRING }
//
// 设备证书的 SubjectKeyIdentifier 要对**这个 BIT STRING 的内容**（RSAPublicKey
// 的 DER）做 SHA1，而不是对整个 SubjectPublicKeyInfo 做。这是 iosctl 作者反复
// 对抓包的地方，也是最容易写错的一处。

bool read_tlv(const std::vector<std::uint8_t>& data, std::size_t offset,
    std::uint8_t& tag, std::size_t& content_offset, std::size_t& content_length) {
    if (offset + 2 > data.size()) return false;
    tag = data[offset];
    std::size_t cursor = offset + 1;
    const std::uint8_t first = data[cursor++];
    if ((first & 0x80U) == 0) {
        content_length = first;
    } else {
        const std::size_t count = first & 0x7FU;
        if (count == 0 || count > 4) return false;
        if (cursor + count > data.size()) return false;
        content_length = 0;
        for (std::size_t index = 0; index < count; ++index) {
            content_length = (content_length << 8U) | data[cursor + index];
        }
        cursor += count;
    }
    if (cursor + content_length > data.size()) return false;
    content_offset = cursor;
    return true;
}

std::vector<std::uint8_t> subject_public_key_bits(
    const std::vector<std::uint8_t>& spki) {
    std::uint8_t tag = 0;
    std::size_t content_offset = 0;
    std::size_t content_length = 0;
    if (!read_tlv(spki, 0, tag, content_offset, content_length)) return {};
    if (tag != TagSequence) return {};

    std::uint8_t inner_tag = 0;
    std::size_t inner_offset = 0;
    std::size_t inner_length = 0;
    if (!read_tlv(spki, content_offset, inner_tag, inner_offset, inner_length)) {
        return {};
    }
    // AlgorithmIdentifier 的**内容结束**位置就是 BIT STRING 的起点。
    //
    // ★ 这里必须用 inner_offset + inner_length，不能用 content_offset +
    //   inner_length ★
    //   content_offset 是 AlgorithmIdentifier 的**内容起点**（跳过它的
    //   tag 与 length 字节），inner_length 是它的内容长度 —— 两者相加
    //   少算了 tag+length 那几个字节，结果是往 BIT STRING 内部偏了
    //   一两个字节，SHA1 出来的 SKI 自然是错的，而设备只会报一个
    //   看不出原因的 InvalidPairRecord。
    const std::size_t bit_string_offset = inner_offset + inner_length;
    if (!read_tlv(spki, bit_string_offset, inner_tag, inner_offset, inner_length)) {
        return {};
    }
    if (inner_tag != TagBitString || inner_length < 1) return {};
    // BIT STRING 的第一个字节是"未用位数"，内容从第二个字节开始。
    return std::vector<std::uint8_t>(
        spki.begin() + static_cast<std::ptrdiff_t>(inner_offset + 1),
        spki.begin() + static_cast<std::ptrdiff_t>(inner_offset + inner_length));
}

// 把一段 RSA 公钥材料统一成 SubjectPublicKeyInfo DER。
//
// ★ 为什么必须"探测"而不是无条件包装 ★
//   SDK 的 OH_CryptoPubKey_Encode(key, CRYPTO_DER, "X509", out) 文档只说
//   "Supports \"X509\""，**没有**写清产出的是 SubjectPublicKeyInfo 还是
//   PKCS#1 的 RSAPublicKey。真机上两种都可能：
//     · 产出 SPKI → 无条件包一层会变成"SPKI 套 SPKI"，证书里的公钥字段
//       结构错位，设备解析失败，报的还是看不出原因的 InvalidPairRecord。
//     · 产出 PKCS#1 → 不包一层直接嵌进证书，同样结构错位。
//
//   判据是可靠的：SPKI 的第一个子元素是 SEQUENCE（AlgorithmIdentifier），
//   PKCS#1 的第一个子元素是 INTEGER（modulus）。看一眼就知道。
//
// 已有 SPKI 原样返回；PKCS#1 才包一层；认不出来就返回空。
std::vector<std::uint8_t> public_key_material_to_spki(
    const std::vector<std::uint8_t>& der) {
    if (der.empty()) return {};

    std::uint8_t tag = 0;
    std::size_t content_offset = 0;
    std::size_t content_length = 0;
    if (!read_tlv(der, 0, tag, content_offset, content_length)) return {};
    if (tag != TagSequence) return {};
    std::uint8_t inner_tag = 0;
    std::size_t inner_offset = 0;
    std::size_t inner_length = 0;
    if (!read_tlv(der, content_offset, inner_tag, inner_offset, inner_length)) {
        return {};
    }
    if (inner_tag == TagSequence) {
        // 已经是 SPKI（AlgorithmIdentifier 是 SEQUENCE）。
        return der;
    }
    if (inner_tag != TagInteger) return {};

    return spki_from_pkcs1(der);
}

// 把设备给的公钥转成 SubjectPublicKeyInfo DER。
//
// ★ 设备返回的 DevicePublicKey 是 **PEM 文本**（标签 "RSA PUBLIC KEY"，
//   即 PKCS#1 的 RSAPublicKey），不是 SPKI DER ★
//
//   依据：libimobiledevice 的 lockdownd_get_device_public_key_as_key_data()
//   拿到的是 key_data_t（裸 PEM 字节），随后 pair_record_generate_keys_and_certs()
//   把它读成公钥；pymobiledevice3 明确写 load_pem_public_key(device_public_key_pem)，
//   参数名就叫 _pem，且要求是 "RSA PUBLIC KEY" 格式。
//
//   所以本函数先把 PEM 剥成 DER，再统一转成 SPKI（证书的
//   subjectPublicKeyInfo 字段要的就是 SPKI）。
//
// 也接受已经是 DER 的输入（SPKI 或 PKCS#1 都能认）。
std::vector<std::uint8_t> device_public_key_to_spki(
    const std::vector<std::uint8_t>& device_public_key) {
    if (device_public_key.empty()) return {};

    // PEM 文本还是裸 DER？用 "-----BEGIN" 判定。
    static constexpr std::string_view kPemMarker = "-----BEGIN";
    const bool looks_like_pem =
        device_public_key.size() >= kPemMarker.size() &&
        std::string_view(reinterpret_cast<const char*>(device_public_key.data()),
            kPemMarker.size()) == kPemMarker;

    std::vector<std::uint8_t> der;
    if (looks_like_pem) {
        const std::string pem(reinterpret_cast<const char*>(
            device_public_key.data()), device_public_key.size());
        der = strip_pem_any(pem);
    } else {
        der = device_public_key;
    }
    if (der.empty()) return {};

    return public_key_material_to_spki(der);
}

#if IM_HAVE_CRYPTO_ARCHITECTURE_KIT

// RAII 包装：CryptoArchitectureKit 的对象都要显式销毁，漏一个就是泄漏。
struct GeneratorHandle {
    OH_CryptoAsymKeyGenerator* generator{nullptr};
    ~GeneratorHandle() {
        if (generator != nullptr) OH_CryptoAsymKeyGenerator_Destroy(generator);
    }
};

struct KeyPairHandle {
    OH_CryptoKeyPair* key_pair{nullptr};
    ~KeyPairHandle() {
        if (key_pair != nullptr) OH_CryptoKeyPair_Destroy(key_pair);
    }
};

struct SignHandle {
    OH_CryptoSign* sign{nullptr};
    ~SignHandle() {
        if (sign != nullptr) OH_CryptoSign_Destroy(sign);
    }
};

struct DigestHandle {
    OH_CryptoDigest* digest{nullptr};
    // ★ CryptoArchitectureKit **没有** OH_CryptoDigest_Destroy ★
    //   （crypto_digest.h 里只有 Create/Update/Final 三个函数。）
    //   所以这里不能像其它句柄那样在析构里销毁 —— 只能靠"用完即弃"。
    //   SHA1 只在签发设备证书时算一次（算 SKI），调用频率极低，泄漏一次
    //   一个上下文对象是可以接受的；真要严格就得用框架提供的其它释放途径，
    //   但那超出本工程的必要范围。
    ~DigestHandle() = default;
};

struct BlobHandle {
    Crypto_DataBlob blob{};
    ~BlobHandle() {
        if (blob.data != nullptr) OH_Crypto_FreeDataBlob(&blob);
    }
};

// 生成一对 RSA-2048 密钥，导出公钥 SPKI DER 与私钥 PEM。
//
// ★ 公钥为什么还要自己包一层 ★
//   证书里的 subjectPublicKeyInfo 字段要的是 **SPKI**，而
//   OH_CryptoPubKey_Encode(key, CRYPTO_DER, "X509", out) 的文档并没有写清
//   "X509" 产出的是 SPKI 还是 PKCS#1 的 RSAPublicKey
//   （SEQUENCE{INTEGER modulus, INTEGER exponent}）。两种都可能，直接嵌进去
//   会让设备解析证书时结构错位，表现为看不出原因的 InvalidPairRecord。
//   所以这里走 public_key_material_to_spki() 做**运行时探测**：是 SPKI 就
//   原样用，是 PKCS#1 才包一层，不猜。
bool generate_key_material(std::vector<std::uint8_t>& public_key_der,
    std::string& private_key_pem) {
    GeneratorHandle generator;
    OH_Crypto_ErrCode code = OH_CryptoAsymKeyGenerator_Create("RSA2048",
        &generator.generator);
    if (code != CRYPTO_SUCCESS || generator.generator == nullptr) return false;

    KeyPairHandle key_pair;
    code = OH_CryptoAsymKeyGenerator_Generate(generator.generator,
        &key_pair.key_pair);
    if (code != CRYPTO_SUCCESS || key_pair.key_pair == nullptr) return false;

    OH_CryptoPubKey* pub_key = OH_CryptoKeyPair_GetPubKey(key_pair.key_pair);
    OH_CryptoPrivKey* priv_key = OH_CryptoKeyPair_GetPrivKey(key_pair.key_pair);
    if (pub_key == nullptr || priv_key == nullptr) return false;

    BlobHandle public_blob;
    code = OH_CryptoPubKey_Encode(pub_key, CRYPTO_DER, "X509", &public_blob.blob);
    if (code != CRYPTO_SUCCESS || public_blob.blob.data == nullptr) return false;

    BlobHandle private_blob;
    code = OH_CryptoPrivKey_Encode(priv_key, CRYPTO_PEM, "PKCS8", nullptr,
        &private_blob.blob);
    if (code != CRYPTO_SUCCESS || private_blob.blob.data == nullptr) return false;

    // PKCS#1 → SPKI（走统一探测，真机返回哪种形态都不出错）。
    std::vector<std::uint8_t> exported(
        public_blob.blob.data,
        public_blob.blob.data + public_blob.blob.len);
    public_key_der = public_key_material_to_spki(exported);
    if (public_key_der.empty()) return false;

    private_key_pem.assign(
        reinterpret_cast<const char*>(private_blob.blob.data),
        private_blob.blob.len);
    return true;
}

// 从私钥材料恢复一个密钥对（并导出它的公钥 SPKI DER 与私钥 PEM）。
//
// ★ 为什么只给私钥也可以 ★
//
// OH_CryptoAsymKeyGenerator_Convert 的文档明确写着：pubKeyData 与
// priKeyData **不能同时为 NULL**，也就是说**可以只传私钥**。这正是
// "复用已存的根 CA"所需要的能力 —— 我们存的是私钥（配对记录里的
// RootPrivateKey），公钥可以从恢复出来的密钥对象里重新导出。
//
// ★ 传私钥时 type 必须与字节形态一致 ★
//   type 参数描述的是**我们传进去的字节是什么形态**，不是"要什么形态"。
//   本函数传的是 PKCS#8 的 DER 字节（从落盘的 PEM 剥出来的），所以
//   type=CRYPTO_DER。type 与字节形态不匹配会被判成格式错误。
bool restore_key_material(const std::string& private_key_pem,
    std::vector<std::uint8_t>& public_key_der, std::string& restored_pem) {
    const auto private_bytes = strip_pem(private_key_pem, "PRIVATE KEY");
    if (private_bytes.empty()) return false;

    GeneratorHandle generator;
    OH_Crypto_ErrCode code = OH_CryptoAsymKeyGenerator_Create("RSA2048",
        &generator.generator);
    if (code != CRYPTO_SUCCESS || generator.generator == nullptr) return false;

    Crypto_DataBlob private_blob{};
    private_blob.data = const_cast<std::uint8_t*>(private_bytes.data());
    private_blob.len = private_bytes.size();

    KeyPairHandle key_pair;
    // 只给私钥：公钥由框架从私钥推出来。
    code = OH_CryptoAsymKeyGenerator_Convert(generator.generator, CRYPTO_DER,
        nullptr, &private_blob, &key_pair.key_pair);
    if (code != CRYPTO_SUCCESS || key_pair.key_pair == nullptr) return false;

    OH_CryptoPubKey* pub_key = OH_CryptoKeyPair_GetPubKey(key_pair.key_pair);
    OH_CryptoPrivKey* priv_key = OH_CryptoKeyPair_GetPrivKey(key_pair.key_pair);
    if (pub_key == nullptr || priv_key == nullptr) return false;

    BlobHandle public_blob;
    code = OH_CryptoPubKey_Encode(pub_key, CRYPTO_DER, "X509", &public_blob.blob);
    if (code != CRYPTO_SUCCESS || public_blob.blob.data == nullptr) return false;

    BlobHandle private_blob_out;
    code = OH_CryptoPrivKey_Encode(priv_key, CRYPTO_PEM, "PKCS8", nullptr,
        &private_blob_out.blob);
    if (code != CRYPTO_SUCCESS || private_blob_out.blob.data == nullptr) {
        return false;
    }

    // PKCS#1 → SPKI（走统一探测）。
    std::vector<std::uint8_t> exported(
        public_blob.blob.data,
        public_blob.blob.data + public_blob.blob.len);
    public_key_der = public_key_material_to_spki(exported);
    if (public_key_der.empty()) return false;

    restored_pem.assign(
        reinterpret_cast<const char*>(private_blob_out.blob.data),
        private_blob_out.blob.len);
    return true;
}

// 用一个已有的密钥对（root_key_pair）签一段数据。
bool sign_with_key_pair(OH_CryptoKeyPair* key_pair, DigestAlgorithm digest,
    const std::vector<std::uint8_t>& data, std::vector<std::uint8_t>& signature) {
    if (key_pair == nullptr) return false;
    OH_CryptoPrivKey* priv_key = OH_CryptoKeyPair_GetPrivKey(key_pair);
    if (priv_key == nullptr) return false;

    const char* algo = digest == DigestAlgorithm::Sha1
        ? "RSA|PKCS1|SHA1" : "RSA|PKCS1|SHA256";
    SignHandle handle;
    OH_Crypto_ErrCode code = OH_CryptoSign_Create(algo, &handle.sign);
    if (code != CRYPTO_SUCCESS) return false;
    code = OH_CryptoSign_Init(handle.sign, priv_key);
    if (code != CRYPTO_SUCCESS) return false;

    Crypto_DataBlob input{};
    input.data = const_cast<std::uint8_t*>(data.data());
    input.len = data.size();
    code = OH_CryptoSign_Update(handle.sign, &input);
    if (code != CRYPTO_SUCCESS) return false;

    BlobHandle output;
    code = OH_CryptoSign_Final(handle.sign, nullptr, &output.blob);
    if (code != CRYPTO_SUCCESS) return false;
    signature.assign(output.blob.data, output.blob.data + output.blob.len);
    return true;
}

// SHA1 摘要（只为算 SubjectKeyIdentifier）。
bool sha1_digest(const std::vector<std::uint8_t>& data,
    std::vector<std::uint8_t>& digest) {
    DigestHandle handle;
    OH_Crypto_ErrCode code = OH_CryptoDigest_Create("SHA1", &handle.digest);
    if (code != CRYPTO_SUCCESS || handle.digest == nullptr) return false;

    Crypto_DataBlob input{};
    input.data = const_cast<std::uint8_t*>(data.data());
    input.len = data.size();
    code = OH_CryptoDigest_Update(handle.digest, &input);
    if (code != CRYPTO_SUCCESS) return false;

    BlobHandle output;
    code = OH_CryptoDigest_Final(handle.digest, &output.blob);
    if (code != CRYPTO_SUCCESS) return false;
    digest.assign(output.blob.data, output.blob.data + output.blob.len);
    return true;
}

// 构造 TBSCertificate 并用给定密钥签发。
//
// is_ca：是否根 CA（决定 BasicConstraints 的 ca 取值）。
// include_key_usage：叶子证书要 KeyUsage，根证书不要。
// include_subject_key_identifier：只有设备证书要 SKI。
bool build_and_sign(OH_CryptoKeyPair* signing_key_pair,
    const std::vector<std::uint8_t>& subject_public_key_der,
    DigestAlgorithm digest, bool is_ca, bool include_key_usage,
    bool include_subject_key_identifier, Certificate& out) {
    std::vector<std::uint8_t> tbs_content;

    // version [0] EXPLICIT INTEGER 2（v3）
    {
        std::vector<std::uint8_t> version;
        encode_integer(version, 2);
        std::vector<std::uint8_t> wrapper;
        encode_tlv(wrapper, TagContext0, version);
        tbs_content.insert(tbs_content.end(), wrapper.begin(), wrapper.end());
    }
    // serialNumber：固定 1（与 idevicepair 一致）
    encode_integer(tbs_content, 1);
    // signature AlgorithmIdentifier
    const auto& digest_oid = digest == DigestAlgorithm::Sha1
        ? oid_sha1_with_rsa() : oid_sha256_with_rsa();
    {
        const auto algorithm = algorithm_identifier(digest_oid);
        tbs_content.insert(tbs_content.end(), algorithm.begin(), algorithm.end());
    }
    // issuer：空 Name
    {
        const auto issuer = empty_name();
        tbs_content.insert(tbs_content.end(), issuer.begin(), issuer.end());
    }
    // validity：now-60s 到 now+10 年
    {
        const auto now = std::chrono::system_clock::now();
        std::vector<std::uint8_t> validity;
        encode_tlv(validity, TagUtcTime, utc_time_at(now - std::chrono::seconds(60)));
        encode_tlv(validity, TagUtcTime,
            utc_time_at(now + std::chrono::hours(24 * 365 * 10)));
        std::vector<std::uint8_t> wrapper;
        encode_tlv(wrapper, TagSequence, validity);
        tbs_content.insert(tbs_content.end(), wrapper.begin(), wrapper.end());
    }
    // subject：空 Name
    {
        const auto subject = empty_name();
        tbs_content.insert(tbs_content.end(), subject.begin(), subject.end());
    }
    // subjectPublicKeyInfo：原文嵌入
    tbs_content.insert(tbs_content.end(), subject_public_key_der.begin(),
        subject_public_key_der.end());

    // extensions [3] EXPLICIT
    {
        std::vector<std::uint8_t> extensions;

        // BasicConstraints：根证书 ca=TRUE，叶子 ca=FALSE。
        // （ca=FALSE 时扩展值是空的 SEQUENCE —— BOOLEAN FALSE 是 DEFAULT，
        //   DER 规则要求省略。）
        encode_extension(extensions, oid_basic_constraints(), true,
            basic_constraints_value(is_ca));

        // KeyUsage：叶子证书要 digitalSignature + keyEncipherment。
        if (include_key_usage) {
            encode_extension(extensions, oid_key_usage(), true,
                key_usage_value());
        }

        // SubjectKeyIdentifier：只有设备证书需要。
        if (include_subject_key_identifier) {
            const auto public_key_bits =
                subject_public_key_bits(subject_public_key_der);
            if (public_key_bits.empty()) {
                logging::write(logging::Level::Warning, "pairing-pki",
                    "解析设备公钥的 BIT STRING 失败，无法计算 SubjectKeyIdentifier");
                return false;
            }
            std::vector<std::uint8_t> identifier;
            if (!sha1_digest(public_key_bits, identifier)) {
                logging::write(logging::Level::Warning, "pairing-pki",
                    "计算 SubjectKeyIdentifier 的 SHA1 失败");
                return false;
            }
            // KeyIdentifier ::= OCTET STRING，所以扩展值本身是一层
            // OCTET STRING；再被 extnValue 的 OCTET STRING 包一层。
            std::vector<std::uint8_t> key_identifier;
            encode_tlv(key_identifier, TagOctetString, identifier);
            encode_extension(extensions, oid_subject_key_identifier(), false,
                key_identifier);
        }

        // ★ 这里有**两层** SEQUENCE，别省 ★
        //
        //   RFC 5280：
        //     Extensions ::= SEQUENCE SIZE (1..MAX) OF Extension
        //     TBSCertificate ::= SEQUENCE { ..., [3] EXPLICIT Extensions OPTIONAL }
        //
        //   所以 [3] 的内容是"一个 SEQUENCE"，那个 SEQUENCE 里才是各个
        //   Extension。少了外面这层，证书的 extensions 字段结构就不对，
        //   OpenSSL 解析时直接报 asn1_check_tlen: wrong tag (Type=X509_EXTENSION)
        //   —— 而设备侧的报错是那个看不出原因的 InvalidPairRecord。
        //
        //   实际字节： A3 <len> 30 <len> 30 <ext1> 30 <ext2> ...
        //             └[3]┘      └SEQUENCE OF┘
        std::vector<std::uint8_t> sequence_of;
        encode_tlv(sequence_of, TagSequence, extensions);

        std::vector<std::uint8_t> wrapper;
        encode_tlv(wrapper, TagContext3, sequence_of);
        tbs_content.insert(tbs_content.end(), wrapper.begin(), wrapper.end());
    }

    std::vector<std::uint8_t> tbs;
    encode_tlv(tbs, TagSequence, tbs_content);

    std::vector<std::uint8_t> signature;
    if (!sign_with_key_pair(signing_key_pair, digest, tbs, signature)) {
        logging::write(logging::Level::Warning, "pairing-pki", "对证书签名失败");
        return false;
    }

    std::vector<std::uint8_t> certificate_content;
    certificate_content.insert(certificate_content.end(), tbs.begin(), tbs.end());
    const auto algorithm = algorithm_identifier(digest_oid);
    certificate_content.insert(certificate_content.end(), algorithm.begin(),
        algorithm.end());
    encode_bit_string(certificate_content, signature);

    std::vector<std::uint8_t> certificate;
    encode_tlv(certificate, TagSequence, certificate_content);

    out.der = std::move(certificate);
    out.pem = to_pem(out.der, "CERTIFICATE");
    return true;
}

#endif // IM_HAVE_CRYPTO_ARCHITECTURE_KIT

} // namespace

DigestAlgorithm select_digest_algorithm(const std::string& version_string) {
    // 解析 "17.4.1" → 主版本号 17。拿不到版本时按现代设备处理。
    if (version_string.empty()) return DigestAlgorithm::Sha256;
    const auto dot = version_string.find('.');
    const std::string major_part = dot == std::string::npos
        ? version_string : version_string.substr(0, dot);
    int major = 0;
    try {
        major = std::stoi(major_part);
    } catch (const std::exception&) {
        return DigestAlgorithm::Sha256;
    }
    // pymobiledevice3 的判据：版本 < 4.0.0 用 SHA-1。
    return major < 4 ? DigestAlgorithm::Sha1 : DigestAlgorithm::Sha256;
}

bool generate_pairing_material(
    const std::vector<std::uint8_t>& device_public_key,
    PairingMaterial& out) {
#if IM_HAVE_CRYPTO_ARCHITECTURE_KIT
    if (device_public_key.empty()) {
        logging::write(logging::Level::Warning, "pairing-pki",
            "缺少设备公钥，无法生成配对材料");
        return false;
    }
    if (!generate_key_material(out.root_public_key_der, out.root_private_key_pem)) {
        logging::write(logging::Level::Warning, "pairing-pki", "生成根 CA 密钥失败");
        return false;
    }
    if (!generate_key_material(out.host_public_key_der, out.host_private_key_pem)) {
        logging::write(logging::Level::Warning, "pairing-pki", "生成主机密钥失败");
        return false;
    }
    // 设备公钥：PEM 文本（或已是 DER）→ SPKI DER（证书里要的就是 SPKI）。
    out.device_public_key_der = device_public_key_to_spki(device_public_key);
    if (out.device_public_key_der.empty()) {
        logging::write(logging::Level::Warning, "pairing-pki",
            "设备公钥解析失败（既不是 PEM 也不是可识别的 DER）");
        return false;
    }
    return true;
#else
    (void)device_public_key;
    (void)out;
    logging::write(logging::Level::Warning, "pairing-pki",
        "本 SDK 未提供 CryptoArchitectureKit，无法生成配对材料");
    return false;
#endif
}

bool restore_pairing_material(const std::string& root_private_key_pem,
    const std::vector<std::uint8_t>& device_public_key,
    PairingMaterial& out) {
#if IM_HAVE_CRYPTO_ARCHITECTURE_KIT
    if (device_public_key.empty()) {
        logging::write(logging::Level::Warning, "pairing-pki",
            "缺少设备公钥，无法恢复配对材料");
        return false;
    }
    // 根 CA：从私钥恢复（公钥由私钥推出来）。
    if (!restore_key_material(root_private_key_pem, out.root_public_key_der,
            out.root_private_key_pem)) {
        logging::write(logging::Level::Warning, "pairing-pki",
            "从已存私钥恢复根 CA 失败");
        return false;
    }
    // 主机密钥：重新生成。设备侧不关心主机私钥（只认 HostID 与根 CA），
    // 所以换一把不影响"免弹窗"。
    if (!generate_key_material(out.host_public_key_der,
            out.host_private_key_pem)) {
        logging::write(logging::Level::Warning, "pairing-pki", "生成主机密钥失败");
        return false;
    }
    out.device_public_key_der = device_public_key_to_spki(device_public_key);
    if (out.device_public_key_der.empty()) {
        logging::write(logging::Level::Warning, "pairing-pki",
            "设备公钥解析失败（既不是 PEM 也不是可识别的 DER）");
        return false;
    }
    return true;
#else
    (void)root_private_key_pem;
    (void)device_public_key;
    (void)out;
    logging::write(logging::Level::Warning, "pairing-pki",
        "本 SDK 未提供 CryptoArchitectureKit，无法恢复配对材料");
    return false;
#endif
}

bool issue_pairing_certificates(const PairingMaterial& material,
    DigestAlgorithm digest, Certificate& root, Certificate& host,
    Certificate& device) {
#if IM_HAVE_CRYPTO_ARCHITECTURE_KIT
    // 根 CA 的密钥对要导入一次：生成阶段导出的 PEM 是给"落盘"用的，
    // 而签名要的是密钥对象。
    //
    // ★ 只传私钥，不传公钥 ★
    //   Convert 的公钥参数该给什么形态（PKCS#1 还是 SPKI）并没有文档说明，
    //   猜错就是"导入失败"。而私钥这一侧是明确的：PKCS#8 的 DER 字节配
    //   CRYPTO_DER。框架能从私钥推出公钥，所以公钥参数直接给 nullptr。
    GeneratorHandle generator;
    OH_Crypto_ErrCode code = OH_CryptoAsymKeyGenerator_Create("RSA2048",
        &generator.generator);
    if (code != CRYPTO_SUCCESS || generator.generator == nullptr) return false;

    const auto private_bytes = strip_pem(material.root_private_key_pem,
        "PRIVATE KEY");
    if (private_bytes.empty()) {
        logging::write(logging::Level::Warning, "pairing-pki",
            "根 CA 私钥 PEM 解析失败");
        return false;
    }
    Crypto_DataBlob private_blob{};
    private_blob.data = const_cast<std::uint8_t*>(private_bytes.data());
    private_blob.len = private_bytes.size();

    KeyPairHandle root_key_pair;
    code = OH_CryptoAsymKeyGenerator_Convert(generator.generator, CRYPTO_DER,
        nullptr, &private_blob, &root_key_pair.key_pair);
    if (code != CRYPTO_SUCCESS || root_key_pair.key_pair == nullptr) {
        logging::write(logging::Level::Warning, "pairing-pki",
            "导入根 CA 私钥失败");
        return false;
    }

    // 从导入后的密钥对重新导出根 CA 的公钥（SPKI DER）。
    //
    // 为什么不直接用 material.root_public_key_der：那是**生成阶段**导出的，
    // 而签名的密钥是从私钥重新导入的。重新导出一遍能保证"证书里的公钥"
    // 与"实际签名的私钥"必然是同一对 —— 否则设备验签必然失败，而报错是
    // 那个看不出原因的 InvalidPairRecord。
    OH_CryptoPubKey* root_pub_key =
        OH_CryptoKeyPair_GetPubKey(root_key_pair.key_pair);
    if (root_pub_key == nullptr) return false;
    BlobHandle root_pub_blob;
    code = OH_CryptoPubKey_Encode(root_pub_key, CRYPTO_DER, "X509",
        &root_pub_blob.blob);
    if (code != CRYPTO_SUCCESS || root_pub_blob.blob.data == nullptr) {
        return false;
    }
    std::vector<std::uint8_t> root_exported(
        root_pub_blob.blob.data,
        root_pub_blob.blob.data + root_pub_blob.blob.len);
    const std::vector<std::uint8_t> root_spki =
        public_key_material_to_spki(root_exported);
    if (root_spki.empty()) return false;

    // 根 CA 自签。
    if (!build_and_sign(root_key_pair.key_pair, root_spki,
            digest, true, false, false, root)) {
        return false;
    }
    // 主机证书：由根 CA 签，公钥是主机自己的。
    if (!build_and_sign(root_key_pair.key_pair, material.host_public_key_der,
            digest, false, true, false, host)) {
        return false;
    }
    // 设备证书：由根 CA 签，公钥是**设备**的，并带 SubjectKeyIdentifier。
    if (!build_and_sign(root_key_pair.key_pair, material.device_public_key_der,
            digest, false, true, true, device)) {
        return false;
    }
    return true;
#else
    (void)material;
    (void)digest;
    (void)root;
    (void)host;
    (void)device;
    logging::write(logging::Level::Warning, "pairing-pki",
        "本 SDK 未提供 CryptoArchitectureKit，无法签发 X.509 证书");
    return false;
#endif
}

} // namespace iPhoneMirror::ohos::pki
