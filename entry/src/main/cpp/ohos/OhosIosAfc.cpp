// SPDX-License-Identifier: GPL-3.0-only
//
// OhosIosAfc.h 的实现。协议参照 libimobiledevice 的 lockdownd.c / afc.c 与
// pymobiledevice3 的 usbmux/lockdown/afc 模块；本文件是这三个角色的合体：
//
//   · lockdown 客户端（StartSession / StartService）
//   · TLS 传输层（OpenSSL 内存 BIO 泵）
//   · AFC 客户端（帧封装 + 文件操作）
//
// 为什么不复用 OhosPairing.cpp 里的 lockdown_exchange()：那里的函数在匿名
// 命名空间里（编译单元私有），而 AFC 需要的是"会话中途切换 TLS"的变体 ——
// StartSession 前明文、之后全加密。两处各自 40 行，复制比硬拆更清晰。

#include "OhosIosAfc.h"

#include "OhosPairingStore.h"
#include "OhosUsbDiagnostics.h"
#include "OhosUsbMux.h"
#include "Protocol/Plist.h"

#include <openssl/bio.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <format>
#include <string>
#include <vector>

namespace iPhoneMirror::ohos {
namespace {

// AFC 帧头的 magic（"CFA6LPAA"，小端写入 = 原样字节）。
constexpr char AfcMagic[8] = {'C', 'F', 'A', '6', 'L', 'P', 'A', 'A'};
constexpr std::uint64_t AfcHeaderSize = 40;

// 操作码（libimobiledevice afc.h 的 afc_op_t）。
constexpr std::uint64_t AfcOpStatus = 1;
constexpr std::uint64_t AfcOpData = 2;
constexpr std::uint64_t AfcOpReadDir = 3;
constexpr std::uint64_t AfcOpRemovePath = 8;
constexpr std::uint64_t AfcOpMakeDir = 9;
constexpr std::uint64_t AfcOpGetFileInfo = 10;
constexpr std::uint64_t AfcOpGetDevInfo = 11;
constexpr std::uint64_t AfcOpFileOpen = 15;
constexpr std::uint64_t AfcOpFileOpenRes = 16;
constexpr std::uint64_t AfcOpFileRead = 17;
constexpr std::uint64_t AfcOpFileWrite = 18;
constexpr std::uint64_t AfcOpFileClose = 20;
constexpr std::uint64_t AfcOpRenamePath = 30;

// 打开模式（afc_file_mode_t）。RDONLY=1；WRONLY=2 是 O_WRONLY|O_CREAT|O_TRUNC
// （覆盖写，正是"上传文件"要的语义）。
constexpr std::uint64_t AfcFopenRdOnly = 1;
constexpr std::uint64_t AfcFopenWrOnly = 2;

// 错误码 → 中文（afc_error_t）。只列用户会遇到的高频项。
std::string afc_error_text(std::uint64_t code) {
    switch (code) {
    case 0: return "成功";
    case 1: return "设备内部错误";
    case 2: return "帧头无效";
    case 3: return "设备资源不足";
    case 4: return "设备读取失败";
    case 5: return "设备写入失败";
    case 8: return "路径不存在";
    case 9: return "目标是目录";
    case 10: return "权限不足";
    case 16: return "目标已存在";
    case 17: return "目标被占用";
    case 18: return "设备空间不足";
    default: return std::format("设备错误码 {}", code);
    }
}

// 读超时。AFC 的每一问一答都要在它之内完成；给足余量是因为手机在后台
// 会做别的 IO，偶尔一拍慢半拍。
constexpr int AfcReadTimeoutMs = 5000;

// TLS 握手允许的时间（换算成 mux.receive 的轮数）。
constexpr int TlsHandshakeTimeoutMs = 10000;

// 单块读写的上限。AFC 的 FILE_READ 一次请求最多给这么多；1 MiB 是
// libimobiledevice 用了很久的值（吞吐与内存占用的平衡点）。
constexpr std::size_t AfcChunkSize = 1024 * 1024;

// ── base64 解码（配对记录里的证书是 base64(PEM)）──────────────────
std::string base64_decode(const std::string& input) {
    auto value_of = [](char c) -> int {
        if (c >= 'A' && c <= 'Z') return c - 'A';
        if (c >= 'a' && c <= 'z') return c - 'a' + 26;
        if (c >= '0' && c <= '9') return c - '0' + 52;
        if (c == '+') return 62;
        if (c == '/') return 63;
        return -1;
    };
    std::string output;
    output.reserve(input.size() / 4 * 3);
    std::uint32_t accumulator = 0;
    int bits = 0;
    for (const char c : input) {
        if (c == '=' || c == '\n' || c == '\r' || c == ' ') break;
        const int value = value_of(c);
        if (value < 0) continue;
        accumulator = (accumulator << 6U) | static_cast<std::uint32_t>(value);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            output.push_back(static_cast<char>((accumulator >> bits) & 0xFFU));
        }
    }
    return output;
}

// 小端 u64 写入。
void put_u64le(std::vector<std::uint8_t>& out, std::uint64_t value) {
    for (int shift = 0; shift < 64; shift += 8) {
        out.push_back(static_cast<std::uint8_t>((value >> shift) & 0xFFU));
    }
}

// 小端 u64 读取（越界返回 0）。
std::uint64_t get_u64le(const std::vector<std::uint8_t>& data, std::size_t offset) {
    if (offset + 8 > data.size()) return 0;
    std::uint64_t value = 0;
    for (int index = 7; index >= 0; --index) {
        value = (value << 8U) | data[offset + static_cast<std::size_t>(index)];
    }
    return value;
}

// 以 NUL 分隔的字符串切分（ReadDir / GetFileInfo 的载荷格式）。
std::vector<std::string> split_nul_list(const std::vector<std::uint8_t>& data) {
    std::vector<std::string> parts;
    std::string current;
    for (const std::uint8_t byte : data) {
        if (byte == 0) {
            if (!current.empty()) parts.push_back(current);
            current.clear();
        } else {
            current.push_back(static_cast<char>(byte));
        }
    }
    if (!current.empty()) parts.push_back(current);
    return parts;
}

} // namespace

