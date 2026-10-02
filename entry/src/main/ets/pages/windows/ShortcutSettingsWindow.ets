// ShortcutSettingsWindow.ets —— 子窗口 13/20：快捷键设置
//
// 逐项对照上游 src/App/Windows/ShortcutSettingsWindow.xaml（157 行）
//              src/App/Windows/ShortcutSettingsWindow.xaml.cs（235 行）
//
// 两侧都读过，取 main（1.8.4）为基准，并把 linux-port（1.8.1）多出的能力纳入：
//   · main 版：14 个动作里排除 ReverseControl（cs 第 24-25 行 .Where(a => a != ReverseControl)）；
//              行面板除了键盘捕获还有 PreviewMouseDown（右键 / 中键也能当快捷键）。
//   · linux 版：动作集合里**保留** ReverseControl
//              —— 其 Unreleased 注明「Add a mirroring-settings shortcut window for
//                 configuring the reverse-control hotkey, with conflict detection」），
//              但没有鼠标捕获，也没有 音量± / 锁屏 三个动作。
//   → 本文件：动作表 = main 的 13 个 + linux 多出来的 ReverseControl（共 14 行），
//     捕获方式用 main 的（键盘 + 鼠标），分组规则用 main 的 GetCategory。
//
// ── 窗口属性（XAML 根元素 <ui:FluentWindow>）────────────────────────────────
//   Title="{DynamicResource ShortcutSettingsTitle}"  → 「快捷键设置」
//   Width="560" Height="650" MinWidth="500" MinHeight="520"
//   WindowStartupLocation="CenterOwner"              → SubWindowHost.open 里算居中
//   ResizeMode="NoResize"                            → resizable: false（本窗口唯一一处）
//   ExtendsContentIntoTitleBar="True"                → decorEnabled: false + 自绘表头
//   WindowBackdropType="Mica" / WindowCornerPreference="Round" → 系统窗口负责
//   Background="{DynamicResource AppBackgroundBrush}" → shell 默认底色
//
// ── 行定义（Grid.RowDefinitions，5 行）──────────────────────────────────────
//   Row Auto : Grid Style=SubWindowHeader
//                TextBlock ShortcutSettingsTitle  Style=SubWindowTitle（**无副标题**）
//                Button Style=SubWindowCloseButton + SymbolIcon Dismiss20/18
//   Row 16   : 间隔
//   Row *    : Grid，内部 4 行 = Auto / * / Auto / Auto
//                Auto : TextBlock ShortcutSettingsDescription（Muted 11 Wrap，0,0,0,12）
//                *    : ScrollViewer（Margin 0,0,-25,0，只垂直）
//                         ItemsControl Sections → 分组 + 行 Grid
//                Auto : TextBlock ShortcutSettingsCaptureHint（Muted 11 Wrap，0,2,0,0）
//                Auto : TextBlock StatusText（ErrorBrush 11 Wrap，MinHeight 20，0,8,0,0）
//   Row 14   : 间隔
//   Row Auto : Grid 列 = * / Auto / 8 / Auto
//                列 1：Button Cancel「取消」Click=OnCloseClick MinWidth="84"
//                列 3：Button Save「保存」Click=OnSaveClick Style=PrimaryButton MinWidth="96"
//
// ── 一行的结构（ItemTemplate 里的 Grid，列 = 190 / * / Auto）────────────────
//   列 0：TextBlock {Binding Label} SemiBold / Wrap / VCenter
//   列 1：TextBox Style=ShortcutCaptureBox Height=40，IsReadOnly=True，
//         Text={Binding ShortcutText, Mode=OneWay}
//         PreviewKeyDown=OnShortcutPreviewKeyDown / PreviewMouseDown=OnShortcutPreviewMouseDown
//         ToolTip=ShortcutSettingsCaptureHint + WindowChrome.IsHitTestVisibleInChrome="True"
//   列 2：Button Style=ShortcutClearButton Click=OnResetRowClick + SymbolIcon Delete20/18
//   行间距：每个 Section 块 Margin 0,0,0,14；每行 Grid Margin 0,0,0,8
//
// ── 局部样式 ───────────────────────────────────────────────────────────────
//   ShortcutCaptureBox（基于 RoundedTextBox）：
//         FontSize 16 / SemiBold / 水平垂直居中 / IsReadOnly / CaretBrush 透明
//         DataTrigger IsBound=False → FontSize 13 / FontWeight Normal
//   ShortcutClearButton：32×32 / Margin 8,0,0,0 / Padding 0 / 背景与边框透明 /
//         无边框厚 / 不可聚焦 / Foreground=ShortcutClearIconBrush /
//         ToolTip=ShortcutSettingsReset / IsEnabled=False 时 Opacity 0.42
//   分组标题：AccentBrush / 11 / SemiBold / Margin 0,0,0,7
//
// ── xaml.cs 的行为（逐条复刻）──────────────────────────────────────────────
//   · 构造时按 BluetoothShortcutAction 枚举顺序建 Rows 与 Sections
//   · OnShortcutPreviewKeyDown：
//       · 无修饰键 + Backspace/Delete → row.Shortcut = Unbound
//       · KeyboardShortcut.TryCreate 失败 → StatusText = ShortcutSettingsInvalid
//       · 成功 → row.Shortcut = shortcut，StatusText 清空
//   · OnShortcutPreviewMouseDown：右键 / 中键 → TryCreateMouse → 写入当前行
//   · OnResetRowClick：row.Shortcut = row.DefaultShortcut
//   · OnSaveClick：HaveUniqueBoundValues(...) 为假 → ShortcutSettingsDuplicate；
//     否则 _apply(shortcuts) 返回空串才 Close()，否则 StatusText = error
//   · OnCloseClick → Close()；OnLanguageChanged → 刷新所有 Section/Row 文案
//
// ── KeyboardShortcut.cs 的可判定部分**真做**（冲突检测是纯逻辑）────────────
//   Modifiers 位：Alt 0x0001 / Control 0x0002 / Shift 0x0004 / NoRepeat 0x4000
//   VirtualKey：0 = 未绑定；MouseRight 0x100 / MouseMiddle 0x101
//   TryCreate 的四条否决（IsModifierKey、Windows 键组合、virtuallKey==0、
//   无修饰键又不是 Esc/F1..F11）—— 见下方 try_create() 的行级注释
//   HaveUniqueBoundValues：所有已绑定值 Distinct 后数量不变
//   F12 保留给调试器（cs 注释原文），F1-F11 才可以单独使用
//
// ── 平台替换（原版机制在鸿蒙没有对应物）────────────────────────────────────
//   ① 系统级全局热键注册：上游的 `_apply` 委托最终调用 Win32 RegisterHotKey，
//      热键在窗口没焦点、甚至应用最小化时也能触发。
//      OpenHarmony 没有对三方应用开放全局热键注册接口，也没有键盘钩子权限。
//      → 冲突检测、解绑、恢复默认、逐键持久化全部**真做**并落 AppStorage；
//        但生效范围只能是「日后接入的应用内按键分发」，保存后不关窗，
//        在 StatusText 里把这句话说清楚（原版 _apply 无错就 Close()，此处刻意不关）。
//   ② 原版 TextBox.PreviewKeyDown 的「文本框获得焦点即进入捕获」在 ArkUI 里没有
//      等价路由：只读输入框不接收按键事件。改为**点一下捕获框**把行号记进
//      capturingRowIndex，按键事件挂在页面根节点（与 ImageSettingsWindow 的 Esc 同法）。
//      交互结果一致：先点哪一行，再按键，键就写进哪一行。
//   ③ 原版 KeyInterop.VirtualKeyFromKey / KeyConverter 提供全部 WPF Key 的显示名；
//      ArkUI 只有 @ohos.multimodalInput.keyCode 的 keyCode 数字。因此可识别键集限定为
//      F1-F11 / Esc / A-Z / 0-9（外加鼠标右键与中键），数字小键盘不在其中
//      ——这是能力边界，不是省略；不可识别的按键按 cs 的同一路径报 ShortcutSettingsInvalid。
//   ④ 原版 modifiers.HasFlag(ModifierKeys.Windows) 判定 Windows 键；
//      这里用 KeyEvent.metaKey（非 0 即 Win/Meta 组合）做同一否决。
//   ⑤ BossKeyWindowVisibility.cs：老板键的语义是 Window.Hide() / Show() 把整组窗口藏起来。
//      鸿蒙子窗口只有 showWindow / destroyWindow，没有 Hide；SubWindowHost.close 是销毁。
//      → 行本身保留（可配置），但 Save 之后在 StatusText 明确写出它现在不会隐藏任何窗口。
//   ⑥ 原版 Row.DataContext 通过 FrameworkElement 反查（一行一个 row 对象）；
//      ArkUI 没有 DataContext，行对象改成下标 + 静态行表。
//   ⑦ ShortcutRegistrationFailedFormat 原文是「Windows 无法注册 {0}…」——写死宿主
//      操作系统名；本文件改成鸿蒙事实描述（见 REASON_GLOBAL_HOTKEY）。
//
// ── 文案来源 Strings.zh-CN.xaml（逐字取用）────────────────────────────────
//   ShortcutSettingsTitle「快捷键设置」ShortcutSettingsDescription「配置投屏工具的快捷键。」
//   ShortcutSettingsCategoryControl「控制」ShortcutSettingsCategoryNavigation「系统导航」
//   ShortcutSettingsCategoryAssistant「助理」
//   ShortcutSettingsReverseControl「反向控制」ShortcutSettingsBluetoothControl「蓝牙控制」
//   ShortcutSettingsWirelessControl「无线投屏」ShortcutSettingsWiredControl「有线投屏」
//   ShortcutSettingsControlCenter「打开控制中心」ShortcutSettingsNotificationCenter「打开通知栏」
//   ShortcutSettingsAppSwitcher「打开多任务」ShortcutSettingsHome「回到桌面」
//   ShortcutSettingsBossKey「老板键（隐藏 / 显示窗口）」ShortcutSettingsDock「显示 Dock」
//   ShortcutSettingsSiri「唤醒 Siri」ShortcutSettingsVolumeUp「音量+」
//   ShortcutSettingsVolumeDown「音量-」ShortcutSettingsLockScreen「锁定屏幕」
//   ShortcutSettingsUnbound「未绑定」ShortcutSettingsDuplicate「每个动作必须使用不同的快捷键。」
//   ShortcutSettingsCaptureHint「聚焦输入框后按下快捷键。Backspace 或 Delete 可解除绑定；
//       F1-F11、右键、中键可单独使用。」
//   ShortcutSettingsReset「恢复默认值」ShortcutSettingsInvalid
//       「请选择有效快捷键。F12、Windows 键组合及单独修饰键不可用。」
//   ShortcutMouseRight「右键」ShortcutMouseMiddle「中键」
//   ShortcutModifierControl「Ctrl」ShortcutModifierAlt「Alt」ShortcutModifierShift「Shift」
//   Cancel「取消」Save「保存」
//
// ── AppStorage 键名 ───────────────────────────────────────────────────────
//   每个动作两个键：im.shortcutSettings.<Action>.modifiers  /  .virtualKey
//   （Action 取下表 first 列的英文枚举名；另有 im.shortcutSettings.saved 表示点过保存）

