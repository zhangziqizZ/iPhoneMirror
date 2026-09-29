// BluetoothControlNoticeWindow.ets —— 子窗口 14/20：蓝牙反向控制提示（等待 / 已连接 / 失败 / 需重新配对 / 前置确认）
//
// 逐项对照上游（**以 main 1.8.4 为准**；linux 1.8.1 也有这个文件，差异已 diff 核对）
//   src/App/Windows/BluetoothControlNoticeWindow.xaml（157 行）
//   src/App/Windows/BluetoothControlNoticeWindow.xaml.cs（344 行）
//
// ── main 与 linux 的差异（main 为准，逐条列在这里便于核对）──────────────────
//   ① main 的 NoticeState 多一个 Prerequisite（linux 只有 Waiting/Connected/Failed/
//      ReportMapChanged）。
//   ② main 多了 DetailVisibility 绑定（linux 的 DetailText 没有 Visibility，
//      空串时会留出一行空白）。
//   ③ main 的按钮条多一颗「继续」（PrerequisiteActionsVisibility），
//      且关闭按钮文案由写死的 Close 改成绑定 CloseButtonText（Prerequisite 时是「取消」）。
//   ④ main 的构造函数多一个 previewOnly（ConfirmPrerequisite / ShowPrerequisitePreview）。
//   → 本文件按 main 的四处差异实现。
//
// ── 窗口属性（XAML 根元素 <ui:FluentWindow> 那一行）──────────────────────────
//   Width="500" SizeToContent="Height"       → 宽度固定 500，高度随内容（见平台替换 ⑤）
//   ResizeMode="NoResize"                    → resizable: false
//   WindowStartupLocation="CenterOwner"      → SubWindowHost.open 里算居中
//   WindowStyle="None" + ExtendsContentIntoTitleBar="True" → decorEnabled: false + 自绘表头
//   WindowBackdropType="None"                → 不带 Mica/Acrylic
//   Background="{DynamicResource WindowBackgroundBrush}"
//   ShowInTaskbar="False" / ShowActivated="True" / Topmost="True"
//   ★ 这个窗口没有 Title 属性；表头文字走绑定 TitleText（不是 SubWindowSubtitle）。
//
// ── 内容根 ────────────────────────────────────────────────────────────────
//   <Border Style="{StaticResource ModernDialogSurface}" Margin="0"
//           Effect="{x:Null}" CornerRadius="0" BorderThickness="0" Padding="20">
//   ModernControls.xaml 的 ModernDialogSurface：DialogSurfaceBrush 底 / 1px 边 /
//   圆角 20 / Padding 26；这里只覆盖了 CornerRadius(0) / BorderThickness(0) /
//   Padding(20) / Effect，**没有覆盖 Background**
//   → 页面底色取 DIALOG_SURFACE，内边距取 20（与 ProtectedContentNoticeWindow 同一处理）。
//
// ── 行定义（5 行）─────────────────────────────────────────────────────────
//   Row Auto : SubWindowHeader（标题 TitleText，Margin 0,0,48,0 + SubWindowCloseButton）
//   Row 16   : 间隔
//   Row Auto : 黄色提示块（WarningSurfaceBrush 底 / WarningBrush 1px 边 / 圆角 12 / Padding 14）
//   Row 12   : 间隔
//   Row Auto : Grid 两列 = * / Auto：左列两枚徽标，右列最多三颗按钮
//
// ── 黄色提示块 ────────────────────────────────────────────────────────────
//   Grid 两列 = 38 / *
//     列 0：Border 30×30 圆角 15 底色 WarningBrush，顶部对齐；
//           SymbolIcon Cursor20 / 17 / OnAccentBrush / 居中
//     列 1：StackPanel Margin="8,0,0,0"
//           TextBlock BodyText    14 / SemiBold / Wrap
//           TextBlock DetailText  MutedTextBrush / 12 / Margin 0,4,0,0 / Wrap
//                                 （Visibility = DetailVisibility，main 新增）
//           StackPanel PairingStepsPanel  Margin="0,14,0,0"
//                                 （Visibility = WaitingStepsVisibility，
//                                   Waiting 与 ReportMapChanged 才显示）
//             5 步，每步 Grid 两列 = 24 / *：
//               第 1 步：圆 20×20 圆角 10 底色 AccentBrush，文字「1」OnAccentBrush / 11 / SemiBold
//               第 2–5 步：圆 20×20 圆角 10 底色 ControlFillBrush + BorderSoftBrush 1px 边，
//                          文字 MutedTextBrush / 11 / SemiBold
//               文字 12 / Wrap / VCenter / Margin 7,0,0,0
//               第 1–4 步 Grid Margin="0,0,0,8"；第 5 步 Grid Margin="0,8,0,0"
//
// ── 底行 ──────────────────────────────────────────────────────────────────
//   左列 WrapPanel（ItemHeight 30，VCenter）两枚圆角 15 徽标：
//     ShortcutBadge：ControlFill 底 / BorderSoft 边 / Padding 10,5 / Margin 0,0,6,0
//                    KeyboardShift16(14, Muted) + ShortcutText(11, Muted)
//                    Visibility = ShortcutVisibility（只有 Connected 显示）
//     状态徽标  ：同上但无右边距
//                    ArrowClockwise20(14, Muted) + StatusText(11, Muted)
//   右列 StackPanel Orientation=Horizontal：
//     Button「我已重新配对」Primary / MinWidth 150 / Height 36 / Margin 12,0,8,0
//            Visibility = ReportMapAcknowledgementVisibility
//     Button「继续」        Primary / MinWidth 100 / Height 36 / Margin 12,0,8,0
//            Visibility = PrerequisiteActionsVisibility（main 新增）
//     Button CloseButtonText MinWidth 80 / Height 36 / ControlFill 底 / BorderSoft 边 /
//            TextBrush 字 / 1px 边（= 普通按钮，不是 Primary）
//
// ── xaml.cs 的状态机（NoticeState，逐条照搬）───────────────────────────────
//   Waiting          ShowWaiting(owner, suggestedDeviceName)            非模态 Show()
//   Connected        ShowConnected(owner)                               复用 _active；启动 5 秒倒计时
//   Failed           ShowFailure(owner, detail)                         复用 _active
//   ReportMapChanged ShowReportMapChanged(owner, suggestedDeviceName, acknowledged)
//   Prerequisite     ConfirmPrerequisite(owner, wireless) → ShowDialog 返回 bool
//                    ShowPrerequisitePreview(owner, wireless) → 非模态 Show()
//   SetState：把 Width/MinWidth/MaxWidth 全部钉回 WaitingWidth(500)、重置 _remainingSeconds=5、
//             只在 Connected 时启动 _closeTimer，然后 ReflowToContent 重算高度。
//   OnCloseTimerTick：只有 Connected 才倒数，归零即 Close()
//   OnReportMapAcknowledgedClick：调 acknowledged 回调后 Close()
//   OnPrerequisiteConfirmClick：previewOnly → Close()，否则 DialogResult = true
//   OnCloseClick：Close()（Prerequisite 时等于取消）
//   TryCloseActive / NotifyShortcutChanged / ActiveNoticeClosed 事件
//
// ── 调用方（还原时保持同一条链路）──────────────────────────────────────────
//   MainViewModel.cs:1413 ShowWaiting / :1746 ShowConnected / :1393,:1447 ShowFailure
//   MainViewModel.cs:1510 ShowReportMapChanged / :1594,:1699 TryCloseActive
//   AppPromptWindow.xaml.cs:78 ShowPrerequisitePreview / :87 ConfirmPrerequisite
//   MainWindow.xaml.cs:536 NotifyShortcutChanged / :6583 TryCloseActive
//
// ── 文案来源 Strings.zh-CN.xaml（main 版）─────────────────────────────────
//   BluetoothControlWaitingTitle / Body / WaitingTargetFormat / WaitingDetail / WaitingStatus
//   BluetoothControlPairStepOneFormat / Two / Three / Four / Five
//   BluetoothControlFailedTitle / Body / Status
//   BluetoothControlReportMapChangedTitle / Body / Detail / Status / Confirm
//   BluetoothControlPromptTitle / BodyFormat / Detail / ShortcutFormat / AutoCloseFormat
//   ReverseControlPrerequisiteStatus / WirelessTitle / WirelessBody / WiredTitle / WiredBody
//   ShortcutSettingsUnbound / Cancel / Close / Continue
//
// ═══════════════════ 平台替换（原版机制在鸿蒙没有对应物）═══════════════════
// ① 快捷键（ShortcutText / BodyText 里的 {0}）
//    原版：GetConfiguredShortcut() = KeyboardShortcut.FromSettings(app.UpdateSettings,
//          BluetoothShortcutAction.BluetoothControl)，未设置时 DisplayText = 「未绑定」。
//    鸿蒙：没有全局热键注册能力，也拿不到上游 UpdateSettings → 恒定取未绑定态「未绑定」，
//          徽标与正文照原版格式渲染（见 SHORTCUT_TEXT）。
// ② 写死 Windows 的措辞（改为鸿蒙事实，逐条对应）
//    · BluetoothControlWaitingBody「iPhone 与 Windows 的系统配对」「若 Windows 已连接过此
//      HID 设备，请先在蓝牙设置中断开」→ 「iPhone 与鸿蒙设备的系统配对」「若本机已连接过…」。
//    · BluetoothControlPairStepThree「Windows：右下角出现“添加设备 - 点击以设置 iPhone”时，
//      点击该系统通知。」→ 鸿蒙不会出现该系统通知，改成写实的说明（见 S_PAIR_STEP_THREE）。
//    · BluetoothControlPairStepFour「Windows：在系统蓝牙配对窗口中点击“配对”。」
//      → 鸿蒙不会弹出系统蓝牙配对窗口（见 S_PAIR_STEP_FOUR）。
//    · BluetoothControlFailedBody「Windows 未能启动 BLE HID 外设服务。请检查蓝牙适配器和
//      驱动是否支持外设模式。」→ 去掉 Windows 专有名词，改成鸿蒙侧的真实失败原因
//      （见 S_FAILED_BODY；**确切原因由调用方经 failureDetail 原样传入**，比如
//      801 不具备 BLE 外设角色）。
//    · BluetoothControlPromptBodyFormat「Windows 鼠标输入已转发到 iPhone/iPad。」
//      → 「本机鼠标输入已转发到 iPhone/iPad。」（见 S_PROMPT_BODY_FORMAT）。
//      ★ 这两个串此前写的是「鸿蒙根本不支持 BLE HID 外设模式 / 无法转发输入」——
//        **那是错的，已作废**：本移植已用 GATT Server + 广播实现了真的 BLE HID 外设，
//        鼠标移动/按键/滚轮能真的转发到 iPhone（ets/common/BluetoothHidPeripheral.ets）。
//    · BluetoothControlPromptDetail「反向控制期间 Windows 光标会隐藏。」→ 「本机光标」。
//    · ReverseControlPrerequisiteWirelessBody 第 4 条「允许 iPhoneMirror 通过 Windows
//      防火墙通信。」→ 鸿蒙无 Windows 防火墙概念，改成局域网可达性说明。
// ③ SuggestedDeviceName
//    原版 = Environment.MachineName（Windows 电脑名，BluetoothHidMouseService.cs:134）。
//    鸿蒙没有等价的机器名 API → 由调用方经 AppStorage 传入，缺省「本设备」。
// ④ 「我已重新配对」（OnReportMapAcknowledgedClick）
//    原版：调 acknowledged 回调（清掉「需要重新配对」标记）后关窗。
//    鸿蒙：本移植的 GATT 服务也是每次 start() 重新注册（Report Map 变了就得重配），
//          但不像 Windows 那样在系统里留下"需要重新配对的 HID 设备"标记 →
//          仍按原版写回 acknowledged 结果并关窗，界面文案照原版（见 S_REPORT_MAP_*）。
// ⑤ SizeToContent="Height" + ReflowToContent()
//    原版宽度固定 500、高度按内容重算（SetState 里还会 BeginInvoke 再算一次并重新居中）。
//    鸿蒙子窗口必须显式给矩形 → 按状态给出估算高度（见 *_HEIGHT 常量），注释里标明
//    原版是自适应；取值偏大以保证 5 步清单不被裁切。
// ⑥ Topmost="True" / ShowInTaskbar="False" / ShowActivated="True"
//    SubWindowSpec 没有对应字段（且本轮不允许改 SubWindow.ets）→ 无法还原，仅在此记录。
// ⑦ DialogResult（ConfirmPrerequisite 返回 bool）
//    → 改用 AppStorage 的 RESULT_KEY_PREREQUISITE_CONFIRMED（true/false）。