// ── SSL 上下文与生命周期 ─────────────────────────────────────────────

void OhosIosAfc::SslCtxDeleter::operator()(void* ctx) const noexcept {
    SSL_CTX_free(static_cast<SSL_CTX*>(ctx));
}

std::unique_ptr<void, OhosIosAfc::SslCtxDeleter> OhosIosAfc::make_ssl_ctx() {
    SSL_CTX* ctx = SSL_CTX_new(TLS_client_method());
    if (ctx == nullptr) return {nullptr, SslCtxDeleter{}};
    // 与 libimobiledevice 一致：不校验设备证书（配对记录就是信任根）。
    SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, nullptr);
    // 允许 TLS1.2（iOS lockdown 服务端只到 TLS1.2；OpenSSL 3 默认已含）。
    SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
    // 锁定 RSA 密钥交换 + CBC/AES 套件：lockdown 服务端的套件表很老，
    // 显式列出避免 OpenSSL 默认禁用表把共同套件筛空导致 no shared cipher。
    SSL_CTX_set_cipher_list(ctx, "ALL:@SECLEVEL=0");
    return {ctx, SslCtxDeleter{}};
}

void OhosIosAfc::note(const std::string& text) {
    diagnostic_ = text;
    ohos_usb_diag::note("AFC: " + text);
}

// ── 打开 ─────────────────────────────────────────────────────────────

OhosIosAfc::OhosIosAfc() = default;

OhosIosAfc::~OhosIosAfc() {
    close();
}

void OhosIosAfc::close() noexcept {
    if (ssl_ != nullptr) {
        SSL_shutdown(static_cast<SSL*>(ssl_));   // 尽力而为，不断链也无所谓
        SSL_free(static_cast<SSL*>(ssl_));       // 同时释放两个 BIO
        ssl_ = nullptr;
        rbio_ = nullptr;
        wbio_ = nullptr;
    }
    if (mux_ != nullptr && mux_->connected()) {
        mux_->disconnect();
    }
    mux_.reset();
    opened_ = false;
}

bool OhosIosAfc::opened() const noexcept {
    return opened_;
}

bool OhosIosAfc::open_fd(int fd) {
    close();
    diagnostic_.clear();

    // ── 第 1 步：lockdown StartService ──────────────────────────────
    // 单独用一个临时 mux（连 62078）。StartService 拿到端口后这条隧道就
    // 没用了 —— AFC 走一条全新的隧道（同样的 TLS 证书，但独立的 TLS 会话）。
    LockdownResult lockdown = lockdown_start_service(fd, "com.apple.afc");
    if (!lockdown.ok) return false;
    note(std::format("AFC 服务端口 = {}", lockdown.service_port));

    // ── 第 2 步：AFC 隧道 ───────────────────────────────────────────
    mux_ = std::make_unique<OhosUsbMux>();
    if (!mux_->connect_fd(fd)) {
        note("AFC 隧道建立失败（usbmux 通道没建起来）");
        close();
        return false;
    }
    udid_ = mux_->fd_serial();
    if (!mux_->open_port(lockdown.service_port)) {
        note(std::format("连不上 AFC 端口 {}（设备拒绝或链路中断）",
            lockdown.service_port));
        close();
        return false;
    }

    // ── 第 3 步：AFC 隧道上的 TLS 握手 ─────────────────────────────
    void* ssl_opaque = nullptr;
    if (!tls_handshake_on_mux(mux_.get(), &ssl_opaque) || ssl_opaque == nullptr) {
        close();
        return false;
    }
    ssl_ = ssl_opaque;

    // ── 第 4 步：AFC GetDevInfo 当"链路通了"的判据 ─────────────────
    std::vector<std::uint8_t> devinfo;
    if (!afc_roundtrip(AfcOpGetDevInfo, {}, devinfo)) {
        close();
        return false;
    }
    opened_ = true;
    note("AFC 通道就绪");
    return true;
}

