/**
 * 应用偏好持久化 —— 开关 / 半透明浓度这类「用户选过一次就该记住」的设置。
 *
 * ── 为什么不用 PersistentStorage ────────────────────────────────────────────
 * AppStorage 是**进程内内存态**，进程一退就没 ⇒ 用户选了 40%、重开又变回 60%。
 * 第一版改成了 `PersistentStorage.persistProp`，**实测仍不行**：它自己决定什么时候把
 * 数据刷到磁盘，用户直接关掉/杀掉应用时不一定来得及落盘（没法验证、也没法排错）。
 *
 * ⇒ 这里改用 API 级显式读写：`putSync()` 之后立刻 `flushSync()`（@since 14），
 *   什么时候写的、写成功没有，都由我们掌握；结果写进 AppStorage 由读数行显示
 *   ——「没保存」这件事必须能自证，不能靠感觉。
 *
 * ★ 调用时机（顺序不可换）：
 *   1. `open_app_preferences(context)` —— Ability `onCreate` 里尽早调；
 *   2. `load_acrylic_preferences()` —— 把磁盘值读进 AppStorage，**必须在任何 UI
 *      （@StorageLink 会读取并建立这个键）装载之前**，否则 UI 先建了键，这里读到的是默认值；
 *   3. 用户改动时 `save_acrylic_preferences(...)` —— 立即写盘。
 *
 * ★ 这三个函数在 Preferences 不可用（store 为 null）时**只记不崩**：界面照常能用，
 *   代价仅仅是偏好不跨启动，而不是白屏或崩溃（子窗口铁律：失败必须能被看见，但不能连带崩）。
 */
import { preferences } from '@kit.ArkData';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ACRYLIC_ALPHA_DEFAULT,
  ACRYLIC_ALPHA_KEY,
  ACRYLIC_WINDOW_KEY,
  PERSIST_READ_RESULT_KEY,
  PERSIST_WRITE_RESULT_KEY,
  HIDE_POINTER_ON_TAKEOVER_KEY,
  GLOW_ENABLED_KEY,
  GLOW_STRENGTH_KEY,
  GLOW_DEGRADED_KEY,
  MINIMIZE_TO_TRAY_KEY,
  TRAY_AVAILABLE_KEY,
} from './WindowServices';
import { LANG_INDEX_KEY } from './i18n';
import {
  KeyboardMappingSettings, KeyboardMappingEntry, MappedTouchAction,
  ALL_MAPPED_ACTIONS, KEYBOARD_MAPPING_MAX_ENTRIES, KEYBOARD_MAPPING_SCHEMA_VERSION,
  default_keyboard_mapping_settings, new_mapping_id,
  keymap_same_key, keymap_validate_entry,
} from './KeyboardMapping';

/** 偏好文件名 —— 落在应用沙箱的 preferences 目录，卸载才清。 */
const PREFS_NAME: string = 'iphone_mirror_prefs';

/** ★ preferences 里的键：与 AppStorage 的 `im.xxx` 分开命名，避免两套键被误当成同一个。 */
const PREFS_KEY_ACRYLIC_ON: string = 'acrylic_on';
const PREFS_KEY_ACRYLIC_ALPHA: string = 'acrylic_alpha';
/** ★ preferences 里的键：界面语言档位（0=跟随系统 1=简体 2=繁中香港 3=英文）。 */
const PREFS_KEY_LANGUAGE: string = 'language_index';
/** ★ preferences 里的键：反控接管时是否收起本地指针（默认 false = 保持可见）。 */
const PREFS_KEY_HIDE_POINTER: string = 'hide_pointer_on_takeover';
const PREFS_KEY_GLOW_ENABLED: string = 'glow_enabled';
const PREFS_KEY_GLOW_STRENGTH: string = 'glow_strength';
const PREFS_KEY_MINIMIZE_TO_TRAY: string = 'minimize_to_tray';
/** ★ preferences 里的键：首启向导是否已看过（默认 false = 没看过，首次启动弹）。 */
const PREFS_KEY_FIRST_RUN_DONE: string = 'first_run_done';