import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  SubWindowShell, SubWindowHost, SecondaryButton, PrimaryButton, BadgeChip,
  SUBWINDOW_ROW_GAP,
  SubWindowSpec,
} from '../../common/SubWindow';
import { FluentSymbol } from '../../common/FluentIcon';
import {
  TEXT, MUTED_TEXT, WARNING, WARNING_SURFACE, ON_ACCENT, DIALOG_SURFACE,
  CONTROL_FILL, BORDER_SOFT, ACCENT,
} from '../../common/Theme';

const TAG: string = 'im_bluetooth_notice';
const DOMAIN: number = 0x0100;

export const WINDOW_NAME: string = 'BluetoothControlNoticeWindow';
export const PAGE_PATH: string = 'pages/windows/BluetoothControlNoticeWindow';

// ── 原版 NoticeState（xaml.cs 的 private enum，五个值）───────────────────────
export const STATE_WAITING: number = 0;
export const STATE_CONNECTED: number = 1;
export const STATE_FAILED: number = 2;
export const STATE_REPORT_MAP_CHANGED: number = 3;
export const STATE_PREREQUISITE: number = 4;

/** 原版各静态 Show* 的入参键。 */
export const ARG_KEY_STATE: string = 'im.bluetoothNotice.state';
export const ARG_KEY_FAILURE_DETAIL: string = 'im.bluetoothNotice.failureDetail';
export const ARG_KEY_SUGGESTED_NAME: string = 'im.bluetoothNotice.suggestedDeviceName';
export const ARG_KEY_WIRELESS: string = 'im.bluetoothNotice.wireless';
export const ARG_KEY_PREVIEW_ONLY: string = 'im.bluetoothNotice.previewOnly';
/** 结果键。 */
export const RESULT_KEY_PREREQUISITE_CONFIRMED: string = 'im.bluetoothNotice.prerequisiteConfirmed';
export const RESULT_KEY_REPORT_MAP_ACKNOWLEDGED: string = 'im.bluetoothNotice.reportMapAcknowledged';

