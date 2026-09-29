#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-only
//
// check_corner_profile.js —— 机型外形适配（DeviceCornerProfileResolver 移植）的回归测试。
//
// ── 为什么值得单独有一个 ────────────────────────────────────────────────────
// `ets/common/DeviceCornerProfile.ets` 是**纯函数 + 一张常量表**，没有任何 I/O、
// 不碰渲染器、不碰窗口。也就是说：它是这个工程里少数几处「本机就能给出强证据」
// 的地方之一（其余部分要么要 DevEco 构建、要么要真机）。
// 而这张表又极容易写错 —— 上游用 major/minor **两个维度**分派，
// 同代里既有全面屏也有 Home 键机型（iPhone10,3/10,6 = X，10,1/10,2/10,4/10,5 = 8），
// 还有"同代里只有某个次号保留刘海"（iPhone17,5 = 16e）。逐条对答案比肉眼复核可靠。
//
// 做法：用 SDK 自带的 patched TypeScript（ets-loader 里那份）把 .ets 直接
// transpileModule 成 JS，再在 node 里 require —— **跑的是真源码**，不是副本。
// 这与 tools/check_arkts_types.py 用的是同一个编译器、同一个思路。
//
// 用法：
//     node tools/check_corner_profile.js
//     OHOS_SDK=/path/to/ohos-sdk node tools/check_corner_profile.js
// 退出码：0 = 全部通过；1 = 有不符合项；2 = 环境不满足（此时**不能**认为代码没问题）。
'use strict';

const fs = require('fs');
const path = require('path');

const PROJECT = path.resolve(__dirname, '..');
const ETS = path.join(PROJECT, 'entry/src/main/ets/common/DeviceCornerProfile.ets');
const REL_TYPESCRIPT = 'ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js';

/** 定位 SDK 里的 typescript.js —— 与 check_arkts_types.py 的搜索顺序保持一致。 */
function find_typescript() {
  const candidates = [];
  if (process.env.OHOS_SDK) {
    candidates.push(path.join(process.env.OHOS_SDK, REL_TYPESCRIPT));
  }
  const roots = [
    path.join(process.env.HOME || '', '.harmonybrew/Cellar/ohos-sdk'),
    path.join(process.env.HOME || '', 'Library/OpenHarmony/Sdk'),
    '/opt/ohos-sdk',
  ];
  for (const root of roots) {
    if (!fs.existsSync(root) || !fs.statSync(root).isDirectory()) continue;
    // 版本目录名排序后倒序，取最新的几个；根目录本身也试一下
    const entries = fs.readdirSync(root)
      .map((name) => path.join(root, name))
      .filter((p) => fs.statSync(p).isDirectory())
      .sort()
      .reverse();
    for (const dir of entries.concat([root])) {
      candidates.push(path.join(dir, REL_TYPESCRIPT));
    }
  }
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  return null;
}

const typescriptPath = find_typescript();
if (typescriptPath === null) {
  console.error('找不到 SDK 里的 typescript.js。可用 OHOS_SDK=<sdk 根目录> 指定。');
  process.exit(2);
}
const ts = require(typescriptPath);

if (!fs.existsSync(ETS)) {
  console.error('找不到源文件：' + ETS);
  process.exit(2);
}

// 只把那一行 `import { hilog } ...` 换成空实现 —— 其余源码一字不动。
let source = fs.readFileSync(ETS, 'utf8');
const stub = 'const hilog = { info: function () {} };';
const before = source;
source = source.replace(/^import \{ hilog \} from '@kit\.PerformanceAnalysisKit';$/m, stub);
if (source === before) {
  console.error('!! 没能替换 hilog import（源文件的 import 写法变了？），测试无效');
  process.exit(2);
}

const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2019 },
  reportDiagnostics: true,
});
if (compiled.diagnostics && compiled.diagnostics.length > 0) {
  console.error('transpile 报错 ' + compiled.diagnostics.length + ' 条，测试无效');
  process.exit(2);
}
const jsPath = path.join(
  fs.mkdtempSync(path.join(require('os').tmpdir(), 'corner-')), 'mod.js');
fs.writeFileSync(jsPath, compiled.outputText);
const mod = require(jsPath);