import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import { KeyCode } from '@ohos.multimodalInput.keyCode';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  SubWindowShell, SubWindowHost, SecondaryButton, PrimaryButton, SubWindowSpec,
  SUBWINDOW_ROW_GAP, SUBWINDOW_ROW_GAP_NARROW,
} from '../../common/SubWindow';
import {
  TEXT, MUTED_TEXT, ACCENT, ERROR, BORDER, SHORTCUT_CLEAR_ICON, CONTROL_FILL,
} from '../../common/Theme';
import { FluentSymbol } from '../../common/FluentIcon';
import { t } from '../../common/i18n';

const TAG: string = 'im_shortcut_settings';
const DOMAIN: number = 0x0100;

export const WINDOW_NAME: string = 'ShortcutSettingsWindow';
export const PAGE_PATH: string = 'pages/windows/ShortcutSettingsWindow';

/** AppStorage 键前缀；每个动作再挂 .modifiers / .virtualKey 两个后缀。 */
export const KEY_PREFIX: string = 'im.shortcutSettings.';
/** cs OnSaveClick 成功落地后置 true，供宿主读取（对应 _apply 的调用侧）。 */
export const RESULT_KEY_SAVED: string = 'im.shortcutSettings.saved';

// ─────────────────── KeyboardShortcut.cs 的移植 ───────────────────