/** 原版 private const double WaitingWidth = 500。 */
const WAITING_WIDTH: number = 500;
/** 平台替换 ⑤：原版 SizeToContent="Height"，这里按状态给估算高度。
 *  ★ Waiting / Connected 两态因新增平台补充的成熟度声明（S_PORT_EXPERIMENTAL，
 *    约两行）各 +50：子窗口高度是写死的，估小了那两行会被直接裁掉。 */
const WAITING_HEIGHT: number = 570;
const REPORT_MAP_HEIGHT: number = 520;
const CONNECTED_HEIGHT: number = 330;
const FAILED_HEIGHT: number = 320;
const PREREQUISITE_HEIGHT: number = 360;
/** 黄色提示块的 Grid 第一列 = 38。 */
const ICON_COLUMN_WIDTH: number = 38;
/** 图标圆：30×30 / 圆角 15 / 图标 FontSize 17。 */
const ICON_DISC_SIZE: number = 30;
const ICON_DISC_CORNER: number = 15;
const ICON_SIZE: number = 17;
/** 步骤序号圆：20×20 / 圆角 10；序号列 Grid 宽 24。 */
const STEP_DISC_SIZE: number = 20;
const STEP_DISC_CORNER: number = 10;
const STEP_INDEX_COLUMN_WIDTH: number = 24;
/** 原版 _remainingSeconds 初值 5（DispatcherTimer 间隔 1 秒）。 */
const AUTO_CLOSE_SECONDS: number = 5;
/** 步骤圆的直径（Border Width/Height 20）。 */
const STEP_ROW_COUNT: number = 5;

// ── Strings（键名与取值逐条标注）────────────────────────────────────────────
const S_WAITING_TITLE: string = '正在等待蓝牙控制连接';               // BluetoothControlWaitingTitle
// BluetoothControlWaitingBody —— 平台替换 ②：Windows → 鸿蒙设备 / 本机
const S_WAITING_BODY: string =
  '请按以下顺序完成 iPhone 与鸿蒙设备的系统配对。若本机已连接过此 HID 设备，请先在蓝牙设置中断开，' +
  '再重新启用控制并重新连接。';
const S_WAITING_TARGET_FORMAT: string = '设备列表中通常显示为：{0}';   // BluetoothControlWaitingTargetFormat
const S_WAITING_DETAIL: string =                                    // BluetoothControlWaitingDetail
  '连接后会弹出蓝牙客户端绑定窗口，请选择对应手机。绑定完成前不会发送输入；等待期间鼠标不会被隐藏或限制。';
const S_WAITING_STATUS: string = '等待 HID 鼠标连接';                 // BluetoothControlWaitingStatus
// BluetoothControlPairStepOneFormat（资源名带 Format，但正文里没有占位符，原版也用 Get 取）
const S_PAIR_STEP_ONE: string =
  'iPhone：打开“设置 → 辅助功能 → 触控 → 辅助触控”，开启“辅助触控”。';
