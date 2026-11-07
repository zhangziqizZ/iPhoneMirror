#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""配对证书 X.509 结构的回归自检。

为什么需要它
------------
配对证书是**手写 DER** 拼出来的（鸿蒙的 CryptoArchitectureKit 没有 X.509
构造 API），而配对失败在设备侧只表现为一个 `InvalidPairRecord` —— 看不出
哪里错了。这类 bug 靠读代码极难发现：本文件第一次跑的时候就抓到一个 ——
``extensions`` 字段少了 ``SEQUENCE OF Extension`` 那一层，OpenSSL 直接报

    asn1_check_tlen: wrong tag :: Type=X509_EXTENSION

而设备只会说"证书被拒"。任何一次对证书编码的改动都应该跑这个脚本。

它做什么
--------
1. 从 **C++ 源码**里解析出 tag 常量与 OID 字节（``OhosPairingPki.cpp``），
   用它们拼出证书 —— 所以 C++ 改了常量，这个脚本立刻失配。
2. 产出三张证书（根 CA / 主机 / 设备），交给 **OpenSSL** 做权威判定：
   能不能解析、扩展对不对、签名有效吗。
3. 核对设备证书里的公钥就是设备自己的公钥、SKI 就是"设备公钥 PKCS#1
   DER"的 SHA1。

用法
----
    python3 tools/pairing_der_selftest.py

