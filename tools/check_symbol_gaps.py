#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
#
# 链接缺口静态体检：找出「被已编译文件引用、却只由未编译的平台文件定义」的符号。
#
# 背景：上游 src/Core 用三套源列表（PORTABLE / WINDOWS / LINUX）拼出每个平台的
# 目标文件。移植到新平台时必须整份核对——某个可移植文件引用的符号如果只在
# Windows 或 Linux 的平台文件里定义，新平台的构建列表就会漏掉它，直到链接期
# 才报 undefined symbol（或者更糟：被 C ABI 的 weak 兜底掩盖）。
#
# 用法：python3 tools/check_symbol_gaps.py

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CPP = ROOT / "entry/src/main/cpp"
CORE = CPP / "Core/src"
OHOS = CPP / "ohos"

# 逐条对齐 entry/src/main/cpp/CMakeLists.txt 中实际参与编译的文件。
PORTABLE = [
    "Protocol/Plist.cpp",
    "Protocol/QuickTimePacket.cpp",
    "Protocol/QuickTimeSession.cpp",
    "Media/H264.cpp",
    "Media/CoreMedia.cpp",
    "Media/VideoFrameCopy.cpp",
    "Audio/PcmBufferPolicy.cpp",
    "Text/Utf.cpp",
    "Logging.cpp",
    "Transport/Socket.cpp",
    "Transport/AppleUsbSerial.cpp",
    "Transport/AppleUsbSelection.cpp",
    "Transport/UsbMuxClient.cpp",
    "Capture/CaptureSession.cpp",
]
OHOS_SOURCES = [
    "OhosAppleUsbDiscovery.cpp",
    "OhosAudioRenderer.cpp",
    "OhosCoreApi.cpp",
    "OhosDeviceManager.cpp",
    "OhosEnvironmentProbe.cpp",
    "OhosMediaBackends.cpp",
    "OhosPreviewRenderer.cpp",
    "OhosSharedGpuFrame.cpp",
    "OhosUsbDdk.cpp",
    "OhosUsbTransport.cpp",
    "OhosVideoDecoder.cpp",
]

# 上游里存在、但本平台构建列表故意不包含的平台文件。
EXCLUDED = [
    "CoreApi.cpp",
    "Media/ActiveVideoDecoder.cpp",
    "Transport/LibUsb0Transport.cpp",
    "Transport/QtUsbTransport.cpp",
    "Device/AppleUsbDiscovery.cpp",
    "Device/DeviceManager.cpp",
    "Capture/WirelessReceiverHub.cpp",
    "Capture/WirelessCaptureSession.cpp",
    "Media/MediaFoundationDecoder.cpp",
    "Audio/WasapiRenderer.cpp",
    "Renderer/D3D11PreviewRenderer.cpp",
    "Media/LinuxSharedGpuFrame.cpp",
    "Media/LinuxMediaBackends.cpp",
    "Media/LinuxFFmpegVideoDecoder.cpp",
    "Media/LinuxPlaceboRenderer.cpp",
    "Audio/LinuxPipeWireAudioRenderer.cpp",
    "Device/LinuxAppleUsbDiscovery.cpp",
    "Device/LinuxDeviceManager.cpp",
    "Device/LinuxEnvironmentProbe.cpp",
    "Device/LinuxUdevMonitor.cpp",
    "Transport/LinuxUsbConfiguration.cpp",
    "LinuxCoreApi.cpp",
    "LinuxPreviewApi.cpp",
]

# 路径相对 Core/src（CORE 常量指向那里）。
COUNTERPARTS = [
    ("LinuxCoreApi.cpp", "OhosCoreApi.cpp",
     "60 个 im_* 导出必须逐个有对应；缺一个就是 ABI 破口"),
    ("Media/LinuxMediaBackends.cpp", "OhosMediaBackends.cpp",
     "只做平台选择，两个工厂函数"),
    ("Media/LinuxSharedGpuFrame.cpp", "OhosSharedGpuFrame.cpp",
     "VideoFrameCopy.cpp 唯一要的平台钩子"),
    ("Media/LinuxFFmpegVideoDecoder.cpp", "OhosVideoDecoder.cpp",
     "IVideoDecoder 接缝：configure/decode/drain/flush/preference/四个自述"),
    ("Audio/LinuxPipeWireAudioRenderer.cpp", "OhosAudioRenderer.cpp",
     "IAudioRenderer 接缝：enqueue/set_enabled/set_volume/stop/stats"),
    ("Media/LinuxPlaceboRenderer.cpp", "OhosPreviewRenderer.cpp",
     "预览渲染器（Linux 用 libplacebo/Vulkan，鸿蒙用 EGL+GLES）"),
    ("Device/LinuxAppleUsbDiscovery.cpp", "OhosAppleUsbDiscovery.cpp",
     "只实现共享代码真会走到的两个查询"),
    ("Device/LinuxDeviceManager.cpp", "OhosDeviceManager.cpp",
     "DeviceManager.h 的平台实现"),
    ("Device/LinuxEnvironmentProbe.cpp", "OhosEnvironmentProbe.cpp",
     "环境自检报告与就绪判定"),
    ("Transport/QtUsbTransport.cpp", "OhosUsbTransport.cpp",
     "QtUsbContext/QtUsbConnection/UsbError/probe_usb_runtime；"
     "上游 Linux 直接调 libusb-1.0，鸿蒙走 USB DDK"),
]