// ── 上游决策表（由 DeviceCornerProfileResolver.cs 的分支手工推导）──────────────
// [ProductType, frameWidth, frameHeight, 期望 profile id]
const cases = [
  // iPhone10 这一代是混合代：8/8 Plus 是直角，X 才是圆角 —— 只能按次号分
  ['iPhone10,1', 0, 0, 'rectangular'],
  ['iPhone10,2', 0, 0, 'rectangular'],
  ['iPhone10,3', 0, 0, 'iphone-x'],
  ['iPhone10,4', 0, 0, 'rectangular'],
  ['iPhone10,5', 0, 0, 'rectangular'],
  ['iPhone10,6', 0, 0, 'iphone-x'],
  ['iPhone9,1', 0, 0, 'rectangular'],
  // 有刘海但非 mini/标准/Max 的
  ['iPhone11,2', 0, 0, 'iphone-notch'],
  ['iPhone12,1', 0, 0, 'iphone-notch'],
  ['iPhone13,10', 0, 0, 'iphone-notch'],
  // SE 系列仍是直角
  ['iPhone12,8', 0, 0, 'rectangular'],
  ['iPhone14,6', 0, 0, 'rectangular'],
  // iPhone13,* = iPhone 12 家族
  ['iPhone13,1', 0, 0, 'iphone-12-mini'],
  ['iPhone13,2', 0, 0, 'iphone-12-standard'],
  ['iPhone13,3', 0, 0, 'iphone-12-standard'],
  ['iPhone13,4', 0, 0, 'iphone-12-max'],
  // iPhone14,* = iPhone 12 Pro / 13 家族（14,3 上游判 standard，照搬）
  ['iPhone14,2', 0, 0, 'iphone-12-max'],
  ['iPhone14,3', 0, 0, 'iphone-12-standard'],
  ['iPhone14,4', 0, 0, 'iphone-13-mini'],
  ['iPhone14,7', 0, 0, 'iphone-12-standard'],
  ['iPhone14,5', 0, 0, 'iphone-12-standard'],
  // iPhone15,* 起进入全灵动岛；16e（17,5）是例外，保留刘海
  ['iPhone15,2', 0, 0, 'iphone-dynamic-island'],
  ['iPhone16,1', 0, 0, 'iphone-dynamic-island'],
  ['iPhone17,1', 0, 0, 'iphone-dynamic-island'],
  ['iPhone17,5', 0, 0, 'iphone-notch'],
  ['iPhone20,1', 0, 0, 'iphone-dynamic-island'],
  // iPad
  ['iPad8,1', 0, 0, 'ipad-pro-rounded'],
  ['iPad12,1', 0, 0, 'rectangular'],
  ['iPad13,1', 0, 0, 'ipad-air-rounded'],
  ['iPad13,2', 0, 0, 'ipad-air-rounded'],
  ['iPad13,4', 0, 0, 'ipad-pro-rounded'],
  ['iPad13,18', 0, 0, 'ipad-rounded'],
  ['iPad13,19', 0, 0, 'ipad-rounded'],
  ['iPad14,1', 0, 0, 'ipad-mini-rounded'],
  ['iPad14,2', 0, 0, 'ipad-mini-rounded'],
  ['iPad14,8', 0, 0, 'ipad-air-rounded'],
  ['iPad14,3', 0, 0, 'ipad-pro-rounded'],
  ['iPad15,4', 0, 0, 'ipad-air-rounded'],
  ['iPad15,7', 0, 0, 'ipad-rounded'],
  ['iPad16,1', 0, 0, 'ipad-mini-rounded'],
  ['iPad16,8', 0, 0, 'ipad-air-rounded'],
  ['iPad17,1', 0, 0, 'ipad-pro-rounded'],
  ['iPad18,1', 0, 0, 'ipad-rounded'],
  // 非移动设备 / 不认识的一律直角
  ['AppleTV6,2', 0, 0, 'rectangular'],
  ['iPod9,1', 0, 0, 'rectangular'],
  // 前缀大小写不敏感；格式不合法 = 解析失败
  ['iphone13,2', 0, 0, 'iphone-12-standard'],
  ['IPAD13,1', 0, 0, 'ipad-air-rounded'],
  ['iPhone13', 0, 0, 'rectangular'],
  ['iPhone13,', 0, 0, 'rectangular'],
  ['iPhone,2', 0, 0, 'rectangular'],
  // 没有 ProductType 才看几何
  ['', 1206, 2622, 'iphone-dynamic-island'],
  ['', 800, 1200, 'ipad-rounded'],
  ['', 1000, 1000, 'rectangular'],
  ['', 0, 0, 'rectangular'],
];