// ── lockdown（StartSession → TLS → StartService）──────────────────────

OhosIosAfc::LockdownResult OhosIosAfc::lockdown_start_service(int fd,
    const std::string& service_name) {
    LockdownResult result;

    OhosUsbMux mux;
    if (!mux.connect_fd(fd)) {
        note("连不上 iPhone（usbmux 通道没建起来），请重新插拔数据线");
        return result;
    }
    const std::string udid = mux.fd_serial();
    if (mux.open_port(LockdowndPort) == false) {
        note("连不上设备的 lockdownd(62078)");
        return result;
    }

    // 读配对记录。StartSession 的三件套都在里面：HostID / SystemBUID /
    // 主机证书 + 私钥。
    std::string record_xml;
    if (!pairing_store::load_record(udid, record_xml)) {
        note(std::format("没有设备 {} 的配对记录（请先完成「信任此电脑」）",
            udid.empty() ? std::string("(未知)") : udid));
        return result;
    }
    std::string host_id;
    std::string system_buid;
    std::string host_cert_pem;
    std::string host_key_pem;
    try {
        const plist::Value record = plist::parse_xml(record_xml);
        if (const auto* value = record.find("HostID")) {
            host_id = value->string_or();
        }
        if (const auto* value = record.find("SystemBUID")) {
            system_buid = value->string_or();
        }
        // 证书存的是 base64(PEM)（与 libimobiledevice 的 pair record 形态
        // 一致，见 OhosPairing.cpp 保存处的说明）；私钥是 PEM 原文。
        if (const auto* value = record.find("HostCertificate")) {
            host_cert_pem = base64_decode(value->string_or());
        }
        if (const auto* value = record.find("HostPrivateKey")) {
            host_key_pem = value->string_or();
        }
    } catch (const std::exception&) {
        note("配对记录损坏（无法解析），请重新配对");
        return result;
    }
    if (host_id.empty() || host_cert_pem.empty() || host_key_pem.empty()) {
        note("配对记录不完整（缺 HostID/主机证书/私钥），请重新配对");
        return result;
    }

    // 明文阶段一：StartSession。成功后设备要求立刻切 TLS。
    auto exchange = [&mux](const plist::Value& request,
                          plist::Value& response) -> bool {
        const std::string xml = plist::to_xml(request);
        std::vector<std::uint8_t> frame;
        const auto length = static_cast<std::uint32_t>(xml.size());
        frame.push_back(static_cast<std::uint8_t>((length >> 24U) & 0xFFU));
        frame.push_back(static_cast<std::uint8_t>((length >> 16U) & 0xFFU));
        frame.push_back(static_cast<std::uint8_t>((length >> 8U) & 0xFFU));
        frame.push_back(static_cast<std::uint8_t>(length & 0xFFU));
        frame.insert(frame.end(), xml.begin(), xml.end());
        if (mux.send(frame) != static_cast<int>(frame.size())) return false;
        const auto deadline = std::chrono::steady_clock::now() +
            std::chrono::seconds(5);
        std::vector<std::uint8_t> buffer;
        for (;;) {
            if (buffer.size() >= 4) {
                const std::uint32_t payload_length =
                    (static_cast<std::uint32_t>(buffer[0]) << 24U) |
                    (static_cast<std::uint32_t>(buffer[1]) << 16U) |
                    (static_cast<std::uint32_t>(buffer[2]) << 8U) |
                    static_cast<std::uint32_t>(buffer[3]);
                if (payload_length > 0 && payload_length <= 8U * 1024U * 1024U &&
                    buffer.size() >= 4 + payload_length) {
                    try {
                        response = plist::parse_xml(
                            std::string_view(reinterpret_cast<const char*>(
                                buffer.data() + 4), payload_length));
                    } catch (const std::exception&) {
                        return false;
                    }
                    return true;
                }
            }
            if (std::chrono::steady_clock::now() >= deadline) return false;
            const auto chunk = mux.receive(AfcReadTimeoutMs);
            if (chunk.empty()) continue;
            buffer.insert(buffer.end(), chunk.begin(), chunk.end());
        }
    };

    plist::Value session_response;
    if (!exchange(plist::Value::Dict({
            {"Label", plist::Value::String("iPhoneMirror")},
            {"Request", plist::Value::String("StartSession")},
            {"HostID", plist::Value::String(host_id)},
            {"SystemBUID", plist::Value::String(system_buid)},
        }), session_response)) {
        note("StartSession 没有得到答复（链路中断或设备已锁屏断开）");
        return result;
    }
    if (const auto* error = session_response.find("Error")) {
        note(std::format("StartSession 被拒：{}（配对记录失效，请重新配对）",
            error->string_or()));
        return result;
    }
    note("lockdown 会话已建立，切换 TLS…");

    // ── TLS 切换 ────────────────────────────────────────────────────
    // 证书/私钥来自配对记录。SSL 上下文只在第一次建立（同一台设备的
    // AFC 隧道复用同一份）。
    if (ssl_ctx_ == nullptr) {
        auto ctx = make_ssl_ctx();
        if (ctx == nullptr) {
            note("OpenSSL 上下文创建失败");
            return result;
        }
        // 主机证书（PEM → X509）。
        {
            BIO* bio = BIO_new_mem_buf(host_cert_pem.data(),
                static_cast<int>(host_cert_pem.size()));
            X509* cert = PEM_read_bio_X509(bio, nullptr, nullptr, nullptr);
            BIO_free(bio);
            if (cert == nullptr ||
                SSL_CTX_use_certificate(static_cast<SSL_CTX*>(ctx.get()),
                    cert) != 1) {
                note("主机证书加载失败（配对记录的 HostCertificate 无效）");
                X509_free(cert);
                return result;
            }
            X509_free(cert);
        }
        // 主机私钥（PEM → EVP_PKEY）。
        {
            BIO* bio = BIO_new_mem_buf(host_key_pem.data(),
                static_cast<int>(host_key_pem.size()));
            EVP_PKEY* key = PEM_read_bio_PrivateKey(bio, nullptr, nullptr,
                nullptr);
            BIO_free(bio);
            if (key == nullptr || SSL_CTX_use_PrivateKey(
                    static_cast<SSL_CTX*>(ctx.get()), key) != 1) {
                note("主机私钥加载失败（配对记录的 HostPrivateKey 无效）");
                EVP_PKEY_free(key);
                return result;
            }
            EVP_PKEY_free(key);
        }
        ssl_ctx_ = ctx.release();
    }

    void* ssl_opaque = nullptr;
    if (!tls_handshake_on_mux(&mux, &ssl_opaque) || ssl_opaque == nullptr) {
        // tls_handshake_on_mux 已经写了 diagnostic。
        return result;
    }
    SSL* ssl = static_cast<SSL*>(ssl_opaque);

    // ── TLS 阶段二：StartService（报文格式同明文阶段，只是跑在 TLS 里）──
    auto send_encrypted = [&ssl](const std::string& xml) -> bool {
        std::vector<std::uint8_t> frame;
        const auto length = static_cast<std::uint32_t>(xml.size());
        frame.push_back(static_cast<std::uint8_t>((length >> 24U) & 0xFFU));
        frame.push_back(static_cast<std::uint8_t>((length >> 16U) & 0xFFU));
        frame.push_back(static_cast<std::uint8_t>((length >> 8U) & 0xFFU));
        frame.push_back(static_cast<std::uint8_t>(length & 0xFFU));
        frame.insert(frame.end(), xml.begin(), xml.end());
        const int written = SSL_write(ssl, frame.data(),
            static_cast<int>(frame.size()));
        return written == static_cast<int>(frame.size());
    };
    auto recv_encrypted_bytes = [&ssl, &mux](std::vector<std::uint8_t>& out,
        int timeout_ms) -> bool {
        out.resize(16 * 1024);
        const int got = SSL_read(ssl, out.data(), static_cast<int>(out.size()));
        if (got > 0) {
            out.resize(static_cast<std::size_t>(got));
            return true;
        }
        // WANT_READ：从 mux 收一段密文灌进 rbio 后重试。
        if (SSL_get_error(ssl, got) == SSL_ERROR_WANT_READ) {
            const auto chunk = mux.receive(timeout_ms);
            if (!chunk.empty()) {
                BIO_write(static_cast<BIO*>(SSL_get_rbio(ssl)),
                    chunk.data(), static_cast<int>(chunk.size()));
            }
        }
        out.clear();
        return false;
    };

    const std::string service_xml = plist::to_xml(plist::Value::Dict({
        {"Label", plist::Value::String("iPhoneMirror")},
        {"Request", plist::Value::String("StartService")},
        {"Service", plist::Value::String(service_name)},
    }));
    if (!send_encrypted(service_xml)) {
        SSL_free(ssl);
        note("StartService 发送失败（TLS 通道中断）");
        return result;
    }
    std::vector<std::uint8_t> tls_buffer;
    const auto deadline = std::chrono::steady_clock::now() +
        std::chrono::seconds(8);
    plist::Value service_response;
    bool got_response = false;
    while (std::chrono::steady_clock::now() < deadline) {
        std::vector<std::uint8_t> chunk;
        if (!recv_encrypted_bytes(chunk, AfcReadTimeoutMs)) continue;
        tls_buffer.insert(tls_buffer.end(), chunk.begin(), chunk.end());
        if (tls_buffer.size() >= 4) {
            const std::uint32_t payload_length =
                (static_cast<std::uint32_t>(tls_buffer[0]) << 24U) |
                (static_cast<std::uint32_t>(tls_buffer[1]) << 16U) |
                (static_cast<std::uint32_t>(tls_buffer[2]) << 8U) |
                static_cast<std::uint32_t>(tls_buffer[3]);
            if (payload_length > 0 && payload_length <= 8U * 1024U * 1024U &&
                tls_buffer.size() >= 4 + payload_length) {
                try {
                    service_response = plist::parse_xml(std::string_view(
                        reinterpret_cast<const char*>(tls_buffer.data() + 4),
                        payload_length));
                    got_response = true;
                } catch (const std::exception&) {
                    note("StartService 的答复无法解析");
                }
                break;
            }
        }
    }
    SSL_free(ssl);   // lockdown 隧道到此结束；mux 析构时断链
    if (!got_response) {
        note("StartService 没有得到答复");
        return result;
    }
    if (const auto* error = service_response.find("Error")) {
        note(std::format("设备拒绝打开 AFC 服务：{}", error->string_or()));
        return result;
    }
    if (const auto* port = service_response.find("Port")) {
        result.service_port = static_cast<std::uint16_t>(
            port->integer_or(0));
    }
    if (result.service_port == 0) {
        note("设备没有给出 AFC 服务端口");
        return result;
    }
    result.ok = true;
    return result;
}

