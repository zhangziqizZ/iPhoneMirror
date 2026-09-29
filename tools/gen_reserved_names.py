#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_reserved_names.py —— 生成「ArkUI 自定义组件里不能用的属性名」清单。

用途：
  写 ArkTS 自定义组件（@Component struct）时，@Prop / @State / @BuilderParam 一旦与
  CommonMethod / CommonShapeMethod 里的属性方法同名，就会报：

    error 2416: Property 'outline' in type 'FluentSymbol' is not assignable to
                the same property in base type 'CustomComponent'.

  CompileArkTS 直接失败。这份名单把这些名字列全，起属性名前先扫一眼。

用法：
  python3 tools/gen_reserved_names.py                     # 打印到 stdout
  python3 tools/gen_reserved_names.py --markdown <输出>   # 生成完整参考文档
  python3 tools/gen_reserved_names.py --check Foo Bar     # 检查若干名字是否被占用

★ 实现上的关键点：
  common.d.ts 里 CommonMethod 每个方法都带几十行 JSDoc，JSDoc 里到处是 {@link Foo}。
  如果**不先剥掉注释**就做大括号配平，`{@link` 里的 `{` 会把 depth 加错，
  类体提前截断 —— 名单会静默地少掉一大截。

  本项目第一版就是这么错的：只抽到 157 个，漏掉了 brightness / borderColor / contrast，
  结果写 ImageSettingsWindow 时连撞三个 TS2416。所以下面必须先 strip_comments()。
"""

import argparse
import glob
import os
import re
import sys
import textwrap

DEFAULT_SDK_GLOBS = [
    os.path.expanduser('~/.harmonybrew/Cellar/ohos-sdk/*'),
    os.path.expanduser('~/Library/Huawei/Sdk/*'),
    '/opt/ohos-sdk/*',
]

# 继承链上所有会参与「属性合并」的类
CLASSES = (
    'CommonMethod',        # 210 个
    'CommonAttribute',     # 空壳
    'CommonInterface',     # 空壳
    'CommonShapeMethod',   # 11 个
    'BaseCustomComponent', # 21 个
    'CustomComponent',     # 3 个
)

KEYWORDS = ('declare', 'class', 'interface', 'extends', 'type', 'static', 'readonly')


def find_sdk(explicit=None):
    if explicit:
        return explicit
    for pattern in DEFAULT_SDK_GLOBS:
        for path in sorted(glob.glob(pattern), reverse=True):
            if os.path.isdir(os.path.join(path, 'ets', 'component')):
                return path
    raise SystemExit('找不到鸿蒙 SDK，请用 --sdk 指定')


def strip_comments(text):
    """先剥注释 —— 否则 JSDoc 里的 {@link X} 会打乱大括号配平。"""
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    text = re.sub(r'//[^\n]*', '', text)
    return text


def class_members(text, decl):
    """取某个 declare class/interface 的直接成员名。"""
    out = set()
    pattern = re.compile(r'declare (?:class|interface) ' + decl + r'(?:<[^>]*>)?[^{]*\{')
    for m in pattern.finditer(text):
        i = m.end()
        depth = 1
        j = i
        while j < len(text) and depth > 0:
            if text[j] == '{':
                depth += 1
            elif text[j] == '}':
                depth -= 1
            j += 1
        body = text[i:j - 1]
        for mm in re.finditer(
                r'(?:^|[\n;}])\s*(?:readonly\s+)?([A-Za-z_$][A-Za-z0-9_$]*)\s*[?]?\s*[(<:=]',
                body):
            name = mm.group(1)
            if name not in KEYWORDS:
                out.add(name)
    return out


def collect(sdk):
    path = os.path.join(sdk, 'ets', 'component', 'common.d.ts')
    if not os.path.isfile(path):
        raise SystemExit('找不到 ' + path)
    clean = strip_comments(open(path, encoding='utf-8', errors='replace').read())
    per_class = {}
    allnames = set()
    for cls in CLASSES:
        found = class_members(clean, cls)
        per_class[cls] = found
        allnames |= found
    return per_class, allnames


MARKDOWN_HEAD = """# ArkUI 自定义组件里不能用的 @Prop / @State / @BuilderParam 名字

自定义组件的继承链：

```
@Component struct X
  → CustomComponent              ← {n_custom} 个
      → BaseCustomComponent      ← {n_base} 个
          → CommonAttribute      ← 空壳（真正的方法在下面两个里）
              → CommonMethod     ← {n_method} 个属性方法
          → CommonShapeMethod    ← {n_shape} 个（Shape 系）
```