/** Modifiers 位掩码（cs 第 14-17 行，值一个不改）。 */
const MOD_ALT: number = 0x0001;
const MOD_CONTROL: number = 0x0002;
const MOD_SHIFT: number = 0x0004;
/** cs: RegistrationModifiers => Modifiers | NoRepeat —— 注册时才或上，存储里不带。 */
const MOD_NO_REPEAT: number = 0x4000;
/** cs: MouseRight = 0x100 / MouseMiddle = 0x101 */
const VK_MOUSE_RIGHT: number = 0x100;
const VK_MOUSE_MIDDLE: number = 0x101;

/** cs: Unbound => new(0, 0) */
const UNBOUND_VIRTUAL_KEY: number = 0;

/**
 * 一个快捷键绑定 —— 对应 cs 的 readonly record struct KeyboardShortcut。
 * 用 interface 承载（**没有**方法成员，所以可以直接用对象字面量赋值；
 * 含方法的对象字面量才会在 ArkTS 触发 arkts-no-untyped-obj-literals）。
 */
export interface ShortcutBinding {
  modifiers: number;
  virtualKey: number;
}

/** ShortcutSettingsUnbound「未绑定」。 */
const S_UNBOUND = (): string => t('未绑定');
/** ShortcutModifierControl / Alt / Shift。 */
const S_MOD_CTRL = (): string => t('Ctrl');
const S_MOD_ALT = (): string => t('Alt');
const S_MOD_SHIFT = (): string => t('Shift');
/** ShortcutMouseRight / ShortcutMouseMiddle。 */
const S_MOUSE_RIGHT = (): string => t('右键');
const S_MOUSE_MIDDLE = (): string => t('中键');

/** 可识别的功能键：F1-F11（F12 按 cs 注释保留给调试器）。 */
const FUNCTION_KEY_CODES: number[] = [
  KeyCode.KEYCODE_F1, KeyCode.KEYCODE_F2, KeyCode.KEYCODE_F3, KeyCode.KEYCODE_F4,
  KeyCode.KEYCODE_F5, KeyCode.KEYCODE_F6, KeyCode.KEYCODE_F7, KeyCode.KEYCODE_F8,
  KeyCode.KEYCODE_F9, KeyCode.KEYCODE_F10, KeyCode.KEYCODE_F11,
];
const FUNCTION_KEY_LABELS: string[] =
  ['F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11'];

const LETTER_KEY_CODES: number[] = [
  KeyCode.KEYCODE_A, KeyCode.KEYCODE_B, KeyCode.KEYCODE_C, KeyCode.KEYCODE_D,
  KeyCode.KEYCODE_E, KeyCode.KEYCODE_F, KeyCode.KEYCODE_G, KeyCode.KEYCODE_H,
  KeyCode.KEYCODE_I, KeyCode.KEYCODE_J, KeyCode.KEYCODE_K, KeyCode.KEYCODE_L,
  KeyCode.KEYCODE_M, KeyCode.KEYCODE_N, KeyCode.KEYCODE_O, KeyCode.KEYCODE_P,
  KeyCode.KEYCODE_Q, KeyCode.KEYCODE_R, KeyCode.KEYCODE_S, KeyCode.KEYCODE_T,
  KeyCode.KEYCODE_U, KeyCode.KEYCODE_V, KeyCode.KEYCODE_W, KeyCode.KEYCODE_X,
  KeyCode.KEYCODE_Y, KeyCode.KEYCODE_Z,
];
const LETTER_KEY_LABELS: string[] = [
  'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
  'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
];