// ── TLS over mux ─────────────────────────────────────────────────────

bool OhosIosAfc::tls_handshake_on_mux(void* mux_opaque,
    void* ssl_out_opaque) {
    auto* mux = static_cast<OhosUsbMux*>(mux_opaque);
    SSL** ssl_out = static_cast<SSL**>(ssl_out_opaque);
    *ssl_out = nullptr;
    if (ssl_ctx_ == nullptr) return false;

    SSL* ssl = SSL_new(static_cast<SSL_CTX*>(ssl_ctx_));
    if (ssl == nullptr) {
        note("SSL 会话创建失败");
        return false;
    }
    BIO* rbio = BIO_new(BIO_s_mem());
    BIO* wbio = BIO_new(BIO_s_mem());
    if (rbio == nullptr || wbio == nullptr) {
        note("内存 BIO 创建失败");
        SSL_free(ssl);
        return false;
    }
    // 所有权交给 SSL_free（SSL_set_bio 之后 rbio/wbio 随 ssl 一起释放）。
    SSL_set_bio(ssl, rbio, wbio);
    SSL_set_connect_state(ssl);

    auto flush_wbio = [&]() -> bool {
        const std::size_t pending = BIO_ctrl_pending(wbio);
        if (pending == 0) return true;
        std::vector<std::uint8_t> out(pending);
        const int got = BIO_read(wbio, out.data(), static_cast<int>(pending));
        if (got <= 0) return true;
        out.resize(static_cast<std::size_t>(got));
        return mux->send(out) == static_cast<int>(out.size());
    };

    const auto deadline = std::chrono::steady_clock::now() +
        std::chrono::milliseconds(TlsHandshakeTimeoutMs);
    while (std::chrono::steady_clock::now() < deadline) {
        if (!flush_wbio()) {
            SSL_free(ssl);
            note("TLS 握手发送失败（链路中断）");
            return false;
        }
        const int rc = SSL_do_handshake(ssl);
        if (rc == 1) {
            *ssl_out = ssl;
            return true;
        }
        const int error = SSL_get_error(ssl, rc);
        if (error != SSL_ERROR_WANT_READ) {
            const unsigned long ssl_error = ERR_peek_last_error();
            char buffer[128] = {};
            ERR_error_string_n(ssl_error, buffer, sizeof(buffer));
            SSL_free(ssl);
            note(std::format("TLS 握手失败：{}", buffer[0] != '\0'
                ? std::string(buffer) : std::string("未知 OpenSSL 错误")));
            return false;
        }
        const auto chunk = mux->receive(AfcReadTimeoutMs);
        if (chunk.empty()) continue;
        BIO_write(rbio, chunk.data(), static_cast<int>(chunk.size()));
    }
    SSL_free(ssl);
    note("TLS 握手超时");
    return false;
}