const S_PAIR_STEP_TWO_FORMAT: string =                              // BluetoothControlPairStepTwo
  'iPhone：打开“设置 → 蓝牙”，连接“{0}”，然后点击“配对”。';
// BluetoothControlPairStepThree —— 平台替换 ②：原版写的是 Windows 系统通知
// ★ 原文是「鸿蒙不会出现该系统通知（无 BLE HID 外设能力），此步骤无法完成」——**已作废**。
//   本移植确实在广播 HID 服务（含设备名），步骤三要的是"iPhone 侧弹出配对提示"，
//   在鸿蒙上这件事由 iPhone 一侧完成，与"能不能做外设"无关。
const S_PAIR_STEP_THREE: string =
  '鸿蒙：不会出现“添加设备 - 点击以设置 iPhone”的系统通知（那是 Windows 独有的）。' +
  '配对提示由 iPhone 一侧给出，若没弹出，请回到上一步在蓝牙设置里重新选择本设备。';
// BluetoothControlPairStepFour —— 平台替换 ②：原版写的是 Windows 系统蓝牙配对窗口
// ★ 原文是「系统蓝牙配对窗口不会弹出（无法作为 BLE HID 外设被配对），此步骤无法完成」——**已作废**。
//   本机侧本来就不弹配对窗口：HID 服务由应用的 GATT Server 提供，配对由 iPhone 发起。
const S_PAIR_STEP_FOUR: string =
  '本机：不会弹出系统蓝牙配对窗口（HID 服务由应用的 GATT Server 提供，配对由 iPhone 发起）。' +
  '若 iPhone 上已显示为已连接，此步骤即已完成。';
const S_PAIR_STEP_FIVE: string = 'iPhone：若再次出现配对提示窗口，点击“配对”。'; // BluetoothControlPairStepFive

/**
 * ★ 平台新增（上游**没有**这一条）。
 *
 * 为什么加：上游 Windows 版这个窗口的语气是"功能已经能用，只差配对"；本移植不是 ——
 * 反控仍在实现阶段，iPhone 侧至今可能**完全不出现指针**。用户照着下面 5 步做完还是
 * 不能用，就只会得到"白折腾一场"的结论。把成熟度写在最显眼的位置，比事后在 issue 里
 * 逐条解释便宜得多，也更诚实。
 *
 * 只在「等待连接 / 已连接」两态显示：这两个状态最容易被误读成"能用"。
 * 前置确认（与反控实现无关）与失败态不显示。
 */
const S_PORT_EXPERIMENTAL: string =
  '本移植版的蓝牙反控仍在实现阶段，不保证可用：按下面步骤做完后，iPhone 上仍可能不出现指针，' +
  '那属当前已知情况 —— 欢迎把「复制诊断」的输出提到 issue 里，那正是我们需要的现场。';

const S_FAILED_TITLE: string = '蓝牙控制无法启动';                    // BluetoothControlFailedTitle
// BluetoothControlFailedBody —— 平台替换 ②：原版写的是 Windows 未能启动 BLE HID 外设服务
//   「请检查蓝牙适配器和驱动是否支持外设模式」→ 鸿蒙侧的对应问法是"蓝牙是否开启、
//   该设备是否有 BLE 外设角色"。**确切原因由调用方经 failureDetail 传进来并显示在下方**，
//   这里只写引导，不写死原因。
// ★ 原文是「鸿蒙不支持 BLE HID 外设模式（既不能 BLE 广播，也没有 GATT Server），
//   因此无法启动蓝牙控制」——**那是错的，已作废**（本移植已实现该外设）。
const S_FAILED_BODY: string =
  '本设备未能启动 BLE HID 外设服务。请确认蓝牙已开启，且当前设备支持 BLE 外设角色。';
const S_FAILED_STATUS: string = '启动失败';                          // BluetoothControlFailedStatus

const S_REPORT_MAP_TITLE: string = '蓝牙控制需要刷新配对';             // BluetoothControlReportMapChangedTitle
const S_REPORT_MAP_BODY: string =                                    // BluetoothControlReportMapChangedBody
  '此更新修改了蓝牙 HID 控制。请在 iPhone/iPad 上忽略现有的 iPhoneMirror 设备，然后重新配对，再启用控制。';
const S_REPORT_MAP_DETAIL: string =                                  // BluetoothControlReportMapChangedDetail
  '移除旧配对后关闭此提示。完成新配对后再次启用蓝牙控制。';
const S_REPORT_MAP_STATUS: string = '需要重新配对';                    // BluetoothControlReportMapChangedStatus
const S_REPORT_MAP_CONFIRM: string = '我已重新配对';                   // BluetoothControlReportMapChangedConfirm

// ★ 平台新增「（实验）」：原版这一条是"功能成立"的宣告（Windows 版确实能用），
//   本移植版不是 —— 见 S_PORT_EXPERIMENTAL。标题是窗口上最大的一行，不带成熟度
//   就等于替我们给这个功能背书。
const S_PROMPT_TITLE: string = '蓝牙反向控制已开启（实验）';           // BluetoothControlPromptTitle
// BluetoothControlPromptBodyFormat —— 平台替换 ②：原版写的是 Windows 鼠标输入已转发
// ★ 原文是「鸿蒙无法把鼠标输入转发到 iPhone/iPad（无 BLE HID 外设能力）」——**已作废**，
//   输入转发已经实现（ReverseControlInput → BLE HID Report，见 Index.ets 的开关）。
//   按原版句式，只把「Windows」换成本机口径。
const S_PROMPT_BODY_FORMAT: string =
  '本机鼠标输入已转发到 iPhone/iPad。按 {0} 释放鼠标并关闭反向控制。';