// [ProductType, frameW, frameH, 期望] —— 走 for_frame 那一层（带 1206×2622 兜底）
const frameCases = [
  ['', 0, 0, 'iphone-dynamic-island'],
  ['', 800, 1200, 'ipad-rounded'],
  ['iPad13,1', 0, 0, 'ipad-air-rounded'],
  ['iPhone17,5', 0, 0, 'iphone-notch'],
];

// [输入, 期望] —— looks_like_product_type
const shapeCases = [
  ['iPhone17,5', true],
  ['iPad13,1', true],
  ['AppleTV6,2', true],
  ['iPod9,1', true],
  ['—', false],
  ['', false],
  ['型号读取中', false],
  ['iPhone13', false],
  ['iPhone,2', false],
  ['iPhone13,', false],
  ['13,2', false],
  ['iPhone 13,2', false],
];

let failures = 0;

for (const c of cases) {
  const got = mod.resolve_corner_profile(c[0], c[1], c[2]).id;
  if (got !== c[3]) {
    failures++;
    console.log('FAIL  resolve_corner_profile(' + JSON.stringify(c[0]) + ', ' + c[1] + ', ' + c[2]
      + ')  期望 ' + c[3] + '，实际 ' + got);
  }
}
for (const c of frameCases) {
  const got = mod.resolve_corner_profile_for_frame(c[0], c[1], c[2]).id;
  if (got !== c[3]) {
    failures++;
    console.log('FAIL  resolve_corner_profile_for_frame(' + JSON.stringify(c[0]) + ', '
      + c[1] + ', ' + c[2] + ')  期望 ' + c[3] + '，实际 ' + got);
  }
}
for (const c of shapeCases) {
  const got = mod.looks_like_product_type(c[0]);
  if (got !== c[1]) {
    failures++;
    console.log('FAIL  looks_like_product_type(' + JSON.stringify(c[0]) + ')  期望 ' + c[1]
      + '，实际 ' + got);
  }
}

// ── 数值面：半径、超椭圆指数、窗口圆角算式 ───────────────────────────────────
const iphoneX = mod.resolve_corner_profile('iPhone10,3', 0, 0);
if (Math.abs(iphoneX.preview_radius() - 0.1460) > 1e-9) {
  failures++;
  console.log('FAIL  iphone-x 的归一化半径应为 0.1460，实际 ' + iphoneX.preview_radius());
}
if (Math.abs(iphoneX.curveExponent - 2.15) > 1e-9) {
  failures++;
  console.log('FAIL  iphone-x 的超椭圆指数应为 2.15，实际 ' + iphoneX.curveExponent);
}
// 上游 GetGdiRadius：400 × 0.1320 = 52.8 → 53
const windowRadius = iphoneX.window_radius(400, 1.0);
if (windowRadius !== 53) {
  failures++;
  console.log('FAIL  iphone-x 在短边 400vp 下的窗口圆角应为 53，实际 ' + windowRadius);
}
// 极小窗口走 minimum 下限：min(10×0.2, 6×max(0.5,1)) = 2；fitted = 1.32 → 取 2
const tinyRadius = iphoneX.window_radius(10, 1.0);
if (tinyRadius !== 2) {
  failures++;
  console.log('FAIL  iphone-x 在短边 10vp 下的窗口圆角应为 2，实际 ' + tinyRadius);
}
// 直角机型：两条路都必须是 0（"不圆角"的唯一表达就是半径 0）
const square = mod.resolve_corner_profile('iPhone12,8', 0, 0);
if (square.preview_radius() !== 0) {
  failures++;
  console.log('FAIL  直角机型的 preview_radius 应为 0');
}
if (square.window_radius(400, 1.0) !== 0) {
  failures++;
  console.log('FAIL  直角机型的 window_radius 应为 0');
}
// 这条是"调用方为什么必须先做 looks_like_product_type"的直接证据：
// 界面占位符 '—' 直接喂进去会命中"非空但不认识 ⇒ 直角"，把机型拟合整个吃掉。
if (mod.resolve_corner_profile('—', 0, 0).id !== 'rectangular') {
  failures++;
  console.log('FAIL  前提已变：\'—\' 不再被判为直角，current_product_type 的过滤逻辑需要重新评估');
}

const total = cases.length + frameCases.length + shapeCases.length + 7;
if (failures === 0) {
  console.log('机型轮廓：全部通过（' + total + ' 项）');
  process.exit(0);
}
console.log('机型轮廓：' + failures + ' 项不符（共 ' + total + ' 项）');
process.exit(1);