// ── AFC 帧层 ─────────────────────────────────────────────────────────

bool OhosIosAfc::afc_send(std::uint64_t operation,
    const std::vector<std::uint8_t>& payload) {
    auto* ssl = static_cast<SSL*>(ssl_);
    std::vector<std::uint8_t> header;
    header.reserve(AfcHeaderSize + payload.size());
    header.insert(header.end(), AfcMagic, AfcMagic + 8);
    put_u64le(header, AfcHeaderSize + payload.size());   // entire length
    put_u64le(header, AfcHeaderSize);                    // header size
    put_u64le(header, packet_num_++);                    // packet number
    put_u64le(header, operation);
    put_u64le(header, 0);                                // code（请求恒 0）
    header.insert(header.end(), payload.begin(), payload.end());
    int written = 0;
    const int total = static_cast<int>(header.size());
    while (written < total) {
        const int rc = SSL_write(ssl, header.data() + written, total - written);
        if (rc > 0) {
            written += rc;
            continue;
        }
        if (SSL_get_error(ssl, rc) == SSL_ERROR_WANT_READ) {
            const auto chunk = mux_->receive(AfcReadTimeoutMs);
            if (!chunk.empty()) {
                BIO_write(static_cast<BIO*>(rbio_), chunk.data(),
                    static_cast<int>(chunk.size()));
            }
            continue;
        }
        return false;
    }
    // 把 wbio 里攒的密文泵出去。
    std::vector<std::uint8_t> out(BIO_ctrl_pending(static_cast<BIO*>(wbio_)));
    while (!out.empty()) {
        const int got = BIO_read(static_cast<BIO*>(wbio_), out.data(),
            static_cast<int>(out.size()));
        if (got <= 0) break;
        const std::vector<std::uint8_t> piece(out.begin(),
            out.begin() + got);
        if (mux_->send(piece) != got) return false;
        out.resize(BIO_ctrl_pending(static_cast<BIO*>(wbio_)));
    }
    return true;
}

