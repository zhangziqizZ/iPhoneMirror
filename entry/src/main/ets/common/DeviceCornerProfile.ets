// SPDX-License-Identifier: GPL-3.0-only
//
// 机型外形适配 —— 上游两份文件的逐行移植：
//   src/App/Models/DeviceCornerProfile.cs      （轮廓描述 + GDI 半径换算）
//   src/App/Services/DeviceCornerProfileResolver.cs（179 行：ProductType → 轮廓）
//
// ── 上游怎么用它（MultiDevicePreviewManager.cs:148-153）──────────────────────
//   var profile = DeviceCornerProfileResolver.Resolve(device.ProductType, 1206, 2622);
//   var cornerRadius = profile.IsRounded ? profile.RadiusRatio : 0;
//   NativeCore.SetDeviceCornerProfile(started.Handle, cornerRadius, profile.CurveExponent);
//   NativeCore.SetDeviceWindowCornerProfile(..., _cornersEnabled ? _cornerRadius : 0,
//                                                _cornerExponent);
// 注意最后一行：**右键菜单的「去除圆角」就是把 radius 传 0**（NativePreviewWindow.cs:404-405
// 的 `_cornersEnabled ? _cornerRadius : 0`）。本移植照这个做法，不另造开关体系。
//
// ── 鸿蒙侧落点：**纯 ArkTS，C++ 一行不用改** ─────────────────────────────────
// CoreApi.h:362-368 写得很清楚：`im_set_preview_corner_profile` 是
// "the display-outline fit used by a **borderless top-level preview**"，
// `normalized_radius` 相对短边，`curve_exponent` ∈ [1.5, 8] 是超椭圆指数。
// 而鸿蒙的 OhosPreviewRenderer.cpp 里**已经实现完了**：
//   · set_corner_profile() 存两个原子量（:748-752）
//   · 片元着色器按超椭圆裁剪，圆角外 alpha 置 0（:94 / :106-132）
//   · draw 里 radius = normalized_radius × min(surface 短边)（:493-495 / :511-512）
// napi 也已导出 `setPreviewCornerProfile(normalizedRadius, curveExponent)`
// （cpp/types/libim_core/Index.d.ts:135）。缺的只是"谁来算这两个数" —— 就是本文件。
//
// ── 两条刻意的口径（不照抄上游的地方，写在这里免得下次又猜）────────────────
//  1. **只作用于独立窗口，不作用于主窗口预览区**。契约把这条接口限定为
//     "borderless top-level preview"，而主窗口的预览区是**定宽面板**（画面必然
//     letterbox），着色器却按 surface 短边算半径 —— 在那里调用会把圆角放大成
//     两倍多，看起来像个胶囊而不是手机。上游同样只在独立窗口那条路上用它。
//     ⇒ 独立窗口开时套用，关时把半径复位成 0（见 StandalonePreviewWindow.finish）。
//  2. 上游在 `Resolve(..., 1206, 2622)` 里**硬编码**了一组 iPhone 12/13 的分辨率
//     当作几何兜底的入参，效果是"不认识的新机型一律按 Dynamic Island 拟合"。
//     本移植优先用渲染器实测的真实帧尺寸（更诚实），只有拿不到时才回退到
//     同一组 1206×2622，保证"未知机型"的结论与上游一致。
//
// ── 这些数字是什么 ─────────────────────────────────────────────────────────
// 上游注释原话：**视觉拟合，不是 Apple 公布的工业尺寸**。Apple 只公布机型
// 外观图与"屏幕是否有圆角"，不公布数值半径。所以这里是一份可整体替换的拟合表，
// 将来若有官方外观数据，只改这个文件即可，不必碰渲染器与窗口代码。

import { hilog } from '@kit.PerformanceAnalysisKit';
import { t } from './i18n';

const DOMAIN: number = 0x0100;
const TAG: string = 'im_corner_profile';

/**
 * 一个机型族的显示轮廓拟合。
 *
 * 对应上游 `readonly record struct DeviceCornerProfile(Id, IsRounded,
 * RadiusRatio, CurveExponent, GdiRadiusRatio)`。字段名一一对应，含义：
 *   radiusRatio    —— 圆角半径 **相对短边** 的比例，直接喂给
 *                     `setPreviewCornerProfile(normalizedRadius, ...)`。
 *   curveExponent  —— 超椭圆指数（2 = 正圆角，越大越"方"），同上传。
 *   gdiRadiusRatio —— 窗口**轮廓**（非画面）的圆角比例，上游用它算 GDI region；
 *                     本移植用它算 `window.setWindowCornerRadius()`。
 */
