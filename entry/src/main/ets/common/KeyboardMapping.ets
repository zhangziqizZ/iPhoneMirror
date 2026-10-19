// KeyboardMapping.ets —— 键盘映射数据模型与校验
//
// 逐项对照上游：
//   src/App/Services/KeyboardMapping.cs（MappedTouchAction / MappedKey /
//     KeyboardMappingEntry / KeyboardMappingSettings / 校验）
//   src/App/Services/KeyboardMappingWizardState.cs（向导状态机用到的大部分判定）
//
// ── 平台替换（必须逐条列明）──────────────────────────────────────────────────
//   1. 【物理键标识】上游用 Windows 扫描码(ScanCode)+扩展键(Extended)，与键盘布局无关；
//      鸿蒙侧用 KeyCode（@ohos.multimodalInput.keyCode 的数值）做物理标识，语义等价
//      （同样与布局无关）。故 MappingKey 只存 code + 采集时的可读 label。
//   2. 【动作语义】上游把物理键映射到 iPhone 屏幕的**触摸动作**（点按/长按/按住/
//      双击/滑动），需要「绝对触控」通道。鸿蒙版反控当前是蓝牙 HID 相对鼠标，
//      没有绝对触控 ⇒ 本特性**只完成配置/编辑器/持久化/向导**，
//      动作的真实下发待绝对触控后端落地（见两窗口里的诚实提示，不假装能执行）。
//   3. 【位置取点】上游在投屏预览框里取点（MappingPreviewSurface 那一层），鸿蒙版
//      没有该预览取点层 ⇒ 位置改用「归一化坐标数字输入（0–100%）」，数据模型保持完整。
//   4. 【唯一 id】上游用 Guid；鸿蒙没有 Guid，用 时间戳+随机串 做本机唯一标识。

import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'im_keymap';
const DOMAIN: number = 0x0100;

/** 映射动作（对照上游 MappedTouchAction）。 */
export enum MappedTouchAction {
  Tap = 'Tap',
  LongPress = 'LongPress',
  DoubleTap = 'DoubleTap',
  Swipe = 'Swipe',
  SwipeUp = 'SwipeUp',
  SwipeDown = 'SwipeDown',
  SwipeLeft = 'SwipeLeft',
  SwipeRight = 'SwipeRight',
  HoldUntilRelease = 'HoldUntilRelease',
}

/** 全部动作（避免用 Object.values，兼容 ArkTS 受限标准库）。 */
export const ALL_MAPPED_ACTIONS: MappedTouchAction[] = [
  MappedTouchAction.Tap,
  MappedTouchAction.LongPress,
  MappedTouchAction.HoldUntilRelease,
  MappedTouchAction.DoubleTap,
  MappedTouchAction.Swipe,
  MappedTouchAction.SwipeUp,
  MappedTouchAction.SwipeDown,
  MappedTouchAction.SwipeLeft,
  MappedTouchAction.SwipeRight,
];

/** 物理键（对照上游 MappedKey：用鸿蒙 KeyCode 做物理标识，与布局无关）。 */
export interface MappingKey {
  code: number;   // 鸿蒙 KeyCode
  label: string;  // 采集时记录的可读名
}

/** 单条映射（对照上游 KeyboardMappingEntry）。 */
export interface KeyboardMappingEntry {
  id: string;
  key: MappingKey | null;
  action: MappedTouchAction;
  enabled: boolean;
  x: number;        // 起点 X 归一化 0..1
  y: number;
  endX: number;     // 终点 X（自定义滑动 / 方向滑动推导结果）
  endY: number;
  distance: number; // 方向滑动距离（归一化）
  durationMs: number;
  intervalMs: number;
  deviceCoordinates: boolean;
}

/** 全局设置（对照上游 KeyboardMappingSettings）。 */
export interface KeyboardMappingSettings {
  schemaVersion: number;
  enabled: boolean;
  suppressOriginalKey: boolean;
  mappings: KeyboardMappingEntry[];
}