// BluetoothControlPromptDetail —— 平台替换 ②：Windows 光标 → 本机光标
const S_PROMPT_DETAIL: string = '反向控制期间本机光标会隐藏。';
const S_PROMPT_SHORTCUT_FORMAT: string = '按 {0} 释放鼠标';            // BluetoothControlPromptShortcutFormat
const S_PROMPT_AUTO_CLOSE_FORMAT: string = '{0} 秒后自动关闭';         // BluetoothControlPromptAutoCloseFormat

const S_PREREQUISITE_STATUS: string = '请确认准备工作后继续';           // ReverseControlPrerequisiteStatus
const S_PREREQUISITE_WIRELESS_TITLE: string = '启用无线控制前请确认';    // ReverseControlPrerequisiteWirelessTitle
// ReverseControlPrerequisiteWirelessBody —— 平台替换 ②：第 4 条改写成局域网可达性
const S_PREREQUISITE_WIRELESS_BODY: string =
  '1. 开启“开发者模式”并重启设备。\n2. 先通过 USB 完成信任和无线配对。\n3. 保持设备解锁，并连接同一局域网。\n' +
  '4. 鸿蒙没有 Windows 防火墙，但请确认局域网未被隔离、本机可被设备访问。\n\n完成后点击“继续”，否则点击“取消”。';
const S_PREREQUISITE_WIRED_TITLE: string = '启用有线控制前请确认';      // ReverseControlPrerequisiteWiredTitle
const S_PREREQUISITE_WIRED_BODY: string =                            // ReverseControlPrerequisiteWiredBody
  '1. 开启“开发者模式”并重启设备。\n2. USB 连接设备，解锁并点击“信任此电脑”。\n' +
  '3. 首次使用会从 GitHub 下载匹配的 DDI。\n4. 准备完成前不会发送输入。\n\n完成后点击“继续”，否则点击“取消”。';

/** ShortcutSettingsUnbound —— 平台替换 ①：鸿蒙无法注册全局热键，恒定是未绑定态。 */
const SHORTCUT_TEXT_UNBOUND: string = '未绑定';
const S_CANCEL: string = '取消';                                     // Cancel
const S_CLOSE: string = '关闭';                                      // Close
const S_CONTINUE: string = '继续';                                    // Continue
/** 平台替换 ③：Environment.MachineName 的缺省替代。 */
const DEFAULT_SUGGESTED_NAME: string = '本设备';

/** 按状态给出窗口高度（平台替换 ⑤）。 */
function height_for_state(state: number): number {
  if (state === STATE_CONNECTED) {
    return CONNECTED_HEIGHT;
  }
  if (state === STATE_FAILED) {
    return FAILED_HEIGHT;
  }
  if (state === STATE_PREREQUISITE) {
    return PREREQUISITE_HEIGHT;
  }
  if (state === STATE_REPORT_MAP_CHANGED) {
    return REPORT_MAP_HEIGHT;
  }
  return WAITING_HEIGHT;
}

/** 原版 ShowWaiting(Window owner, string? suggestedDeviceName)。 */
export function open_bluetooth_control_waiting(ctx: common.Context,
                                               suggestedDeviceName: string): void {
  AppStorage.setOrCreate<number>(ARG_KEY_STATE, STATE_WAITING);
  AppStorage.setOrCreate<string>(ARG_KEY_SUGGESTED_NAME, suggestedDeviceName);
  AppStorage.setOrCreate<string>(ARG_KEY_FAILURE_DETAIL, '');
  open_bluetooth_control_notice(ctx, STATE_WAITING, suggestedDeviceName);
}

/** 原版 ShowConnected(Window owner)。 */
export function open_bluetooth_control_connected(ctx: common.Context): void {
  AppStorage.setOrCreate<number>(ARG_KEY_STATE, STATE_CONNECTED);
  open_bluetooth_control_notice(ctx, STATE_CONNECTED, '');
}

/** 原版 ShowFailure(Window owner, string? detail)。 */
export function open_bluetooth_control_failure(ctx: common.Context, detail: string): void {
  AppStorage.setOrCreate<number>(ARG_KEY_STATE, STATE_FAILED);
  AppStorage.setOrCreate<string>(ARG_KEY_FAILURE_DETAIL, detail);
  open_bluetooth_control_notice(ctx, STATE_FAILED, '');
}

/** 原版 ShowReportMapChanged(Window owner, string? suggestedDeviceName, Action acknowledged)。 */
export function open_bluetooth_control_report_map_changed(ctx: common.Context,
                                                           suggestedDeviceName: string): void {
  AppStorage.setOrCreate<number>(ARG_KEY_STATE, STATE_REPORT_MAP_CHANGED);
  AppStorage.setOrCreate<string>(ARG_KEY_SUGGESTED_NAME, suggestedDeviceName);
  AppStorage.setOrCreate<boolean>(RESULT_KEY_REPORT_MAP_ACKNOWLEDGED, false);
  open_bluetooth_control_notice(ctx, STATE_REPORT_MAP_CHANGED, suggestedDeviceName);
}

/** 原版 ConfirmPrerequisite(Window owner, bool wireless)（模态，返回 bool）。 */
export function confirm_bluetooth_control_prerequisite(ctx: common.Context,
                                                        wireless: boolean): void {
  AppStorage.setOrCreate<number>(ARG_KEY_STATE, STATE_PREREQUISITE);
  AppStorage.setOrCreate<boolean>(ARG_KEY_WIRELESS, wireless);
  AppStorage.setOrCreate<boolean>(ARG_KEY_PREVIEW_ONLY, false);
  AppStorage.setOrCreate<boolean>(RESULT_KEY_PREREQUISITE_CONFIRMED, false);
  open_bluetooth_control_notice(ctx, STATE_PREREQUISITE, '');
}