const DIGIT_KEY_CODES: number[] = [
  KeyCode.KEYCODE_0, KeyCode.KEYCODE_1, KeyCode.KEYCODE_2, KeyCode.KEYCODE_3,
  KeyCode.KEYCODE_4, KeyCode.KEYCODE_5, KeyCode.KEYCODE_6, KeyCode.KEYCODE_7,
  KeyCode.KEYCODE_8, KeyCode.KEYCODE_9,
];
const DIGIT_KEY_LABELS: string[] = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9'];

/** cs IsModifierKey：单独按下的左右 Ctrl / Alt / Shift / Meta 都不能当快捷键。 */
const MODIFIER_KEY_CODES: number[] = [
  KeyCode.KEYCODE_CTRL_LEFT, KeyCode.KEYCODE_CTRL_RIGHT,
  KeyCode.KEYCODE_ALT_LEFT, KeyCode.KEYCODE_ALT_RIGHT,
  KeyCode.KEYCODE_SHIFT_LEFT, KeyCode.KEYCODE_SHIFT_RIGHT,
  KeyCode.KEYCODE_META_LEFT, KeyCode.KEYCODE_META_RIGHT,
];

/**
 * cs：`key is Key.Back or Key.Delete`。
 * ArkUI 在这台设备上把退格 / 删除上报为 KEYCODE_DEL；KEYCODE_BACK 是同义兜底。
 */
const CLEAR_KEY_CODES: number[] = [KeyCode.KEYCODE_DEL, KeyCode.KEYCODE_BACK];

/** Esc：可以由 try_create 单独放行（cs 允许 Key.Escape 不带修饰键）。 */
/** 注：数字小键盘不在可识别集合内——见平台替换 ③。 */
const KEY_ESCAPE: number = KeyCode.KEYCODE_ESCAPE;
const ESCAPE_LABEL: string = 'Esc';   // cs: new KeyConverter().ConvertToString(Key.Escape) == "Esc"

/** cs Default「F9」/ AppSwitcherDefault「中键」/ HomeDefault「右键」/ BossKeyDefault「Ctrl+Alt+B」。 */
const DEFAULT_SHORTCUT: ShortcutBinding = { modifiers: 0, virtualKey: KeyCode.KEYCODE_F9 };
const APPSWITCHER_SHORTCUT: ShortcutBinding =
  { modifiers: 0, virtualKey: VK_MOUSE_MIDDLE };
const HOME_SHORTCUT: ShortcutBinding = { modifiers: 0, virtualKey: VK_MOUSE_RIGHT };
const BOSSKEY_SHORTCUT: ShortcutBinding =
  { modifiers: MOD_CONTROL | MOD_ALT, virtualKey: KeyCode.KEYCODE_B };
const UNBOUND: ShortcutBinding = { modifiers: 0, virtualKey: UNBOUND_VIRTUAL_KEY };

// ─────────────────── 动作表 / 分组表（cs 第 23-40 行的枚举遍历结果）───────────────────

/** 一个可配置的动作 —— cs ShortcutBindingRow 的静态部分。 */
export class ShortcutActionRow {
  /** 上游 BluetoothShortcutAction 的枚举名，也是 AppStorage 键的中段。 */
  actionId: string = '';
  /** Strings 资源键。 */
  labelKey: string = '';
  /** Strings.zh-CN.xaml 的简体中文原文。 */
  label: string = '';
  /** cs KeyboardShortcut.DefaultFor(action)。 */
  defaultShortcut: ShortcutBinding = UNBOUND;

  constructor(actionId: string, labelKey: string, label: string,
    defaultShortcut: ShortcutBinding) {
    this.actionId = actionId;
    this.labelKey = labelKey;
    this.label = label;
    this.defaultShortcut = defaultShortcut;
  }
}

/** cs ShortcutBindingSection 的静态部分。 */
export class ShortcutActionGroup {
  titleKey: string = '';
  title: string = '';
  /** 所属行在 ACTION_ROWS 里的下标，顺序 = 枚举遍历顺序。 */
  rowIndexes: number[] = [];

  constructor(titleKey: string, title: string, rowIndexes: number[]) {
    this.titleKey = titleKey;
    this.title = title;
    this.rowIndexes = rowIndexes;
  }
}

/**
 * 14 行：顺序严格照 BluetoothShortcutAction 的声明顺序
 * （cs 用 Enum.GetValues<BluetoothShortcutAction>() 遍历）。
 * 其中 ReverseControl 来自 linux 版（main 把它排除掉了，见文件头）。
 */