/** ★ AppStorage 键：首启向导是否已看过（false = 首次启动应弹出向导）。 */
export const FIRST_RUN_DONE_KEY: string = 'im.firstRun.done';

/**
 * 偏好实例。为什么是模块级可变变量：写入发生在 UI 点击回调里，那里拿不到 Ability 的
 * context，也不该为了存一个 bool 每次再去开一次文件句柄。
 */
let store: preferences.Preferences | null = null;

/**
 * 打开偏好存储。放在 Ability `onCreate` 里调用。
 *
 * @param context Ability 上下文（`this.context`），用来定位应用沙箱。
 */
export function open_app_preferences(context: common.Context): void {
  try {
    store = preferences.getPreferencesSync(context, { name: PREFS_NAME });
  } catch (openError) {
    const openFailure = openError as BusinessError;
    AppStorage.setOrCreate(PERSIST_READ_RESULT_KEY,
      `偏好打开失败 ${openFailure.code} ${openFailure.message}`);
  }
}

/**
 * 从磁盘读回半透明的两项偏好，写进 AppStorage。
 *
 * ★ 必须在 UI 装载**之前**调用：`@StorageLink` 首次读取会**创建**这个键（用的是它的
 *   默认值），一旦先创建，这里的写入就会被当成普通更新、用户看到的是被 UI 覆盖前的值。
 */
export function load_acrylic_preferences(): void {
  if (store === null) {
    AppStorage.setOrCreate(PERSIST_READ_RESULT_KEY, '偏好未打开 · 本次不跨启动保留');
    return;
  }
  try {
    const on: boolean = store.getSync(PREFS_KEY_ACRYLIC_ON, true) as boolean;
    const alpha: string = store.getSync(PREFS_KEY_ACRYLIC_ALPHA, ACRYLIC_ALPHA_DEFAULT) as string;
    AppStorage.setOrCreate(ACRYLIC_WINDOW_KEY, on);
    AppStorage.setOrCreate(ACRYLIC_ALPHA_KEY, alpha);
    AppStorage.setOrCreate(PERSIST_READ_RESULT_KEY,
      `存档 开关=${on ? '开' : '关'} 浓度=${alpha}`);
  } catch (readError) {
    const readFailure = readError as BusinessError;
    AppStorage.setOrCreate(PERSIST_READ_RESULT_KEY,
      `偏好读取失败 ${readFailure.code} ${readFailure.message}`);
  }
}

/**
 * 写入半透明的两项偏好并**立即落盘**。
 *
 * ★ `flushSync()` 是这版能生效的关键：`putSync()` 只改内存副本，进程被直接杀掉时
 *   没机会走 Ability 的正常收尾 ⇒ 不 flush 就等于没存（第一版 PersistentStorage
 *   失败的根因就在这里）。
 *
 * @param on 半透明开关
 * @param alpha 浓度的 alpha 十六进制串（两位，如 '99'）
 */
export function save_acrylic_preferences(on: boolean, alpha: string): void {
  if (store === null) {
    AppStorage.setOrCreate(PERSIST_WRITE_RESULT_KEY, '偏好未打开 · 未写入');
    return;
  }
  try {
    store.putSync(PREFS_KEY_ACRYLIC_ON, on);
    store.putSync(PREFS_KEY_ACRYLIC_ALPHA, alpha);
    store.flushSync();
    AppStorage.setOrCreate(PERSIST_WRITE_RESULT_KEY, `落盘 ok ${on ? '开' : '关'}/${alpha}`);
  } catch (writeError) {
    const writeFailure = writeError as BusinessError;
    AppStorage.setOrCreate(PERSIST_WRITE_RESULT_KEY,
      `偏好写入失败 ${writeFailure.code} ${writeFailure.message}`);
  }
}

/**
 * 从磁盘读回界面语言档位，写进 AppStorage 的 `LANG_INDEX_KEY`。
 *
 * ★ 与 load_acrylic_preferences 同理：必须在 UI 装载**之前**调用 —— UI 里的
 *   `@StorageLink`/`t()` 首次读取会**建立**这个键，一旦先建，这里读到的是默认值。
 *   store 未打开（preferences 不可用）时按 0（跟随系统）处理：代价只是本次不跨启动保留。
 */
