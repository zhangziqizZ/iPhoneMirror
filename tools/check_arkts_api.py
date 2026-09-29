#!/usr/bin/env python3
"""ArkTS API 校验器 —— 用本机 OHOS SDK 的 .d.ts 检查 .ets 里用到的属性/方法是否存在。

为什么需要它：
  ArkTS 编译要在用户设备上跑（hvigor + SDK 在 /data/app/，本工具沙箱看不到），
  但 SDK 的声明文件是完整可读的。Index.ets 里一次真实的编译错误是
      Property 'maxWidth' does not exist on type 'TextAttribute'
  —— 这类"属性名不存在"的错误完全可以在本地靠 .d.ts 静态查出来，
  不必等一轮 hvigor 构建。

做法：
  1. 扫 $SDK/ets/component/*.d.ts，收集全部组件属性方法名（XxxAttribute 的成员）；
  2. 扫 $SDK/ets/api/**/*.d.ts，收集系统 API 的导出名与方法名（白名单宽松化）；
  3. 扫目标 .ets，取出所有 `.name(` 形式的链式调用与 `name(` 形式的全局函数；
  4. 报告既不在 SDK 声明里、也不在本工程自定义里的名字。

用法：
  python3 tools/check_arkts_api.py <工程根> <SDK 根>
"""
import glob
import os
import re
import sys

# ArkTS 语言内置（不是 ArkUI 组件属性，但会出现在 .xxx( 位置）
LANGUAGE_BUILTINS = {
    'toFixed', 'toString', 'length', 'push', 'pop', 'slice', 'splice', 'map',
    'filter', 'find', 'findIndex', 'forEach', 'join', 'includes', 'indexOf',
    'trim', 'split', 'replace', 'concat', 'sort', 'reverse', 'substring',
    'substr', 'startsWith', 'endsWith', 'toUpperCase', 'toLowerCase',
    'charAt', 'charCodeAt', 'padStart', 'padEnd', 'repeat', 'getTime',
    'set', 'get', 'has', 'delete', 'clear', 'keys', 'values', 'entries',
    'then', 'catch', 'finally', 'stringify', 'parse', 'isInteger', 'isNaN',
    'floor', 'ceil', 'round', 'abs', 'max', 'min', 'pow', 'random',
    'toLocaleString', 'valueOf', 'hasOwnProperty', 'apply', 'call',
}

# ArkTS 特有/框架内置（不在 .d.ts 的组件属性里，但合法）
FRAMEWORK_BUILTINS = {
    'commands', 'viewPort',           # Shape/Path（本工程已单独验证过，仍列入以免误报）
    'onLoad', 'onSelect', 'onChange', 'onClick', 'onAppear', 'onDisappear',
    'aboutToAppear', 'aboutToDisappear', 'build', 'onPageShow', 'onPageHide',
    'onBackPress', 'onDestroy', 'onWindowStageCreate', 'onCreate',
    'getXComponentSurfaceId', 'on', 'off',
    'invalidate', 'schedule', 'request', 'cancel',
}

# JS 运行时全局函数（.ets 里可以直接用，不属于 ArkUI 声明文件）
JS_GLOBALS = {
    'setInterval', 'clearInterval', 'setTimeout', 'clearTimeout',
    'getContext', 'setImmediate', 'requestAnimationFrame', 'cancelAnimationFrame',
    'parseInt', 'parseFloat', 'isNaN', 'isFinite', 'encodeURI', 'decodeURI',
    'encodeURIComponent', 'decodeURIComponent',
    'Number', 'String', 'Boolean', 'Array', 'Object', 'JSON', 'Math', 'Date',
    'Promise', 'Error', 'TypeError', 'RangeError', 'Map', 'Set', 'WeakMap',
    'WeakSet', 'RegExp', 'Symbol', 'BigInt', 'Proxy', 'Reflect',
    'BigInt64Array', 'Uint8Array', 'Uint16Array', 'Uint32Array', 'Int32Array',
    'Float32Array', 'Float64Array', 'ArrayBuffer', 'DataView',
    'console', 'structuredClone', 'atob', 'btoa',
}