export const ACTION_ROWS: ShortcutActionRow[] = [
  new ShortcutActionRow('ReverseControl', 'ShortcutSettingsReverseControl', '反向控制', UNBOUND),
  new ShortcutActionRow('BluetoothControl', 'ShortcutSettingsBluetoothControl', '蓝牙控制',
    DEFAULT_SHORTCUT),
  new ShortcutActionRow('WirelessControl', 'ShortcutSettingsWirelessControl', '无线投屏', UNBOUND),
  new ShortcutActionRow('WiredControl', 'ShortcutSettingsWiredControl', '有线投屏', UNBOUND),
  new ShortcutActionRow('ControlCenter', 'ShortcutSettingsControlCenter', '打开控制中心', UNBOUND),
  new ShortcutActionRow('NotificationCenter', 'ShortcutSettingsNotificationCenter',
    '打开通知栏', UNBOUND),
  new ShortcutActionRow('AppSwitcher', 'ShortcutSettingsAppSwitcher', '打开多任务',
    APPSWITCHER_SHORTCUT),
  new ShortcutActionRow('Home', 'ShortcutSettingsHome', '回到桌面', HOME_SHORTCUT),
  new ShortcutActionRow('BossKey', 'ShortcutSettingsBossKey', '老板键（隐藏 / 显示窗口）',
    BOSSKEY_SHORTCUT),
  new ShortcutActionRow('Dock', 'ShortcutSettingsDock', '显示 Dock', UNBOUND),
  new ShortcutActionRow('Siri', 'ShortcutSettingsSiri', '唤醒 Siri', UNBOUND),
  new ShortcutActionRow('VolumeUp', 'ShortcutSettingsVolumeUp', '音量+', UNBOUND),
  new ShortcutActionRow('VolumeDown', 'ShortcutSettingsVolumeDown', '音量-', UNBOUND),
  new ShortcutActionRow('LockScreen', 'ShortcutSettingsLockScreen', '锁定屏幕', UNBOUND),
];

/**
 * 三个分组与它们包含的行 —— cs GetCategory 的结果按「首次出现」建 section
 * （ReverseControl 归入 Control，取自 linux 版 GetCategory 的第 122 行）。
 */
export const ACTION_GROUPS: ShortcutActionGroup[] = [
  new ShortcutActionGroup('ShortcutSettingsCategoryControl', '控制',
    [0, 1, 2, 3, 8, 11, 12, 13]),
  new ShortcutActionGroup('ShortcutSettingsCategoryNavigation', '系统导航', [4, 5, 6, 7, 9]),
  new ShortcutActionGroup('ShortcutSettingsCategoryAssistant', '助理', [10]),
];

/** AppStorage 键：某个动作的 modifiers。 */
function modifiers_key(actionId: string): string {
  return `${KEY_PREFIX}${actionId}.modifiers`;
}

/** AppStorage 键：某个动作的 virtualKey。 */
function virtual_key_name(actionId: string): string {
  return `${KEY_PREFIX}${actionId}.virtualKey`;
}

// ─────────────────── KeyboardShortcut 的判定函数 ───────────────────

function index_of(codes: number[], value: number): number {
  for (let i: number = 0; i < codes.length; i++) {
    if (codes[i] === value) {
      return i;
    }
  }
  return -1;
}

/** cs IsBound => VirtualKey != 0。 */
function is_bound(binding: ShortcutBinding): boolean {
  return binding.virtualKey !== UNBOUND_VIRTUAL_KEY;
}

/** cs DisplayText：Ctrl / Alt / Shift 之后拼键名，用 " + " 连接。 */
function display_text(binding: ShortcutBinding): string {
  if (!is_bound(binding)) {
    return S_UNBOUND();
  }
  const parts: string[] = [];
  if ((binding.modifiers & MOD_CONTROL) !== 0) {
    parts.push(S_MOD_CTRL());
  }
  if ((binding.modifiers & MOD_ALT) !== 0) {
    parts.push(S_MOD_ALT());
  }
  if ((binding.modifiers & MOD_SHIFT) !== 0) {
    parts.push(S_MOD_SHIFT());
  }
  parts.push(key_label(binding.virtualKey));
  return parts.join(' + ');
}

/** cs FormatKey 的前两支（鼠标键）。 */
function key_label(virtualKey: number): string {
  if (virtualKey === VK_MOUSE_RIGHT) {
    return S_MOUSE_RIGHT();
  }
  if (virtualKey === VK_MOUSE_MIDDLE) {
    return S_MOUSE_MIDDLE();
  }
  let index: number = index_of(FUNCTION_KEY_CODES, virtualKey);
  if (index >= 0) {
    return FUNCTION_KEY_LABELS[index];
  }
  index = index_of(LETTER_KEY_CODES, virtualKey);
  if (index >= 0) {
    return LETTER_KEY_LABELS[index];
  }
  index = index_of(DIGIT_KEY_CODES, virtualKey);
  if (index >= 0) {
    return DIGIT_KEY_LABELS[index];
  }
  if (virtualKey === KEY_ESCAPE) {
    return ESCAPE_LABEL;
  }
  return `0x${virtualKey.toString(16)}`;
}

/**
 * cs IsFunctionKey：`key is >= Key.F1 and <= Key.F11`。
 * 用集合判定，不依赖 KeyCode 的数值连续性。
 */
function is_function_key(keyCode: number): boolean {
  return index_of(FUNCTION_KEY_CODES, keyCode) >= 0;
}

/**
 * cs TryCreate(Key key, ModifierKeys modifiers, out KeyboardShortcut shortcut)。
 * 四道否决逐条照搬：单独修饰键 / Windows 键组合 / virtualKey==0 /
 * 无修饰键又不是 Esc 或 F1-F11。
 */