export class DeviceCornerProfile {
  id: string = '';
  isRounded: boolean = false;
  radiusRatio: number = 0;
  curveExponent: number = 2;
  gdiRadiusRatio: number = 0;

  constructor(id: string, isRounded: boolean, radiusRatio: number,
              curveExponent: number, gdiRadiusRatio: number) {
    this.id = id;
    this.isRounded = isRounded;
    this.radiusRatio = radiusRatio;
    this.curveExponent = curveExponent;
    this.gdiRadiusRatio = gdiRadiusRatio;
  }

  /**
   * 喂给渲染器的归一化半径：不圆角就是 0（对应上游
   * `profile.IsRounded ? profile.RadiusRatio : 0`）。
   */
  preview_radius(): number {
    return this.isRounded ? this.radiusRatio : 0;
  }

  /**
   * 窗口轮廓圆角（vp）—— 上游 `GetGdiRadius(shortEdge, dpiScale)` 的移植，
   * 只把"像素"换成"vp"（本工程的窗口 API 收 vp；代入的是 vp 短边即可，算式不变）。
   *
   * 上游原式：fitted = shortEdge × clamp(GdiRadiusRatio, 0, 0.5)；
   * minimum = min(shortEdge × 0.20, 6.0 × max(0.5, dpiScale))；
   * return max(1, round(max(fitted, minimum)))。
   * 那条 minimum 的用意（上游注释）：缩得很小的预览窗也要有足够抗锯齿的圆角，
   * 不至于看起来还是个方角；但又不能让这个下限盖过正常窗口。
   */
  window_radius(shortEdge: number, dpiScale: number): number {
    if (!this.isRounded || shortEdge <= 0) {
      return 0;
    }
    const ratio: number = clamp(this.gdiRadiusRatio, 0, 0.5);
    const fitted: number = shortEdge * ratio;
    const minimum: number = Math.min(shortEdge * 0.20, 6.0 * Math.max(0.5, dpiScale));
    return Math.max(1, Math.round(Math.max(fitted, minimum)));
  }
}

function clamp(value: number, low: number, high: number): number {
  if (value < low) {
    return low;
  }
  return value > high ? high : value;
}

/** 直角兜底：Home 键机型、旧款 iPad、以及"无法判断"的一切。 */
export const CORNER_RECTANGULAR: DeviceCornerProfile =
  new DeviceCornerProfile('rectangular', false, 0, 2, 0);

// ── 机型族表（数值与上游 DeviceCornerProfileResolver.cs:18-39 完全一致）──────
const CORNER_IPHONE_X: DeviceCornerProfile =
  new DeviceCornerProfile('iphone-x', true, 0.1460, 2.15, 0.1320);
const CORNER_IPHONE_NOTCH: DeviceCornerProfile =
  new DeviceCornerProfile('iphone-notch', true, 0.1580, 2.25, 0.1420);
const CORNER_IPHONE_12_MINI: DeviceCornerProfile =
  new DeviceCornerProfile('iphone-12-mini', true, 0.1180, 2.18, 0.1080);
const CORNER_IPHONE_13_MINI: DeviceCornerProfile =
  new DeviceCornerProfile('iphone-13-mini', true, 0.1240, 2.20, 0.1130);
const CORNER_IPHONE_12_STANDARD: DeviceCornerProfile =
  new DeviceCornerProfile('iphone-12-standard', true, 0.1390, 2.22, 0.1260);
const CORNER_IPHONE_12_MAX: DeviceCornerProfile =
  new DeviceCornerProfile('iphone-12-max', true, 0.1320, 2.22, 0.1200);
const CORNER_IPHONE_DYNAMIC_ISLAND: DeviceCornerProfile =
  new DeviceCornerProfile('iphone-dynamic-island', true, 0.1784, 2.36, 0.1583);
const CORNER_IPAD_PRO: DeviceCornerProfile =
  new DeviceCornerProfile('ipad-pro-rounded', true, 0.0430, 2.12, 0.0390);
const CORNER_IPAD_AIR: DeviceCornerProfile =
  new DeviceCornerProfile('ipad-air-rounded', true, 0.0390, 2.08, 0.0360);