/** 原版 ShowPrerequisitePreview(Window owner, bool wireless)（非模态）。 */
export function show_bluetooth_control_prerequisite_preview(ctx: common.Context,
                                                             wireless: boolean): void {
  AppStorage.setOrCreate<number>(ARG_KEY_STATE, STATE_PREREQUISITE);
  AppStorage.setOrCreate<boolean>(ARG_KEY_WIRELESS, wireless);
  AppStorage.setOrCreate<boolean>(ARG_KEY_PREVIEW_ONLY, true);
  AppStorage.setOrCreate<boolean>(RESULT_KEY_PREREQUISITE_CONFIRMED, false);
  open_bluetooth_control_notice(ctx, STATE_PREREQUISITE, '');
}

/** 五个静态入口共用的一次开窗。 */
function open_bluetooth_control_notice(ctx: common.Context, state: number,
                                       suggestedDeviceName: string): void {
  const spec: SubWindowSpec = {
    name: WINDOW_NAME,
    page: PAGE_PATH,
    title: S_WAITING_TITLE,           // 原版没有 Title 属性；窗口名按 Waiting 的标题给
    width: WAITING_WIDTH,             // Width="500"（SetState 里还会把 Min/Max 都钉回 500）
    height: height_for_state(state),  // 平台替换 ⑤
    resizable: false,                 // ResizeMode="NoResize"
    minWidth: WAITING_WIDTH,
    minHeight: height_for_state(state),
    modal: state === STATE_PREREQUISITE,   // 只有 ConfirmPrerequisite 走 ShowDialog()
  };
  SubWindowHost.open(ctx, spec).catch((error: BusinessError): void => {
    hilog.error(DOMAIN, TAG, '打开失败: %{public}s', error.message);
  });
  hilog.info(DOMAIN, TAG, 'state=%{public}d suggested=%{public}s', state, suggestedDeviceName);
}

@Entry
@Component
struct BluetoothControlNoticeWindow {
  /**
   * 原版 _state（默认 Waiting，由各静态入口在 SetState 里改）。
   *
   * ★ 这里必须用 **@StorageLink** 而不是 @State：上游 `ShowConnected` / `ShowFailure`
   *   会**复用**已经开着的那一个窗口对象然后只改状态（BluetoothControlNoticeWindow.xaml.cs
   *   :128-153），而本移植的 `SubWindowHost.open` 对已存在的窗口只做 showWindow()
   *   —— 用 @State 的话新状态永远送不进那个活着的窗口，界面会一直停在"等待连接"。
   *   @StorageLink 让 AppStorage 的写入直接驱动活窗口重绘，才是上游那个语义。
   */
  @StorageLink(ARG_KEY_STATE) state: number = STATE_WAITING;
  /** 原版 _failureDetail（同上：ShowFailure 是复用窗口改状态）。 */
  @StorageLink(ARG_KEY_FAILURE_DETAIL) failureDetail: string = '';
  /** 原版 _suggestedDeviceName。 */
  @StorageLink(ARG_KEY_SUGGESTED_NAME) suggestedDeviceName: string = '';
  /** 原版 ConfirmPrerequisite(owner, wireless) 的 wireless。 */
  @State wireless: boolean = false;
  /** 原版 _previewOnly。 */
  @State previewOnly: boolean = false;
  /** 原版 _remainingSeconds。 */
  @State remainingSeconds: number = AUTO_CLOSE_SECONDS;

  /** 原版 _closeTimer（DispatcherTimer，间隔 1 秒）。 */
  private timerId: number = -1;
  /** 上一秒看到的状态，用来识别"状态被外部改了"并重置倒计时。 */
  private lastState: number = STATE_WAITING;

  aboutToAppear(): void {
    this.lastState = this.state;
    this.remainingSeconds = AUTO_CLOSE_SECONDS;
    this.wireless = AppStorage.get<boolean>(ARG_KEY_WIRELESS) ?? false;
    this.previewOnly = AppStorage.get<boolean>(ARG_KEY_PREVIEW_ONLY) ?? false;
    // 计时器**常驻**（原版只在 Connected 时 Start）：状态现在是 @StorageLink，
    // 外部把它改成 Connected 时不会有任何回调通知本页面，所以只能靠这个 1 秒的
    // 心跳去发现"该开始倒计时了"。成本是一次无操作的 tick。
    this.timerId = setInterval((): void => { this.on_close_timer_tick(); }, 1000);
    hilog.info(DOMAIN, TAG, '已打开 state=%{public}d', this.state);
  }

  aboutToDisappear(): void {
    this.stop_close_timer();
  }