bool OhosIosAfc::afc_receive(std::uint64_t& status_code,
    std::vector<std::uint8_t>& data_payload) {
    auto* ssl = static_cast<SSL*>(ssl_);
    auto ssl_read_all = [&](std::vector<std::uint8_t>& out,
        std::size_t want) -> bool {
        out.clear();
        out.reserve(want);
        std::vector<std::uint8_t> buffer(AfcChunkSize);
        const auto deadline = std::chrono::steady_clock::now() +
            std::chrono::milliseconds(AfcReadTimeoutMs);
        while (out.size() < want) {
            const int rc = SSL_read(ssl, buffer.data(),
                static_cast<int>(std::min(buffer.size(), want - out.size())));
            if (rc > 0) {
                out.insert(out.end(), buffer.begin(), buffer.begin() + rc);
                continue;
            }
            if (SSL_get_error(ssl, rc) != SSL_ERROR_WANT_READ) return false;
            if (std::chrono::steady_clock::now() >= deadline) return false;
            const auto chunk = mux_->receive(AfcReadTimeoutMs);
            if (chunk.empty()) continue;
            BIO_write(static_cast<BIO*>(rbio_), chunk.data(),
                static_cast<int>(chunk.size()));
        }
        return true;
    };

    // 第一帧：数据帧（DATA / FILE_OPEN_RES）或直接的 STATUS。
    std::vector<std::uint8_t> header;
    if (!ssl_read_all(header, AfcHeaderSize)) {
        note("AFC 响应读取失败（链路中断或超时）");
        return false;
    }
    if (std::memcmp(header.data(), AfcMagic, 8) != 0) {
        note("AFC 响应帧头不合法（magic 不匹配）");
        return false;
    }
    const std::uint64_t entire_length = get_u64le(header, 8);
    const std::uint64_t operation = get_u64le(header, 24);
    status_code = get_u64le(header, 32);
    if (entire_length < AfcHeaderSize || entire_length > 64U * 1024U * 1024U) {
        note(std::format("AFC 响应长度异常（{}）", entire_length));
        return false;
    }
    std::vector<std::uint8_t> payload;
    if (entire_length > AfcHeaderSize) {
        if (!ssl_read_all(payload, static_cast<std::size_t>(
                entire_length - AfcHeaderSize))) {
            note("AFC 响应载荷读取失败");
            return false;
        }
    }

    if (operation == AfcOpStatus) {
        // 直接的 STATUS：code!=0 时载荷是错误文本。
        if (status_code != 0 && !payload.empty()) {
            auto parts = split_nul_list(payload);
            if (!parts.empty()) {
                note(std::format("设备拒绝（{}）：{}", afc_error_text(
                    status_code), parts.front()));
            } else {
                note(std::format("设备拒绝（{}）",
                    afc_error_text(status_code)));
            }
        }
        return status_code == 0;
    }
    if (operation != AfcOpData && operation != AfcOpFileOpenRes) {
        note(std::format("AFC 响应类型异常（op={}）", operation));
        return false;
    }
    data_payload = std::move(payload);

    // 数据帧之后必跟一个 STATUS 帧确认成功与否（libimobiledevice 的
    // afc_receive_data 同样这么做）。
    std::vector<std::uint8_t> status_header;
    if (!ssl_read_all(status_header, AfcHeaderSize) ||
        std::memcmp(status_header.data(), AfcMagic, 8) != 0) {
        note("AFC 状态帧读取失败");
        return false;
    }
    const std::uint64_t status_operation = get_u64le(status_header, 24);
    status_code = get_u64le(status_header, 32);
    if (status_operation != AfcOpStatus) {
        note("AFC 状态帧类型异常");
        return false;
    }
    return status_code == 0;
}