# 粗略识别「函数 / 变量定义」：行首是类型或限定名，紧跟一个标识符，再跟 ( 或 = 或 ;。
# 允许 C ABI 的调用约定宏（IM_CALL / IM_API / NAPI_CALL 之类全大写记号）夹在中间。
DEF_RE = re.compile(
    r"^\s*(?:[A-Z_]{2,}\s+)?"                       # IM_API / extern "C" 之外的全大写宏
    r"(?:[A-Za-z_][\w:]*\s*(?:::\s*[\w:]+\s*)*)"    # 返回类型（含 :: 限定）
    r"(?:[\*&]\s*)*"
    r"(?:[A-Z_]{2,}\s+)*"                            # IM_CALL 等
    r"(?:[A-Za-z_]\w*\s*::\s*)*"                     # 类外成员定义：Type Class::name(
    r"([A-Za-z_]\w*)\s*"
    r"(?:\(|=\s*\{|=)",
)

# 出现在这些位置的行不是定义，跳过。
SKIP_PREFIX = (
    "if", "for", "while", "switch", "return", "else", "catch", "do",
    "case", "using", "typedef", "template", "static_assert", "assert",
    "namespace", "class", "struct", "enum", "union", "public", "private",
    "protected", "friend", "extern", "sizeof", "decltype", "throw",
)

IDENT_RE = re.compile(r"\b([A-Za-z_]\w*)\b")

# 可移植头文件：这些是三个平台都要满足的契约面。
PORTABLE_HEADERS = [
    "Media/VideoFormats.h",
    "Media/H264.h",
    "Media/CoreMedia.h",
    "Audio/PcmBufferPolicy.h",
    "Text/Utf.h",
    "Logging.h",
    "Protocol/Plist.h",
    "Protocol/QuickTimePacket.h",
    "Protocol/QuickTimeSession.h",
    "Transport/Socket.h",
    "Transport/UsbMuxClient.h",
    "Transport/AppleUsbSerial.h",
    "Capture/CaptureSession.h",
    "Capture/ICaptureSession.h",
    "Capture/DecoderSwitchCoordinator.h",
    "Device/AppleUsbDiscovery.h",
    "Transport/QtUsbTransport.h",
    "Transport/LibUsb0Transport.h",
]

# 声明行：以 ; 结尾且带 ( 的行，去掉注释。
DECL_RE = re.compile(r"^[^/]*\b([A-Za-z_]\w*)\s*\([^;{]*\)\s*(?:const\s*)?(?:noexcept\s*)?"
                     r"(?:override\s*)?(?:->\s*[\w:<>,\* &]+)?\s*;\s*$")


def header_declarations(path: Path) -> set[str]:
    """头文件里"需要别处给定义"的函数名。行内带 { 的是 inline/默认实现，排除。"""
    out: set[str] = set()
    if not path.exists():
        return out
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = re.sub(r"//.*$", "", raw)
        if "{" in line or "=" in line:  # inline 定义 / = delete / = default / 带默认值
            continue
        m = DECL_RE.match(line.strip())
        if not m:
            continue
        name = m.group(1)
        if name in ("if", "for", "while", "switch", "return", "sizeof", "decltype"):
            continue
        out.add(name)
    return out


def definitions(path: Path) -> set[str]:
    out: set[str] = set()
    if not path.exists():
        return out
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("//") or stripped.startswith("*"):
            continue
        m = DEF_RE.match(line)
        if not m:
            continue
        name = m.group(1)
        if name in SKIP_PREFIX or "::" in line[: m.start(1)] and any(
            k in line for k in ("if ", "for ", "while ")
        ):
            continue
        out.add(name)
    return out


def symbol_like(name: str) -> bool:
    """粗略判断"这像不像一个真符号"。

    局部变量不会同时带下划线又长过 7 个字符，这条规则能滤掉绝大多数
    std::string name / auto count / bool ok 之类噪声。
    """
    return "_" in name and len(name) >= 8


def identifiers(path: Path) -> set[str]:
    if not path.exists():
        return set()
    text = path.read_text(encoding="utf-8", errors="replace")
    # 去掉注释，避免把注释里的词当成引用。
    text = re.sub(r"//[^\n]*", " ", text)
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return set(IDENT_RE.findall(text))