  private stop_close_timer(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  /**
   * 原版 OnCloseTimerTick：非 Connected 直接 return；归零即 Close()。
   * 差异 ①：状态从外部切进来时先重置倒计时（原版 SetState 里做这件事）。
   */
  private on_close_timer_tick(): void {
    if (this.state !== this.lastState) {
      this.lastState = this.state;
      this.remainingSeconds = AUTO_CLOSE_SECONDS;
    }
    if (this.state !== STATE_CONNECTED) {
      return;
    }
    this.remainingSeconds -= 1;
    if (this.remainingSeconds <= 0) {
      hilog.info(DOMAIN, TAG, '已连接提示自动关闭');
      this.close_window();
    }
  }

  private close_window(): void {
    this.stop_close_timer();
    SubWindowHost.close(WINDOW_NAME);
  }

  // ── 原版那组绑定属性（TitleText / BodyText / DetailText / StatusText …）────

  private title_text(): string {
    if (this.state === STATE_PREREQUISITE) {
      return this.wireless ? S_PREREQUISITE_WIRELESS_TITLE : S_PREREQUISITE_WIRED_TITLE;
    }
    if (this.state === STATE_WAITING) {
      return S_WAITING_TITLE;
    }
    if (this.state === STATE_FAILED) {
      return S_FAILED_TITLE;
    }
    if (this.state === STATE_REPORT_MAP_CHANGED) {
      return S_REPORT_MAP_TITLE;
    }
    return S_PROMPT_TITLE;
  }

  private body_text(): string {
    if (this.state === STATE_PREREQUISITE) {
      return this.wireless ? S_PREREQUISITE_WIRELESS_BODY : S_PREREQUISITE_WIRED_BODY;
    }
    if (this.state === STATE_CONNECTED) {
      return S_PROMPT_BODY_FORMAT.replace('{0}', SHORTCUT_TEXT_UNBOUND);
    }
    if (this.state === STATE_WAITING) {
      return S_WAITING_BODY;
    }
    if (this.state === STATE_REPORT_MAP_CHANGED) {
      return S_REPORT_MAP_BODY;
    }
    return S_FAILED_BODY;
  }

  /** 原版 DetailText：Failed 用 _failureDetail；Waiting/ReportMap 会在前面加一行目标设备。 */
  private detail_text(): string {
    if (this.state === STATE_PREREQUISITE) {
      return '';
    }
    if (this.state === STATE_FAILED) {
      return this.failureDetail;
    }
    if (this.state === STATE_WAITING) {
      return this.target_line() + S_WAITING_DETAIL;
    }
    if (this.state === STATE_REPORT_MAP_CHANGED) {
      return this.target_line() + S_REPORT_MAP_DETAIL;
    }
    return S_PROMPT_DETAIL;
  }

  /** 原版把 WaitingTargetFormat 与 detail 用 '\n' 拼起来（只有建议设备名非空时才加）。 */
  private target_line(): string {
    if (this.suggestedDeviceName.trim().length === 0) {
      return '';
    }
    return S_WAITING_TARGET_FORMAT.replace('{0}', this.suggestedDeviceName) + '\n';
  }

  private status_text(): string {
    if (this.state === STATE_WAITING) {
      return S_WAITING_STATUS;
    }
    if (this.state === STATE_PREREQUISITE) {
      return S_PREREQUISITE_STATUS;
    }
    if (this.state === STATE_FAILED) {
      return S_FAILED_STATUS;
    }
    if (this.state === STATE_REPORT_MAP_CHANGED) {
      return S_REPORT_MAP_STATUS;
    }
    return S_PROMPT_AUTO_CLOSE_FORMAT.replace('{0}', this.remainingSeconds.toString());
  }

  /** 原版 ShortcutVisibility：只有 Connected 显示。 */
  private show_shortcut_badge(): boolean {
    return this.state === STATE_CONNECTED;
  }

  /** 原版 WaitingStepsVisibility：Waiting 与 ReportMapChanged 显示。 */
  private show_pairing_steps(): boolean {
    return this.state === STATE_WAITING || this.state === STATE_REPORT_MAP_CHANGED;
  }

  /**
   * ★ 平台新增（上游没有）：成熟度声明 S_PORT_EXPERIMENTAL 的显隐。
   * 只在"看起来能用"的两态显示 —— 那两态才会被读成"功能好了"。
   */
  private show_experimental_note(): boolean {
    return this.state === STATE_WAITING || this.state === STATE_CONNECTED;
  }

  private show_report_map_confirm(): boolean {
    return this.state === STATE_REPORT_MAP_CHANGED;
  }

  private show_prerequisite_confirm(): boolean {
    return this.state === STATE_PREREQUISITE;
  }

  /** 原版 CloseButtonText：Prerequisite 是「取消」，其余是「关闭」。 */
  private close_button_text(): string {
    return this.state === STATE_PREREQUISITE ? S_CANCEL : S_CLOSE;
  }

  private step_text(step: number): string {
    if (step === 0) {
      return S_PAIR_STEP_ONE;
    }
    if (step === 1) {
      // 原版 PairStepTwo 的 {0} = Environment.MachineName（平台替换 ③）。
      const name: string = this.suggestedDeviceName.trim().length > 0
        ? this.suggestedDeviceName : DEFAULT_SUGGESTED_NAME;
      return S_PAIR_STEP_TWO_FORMAT.replace('{0}', name);
    }
    if (step === 2) {
      return S_PAIR_STEP_THREE;
    }
    if (step === 3) {
      return S_PAIR_STEP_FOUR;
    }
    return S_PAIR_STEP_FIVE;
  }

  // ── 三个按钮的点击（原版 OnCloseClick / OnReportMapAcknowledgedClick /
  //    OnPrerequisiteConfirmClick）────────────────────────────────────────

  /** 原版 OnCloseClick → Close()（Prerequisite 时等于取消）。 */
  private on_close(): void {
    if (this.state === STATE_PREREQUISITE) {
      AppStorage.setOrCreate<boolean>(RESULT_KEY_PREREQUISITE_CONFIRMED, false);
    }
    this.close_window();
  }

  /** 原版 OnReportMapAcknowledgedClick —— 见平台替换 ④。 */
  private on_report_map_acknowledged(): void {
    if (this.state !== STATE_REPORT_MAP_CHANGED) {
      return;
    }
    AppStorage.setOrCreate<boolean>(RESULT_KEY_REPORT_MAP_ACKNOWLEDGED, true);
    hilog.warn(DOMAIN, TAG, '“我已重新配对”仅记录并关窗：鸿蒙无法完成 BLE HID 配对');
    this.close_window();
  }

  /** 原版 OnPrerequisiteConfirmClick：previewOnly → Close()，否则 DialogResult = true。 */
  private on_prerequisite_confirm(): void {
    if (this.state !== STATE_PREREQUISITE) {
      return;
    }
    AppStorage.setOrCreate<boolean>(RESULT_KEY_PREREQUISITE_CONFIRMED, true);
    this.close_window();
  }

  /** Row Auto：黄色提示块（图标圆 + BodyText + DetailText + 5 步清单）。 */
  @Builder
  notice() {
    Row() {
      // 列 0：圆底 + 居中 Cursor20（顶部对齐）
      Stack() {
        FluentSymbol({
          iconName: 'Cursor20',
          iconSize: ICON_SIZE,
          iconColor: ON_ACCENT,
        });
      }
      .width(ICON_DISC_SIZE)
      .height(ICON_DISC_SIZE)
      .borderRadius(ICON_DISC_CORNER)
      .backgroundColor(WARNING)
      .alignContent(Alignment.Center)
      .alignSelf(ItemAlign.Start);

      // 列 1：正文 + 详情 + 配对步骤
      Column() {
        Text(this.body_text())
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT)
          .width('100%');

        // 原版 Visibility="{Binding DetailVisibility}"（main 新增，linux 没有）
        if (this.detail_text().length > 0) {
          Text(this.detail_text())
            .fontSize(12)
            .fontColor(MUTED_TEXT)
            .width('100%')
            .margin({ top: 4 });
        }

        // ★ 平台新增：成熟度声明（见 S_PORT_EXPERIMENTAL 的说明）。
        //   放在详情文字与配对清单**之间** —— 用户读完"要做什么"、还没开始做之前
        //   先看到"做完也可能不成功"，比放在末尾（做完才发现）有用得多。
        if (this.show_experimental_note()) {
          Text(S_PORT_EXPERIMENTAL)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(WARNING)
            .width('100%')
            .margin({ top: 10 });
        }

        // 原版 PairingStepsPanel（WaitingStepsVisibility）
        if (this.show_pairing_steps()) {
          Column() {
            ForEach(this.steps, (step: number, index: number): void => {
              this.pairing_step(index);
            }, (step: number, index: number): string => `${step}`);
          }
          .width('100%')
          .margin({ top: 14 });
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: ICON_COLUMN_WIDTH - ICON_DISC_SIZE + 8 });
    }
    .width('100%')
    .padding(14)
    .borderRadius(12)
    .backgroundColor(WARNING_SURFACE)
    .border({ width: 1, color: WARNING })
    .alignItems(VerticalAlign.Top);
  }