bool OhosIosAfc::afc_roundtrip(std::uint64_t operation,
    const std::vector<std::uint8_t>& payload,
    std::vector<std::uint8_t>& response_payload) {
    std::uint64_t status_code = 0;
    response_payload.clear();
    if (!afc_send(operation, payload)) {
        note("AFC 请求发送失败（TLS/链路中断）");
        return false;
    }
    return afc_receive(status_code, response_payload);
}

// ── AFC 文件操作 ─────────────────────────────────────────────────────

bool OhosIosAfc::list_dir(const std::string& path,
    std::vector<AfcEntry>& out) {
    out.clear();
    std::vector<std::uint8_t> payload(path.begin(), path.end());
    payload.push_back(0);
    std::vector<std::uint8_t> response;
    if (!afc_roundtrip(AfcOpReadDir, payload, response)) return false;
    const std::vector<std::string> names = split_nul_list(response);
    for (const std::string& name : names) {
        AfcEntry entry;
        entry.name = name;
        AfcEntry info;
        if (stat_path(path == "/" ? "/" + name : path + "/" + name, info)) {
            entry.is_dir = info.is_dir;
            entry.size = info.size;
            entry.mtime = info.mtime;
        }
        out.push_back(std::move(entry));
    }
    return true;
}

bool OhosIosAfc::stat_path(const std::string& path, AfcEntry& out) {
    std::vector<std::uint8_t> payload(path.begin(), path.end());
    payload.push_back(0);
    std::vector<std::uint8_t> response;
    if (!afc_roundtrip(AfcOpGetFileInfo, payload, response)) return false;
    out.name.clear();
    out.is_dir = false;
    out.size = 0;
    out.mtime = 0;
    // GetFileInfo 的载荷是 "key\0value\0key\0value\0…"。
    const std::vector<std::string> parts = split_nul_list(response);
    for (std::size_t index = 0; index + 1 < parts.size(); index += 2) {
        const std::string& key = parts[index];
        const std::string& value = parts[index + 1];
        if (key == "st_ifmt") {
            out.is_dir = (value == "S_IFDIR");
        } else if (key == "st_size") {
            out.size = std::strtoll(value.c_str(), nullptr, 10);
        } else if (key == "st_mtime") {
            // 设备给的单位随固件不同（秒/毫秒/微秒/纳秒），按量级归一到秒。
            const std::int64_t raw = std::strtoll(value.c_str(), nullptr, 10);
            if (raw > 1000000000000000000LL) {
                out.mtime = raw / 1000000000LL;                 // 纳秒
            } else if (raw > 1000000000000000LL) {
                out.mtime = raw / 1000000LL;                    // 微秒
            } else if (raw > 100000000000LL) {
                out.mtime = raw / 1000LL;                       // 毫秒
            } else {
                out.mtime = raw;                                // 秒
            }
        }
    }
    return true;
}