export function load_language_preference(): void {
  if (store === null) {
    return;
  }
  try {
    const index: number = store.getSync(PREFS_KEY_LANGUAGE, 0) as number;
    AppStorage.setOrCreate(LANG_INDEX_KEY, index);
  } catch (readError) {
    const readFailure = readError as BusinessError;
    // 读取失败不连带崩：退回跟随系统，界面照常能用。
    hilog.warn(0x0000, 'AppPreferences', '语言偏好读取失败 %d %{public}s',
      readFailure.code, readFailure.message);
  }
}

/**
 * 写入界面语言档位并**立即落盘**（`flushSync()` 是关键，见文件头说明）。
 *
 * @param index 0=跟随系统 1=简体 2=繁中(香港) 3=英文
 */
export function save_language_preference(index: number): void {
  if (store === null) {
    return;
  }
  try {
    store.putSync(PREFS_KEY_LANGUAGE, index);
    store.flushSync();
  } catch (writeError) {
    const writeFailure = writeError as BusinessError;
    hilog.warn(0x0000, 'AppPreferences', '语言偏好写入失败 %d %{public}s',
      writeFailure.code, writeFailure.message);
  }
}

/**
 * 从磁盘读回「反控接管时是否收起本地指针」，写进 AppStorage。
 *
 * ★ 与其他 load_* 同理：必须在 UI 装载**之前**调用，否则 `@StorageLink` 已经用
 *   默认值把键建好了，这里再写就只是普通更新。
 * ★ 默认值 false = **保持可见**（理由见 WindowServices 里该键的注释）。
 */
export function load_hide_pointer_preference(): void {
  if (store === null) {
    AppStorage.setOrCreate(HIDE_POINTER_ON_TAKEOVER_KEY, false);
    return;
  }
  try {
    const hide: boolean = store.getSync(PREFS_KEY_HIDE_POINTER, false) as boolean;
    AppStorage.setOrCreate(HIDE_POINTER_ON_TAKEOVER_KEY, hide);
  } catch (readError) {
    const readFailure = readError as BusinessError;
    // 读不到就保持可见 —— 指针消失比"多一个指针"严重得多。
    AppStorage.setOrCreate(HIDE_POINTER_ON_TAKEOVER_KEY, false);
    hilog.warn(0x0000, 'AppPreferences', '指针偏好读取失败 %d %{public}s',
      readFailure.code, readFailure.message);
  }
}

/**
 * 写入「反控接管时是否收起本地指针」并立即落盘。
 *
 * @param hide true = 接管期间收起本地指针（上游行为）；false = 始终可见（默认）。
 */
export function save_hide_pointer_preference(hide: boolean): void {
  if (store === null) {
    return;
  }
  try {
    store.putSync(PREFS_KEY_HIDE_POINTER, hide);
    store.flushSync();
  } catch (writeError) {
    const writeFailure = writeError as BusinessError;
    hilog.warn(0x0000, 'AppPreferences', '指针偏好写入失败 %d %{public}s',
      writeFailure.code, writeFailure.message);
  }
}

export function load_glow_preferences(): void {
  if (store === null) {
    AppStorage.setOrCreate(GLOW_ENABLED_KEY, true);
    AppStorage.setOrCreate(GLOW_STRENGTH_KEY, 1);
    AppStorage.setOrCreate(GLOW_DEGRADED_KEY, false);
    return;
  }
  try {
    const enabled: boolean = store.getSync(PREFS_KEY_GLOW_ENABLED, true) as boolean;
    const strength: number = store.getSync(PREFS_KEY_GLOW_STRENGTH, 1) as number;
    AppStorage.setOrCreate(GLOW_ENABLED_KEY, enabled);
    AppStorage.setOrCreate(GLOW_STRENGTH_KEY, strength);
    AppStorage.setOrCreate(GLOW_DEGRADED_KEY, false);
  } catch (readError) {
    const readFailure = readError as BusinessError;
    AppStorage.setOrCreate(GLOW_ENABLED_KEY, true);
    AppStorage.setOrCreate(GLOW_STRENGTH_KEY, 1);
    AppStorage.setOrCreate(GLOW_DEGRADED_KEY, false);
    hilog.warn(0x0000, 'AppPreferences', '光感偏好读取失败 %d %{public}s',
      readFailure.code, readFailure.message);
  }
}

