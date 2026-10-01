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
import {
  ACRYLIC_ALPHA_DEFAULT,
  ACRYLIC_ALPHA_KEY,
  ACRYLIC_WINDOW_KEY,
  PERSIST_READ_RESULT_KEY,
  PERSIST_WRITE_RESULT_KEY,
} from './WindowServices';

/** 偏好文件名 —— 落在应用沙箱的 preferences 目录，卸载才清。 */
const PREFS_NAME: string = 'iphone_mirror_prefs';

/** ★ preferences 里的键：与 AppStorage 的 `im.xxx` 分开命名，避免两套键被误当成同一个。 */
const PREFS_KEY_ACRYLIC_ON: string = 'acrylic_on';
const PREFS_KEY_ACRYLIC_ALPHA: string = 'acrylic_alpha';

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