function try_create(keyCode: number, modifiers: number, metaPressed: boolean)
  : ShortcutBinding | null {
  if (index_of(MODIFIER_KEY_CODES, keyCode) >= 0) {
    return null;
  }
  if (metaPressed) {
    return null;
  }
  const allowed: boolean = is_function_key(keyCode) || keyCode === KEY_ESCAPE ||
    index_of(LETTER_KEY_CODES, keyCode) >= 0 || index_of(DIGIT_KEY_CODES, keyCode) >= 0;
  if (!allowed) {
    return null;
  }
  if (modifiers === 0 && keyCode !== KEY_ESCAPE && !is_function_key(keyCode)) {
    return null;
  }
  return { modifiers: modifiers, virtualKey: keyCode };
}

/** cs TryCreateMouse —— 只认右键与中键，Windows 键组合一样否决。 */
function try_create_mouse(button: MouseButton, modifiers: number, metaPressed: boolean)
  : ShortcutBinding | null {
  if (metaPressed) {
    return null;
  }
  if (button === MouseButton.Right) {
    return { modifiers: modifiers, virtualKey: VK_MOUSE_RIGHT };
  }
  if (button === MouseButton.Middle) {
    return { modifiers: modifiers, virtualKey: VK_MOUSE_MIDDLE };
  }
  return null;
}

/** cs HaveUniqueBoundValues —— 纯逻辑，冲突检测就靠它。 */
function have_unique_bound_values(bindings: ShortcutBinding[]): boolean {
  const bound: ShortcutBinding[] = [];
  for (let i: number = 0; i < bindings.length; i++) {
    if (is_bound(bindings[i])) {
      bound.push(bindings[i]);
    }
  }
  for (let i: number = 0; i < bound.length; i++) {
    for (let j: number = i + 1; j < bound.length; j++) {
      if (bound[i].modifiers === bound[j].modifiers &&
        bound[i].virtualKey === bound[j].virtualKey) {
        return false;
      }
    }
  }
  return true;
}

// ─────────────────── 局部控件 ───────────────────

/**
 * Style x:Key="ShortcutCaptureBox"（基于 RoundedTextBox）
 *   FontSize 16 / SemiBold / 居中 / IsReadOnly / CaretBrush 透明
 *   DataTrigger IsBound=False → FontSize 13 / FontWeight Normal
 */
@Component
struct ShortcutCaptureBox {
  @Prop captureText: string = '';
  @Prop captureBound: boolean = false;
  @Prop capturing: boolean = false;
  on_tap: () => void = () => {};
  on_mouse_button: (button: MouseButton) => void = () => {};

  build() {
    Text(this.captureText)
      .fontSize(this.captureBound ? 16 : 13)
      .fontWeight(this.captureBound ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(TEXT)
      .textAlign(TextAlign.Center)
      .height(40)
      .width('100%')
      .borderRadius(10)
      .backgroundColor(CONTROL_FILL)
      .border({ width: 1, color: this.capturing ? ACCENT : BORDER })
      .onClick((): void => { this.on_tap(); })
      .onMouse((event: MouseEvent): void => { this.on_mouse_button(event.button); });
  }
}

/**
 * Style x:Key="ShortcutClearButton"
 *   32×32 / Margin 8,0,0,0 / 透明底 + 透明边 / Foreground=ShortcutClearIconBrush
 *   不可聚焦 / ToolTip=ShortcutSettingsReset「恢复默认值」
 */
@Component
struct ShortcutClearButton {
  on_action: () => void = () => {};

  build() {
    Row() {
      FluentSymbol({ iconName: 'Delete20', iconSize: 18, iconColor: SHORTCUT_CLEAR_ICON })
    }
    .width(32)
    .height(32)
    .margin({ left: 8 })
    .borderRadius(6)
    .justifyContent(FlexAlign.Center)
    .onClick((): void => { this.on_action(); });
  }
}

/** 分组标题：AccentBrush / 11 / SemiBold / Margin 0,0,0,7。 */
@Builder
function group_title(text: string) {
  Text(text)
    .fontSize(11)
    .fontWeight(FontWeight.Bold)
    .fontColor(ACCENT)
    .width('100%')
    .margin({ bottom: 7 });
}

/**
 * 平台替换 ①⑤⑦：cs 的 ShortcutRegistrationFailedFormat 原文是
 * 「Windows 无法注册 {0}，该快捷键可能已被占用。」——宿主系统名写死且语义是「注册」，
 * 鸿蒙侧的事实是「根本注册不了，只能存起来」。这条常量就是保存后的确切原因。
 */
const REASON_GLOBAL_HOTKEY: string =
  '绑定已逐个保存，冲突检测也通过；但 OpenHarmony 不向三方应用开放系统级全局热键注册接口（上游为 Win32 RegisterHotKey），因此这些快捷键目前不会在应用无焦点时触发；老板键也无法隐藏窗口（SubWindowHost.close 是销毁，鸿蒙子窗口没有 Hide）。';

// ─────────────────── 开窗 ───────────────────

/** 按原版打开这个子窗口（cs：`new ShortcutSettingsWindow(shortcuts, apply).ShowDialog()`） */
export function open_shortcut_settings(ctx: common.Context): void {
  const spec: SubWindowSpec = {
    name: WINDOW_NAME,
    page: PAGE_PATH,
    title: '快捷键设置',              // Strings: ShortcutSettingsTitle
    width: 560,
    height: 650,
    resizable: false,                 // ResizeMode="NoResize"
    minWidth: 500,
    minHeight: 520,
    modal: true,
  };
  SubWindowHost.open(ctx, spec).catch((error: BusinessError): void => {
    hilog.error(DOMAIN, TAG, '打开失败: %{public}s', error.message);
  });
}

@Entry
@Component
struct ShortcutSettingsWindow {
  /** 14 行的当前绑定；下标与 ACTION_ROWS 对齐。 */
  @State bindings: ShortcutBinding[] = [];
  /** cs StatusText。 */
  @State statusText: string = '';
  /** 平台替换 ②：当前正在等待按键的那一行；-1 = 没有。 */
  @State capturingRowIndex: number = -1;