export function save_glow_preferences(enabled: boolean, strength: number): void {
  if (store === null) {
    return;
  }
  try {
    store.putSync(PREFS_KEY_GLOW_ENABLED, enabled);
    store.putSync(PREFS_KEY_GLOW_STRENGTH, strength);
    store.flushSync();
  } catch (writeError) {
    const writeFailure = writeError as BusinessError;
    hilog.warn(0x0000, 'AppPreferences', '光感偏好写入失败 %d %{public}s',
      writeFailure.code, writeFailure.message);
  }
}

export function load_tray_preferences(): void {
  if (store === null) {
    AppStorage.setOrCreate(MINIMIZE_TO_TRAY_KEY, true);
    AppStorage.setOrCreate(TRAY_AVAILABLE_KEY, false);
    return;
  }
  try {
    const minimizeToTray: boolean = store.getSync(PREFS_KEY_MINIMIZE_TO_TRAY, true) as boolean;
    AppStorage.setOrCreate(MINIMIZE_TO_TRAY_KEY, minimizeToTray);
    AppStorage.setOrCreate(TRAY_AVAILABLE_KEY, false);
  } catch (readError) {
    const readFailure = readError as BusinessError;
    AppStorage.setOrCreate(MINIMIZE_TO_TRAY_KEY, true);
    AppStorage.setOrCreate(TRAY_AVAILABLE_KEY, false);
    hilog.warn(0x0000, 'AppPreferences', '托盘偏好读取失败 %d %{public}s',
      readFailure.code, readFailure.message);
  }
}

export function save_tray_preferences(minimizeToTray: boolean): void {
  if (store === null) {
    return;
  }
  try {
    store.putSync(PREFS_KEY_MINIMIZE_TO_TRAY, minimizeToTray);
    store.flushSync();
  } catch (writeError) {
    const writeFailure = writeError as BusinessError;
    hilog.warn(0x0000, 'AppPreferences', '托盘偏好写入失败 %d %{public}s',
      writeFailure.code, writeFailure.message);
  }
}

/**
 * 从磁盘读回「首启向导是否已看过」，写进 AppStorage。
 *
 * ★ 与 load_acrylic_preferences 同理：必须在 UI 装载**之前**调用，否则 Index 里的
 *   @StorageLink / AppStorage 读取会先建键（默认值 false），这里再写也只是普通更新。
 * ★ 默认值 false = 没看过：首次启动应弹出首启向导（见 EntryAbility.onWindowStageCreate）。
 */
export function load_first_run_done(): void {
  if (store === null) {
    AppStorage.setOrCreate(FIRST_RUN_DONE_KEY, false);
    return;
  }
  try {
    const done: boolean = store.getSync(PREFS_KEY_FIRST_RUN_DONE, false) as boolean;
    AppStorage.setOrCreate(FIRST_RUN_DONE_KEY, done);
  } catch (readError) {
    const readFailure = readError as BusinessError;
    AppStorage.setOrCreate(FIRST_RUN_DONE_KEY, false);
    hilog.warn(0x0000, 'AppPreferences', '首启向导标记读取失败 %d %{public}s',
      readFailure.code, readFailure.message);
  }
}

/** 标记首启向导已看过，并立即落盘（下次启动不再弹出）。 */
export function save_first_run_done(): void {
  if (store === null) {
    return;
  }
  try {
    store.putSync(PREFS_KEY_FIRST_RUN_DONE, true);
    store.flushSync();
  } catch (writeError) {
    const writeFailure = writeError as BusinessError;
    hilog.warn(0x0000, 'AppPreferences', '首启向导标记写入失败 %d %{public}s',
      writeFailure.code, writeFailure.message);
  }
}