/**
 * 归一化坐标点（0..1）。
 *
 * ★ 必须显式声明成 interface：ArkTS 禁止把「对象字面量类型」直接当类型标注写
 *   （arkts-no-obj-literals-as-types），也不允许没有对应声明的字面量
 *   （arkts-no-untyped-obj-literals）。所以 { x, y } 这种返回/局部类型一律走这里。
 */
export interface KeymapPoint {
  x: number;
  y: number;
}

export const KEYBOARD_MAPPING_SCHEMA_VERSION: number = 1;
export const KEYBOARD_MAPPING_MAX_ENTRIES: number = 256;

/** 默认值。 */
export function default_keyboard_mapping_settings(): KeyboardMappingSettings {
  return { schemaVersion: KEYBOARD_MAPPING_SCHEMA_VERSION, enabled: false, suppressOriginalKey: false, mappings: [] };
}

/** 本机唯一 id（替代 Guid）。 */
export function new_mapping_id(): string {
  return `km_${Date.now().toString(36)}_${Math.floor(Math.random() * 0xFFFFFF).toString(36)}`;
}

/** 滑动类动作。 */
export function keymap_is_swipe(action: MappedTouchAction): boolean {
  return action === MappedTouchAction.Swipe
    || action === MappedTouchAction.SwipeUp
    || action === MappedTouchAction.SwipeDown
    || action === MappedTouchAction.SwipeLeft
    || action === MappedTouchAction.SwipeRight;
}

/** 方向滑动（上/下/左/右）。 */
export function keymap_is_directional(action: MappedTouchAction): boolean {
  return action === MappedTouchAction.SwipeUp
    || action === MappedTouchAction.SwipeDown
    || action === MappedTouchAction.SwipeLeft
    || action === MappedTouchAction.SwipeRight;
}

/** 需要参数页的动作（长按/滑动需时长，双击需间隔）。 */
export function keymap_has_parameters(action: MappedTouchAction): boolean {
  return action === MappedTouchAction.LongPress
    || action === MappedTouchAction.DoubleTap
    || keymap_is_swipe(action);
}

/** 物理键是否相同（同 code = 同一物理位置）。 */
export function keymap_same_key(a: MappingKey | null, b: MappingKey | null): boolean {
  if (a === null || b === null) {
    return false;
  }
  return a.code === b.code;
}

/** 校验物理键（拒绝 0 / 越界）。 */
export function keymap_validate_key(key: MappingKey | null): string | null {
  if (key === null) {
    return 'MappingCaptureHint';
  }
  if (!Number.isFinite(key.code) || key.code <= 0 || key.code > 0xFFFF) {
    return 'MappingUnsupportedKey';
  }
  return null;
}

/** 坐标合法（0..1）。 */
function keymap_coordinate(value: number): boolean {
  return Number.isFinite(value) && value >= 0 && value <= 1;
}

/** 校验单条映射（对照上游 KeyboardMappingEntry.Validate）。返回 i18n key 或 null。 */
export function keymap_validate_entry(entry: KeyboardMappingEntry): string | null {
  if (entry.key === null) {
    return 'MappingCaptureHint';
  }
  const keyError: string | null = keymap_validate_key(entry.key);
  if (keyError !== null) {
    return keyError;
  }
  if (!ALL_MAPPED_ACTIONS.includes(entry.action)) {
    return 'MappingUnsupportedAction';
  }
  if (!keymap_coordinate(entry.x) || !keymap_coordinate(entry.y)) {
    return 'MappingInvalidCoordinates';
  }
  if (entry.action === MappedTouchAction.LongPress || keymap_is_swipe(entry.action)) {
    if (entry.durationMs < 50 || entry.durationMs > 10000) {
      return 'MappingInvalidDuration';
    }
  }
  if (entry.action === MappedTouchAction.DoubleTap) {
    if (entry.intervalMs < 40 || entry.intervalMs > 1000) {
      return 'MappingInvalidInterval';
    }
  }
  if (keymap_is_directional(entry.action)) {
    if (!Number.isFinite(entry.distance) || entry.distance <= 0 || entry.distance > 1) {
      return 'MappingInvalidDistance';
    }
  }
  if (keymap_is_swipe(entry.action)) {
    const end: KeymapPoint = keymap_end_point(entry);
    if (!keymap_coordinate(end.x) || !keymap_coordinate(end.y) || (end.x === entry.x && end.y === entry.y)) {
      return 'MappingInvalidSwipe';
    }
  }
  return null;
}