  /** 配对清单的一步（第 1–4 步 Margin 0,0,0,8；第 5 步 Margin 0,8,0,0）。 */
  @Builder
  pairing_step(index: number) {
    Row() {
      // 第 1 步是实心 Accent 圆（进行中），其余是描边圆（未开始）。
      Stack() {
        Text((index + 1).toString())
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor(index === 0 ? ON_ACCENT : MUTED_TEXT);
      }
      .width(STEP_DISC_SIZE)
      .height(STEP_DISC_SIZE)
      .borderRadius(STEP_DISC_CORNER)
      .backgroundColor(index === 0 ? ACCENT : CONTROL_FILL)
      .border(index === 0 ? { width: 0, color: ACCENT } : { width: 1, color: BORDER_SOFT })
      .alignContent(Alignment.Center);

      Text(this.step_text(index))
        .fontSize(12)
        .fontColor(TEXT)
        .layoutWeight(1)
        .margin({ left: STEP_INDEX_COLUMN_WIDTH - STEP_DISC_SIZE + 7 });
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .margin(index === STEP_ROW_COUNT - 1 ? { top: 8 } : { bottom: 8 });
  }

  /** Row Auto：左列两枚徽标、右列最多三颗按钮。 */
  @Builder
  actions() {
    Row() {
      // 原版 ShortcutBadge（只有 Connected 显示）
      if (this.show_shortcut_badge()) {
        BadgeChip({
          iconName: 'KeyboardShift16',
          chipText: S_PROMPT_SHORTCUT_FORMAT.replace('{0}', SHORTCUT_TEXT_UNBOUND),
          chipMarginEnd: 6,
        });
      }
      // 状态徽标（始终显示）
      BadgeChip({
        iconName: 'ArrowClockwise20',
        chipText: this.status_text(),
        chipMarginEnd: 0,
      });
    }
    .alignItems(VerticalAlign.Center);

    Row() {
      // 「我已重新配对」—— ReportMapAcknowledgementVisibility
      if (this.show_report_map_confirm()) {
        Row() {
          PrimaryButton({
            label: S_REPORT_MAP_CONFIRM,
            minButtonWidth: 150,
            buttonHeight: 36,
            on_action: (): void => { this.on_report_map_acknowledged(); },
          });
        }
        .margin({ left: 12, right: 8 });
      }

      // 「继续」—— PrerequisiteActionsVisibility（main 新增）
      if (this.show_prerequisite_confirm()) {
        Row() {
          PrimaryButton({
            label: S_CONTINUE,
            minButtonWidth: 100,
            buttonHeight: 36,
            on_action: (): void => { this.on_prerequisite_confirm(); },
          });
        }
        .margin({ left: 12, right: 8 });
      }

      SecondaryButton({
        label: this.close_button_text(),
        minButtonWidth: 80,
        buttonHeight: 36,
        on_action: (): void => { this.on_close(); },
      });
    }
    .alignItems(VerticalAlign.Center);
  }

  /** 配对步骤的下标表（ForEach 需要一份数据源）。 */
  private steps: number[] = [0, 1, 2, 3, 4];

  build() {
    Column() {
      SubWindowShell({
      windowName: WINDOW_NAME,
      title: this.title_text(),
      subtitle: '',                    // 原版表头只有 TitleText，没有 SubWindowSubtitle
      // Border Padding="20"（覆盖 ModernDialogSurface 的 26）；底色是 DialogSurfaceBrush
      pageMarginH: 20,
      pageMarginV: 20,
      shellBackground: DIALOG_SURFACE,
      gap: SUBWINDOW_ROW_GAP,          // 行 1 = 16
      hasNotice: true,                 // 行 2 = 黄色提示块
      noticeGap: 12,                   // 行 3 = 12
      hasFooter: false,
      hasActions: true,
      actionGap: 0,                    // 原版最后一行紧接提示块（12 的间隔已计入 noticeGap）
      actionsSplit: true,              // 徽标靠左、按钮靠右
      notice: (): void => { this.notice(); },
      actions: (): void => { this.actions(); },
    });
    }
  }
}