const CORNER_IPAD_MINI: DeviceCornerProfile =
  new DeviceCornerProfile('ipad-mini-rounded', true, 0.0520, 2.12, 0.0470);
const CORNER_IPAD_BASE: DeviceCornerProfile =
  new DeviceCornerProfile('ipad-rounded', true, 0.0380, 2.08, 0.0350);

/**
 * 已知是**直角屏**的 iPhone：它们与全面屏机型共用同一代 ProductType 主号，
 * 所以只能按次号点名（上游 DeviceCornerProfileResolver.cs:41-47）。
 *   iPhone10,1 / 10,2 = iPhone 8；10,4 / 10,5 = iPhone 8 Plus（同代的 10,3/10,6 是 iPhone X）
 *   iPhone12,8 = SE 2；iPhone14,6 = SE 3
 * 编码成 major*10000+minor，省掉 C# 的元组集合。
 */
const RECTANGULAR_IPHONES: number[] = [
  10 * 10000 + 1, 10 * 10000 + 2, 10 * 10000 + 4, 10 * 10000 + 5,
  12 * 10000 + 8, 14 * 10000 + 6,
];

/**
 * 同代里**保留刘海**的机型：iPhone16e = iPhone17,5
 * （同代其余 iPhone17,* 都是灵动岛；上游 :49-54）。
 */
const NOTCHED_MODERN_IPHONES: number[] = [17 * 10000 + 5];

function in_list(list: number[], major: number, minor: number): boolean {
  return list.includes(major * 10000 + minor);
}

/**
 * 解析 `iPhone17,5` 这类 Apple ProductType。
 *
 * 对应上游 TryParseProductType：前缀**大小写不敏感**，但取后缀时用原始串的
 * 长度切（`value.AsSpan(prefix.Length)`）；逗号必须在中间（两段都非空）；
 * 两段都必须是合法的非负整数 —— `major >= 0 && minor >= 0` 意味着上游其实
 * 接受前导 '+' 之类，本移植收紧成纯数字（真实 ProductType 不会出现别的形态）。
 */
function parse_product_type(value: string, prefix: string):
    ProductTypeParts | null {
  if (value.length === 0 || value.trim().length === 0) {
    return null;
  }
  if (!value.toLowerCase().startsWith(prefix.toLowerCase())) {
    return null;
  }
  const suffix: string = value.substring(prefix.length);
  const comma: number = suffix.indexOf(',');
  if (comma <= 0 || comma === suffix.length - 1) {
    return null;
  }
  const majorText: string = suffix.substring(0, comma);
  const minorText: string = suffix.substring(comma + 1);
  if (!is_digits(majorText) || !is_digits(minorText)) {
    return null;
  }
  return new ProductTypeParts(Number(majorText), Number(minorText));
}

/** ProductType 的两段数字。用一个类而不是对象字面量：ArkTS 严格模式不允许裸字面量。 */
class ProductTypeParts {
  major: number = 0;
  minor: number = 0;

  constructor(major: number, minor: number) {
    this.major = major;
    this.minor = minor;
  }
}

function is_digits(text: string): boolean {
  if (text.length === 0) {
    return false;
  }
  for (let i = 0; i < text.length; i++) {
    const code: number = text.charCodeAt(i);
    if (code < 0x30 || code > 0x39) {
      return false;
    }
  }
  return true;
}

function is_letter(code: number): boolean {
  return (code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A);
}

/**
 * 判断一个字符串**长得像不像** Apple 的 ProductType（`iPhone17,5` / `AffixN,M`）。
 *
 * ★ 为什么需要它：本工程的界面上，设备型号的占位值是 `'—'`（`Index.clear_selection`
 *   写的就是它，对齐上游 SelectedModel 的空值分支）。而 `resolve_corner_profile`
 *   的规则是「ProductType **非空**但不认识 ⇒ 直角」（上游为了 Apple TV / iPod
 *   才这么定）—— 直接把 `'—'` 喂进去，会让"还没选设备/正在读型号"的情况被判成
 *   直角屏，把机型拟合整个吃掉。
 *
 * 所以调用方必须先用本函数过滤：像 ProductType 才传，否则传空串走几何兜底。
 * 注意 `AppleTV6,2` 这种**要**放行 —— 它本来就该判直角，过滤掉反而会让几何兜底
 * 把一台 Apple TV 当成手机。
 */