/** 滑动终点（方向滑动按 distance 推导；自定义滑动用 endX/endY）。 */
export function keymap_end_point(entry: KeyboardMappingEntry): KeymapPoint {
  if (entry.deviceCoordinates) {
    return { x: entry.endX, y: entry.endY };
  }
  switch (entry.action) {
    case MappedTouchAction.SwipeUp:
      return { x: entry.x, y: entry.y - entry.distance };
    case MappedTouchAction.SwipeDown:
      return { x: entry.x, y: entry.y + entry.distance };
    case MappedTouchAction.SwipeLeft:
      return { x: entry.x - entry.distance, y: entry.y };
    case MappedTouchAction.SwipeRight:
      return { x: entry.x + entry.distance, y: entry.y };
    default:
      return { x: entry.endX, y: entry.endY };
  }
}

// ── 鸿蒙 KeyCode 常量（取自 ReverseControlInput，避免依赖其私有常量）──
const KC_0 = 2000;
const KC_9 = 2009;
const KC_A = 2017;
const KC_Z = 2042;
const KC_F1 = 2090;
const KC_DPAD_UP = 2012;
const KC_DPAD_DOWN = 2013;
const KC_DPAD_LEFT = 2014;
const KC_DPAD_RIGHT = 2015;
const KC_DPAD_CENTER = 2016;
const KC_TAB = 2049;
const KC_SPACE = 2050;
const KC_ENTER = 2054;
const KC_DEL = 2055;           // 退格
const KC_FORWARD_DEL = 2071;   // Delete
const KC_ESCAPE = 2070;
const KC_CTRL_LEFT = 2072;
const KC_CTRL_RIGHT = 2073;
const KC_SHIFT_LEFT = 2047;
const KC_SHIFT_RIGHT = 2048;
const KC_ALT_LEFT = 2045;
const KC_ALT_RIGHT = 2046;
const KC_META_LEFT = 2076;
const KC_META_RIGHT = 2077;
const KC_CAPS_LOCK = 2074;

/** 特殊键的可读名（其余按字母/数字/功能键推导）。 */
const SPECIAL_KEY_LABELS: Map<number, string> = new Map<number, string>([
  [KC_ENTER, 'Enter'],
  [KC_ESCAPE, 'Esc'],
  [KC_TAB, 'Tab'],
  [KC_SPACE, 'Space'],
  [KC_DEL, 'Backspace'],
  [KC_FORWARD_DEL, 'Delete'],
  [KC_CAPS_LOCK, 'CapsLock'],
  [KC_CTRL_LEFT, '左Ctrl'],
  [KC_CTRL_RIGHT, '右Ctrl'],
  [KC_SHIFT_LEFT, '左Shift'],
  [KC_SHIFT_RIGHT, '右Shift'],
  [KC_ALT_LEFT, '左Alt'],
  [KC_ALT_RIGHT, '右Alt'],
  [KC_META_LEFT, '左Win'],
  [KC_META_RIGHT, '右Win'],
  [KC_DPAD_UP, '↑'],
  [KC_DPAD_DOWN, '↓'],
  [KC_DPAD_LEFT, '←'],
  [KC_DPAD_RIGHT, '→'],
  [KC_DPAD_CENTER, 'OK'],
]);