// ── 独立窗口风格（WindowStyleSettingsWindow）──
const PREFS_KEY_INDEPENDENT_OPACITY: string = 'independent_window_opacity';                // 10..100，默认 100
const PREFS_KEY_INDEPENDENT_OPAQUE_ON_HOVER: string = 'independent_window_opaque_on_hover'; // 默认 false

/** AppStorage 键：独立窗口透明度（百分比 10..100，100 = 全不透明）。 */
export const INDEPENDENT_OPACITY_KEY: string = 'im.independentWindow.opacity';
/** AppStorage 键：独立窗口悬停时是否临时变全不透明。 */
export const INDEPENDENT_OPAQUE_ON_HOVER_KEY: string = 'im.independentWindow.opaqueOnHover';

/** 透明度合法区间（与上游 Slider Minimum=10 Maximum=100 一致）。 */
export const INDEPENDENT_OPACITY_MIN: number = 10;
export const INDEPENDENT_OPACITY_MAX: number = 100;

/** 把任意数值夹到 [MIN, MAX] 并取整；非有限值回退默认 100。 */
function clamp_independent_opacity(value: number): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    return INDEPENDENT_OPACITY_MAX;
  }
  return Math.max(INDEPENDENT_OPACITY_MIN, Math.min(INDEPENDENT_OPACITY_MAX, Math.round(value)));
}

/**
 * 读回独立窗口风格偏好，写进 AppStorage。
 * ★ 必须在 UI 装载之前调用（EntryAbility.onCreate）；独立预览 Ability 也走同一份
 *   AppStorage（应用级、跨 Ability 共享），这里建键即可被它读到。
 */
export function load_independent_window_style(): void {
  const defOpacity: number = INDEPENDENT_OPACITY_MAX;
  const defHover: boolean = false;
  if (store === null) {
    AppStorage.setOrCreate(INDEPENDENT_OPACITY_KEY, defOpacity);
    AppStorage.setOrCreate(INDEPENDENT_OPAQUE_ON_HOVER_KEY, defHover);
    return;
  }
  try {
    const opacity: number = store.getSync(PREFS_KEY_INDEPENDENT_OPACITY, defOpacity) as number;
    AppStorage.setOrCreate(INDEPENDENT_OPACITY_KEY, clamp_independent_opacity(opacity));
    const hover: boolean = store.getSync(PREFS_KEY_INDEPENDENT_OPAQUE_ON_HOVER, defHover) as boolean;
    AppStorage.setOrCreate(INDEPENDENT_OPAQUE_ON_HOVER_KEY, hover);
  } catch (readError) {
    const readFailure = readError as BusinessError;
    AppStorage.setOrCreate(INDEPENDENT_OPACITY_KEY, defOpacity);
    AppStorage.setOrCreate(INDEPENDENT_OPAQUE_ON_HOVER_KEY, defHover);
    hilog.warn(0x0000, 'AppPreferences', '独立窗口风格读取失败 %d %{public}s',
      readFailure.code, readFailure.message);
  }
}

/** 保存独立窗口透明度（百分比）。立即落盘，并同步 AppStorage（供独立窗口 @Watch 实时生效）。 */
export function save_independent_window_opacity(value: number): void {
  const v: number = clamp_independent_opacity(value);
  AppStorage.setOrCreate(INDEPENDENT_OPACITY_KEY, v);
  if (store === null) {
    return;
  }
  try {
    store.putSync(PREFS_KEY_INDEPENDENT_OPACITY, v);
    store.flushSync();
  } catch (writeError) {
    const writeFailure = writeError as BusinessError;
    hilog.warn(0x0000, 'AppPreferences', '独立窗口透明度写入失败 %d %{public}s',
      writeFailure.code, writeFailure.message);
  }
}

/** 保存「悬停变不透明」开关。立即落盘并同步 AppStorage。 */
export function save_independent_window_opaque_on_hover(value: boolean): void {
  AppStorage.setOrCreate(INDEPENDENT_OPAQUE_ON_HOVER_KEY, value);
  if (store === null) {
    return;
  }
  try {
    store.putSync(PREFS_KEY_INDEPENDENT_OPAQUE_ON_HOVER, value);
    store.flushSync();
  } catch (writeError) {
    const writeFailure = writeError as BusinessError;
    hilog.warn(0x0000, 'AppPreferences', '悬停不透明开关写入失败 %d %{public}s',
      writeFailure.code, writeFailure.message);
  }
}