所以**任何 `@Prop` / `@State` 只要与这些属性方法同名，就是「同一属性在派生类里类型不兼容」**：

```
error 2416: Property 'outline' in type 'FluentSymbol' is not assignable to
            the same property in base type 'CustomComponent'.
```

`CompileArkTS` 直接失败，而且**正则扫属性名是查不出来的**——只有真类型检查能抓到。

## 怎么自己重新生成

```bash
python3 tools/gen_reserved_names.py                     # 交互式看
python3 tools/gen_reserved_names.py --check brightness  # 起名前先查
python3 tools/gen_reserved_names.py --markdown <输出.md>  # 重写本文档
```

## ⚠ 抽取时的坑

`common.d.ts` 里 `CommonMethod` 每个方法都带几十行 JSDoc，而 JSDoc 里到处是 `{{@link Foo}}`。
如果**不先剥掉注释**就直接做大括号配平，`{{@link` 里的 `{{` 会把 depth 加错，
类体被提前截断 —— 名单会静默地少掉一大截。

第一版就是这么错的：只抽到 157 个，把 `brightness`、`borderColor`、`contrast`
这一类全漏了，结果写 `ImageSettingsWindow` 时连撞三个 TS2416。
**务必用本脚本（内部先剥注释）**，现版本抽出 {n_all} 个。

## 实测撞名记录（都是真类型检查抓到的，不是推演）

| 撞的名 | 撞在哪 | 症状 | 改法 |
|---|---|---|---|
| `outline` | `FluentIcon.ets` `FluentSymbol` | TS2416 | → `iconOutline` |
| `outlineWidth` | 同上 | TS2416 | → `iconOutlineWidth` |
| `enabled` | `SubWindow.ets` `PrimaryButton` | TS2416 | → `actionEnabled` |
| `background` | `SubWindow.ets` `SubWindowShell` | TS2416 | → `shellBackground` |
| `borderColor` | `SubWindow.ets` `NoticeBanner` | TS2416 | → `bannerBorderColor` |
| `brightness` | `ImageSettingsWindow.ets` | TS2416，类型是 `{{(value:number):CommonAttribute; (brightness:number):CommonAttribute}}` | → `brightnessValue` |
| `contrast` | 同上 | TS2416 | → `contrastValue` |

**经验**：给可复用组件起属性名时，凡是「颜色 / 尺寸 / 可见性 / 文字 / 缩放 / 边框 / 布局」
这一类通用语义的词，几乎都已经被占了。稳妥做法是**一律加业务前缀**
（`icon*` / `shell*` / `banner*` / `chip*` / `notice*` / `button*` / `box*`），
既避开撞名，也让调用处一眼看出这是哪个组件的参数。

`@State` / `@Prop` / `@BuilderParam` / 自定义组件的**普通成员函数**都受这条约束；
但 `private` 的普通成员变量与普通方法**不受**（不参与属性合并）——实测确认。

## 完整名单（{n_all} 个）

```
"""

MARKDOWN_TAIL = '```\n'


def write_markdown(path, per_class, allnames):
    head = MARKDOWN_HEAD.format(
        n_custom=len(per_class['CustomComponent']),
        n_base=len(per_class['BaseCustomComponent']),
        n_method=len(per_class['CommonMethod']),
        n_shape=len(per_class['CommonShapeMethod']),
        n_all=len(allnames),
    )
    body = textwrap.fill('、'.join(sorted(allnames)), width=96)
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write(head + body + '\n' + MARKDOWN_TAIL)
    print('已写出 ' + path)
    print('名单共 {} 个'.format(len(allnames)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--sdk', default=None, help='鸿蒙 SDK 根目录')
    ap.add_argument('--markdown', default=None, help='把完整参考文档写到这个路径')
    ap.add_argument('--check', nargs='*', default=None, help='检查这些名字是否被占用')
    args = ap.parse_args()

    sdk = find_sdk(args.sdk)
    per_class, allnames = collect(sdk)

    if args.check is not None:
        bad = False
        for name in args.check:
            hit = name in allnames
            print('{:24s} {}'.format(name, '❌ 被占用，必须改名' if hit else '✅ 可用'))
            bad = bad or hit
        return 1 if bad else 0

    if args.markdown:
        write_markdown(args.markdown, per_class, allnames)
        return 0

    for cls in CLASSES:
        print('{:22s} {:4d}'.format(cls, len(per_class[cls])))
    print('{:22s} {:4d}'.format('合计（去重）', len(allnames)))
    print()
    print(textwrap.fill('、'.join(sorted(allnames)), width=96))
    return 0


if __name__ == '__main__':
    sys.exit(main())