需要 openssl 在 PATH 里（脚本会自己找 /usr/bin/openssl 与 /bin/openssl）。
"""
from __future__ import annotations

import base64
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)
PKI_CPP = os.path.join(PROJ, "entry/src/main/cpp/ohos/OhosPairingPki.cpp")

OPENSSL = shutil.which("openssl") or next(
    (p for p in ("/usr/bin/openssl", "/bin/openssl") if os.path.exists(p)), None)

failures: list[str] = []
checks = 0


def check(ok: bool, what: str) -> bool:
    global checks
    checks += 1
    print(f"  {'[OK]' if ok else '[!!]'} {what}")
    if not ok:
        failures.append(what)
    return ok


# ── 从 C++ 源码里取常量 ───────────────────────────────────────────
#
# 这一步是整个脚本的关键：**常量不复制第二份**，而是现场从 C++ 源码里读。
# 这样 C++ 改了 tag 或 OID，脚本会立刻发现（拼出来的证书 OpenSSL 读不了），
# 而不是"两边一起改错、一起通过"。

def parse_cpp_constants() -> dict:
    if not os.path.exists(PKI_CPP):
        raise SystemExit(f"找不到 C++ 源码：{PKI_CPP}")
    src = open(PKI_CPP, encoding="utf-8").read()

    tags: dict[str, int] = {}
    for name, value in re.findall(
            r"constexpr std::uint8_t (Tag\w+) = (0x[0-9A-Fa-f]+);", src):
        tags[name] = int(value, 16)

    oids: dict[str, bytes] = {}
    for name, body in re.findall(
            r"const std::vector<std::uint8_t>& (oid_\w+)\(\) \{"
            r"\s*static const std::vector<std::uint8_t> value = \{(.*?)\}", src,
            re.S):
        values = [int(x, 16) for x in re.findall(r"0x([0-9A-Fa-f]{2})", body)]
        oids[name] = bytes(values)

    return {"tags": tags, "oids": oids, "source": src}


def check_cpp_extensions_structure(src: str) -> list[str]:
    """从 C++ 源码里确认 extensions 的**字节结构**，而不只是常量。

    为什么必须查源码：脚本是用 Python 复刻 C++ 的编码逻辑的，如果只看
    Python 那一侧，两边同时改错就会一起通过 —— 那样这个自检就白做了。
    所以这里额外盯住 C++ 里最关键的那一处结构：

        encode_tlv(wrapper, TagContext3, sequence_of);   // [3] 包着 SEQUENCE
        encode_tlv(sequence_of, TagSequence, extensions); // SEQUENCE OF Extension

    少了中间那层 SEQUENCE，证书的 extensions 字段就不合法（OpenSSL 报
    asn1_check_tlen: wrong tag），而设备只会说"证书被拒"。

    这里检查的是"TagContext3 的参数是否经过一次 TagSequence 包装"。
    """
    problems: list[str] = []

    # 找到 extensions [3] 那段的编码语句
    context3 = re.search(
        r"encode_tlv\((\w+),\s*TagContext3,\s*([\w.]+)\)", src)
    if context3 is None:
        problems.append("C++ 源码里找不到 extensions 的 [3] 包装（TagContext3）")
        return problems

    wrapper_var, payload = context3.group(1), context3.group(2)

    # payload 必须是一个"由 TagSequence 装出来的"变量
    sequence_of = re.search(
        r"encode_tlv\((\w+),\s*TagSequence,\s*extensions\);", src)
    if sequence_of is None:
        problems.append(
            "C++ 源码里 extensions 缺少 SEQUENCE OF 包装 —— "
            "[3] 必须装着一个 SEQUENCE（Extensions ::= SEQUENCE OF Extension），"
            "少这层 OpenSSL 会报 wrong tag，设备侧只会说证书被拒")
        return problems

    if sequence_of.group(1) != payload:
        problems.append(
            f"C++ 源码里 [3] 装的是 {payload}，但 SEQUENCE OF 的变量名是 "
            f"{sequence_of.group(1)} —— 两者应当是同一个")

    return problems


# ── DER 编码（与 OhosPairingPki.cpp 的 encode_* 一一对应）──────────

class Der:
    def __init__(self, consts: dict):
        self.t = consts["tags"]
        self.o = consts["oids"]

    def tlv(self, tag: int, content: bytes) -> bytes:
        return bytes([tag]) + self.enc_len(len(content)) + content

    @staticmethod
    def enc_len(n: int) -> bytes:
        if n < 0x80:
            return bytes([n])
        out = b""
        while n:
            out = bytes([n & 0xFF]) + out
            n >>= 8
        return bytes([0x80 | len(out)]) + out

    def integer(self, value: int) -> bytes:
        # 对齐 encode_integer()：最短字节，最高位为 1 时补 0x00
        content = b""
        started = False
        for shift in range(24, -1, -8):
            byte = (value >> shift) & 0xFF
            if byte != 0 or started:
                content += bytes([byte])
                started = True
        if not content:
            content = b"\x00"
        if content[0] & 0x80:
            content = b"\x00" + content
        return self.tlv(self.t["TagInteger"], content)

    def bit_string(self, content: bytes) -> bytes:
        # 对齐 encode_bit_string()：前置"未用位数 0"
        return self.tlv(self.t["TagBitString"], b"\x00" + content)

    def oid(self, name: str) -> bytes:
        return self.tlv(self.t["TagOid"], self.o[name])

    def algorithm_identifier(self, name: str) -> bytes:
        content = self.oid(name) + bytes([self.t["TagNull"], 0x00])
        return self.tlv(self.t["TagSequence"], content)

    def basic_constraints_value(self, is_ca: bool) -> bytes:
        content = b""
        if is_ca:
            content += bytes([self.t["TagBoolean"], 0x01, 0xFF])
        return self.tlv(self.t["TagSequence"], content)

    def key_usage_value(self) -> bytes:
        # 对齐 key_usage_value()：BIT STRING { 未用位数 5, 0xA0 }
        return self.tlv(self.t["TagBitString"], b"\x05\xa0")

    def extension(self, oid_name: str, critical: bool, value_der: bytes) -> bytes:
        # 对齐 encode_extension()：critical 是裸字节 01 01 FF（不是 BIT STRING）
        item = self.oid(oid_name)
        if critical:
            item += bytes([self.t["TagBoolean"], 0x01, 0xFF])
        item += self.tlv(self.t["TagOctetString"], value_der)
        return self.tlv(self.t["TagSequence"], item)

    def utc_time(self, when: datetime) -> bytes:
        text = when.strftime("%y%m%d%H%M%SZ")
        return self.tlv(self.t["TagUtcTime"], text.encode())

    def empty_name(self) -> bytes:
        return self.tlv(self.t["TagSequence"], b"")

    def spki_from_pkcs1(self, pkcs1: bytes) -> bytes:
        algorithm = self.algorithm_identifier("oid_rsa_encryption")
        return self.tlv(self.t["TagSequence"],
                        algorithm + self.bit_string(pkcs1))

    def build_certificate(self, subject_spki: bytes, signer_key: str,
                          digest: str, is_ca: bool, key_usage: bool,
                          subject_key_id: bool) -> bytes:
        alg_oid = ("oid_sha1_with_rsa" if digest == "sha1"
                   else "oid_sha256_with_rsa")
        now = datetime.now(timezone.utc)
        content = b""
        content += self.tlv(self.t["TagContext0"], self.integer(2))
        content += self.integer(1)
        content += self.algorithm_identifier(alg_oid)
        content += self.empty_name()
        content += self.tlv(self.t["TagSequence"],
                            self.utc_time(now - timedelta(seconds=60)) +
                            self.utc_time(now + timedelta(days=365 * 10)))
        content += self.empty_name()
        content += subject_spki

        extensions = b""
        extensions += self.extension("oid_basic_constraints", True,
                                     self.basic_constraints_value(is_ca))
        if key_usage:
            extensions += self.extension("oid_key_usage", True,
                                         self.key_usage_value())
        if subject_key_id:
            ski = hashlib.sha1(spki_bit_string(subject_spki)).digest()
            extensions += self.extension("oid_subject_key_identifier", False,
                                         self.tlv(self.t["TagOctetString"], ski))
        # ★ 两层 SEQUENCE：Extensions ::= SEQUENCE OF Extension，
        #   而 [3] EXPLICIT 装的是这个 SEQUENCE。少了内层会被 OpenSSL 拒。
        content += self.tlv(self.t["TagContext3"],
                            self.tlv(self.t["TagSequence"], extensions))

        tbs = self.tlv(self.t["TagSequence"], content)
        signature = subprocess.run(
            [OPENSSL, "dgst", f"-{digest}", "-sign", signer_key],
            input=tbs, capture_output=True, check=True).stdout
        return self.tlv(self.t["TagSequence"],
                        tbs + self.algorithm_identifier(alg_oid) +
                        self.bit_string(signature))


# ── DER 读取（独立实现，不复用 C++ 的解析逻辑）────────────────────

def read_tlv(data: bytes, offset: int):
    tag = data[offset]
    cursor = offset + 1
    first = data[cursor]
    cursor += 1
    if first & 0x80:
        n = first & 0x7F
        length = int.from_bytes(data[cursor:cursor + n], "big")
        cursor += n
    else:
        length = first
    return tag, cursor, length, cursor + length


def spki_bit_string(spki: bytes) -> bytes:
    tag, content, length, _ = read_tlv(spki, 0)
    assert tag == 0x30
    alg_tag, alg_content, alg_len, alg_end = read_tlv(spki, content)
    assert alg_tag == 0x30
    bs_tag, bs_content, bs_len, _ = read_tlv(spki, alg_end)
    assert bs_tag == 0x03
    return spki[bs_content + 1:bs_content + bs_len]


def to_pem(der: bytes, label: str = "CERTIFICATE") -> str:
    b64 = base64.b64encode(der).decode()
    body = "\n".join(textwrap.wrap(b64, 64))
    return f"-----BEGIN {label}-----\n{body}\n-----END {label}-----\n"


def main() -> int:
    if OPENSSL is None:
        raise SystemExit("找不到 openssl")
    print("配对证书 X.509 结构自检")
    print("=" * 64)

    consts = parse_cpp_constants()
    tags, oids = consts["tags"], consts["oids"]
    print(f"  从 C++ 源码读到 {len(tags)} 个 tag、{len(oids)} 个 OID")

    required_tags = ["TagInteger", "TagBitString", "TagOctetString",
                     "TagNull", "TagOid", "TagUtcTime", "TagSequence",
                     "TagBoolean", "TagContext0", "TagContext3"]
    missing = [t for t in required_tags if t not in tags]
    check(not missing, f"C++ 源码里的 tag 常量齐全（缺 {missing}）")
    required_oids = ["oid_rsa_encryption", "oid_sha1_with_rsa",
                     "oid_sha256_with_rsa", "oid_basic_constraints",
                     "oid_key_usage", "oid_subject_key_identifier"]
    missing = [o for o in required_oids if o not in oids]
    check(not missing, f"C++ 源码里的 OID 常量齐全（缺 {missing}）")

    # ★ 结构级校验：直接盯住 C++ 里 extensions 的字节布局 ★
    #
    # 只查常量是不够的 —— 脚本的 Python 侧是 C++ 的复刻，两边同时改错会
    # 一起通过。所以这里额外从 C++ 源码里确认"[3] 包着 SEQUENCE OF"这层
    # 结构确实存在（这是手写 DER 最容易错、也最难查的一处）。
    problems = check_cpp_extensions_structure(consts["source"])
    check(not problems,
          "C++ 源码里 extensions 的 [3] 包装包含 SEQUENCE OF 层"
          + ("" if not problems else f"（{problems[0]}）"))

    der = Der(consts)
    work = tempfile.mkdtemp(prefix="pairing-der-")

    # 设备公钥：PKCS#1 PEM —— 与 lockdownd 的 GetValue("DevicePublicKey") 同形态
    subprocess.run([OPENSSL, "genrsa", "-out", f"{work}/dev.pem", "2048"],
                   capture_output=True, check=True)
    subprocess.run([OPENSSL, "rsa", "-in", f"{work}/dev.pem", "-pubout",
                    "-RSAPublicKey_out", "-out", f"{work}/dev_pub.pem"],
                   capture_output=True, check=True)
    dev_pkcs1 = subprocess.run(
        [OPENSSL, "rsa", "-pubin", "-in", f"{work}/dev_pub.pem",
         "-RSAPublicKey_out", "-outform", "DER"],
        capture_output=True, check=True).stdout
    dev_spki = der.spki_from_pkcs1(dev_pkcs1)

    # 根 CA 与主机密钥
    for name in ("root", "host"):
        subprocess.run([OPENSSL, "genrsa", "-out", f"{work}/{name}_key.pem",
                        "2048"], capture_output=True, check=True)
    root_spki = subprocess.run(
        [OPENSSL, "rsa", "-in", f"{work}/root_key.pem", "-pubout",
         "-outform", "DER"], capture_output=True, check=True).stdout
    host_spki = subprocess.run(
        [OPENSSL, "rsa", "-in", f"{work}/host_key.pem", "-pubout",
         "-outform", "DER"], capture_output=True, check=True).stdout

    root = der.build_certificate(root_spki, f"{work}/root_key.pem",
                                 "sha256", True, False, False)
    host = der.build_certificate(host_spki, f"{work}/root_key.pem",
                                 "sha256", False, True, False)
    device = der.build_certificate(dev_spki, f"{work}/root_key.pem",
                                    "sha256", False, True, True)

    for name, blob in (("root", root), ("host", host), ("device", device)):
        with open(f"{work}/{name}.pem", "w") as handle:
            handle.write(to_pem(blob))

    # ── OpenSSL 权威判定 ────────────────────────────────────────
    for name in ("root", "host", "device"):
        result = subprocess.run(
            [OPENSSL, "x509", "-in", f"{work}/{name}.pem", "-noout", "-text"],
            capture_output=True)
        check(result.returncode == 0,
              f"{name}.pem 能被 OpenSSL 解析"
              + ("" if result.returncode == 0
                 else f"（{result.stderr.decode().strip()[:120]}）"))

    # 扩展内容
    def extensions_of(name: str) -> str:
        result = subprocess.run(
            [OPENSSL, "x509", "-in", f"{work}/{name}.pem", "-noout", "-text"],
            capture_output=True, check=True)
        text = result.stdout.decode()
        start = text.find("X509v3 extensions:")
        return text[start:] if start >= 0 else ""

    check("CA:TRUE" in extensions_of("root"), "根证书 BasicConstraints CA:TRUE")
    check("CA:FALSE" in extensions_of("host"), "主机证书 BasicConstraints CA:FALSE")
    check("Digital Signature, Key Encipherment" in extensions_of("host"),
          "主机证书 KeyUsage = digitalSignature + keyEncipherment")
    check("Subject Key Identifier" in extensions_of("device"),
          "设备证书带 SubjectKeyIdentifier")
    check("Subject Key Identifier" not in extensions_of("host"),
          "主机证书不带 SubjectKeyIdentifier（只有设备证书需要）")

    # 签名有效性：用根 CA 公钥直接验主机证书的签名
    subprocess.run([OPENSSL, "x509", "-in", f"{work}/root.pem", "-noout",
                    "-pubkey", "-out", f"{work}/root_pub.pem"], check=True,
                   capture_output=True)
    ok = verify_signature(root, f"{work}/root_pub.pem", "sha256")
    check(ok, "根 CA 的自签有效")

    # 主机证书由根 CA 签
    root_pub = subprocess.run(
        [OPENSSL, "x509", "-in", f"{work}/root.pem", "-noout", "-pubkey"],
        capture_output=True, check=True).stdout
    open(f"{work}/root_pub2.pem", "wb").write(root_pub)
    ok = verify_signature(host, f"{work}/root_pub2.pem", "sha256")
    check(ok, "主机证书的签名能被根 CA 公钥验证")

    ok = verify_signature(device, f"{work}/root_pub2.pem", "sha256")
    check(ok, "设备证书的签名能被根 CA 公钥验证")

    # ── 内容一致性 ──────────────────────────────────────────────
    device_tbs = certificate_tbs(device)
    embedded = tbs_subject_public_key_info(device_tbs)
    check(embedded == dev_spki,
          "设备证书里的 subjectPublicKeyInfo == 设备自己的公钥（SPKI）")

    root_tbs = certificate_tbs(root)
    check(tbs_subject_public_key_info(root_tbs) == root_spki,
          "根证书里的公钥 == 根 CA 的公钥")

    # SKI == SHA1(设备公钥的 PKCS#1 DER)
    ski_text = extensions_of("device")
    match = re.search(r"Subject Key Identifier:\s*\n\s*([0-9A-Fa-f:]+)", ski_text)
    if check(match is not None, "设备证书的 SKI 可读"):
        declared = bytes.fromhex(match.group(1).replace(":", ""))
        expected = hashlib.sha1(dev_pkcs1).digest()
        check(declared == expected,
              "SKI == SHA1(设备公钥的 PKCS#1 DER)（不是整个 SPKI 的 SHA1）")

    # SHA1 版本
    root1 = der.build_certificate(root_spki, f"{work}/root_key.pem",
                                  "sha1", True, False, False)
    open(f"{work}/root_sha1.pem", "w").write(to_pem(root1))
    result = subprocess.run(
        [OPENSSL, "x509", "-in", f"{work}/root_sha1.pem", "-noout", "-text"],
        capture_output=True)
    check(result.returncode == 0, "SHA1 版本的证书也能被 OpenSSL 解析")
    if result.returncode == 0:
        check("sha1WithRSAEncryption" in result.stdout.decode(),
              "SHA1 版本的签名算法是 sha1WithRSAEncryption")

    print("=" * 64)
    if failures:
        print(f"有 {len(failures)} 项失败（共 {checks} 项检查）：")
        for item in failures:
            print(f"  - {item}")
        return 1
    print(f"全部通过（{checks} 项检查）")
    return 0


def certificate_tbs(certificate: bytes) -> bytes:
    tag, content, length, _ = read_tlv(certificate, 0)
    assert tag == 0x30
    tbs_tag, tbs_content, tbs_len, _ = read_tlv(certificate, content)
    assert tbs_tag == 0x30
    return certificate[content:tbs_content + tbs_len]


def tbs_subject_public_key_info(tbs: bytes) -> bytes:
    tag, content, length, _ = read_tlv(tbs, 0)
    cursor = content
    for _ in range(6):
        _, item_content, item_len, _ = read_tlv(tbs, cursor)
        cursor = item_content + item_len
    spki_tag, spki_content, spki_len, _ = read_tlv(tbs, cursor)
    assert spki_tag == 0x30
    return tbs[cursor:spki_content + spki_len]


def verify_signature(certificate: bytes, public_key_pem: str, digest: str) -> bool:
    """用给定的公钥直接验证书的签名（绕开 X.509 链的 subject/issuer 判定）。

    根 CA 的 subject 与 issuer 都是空名（协议要求），OpenSSL 的链验证会
    因此报 "self-signed certificate"，所以这里手工拆出 tbs 与签名来验。
    """
    tag, content, length, _ = read_tlv(certificate, 0)
    _, tbs_content, tbs_len, tbs_end = read_tlv(certificate, content)
    tbs = certificate[content:tbs_end]
    _, _, _, alg_end = read_tlv(certificate, tbs_end)
    bs_tag, bs_content, bs_len, _ = read_tlv(certificate, alg_end)
    signature = certificate[bs_content + 1:bs_content + bs_len]

    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as handle:
        handle.write(tbs)
        tbs_path = handle.name
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as handle:
        handle.write(signature)
        sig_path = handle.name
    try:
        result = subprocess.run(
            [OPENSSL, "dgst", f"-{digest}", "-verify", public_key_pem,
             "-signature", sig_path, tbs_path],
            capture_output=True)
        return result.returncode == 0
    finally:
        os.unlink(tbs_path)
        os.unlink(sig_path)


if __name__ == "__main__":
    sys.exit(main())