// ── 键盘映射（KeyboardMappingWindow / KeyboardMappingEditorWindow）──
//
// 整份设置（总开关 + 阻止原键 + 映射列表）作为一个 JSON 字符串存进 preferences，
// 解析时逐条校验（对照上游 KeyboardMappingSettingsConverter）：损坏/重复/非法版本
// 的条目被隔离，且一旦有损坏就把 enabled 置 false，等用户检查，不连累其它设置。
const PREFS_KEY_KEYBOARD_MAPPING: string = 'keyboard_mapping';

/** AppStorage 键：键盘映射设置（KeyboardMappingSettings 对象，全量）。 */
export const KEYBOARD_MAPPING_KEY: string = 'im.keyboardMapping';
/** AppStorage 键：编辑器当前要编辑的条目 id（'__new__' 表示新增）。 */
export const KEYBOARD_EDIT_TARGET_KEY: string = 'im.keyboardMapping.editTarget';

/**
 * 键盘映射 JSON 的解析结果。
 *
 * ★ 必须显式声明成 interface：ArkTS 不支持元组解构声明
 *   （arkts-no-destruct-decls），所以 `const [a, b] = f()` 这种写法不可用，
 *   多返回值一律走这里这种具名结果对象。
 */
export interface KeymapParseResult {
  settings: KeyboardMappingSettings;
  hadInvalid: boolean;   // 原数据里有被拒绝的条目/版本
}

/**
 * 把任意未知结构安全地解析成键盘映射设置。
 *
 * @returns 解析结果（settings + hadInvalid，hadInvalid 表示有被拒绝的条目/版本）。
 */
function parse_keyboard_mapping_json(text: string): KeymapParseResult {
  const def = default_keyboard_mapping_settings();
  if (text.length === 0) {
    return { settings: def, hadInvalid: false };
  }
  let root: Object | null = null;
  try {
    root = JSON.parse(text) as Object;
  } catch (e) {
    hilog.warn(0x0000, 'AppPreferences', '键盘映射 JSON 解析失败，回退默认');
    return { settings: def, hadInvalid: true };
  }
  if (root === null || typeof root !== 'object' || Array.isArray(root)) {
    return { settings: def, hadInvalid: true };
  }
  const obj = root as Record<string, Object>;
  let version: number = KEYBOARD_MAPPING_SCHEMA_VERSION;
  let enabled: boolean = false;
  let suppress: boolean = false;
  let hadInvalid: boolean = false;
  const mappings: KeyboardMappingEntry[] = [];

  if (typeof obj['schemaVersion'] === 'number') {
    version = obj['schemaVersion'] as number;
  }
  if (typeof obj['enabled'] === 'boolean') {
    enabled = obj['enabled'] as boolean;
  }
  if (typeof obj['suppressOriginalKey'] === 'boolean') {
    suppress = obj['suppressOriginalKey'] as boolean;
  }
  if (version !== KEYBOARD_MAPPING_SCHEMA_VERSION) {
    hadInvalid = true;
    version = KEYBOARD_MAPPING_SCHEMA_VERSION;
  }

  const rawList = obj['mappings'];
  if (Array.isArray(rawList)) {
    const seenIds: Set<string> = new Set<string>();
    for (let i = 0; i < rawList.length; i++) {
      const item = rawList[i] as Record<string, Object> | null;
      if (item === null || typeof item !== 'object') {
        hadInvalid = true;
        continue;
      }
      const parsed = parse_one_mapping_entry(item);
      if (parsed === null) {
        hadInvalid = true;
        continue;
      }
      if (seenIds.has(parsed.id) || mappings.length >= KEYBOARD_MAPPING_MAX_ENTRIES) {
        hadInvalid = true;
        continue;
      }
      // 与已有条目物理键冲突也视为无效（与上游 SamePhysicalKey 去重同律）
      const conflict: boolean = mappings.some((m: KeyboardMappingEntry): boolean =>
        keymap_same_key(m.key, parsed.key));
      if (conflict) {
        hadInvalid = true;
        continue;
      }
      seenIds.add(parsed.id);
      mappings.push(parsed);
    }
  }

  if (hadInvalid) {
    enabled = false;   // 有损坏 ⇒ 关闭映射，等用户检查（对照上游 HadInvalidEntries）
  }
  return {
    settings: { schemaVersion: version, enabled: enabled, suppressOriginalKey: suppress, mappings: mappings },
    hadInvalid: hadInvalid,
  };
}

