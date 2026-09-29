#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_alias_narrowing.py —— 抓「靠布尔别名收窄」的写法。

背景（2026-09-22 真机构建翻车）：
    **tsc 会**把 `const p = a !== undefined && b !== undefined;` 记成"保留的条件"，随后
    `if (p) { f(a, b) }` 里 `a/b` 自动收窄；**ArkTS 编译器不会** —— 它只按每个变量自己
    的声明类型判定，于是真构建报：

        10605999 ArkTS Compiler Error
        Argument of type 'number | undefined' is not assignable to parameter of type 'number'.
        At File: .../ReverseControlInput.ets:710:23

    本工程的 `tools/check_arkts_types.py`（走 tsc）**会放过**这种写法 ⇒
    "自检 0 错误"不等于"能编过"。这个脚本专门补这个盲区。

它做什么：
    找 `const <名> [ : 类型 ] = <含 `!== undefined` / `!== null` 的表达式>`，
    取出该表达式里被比较的标识符；再在其后若干行内找 `if (<名> ...)` 的分支里
    对这些标识符的**非比较用法**（当参数传、赋值给字段、参与算术）⇒ 报嫌疑点。
    命中即需人工确认：把 `!== undefined` 直接写进那个 `if` 条件即可消除。

用法：
    python3 tools/check_alias_narrowing.py .            # 退出码 0=无, 1=有嫌疑
"""
import os
import re
import sys

SKIP_DIRS = {'node_modules', 'build', '.git', 'oh_modules', '.hvigor', 'third_party'}

CONST_RE = re.compile(
    r'^\s*(?:const|let)\s+([A-Za-z_$][\w$]*)\s*(?::\s*[^=]+)?=\s*(.+?);\s*$')
COMPARE_RE = re.compile(r'([A-Za-z_$][\w$]*)\s*!==\s*(?:undefined|null)')
IF_BOOL_RE = r'\bif\s*\(\s*%s\b'
WINDOW = 60            # 别名的有效观察窗口（行）


def scan_file(path):
    with open(path, encoding='utf-8') as fh:
        lines = fh.read().split('\n')
    hits = []
    for i, line in enumerate(lines):
        m = CONST_RE.match(line)
        if not m:
            continue
        name, rhs = m.group(1), m.group(2)
        if '!== undefined' not in rhs and '!== null' not in rhs:
            continue
        ids = sorted(set(COMPARE_RE.findall(rhs)))
        if not ids:
            continue
        # 别名的每个 `if` 都要看（不能只看第一个：真正出事的那处常在后面）
        if_re = re.compile(IF_BOOL_RE % re.escape(name))
        for j in range(i + 1, min(i + 1 + WINDOW, len(lines))):
            if not if_re.search(lines[j]):
                continue
            # 该 if 起算的 8 行内，看这些标识符有没有被"当值用"
            for k in range(j, min(j + 8, len(lines))):
                body = lines[k]
                if k == j:
                    body = body.split(name, 1)[-1]      # 跳过条件里的别名自身
                for ident in ids:
                    # 参数位置 / 逗号右邻 / 赋值右侧 / 算术 —— 都是"当值用"
                    if re.search(r'\b%s\s*[,)]' % re.escape(ident), body) \
                       or re.search(r'=\s*[^=;]*\b%s\b' % re.escape(ident), body) \
                       or re.search(r'\b%s\b\s*[+\-*/]' % re.escape(ident), body):
                        hit = (path, k + 1, name, ident, lines[k].strip())
                        if hit not in hits:
                            hits.append(hit)
    return hits


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else '.'
    total = 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if not fn.endswith('.ets'):
                continue
            p = os.path.join(dirpath, fn)
            for path, ln, alias, ident, text in scan_file(p):
                total += 1
                print('%s:%d  嫌疑：`%s` 依赖 `%s !== undefined`，但其 `if` 之后把 `%s` 当值用了'
                      % (path, ln, alias, ident, ident))
                print('             %s' % text)
                print('             改法：把 `%s !== undefined` 直接写进那个 if 条件'
                      % ident)
    print('------------------------------------------------------------')
    print('结果: %d 处嫌疑' % total)
    return 1 if total else 0


if __name__ == '__main__':
    sys.exit(main())
