// SPDX-License-Identifier: GPL-3.0-only
//
// OhosPairing.h 的实现：在 usbmux 隧道上与设备的 lockdownd 对话，请求
// 「信任此电脑」。
//
// ── 报文格式 ─────────────────────────────────────────────────────
//
// lockdownd 的报文极简：**4 字节大端长度 + XML plist 正文**。
// 与 usbmux 隧道那层的全大端一致（同一层协议，不存在字节序混用）。
// 上游 Core/DeviceManager.cpp 的 lockdown_exchange() 是同一格式的权威参照。
//
// 请求/响应都是 plist。请求形如：
//
//   { Label: "iPhoneMirror", Request: "GetValue", Key: "DevicePublicKey" }
//
// 失败时响应带一个 Error 字符串；ExtendedPairingErrors 打开后它能一一对应
// 到真实原因（见 OhosPairing.h 里的对照表）。
//
// ── cert 字段为什么是 base64 ─────────────────────────────────────
//
// 本工程复用的 plist::Value::Data **存的就是 base64 文本本身**
// （Core/src/Protocol/Plist.cpp 的 serialize_value 直接把 string 拼进
// <data>），不像 libplist 那样自动编码。所以这里必须自己 base64 编解码。
// 设备侧要的是 **base64(PEM 文本)**（对照 theapplewiki 的 lockdownd 协议
// 记录：<data> 里是 "-----BEGIN CERTIFICATE-----" 的 base64）。

#include "OhosPairing.h"

#include "Logging.h"
#include "OhosPairingPki.h"
#include "OhosPairingStatus.h"
#include "OhosPairingStore.h"
#include "OhosUsbDiagnostics.h"
#include "OhosUsbMux.h"
#include "Protocol/Plist.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <format>
#include <random>
#include <string>
#include <thread>
#include <vector>

