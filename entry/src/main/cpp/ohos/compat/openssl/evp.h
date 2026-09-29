// SPDX-License-Identifier: GPL-3.0-only
//
// OpenSSL EVP 垫片（仅提供上游用到的那几个函数）。
//
// 上游 Logging.cpp 在非 Windows 分支用 libcrypto 的 EVP 接口做 SHA-256，用途只有
// 一处：把设备序列号在日志里匿名化（每进程随机 salt + SHA-256，见 Logging.h 的
// fingerprint 注释）。OHOS NDK 不暴露 OpenSSL，而本工程不改上游文件，所以这里
// 用一份自带的 SHA-256 实现顶上，接口签名与 OpenSSL 一致：
//
//   EVP_MD_CTX* EVP_MD_CTX_new();
//   void        EVP_MD_CTX_free(EVP_MD_CTX*);
//   const EVP_MD* EVP_sha256();
//   int EVP_DigestInit_ex(EVP_MD_CTX*, const EVP_MD*, ENGINE*);
//   int EVP_DigestUpdate(EVP_MD_CTX*, const void*, size_t);
//   int EVP_DigestFinal_ex(EVP_MD_CTX*, unsigned char*, unsigned int*);
//
// 行为与 OpenSSL 的 SHA-256 一致（NIST FIPS 180-4），所以匿名化标签的取值不变。

#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

#if defined(__has_include_next)
#  if __has_include_next(<openssl/evp.h>)
#    include_next <openssl/evp.h>
#    define IM_OHOS_HAVE_REAL_OPENSSL 1
#  endif
#endif

#ifndef IM_OHOS_HAVE_REAL_OPENSSL

// OpenSSL 的 ENGINE 在只做摘要时永远是 nullptr；声明成不完整类型即可。
struct engine_st;
using ENGINE = engine_st;

struct evp_md_st;
using EVP_MD = evp_md_st;

namespace iPhoneMirror::ohos_compat {

class Sha256 {
public:
    void reset() {
        state_[0] = 0x6a09e667U;
        state_[1] = 0xbb67ae85U;
        state_[2] = 0x3c6ef372U;
        state_[3] = 0xa54ff53aU;
        state_[4] = 0x510e527fU;
        state_[5] = 0x9b05688cU;
        state_[6] = 0x1f83d9abU;
        state_[7] = 0x5be0cd19U;
        buffered_ = 0;
        bit_length_ = 0;
    }

    Sha256() { reset(); }

    void update(const std::uint8_t* data, std::size_t length) {
        bit_length_ += static_cast<std::uint64_t>(length) * 8U;
        for (std::size_t index = 0; index < length; ++index) {
            buffer_[buffered_++] = data[index];
            if (buffered_ == 64) {
                transform(buffer_);
                buffered_ = 0;
            }
        }
    }

    void finalize(std::uint8_t* digest) {
        const std::uint64_t total_bits = bit_length_;
        const std::uint8_t padding = 0x80;
        update(&padding, 1);
        const std::uint8_t zero = 0x00;
        while (buffered_ != 56) update(&zero, 1);

        std::uint8_t length_bytes[8];
        for (int index = 0; index < 8; ++index) {
            length_bytes[index] = static_cast<std::uint8_t>(
                (total_bits >> (56 - 8 * index)) & 0xffU);
        }
        bit_length_ -= 8U * 8U; // 长度域不属于被哈希的数据
        update(length_bytes, 8);
        bit_length_ += 8U * 8U;

        for (int word = 0; word < 8; ++word) {
            digest[4 * word + 0] = static_cast<std::uint8_t>(state_[word] >> 24);
            digest[4 * word + 1] = static_cast<std::uint8_t>(state_[word] >> 16);
            digest[4 * word + 2] = static_cast<std::uint8_t>(state_[word] >> 8);
            digest[4 * word + 3] = static_cast<std::uint8_t>(state_[word]);
        }
    }

private:
    static std::uint32_t rotate_right(std::uint32_t value, std::uint32_t bits) {
        return (value >> bits) | (value << (32U - bits));
    }