# ArkTS 装饰器（出现在 @Xxx( 位置，不是属性调用）
DECORATORS = {
    'Extend', 'Styles', 'Builder', 'Component', 'Entry', 'Preview', 'Prop',
    'State', 'Link', 'Provide', 'Consume', 'Watch', 'ObjectLink', 'Observed',
    'BuilderParam', 'Require', 'Local', 'Param', 'Event', 'Once', 'Monitor',
    'Track', 'Trace', 'Type', 'Concurrent', 'Sendable', 'AnimatableExtend',
    'LocalBuilder', 'Reusable', 'ComponentV2', 'LocalStorageLink',
    'LocalStorageProp', 'StorageLink', 'StorageProp', 'CustomDialog',
    'AnimatableExtend',
}


def collect_sdk_types(sdk_root):
    """SDK 里声明的类型名（class / interface / enum / type）——用于排除类型标注与 new。"""
    names = set()
    pattern = re.compile(
        r'^\s*(?:export\s+)?(?:declare\s+)?'
        r'(?:class|interface|enum|type|namespace|struct)\s+([A-Za-z_][A-Za-z0-9_]*)')
    for sub in ('component', 'api', 'kits'):
        base = os.path.join(sdk_root, 'ets', sub)
        for path in glob.glob(os.path.join(base, '**', '*.d.ts'), recursive=True):
            with open(path, encoding='utf-8') as fh:
                for line in fh:
                    m = pattern.match(line)
                    if m:
                        names.add(m.group(1))
    return names


def collect_imports(project_root):
    """本工程 .ets 里从模块 import 进来的符号（如 libim_core.so 的 NAPI 导出）。"""
    names = set()
    for path in glob.glob(os.path.join(project_root, 'entry', 'src', 'main',
                                       'ets', '**', '*.ets'), recursive=True):
        with open(path, encoding='utf-8') as fh:
            text = fh.read()
        for m in re.finditer(r'import\s*\{([^}]*)\}\s*from', text):
            for piece in m.group(1).split(','):
                piece = piece.strip()
                if not piece:
                    continue
                # 处理 "A as B" 形式
                alias = piece.split(' as ')
                names.add(alias[-1].strip())
        for m in re.finditer(r'import\s+([A-Za-z_][A-Za-z0-9_]*)\s+from', text):
            names.add(m.group(1))
    return names


def collect_component_attrs(sdk_root):
    """XxxAttribute 接口的成员名 = ArkUI 组件属性。"""
    names = set()
    pattern = re.compile(r'^\s{4}([a-zA-Z_][a-zA-Z0-9_]*)\s*\(')
    for path in glob.glob(os.path.join(sdk_root, 'ets', 'component', '*.d.ts')):
        with open(path, encoding='utf-8') as fh:
            for line in fh:
                m = pattern.match(line)
                if m:
                    names.add(m.group(1))
    return names


def collect_api_names(sdk_root):
    """系统 API：导出函数名、类方法名、枚举成员（宽松收集，避免误报）。"""
    names = set()
    # 缩进的方法/字段
    pattern = re.compile(r'^\s{4,8}([a-zA-Z_][a-zA-Z0-9_]*)\s*[(:]')
    # namespace 里的 function 声明（如 window.getLastWindow）
    func_pattern = re.compile(
        r'^\s*(?:export\s+)?(?:declare\s+)?function\s+([a-zA-Z_][a-zA-Z0-9_]*)')
    for path in glob.glob(os.path.join(sdk_root, 'ets', 'api', '**', '*.d.ts'),
                          recursive=True):
        with open(path, encoding='utf-8') as fh:
            for line in fh:
                m = pattern.match(line)
                if m:
                    names.add(m.group(1))
                m = func_pattern.match(line)
                if m:
                    names.add(m.group(1))
    # kits 目录也导出大量符号
    for path in glob.glob(os.path.join(sdk_root, 'ets', 'kits', '*.d.ts')):
        with open(path, encoding='utf-8') as fh:
            for line in fh:
                m = re.match(r'^\s*(?:export\s+)?(?:declare\s+)?'
                             r'(?:const|function|class|interface|enum|type)\s+'
                             r'([a-zA-Z_][a-zA-Z0-9_]*)', line)
                if m:
                    names.add(m.group(1))
    return names