namespace iPhoneMirror::ohos {
namespace {

// 重试节奏。iosctl 用 1.2 秒、pymobiledevice3 用 1 秒；这里取 1.2 秒，
// 理由是它比 1 秒更不容易和设备的弹窗刷新节奏撞上，同时对用户来说仍然
// 感觉是"立刻"。
constexpr auto PairRetryInterval = std::chrono::milliseconds(1200);

// 单次读设备的超时。弹窗期间设备不一定会回数据（它在等用户点），所以
// 读超时不能太长，否则"用户还没点"会被误判成链路断了。
constexpr int PairReadTimeoutMs = 2000;

// 设备答复里的错误串 → 配对结果。
PairingOutcome outcome_for_error(std::string_view error) {
    if (error == "PairingDialogResponsePending") return PairingOutcome::AwaitingUser;
    if (error == "UserDeniedPairing") return PairingOutcome::DeniedByUser;
    if (error == "PasswordProtected") return PairingOutcome::PasswordProtected;
    if (error == "InvalidHostID") return PairingOutcome::InvalidHostId;
    if (error == "InvalidPairRecord") return PairingOutcome::InvalidPairRecord;
    return PairingOutcome::LinkFailed;
}

// ── base64 ────────────────────────────────────────────────────────
//
// 只需要标准字母表 + 补位 '='，不需要 URL-safe 变体。
constexpr char Base64Alphabet[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

std::string base64_encode(const std::string& input) {
    std::string output;
    output.reserve((input.size() + 2) / 3 * 4);
    std::size_t index = 0;
    while (index + 2 < input.size()) {
        const std::uint32_t triple =
            (static_cast<std::uint8_t>(input[index]) << 16U) |
            (static_cast<std::uint8_t>(input[index + 1]) << 8U) |
            static_cast<std::uint8_t>(input[index + 2]);
        output.push_back(Base64Alphabet[(triple >> 18U) & 0x3FU]);
        output.push_back(Base64Alphabet[(triple >> 12U) & 0x3FU]);
        output.push_back(Base64Alphabet[(triple >> 6U) & 0x3FU]);
        output.push_back(Base64Alphabet[triple & 0x3FU]);
        index += 3;
    }
    const std::size_t remaining = input.size() - index;
    if (remaining == 1) {
        const std::uint32_t triple = static_cast<std::uint8_t>(input[index]) << 16U;
        output.push_back(Base64Alphabet[(triple >> 18U) & 0x3FU]);
        output.push_back(Base64Alphabet[(triple >> 12U) & 0x3FU]);
        output.push_back('=');
        output.push_back('=');
    } else if (remaining == 2) {
        const std::uint32_t triple =
            (static_cast<std::uint8_t>(input[index]) << 16U) |
            (static_cast<std::uint8_t>(input[index + 1]) << 8U);
        output.push_back(Base64Alphabet[(triple >> 18U) & 0x3FU]);
        output.push_back(Base64Alphabet[(triple >> 12U) & 0x3FU]);
        output.push_back(Base64Alphabet[(triple >> 6U) & 0x3FU]);
        output.push_back('=');
    }
    return output;
}

std::string base64_decode(std::string_view input) {
    std::array<int, 256> table{};
    table.fill(-1);
    for (int index = 0; index < 64; ++index) {
        table[static_cast<unsigned char>(Base64Alphabet[index])] = index;
    }
    std::string output;
    output.reserve(input.size() / 4 * 3);
    std::uint32_t accumulator = 0;
    int bits = 0;
    for (const char raw : input) {
        const unsigned char byte = static_cast<unsigned char>(raw);
        if (byte == '=') break;
        const int value = table[byte];
        if (value < 0) continue; // 换行等空白直接跳过
        accumulator = (accumulator << 6U) | static_cast<std::uint32_t>(value);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            output.push_back(static_cast<char>((accumulator >> bits) & 0xFFU));
        }
    }
    return output;
}

// 生成一个 UUID 形态的字符串（大写，带连字符），用作 HostID / SystemBUID。
//
// 为什么 HostID 要随机：它是"这台电脑"的稳定身份。设备端用它判断"是不是
// 上次那台电脑"。同一台应用重复生成新 HostID 会被设备当成新设备，于是
// 每次都弹窗 —— 所以真正要长期免弹窗，必须把 HostID 固定存下来
// （第二步的持久化要做的事）。
std::string generate_uuid() {
    std::random_device random;
    std::uniform_int_distribution<int> nibble(0, 15);
    std::array<char, 37> text{};
    static constexpr char Digits[] = "0123456789ABCDEF";
    std::size_t cursor = 0;
    for (int index = 0; index < 36; ++index) {
        if (index == 8 || index == 13 || index == 18 || index == 23) {
            text[cursor++] = '-';
            continue;
        }
        text[cursor++] = Digits[nibble(random)];
    }
    text[cursor] = '\0';
    return std::string(text.data(), cursor);
}

// 拼一条 lockdownd 报文：4 字节大端长度 + XML 正文。
std::vector<std::uint8_t> frame_lockdown_request(const std::string& xml) {
    std::vector<std::uint8_t> frame;
    frame.reserve(4 + xml.size());
    const auto length = static_cast<std::uint32_t>(xml.size());
    frame.push_back(static_cast<std::uint8_t>((length >> 24U) & 0xFFU));
    frame.push_back(static_cast<std::uint8_t>((length >> 16U) & 0xFFU));
    frame.push_back(static_cast<std::uint8_t>((length >> 8U) & 0xFFU));
    frame.push_back(static_cast<std::uint8_t>(length & 0xFFU));
    frame.insert(frame.end(), xml.begin(), xml.end());
    return frame;
}

// 在字节流里找一条完整的 lockdownd 报文（按 4 字节大端长度切）。
//
// 隧道是 TCP 字节流，一条报文可能跨多次 receive 到达，也可能一次 receive
// 里挤着多条。所以这里按长度前缀切，而不是"一次 receive = 一条报文"。
bool take_lockdown_frame(std::vector<std::uint8_t>& buffer,
    std::string& frame) {
    if (buffer.size() < 4) return false;
    const std::uint32_t length =
        (static_cast<std::uint32_t>(buffer[0]) << 24U) |
        (static_cast<std::uint32_t>(buffer[1]) << 16U) |
        (static_cast<std::uint32_t>(buffer[2]) << 8U) |
        static_cast<std::uint32_t>(buffer[3]);
    // 8 MiB 上限与上游 Core/DeviceManager.cpp 的 lockdown_exchange 一致，
    // 用来挡住长度字段被读错时的巨额分配。
    if (length == 0 || length > 8U * 1024U * 1024U) return false;
    if (buffer.size() < 4 + length) return false;
    frame.assign(reinterpret_cast<const char*>(buffer.data() + 4), length);
    buffer.erase(buffer.begin(), buffer.begin() + static_cast<std::ptrdiff_t>(4 + length));
    return true;
}

// 与设备的 lockdownd 对话一次：发一条 plist 请求，收一条 plist 响应。
//
// 这里只处理"一问一答"。Pair 请求的等待用户重试在调用方做，因为那需要
// 跨越多轮"发-等-再发"。
bool lockdown_exchange(OhosUsbMux& mux, std::vector<std::uint8_t>& buffer,
    const plist::Value& request, plist::Value& response) {
    const std::string xml = plist::to_xml(request);
    const auto frame = frame_lockdown_request(xml);
    if (mux.send(frame) != static_cast<int>(frame.size())) return false;

    const auto deadline = std::chrono::steady_clock::now() +
        std::chrono::seconds(5);
    for (;;) {
        std::string payload;
        if (take_lockdown_frame(buffer, payload)) {
            try {
                response = plist::parse_xml(payload);
            } catch (const std::exception&) {
                // 设备回了本工程 plist 解析器不认识的 XML：不是链路问题，
                // 但也不能当成成功。
                return false;
            }
            return true;
        }
        if (std::chrono::steady_clock::now() >= deadline) return false;
        const auto chunk = mux.receive(PairReadTimeoutMs);
        if (chunk.empty()) continue;
        buffer.insert(buffer.end(), chunk.begin(), chunk.end());
    }
}

// 构造 Pair 请求。
//
// 字段与 libimobiledevice 的 lockdownd_do_pair() 对齐：
//   Label / Request="Pair" / ProtocolVersion="2" /
//   PairingOptions{ExtendedPairingErrors:true} / PairRecord{...}
//
// PairRecord 里**不放私钥**（上游把 RootPrivateKey/HostPrivateKey 从
// 请求副本里删掉），只放证书与身份。
//
// ★ 证书字段必须是 base64(PEM 文本)，不是 base64(DER) ★
//
//   依据：libimobiledevice 的 lockdownd_pair_record_to_plist() 写的是
//     plist_dict_set_item(dict, "DeviceCertificate",
//         plist_new_data(pair_record->device_certificate,
//                        strlen(pair_record->device_certificate)));
//   strlen() 说明存的是**以 NUL 结尾的字符串** —— 而 pair_record 里存的是
//   PEM（userpref.c 的 pair_record_generate_keys_and_certs() 用
//   PEM_write_bio_X509 产出 root_cert_pem/host_cert_pem/dev_cert_pem）。
//   libplist 把 <data> 序列化成 base64，所以线上格式是 base64(PEM)。
//
//   本工程的 plist 实现与 libplist 有个关键差异：Type::Data 存的就是
//   base64 **文本本身**（Core/src/Protocol/Plist.cpp 的 serialize_value
//   直接把 string 拼进 <data>），不像 libplist 那样自动编码。所以这里
//   必须自己把 PEM 文本编码成 base64 —— 传 DER 的话设备解出来是一段
//   二进制而不是 PEM，会直接拒收，而报的是 InvalidPairRecord 这种
//   看不出原因的错。
plist::Value build_pair_request(const std::string& hostId,
    const std::string& systemBuid, const pki::Certificate& root,
    const pki::Certificate& host, const pki::Certificate& device) {
    plist::Value pair_record = plist::Value::Dict({
        {"DeviceCertificate", plist::Value::Data(base64_encode(device.pem))},
        {"HostCertificate", plist::Value::Data(base64_encode(host.pem))},
        {"RootCertificate", plist::Value::Data(base64_encode(root.pem))},
        {"HostID", plist::Value::String(hostId)},
        {"SystemBUID", plist::Value::String(systemBuid)},
    });

    return plist::Value::Dict({
        {"Label", plist::Value::String("iPhoneMirror")},
        {"Request", plist::Value::String("Pair")},
        {"ProtocolVersion", plist::Value::String("2")},
        {"PairingOptions", plist::Value::Dict({
            {"ExtendedPairingErrors", plist::Value::Bool(true)},
        })},
        {"PairRecord", std::move(pair_record)},
    });
}

// ── 上游 preflight 的两个前置步骤（2026-10-30 补）──────────────────
//
// 上游 usbmuxd 的 preflight.c 在发 Pair 之前做两件事，本工程原先都没做。
// 依据：libimobiledevice/usbmuxd src/preflight.c
//   · lockdownd_client_new() 的**第一件事**就是 QueryType，并校验返回
//     "com.apple.mobile.lockdown"（不是则说明对端不是 lockdownd ——
//     restore 模式的设备会回 "com.apple.mobile.restored"）。
//   · iOS 7+ 分支里先 lockdownd_set_untrusted_host_buid(lockdown)，
//     即 SetValue{Key:"UntrustedHostBUID", Value:本机 SystemBUID}，
//     **然后**才 lockdownd_pair()。

// 询问对端是哪个服务。返回空串表示没问出结果。
//
// 为什么必须有它：连上 62078 不代表对面就是 lockdownd（62078 上也可能
// 是别的服务）。问一句能立刻区分"链路通但服务不对"与"链路根本不通"。
std::string query_lockdown_type(OhosUsbMux& mux,
    std::vector<std::uint8_t>& buffer) {
    const plist::Value request = plist::Value::Dict({
        {"Label", plist::Value::String("iPhoneMirror")},
        {"Request", plist::Value::String("QueryType")},
    });
    plist::Value response;
    if (!lockdown_exchange(mux, buffer, request, response)) return {};
    if (const auto* error = response.find("Error")) {
        ohos_usb_diag::note(std::format("QueryType 被拒：{}",
            error->string_or()));
        return {};
    }
    const auto* value = response.find("Type");
    if (value == nullptr) return {};
    return value->string_or();
}

// 告诉设备"这台未受信任的主机的 BUID 是这个"。
//
// 上游 usbmuxd 用它把「弹窗」与「请求方」关联起来 —— 设备侧记的是
// "HostID + 根 CA 公钥"，而 UntrustedHostBUID 让设备在弹窗阶段就知道
// 是谁在请求配对。本工程把 SystemBUID 一并给它，与 PairRecord 里的
// SystemBUID 保持同一个值（上游用的也是同一个 system_buid）。
//
// ★ 这个请求的失败**不影响**后续配对 ★
//   上游 lockdownd_set_untrusted_host_buid() 也不检查返回值；
//   设备在某些版本上会回 SetProhibited。所以这里只记日志不报错。
void set_untrusted_host_buid(OhosUsbMux& mux,
    std::vector<std::uint8_t>& buffer, const std::string& systemBuid) {
    const plist::Value request = plist::Value::Dict({
        {"Label", plist::Value::String("iPhoneMirror")},
        {"Request", plist::Value::String("SetValue")},
        {"Key", plist::Value::String("UntrustedHostBUID")},
        {"Value", plist::Value::String(systemBuid)},
    });
    plist::Value response;
    if (!lockdown_exchange(mux, buffer, request, response)) {
        ohos_usb_diag::note("设置 UntrustedHostBUID 失败（不影响配对）");
        return;
    }
    if (const auto* error = response.find("Error")) {
        ohos_usb_diag::note(std::format("设备拒绝 UntrustedHostBUID：{}"
            "（不影响配对）", error->string_or()));
        return;
    }
    ohos_usb_diag::note("已设置 UntrustedHostBUID");
}

} // namespace

std::string describe_pairing_outcome(PairingOutcome outcome) {
    switch (outcome) {
    case PairingOutcome::Trusted:
        return "iPhone 已信任本机";
    case PairingOutcome::AwaitingUser:
        return "iPhone 上正在等待你点击「信任此电脑」（请解锁手机并点「信任」）";
    case PairingOutcome::DeniedByUser:
        return "你在 iPhone 上点了「不信任」；如需重试请解锁手机后重新发起配对";
    case PairingOutcome::PasswordProtected:
        return "iPhone 有密码锁，请先解锁手机再发起配对";
    case PairingOutcome::InvalidHostId:
        return "iPhone 不认这个本机身份（配对记录已失效）；请在 iPhone 上"
               "「设置 → 通用 → 传输或还原 iPhone → 还原」后重新配对";
    case PairingOutcome::InvalidPairRecord:
        return "iPhone 拒绝了本机的配对证书（配对记录未被接受）；"
               "请拔插数据线后重试";
    case PairingOutcome::LinkFailed:
        return "未能连上 iPhone 的配对通道（usbmux/隧道/报文任一环节失败；"
               "设备拒绝连接多为手机锁屏）";
    }
    return "配对结果未知";
}

// 配对协议主体：mux 已连上（DDK 或 fd 通道均可），从这里开始只关心协议。
//
// 拆出来是因为连接方式有两条路（DDK deviceId / usbManager fd），但
// lockdownd 对话、证书签发、Pair 轮询、记录保存完全共用 —— 复制一份
// 迟早改出两个不一样的配对行为。
PairingOutcome run_device_trust(OhosUsbMux& mux, const std::string& udid,
    int timeoutSeconds) {
    if (timeoutSeconds <= 0) timeoutSeconds = 60;

    if (!mux.open_port(LockdowndPort)) {
        ohos_usb_diag::note("配对失败：连不上设备的 lockdownd(62078)");
        // 设备侧回 RST 的最常见原因是**手机锁屏**：iOS 在锁定状态下会拒绝
        // usbmux 隧道连到 lockdownd。解锁后重试即可。
        pairing_status::set("未能连上 iPhone 的配对通道（设备拒绝了 lockdownd "
            "连接，多为手机锁屏）——请解锁 iPhone 后重试");
        return PairingOutcome::LinkFailed;
    }
    ohos_usb_diag::note("已连上设备 lockdownd，准备请求「信任此电脑」");
    pairing_status::set("正在向 iPhone 请求配对…");

    std::vector<std::uint8_t> buffer;

    // ── 上游 preflight 的第一步：QueryType ───────────────────────────
    //
    // 上游 lockdownd_client_new() 做的**第一件事**就是问对端是哪个服务，
    // 并校验是 "com.apple.mobile.lockdown"。这一步能把两类完全不同的
    // 失败分开：
    //   · 对端回了别的类型（如 restore 模式的 "com.apple.mobile.restored"）
    //     → 设备不在正常模式，配对无从谈起
    //   · 压根没应答 → 隧道其实没通（后面所有 GetValue 都会超时）
    //
    // 问不到**不**直接失败：部分固件对未配对主机的 QueryType 可能不回，
    // 上游也只是记个日志继续往下走。真正的判据留给下面的 GetValue 探测。
    {
        const std::string type = query_lockdown_type(mux, buffer);
        if (type.empty()) {
            ohos_usb_diag::note("QueryType 没有问出结果（继续往下试探）");
        } else if (type != "com.apple.mobile.lockdown") {
            ohos_usb_diag::note(std::format(
                "设备侧服务不是 lockdownd（Type={}），无法配对", type));
            pairing_status::set(std::format(
                "iPhone 当前处于非正常模式（{}），请退出恢复模式后重试", type));
            return PairingOutcome::LinkFailed;
        } else {
            ohos_usb_diag::note("对端确认为 com.apple.mobile.lockdown");
        }
    }

    // 先做一次只读探测，确认 lockdownd 真的在应答。
    //
    // 为什么要单独探一次：usbmux 隧道通了不代表 lockdownd 在应答（62078
    // 上可能是别的服务）。而 GetValue("DevicePublicKey") 在**未配对**时也
    // 允许（这正是设备侧给"首次配对"留的口子），所以它能干净地把
    // "链路问题"与"配对被拒"区分开；而且它的返回值正是签发设备证书所需的
    // **设备公钥**（设备证书要嵌的就是这把钥匙，见 OhosPairingPki.h）。
    plist::Value probe_response;
    const plist::Value probe_request = plist::Value::Dict({
        {"Label", plist::Value::String("iPhoneMirror")},
        {"Request", plist::Value::String("GetValue")},
        {"Key", plist::Value::String("DevicePublicKey")},
    });
    if (!lockdown_exchange(mux, buffer, probe_request, probe_response)) {
        ohos_usb_diag::note("配对失败：lockdownd 没有应答（读超时）");
        pairing_status::set("iPhone 没有回应配对请求，请解锁手机并重试");
        return PairingOutcome::LinkFailed;
    }
    if (const auto* error = probe_response.find("Error")) {
        ohos_usb_diag::note(std::format("lockdownd 拒绝只读探测：{}",
            error->string_or()));
        pairing_status::set(std::format("iPhone 拒绝了配对请求（{}）",
            error->string_or()));
        return PairingOutcome::LinkFailed;
    }
    ohos_usb_diag::note("lockdownd 应答正常，开始请求配对");

    // 取设备公钥。
    //
    // ★ 设备返回的是 <data>，里面装的是 **base64(PEM 文本)** ★
    //
    //   依据：libimobiledevice 的 lockdownd_get_device_public_key_as_key_data()
    //   用 plist_get_data_val() 取值 —— libplist 会把 <data> 的 base64 自动
    //   解码，所以它拿到的是**裸 PEM 字节**。pymobiledevice3 侧一致：
    //   get_value() 对 <data> 返回 r.data（原始字节），随后
    //   load_pem_public_key(device_public_key_pem) 直接当 PEM 用。
    //
    //   而本工程的 plist 实现不解码：Type::Data 存的就是 base64 文本本身
    //   （Plist.cpp 的 serialize_value 直接把 string 拼进 <data>）。所以这里
    //   必须自己解一次 base64，解出来的才是 PEM 文本。
    //
    //   防御性：万一某些固件把它放在 <string> 里（不带 base64），那就直接
    //   用原文。看到 "-----BEGIN" 就说明已经是明文，不必再解。
    std::vector<std::uint8_t> device_public_key;
    if (const auto* value = probe_response.find("Value")) {
        const std::string& raw = value->string_or();
        if (raw.find("-----BEGIN") != std::string::npos) {
            device_public_key.assign(raw.begin(), raw.end());
        } else {
            const std::string decoded = base64_decode(raw);
            device_public_key.assign(decoded.begin(), decoded.end());
        }
    }
    if (device_public_key.empty()) {
        ohos_usb_diag::note("设备没有提供公钥（DevicePublicKey），无法签发配对证书");
        pairing_status::set("iPhone 未提供配对所需的公钥，无法完成配对");
        return PairingOutcome::LinkFailed;
    }

    // ── 取设备版本（决定签名算法）──────────────────────────────────
    //
    // 依据：pymobiledevice3 的 select_hash_algorithm() —— 版本 < 4.0.0 用
    // SHA1WithRSA，否则 SHA256WithRSA。现代 iOS 都是 SHA256。
    std::string device_version;
    {
        plist::Value version_response;
        const plist::Value version_request = plist::Value::Dict({
            {"Label", plist::Value::String("iPhoneMirror")},
            {"Request", plist::Value::String("GetValue")},
            {"Key", plist::Value::String("ProductVersion")},
        });
        if (lockdown_exchange(mux, buffer, version_request, version_response)) {
            if (const auto* value = version_response.find("Value")) {
                device_version = value->string_or();
            }
        }
    }

    // ── 取 WiFiAddress（必须在 Pair **之前**取）────────────────────
    //
    // 依据：libimobiledevice 的 lockdownd_do_pair() 在发 Pair 之前先调
    // lockdownd_get_value(client, NULL, "WiFiAddress", &wifi_node)，注释写着
    // "get wifi mac now, if we get it later we fail on iOS 7 which causes a
    // reconnect" —— 配对完成后再取会失败，还会导致设备重连。
    //
    // 这个值要存进配对记录：它是设备的 Wi-Fi MAC 地址，设备的"这台电脑"
    // 身份校验会用到。
    //
    // ★ 类型原样保留，不要自己转成字符串 ★
    //   iOS 上 WiFiAddress 的类型在不同版本上不一样（新设备给 <string>，
    //   老设备给 <data>，里面是 6 字节 MAC 二进制）。libimobiledevice 是
    //   plist_copy(wifi_node) 原样存进配对记录的，所以这里也原样存 ——
    //   强行转成字符串会把 <data> 的内容变成 base64 文本，语义就变了。
    plist::Value wifi_address;
    {
        plist::Value wifi_response;
        const plist::Value wifi_request = plist::Value::Dict({
            {"Label", plist::Value::String("iPhoneMirror")},
            {"Request", plist::Value::String("GetValue")},
            {"Key", plist::Value::String("WiFiAddress")},
        });
        if (lockdown_exchange(mux, buffer, wifi_request, wifi_response)) {
            if (const auto* value = wifi_response.find("Value")) {
                wifi_address = *value;
            }
        }
        if (wifi_address.type == plist::Type::Null) {
            // 取不到不算致命：它只影响记录里的一个附加字段。
            ohos_usb_diag::note("未取到设备 WiFiAddress（不影响配对）");
        }
    }

    // ── 取回已保存的配对身份 ──────────────────────────────────────
    //
    // HostID 的来源：**优先复用已保存的配对记录**。
    //
    // ★ 这是"插一次就长期免弹窗"的关键 ★
    //   设备侧记的是"HostID + 根 CA 公钥"。HostID 每次随机 ⇒ 设备会当成
    //   一台新电脑 ⇒ 每次插线都弹窗。所以 HostID 必须**稳定**：从已存的
    //   配对记录里取，取不到才新建并把新的存回去。
    //
    //   同理，根 CA 的密钥也必须复用（设备记着它的公钥）。所以这里还要
    //   从记录里恢复根 CA 的私钥 —— 这也是为什么记录里必须存私钥。
    //
    // 这一段必须在**签发证书之前**读：签发时若能复用已存的根 CA 私钥，
    // 设备看到的还是同一把钥匙，配对才能一次通过。
    std::string hostId;
    std::string systemBuid;
    std::string stored_root_key_pem;
    if (!udid.empty()) {
        std::string stored_xml;
        if (pairing_store::load_record(udid, stored_xml)) {
            try {
                const plist::Value stored = plist::parse_xml(stored_xml);
                if (const auto* value = stored.find("HostID")) {
                    hostId = value->string_or();
                }
                if (const auto* value = stored.find("SystemBUID")) {
                    systemBuid = value->string_or();
                }
                if (const auto* value = stored.find("RootPrivateKey")) {
                    stored_root_key_pem = value->string_or();
                }
                if (!hostId.empty() && !systemBuid.empty()) {
                    ohos_usb_diag::note("复用已保存的配对身份（HostID 不变）");
                }
            } catch (const std::exception&) {
                ohos_usb_diag::note("已保存的配对记录无法解析，将重新配对");
                hostId.clear();
                systemBuid.clear();
                stored_root_key_pem.clear();
            }
        }
    }
    if (hostId.empty()) hostId = generate_uuid();
    if (systemBuid.empty()) systemBuid = generate_uuid();

    // 准备配对材料并签发三张证书。
    //
    // ★ 为什么证书失败**不**直接放弃 ★
    //   弹窗与"证书是否被设备接受"是两个独立的失败点。证书这条路要是先
    //   断掉，用户连弹窗都看不到，就分不清是"协议没通"还是"证书不对"。
    //   所以证书失败时仍然发 Pair（用占位证书），让弹窗先出来 —— 弹窗能出
    //   来就证明 usbmux 隧道与 lockdownd 都通了，剩下的才是证书问题。
    pki::Certificate root_certificate;
    pki::Certificate host_certificate;
    pki::Certificate device_certificate;
    bool certificates_ready = false;
    pki::PairingMaterial material;
    bool material_ready = false;
    if (!stored_root_key_pem.empty()) {
        // 复用已存的根 CA：设备记着它的公钥，换一把就等于换了一台电脑，
        // "插一次长期免弹窗"就无从谈起。
        material_ready = pki::restore_pairing_material(stored_root_key_pem,
            device_public_key, material);
        if (!material_ready) {
            ohos_usb_diag::note("复用已存的根 CA 失败，改为新建");
        }
    }
    if (!material_ready) {
        material_ready = pki::generate_pairing_material(device_public_key,
            material);
    }
    if (material_ready) {
        // 摘要算法按**设备版本**选，而不是"先试一个"。
        //
        // 之前的写法是"先 SHA256，签发失败再 SHA1"—— 但签发本身不会因为
        // 算法不对而失败（SHA256 签名总是能算出来），失败发生在**设备端**
        // 校验证书时，那时已经晚了。正确做法是一开始就按版本选对：
        // pymobiledevice3 的 select_hash_algorithm() 判据是 < 4.0.0 用
        // SHA1、否则 SHA256。
        const pki::DigestAlgorithm digest =
            pki::select_digest_algorithm(device_version);
        ohos_usb_diag::note(std::format(
            "设备版本 {}，配对证书签名算法 {}",
            device_version.empty() ? std::string("未知") : device_version,
            digest == pki::DigestAlgorithm::Sha1 ? "SHA1WithRSA"
                                                  : "SHA256WithRSA"));
        certificates_ready = pki::issue_pairing_certificates(material,
            digest, root_certificate, host_certificate, device_certificate);
    }
    if (!certificates_ready) {
        ohos_usb_diag::note("配对证书签发失败，改用占位证书以先弹出信任框");
        const std::string placeholder =
            "-----BEGIN CERTIFICATE-----\n"
            "MIIBplaceholder\n"
            "-----END CERTIFICATE-----\n";
        root_certificate.pem = placeholder;
        host_certificate.pem = placeholder;
        device_certificate.pem = placeholder;
    }

    // ── 上游 preflight 的第二步：UntrustedHostBUID ──────────────────
    //
    // 上游 usbmuxd 的 preflight.c 在 lockdownd_pair() **之前**先
    // lockdownd_set_untrusted_host_buid(lockdown)，即：
    //     SetValue { Key: "UntrustedHostBUID", Value: <本机 SystemBUID> }
    //
    // 作用是让设备在弹窗阶段就知道「是谁在请求配对」——设备侧记的是
    // "HostID + 根 CA 公钥"，而 UntrustedHostBUID 把请求方提前告诉它。
    //
    // ★ 必须在发 Pair 之前 ★：Pair 一旦发出，设备就开始弹窗了；
    //   之后再补这个请求就晚了。
    //
    // ★ 失败不影响配对 ★：上游也不检查返回值（某些固件会回
    //   SetProhibited），所以这里只记日志。
    set_untrusted_host_buid(mux, buffer, systemBuid);

    // 发 Pair 并轮询。
    //
    // 轮询是必须的：设备在用户点「信任」之前一直回
    // PairingDialogResponsePending。只发一次就判定失败，等于用户还没看到
    // 弹窗程序就报错了（iosctl 踩过这个坑）。
    const plist::Value request = build_pair_request(hostId, systemBuid,
        root_certificate, host_certificate, device_certificate);

    const auto deadline = std::chrono::steady_clock::now() +
        std::chrono::seconds(timeoutSeconds);
    bool announced = false;
    for (;;) {
        plist::Value response;
        if (!lockdown_exchange(mux, buffer, request, response)) {
            // 读不到答复：可能设备还在弹窗期间静默，也可能是链路抖了。
            // 在等待窗口内继续试，超时后才算失败。
            if (std::chrono::steady_clock::now() >= deadline) {
                ohos_usb_diag::note("配对失败：等待用户响应超时");
                pairing_status::set(
                    "等待 iPhone 确认超时；请保持手机解锁并重新发起配对");
                return PairingOutcome::AwaitingUser;
            }
            std::this_thread::sleep_for(PairRetryInterval);
            continue;
        }

        if (const auto* error = response.find("Error")) {
            const std::string text = error->string_or();
            if (text == "PairingDialogResponsePending") {
                if (!announced) {
                    announced = true;
                    ohos_usb_diag::note(
                        "弹窗已出现在 iPhone 上，等待你点「信任」…");
                    logging::write(logging::Level::Info, "pairing",
                        "设备已弹出信任对话框，等待用户响应");
                    // 这一句是整件事里**唯一真正需要用户动手**的提示，
                    // 所以要放在普通界面也看得见的地方（不是开发者模式的
                    // 诊断区）。iOS 的弹窗标题是"信任此电脑"，文案要与之一致，
                    // 否则用户会去手机上找别的按钮。
                    pairing_status::set("请在 iPhone 上点「信任此电脑」");
                }
                if (std::chrono::steady_clock::now() >= deadline) {
                    ohos_usb_diag::note("等待用户点「信任」超时");
                    pairing_status::set(
                        "等待 iPhone 确认超时；请保持手机解锁并重新发起配对");
                    return PairingOutcome::AwaitingUser;
                }
                std::this_thread::sleep_for(PairRetryInterval);
                continue;
            }
            ohos_usb_diag::note(std::format("配对被设备拒绝：{}", text));
            logging::write(logging::Level::Warning, "pairing", std::format(
                "配对被拒：{}", text));
            const PairingOutcome outcome = outcome_for_error(text);
            pairing_status::set(describe_pairing_outcome(outcome));
            return outcome;
        }

        // 没有 Error 字段就是成功了。
        //
        // ★ EscrowBag 在响应的**顶层**，不在 PairRecord 里 ★
        //
        // 依据：libimobiledevice 的 lockdownd_do_pair() 在配对成功后做的是
        //     plist_t extra_node = plist_dict_get_item(dict, USERPREF_ESCROW_BAG_KEY);
        //     if (extra_node && plist_get_node_type(extra_node) == PLIST_DATA) {
        //         plist_dict_set_item(pair_record_plist, USERPREF_ESCROW_BAG_KEY,
        //                             plist_copy(extra_node));
        //     }
        // 其中 dict 是**响应**本身。EscrowBag 是设备用我们根 CA 的公钥
        // 加密的密钥包 —— 后续开 SSL 会话要靠它解密设备的私钥，丢了就
        // 无法建立加密通道。
        ohos_usb_diag::note("iPhone 已接受配对（本机已被信任）");
        logging::write(logging::Level::Info, "pairing", "设备接受了配对请求");

        // 保存配对记录。
        //
        // 存的是"我们的证书 + 我们的私钥 + 设备回的 EscrowBag"。
        // 证书存 base64(PEM)：与 libimobiledevice 的 pair record 形态一致
        //（那边也是 PEM 放进 <data>），将来能用现成工具排查。
        if (!udid.empty() && certificates_ready) {
            plist::Value stored = plist::Value::Dict({
                {"HostID", plist::Value::String(hostId)},
                {"SystemBUID", plist::Value::String(systemBuid)},
                {"RootCertificate", plist::Value::Data(base64_encode(
                    root_certificate.pem))},
                {"RootPrivateKey", plist::Value::String(
                    material.root_private_key_pem)},
                {"HostCertificate", plist::Value::Data(base64_encode(
                    host_certificate.pem))},
                {"HostPrivateKey", plist::Value::String(
                    material.host_private_key_pem)},
                {"DeviceCertificate", plist::Value::Data(base64_encode(
                    device_certificate.pem))},
            });
            if (wifi_address.type != plist::Type::Null) {
                stored.dictionary["WiFiMACAddress"] = wifi_address;
            }
            // EscrowBag：设备回的响应顶层。
            if (const auto* value = response.find("EscrowBag")) {
                stored.dictionary["EscrowBag"] = *value;
            }
            if (pairing_store::save_record(udid, plist::to_xml(stored))) {
                ohos_usb_diag::note("配对记录已保存，下次插线无需再信任");
            } else {
                ohos_usb_diag::note("配对记录保存失败，下次插线可能需要重新信任");
            }
        }

        pairing_status::set("iPhone 已信任本机");
        return PairingOutcome::Trusted;
    }
}

PairingOutcome request_device_trust(std::uint64_t deviceId,
    const std::string& udid, int timeoutSeconds) {
    if (timeoutSeconds <= 0) timeoutSeconds = 60;

    pairing_status::clear();

    OhosUsbMux mux;
    if (!mux.connect(deviceId)) {
        ohos_usb_diag::note("配对失败：usbmux 通道没建起来");
        pairing_status::set("未能连上 iPhone 的配对通道，请重新插拔数据线后重试");
        return PairingOutcome::LinkFailed;
    }
    return run_device_trust(mux, udid, timeoutSeconds);
}

// fd 路径在跑的标志（见头文件 fd_pairing_active 的注释）。
// 原子 + RAII 守卫：request_device_trust_fd 有多个返回点（connect_fd 失败、
// run_device_trust 的各路 outcome），靠析构复位才能不遗漏。
std::atomic<bool>& fd_pairing_flag() noexcept {
    static std::atomic<bool> value{false};
    return value;
}

class FdPairingGuard {
public:
    FdPairingGuard() { fd_pairing_flag().store(true); }
    ~FdPairingGuard() { fd_pairing_flag().store(false); }
    FdPairingGuard(const FdPairingGuard&) = delete;
    FdPairingGuard& operator=(const FdPairingGuard&) = delete;
};

bool fd_pairing_active() noexcept {
    return fd_pairing_flag().load();
}

PairingOutcome request_device_trust_fd(int fd, int timeoutSeconds) {
    if (timeoutSeconds <= 0) timeoutSeconds = 60;

    // ★ 在跑期间让 DDK 自动配对让路（maybe_start_pairing 查 fd_pairing_active）★
    // ★ 不再 clear 配对状态 ★：两条路径共用一份状态，fd 只在失败时写一句带
    // 前缀的话，不与 DDK 主路抢话筒。
    FdPairingGuard guard;

    OhosUsbMux mux;
    if (!mux.connect_fd(fd)) {
        ohos_usb_diag::note("fd 兜底通道配对失败：usbmux 通道没建起来");
        pairing_status::set(
            "fd 兜底通道不可用（bulk 被系统拒绝），等待 DDK 通道配对");
        return PairingOutcome::LinkFailed;
    }
    // UDID 由 connect_fd 的发现阶段读出（非系统应用拿不到 getDevices 的
    // serial，这是唯一的来源）。读不到就传空串：配对仍会进行（用户能看到
    // 弹窗），只是记录存不下来，下次还要再信任一次。
    return run_device_trust(mux, mux.fd_serial(), timeoutSeconds);
}

} // namespace iPhoneMirror::ohos

// ───────────────────────── C ABI：配对状态 ─────────────────────────
//
// 返回进程内静态缓冲：调用方（NAPI 桥）用完即走，不要释放、不要跨线程长期
// 持有。每次重新拷贝一份，是因为 NAPI 的字符串创建本身就是拷贝语义，而这里
// 给出一个稳定生命周期的 const char* 比让调用方管内存更不容易出错。
//
// 为什么放在本文件而不是 OhosPairingStatus.h：那个头是 inline 的状态容器，
// 而"对外暴露一个 C ABI 符号"这件事需要一个真实的编译单元（否则符号只在
// 引用它的那个 .cpp 里可见，napi_bridge.cpp 链不到）。
const char *im_pairing_status(void) {
    static std::mutex buffer_mutex;
    static std::string buffer;
    try {
        std::scoped_lock lock(buffer_mutex);
        buffer = iPhoneMirror::ohos::pairing_status::get();
        return buffer.c_str();
    } catch (...) {
        return "";
    }
}