    void transform(const std::uint8_t* block) {
        static const std::uint32_t constants[64] = {
            0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U, 0x3956c25bU,
            0x59f111f1U, 0x923f82a4U, 0xab1c5ed5U, 0xd807aa98U, 0x12835b01U,
            0x243185beU, 0x550c7dc3U, 0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U,
            0xc19bf174U, 0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU,
            0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU, 0x983e5152U,
            0xa831c66dU, 0xb00327c8U, 0xbf597fc7U, 0xc6e00bf3U, 0xd5a79147U,
            0x06ca6351U, 0x14292967U, 0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU,
            0x53380d13U, 0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U,
            0xa2bfe8a1U, 0xa81a664bU, 0xc24b8b70U, 0xc76c51a3U, 0xd192e819U,
            0xd6990624U, 0xf40e3585U, 0x106aa070U, 0x19a4c116U, 0x1e376c08U,
            0x2748774cU, 0x34b0bcb5U, 0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU,
            0x682e6ff3U, 0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U,
            0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U};

        std::uint32_t schedule[64];
        for (int index = 0; index < 16; ++index) {
            schedule[index] = (static_cast<std::uint32_t>(block[4 * index]) << 24) |
                (static_cast<std::uint32_t>(block[4 * index + 1]) << 16) |
                (static_cast<std::uint32_t>(block[4 * index + 2]) << 8) |
                static_cast<std::uint32_t>(block[4 * index + 3]);
        }
        for (int index = 16; index < 64; ++index) {
            const std::uint32_t s0 = rotate_right(schedule[index - 15], 7) ^
                rotate_right(schedule[index - 15], 18) ^ (schedule[index - 15] >> 3);
            const std::uint32_t s1 = rotate_right(schedule[index - 2], 17) ^
                rotate_right(schedule[index - 2], 19) ^ (schedule[index - 2] >> 10);
            schedule[index] = schedule[index - 16] + s0 + schedule[index - 7] + s1;
        }

        std::uint32_t a = state_[0], b = state_[1], c = state_[2], d = state_[3];
        std::uint32_t e = state_[4], f = state_[5], g = state_[6], h = state_[7];
        for (int index = 0; index < 64; ++index) {
            const std::uint32_t s1 = rotate_right(e, 6) ^ rotate_right(e, 11) ^
                rotate_right(e, 25);
            const std::uint32_t choose = (e & f) ^ ((~e) & g);
            const std::uint32_t temp1 = h + s1 + choose + constants[index] +
                schedule[index];
            const std::uint32_t s0 = rotate_right(a, 2) ^ rotate_right(a, 13) ^
                rotate_right(a, 22);
            const std::uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
            const std::uint32_t temp2 = s0 + majority;
            h = g; g = f; f = e; e = d + temp1;
            d = c; c = b; b = a; a = temp1 + temp2;
        }

        state_[0] += a; state_[1] += b; state_[2] += c; state_[3] += d;
        state_[4] += e; state_[5] += f; state_[6] += g; state_[7] += h;
    }

    std::uint32_t state_[8]{};
    std::uint8_t buffer_[64]{};
    std::size_t buffered_{};
    std::uint64_t bit_length_{};
};

} // namespace iPhoneMirror::ohos_compat

struct evp_md_ctx_st {
    iPhoneMirror::ohos_compat::Sha256 hash;
};

using EVP_MD_CTX = evp_md_ctx_st;

inline EVP_MD_CTX* EVP_MD_CTX_new() { return new (std::nothrow) EVP_MD_CTX(); }
inline void EVP_MD_CTX_free(EVP_MD_CTX* context) { delete context; }

inline const EVP_MD* EVP_sha256() {
    static const int marker = 0;
    return reinterpret_cast<const EVP_MD*>(&marker);
}

inline int EVP_DigestInit_ex(EVP_MD_CTX* context, const EVP_MD*, ENGINE*) {
    if (context == nullptr) return 0;
    context->hash.reset();
    return 1;
}

inline int EVP_DigestUpdate(EVP_MD_CTX* context, const void* data, std::size_t length) {
    if (context == nullptr) return 0;
    if (length == 0) return 1;
    if (data == nullptr) return 0;
    context->hash.update(static_cast<const std::uint8_t*>(data), length);
    return 1;
}

inline int EVP_DigestFinal_ex(EVP_MD_CTX* context, unsigned char* digest,
    unsigned int* length) {
    if (context == nullptr || digest == nullptr) return 0;
    context->hash.finalize(reinterpret_cast<std::uint8_t*>(digest));
    if (length != nullptr) *length = 32U;
    return 1;
}

#endif // IM_OHOS_HAVE_REAL_OPENSSL