export function looks_like_product_type(value: string): boolean {
  const text: string = value.trim();
  const comma: number = text.indexOf(',');
  if (comma <= 0 || comma === text.length - 1) {
    return false;
  }
  const head: string = text.substring(0, comma);
  const tail: string = text.substring(comma + 1);
  if (!is_digits(tail)) {
    return false;
  }
  // head 必须是「若干字母 + 若干数字」，且两段都非空。
  let index: number = 0;
  while (index < head.length && is_letter(head.charCodeAt(index))) {
    index++;
  }
  if (index === 0 || index === head.length) {
    return false;
  }
  return is_digits(head.substring(index));
}

/** 上游 ResolveIPhone（:73-104）。 */
function resolve_iphone(major: number, minor: number): DeviceCornerProfile {
  if (major < 10 || in_list(RECTANGULAR_IPHONES, major, minor)) {
    return CORNER_RECTANGULAR;
  }
  // iPhone X 与 iPhone 8 同属 iPhone10 这一代，只能按次号区分。
  if (major === 10) {
    return (minor === 3 || minor === 6) ? CORNER_IPHONE_X : CORNER_RECTANGULAR;
  }
  if (major === 13) {
    if (minor === 1) {
      return CORNER_IPHONE_12_MINI;
    }
    if (minor === 2 || minor === 3) {
      return CORNER_IPHONE_12_STANDARD;
    }
    if (minor === 4) {
      return CORNER_IPHONE_12_MAX;
    }
    return CORNER_IPHONE_NOTCH;
  }
  if (major === 14) {
    if (minor === 4) {
      return CORNER_IPHONE_13_MINI;
    }
    if (minor === 3 || minor === 5 || minor === 7 || minor === 8) {
      return CORNER_IPHONE_12_STANDARD;
    }
    if (minor === 2) {
      return CORNER_IPHONE_12_MAX;
    }
    return CORNER_IPHONE_NOTCH;
  }
  // iPhone15,* 从 iPhone 14 Pro 起算，是第一代全灵动岛；之后的标识一路继承。
  if (in_list(NOTCHED_MODERN_IPHONES, major, minor)) {
    return CORNER_IPHONE_NOTCH;
  }
  if (major >= 15) {
    return CORNER_IPHONE_DYNAMIC_ISLAND;
  }
  return CORNER_IPHONE_NOTCH;
}

/** 上游 ResolveIPad（:106-144）。 */
function resolve_ipad(major: number, minor: number): DeviceCornerProfile {
  // iPad8,* = 2018/2020 的全面屏 Pro；iPad9~12 仍是带 Home 键的直角屏；
  // Air/Pro/mini/基础款的全面屏从 iPad13,* 重新开始。
  if (major === 8) {
    return CORNER_IPAD_PRO;
  }
  if (major < 13) {
    return CORNER_RECTANGULAR;
  }
  if (major === 13) {
    if (minor === 1 || minor === 2 || minor === 16 || minor === 17) {
      return CORNER_IPAD_AIR;
    }
    if (minor === 18 || minor === 19) {
      return CORNER_IPAD_BASE;
    }
    return CORNER_IPAD_PRO;
  }
  if (major === 14) {
    if (minor === 1 || minor === 2) {
      return CORNER_IPAD_MINI;
    }
    if (minor >= 8 && minor <= 11) {
      return CORNER_IPAD_AIR;
    }
    return CORNER_IPAD_PRO;
  }
  if (major === 15) {
    if (minor >= 3 && minor <= 6) {
      return CORNER_IPAD_AIR;
    }
    if (minor === 7 || minor === 8) {
      return CORNER_IPAD_BASE;
    }
    return CORNER_IPAD_PRO;
  }
  if (major === 16) {
    if (minor === 1 || minor === 2) {
      return CORNER_IPAD_MINI;
    }
    if (minor >= 8 && minor <= 11) {
      return CORNER_IPAD_AIR;
    }
    return CORNER_IPAD_PRO;
  }
  // iPad17,* 从 M5 Pro 起算；更未知的全面屏 iPad 用"中等拟合"，
  // 而不是按手机去裁（上游注释原话：rather than clipping like a phone）。
  if (major === 17) {
    return CORNER_IPAD_PRO;
  }
  if (major > 17) {
    return CORNER_IPAD_BASE;
  }
  return CORNER_IPAD_PRO;
}

