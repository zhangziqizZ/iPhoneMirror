#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sync_project.py —— 把主工程同步到工作区镜像。

本项目的规矩：**主工程在 ~/Desktop/iPhoneMirror-ohos，工作区里放一份镜像**，
方便在 WorkBuddy 里直接看/改，也避免手滑把工作区当成唯一副本。

同步规则：
  · 只同步「源码 + 文档 + 工具」，不含构建产物；
  · 跳过目录：.hvigor / .build-check / .bitfun / oh_modules / build / node_modules / .git；
  · 默认只做增量复制（按 mtime + 大小判断），--force 全量覆盖；
  · 默认 --dry-run 只在 --apply 时真正写盘，避免误伤。

用法：
  python3 tools/sync_project.py                     # 预演，列出要同步的文件
  python3 tools/sync_project.py --apply             # 真正同步
  python3 tools/sync_project.py --apply --force     # 忽略 mtime，全部覆盖
  python3 tools/sync_project.py --to <目标目录>      # 换目标
"""

import argparse
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# tools/ 的上一级就是工程根
DEFAULT_SRC = os.path.dirname(HERE)
DEFAULT_DST = '/storage/Users/currentUser/WorkBuddy/2026-09-13-09-38-25/iPhoneMirror-ohos'

SKIP_DIRS = {
    '.hvigor', '.build-check', '.bitfun', 'oh_modules', 'build',
    'node_modules', '.git', '.idea', '.cxx', '__pycache__',
}
SKIP_FILES = {'.DS_Store'}


def iter_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            if name in SKIP_FILES:
                continue
            full = os.path.join(dirpath, name)
            yield os.path.relpath(full, root), full


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src', default=DEFAULT_SRC)
    ap.add_argument('--to', default=DEFAULT_DST)
    ap.add_argument('--apply', action='store_true', help='真正写盘（默认只是预演）')
    ap.add_argument('--force', action='store_true', help='忽略 mtime，全部覆盖')
    args = ap.parse_args()

    src = os.path.abspath(args.src)
    dst = os.path.abspath(args.to)
    if not os.path.isdir(src):
        raise SystemExit('源目录不存在: ' + src)
    if not os.path.isdir(dst):
        raise SystemExit('目标目录不存在: ' + dst)

    copied = []
    same = 0
    for rel, full in sorted(iter_files(src)):
        target = os.path.join(dst, rel)
        need = args.force or (not os.path.isfile(target))
        if not need:
            a, b = os.stat(full), os.stat(target)
            need = (int(a.st_mtime) != int(b.st_mtime)) or (a.st_size != b.st_size)
        if not need:
            same += 1
            continue
        copied.append(rel)
        if args.apply:
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copy2(full, target)

    # 反向检查：目标里有没有源里已经删掉的文件
    extra = []
    for rel, full in sorted(iter_files(dst)):
        if not os.path.isfile(os.path.join(src, rel)):
            extra.append(rel)

    mode = '已同步' if args.apply else '待同步（预演，加 --apply 才写盘）'
    print('源    : ' + src)
    print('目标  : ' + dst)
    print('{}: {} 个文件'.format(mode, len(copied)))
    for rel in copied:
        print('   + ' + rel)
    print('内容一致未动: {} 个文件'.format(same))
    if extra:
        print('⚠ 目标里多出（源里已删除）：')
        for rel in extra:
            print('   - ' + rel)
    return 0


if __name__ == '__main__':
    sys.exit(main())
