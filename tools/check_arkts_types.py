#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_arkts_types.py —— 本地复现 `CompileArkTS` 的**真类型检查**。

背景
----
`hvigor`/DevEco 不在本机可访问路径下（`/data/app/hvigor.org/` Permission denied），
但 `CompileArkTS` 报的错绝大多数是纯 TypeScript 语义错误（例如
`Property 'maxWidth' does not exist on type 'TextAttribute'`），完全可以在本地查。
本机 `~/.harmonybrew` 里的 OHOS SDK 自带 ets-loader，而 ets-loader 又自带一份
OpenHarmony 打过补丁的 TypeScript（`typescript@4.9.5-r4`），它认得 ArkTS 的
`struct` / `@Component` / `@Builder` 语法。于是：

    SDK 的 patched TS  +  SDK 的 ArkUI 声明（ets/component/*.d.ts）  +  工程源码
    →  ==  CompileArkTS 的语义检查结果

注意：**必须走 `typescript.js` 的 API，不能用 `tsc.js` CLI**。ETS 检查器里
`checkIfChildComponent()` 依赖 `node.getChildren()`，而该方法只由 TypeScript 的
services 层安装（`typescript.js` 48 处 / `tsc.js` 5 处，全为调用点）。
用 CLI 跑时，只要 `build()` 里出现裸 `if` 就会 `TypeError: node.getChildren is
not a function` 崩掉，而且**退出码是 0、不产生任何诊断** —— 一个静默的假阴性。
详见 `tools/arkts_typecheck/arkts_check.js`。

用法
----
    python3 tools/check_arkts_types.py [工程根] [--json] [-q] [--all]
    # 环境变量 OHOS_SDK 可指定 SDK 根目录

退出码
------
    0 = 无错误（且编译器正常跑完）
    1 = 有真实诊断
    2 = 环境不满足 / 工具自身失败（此时**不能**认为代码没问题）
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_PROJECT = HERE.parent
DRIVER = HERE / "arkts_typecheck" / "arkts_check.js"

NODE_CANDIDATES = [
    "/data/storage/el1/bundle/libs/arm64/node/bin/node",
    shutil.which("node"),
]


def find_node() -> str | None:
    for c in NODE_CANDIDATES:
        if c and Path(c).exists():
            return c
    return None


def find_sdk() -> Path | None:
    """定位 SDK 根：含 ets/build-tools/ets-loader/node_modules/typescript。"""
    env = os.environ.get("OHOS_SDK")
    if env:
        p = Path(env)
        if (p / "ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js").exists():
            return p

    roots = [
        Path.home() / ".harmonybrew" / "Cellar" / "ohos-sdk",
        Path.home() / "Library" / "OpenHarmony" / "Sdk",
        Path("/opt") / "ohos-sdk",
    ]
    for root in roots:
        if not root.is_dir():
            continue
        cands = sorted([p for p in root.iterdir() if p.is_dir()], reverse=True) + [root]
        for c in cands:
            if (c / "ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js").exists():
                return c
    return None


def collect_source_files(project: Path) -> list[str]:
    """只把**工程自己的**源码交给编译器；SDK 声明按需自动载入。"""
    files: list[str] = []
    ets_root = project / "entry/src/main/ets"
    for pat in ("**/*.ets", "**/*.ts"):
        files += [str(p) for p in sorted(ets_root.glob(pat))]
    return files


def napi_types_entry(project: Path) -> Path | None:
    """按 oh-package.json5 的 `types` 字段取 NAPI 声明的**确切文件**。

    不能把目录交给 paths —— 那样 TypeScript 会按 node 解析规则去找 `index.d.ts`，
    而实际文件是 `Index.d.ts`（大写 I），于是同一文件以两种大小写进 program，
    报 TS1261 `... differs from file name ... only in casing`。
    """
    napi = project / "entry/src/main/cpp/types/libim_core"
    if not napi.is_dir():
        return None
    pkg = napi / "oh-package.json5"
    if pkg.exists():
        import re as _re
        m = _re.search(r'"types"\s*:\s*"([^"]+)"', pkg.read_text(encoding="utf-8"))
        if m:
            cand = (napi / m.group(1)).resolve()
            if cand.exists():
                return cand
    fallback = napi / "Index.d.ts"
    return fallback if fallback.exists() else None


def arkts_global_decls(sdk: Path) -> list[str]:
    """ArkTS 运行时全局声明。

    `setInterval` / `clearInterval` / `console` 等不是 ArkUI 组件属性，而在
    `ets-loader/declarations/global.d.ts` 里以 ambient `declare function` 形式给出。
    不带上它就会误报 `TS2304: Cannot find name 'setInterval'`。
    """
    decl = sdk / "ets/build-tools/ets-loader/declarations"
    out: list[str] = []
    for name in ("global.d.ts", "common_ts_ets_api.d.ts"):
        p = decl / name
        if p.exists():
            out.append(str(p))
    return out


def build_tsconfig(project: Path, sdk: Path, src_files: list[str]) -> dict:
    paths = {
        "@ohos.*": [str(sdk / "ets/api/@ohos.*")],
        "@kit.*": [str(sdk / "ets/kits/@kit.*")],
    }
    napi = napi_types_entry(project)
    if napi is not None:
        paths["libim_core.so"] = [str(napi)]

    return {
        # 继承 ets-loader 的 tsconfig，以取得 `ets` 编译选项（struct / 装饰器表）——
        # 这是让裸 TypeScript 解析 ArkTS 语法的关键。
        "extends": str(sdk / "ets/build-tools/ets-loader/tsconfig.json"),
        "__sdkTypescriptDir": str(sdk / "ets/build-tools/ets-loader/node_modules/typescript/lib"),
        "compilerOptions": {
            "target": "es2021",
            "module": "commonjs",
            "moduleResolution": "node",
            "lib": ["es2021"],
            "types": [],
            "typeRoots": [],
            "skipLibCheck": True,
            "noEmit": True,
            "allowJs": True,
            "esModuleInterop": True,
            "allowSyntheticDefaultImports": True,
            "experimentalDecorators": True,
            "resolveJsonModule": True,
            "noImplicitAny": False,
            "alwaysStrict": True,
            "baseUrl": str(project),
            "paths": paths,
        },
        # ArkUI 组件/枚举声明（Column / Text / TextAttribute / Shape / Path ...）
        # 与 ArkTS 运行时全局声明，显式列进 files。
        "files": src_files
        + arkts_global_decls(sdk)
        + [str(p) for p in sorted((sdk / "ets/component").glob("*.d.ts"))],
    }


def relproject(p: str, project: Path) -> str:
    try:
        return str(Path(p).resolve().relative_to(project))
    except Exception:
        return p


def main() -> int:
    ap = argparse.ArgumentParser(description="ArkTS 真类型检查（复用 SDK 内 patched TypeScript）")
    ap.add_argument("project", nargs="?", default=str(DEFAULT_PROJECT))
    ap.add_argument("--json", action="store_true")
    ap.add_argument("-q", "--quiet", action="store_true")
    ap.add_argument("--all", action="store_true",
                    help="同时显示 SDK 声明文件里的诊断（默认过滤，本工程管不到）")
    args = ap.parse_args()

    project = Path(args.project).resolve()
    if not (project / "entry/src/main/ets").is_dir():
        print(f"[x] 不是 OHOS 工程：{project}", file=sys.stderr)
        return 2

    sdk = find_sdk()
    if sdk is None:
        print("[x] 找不到 OHOS SDK（可用 OHOS_SDK 指定）", file=sys.stderr)
        return 2
    node = find_node()
    if node is None:
        print("[x] 找不到 node", file=sys.stderr)
        return 2
    if not DRIVER.exists():
        print(f"[x] 缺少驱动器 {DRIVER}", file=sys.stderr)
        return 2

    src_files = collect_source_files(project)
    cfg = build_tsconfig(project, sdk, src_files)

    with tempfile.TemporaryDirectory(prefix="arkts-typecheck-") as td:
        cfg_path = Path(td) / "tsconfig.json"
        cfg_path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
        proc = subprocess.run(
            [node, str(DRIVER), str(cfg_path)],
            cwd=str(project), capture_output=True, text=True,
        )

    raw = (proc.stdout or "").strip()
    if not raw:
        print("[x] 驱动器没有输出，stderr：", file=sys.stderr)
        print((proc.stderr or "")[:3000], file=sys.stderr)
        return 2
    try:
        result = json.loads(raw.splitlines()[-1])
    except json.JSONDecodeError:
        print("[x] 驱动器输出无法解析：", file=sys.stderr)
        print(raw[:3000], file=sys.stderr)
        return 2

    if not result.get("ok"):
        print(f"[x] 工具自身失败：{result.get('crash')}", file=sys.stderr)
        return 2

    sdk_prefix = str(sdk)
    diags = []
    for d in result.get("diagnostics", []):
        f = relproject(d["file"], project)
        is_sdk = Path(d["file"]).is_absolute() and str(d["file"]).startswith(sdk_prefix)
        d = dict(d, file=f, is_sdk=is_sdk)
        if is_sdk and not args.all:
            continue
        diags.append(d)

    crash = result.get("crash")
    errors = [d for d in diags if d.get("category") != "Warning"]
    warnings = [d for d in diags if d.get("category") == "Warning"]

    if args.json:
        print(json.dumps({
            "project": str(project), "sdk": str(sdk),
            "ts_version": result.get("tsVersion"),
            "file_count": result.get("fileCount"),
            "error_count": len(errors), "warning_count": len(warnings),
            "harness_crash": crash, "diagnostics": diags,
        }, ensure_ascii=False, indent=2))
        return 0 if (not errors and not crash) else (2 if crash else 1)

    if not args.quiet:
        print(f"工程   : {project}")
        print(f"SDK    : {sdk}")
        print(f"编译器 : typescript@{result.get('tsVersion')}  (SDK 内 ets-loader 自带，OpenHarmony 补丁版)")
        print(f"源文件 : {len(src_files)} 个")
        print("-" * 68)

    for d in diags:
        tag = "warning" if d.get("category") == "Warning" else "error"
        print(f"{d['file']}({d['line']},{d['col']}): {tag} {d['code']}: {d['message']}")
    if not diags and not args.quiet:
        print("（无诊断）")

    if crash:
        if not args.quiet:
            print("-" * 68)
        print("⚠ 编译器内部异常，结果不可信：")
        for ln in crash.splitlines()[:12]:
            print("   " + ln)

    if not args.quiet:
        print("-" * 68)
    if crash:
        print(f"结果: 工具失败（{len(diags)} 条可能的诊断）⚠  不能据此判断代码是否正确")
        return 2
    print(f"结果: {len(errors)} 个错误, {len(warnings)} 个警告"
          + (" ✅" if not errors else " ❌"))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