/**
 * 没有 ProductType 时的几何兜底（上游 ResolveByGeometry，:146-159）。
 *
 * 阈值是**故意留缝**的：手机大致 0.42-0.50、圆角 iPad 大致 0.69-0.75，
 * 落在缝里的一律判直角 —— 宁可少裁，也不要把一台不认识的设备裁坏。
 */
function resolve_by_geometry(frameWidth: number, frameHeight: number): DeviceCornerProfile {
  if (frameWidth <= 0 || frameHeight <= 0) {
    return CORNER_RECTANGULAR;
  }
  const shortEdge: number = Math.min(frameWidth, frameHeight);
  const longEdge: number = Math.max(frameWidth, frameHeight);
  const ratio: number = shortEdge / longEdge;
  if (ratio >= 0.38 && ratio <= 0.56) {
    return CORNER_IPHONE_DYNAMIC_ISLAND;
  }
  if (ratio >= 0.64 && ratio <= 0.80) {
    return CORNER_IPAD_BASE;
  }
  return CORNER_RECTANGULAR;
}

/**
 * 上游 `DeviceCornerProfileResolver.Resolve`（:56-71）：
 * **ProductType 优先**；不认识但非空 ⇒ 直角；完全没有 ProductType 才看几何。
 */
export function resolve_corner_profile(productType: string, frameWidth: number,
                                      frameHeight: number): DeviceCornerProfile {
  const phone: ProductTypeParts | null = parse_product_type(productType, 'iPhone');
  if (phone !== null) {
    return resolve_iphone(phone.major, phone.minor);
  }
  const pad: ProductTypeParts | null = parse_product_type(productType, 'iPad');
  if (pad !== null) {
    return resolve_ipad(pad.major, pad.minor);
  }
  // Apple TV / iPod / 已知的其它非移动标识都按直角处理。
  if (productType.trim().length > 0) {
    return CORNER_RECTANGULAR;
  }
  return resolve_by_geometry(frameWidth, frameHeight);
}

/**
 * 上游硬编码的几何兜底入参（MultiDevicePreviewManager.cs:148 的 `Resolve(..., 1206, 2622)`）。
 *
 * 只在**渲染器还没量到帧尺寸**时使用 —— 效果与上游完全一致：未知机型按
 * Dynamic Island 拟合（1206/2622 ≈ 0.4600，落在 0.38~0.56 区间）。
 */
export const FALLBACK_FRAME_WIDTH: number = 1206;
export const FALLBACK_FRAME_HEIGHT: number = 2622;

/**
 * 给调用方用的一步到位的口径：拿不到实测帧尺寸就套上游那组常量。
 *
 * 把它单独包一层的原因：`resolve_corner_profile(p, 0, 0)` 会走"几何兜底 → 直角"，
 * 与上游"未知 ⇒ Dynamic Island"的结论**不一样**。差别必须集中在这一点上，
 * 免得两处调用各写一遍、又各自漂移。
 */
export function resolve_corner_profile_for_frame(productType: string,
                                                 frameWidth: number,
                                                 frameHeight: number): DeviceCornerProfile {
  if (frameWidth > 0 && frameHeight > 0) {
    return resolve_corner_profile(productType, frameWidth, frameHeight);
  }
  return resolve_corner_profile(productType, FALLBACK_FRAME_WIDTH, FALLBACK_FRAME_HEIGHT);
}

/**
 * 诊断行：把"这台设备被判成了什么"摊给用户看。
 *
 * 为什么必须有：轮廓是个"看起来不对但说不清哪不对"的东西。没有这一行，
 * 用户只能反馈"圆角怪怪的"；有了它，一眼能看出是 ProductType 没识别出来、
 * 还是几何兜底判成了直角。
 */
export function describe_corner_profile(profile: DeviceCornerProfile,
                                        productType: string): string {
  if (productType.trim().length === 0) {
    return `外形拟合：${profile.id}（未取得机型标识，按画面比例推断）`;
  }
  return `外形拟合：${profile.id}（机型 ${productType}）`;
}

/** 打印一次判定结果 —— 用户侧读不到 hilog 时，靠上面的 describe 走界面。 */
export function log_corner_profile(profile: DeviceCornerProfile, productType: string): void {
  hilog.info(DOMAIN, TAG, 'corner profile: id=%{public}s productType=%{public}s '
    + 'radius=%{public}f exponent=%{public}f rounded=%{public}d',
    profile.id, productType.length > 0 ? productType : '(empty)',
    profile.preview_radius(), profile.curveExponent, profile.isRounded ? 1 : 0);
}