/** 物理键可读名（对照上游 KeyboardMappingKeys.Display）。 */
export function keymap_key_display(code: number): string {
  const special: string | undefined = SPECIAL_KEY_LABELS.get(code);
  if (special !== undefined) {
    return special;
  }
  if (code >= KC_A && code <= KC_Z) {
    return String.fromCharCode(65 + (code - KC_A));   // A..Z
  }
  if (code >= KC_0 && code <= KC_9) {
    return String.fromCharCode(48 + (code - KC_0));   // 0..9
  }
  if (code >= KC_F1 && code <= KC_F1 + 11) {
    return `F${code - KC_F1 + 1}`;                     // F1..F12
  }
  return `Key${code}`;
}

/** 是否为修饰键（Ctrl/Shift/Alt/Win），不拦截其原有行为。 */
export function keymap_is_modifier(code: number): boolean {
  return code === KC_CTRL_LEFT || code === KC_CTRL_RIGHT
    || code === KC_SHIFT_LEFT || code === KC_SHIFT_RIGHT
    || code === KC_ALT_LEFT || code === KC_ALT_RIGHT
    || code === KC_META_LEFT || code === KC_META_RIGHT;
}

/**
 * 动作 → i18n key（对照上游 "MappingAction" + 动作名）。
 * ★ 本移植的 i18n 以「简体中文原文」作 key（见 i18n.ets），
 *   故这里返回的是中文串，由 t() 按当前语言查表翻译。
 */
const ACTION_LABEL_ZH: Record<string, string> = {
  [MappedTouchAction.Tap]: '映射动作：点按',
  [MappedTouchAction.LongPress]: '映射动作：长按',
  [MappedTouchAction.HoldUntilRelease]: '映射动作：按住直到松开',
  [MappedTouchAction.DoubleTap]: '映射动作：双击',
  [MappedTouchAction.Swipe]: '映射动作：滑动',
  [MappedTouchAction.SwipeUp]: '映射动作：上滑',
  [MappedTouchAction.SwipeDown]: '映射动作：下滑',
  [MappedTouchAction.SwipeLeft]: '映射动作：左滑',
  [MappedTouchAction.SwipeRight]: '映射动作：右滑',
};

export function keymap_action_label_key(action: MappedTouchAction): string {
  return ACTION_LABEL_ZH[action] ?? '映射动作：点按';
}

/** 列表行参数摘要（对照上游 KeyboardMappingRow.ParameterText）。 */
export function keymap_entry_summary(entry: KeyboardMappingEntry): string {
  const px: number = Math.round(entry.x * 100);
  const py: number = Math.round(entry.y * 100);
  if (keymap_is_swipe(entry.action)) {
    const end: KeymapPoint = keymap_end_point(entry);
    return `(${px}%, ${py}%) → (${Math.round(end.x * 100)}%, ${Math.round(end.y * 100)}%) · ${entry.durationMs}ms`;
  }
  if (entry.action === MappedTouchAction.LongPress) {
    return `(${px}%, ${py}%) · ${entry.durationMs}ms`;
  }
  if (entry.action === MappedTouchAction.DoubleTap) {
    return `(${px}%, ${py}%) · ${entry.intervalMs}ms`;
  }
  return `(${px}%, ${py}%)`;
}

/** 深拷贝一条映射（避免共用引用导致跨窗口互相污染）。 */
export function keymap_clone_entry(entry: KeyboardMappingEntry): KeyboardMappingEntry {
  return {
    id: entry.id,
    key: entry.key === null ? null : { code: entry.key.code, label: entry.key.label },
    action: entry.action,
    enabled: entry.enabled,
    x: entry.x,
    y: entry.y,
    endX: entry.endX,
    endY: entry.endY,
    distance: entry.distance,
    durationMs: entry.durationMs,
    intervalMs: entry.intervalMs,
    deviceCoordinates: entry.deviceCoordinates,
  };
}

/** 深拷贝设置。 */
export function keymap_clone_settings(settings: KeyboardMappingSettings): KeyboardMappingSettings {
  return {
    schemaVersion: settings.schemaVersion,
    enabled: settings.enabled,
    suppressOriginalKey: settings.suppressOriginalKey,
    mappings: settings.mappings.map((item: KeyboardMappingEntry): KeyboardMappingEntry => keymap_clone_entry(item)),
  };
}