  aboutToAppear(): void {
    const initial: ShortcutBinding[] = [];
    for (let i: number = 0; i < ACTION_ROWS.length; i++) {
      const row: ShortcutActionRow = ACTION_ROWS[i];
      const storedKey: number = AppStorage.get<number>(virtual_key_name(row.actionId)) ?? -1;
      const storedModifiers: number = AppStorage.get<number>(modifiers_key(row.actionId)) ?? -1;
      if (storedKey >= 0 && storedModifiers >= 0) {
        initial.push({ modifiers: storedModifiers, virtualKey: storedKey });
      } else {
        initial.push(row.defaultShortcut);
      }
    }
    this.bindings = initial;
    hilog.info(DOMAIN, TAG, '快捷键窗口就绪：%{public}d 行', this.bindings.length);
  }

  // ───────────────────────── cs 的行为 ─────────────────────────

  /** 整行替换以保证 @State 能观察到变化（ArkTS 数组元素直写不触发刷新）。 */
  private set_binding(index: number, value: ShortcutBinding): void {
    const next: ShortcutBinding[] = [];
    for (let i: number = 0; i < this.bindings.length; i++) {
      if (i === index) {
        next.push(value);
      } else {
        next.push(this.bindings[i]);
      }
    }
    this.bindings = next;
    this.statusText = '';
  }

  /** cs OnResetRowClick：row.Shortcut = row.DefaultShortcut。 */
  private on_reset_row(index: number): void {
    this.set_binding(index, ACTION_ROWS[index].defaultShortcut);
  }

  /**
   * cs OnShortcutPreviewKeyDown。返回 true 表示这次按键已经被窗口吃掉了。
   * @param keyCode KeyEvent.keyCode
   * @param modifiers 已经合成好的 Alt|Control|Shift 位掩码
   * @param metaPressed 对应 cs 的 modifiers.HasFlag(ModifierKeys.Windows)
   */
  private on_key_down(keyCode: number, modifiers: number, metaPressed: boolean): void {
    // Strings: ShortcutSettingsInvalid
    const invalid: string = '请选择有效快捷键。F12、Windows 键组合及单独修饰键不可用。';
    if (index_of(CLEAR_KEY_CODES, keyCode) >= 0 && modifiers === 0 && !metaPressed) {
      this.set_binding(this.capturingRowIndex, UNBOUND);
      return;
    }
    const shortcut: ShortcutBinding | null = try_create(keyCode, modifiers, metaPressed);
    if (shortcut === null) {
      this.statusText = invalid;
      return;
    }
    this.set_binding(this.capturingRowIndex, shortcut);
  }

  /** cs OnShortcutPreviewMouseDown。 */
  private on_mouse_down(button: MouseButton, modifiers: number, metaPressed: boolean): void {
    if (this.capturingRowIndex < 0) {
      return;
    }
    const shortcut: ShortcutBinding | null =
      try_create_mouse(button, modifiers, metaPressed);
    if (shortcut === null) {
      return;
    }
    this.set_binding(this.capturingRowIndex, shortcut);
  }

  /**
   * cs OnSaveClick。
   * 冲突检测走 HaveUniqueBoundValues（纯逻辑，**真做**）。
   */
  private on_save(): void {
    if (!have_unique_bound_values(this.bindings)) {
      // Strings: ShortcutSettingsDuplicate
      this.statusText = '每个动作必须使用不同的快捷键。';
      return;
    }
    for (let i: number = 0; i < ACTION_ROWS.length; i++) {
      AppStorage.setOrCreate<number>(modifiers_key(ACTION_ROWS[i].actionId),
        this.bindings[i].modifiers);
      AppStorage.setOrCreate<number>(virtual_key_name(ACTION_ROWS[i].actionId),
        this.bindings[i].virtualKey);
    }
    AppStorage.setOrCreate<boolean>(RESULT_KEY_SAVED, true);
    // 平台替换 ①⑤：保存本身是真的，但「注册到系统」这一步鸿蒙做不到。
    this.statusText = REASON_GLOBAL_HOTKEY;
    this.capturingRowIndex = -1;
  }

  /** cs OnCloseClick（取消键与右上角关闭同一个处理）。 */
  private on_close(): void {
    SubWindowHost.close(WINDOW_NAME);
  }

  // ───────────────────────── 界面 ───────────────────