def collect_local_names(project_root):
    """本工程自己定义的东西：@Builder 名、普通方法名、顶层函数、struct 名、常量名。"""
    names = set()
    for path in glob.glob(os.path.join(project_root, 'entry', 'src', 'main',
                                       'ets', '**', '*.ets'), recursive=True):
        with open(path, encoding='utf-8') as fh:
            text = fh.read()
        # @Builder / async 方法 / 普通方法 / 构造函数
        for m in re.finditer(r'^\s*(?:@Builder\s+)?(?:async\s+)?'
                             r'([a-zA-Z_][a-zA-Z0-9_]*)\s*\(', text, re.M):
            names.add(m.group(1))
        # 顶层函数与常量
        for m in re.finditer(r'^(?:export\s+)?(?:function|const|let|class|struct)\s+'
                             r'([a-zA-Z_][a-zA-Z0-9_]*)', text, re.M):
            names.add(m.group(1))
    return names


def scan_usage(path):
    """取出 .ets 里所有 `name(` 的调用名，附带行号。跳过装饰器。"""
    usages = {}
    with open(path, encoding='utf-8') as fh:
        for lineno, line in enumerate(fh, 1):
            # 去掉注释与字符串，避免把文案里的括号当调用
            code = re.sub(r'//.*$', '', line)
            code = re.sub(r"'(?:\\.|[^'\\])*'", "''", code)
            code = re.sub(r'`(?:\\.|[^`\\])*`', '``', code)
            # 装饰器 @Foo(...) 不是属性调用
            code = re.sub(r'@[A-Za-z_][A-Za-z0-9_]*', '@', code)
            for m in re.finditer(r'\b([a-zA-Z_][a-zA-Z0-9_]*)\s*\(', code):
                usages.setdefault(m.group(1), []).append(lineno)
    return usages


def main():
    project_root = sys.argv[1]
    sdk_root = sys.argv[2]

    component_attrs = collect_component_attrs(sdk_root)
    api_names = collect_api_names(sdk_root)
    sdk_types = collect_sdk_types(sdk_root)
    imported = collect_imports(project_root)
    local_names = collect_local_names(project_root)
    known = (component_attrs | api_names | sdk_types | imported | local_names
             | LANGUAGE_BUILTINS | FRAMEWORK_BUILTINS | JS_GLOBALS | DECORATORS)

    print(f'SDK 组件属性: {len(component_attrs)}')
    print(f'SDK 系统 API: {len(api_names)}')
    print(f'SDK 类型名: {len(sdk_types)}')
    print(f'本工程自定义: {len(local_names)}    本工程 import: {len(imported)}')
    print()

    targets = sorted(glob.glob(os.path.join(project_root, 'entry', 'src', 'main',
                                            'ets', '**', '*.ets'), recursive=True))
    unknown = {}
    for path in targets:
        usages = scan_usage(path)
        for name, lines in usages.items():
            if name not in known:
                unknown.setdefault(name, []).append(
                    (os.path.relpath(path, project_root), lines))

    print(f'扫描文件: {len(targets)}')
    if not unknown:
        print('✔ 未发现 SDK 声明之外的属性/方法调用')
        return 0

    print(f'✘ 发现 {len(unknown)} 个可疑名字（SDK 声明里查不到，也不是本工程自定义）：')
    print()
    for name in sorted(unknown):
        print(f'  {name}')
        for rel, lines in unknown[name]:
            head = ', '.join(str(n) for n in lines[:6])
            more = '' if len(lines) <= 6 else f' ...共 {len(lines)} 处'
            print(f'      {rel}:{head}{more}')
    print()
    print('说明：ArkUI 的组件属性都声明在 $SDK/ets/component/*.d.ts 的 XxxAttribute 接口里。')
    print('      名字查不到通常意味着该属性不存在（例如 maxWidth 只属于 constraintSize），')
    print('      需要换成正确写法；少数情况是本校验器的白名单不够，请人工确认。')
    return 1


if __name__ == '__main__':
    sys.exit(main())