/** 解析单条映射条目；任何字段缺失/越界返回 null（被隔离）。 */
function parse_one_mapping_entry(item: Record<string, Object>): KeyboardMappingEntry | null {
  const key = item['key'] as Record<string, Object> | null;
  if (key === null || typeof key !== 'object') {
    return null;
  }
  const code = key['code'];
  const label = key['label'];
  if (typeof code !== 'number' || typeof label !== 'string') {
    return null;
  }
  const action = item['action'];
  if (typeof action !== 'string' || !ALL_MAPPED_ACTIONS.includes(action as MappedTouchAction)) {
    return null;
  }
  const num = (v: Object | undefined, fallback: number): number =>
    typeof v === 'number' && Number.isFinite(v) ? v : fallback;
  const bool = (v: Object | undefined, fallback: boolean): boolean =>
    typeof v === 'boolean' ? v : fallback;
  const entry: KeyboardMappingEntry = {
    id: typeof item['id'] === 'string' ? (item['id'] as string) : new_mapping_id(),
    key: { code: code as number, label: label as string },
    action: action as MappedTouchAction,
    enabled: bool(item['enabled'], true),
    x: num(item['x'], 0.5),
    y: num(item['y'], 0.5),
    endX: num(item['endX'], 0.5),
    endY: num(item['endY'], 0.75),
    distance: num(item['distance'], 0.25),
    durationMs: num(item['durationMs'], 400),
    intervalMs: num(item['intervalMs'], 100),
    deviceCoordinates: bool(item['deviceCoordinates'], false),
  };
  // 最终再用统一校验把关一次（坐标/时长/距离/滑动终点）
  if (keymap_validate_entry(entry) !== null) {
    return null;
  }
  return entry;
}

/**
 * 读回键盘映射设置，写进 AppStorage。
 * ★ 必须在 UI 装载之前调用（EntryAbility.onCreate）。
 */
export function load_keyboard_mapping(): void {
  let settings = default_keyboard_mapping_settings();
  if (store !== null) {
    try {
      const text: string = store.getSync(PREFS_KEY_KEYBOARD_MAPPING, '') as string;
      const parsedResult: KeymapParseResult = parse_keyboard_mapping_json(text);
      settings = parsedResult.settings;
    } catch (readError) {
      const readFailure = readError as BusinessError;
      hilog.warn(0x0000, 'AppPreferences', '键盘映射读取失败 %d %{public}s',
        readFailure.code, readFailure.message);
    }
  }
  AppStorage.setOrCreate(KEYBOARD_MAPPING_KEY, settings);
  AppStorage.setOrCreate(KEYBOARD_EDIT_TARGET_KEY, '__new__');
}

/** 持久化整份键盘映射设置（写 AppStorage + 落盘）。返回是否落盘成功。 */
export function save_keyboard_mapping(settings: KeyboardMappingSettings): boolean {
  AppStorage.setOrCreate(KEYBOARD_MAPPING_KEY, settings);
  if (store === null) {
    return false;
  }
  try {
    const text: string = JSON.stringify(settings);
    store.putSync(PREFS_KEY_KEYBOARD_MAPPING, text);
    store.flushSync();
    return true;
  } catch (writeError) {
    const writeFailure = writeError as BusinessError;
    hilog.warn(0x0000, 'AppPreferences', '键盘映射写入失败 %d %{public}s',
      writeFailure.code, writeFailure.message);
    return false;
  }
}