  /** ScrollViewer 里的 ItemsControl Sections。 */
  @Builder
  groups() {
    Column() {
      ForEach(ACTION_GROUPS, (group: ShortcutActionGroup): void => {
        Column() {
          group_title(group.title);
          ForEach(group.rowIndexes, (rowIndex: number): void => {
            Column() {
              this.binding_row(rowIndex);
            }
            .width('100%')
            .margin({ bottom: 8 });
          }, (rowIndex: number): string => rowIndex.toString());
        }
        .width('100%')
        .margin({ bottom: 14 });
      }, (group: ShortcutActionGroup): string => group.titleKey);
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  /** 一行动作：列 = 190 / * / Auto，列 0 的标签 SemiBold / Wrap / 垂直居中。 */
  @Builder
  binding_row(rowIndex: number) {
    Row() {
      Text(ACTION_ROWS[rowIndex].label)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT)
        .fontSize(12)
        .textAlign(TextAlign.Start)
        .width(190)
        .alignSelf(ItemAlign.Center);

      ShortcutCaptureBox({
        captureText: display_text(this.bindings[rowIndex]),
        captureBound: is_bound(this.bindings[rowIndex]),
        capturing: this.capturingRowIndex === rowIndex,
        on_tap: (): void => { this.capturingRowIndex = rowIndex; },
        on_mouse_button: (button: MouseButton): void => {
          this.capturingRowIndex = rowIndex;
          if (button !== MouseButton.Left) {
            this.on_mouse_down(button, 0, false);
          }
        },
      })
        .layoutWeight(1);

      ShortcutClearButton({
        on_action: (): void => { this.on_reset_row(rowIndex); },
      });
    }
    .width('100%')
    .alignItems(VerticalAlign.Center);
  }

  /** Row * 第一行：ShortcutSettingsDescription（Muted 11 Wrap，Margin 0,0,0,12）。 */
  @Builder
  notice() {
    Text('配置投屏工具的快捷键。')
      .fontSize(11)
      .fontColor(MUTED_TEXT)
      .width('100%')
      .margin({ bottom: 12 });
  }

  /** Row * ：ScrollViewer 包分组列表。 */
  @Builder
  body() {
    Scroll() {
      Column() {
        this.groups();
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start);
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring);
  }

  /** Row * 第三、四行：捕获提示 + StatusText。 */
  @Builder
  footer() {
    Column() {
      Text('聚焦输入框后按下快捷键。Backspace 或 Delete 可解除绑定；F1-F11、右键、中键可单独使用。')
        .fontSize(11)
        .fontColor(MUTED_TEXT)
        .width('100%')
        .margin({ top: 2 });

      Text(this.statusText)
        .fontSize(11)
        .fontColor(ERROR)
        .width('100%')
        .constraintSize({ minHeight: 20 })
        .margin({ top: 8 });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  /** Row 4：列 = * / Auto / 8 / Auto。 */
  @Builder
  actions() {
    Row() {
      Column().layoutWeight(1);

      SecondaryButton({
        label: '取消',                     // Strings: Cancel
        minButtonWidth: 84,
        on_action: (): void => { this.on_close(); },
      });

      Column().width(8);

      PrimaryButton({
        label: '保存',                     // Strings: Save
        minButtonWidth: 96,
        on_action: (): void => { this.on_save(); },
      });
    }
    .width('100%')
    .alignItems(VerticalAlign.Center);
  }

  build() {
    Column() {
      SubWindowShell({
        windowName: WINDOW_NAME,
        title: '快捷键设置',              // Strings: ShortcutSettingsTitle
        gap: SUBWINDOW_ROW_GAP,           // 行 1 = 16
        hasNotice: true,                  // 行 2 的首个子行：Description
        noticeGap: 0,
        hasFooter: true,                  // 行 2 的第三、四个子行：Hint + StatusText
        footerGap: 0,
        hasActions: true,
        actionGap: SUBWINDOW_ROW_GAP_NARROW,   // 行 3 = 14
        actionsSplit: false,
        notice: (): void => { this.notice(); },
        content: (): void => { this.body(); },
        footer: (): void => { this.footer(); },
        actions: (): void => { this.actions(); },
      });
    }
    .width('100%')
    .height('100%')
    // 平台替换 ②：按键事件挂在页面根节点，按 capturingRowIndex 路由到那一行。
    .focusable(true)
    .defaultFocus(true)
    .onKeyEvent((event: KeyEvent): void => {
      if (event.type !== KeyType.Down || this.capturingRowIndex < 0) {
        return;
      }
      let ctrlDown: boolean = false;
      let altDown: boolean = false;
      let shiftDown: boolean = false;
      if (event.getModifierKeyState !== undefined) {
        ctrlDown = event.getModifierKeyState(['ctrl']);
        altDown = event.getModifierKeyState(['alt']);
        shiftDown = event.getModifierKeyState(['shift']);
      }
      let modifiers: number = 0;
      if (ctrlDown) {
        modifiers = modifiers | MOD_CONTROL;
      }
      if (altDown) {
        modifiers = modifiers | MOD_ALT;
      }
      if (shiftDown) {
        modifiers = modifiers | MOD_SHIFT;
      }
      this.on_key_down(event.keyCode, modifiers, event.metaKey !== 0);
    });
  }
}

