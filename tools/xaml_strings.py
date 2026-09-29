#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
xaml_strings.py —— 从原版 XAML 里抽出所有 {DynamicResource X} 键，并回填 zh-CN 文案。

移植时每个窗口都要做同一件事：读 XAML -> 找出引用的资源键 -> 查 Strings.zh-CN.xaml
里的中文文案。手工做又慢又容易漏，所以工具化。

用法：
    python3 tools/xaml_strings.py <xaml 或 xaml.cs 文件…>
    python3 tools/xaml_strings.py --keys KeyA KeyB      # 只查指定键
    python3 tools/xaml_strings.py --all-window ImageSettingsWindow

输出按 XAML 里出现的顺序列出「键 = 值」，同时标出【缺失】的键
（缺失说明该键不在 zh-CN 字典里，需要去别处找，别凭空编）。
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)

APP_STRINGS = os.path.join(
    PROJ, '..', '..', 'iPhoneMirror-main', 'iPhoneMirror-main',
    'src', 'App', 'Localization', 'Strings.zh-CN.xaml')
# 上游仓库可能以别的方式摆放，这里再做几次探测
CANDIDATES = [
    APP_STRINGS,
    os.path.expanduser(
        '~/Desktop/iPhoneMirror-main/iPhoneMirror-main/src/App/Localization/Strings.zh-CN.xaml'),
    '/storage/Users/currentUser/Desktop/iPhoneMirror-main/iPhoneMirror-main/src/App/Localization/Strings.zh-CN.xaml',
]

WINDOWS_DIR_CANDIDATES = [
    os.path.expanduser('~/Desktop/iPhoneMirror-main/iPhoneMirror-main/src/App/Windows'),
    '/storage/Users/currentUser/Desktop/iPhoneMirror-main/iPhoneMirror-main/src/App/Windows',
]


def find_strings_file() -> str:
    for c in CANDIDATES:
        if os.path.isfile(c):
            return c
    raise SystemExit('找不到 Strings.zh-CN.xaml，请用 --strings 指定')


def load_strings(path: str) -> dict:
    with open(path, 'r', encoding='utf-8') as f:
        text = f.read()
    out = {}
    # <system:String x:Key="Foo">值</system:String>
    for m in re.finditer(
            r'<system:String\s+x:Key="([^"]+)"\s*>(.*?)</system:String>', text, re.S):
        out[m.group(1)] = m.group(2).strip()
    # <FontFamily x:Key="Foo">值</FontFamily> 之类
    for m in re.finditer(
            r'<(\w+)\s+x:Key="([^"]+)"\s*>(.*?)</\1>', text, re.S):
        out.setdefault(m.group(2), m.group(3).strip())
    return out


DYNAMIC_RE = re.compile(r'\{(?:DynamicResource|StaticResource)\s+([A-Za-z0-9_.]+)\s*\}')
XKEY_RE = re.compile(r'x:Key="([^"]+)"')


def keys_in_file(path: str):
    with open(path, 'r', encoding='utf-8') as f:
        text = f.read()
    seen = []
    for m in DYNAMIC_RE.finditer(text):
        k = m.group(1)
        if k not in seen:
            seen.append(k)
    return seen


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1

    strings = load_strings(find_strings_file())

    # --keys 模式
    if argv[1] == '--keys':
        keys = argv[2:]
        files = []
    elif argv[1] == '--all-window':
        name = argv[2]
        if not name.endswith('.xaml'):
            name += '.xaml'
        files = []
        for d in WINDOWS_DIR_CANDIDATES:
            p = os.path.join(d, name)
            if os.path.isfile(p):
                files = [p]
                break
        if not files:
            print('找不到窗口文件: ' + name)
            return 1
        keys = []
    else:
        files = argv[1:]
        keys = []

    for path in files:
        if not os.path.isfile(path):
            print('找不到文件: ' + path)
            continue
        ks = keys_in_file(path)
        print('=== {} （{} 个资源键）==='.format(os.path.basename(path), len(ks)))
        for k in ks:
            v = strings.get(k)
            if v is None:
                print('  {:52s} 【缺失】'.format(k))
            else:
                print('  {:52s} {}'.format(k, v))
        print()

    if keys:
        print('=== 指定键 ===')
        for k in keys:
            v = strings.get(k)
            print('  {:52s} {}'.format(k, v if v is not None else '【缺失】'))

    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