def main() -> int:
    built_files = [CORE / p for p in PORTABLE] + [OHOS / p for p in OHOS_SOURCES]
    excluded_files = [CORE / p for p in EXCLUDED]

    defined_here: set[str] = set()
    for p in built_files:
        defined_here |= definitions(p)

    referenced_here: set[str] = set()
    for p in built_files:
        referenced_here |= identifiers(p)

    defined_excluded: dict[str, list[str]] = {}
    for p in excluded_files:
        for name in definitions(p):
            defined_excluded.setdefault(name, []).append(str(p.relative_to(ROOT)))

    print(f"已编译翻译单元: {len(built_files)}")
    print(f"未编译平台翻译单元: {len(excluded_files)}")
    print()

    # --- 检查二：可移植头文件声明的函数，本工程有没有给定义 ------------------
    # 头文件里声明、三个平台都必须满足的那些函数，缺一个就是链接错误。
    all_upstream_defs: set[str] = set()
    for p in CORE.rglob("*.cpp"):
        all_upstream_defs |= definitions(p)

    unwired = []
    for rel in PORTABLE_HEADERS:
        for name in sorted(header_declarations(CORE / rel)):
            if name in defined_here:
                continue
            if name in defined_excluded:
                unwired.append((name, rel, defined_excluded[name]))
            elif name not in all_upstream_defs:
                unwired.append((name, rel, ["<上游任何 .cpp 都没有定义>"]))

    if unwired:
        print("!! 可移植头文件里声明、本工程却没有定义的函数")
        print("-" * 72)
        for name, hdr, where in unwired:
            print(f"  {name}   (声明于 {hdr})")
            for w in where:
                print(f"      上游由 {w} 定义")
        print("-" * 72)
        print("判定：仅当调用点被 #ifdef _WIN32 包住时才是无害的；否则必须补 ohos/ 实现。")
        print()

    # --- 检查三：上游 Linux 平台文件 ↔ 我们的 OHOS 对应文件的接缝面覆盖 ------
    # 移植的验收标准不是"能编过"，而是"同一批接缝符号都被实现了"。
    # 逐对比较：上游那个文件定义的符号，我们的对应文件里有没有。
    print("--- 逐对核对：上游平台实现 → OHOS 对应实现 ---")
    print(f"{'上游文件':<44} {'我们的文件':<30} 覆盖")
    print("-" * 96)
    imperfect = 0
    for upstream_rel, ohos_rel, note in COUNTERPARTS:
        upstream_defs = definitions(CORE / upstream_rel)
        # 只比较"像符号"的名字，跳过局部变量与 lambda 捕获。
        upstream_defs = {n for n in upstream_defs if symbol_like(n)}
        ours = definitions(OHOS / ohos_rel)
        if not upstream_defs:
            print(f"{upstream_rel:<44} {ohos_rel:<30} (上游无可比符号)")
            continue
        covered = sorted(upstream_defs & ours)
        missing = sorted(upstream_defs - ours)
        tag = "全部" if not missing else f"缺 {len(missing)}"
        print(f"{upstream_rel:<44} {ohos_rel:<30} {len(covered)}/{len(upstream_defs)} {tag}")
        if missing:
            imperfect += 1
            for name in missing:
                print(f"      未实现: {name}")
            if note:
                print(f"      备注: {note}")
    print("-" * 96)
    print()

    # 只保留"像符号"的名字，并只比较**被调用**的，排除"只是同名成员"的情况。
    called_here: set[str] = set()
    for p in built_files:
        if not p.exists():
            continue
        text = re.sub(r"//[^\n]*", " ", p.read_text(encoding="utf-8", errors="replace"))
        called_here |= set(re.findall(r"\b([A-Za-z_]\w*)\s*\(", text))

    gaps = []
    for name, where in sorted(defined_excluded.items()):
        if name in defined_here:
            continue  # 本工程也定义了（例如 OhosPreviewRenderer 顶掉 LinuxPlaceboRenderer）
        if name in referenced_here and name in called_here and symbol_like(name):
            gaps.append((name, where))

    if not gaps:
        print("未发现链接缺口。")
        return 0

    print("!! 可疑链接缺口：被已编译文件引用，但只在未编译的上游平台文件里定义")
    print("-" * 72)
    for name, where in gaps:
        print(f"  {name}")
        for w in where:
            print(f"      由 {w} 定义")
    print("-" * 72)
    print()
    print("逐条判定：若该符号在 ohos/ 下有等价实现（换了名字），属正常；")
    print("否则必须补一个 ohos/ 实现并加进 CMakeLists 的 IPHONEMIRROR_CORE_OHOS_SOURCES。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