bool OhosIosAfc::read_file(const std::string& path, std::int64_t max_bytes,
    std::vector<std::uint8_t>& out) {
    out.clear();
    AfcEntry info;
    if (!stat_path(path, info)) return false;    // 顺便确认存在 & 拿大小
    if (info.is_dir) {
        note("目标是目录，不能按文件读取");
        return false;
    }
    if (max_bytes > 0 && info.size > max_bytes) {
        note(std::format("文件太大（{} 字节，超过本次上限 {}）",
            info.size, max_bytes));
        return false;
    }

    std::vector<std::uint8_t> open_payload(path.begin(), path.end());
    open_payload.push_back(0);
    std::vector<std::uint8_t> mode(8);
    put_u64le(mode, AfcFopenRdOnly);
    open_payload.insert(open_payload.begin(), mode.begin(), mode.end());
    std::vector<std::uint8_t> response;
    if (!afc_roundtrip(AfcOpFileOpen, open_payload, response)) return false;
    if (response.size() < 8) {
        note("FILE_OPEN 的答复不完整");
        return false;
    }
    const std::uint64_t handle = get_u64le(response, 0);

    auto close_handle = [&](void) {
        std::vector<std::uint8_t> close_payload(8);
        put_u64le(close_payload, handle);
        std::vector<std::uint8_t> ignore;
        std::ignore = afc_roundtrip(AfcOpFileClose, close_payload, ignore);
    };

    std::int64_t remaining = info.size;
    while (remaining > 0) {
        const std::uint64_t want = static_cast<std::uint64_t>(
            std::min<std::int64_t>(remaining, static_cast<std::int64_t>(
                AfcChunkSize)));
        std::vector<std::uint8_t> read_payload(16);
        put_u64le(read_payload, handle);
        put_u64le(read_payload, want);
        std::vector<std::uint8_t> chunk;
        if (!afc_roundtrip(AfcOpFileRead, read_payload, chunk)) {
            close_handle();
            return false;
        }
        out.insert(out.end(), chunk.begin(), chunk.end());
        remaining -= static_cast<std::int64_t>(chunk.size());
        if (chunk.empty()) break;    // 设备提前给完了（大小估算偏差）
    }
    close_handle();
    return true;
}

bool OhosIosAfc::write_file(const std::string& path,
    const std::vector<std::uint8_t>& data) {
    std::vector<std::uint8_t> open_payload(path.begin(), path.end());
    open_payload.push_back(0);
    std::vector<std::uint8_t> mode(8);
    put_u64le(mode, AfcFopenWrOnly);    // O_WRONLY|O_CREAT|O_TRUNC
    open_payload.insert(open_payload.begin(), mode.begin(), mode.end());
    std::vector<std::uint8_t> response;
    if (!afc_roundtrip(AfcOpFileOpen, open_payload, response)) return false;
    if (response.size() < 8) {
        note("FILE_OPEN 的答复不完整");
        return false;
    }
    const std::uint64_t handle = get_u64le(response, 0);

    auto close_handle = [&](void) {
        std::vector<std::uint8_t> close_payload(8);
        put_u64le(close_payload, handle);
        std::vector<std::uint8_t> ignore;
        std::ignore = afc_roundtrip(AfcOpFileClose, close_payload, ignore);
    };

    std::size_t offset = 0;
    while (offset < data.size()) {
        const std::size_t want = std::min(AfcChunkSize, data.size() - offset);
        std::vector<std::uint8_t> payload(8);
        put_u64le(payload, handle);
        payload.insert(payload.end(), data.begin() + static_cast<
            std::ptrdiff_t>(offset),
            data.begin() + static_cast<std::ptrdiff_t>(offset + want));
        std::vector<std::uint8_t> ignore;
        if (!afc_roundtrip(AfcOpFileWrite, payload, ignore)) {
            close_handle();
            return false;
        }
        offset += want;
    }
    close_handle();
    return true;
}

bool OhosIosAfc::make_dir(const std::string& path) {
    std::vector<std::uint8_t> payload(path.begin(), path.end());
    payload.push_back(0);
    std::vector<std::uint8_t> ignore;
    return afc_roundtrip(AfcOpMakeDir, payload, ignore);
}

bool OhosIosAfc::remove_path(const std::string& path) {
    std::vector<std::uint8_t> payload(path.begin(), path.end());
    payload.push_back(0);
    std::vector<std::uint8_t> ignore;
    return afc_roundtrip(AfcOpRemovePath, payload, ignore);
}

bool OhosIosAfc::rename_path(const std::string& from, const std::string& to) {
    std::vector<std::uint8_t> payload(from.begin(), from.end());
    payload.push_back(0);
    payload.insert(payload.end(), to.begin(), to.end());
    payload.push_back(0);
    std::vector<std::uint8_t> ignore;
    return afc_roundtrip(AfcOpRenamePath, payload, ignore);
}

} // namespace iPhoneMirror::ohos
