// Index.ets —— iPhoneMirror 鸿蒙 PC 主界面
//
// ═══════════════════════════════════════════════════════════════════════════
//  这个文件是上游 WPF 主窗口的**逐项还原**，不是自创布局。
// ═══════════════════════════════════════════════════════════════════════════
//
//  上游是 WPF（net10.0-windows + UseWPF + WPF-UI 4.3.0），XAML 无法在
//  OHOS NEXT 上渲染（鸿蒙没有 .NET 运行时），所以只能按原版**逐项还原**为 ArkTS。
//  上游官方 Linux 版也是这个策略：src/App 的 WPF 工程原样保留，另写 src/LinuxShell
//  （Avalonia），其 csproj 注释自称 "the minimal Linux shell"。
//
//  ── 还原依据（全部逐字对照，不自由发挥） ──────────────────────────────────
//
//    布局   src/App/MainWindow.xaml                        2136 行
//    文案   src/App/Localization/Strings.zh-CN.xaml         747 行
//    配色   src/SharedUI/Themes/DarkTheme.xaml              130 行  →  common/Theme.ets
//    图标   MaterialWindow.xaml 里的 <ui:SymbolIcon Symbol="..."/> 
//           （Fluent System Icons，MIT）                     →  common/FluentIcon.ets
//
//  ── 控件级对照表（原版 XAML → 本文件） ────────────────────────────────────
//
//    ui:NavigationView (LeftMinimal)   → nav_rail()         左侧导航（收起 56 / 展开 208）
//      ├ MenuItems 投屏/投屏来源/设置/设备绑定器
//      │                               → nav_item()          图标 32px + 文字 14px
//      ├ NavigationViewItemSeparator   → Divider()           分组线
//      ├ MenuItems 输出/驱动           → nav_item()
//      └ FooterMenuItems 关于          → nav_item()
//        三个切换项高亮（is_nav_active），四个动作项分别开
//        DeviceBindingWindow / MediaOutputSettingsWindow / AboutWindow
//    HeaderPanel                       → header()           标题 24 + 副标题 12 +
//                                                            状态点 6×6 + CaptureActionButton
//    LeftPanelHost (Width=300)         → left_panel()       DevicePanel / MirroringPanel 互斥
//      ├ DevicePanel                   → device_panel()     投屏来源
//      └ MirroringPanel                → mirroring_panel()  投屏（5 个 ToolButton）
//    CenterPanel                       → center_panel()
//      ├ EnvironmentPanel              → environment_panel() 预览快捷条（6 个按钮）
//      ├ PreviewPanel                  → preview_area()     WaitingForDevice / ReadyToMirror / 画面
//      └ StatsPanel                    → stats_panel()      解码器行 + 四格统计
//    ControlPanel                      → control_panel()    右侧设置（7 张卡片）
//    FooterPanel                       → footer()           本机 USB / AirPlay，无云端中转
//
//  ── 图标：照搬，不替换 ────────────────────────────────────────────────────
//
//    原版 30 处 <ui:SymbolIcon Symbol="X" FontSize="N"/> 全部按 Symbol 名与字号搬用，
//    由 common/FluentIcon.ets 里的 FluentSymbol 组件渲染（矢量路径逐点一致）。
//    另有一处非 SymbolIcon 的手绘轮廓：WaitingForDeviceState 的手机（38×48，Stroke 2），
//    以 FluentSymbol({ iconName: 'DeviceOutline', iconOutline: true }) 还原。
//
//  ── 配色：照搬，不改一个色值 ──────────────────────────────────────────────
//
//    全部颜色来自 common/Theme.ets，该文件逐条对应 DarkTheme.xaml 的 x:Key。
//
//  ── 文案：逐字取用；仅 4 处与平台事实冲突的措辞做了最小替换 ──────────────
//
//    | 原版文案                                     | 本文件          | 为什么 |
//    |----------------------------------------------|-----------------|--------|
//    | 在 Windows 播放声音 (PlayAudioWindows)        | 在本机播放声音   | 鸿蒙上写 Windows 是错的 |
//    | 只限制 Windows 本地渲染… (RenderLimitHelp)    | 只限制本地渲染… | 同上 |
//    | …但 D3D 预览仍会使用 GPU (VideoPipeline…)     | …但鸿蒙预览仍…  | 鸿蒙用 GLES 不是 D3D |
//    | Windows USB 低延迟与 AirPlay 无线投屏 (副标题) | HarmonyOS USB…  | 同上 |
//
//    除此之外（含「投屏来源」「连接后请保持 Apple 设备解锁」「Apple 设备通道已就绪，
//    正在检查采集后端。」等）全部是 Strings.zh-CN.xaml 的原文。
//
//  ── 不做假按钮 ────────────────────────────────────────────────────────────
//
//    尚未在鸿蒙落地的能力（录制推流 / 视频应用投屏）
//    **保留原版的控件与文案**，点击后给出确切原因，绝不静默假装成功。
//    这与 Core 层「任何导出都不得在没做事时报告成功」是同一条纪律。
//
//    蓝牙反控 / 独立窗口 / 截图 / 全屏预览 已从这份清单**移出**：它们现在都有真实实现
//    （蓝牙=GattServer+BLE 广播；独立窗口=StandalonePreviewWindow；截图=
//    componentSnapshot→相册；全屏=window 沉浸切换）。截图有个已知边界：
//    SURFACE XComponent 在个别版本/设备上 componentSnapshot 可能截不到内容（得黑图）。
//
// ═══════════════════════════════════════════════════════════════════════════

import {
  initialize,
  shutdown,
  apiVersion,
  refreshDevices,
  startCaptureWithOptions,
  setVideoPreferences,
  stopCapture,
  getCaptureStatus,
  attachPreview,
  detachPreview,
  forcePreviewRefresh,
  setAudioEnabled,
  setAudioVolume,
  setImageAdjustments,
  setPreviewCornerProfile,
  lastError,
  usbDiagnostics,
  getEnvironment,
  airplayStart,
  airplayStop,
  airplayGetStatus,
  setLogFile,
  DeviceInfo,
  CaptureStatus,
  AirPlayStatus,
  StartCaptureOptions,
  EnvironmentDiagnostics,
} from 'libim_core.so';
import airPlayMdns from '../common/AirPlayMdns';
import { BackgroundKeepAlive } from '../common/BackgroundKeepAlive';
import { BluetoothHidPeripheral, HID_LAYOUT_MULTI, HID_LAYOUT_SINGLE } from '../common/BluetoothHidPeripheral';
import {
  DeviceCornerProfile, describe_corner_profile, log_corner_profile,
  looks_like_product_type, resolve_corner_profile_for_frame,
} from '../common/DeviceCornerProfile';
import { ReverseControlInput } from '../common/ReverseControlInput';
import {
  describe_driver_state,
  read_driver_state,
  UsbDriverState,
} from '../common/UsbDriverState';
import { scan_usb_host, UsbHostScan } from '../common/UsbHostProbe';
import { check_ddk_usb_permission, DdkPermissionGrant } from '../common/UsbPermission';
import {
  DriverBindState, ensure_usb_driver_bound, reset_usb_driver_bind_retry, usb_driver_bind_state,
} from '../common/UsbDriverBinder';
import window from '@ohos.window';
// 反向控制期间要收起本地系统指针（见 apply_pointer_visibility）。
// setPointerVisibleSync 是 @since 10，低于本工程 compileSdkVersion(23)，可用。
import pointer from '@ohos.multimodalInput.pointer';
import pasteboard from '@ohos.pasteboard';
import common from '@ohos.app.ability.common';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import { BusinessError } from '@ohos.base';
// 截图：截取预览 XComponent（id='preview'）当前画面并存入应用私有目录。
// componentSnapshot 是 @since 10，低于本工程 compileSdkVersion(23)，可用。
import componentSnapshot from '@ohos.arkui.componentSnapshot';
import image from '@ohos.multimedia.image';
import fs from '@ohos.file.fs';
import { FluentSymbol } from '../common/FluentIcon';
import {
  NAV_RAIL_COMPACT,
  NAV_RAIL_OPEN,
  DEVICE_PANEL_WIDTH,
  COLUMN_GAP,
  CAPTURE_ACTION_WIDTH,
  CAPTURE_ACTION_HEIGHT,
  CAPTURE_ACTION_RADIUS,
  ICON_TEXT_GAP_CARD,
  ICON_TEXT_GAP_QUICK,
  DARK,
  LIGHT,
  ThemeColors,
} from '../common/Theme';
import { THEME_PREF_KEY, THEME_SCHEME_KEY, recomputeThemeScheme } from '../common/theme_manager';
import {
  WindowServices,
  ImageAdjustmentValues,
  ImageAdjustmentResult,
  STANDALONE_ABILITY,
  STANDALONE_ALIVE_KEY,
  STANDALONE_CLOSE_REQUEST_KEY,
  STANDALONE_CHROME_NOTICE_KEY,
  STANDALONE_NOTICE_KEY,
  REVERSE_CONTROL_DISABLED_KEY,
  HIDE_POINTER_ON_TAKEOVER_KEY,
  DEVELOPER_MODE_KEY,
  ACRYLIC_WINDOW_KEY,
  ACRYLIC_ALPHA_KEY,
  ACRYLIC_ALPHA_DEFAULT,
  WINDOW_ACRYLIC_RESULT_KEY,
  WINDOW_SHADOW_RESULT_KEY,
  PERSIST_READ_RESULT_KEY,
  PERSIST_WRITE_RESULT_KEY,
} from '../common/WindowServices';
import { SecondaryButton, SUBWINDOW_ERROR_KEY, SubWindowHost } from '../common/SubWindow';
import { save_acrylic_preferences, save_hide_pointer_preference } from '../common/AppPreferences';
import {
  open_image_settings,
  DEFAULT_BRIGHTNESS, DEFAULT_CONTRAST, DEFAULT_SATURATION, DEFAULT_GAMMA,
} from './windows/ImageSettingsWindow';
import { open_advanced_settings, AdvancedSettingsArgs } from './windows/AdvancedSettingsWindow';
import { open_about } from './windows/AboutWindow';
import { open_developer_tools } from './windows/DeveloperToolsWindow';
import { open_media_output_settings } from './windows/MediaOutputSettingsWindow';
import { open_projection_settings, OUT_KEY_SEPARATE_WINDOW_REQUESTED } from './windows/ProjectionSettingsWindow';
import { open_standalone_preview } from './windows/StandalonePreviewWindow';
import { open_shortcut_settings } from './windows/ShortcutSettingsWindow';
import {
  open_bluetooth_control_waiting,
  open_bluetooth_control_connected,
  open_bluetooth_control_failure,
  WINDOW_NAME as BLUETOOTH_NOTICE_WINDOW,
} from './windows/BluetoothControlNoticeWindow';
import { open_bluetooth_client_binding, clients_from_hid } from './windows/BluetoothClientBindingWindow';
import { open_device_binding } from './windows/DeviceBindingWindow';
import {
  show_capture_error,
  show_capture_stopped_then,
  is_no_ping_timeout,
} from './windows/CaptureStatusNoticeWindow';
import { open_capture_recovery } from './windows/CaptureRecoveryWindow';
import { open_startup_error } from './windows/StartupErrorWindow';
import { open_usb_projection_mode_info } from './windows/UsbProjectionModeInfoWindow';
import {
  UsbProjectionModeOption,
  USB_PROJECTION_MODES,
} from '../common/UsbProjectionMode';
import { save_language_preference } from '../common/AppPreferences';
import { t, set_language, active_lang, LANGUAGE_LABELS, LANG_INDEX_KEY } from '../common/i18n';

// ───────────────────── 选项（对照原版 ItemsSource / ComboBox） ─────────────────────

// Strings: ResolutionNative / Resolution1080p / Resolution720p / Resolution540p
const RESOLUTION_PRESETS: SelectOption[] = [
  { value: '原生（不限制渲染尺寸）' },
  { value: '1080p（1920×1080）' },
  { value: '720p（1280×720）' },
  { value: '540p（960×540）' },
];
// Strings: RenderLimitFormat "渲染上限 {0}" 的短标签
const RESOLUTION_SHORT: string[] = ['原生', '1080p', '720p', '540p'];
// RESOLUTION_PRESETS 对应的像素值，原样交给 im_set_video_preferences /
// im_start_capture_with_options 的 requested_width/height（0×0 = 不限制本地渲染尺寸）。
const RESOLUTION_WIDTH: number[] = [0, 1920, 1280, 960];
const RESOLUTION_HEIGHT: number[] = [0, 1080, 720, 540];

// Strings: DecoderAuto / DecoderHardwarePreferred / DecoderSoftwareCompatible
const DECODER_PREFERENCE_LABELS: string[] = ['自动（推荐）', '硬件优先', '软件兼容'];
const DECODER_PREFERENCE_OPTIONS: SelectOption[] = [
  { value: '自动（推荐）' },
  { value: '硬件优先' },
  { value: '软件兼容' },
];

// Strings: WirelessProfileMaximum / 1080p / 720p / 540p
const WIRELESS_PROFILE_LABELS: string[] = [
  '原画（最高 5120×2880 · 60 fps）',
  '1080p（推荐 · 60 fps）',
  '720p（流畅 · 30 fps）',
  '540p（弱网 · 30 fps）',
];
const WIRELESS_PROFILE_OPTIONS: SelectOption[] = [
  { value: '原画（最高 5120×2880 · 60 fps）' },
  { value: '1080p（推荐 · 60 fps）' },
  { value: '720p（流畅 · 30 fps）' },
  { value: '540p（弱网 · 30 fps）' },
];

// 原版卡片 3 的 ItemsSource 是 MainViewModel.UsbProjectionModes（UsbProjectionModeOption 列表），
// 每项含 Label / Advantage / Disadvantage / Notice 四段文案，ⓘ 按钮把整项传给
// UsbProjectionModeInfoWindow。所以这里直接用 common/UsbProjectionMode.ets 的同一张表，
// 不再另抄一份只有 Label 的常量（两个真值来源一定会漂移）。

/** 原版 UsbModeInfoButton 样式：18×18 / Padding 0 / 圆角 9 / 边框 1 / 文字 "!" 11 Bold。 */
const USB_MODE_INFO_BUTTON_SIZE: number = 18;
const USB_MODE_INFO_BUTTON_RADIUS: number = 9;
/** 原版 ItemTemplate 里 Label 的 Margin="0,0,20,0"（给 ⓘ 让位）。 */
const USB_MODE_LABEL_RIGHT_MARGIN: number = 20;
/** 原版 UsbModeTabItem 样式：Margin 2 / Padding 7,6 / MinHeight 38 / 圆角 10。 */
const USB_MODE_ITEM_MARGIN: number = 2;
/**
 * 半透明窗口的**浓度**：根容器那一层底色的 alpha（00=全透、FF=完全实色）。
 * 容器色与内容区背景现在都已全透，所以**只有这一个数**决定观感浓淡。
 * 默认 '99'≈60%；界面上的档位按钮可现场改（见 ACRYLIC_ALPHA_OPTIONS）。
 */
const ROOT_ACRYLIC_ALPHA_HEX: string = ACRYLIC_ALPHA_DEFAULT;

/** 浓度档位（设置面板现场切换，避免为调浓淡改代码重建）。 */
interface AcrylicAlphaOption {
  hex: string;
  label: string;
}

/** 由实到透排列；hex 是根容器底色的 alpha（00=全透、FF=实色）。 */
const ACRYLIC_ALPHA_OPTIONS: AcrylicAlphaOption[] = [
  { hex: 'C8', label: '78%' },
  { hex: '99', label: '60%' },
  { hex: '80', label: '50%' },
  { hex: '66', label: '40%' },
];

const USB_MODE_ITEM_CORNER: number = 10;

// Strings: ApplicationModeLightweight / ApplicationModeComplete
const APPLICATION_MODE_LABELS: string[] = ['轻量模式', '完整模式'];
const APPLICATION_MODE_OPTIONS: SelectOption[] = [
  { value: '轻量模式' },
  { value: '完整模式' },
];

// Strings: LanguageSystem / LanguageChinese / LanguageTraditionalChineseHongKong / LanguageEnglish
function language_labels(): string[] {
  return LANGUAGE_LABELS[active_lang()];
}
function language_options(): SelectOption[] {
  return language_labels().map((lab: string): SelectOption => ({ value: lab }));
}

// Strings: ThemeSystem / ThemeDark / ThemeLight
const THEME_LABELS: string[] = ['跟随系统', '深色', '浅色'];
const THEME_OPTIONS: SelectOption[] = [
  { value: '跟随系统' },
  { value: '深色' },
  { value: '浅色' },
];

// 原版 FrameRates 集合：[120, 60, 30, 24]（降序，含 24fps）
const FRAME_RATE_LABELS: string[] = ['120', '60', '30', '24'];
// 对应的数值，原样交给采集参数（targetFps）。
const FRAME_RATE_VALUES: number[] = [120, 60, 30, 24];
const FRAME_RATE_OPTIONS: SelectOption[] = [
  { value: '120' },
  { value: '60' },
  { value: '30' },
  { value: '24' },
];

// 与 CoreApi.h 的 CaptureState 同值；文案取自 Strings.zh-CN.xaml 的 Capture* 系列。
const STATE_NAMES: string[] = [
  '等待设备',                 // 0 Idle             ← CaptureIdle
  '正在启用 USB 投屏接口…',   // 1 ActivatingUsb    ← CaptureActivating
  '等待 Apple 设备投屏接口…', // 2 WaitingForDevice ← CaptureWaitingDevice
  '正在建立投屏会话…',        // 3 Handshaking      ← CaptureHandshaking
  '正在投屏',                 // 4 Streaming        ← CaptureStreaming
  '正在停止投屏…',            // 5 Stopping         ← CaptureStopping
  '投屏已停止',               // 6 Stopped          ← CaptureStopped
  '投屏出现错误',             // 7 Error            ← CaptureError
];

// ───────────────────────── 导航项 ─────────────────────────

/** 一个导航项：原版 NavigationViewItem 的 Content + Icon + ToolTip。 */
class NavEntry {
  key: string;
  label: string;      // Content
  iconName: string;   // ui:SymbolIcon Symbol
  iconSize: number;   // ui:SymbolIcon FontSize
  tooltip: string;    // ToolTip

  constructor(key: string, label: string, iconName: string, iconSize: number,
    tooltip: string) {
    this.key = key;
    this.label = label;
    this.iconName = iconName;
    this.iconSize = iconSize;
    this.tooltip = tooltip;
  }
}

// 顺序即原版顺序：MenuItems（投屏 / 投屏来源 / 设置 / 设备绑定器）→ Separator →
// （输出 / 驱动）。图标与字号逐条取自 MainWindow.xaml 的 SymbolIcon 声明：
//   MirroringPanelToggle  PhoneDesktop24   20
//   DevicePanelToggle     ProjectionScreen24 20
//   SettingsPanelToggle   Settings24       20
//   DeviceBindingNavButton UsbPlug24       20   ← Content=NavDeviceBinding「设备绑定器」
//   OutputNavButton       VideoRecording20 20
//   DriverManagerButton   DeveloperBoard20 20
function nav_main(): NavEntry[] {
  return [
    new NavEntry('mirroring', t('投屏'), 'PhoneDesktop24', 20, t('投屏控制')),                 // Strings: NavMirroring(NavMirroringDescription)
    new NavEntry('devices', t('投屏来源'), 'ProjectionScreen24', 20, t('选择投屏来源')),        // Strings: NavDevices(NavDevicesDescription)
    new NavEntry('settings', t('设置'), 'Settings24', 20, t('投屏设置')),                      // Strings: NavSettings(NavSettingsDescription)
    // Strings: NavDeviceBinding「设备绑定器」/ NavDeviceBindingDescription
    new NavEntry('binding', t('设备绑定器'), 'UsbPlug24', 20, t('管理真实设备的 USB、AirPlay 和 Bluetooth 身份绑定')),
    new NavEntry('output', t('输出'), 'VideoRecording20', 20, t('输出设置')),                  // Strings: NavOutput(NavOutputDescription)
    new NavEntry('driver', t('驱动'), 'DeveloperBoard20', 20, t('驱动管理')),                  // Strings: NavDriver(NavDriverDescription)
  ];
}
// 原版在 DeviceBindingNavButton 之后放 <ui:NavigationViewItemSeparator/>，
// 即前 4 项属于 MenuItems 的第一组。
const NAV_SEPARATOR_AT: number = 4;
// FooterMenuItems
function nav_footer(): NavEntry {
  return new NavEntry('about', t('关于'), 'Info24', 20, t('关于与更新'));
}                           // Strings: NavAbout(NavAboutDescription)

// ───────────────────────── ShellNavigationItem 模板尺寸（MainWindow.xaml:132–244） ─────────────────────────
// 图标列 ColumnDefinition Width="48"（图标在该列内居中）；
// 项根 Grid Height = MinHeight = 44；InteractionBackground Margin="4,0" CornerRadius=7；
// ActiveIndicator 3×18 Margin="4,0,0,0" 垂直居中 CornerRadius=2；
// PaneItemText Margin="8,0,12,0" FontSize=13。
const NAV_ICON_COLUMN: number = 48;
const NAV_ITEM_HEIGHT: number = 44;
const NAV_ITEM_BG_INSET: number = 4;
const NAV_ACTIVE_BAR_WIDTH: number = 3;
const NAV_ACTIVE_BAR_HEIGHT: number = 18;
/**
 * 导航栏展开/收起动画时长（ms）。实测 WPF-UI 4.3.0 的 PaneStates Storyboard：
 * PaneGrid Width 40↔OpenPaneLength，Duration 0:0:.16，AccelerationRatio 0.4
 * （先加速后匀速）——这里取 160ms，曲线用 EaseInOut 近似。
 */
const NAV_EXPAND_ANIM_MS: number = 160;
/** 三横线按钮按压缩放：WPF-UI BasePaneButtonStyle 的 IconScaleTransform 1.0→0.66。 */
const NAV_TOGGLE_PRESSED_SCALE: number = 0.66;
/** 三横线按钮按压缩放时长（两个 EventTrigger 各 0:0:0.08）。 */
const NAV_TOGGLE_PRESSED_MS: number = 80;

/**
 * 导航项名称气泡（原版 ToolTip）的时序。原版 XAML 只写了
 * ToolTip="{DynamicResource NavXxxDescription}"，一行时序设置都没有 ——
 * 也就是说走的是 **WPF 内建默认值**（dotnet/wpf 的 ToolTipService.cs 实测）：
 *   InitialShowDelay 默认 1000ms → hover 停留满 1 秒才弹
 *   BetweenShowDelay 默认 100ms  → 上一处 tooltip 刚消失 100ms 内移到下一处则立即弹
 *   ShowDuration     默认 Int32.MaxValue → 鼠标不移开就一直显示
 */
const NAV_TOOLTIP_INITIAL_DELAY_MS: number = 1000;
const NAV_TOOLTIP_BETWEEN_DELAY_MS: number = 100;

/**
 * 气泡样式：逐条取自 WPF-UI 4.3.0 库的 ToolTip.xaml（DefaultToolTipStyle）——
 *   MaxWidth 260 / FontSize 12 / LineHeight 16 / CornerRadius 4 / BorderThickness 1
 *   Border.Padding 8 + ContentPresenter.Margin 4 → 文字距边框 12
 *   配色三键见 common/Theme.ets 的 TOOLTIP_*（库 Theme/Dark.xaml 取值）
 *   阴影 DropShadowEffect BlurRadius 10 / ShadowDepth 5 / Opacity 0.135 / #202020
 * 为什么自绘而不是用 PopupOptions 的 message：message 形式改不了内边距、行高与边框。
 */
const NAV_TOOLTIP_MAX_WIDTH: number = 260;
const NAV_TOOLTIP_RADIUS: number = 4;
const NAV_TOOLTIP_PADDING: number = 12;   // Padding 8 + Margin 4
const NAV_TOOLTIP_FONT_SIZE: number = 12;
const NAV_TOOLTIP_LINE_HEIGHT: number = 16;
/** 阴影色：#202020、Opacity 0.135 → alpha 0x22（ArkUI 用 #AARRGGBB）。 */
const NAV_TOOLTIP_SHADOW_COLOR: string = '#22202020';
const NAV_TOOLTIP_SHADOW_RADIUS: number = 10;
const NAV_TOOLTIP_SHADOW_OFFSET_Y: number = 5;

/**
 * 鸿蒙版尚未落地的工具动作。这些按钮**恒为灰态**，点击只弹「敬请期待」，
 * 不给任何"看起来能用"的假门槛（此前的写法是它们在投屏中会变成可点，点完
 * 只往设置面板写一行字，用户白点一场）。
 *
 * 判据是代码事实：'media' 需要录制/推流编码管线 —— 本版仍未接。
 * 'image'（画面调节）与 'refresh'（刷新画面）是已实现功能，不在此列 ——
 * 它们灰掉只是因为当前还没开始投屏。
 *
 * ★ 'bluetooth'（蓝牙反向控制）已于 1.0.24 从本清单**移出**：鸿蒙侧现在真的实现了
 *   BLE HID 外设（ets/common/BluetoothHidPeripheral.ets，用 GattServer +
 *   startAdvertising 复刻上游的 GattServiceProvider），但它仍是**实验性**（见 1.0.24）。
 *
 * ★ 'window'（独立窗口）已移出：渲染器本来就能重挂 surface
 *   （OhosPreviewRenderer 在渲染线程里 destroy_gl → create_gl 新 id），
 *   加上 pages/windows/StandalonePreviewWindow.ets，它已经是真功能。
 *
 * ★ 'screenshot'（截图）/ 'fullscreen'（全屏预览）本次移出：截图用
 *   componentSnapshot 截预览 XComponent 当前帧并存入相册（见 capture_screenshot，
 *   已知边界：SURFACE XComponent 在个别版本/设备上可能截不到内容，得黑图就是没截到）；
 *   全屏预览用 window.setWindowLayoutFullScreen + 隐藏系统栏切换。两者可用性都改为
 *   "真有画面时可用"，不再是"未实现"。
 */
const NOT_IMPLEMENTED_ACTIONS: string[] = [
  'media',
];

/** 「敬请期待」浮层的停留时长（ms）。够看清、又不至于挡着后续操作。 */
const COMING_SOON_DURATION_MS: number = 2200;

/**
 * 未实现功能卡片（当前仅剩「视频应用投屏」）整体压暗的不透明度。
 * 与禁用按钮的 0.34 取值不同：卡片里还要读说明文字，压太暗就看不见了。
 *
 * （「蓝牙反控鼠标设置」卡片本次已取消灰化 —— 那项功能真的做出来了。）
 */
const NOT_IMPLEMENTED_CARD_OPACITY: number = 0.55;

/**
 * 反控状态条 / 状态行上的文案（**每个状态都带「（实验）」**）。
 *
 * ★ 为什么要把成熟度写进**每一个**取值里，而不是只在设置卡片里说明一次：
 *   预览快捷条上那颗按钮此前显示「蓝牙反向控制已广播」—— 那只说明 GATT 服务
 *   真的起来了（`isAdvertising()` 为真），**不代表这条链路可用**：iPhone 侧至今
 *   仍可能完全不出现指针。用户看到「已广播」就会读成"功能好了"，然后把
 *   "连上了没反应"当成新 bug 报回来 —— 这是本项目"不许假成功"纪律在**文案**上的
 *   落地：状态可以真，但不能只报好消息。
 *
 * 取值：未启用 / 已广播 / 已连接；三种都拼上（实验）。
 */
function reverse_label(state: string): string {
  return `蓝牙反控（实验）${state}`;
}

/**
 * 窗口三键（最小化 / 最大化 / 关闭）由**系统**绘制在窗口右上角。
 * 本项目隐藏了窗口装饰栏（沉浸式标题栏，对应上游 WPF ExtendsContentIntoTitleBar），
 * 系统仍会在右上角画三键，且它会浮在应用内容之上 —— 所以应用内容必须在右侧把这块
 * 让出来，否则状态点 / 「开始投屏」按钮会被三键压住。
 * 鸿蒙 PC 三键每个约 46vp，三个 + 右边距按 144vp 预留。
 */
const TITLE_BUTTON_RESERVED_WIDTH: number = 144;

/**
 * 设备枚举周期。原版是 MainWindow 里 2 秒一次的 DispatcherTimer → RefreshAsync
 * （MainWindow.xaml.cs:356 `_refreshTimer.Interval = TimeSpan.FromSeconds(2)`）；
 * 本移植的界面心跳是 500ms，攒够 4 次即 2 秒跑一轮。
 */
const DEVICE_POLL_TICKS: number = 4;

/** 在设备列表里按 udid 找回同一个来源；没有则返回 null（原版按 UdidEquals 匹配）。 */
function find_device(list: DeviceInfo[], udid: string): DeviceInfo | null {
  if (udid.length === 0) {
    return null;
  }
  for (let i = 0; i < list.length; i++) {
    if (list[i].udid === udid) {
      return list[i];
    }
  }
  return null;
}

/**
 * 设备清单的指纹（本轮枚举到的 udid 序列）。
 * 设备每 2 秒枚举一次，但 @State 数组每次赋新对象都会触发一次重渲染，
 * 所以只有指纹变了才写回 devices。
 */
function device_signature(list: DeviceInfo[]): string {
  let out: string = '';
  for (let i = 0; i < list.length; i++) {
    out += `${list[i].udid}|`;
  }
  return out;
}

// ───────────────────────── 复用样式 ─────────────────────────

// @Extend 必须定义在文件顶层。这里只做「无参样式」，可变的显隐/使能状态在调用处叠加。

/** 原版 WorkspaceCardBorder：设备面板 / 投屏面板 / 统计面板的外壳 */
@Extend(Column)
function workspace_card(colors: ThemeColors) {
  .backgroundColor(colors.CARD)
  .borderRadius(12)
  .border({ width: 1, color: colors.BORDER_SOFT })
}

/** 原版 ControlSectionCard：设置面板里的卡片 */
@Extend(Column)
function control_card(colors: ThemeColors) {
  .width('100%')
  .padding(12)
  .backgroundColor(colors.CARD)
  .borderRadius(10)
  .border({ width: 1, color: colors.BORDER_SOFT })
  .margin({ bottom: 10 })
}

// 兜底调色板：仅在 DARK / LIGHT 因增量构建缓存或旧包异常为 undefined 时使用，
// 保证首屏不崩。正常路径下 T 始终返回 common/Theme.ets 的 DARK / LIGHT。
// 必须与 ThemeColors 接口逐字段对齐（ArkTS 禁止无类型对象字面量 / any / unknown）。
const FALLBACK_COLORS: ThemeColors = {
  ACCENT: '#FF69B1F8',
  ACCENT_HOVER: '#FF8CC6FF',
  APP_BACKGROUND: '#E61F1F1F',
  BACKGROUND: '#FF1F1F1F',
  BORDER: '#24FFFFFF',
  BORDER_SOFT: '#14FFFFFF',
  CAPTURE_ACTION_TEXT: '#FFFFFFFF',
  CAPTURE_START: '#FF0A67D0',
  CAPTURE_START_BORDER: '#FF78BAFF',
  CAPTURE_START_HOVER: '#FF0A5FAF',
  CAPTURE_STOP: '#FFC9363E',
  CAPTURE_STOP_BORDER: '#FFFF979C',
  CAPTURE_STOP_HOVER: '#FFB92F38',
  CARD: '#A6292929',
  CARD_HOVER: '#C42E2E2E',
  COMBO_BACKGROUND: '#14FFFFFF',
  COMBO_BORDER_HOVER: '#52FFFFFF',
  COMBO_HOVER: '#20FFFFFF',
  COMBO_ITEM_HOVER: '#20FFFFFF',
  COMBO_ITEM_SELECTED: '#28FFFFFF',
  COMBO_ITEM_SELECTED_HOVER: '#38FFFFFF',
  COMBO_OPEN: '#2AFFFFFF',
  COMBO_POPUP: '#F2292929',
  CONTROL_DIVIDER: '#26FFFFFF',
  CONTROL_FILL: '#14FFFFFF',
  CONTROL_HOVER: '#20FFFFFF',
  CONTROL_PRESSED: '#2AFFFFFF',
  DANGER: '#FFC9363E',
  DANGER_BORDER: '#FFFFAAA5',
  DANGER_BUTTON_TEXT: '#FFFFFFFF',
  DANGER_HOVER: '#FFD13D45',
  DANGER_HOVER_BORDER: '#FFFFCBC8',
  DANGER_PRESSED: '#FFA82830',
  DANGER_PRESSED_BORDER: '#FFFF8E87',
  DIALOG_SURFACE: '#F2242424',
  ERROR: '#FFFF6961',
  ERROR_SURFACE: '#22FF6961',
  FOCUS_STROKE: '#FF69B1F8',
  ICON_BUTTON_HOVER: '#1FFFFFFF',
  ICON_BUTTON_PRESSED: '#33FFFFFF',
  MEDIA_OVERLAY: '#E6222226',
  MEDIA_OVERLAY_TEXT: '#FFF7F7F8',
  MUTED: '#FFB7B7BC',
  MUTED_TEXT: '#FFB7B7BC',
  ON_ACCENT: '#FF0F1419',
  OVERLAY: '#D91F1F22',
  PANEL: '#B3242424',
  PANEL_ALT: '#D1292929',
  PREVIEW_BORDER: '#FF3C3C40',
  PREVIEW_CHROME: '#EE0B0B0C',
  PREVIEW_MUTED_TEXT: '#FFB8B8BD',
  PREVIEW_PANEL_ALT: '#FF111113',
  PREVIEW_TEXT: '#FFF5F5F7',
  PRIMARY_ACTION: '#FF479EF5',
  PRIMARY_ACTION_BORDER: '#FF9BCEFF',
  PRIMARY_ACTION_DISABLED: '#FF3A3A3D',
  PRIMARY_ACTION_DISABLED_TEXT: '#FFB8B8BD',
  PRIMARY_ACTION_FOCUS: '#FF0F1419',
  PRIMARY_ACTION_HOVER: '#FF62ABF5',
  PRIMARY_ACTION_HOVER_BORDER: '#FFC4E1FF',
  PRIMARY_ACTION_PRESSED: '#FF2886DE',
  PRIMARY_ACTION_PRESSED_BORDER: '#FF79BDF8',
  PRIMARY_ACTION_TEXT: '#FF0F1419',
  SCROLL_THUMB: '#70FFFFFF',
  SCROLL_THUMB_HOVER: '#94FFFFFF',
  SCROLL_THUMB_PRESSED: '#A6FFFFFF',
  SCROLL_TRACK: '#00FFFFFF',
  SCROLL_TRACK_HOVER: '#24FFFFFF',
  SELECTION: '#24FFFFFF',
  SHORTCUT_CLEAR_ICON: '#FFFFFFFF',
  SIDEBAR: '#C41F1F1F',
  SLIDER_THUMB_BORDER: '#FF479EF5',
  SLIDER_THUMB_FILL: '#FFF5F5F7',
  SLIDER_THUMB_HOVER: '#FFFFFFFF',
  SLIDER_TRACK: '#3DFFFFFF',
  STATUS_APPLIED: '#FF6CCB8F',
  STATUS_FAILED: '#FFFF6961',
  STATUS_PENDING: '#FFFFC55C',
  SUCCESS: '#FF6CCB8F',
  SUCCESS_SURFACE: '#226CCB8F',
  TEXT: '#FFF5F5F7',
  TEXT_SELECTION: '#805CAFFB',
  TOOLTIP_BACKGROUND: '#FF2C2C2C',
  TOOLTIP_BORDER: '#33000000',
  TOOLTIP_FOREGROUND: '#FFFFFFFF',
  WARNING: '#FFFFC55C',
  WARNING_SURFACE: '#22FFC55C',
  WINDOW_BACKGROUND: '#FF1F1F1F',
  WORKSPACE_CARD: '#00FFFFFF',
  WORKSPACE_CARD_HOVER: '#14FFFFFF',
  WORKSPACE_ITEM_SELECTED: '#28479EF5',
  WORKSPACE_ITEM_SELECTED_BORDER: '#FF69B1F8',
};

// ═══════════ 状态驱动的按钮 / 统计格 / 设备行（@Component，不是 @Builder） ═══════════
//
// ★ 为什么这几处必须是 @Component —— 这就是用户报的「这些按钮不能实时刷新」的根因。
//
//   ArkUI 对 @Builder 的刷新有两条硬规定（state-management/arkts-builder）：
//     ·「@Builder 传入的参数是**两个或两个以上**，且未使用按回调传递参数，
//        不会触发动态渲染 UI。」
//     ·「**按值传递**参数时，当传递的参数为状态变量时，状态变量的改变**不会**
//        引起 @Builder 函数内的 UI 刷新。」（只有「仅一个参数 + 直接传对象字面量」
//        才走按引用传递、才会刷新）
//
//   而原来这几处恰好全踩中：**凡"会变的东西"都是经参数传进去的**。
//     · tool_button / quick_button  5 个参数（含可用性 usable 与文案 label）
//     · stat_cell                   3 个参数（含分辨率/帧率/延迟/音频的值）
//   ⇒ 这两类**确定**冻在首帧，症状就是用户截图那两条：投屏已经开始了，
//     「独立窗口」「刷新画面」还是灰的；蓝牙连上了，状态条上还写着「蓝牙反向控制未启用」。
//     （截图里唯一亮着的「调节画面」恰好是把可用性写死 true 的那个 —— 这条判据自证。）
//
//   device_row 属**另一类**：1 个参数（device），参数本身不变，会变的是 body 内部
//   读的 this.selectedUdid。这一类的刷新行为官方文档没有直说（"按值传参不刷新"讲的
//   是参数变化），本工程也拿不到反例，所以**不宣称它坏了**；但它与上面几处一样是
//   不可依赖的 —— 改成 @Prop 下发后行为变成确定的，代价为零，故一并做掉。
//   凡"选中态 / 可用性 / 动态文案"一律不走 @Builder 参数，这条规矩比个案结论可靠。
//
//   @Prop 是 ArkUI 里「父组件给新值 ⇒ 子组件一定重建」的稳定通道，本工程已有先例
//   （BluetoothClientBindingWindow 的 RefreshIconButton、AboutWindow 的 SettingsToggle）。
//   故这几处一律：**会变的东西走 @Prop 下发，不变的东西走普通字段；主题由子组件自己
//   订阅 @StorageLink（theme_manager.ets 的设计即如此，不必把调色板层层传下去）。**
//   代价是父组件每轮 poll_status 重建时子组件也跟着重建 —— 主界面本来就是 500ms
//   整体重算一次，不额外增加负担。
//
// ⚠️ 命名：@Prop 有几个保留名（enabled / background / borderColor …），
//    所以可用性字段叫 usable / selected，不叫 enabled。

/** 「投屏」面板里的一条 ToolButton（整行宽：图标 + 文字 + 右侧留白）。 */
@Component
struct ToolPanelButton {
  @StorageLink(THEME_SCHEME_KEY) scheme: string = 'dark';
  @Prop btnLabel: string = '';
  @Prop iconName: string = '';
  @Prop iconSize: number = 15;
  @Prop usable: boolean = false;
  on_action: () => void = (): void => {};
  on_blocked: () => void = (): void => {};

  private palette(): ThemeColors {
    const p: ThemeColors | undefined = this.scheme === 'dark' ? DARK : LIGHT;
    return p ?? FALLBACK_COLORS;
  }

  build() {
    Row() {
      FluentSymbol({
        iconName: this.iconName,
        iconSize: this.iconSize,
        iconColor: this.usable ? this.palette().TEXT : this.palette().MUTED_TEXT,
      })
      Text(this.btnLabel)
        .fontSize(12)
        .fontColor(this.usable ? this.palette().TEXT : this.palette().MUTED_TEXT)
        .margin({ left: ICON_TEXT_GAP_CARD })
        .layoutWeight(1)
    }
    .width('100%')
    .height(36)
    .padding({ left: 8, right: 8 })
    .borderRadius(11)
    .backgroundColor(this.palette().CONTROL_FILL)
    .opacity(this.usable ? 1.0 : 0.34)
    .margin({ bottom: 8 })
    .hoverEffect(HoverEffect.Highlight)
    .onClick((): void => {
      if (this.usable) {
        this.on_action();
      } else {
        this.on_blocked();
      }
    })
  }
}

/** 预览快捷条（EnvironmentPanel / PreviewQuickActions）上的一颗按钮（紧凑、无整行宽）。 */
@Component
struct QuickBarButton {
  @StorageLink(THEME_SCHEME_KEY) scheme: string = 'dark';
  @Prop btnLabel: string = '';
  @Prop iconName: string = '';
  @Prop iconSize: number = 15;
  @Prop usable: boolean = false;
  on_action: () => void = (): void => {};
  on_blocked: () => void = (): void => {};

  private palette(): ThemeColors {
    const p: ThemeColors | undefined = this.scheme === 'dark' ? DARK : LIGHT;
    return p ?? FALLBACK_COLORS;
  }

  build() {
    Row() {
      FluentSymbol({
        iconName: this.iconName,
        iconSize: this.iconSize,
        iconColor: this.usable ? this.palette().TEXT : this.palette().MUTED_TEXT,
      })
      // 空文案是合法用法（工具条上那两颗只有图标的按钮）。
      if (this.btnLabel.length > 0) {
        Text(this.btnLabel)
          .fontSize(12)
          .fontColor(this.usable ? this.palette().TEXT : this.palette().MUTED_TEXT)
          .margin({ left: ICON_TEXT_GAP_QUICK })
      }
    }
    .height(36)
    .padding({ left: 10, right: 10 })
    .borderRadius(11)
    .backgroundColor(this.palette().CONTROL_FILL)
    .opacity(this.usable ? 1.0 : 0.34)
    .margin({ left: 6 })
    .hoverEffect(HoverEffect.Highlight)
    .onClick((): void => {
      if (this.usable) {
        this.on_action();
      } else {
        this.on_blocked();
      }
    })
  }
}

/** StatsPanel 里的一格（分辨率 / 帧率 / 延迟 / 音频）。 */
@Component
struct StatCell {
  @StorageLink(THEME_SCHEME_KEY) scheme: string = 'dark';
  @Prop cellLabel: string = '';
  @Prop cellValue: string = '';
  @Prop cellDetail: string = '';

  private palette(): ThemeColors {
    const p: ThemeColors | undefined = this.scheme === 'dark' ? DARK : LIGHT;
    return p ?? FALLBACK_COLORS;
  }

  build() {
    Column() {
      Text(this.cellLabel)
        .fontSize(10)
        .fontColor(this.palette().MUTED_TEXT)
        .width('100%')
      Text(this.cellValue)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.palette().TEXT)
        .margin({ top: 3 })
        .width('100%')
      Text(this.cellDetail)
        .fontSize(10)
        .fontColor(this.palette().MUTED_TEXT)
        .margin({ top: 2 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
    .padding(13)
  }
}

/**
 * 设备列表里的一行（原版 ListBox ItemTemplate）。
 *
 * 这里传的全是**拆开的字符串**而不是整个 DeviceInfo：@Prop 对普通对象做的是深拷贝，
 * 而 DeviceInfo 是接口类型，拆成原始值最省事也最不容易踩坑（字段都是只读展示）。
 */
@Component
struct DeviceRow {
  @StorageLink(THEME_SCHEME_KEY) scheme: string = 'dark';
  @Prop devName: string = '';
  @Prop devModel: string = '';
  @Prop devOs: string = '';
  @Prop devStatus: string = '';
  @Prop selected: boolean = false;
  on_pick: () => void = (): void => {};

  private palette(): ThemeColors {
    const p: ThemeColors | undefined = this.scheme === 'dark' ? DARK : LIGHT;
    return p ?? FALLBACK_COLORS;
  }

  build() {
    Row() {
      Column() {
        Circle({ width: 3, height: 3 })
          .fill(this.selected ? this.palette().ACCENT : this.palette().MUTED_TEXT)
          .margin({ top: 4 })
      }
      .width(32)
      .height(48)
      .borderRadius(6)
      .border({ width: 2, color: this.selected ? this.palette().ACCENT : this.palette().MUTED_TEXT })
      .alignItems(HorizontalAlign.Center)

      Column() {
        Text(this.devName)                                        // DisplayName
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.palette().TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.devModel)                                       // ModelDisplay
          .fontSize(11)
          .fontColor(this.palette().MUTED_TEXT)
          .margin({ top: 3 })
          .width('100%')
        Text(this.devOs)                                          // OsDisplay
          .fontSize(11)
          .fontColor(this.palette().MUTED_TEXT)
          .width('100%')
        Text(this.devStatus)                                      // StatusDisplay
          .fontSize(10)
          .fontColor(this.palette().SUCCESS)
          .margin({ top: 5 })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 })
    }
    .width('100%')
    .padding(8)
    .borderRadius(8)
    .backgroundColor(this.selected ? this.palette().SELECTION : Color.Transparent)
    .hoverEffect(HoverEffect.Highlight)
    .onClick((): void => {
      this.on_pick();
    })
  }
}

/**
 * 两个状态快照是否**逐字段相同**（用于轮询时的"无事发生就不重建"）。
 *
 * ★ 为什么需要它（1.0.47）：`poll_status()` 每 500ms 把 `this.airplay` /
 *   `this.capture` 换成 napi 返回的新对象。对 @State 来说**换了对象引用就等于变了**，
 *   哪怕每个字段都一模一样，ArkUI 也会把这一页整棵树重渲染一遍 ——
 *   主窗 362 处 `t()` + 全部布局测量，每秒两次，永不停止。空闲时（没在投屏）
 *   这些字段确实一个都不变，却照样在重建，这就是"整个软件发闷"的底噪。
 *
 * ★ 为什么用 JSON 比：这两个对象是 napi 现造的普通对象，字段列表会随版本加，
 *   手写逐字段比较漏一个就会让某个读数**永久冻结**（比多重建几次更糟，
 *   因为它静默）。序列化比一次整树重建便宜两个数量级。
 *
 * ★ 比较失败（抛异常）时返回 false ⇒ 走"照旧赋值"的保守分支，宁可多重建也不冻屏。
 */
function status_snapshot_equal(a: Object | null, b: Object | null): boolean {
  if (a === null || b === null) {
    return a === null && b === null;
  }
  try {
    return JSON.stringify(a) === JSON.stringify(b);
  } catch (error) {
    return false;
  }
}

@Entry
@Component
struct Index {
  @StorageLink(THEME_SCHEME_KEY) scheme: string = 'dark';
  private themePalette(): ThemeColors {
    const palette: ThemeColors | undefined = this.scheme === 'dark' ? DARK : LIGHT;
    return palette ?? FALLBACK_COLORS;
  }

  /**
   * 把应用当前主题同步给系统（ApplicationContext.setColorMode）。
   *
   * 为什么必须调：窗口三键（最小化/最大化/关闭）是**系统**画的，它的图标颜色由系统
   * 依据应用的 colorMode 推导。本项目此前只改了 AppStorage 里的应用内主题，没告诉系统，
   * 于是出现「应用内容已经是深色、系统三键还是按浅色画」——深色标题区上三键几乎看不见。
   * 调了 setColorMode 之后系统三键才会跟着深浅色一起换色。
   *
   * themeIndex: 0=跟随系统 → COLOR_MODE_NOT_SET；1=深色；2=浅色。
   */
  private sync_system_color_mode(): void {
    try {
      if (this.appContext === null) {
        return;
      }
      const appCtx: common.ApplicationContext = this.appContext.getApplicationContext();
      let mode: ConfigurationConstant.ColorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
      if (this.themeIndex === 1) {
        mode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      } else if (this.themeIndex === 2) {
        mode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
      }
      appCtx.setColorMode(mode);
    } catch (error) {
      const failure = error as BusinessError;
      console.warn('iPhoneMirror setColorMode failed:', failure.message);
    }
  }

  // ── Core（逻辑层：来自逐字移植的上游 Core，经 NAPI 暴露） ──
  @State devices: DeviceInfo[] = [];
  @State selectedUdid: string = '';
  @State selectedName: string = '';
  @State selectedModel: string = '';
  @State selectedOs: string = '';
  @State selectedConnection: string = '';
  @State capture: CaptureStatus | null = null;
  @State audioEnabled: boolean = true;
  @State volume: number = 100;
  @State hint: string = '';
  /**
   * 选中设备最近一次的完整记录。
   *
   * 用途与上游 ReconcileDevices 里的 activeCard 相同：正在投屏的手机在 QuickTime
   * 配置生效后会暂时离开 usbmux，设备列表刷新到空时不能把它的卡片与选中一起丢掉，
   * 否则画面还在投、左边却显示"未选择设备"。
   */
  private selectedSnapshot: DeviceInfo | null = null;
  /**
   * 待重启：有线投屏协议切换时，原版会对活动会话走 RestartUsbSessionAsync
   * （MainViewModel.cs:918-928）。单会话 ABI 必须先停稳再起，所以先记下目标模式，
   * 等轮询看到 Stopped(6) 再按新协议重新开始。
   */
  private pendingRestartMode: number = -1;
  /**
   * 最近一次"保存"成功的画面调节值，归一化到 ABI 刻度
   * （brightness∈[-1,1]、contrast/saturation/gamma∈[0,2]；初始即 Core 的结构体默认值）。
   *
   * 采集开始时必须重新推一次：`im_start_capture_with_options` 会把 Core 的采集偏好
   * **整份替换**（CoreApi.cpp:995 `capture_preferences = preferences`），而
   * preferences_from_options 造出来的结构体里 brightness/contrast/... 是默认值 ——
   * 旧的 im_start_capture 路径沿用的是已经带调节值的 capture_preferences，能保住它们。
   * 上游也是这个顺序：先建会话、再 SetDeviceImageAdjustments（MainViewModel.cs:4965）。
   */
  private appliedAdjustments: number[] = [0, 1, 1, 1];

  /**
   * 「敬请期待」浮层的当前文案（空 = 不显示）。
   *
   * 为什么需要它：未实现的功能按钮此前有两类糟糕表现 —— 灰态按钮在 onClick 里
   * 被 `if (enabled)` 静默吞掉（点了完全没反应），部分按钮则只往设置面板里写一行
   * 没人看得见的字。用户无从判断"暂时不可用"还是"根本没做"。这里统一给一个显式、
   * 短暂、不打断操作的反馈。
   */
  @State comingSoonText: string = '';
  private comingSoonTimer: number = -1;
  /** 设备清单指纹，用于避免每 2 秒一次的轮询反复写 @State（见 device_signature）。 */
  private inventorySignature: string = '';
  /** 500ms 心跳的计数，攒够 DEVICE_POLL_TICKS 次做一轮设备枚举（= 原版的 2 秒）。 */
  private devicePollTicks: number = 0;

  // ── 界面状态（对照原版各控件的可见性绑定） ──
  /** NavigationView.IsPaneOpen —— 原版默认 False（收起成 48px 图标条） */
  @State navExpanded: boolean = false;
  /**
   * 导航栏当前渲染宽度（vp）。navExpanded 是「是否展开」的逻辑真值，宽度动画
   * 由这个数值驱动：点击三横按钮时用 animateTo 把 48↔208 做平滑过渡，还原原版
   * Fluent NavigationView 内建的 pane 展开/收起动效（左滑展开、右滑收起）。
   * 为什么不能直接用 navExpanded 三目表达式做动画：布尔翻转是瞬时的，animateTo
   * 需要在一个数值上做插值，所以把宽度独立成一个连续量。
   */
  @State navRailWidth: number = NAV_RAIL_COMPACT;
  /** 三横线按钮是否被按下（按下时图标横向压缩到 0.66，复刻 WPF-UI 按压反馈）。 */
  @State navTogglePressed: boolean = false;
  /**
   * 当前正在显示名称气泡的导航项 key（'' = 不显示）。
   *
   * 原版每个 ui:NavigationViewItem 都设了 ToolTip，hover 时由 WPF 内建弹出；
   * 这里用一个 key 表示"哪一项的气泡开着"，配合 nav_item 上的 bindPopup 实现。
   */
  @State navTipKey: string = '';
  /** 气泡延迟显示的计时器 id（-1 = 无）。 */
  private navTipTimer: number = -1;
  /** 上一次气泡消失的时刻（Date.now），用于复刻 BetweenShowDelay；0 = 尚未显示过。 */
  private navTipLastHideMs: number = 0;
  /**
   * 导航高亮不单独存状态：原版 ApplyWorkspacePanelState() 里只把三个**切换型**
   * 导航项（MirroringPanelToggle / DevicePanelToggle / SettingsPanelToggle）的
   * IsActive 与面板可见性对齐，另外三个（设备绑定器 / 输出 / 驱动）是动作按钮，
   * IsActive 恒为 false。所以高亮由 is_nav_active() 从下面三个面板状态算出。
   */
  /** DevicePanel.Visibility */
  @State showDevicePanel: boolean = true;
  /** MirroringPanel.Visibility */
  @State showMirroringPanel: boolean = false;
  /** ControlPanel 的展开（原版由 Width 0→300 的动效实现） */
  @State showControlPanel: boolean = true;
  /**
   * 开发者模式（调试入口）：在「关于」子窗口里连点版本号 7 次开启，再点一次关闭。
   * 开启后主界面空状态会显示有线链路的原生/系统/权限/环境/驱动/窗口诊断，
   * 方便排查"识别不到 Apple 设备"的问题。非持久化（仅内存），重启即失效。
   * 由 AppStorage 经 @StorageLink 跨窗口（关于子窗 ↔ 主窗）联动。
   */
  @Watch('on_dev_mode_changed')
  @StorageLink(DEVELOPER_MODE_KEY) devMode: boolean = false;
  /**
   * 半透明窗口：开 = 根容器改用带 alpha 的 Fluent 底色并挂 backgroundEffect 磨砂，
   * 关 = 回到原来的实色 BACKGROUND。本工程的色板本来就是 Fluent 半透明 token
   * （SIDEBAR='#C41F1F1F' 即 76% alpha），在 WPF 的不透明窗口上被混成了实色；
   * 主窗背景一旦真透明，这些 alpha 色会直接混到桌面 —— 正是 Win11 原生观感的来路。
   * ★ 已实机确认生效（读数：窗口透明=是、容器配色探测成功）⇒ 属正式特性，不再标实验；
   *   磨砂能否模糊到桌面取决于系统合成器，但即使不模糊也只是"半透明无磨砂"，不影响功能。
   */
  @StorageLink(ACRYLIC_WINDOW_KEY) acrylicOn: boolean = true;
  /**
   * 半透明浓度档位（alpha 十六进制串）。默认取 ROOT_ACRYLIC_ALPHA_HEX，
   * 设置面板可现场切换 ⇒ 调浓淡不必再改代码重建。
   */
  @StorageLink(ACRYLIC_ALPHA_KEY) acrylicAlpha: string = ROOT_ACRYLIC_ALPHA_HEX;
  /**
   * 主窗属性回读（"系统到底给了什么"，不是"我们设了什么"）。
   * 磨砂半透明要能透视桌面，前提是系统真的给了透明窗口；SDK 里没有公开的
   * 「设主窗透明」接口，isTransparent 是只读属性 ⇒ 只能回读，不能下结论靠推断。
   */
  @State windowAcrylicReadout: string = '';
  /** HeaderPanel 的状态文本（原版 Binding DriverState） */
  @State driverState: string = '正在检查 Apple USB 环境…';   // Strings: StatusCheckingEnvironment
  /** 各卡片下方的操作结果行（原版 SettingsStatus） */
  @State settingsStatus: string = '';
  /** 原版 BluetoothControlActionText；未启用时为 BluetoothControlOff。
   *  ★ 三个状态一律带「（实验）」—— 见 reverse_label() 的说明。 */
  @State bluetoothControlText: string = reverse_label('未启用');
  /**
   * 当前 HID 布局的可读文本（'单特征' / '多特征'）。见 BluetoothHidPeripheral
   * 文件头的「HID 布局模式」—— 鸿蒙只能按 UUID 发通知，5 个共用 0x2A4D 的 Report
   * 特征会让投递落点不可控，所以默认走单特征。这里把它显示出来并给一个切换入口，
   * 是为了让"到底是布局问题还是别的问题"能靠一次切换直接判定。
   */
  @State hidLayoutText: string = '单特征';
  /** 布局切换进行中（要重建 GATT 服务，期间禁用按钮，避免连点）。 */
  @State hidLayoutSwitching: boolean = false;
  /** 蓝牙反控总开关（真实状态，不是 UI 假象） */
  @State bluetoothOn: boolean = false;

  /**
   * 本地系统指针当前是否被我们收起来了。
   *
   * 只记"我们改过没有"，**不记"应该是什么"** —— 应该是什么每轮从
   * ReverseControlInput 的真实接管态重算一次（见 apply_pointer_visibility）。
   * 这两件事分开放，是为了让任何一条漏掉的退出路径都能在 500ms 内自愈。
   */
  private pointerHidden: boolean = false;
  /** 指针可见性接口不可用时置位（能力不支持），之后不再反复重试与刷日志。 */
  private pointerHideUnsupported: boolean = false;

  /**
   * 反控接管期间**要不要**收起本地指针。
   *
   * ★ 默认 false = 保持可见。见 WindowServices 里 HIDE_POINTER_ON_TAKEOVER_KEY
   *   的说明：上游之所以敢藏，是因为它那边对端指针一定能动；这边蓝牙 HID 反控
   *   还是实验性的，藏掉本地指针等于把用户唯一的位置反馈也拿走。用户明确要求
   *   「反控时鼠标不要消失」，所以默认可见，想要原版行为的人自己在设置里打开。
   */
  @State hidePointerOnTakeover: boolean =
    AppStorage.get<boolean>(HIDE_POINTER_ON_TAKEOVER_KEY) ?? false;

  /**
   * 蓝牙外设正在启动中。
   *
   * 必须有这个标记：start(ctx) 是异步的（内部要先弹权限框），完成之前
   * isAdvertising() 一直是 false —— 只看 isAdvertising 的话，鼠标在画面上
   * 多划两下就会重复触发启动流程，弹出第二个权限框。
   */
  private bluetoothStarting: boolean = false;
  /**
   * 蓝牙反控的一行详细状态：广播中/已连接哪个客户端/已发多少报表/发送失败数。
   *
   * 与「解码器状态」行同理 —— 反控"点了没反应"时，只有把这些计数摆出来才能
   * 分清是没广播出去、没人连、还是连上了但报表发不出去。
   */
  @State bluetoothStatus: string = '';
  /**
   * ★ 短摘要：蓝牙反控卡片里最关键的三段（"主机 读N 写N 订阅S + 配对命中W"）
   *   单独抽出来做成一行显眼字，让"iPhone 端配置 vs 投递问题"一眼可分。
   *   旧版把它塞进长串里、用 fontSize 9 单行 Text 显示 ⇒ 截断后等于看不到。
   *   这一行的优先级高于下面的长串诊断。
   */
  @State reverseShortDiag: string = '';
  /**
   * 蓝牙鼠标灵敏度（百分比）—— 对应上游 AppliedBluetoothMouseSensitivity。
   *
   * 100% 的语义：鼠标在预览区横划过一个画面宽度 ⇒ iPhone 光标走一整屏。
   * 换算成 HID 相对位移的公式在 ReverseControlInput 里，这里只管取值。
   */
  @State bluetoothSensitivity: number = 100;
  /**
   * 独立预览窗口是否开着（上游 `_secondaryMirrors.IsOpen(device)`）。
   *
   * 它是一个**派生**状态：真实来源是 WindowServices.standalone_preview_open +
   * 窗口是否真的还存在，由每轮 poll_status 的 sync_standalone_state() 同步过来。
   * 这么做的原因：子窗口可能被系统或其它路径直接销毁，只靠"我们点过打开按钮"记
   * 一个布尔，会让主窗口的预览区永远停在「已在独立窗口打开」。
   */
  @State standaloneOpen: boolean = false;
  /**
   * 独立窗口报上来的**详细**异常说明（占位区显示）。
   *
   * 两条不同来源，刻意分两个键（后写的不会盖掉先写的）：
   *   · chromeNotice —— Ability 写的：系统标题栏/系统三键区有没关干净；
   *   · standaloneNotice —— 独立窗口页面写的：比例锁、圆角、最小化是否成功。
   * 独立窗口自己那条栏只有窗口宽度的 8% 高，写不下整句，只能放短徽标
   * （用户 2026-09-21 反馈：一句话就把栏占满、把画面压掉了）。
   */
  @StorageLink(STANDALONE_CHROME_NOTICE_KEY) standaloneChromeNotice: string = '';
  @StorageLink(STANDALONE_NOTICE_KEY) standaloneNotice: string = '';
  /**
   * 有线（USB）链路最近几步的原话，每轮 poll_status 刷新。
   *
   * 存在的原因：原生日志落在应用沙箱里，进程外读不到、用户也打不开，所以
   * "有线采集卡在哪一步"必须由原生层回传到这里显示。空串 = 没有任何记录，
   * 此时界面不显示这一行（不编造）。
   */
  @State usbDiagnostic: string = '';

  /**
   * 最近一次子窗口打开失败的原因（取不到就空串）。
   *
   * 与 usbDiagnostic 同样存在的理由：子窗口是**独立窗口**，它失败的原因原本只有
   * hilog 里有，而 hilog 在应用进程外读不到。于是 SubWindowHost.open() 把失败原因
   * 写进 AppStorage（SUBWINDOW_ERROR_KEY），这里每轮轮询读出来显示在预览区。
   * 没有这条通道时，"点一下闪退/闪一下"就只能靠猜。
   */
  @State windowError: string = '';
  /** 已经显示过的那条，避免同一条反复刷（AppStorage 里的值在下次成功开窗前不清）。 */
  private shownWindowError: string = '';

  /**
   * 环境诊断：为什么看不到设备。Core 的 ohos_probe::probe() 原话，每 2 秒刷新一次
   * ——**但只在没有采集会话时**（见 refresh 里的说明）。
   *
   * 存在的理由与 usbDiagnostic 相同，只是颗粒度更大：usbDiagnostic 说的是"这一轮
   * 采集卡在哪一步"，而这一条回答的是"设备根本没出现，是权限没放行、还是驱动配置
   * 里没有 Apple VID"。两者都是进程外读不到的原生事实，不让它们出来，用户就只能猜。
   */
  @State environmentDiagnostic: string = '';
  /** 环境诊断自身的返回码。非 0 时 diagnostic 必为空串，界面改显示 lastError()。 */
  @State environmentStatus: number = 0;
  /**
   * 扩展外设驱动（DriverExtensionAbility）的落盘状态。
   *
   * `OH_Usb_GetDevices` 只返回"驱动配置信息里 vid 匹配"的设备，而那份配置来自
   * 本扩展在 module.json5 里声明的 vid/pid、且**要等它被 bind 之后才生效**。
   * 所以"驱动扩展有没有被系统拉起来"是排查识别不到设备时的第一手证据 ——
   * 它写文件（跨 VM 可读），这里读出来显示。
   *
   * （注：早期注释在这句前面还有"USB DDK 只在驱动扩展生命周期内可用"，那条
   * 文档措辞在本机实测不成立 —— 入口 Ability 里 OH_Usb_Init() 返回 0。别再据此
   * 把 DDK 调用点搬进扩展。）
   */
  @State usbDriverNote: string = '';
  /** 驱动扩展是否已经落盘（present=true）。用来决定上面那条要不要标成待处理。 */
  @State usbDriverReady: boolean = false;
  /**
   * **不经过 USB DDK** 的系统 USB 视图（@ohos.usbManager.getDevices）。
   *
   * 它是判别"谁挡住了设备"的关键旁证：系统看得到 Apple 设备而 DDK 枚举为空 ⇒ 卡在
   * 驱动注册或 ACL；系统也看不到 ⇒ 问题在线材/供电/iPhone 那一侧。
   */
  @State usbHostSummary: string = '';
  /** 系统视图里的 Apple 设备台数。0 且查询成功时，上面那条要标成待处理。 */
  @State usbHostAppleCount: number = 0;
  @State usbHostOk: boolean = false;
  /**
   * ACCESS_DDK_USB 的授予状态（问系统令牌账本，不是问推断）。
   *
   * 单独一条的理由：`OH_Usb_Init()` 只会失败在两个码上 —— 201（权限检查失败）与
   * 27400002（连不上 DDK 服务）。有了这一行，"到底是哪个"就不需要再猜：权限已授予
   * 却仍失败 ⇒ 问题不在权限（见 UsbPermission.ets 的说明）。
   */
  @State usbPermissionNote: string = '';
  @State usbPermissionGranted: boolean = false;
  @State usbPermissionOk: boolean = false;
  /**
   * 外部设备驱动扩展的绑定状态（@ohos.driver.deviceManager.bindDevice）。
   *
   * 单独一条的理由：驱动是**懒加载**的（launchOnBind），没有客户端 bind 就永远
   * 不启动；而 module.json5 里那套 vid/pid「驱动配置信息」要等它被 bind 之后才
   * 生效 —— 于是"枚举不到设备"里有一半原因要到这里来找，光看权限与 vid/pid 是
   * 看不出来的。
   */
  @State usbDriverBindNote: string = '';
  @State usbDriverBindOk: boolean = false;

  // ── 设置项（对照原版各 ComboBox / Slider 的绑定） ──
  @State appMode: number = 1;
  @State resolutionPreset: number = 0;
  @State frameRateIndex: number = 1;
  @State decoderPreference: number = 0;
  @State wirelessProfile: number = 1;
  @State wirelessName: string = 'iPhoneMirror AirPlay';
  /** AirPlay 接收端状态（每轮 poll_status 刷新）；null = 还没查过。 */
  @State airplay: AirPlayStatus | null = null;
  /** AirPlay 实测解码帧率（fps，EMA 平滑；0 = 无样本）。UI 显示用，见 poll_status。 */
  @State airplayFps: number = 0;
  // 上轮轮询的 decodedFrames / 时间戳（fps 差分用，不参与渲染故不加 @State）。
  private prevAirplayDecoded: number = -1;
  private prevAirplayPollMs: number = 0;
  @State usbMode: number = 0;
  @State languageIndex: number = AppStorage.get<number>(LANG_INDEX_KEY) ?? 0;
  @State themeIndex: number = 0;

  private xcController: XComponentController = new XComponentController();
  private statsTimer: number = -1;
  private surfaceAttached: boolean = false;
  /**
   * 上一次成功挂载的 surfaceId。
   *
   * 为什么不能只用一个布尔：XComponent 的 surface 会被系统销毁重建（窗口最大化/
   * 还原、DPI 变化、后台切回等），此时 onLoad 会带着**新的** surfaceId 再触发一次。
   * 早期实现用 `surfaceAttached` 直接短路，于是新 surface 永远不会被挂载，而渲染器
   * 手里的 EGLSurface 指向一个已经失效的窗口 —— 表现就是「解码一直在出帧、画面全黑、
   * 没有任何报错」。改成按 id 比对，换了 surface 就重挂。
   */
  private attachedSurfaceId: string = '';
  /**
   * **主窗口** XComponent 当前有效的 surfaceId（与 attachedSurfaceId 分开记）。
   *
   * 为什么要分开：独立预览窗口开着的时候，渲染器挂的是**它**的 surface，
   * 主窗口的 surface 暂时没人挂。此时若系统重建了主窗口的 surface（最大化/DPI
   * 变化/切回前台），on_surface_ready 会带着新 id 进来 —— 那一刻**绝不能**去挂它，
   * 否则画面会被从独立窗口抢回主窗口。所以主窗口的 surfaceId 单独记，等独立窗口
   * 关掉之后再按它接回去。
   */
  private mainSurfaceId: string = '';
  /**
   * 连续多少轮 poll 没在窗口管理器里找到独立预览窗口。
   *
   * 用途：窗口被**别的路径**销毁时（不走我们注册的关窗钩子），标志位会一直挂着
   * true，主窗口的预览区就永远停在占位。这里连续两轮（≈1 秒）都找不到窗口才判定
   * "它没了"，把画面接回来 —— 留一轮余量是因为刚开窗时窗口对象还没进管理器，
   * 那一瞬间找不到是正常的，不能当成关闭。
   */
  private standaloneMissingTicks: number = 0;
  /**
   * 是否**见过**独立窗口对象。
   *
   * 为什么需要这个额外的布尔量：窗口管理器里"窗口还没创建完"和"窗口已经被销毁"在
   * `findWindow` 眼里是一模一样的（都找不到）。只数缺失轮次的话，"开窗慢一点"
   * 就会被自己判死、把画面抢回主窗口 —— 而窗口随后又冒出来了。
   * 所以只在**先见过一次**之后才开始数缺失轮次：那时"找不到"就真的只可能是被销毁了
   * （真正"从没开起来"的情况由 `WindowServices.standalone_preview_open` 那侧负责，
   *  `SubWindowHost.open` 的 catch 会把它清掉）。
   */
  private standaloneSeen: boolean = false;
  /**
   * 上一次 poll 时 BLE 客户端是否连着。
   *
   * 用途：识别「刚连上」这个跃迁 —— 上游在那一刻调
   * `BluetoothControlNoticeWindow.ShowConnected`（MainViewModel.cs:1746），
   * 把「等待连接」那个提示窗口切成「已连接」并开始倒计时自动关闭。
   */
  private lastBluetoothConnected: boolean = false;
  /** 本 UIAbility 的 Context，子窗口开窗时作为宿主传给 SubWindowHost.open。 */
  private appContext: common.Context | null = null;
  /**
   * 后台保活失败原因。App 一进后台进程被冻结的话，mDNS 响应器会立刻哑掉，
   * 而"已应答 N 次"是累计值、回到前台还挂着 —— 必须把保活失败说出来，
   * 否则这个故障会一直静默。
   */
  @State keepAliveError: string = '';
  /** 上一次采集状态，用于检测状态跃迁（投屏错误 / 流中意外停止）。 */
  private lastCaptureState: number = -1;
  /**
   * 用户主动点「停止」时为 true，避免在主动停止时也弹「投屏已停止」提示。
   * 仅在观察到位 Stopped 跃迁后复位（见 poll_status）。
   */
  private userInitiatedStop: boolean = false;

  // ───────────────────────── 生命周期 ─────────────────────────

  aboutToAppear(): void {
    AppStorage.setOrCreate(THEME_PREF_KEY, this.themeIndex);
    recomputeThemeScheme();
    this.appContext = getContext(this);
    // mDNS 广播需要 UIAbilityContext（@ohos.net.mdns 的 addLocalService 要它）。
    // getContext(this) 在 UIAbility 里拿到的就是 UIAbilityContext。
    airPlayMdns.attach(this.appContext as common.UIAbilityContext);
    // 首屏就把应用主题同步给系统，系统三键颜色跟着一致。
    this.sync_system_color_mode();
    // 回读主窗真实属性：半透明磨砂能否透视桌面由系统合成器决定，不靠推断。
    this.refresh_window_acrylic_readout();

    // 画面调节：把预览/保存/回滚三个委托接到原生预览渲染器。
    // 不接的话 ImageSettingsWindow 的 apply 会落到 null 分支返回假成功，
    // 正好踩中工程「不许假成功」的纪律。
    const applyImageAdjustments = (values: ImageAdjustmentValues): ImageAdjustmentResult => {
      // 滑杆是 0-100/0-200 刻度，原生 ABI 要的是 [-1,1]/[0,2] 归一化值。
      const normalized: number[] = [
        values.brightness / 100, values.contrast / 100,
        values.saturation / 100, values.gamma / 100,
      ];
      const code: number = setImageAdjustments(
        normalized[0], normalized[1], normalized[2], normalized[3]);
      if (code === 0) {
        // 记下来：下一次开始采集后要重新推给新会话，否则会被换成默认值。
        this.appliedAdjustments = normalized;
        return { success: true, message: '' };
      }
      return { success: false, message: lastError() };
    };
    WindowServices.register_image_adjustments(
      applyImageAdjustments, applyImageAdjustments, applyImageAdjustments);

    const result: number = initialize();
    if (result === 0) {
      // Strings: EnvironmentReadyApple
      this.driverState = 'Apple 设备通道已就绪，正在检查采集后端。';
      this.refresh();
    } else {
      this.driverState = `核心加载失败：${lastError()}`;   // Strings: CoreLoadFailedFormat
      this.show_startup_error(lastError());
    }
    this.statsTimer = setInterval((): void => {
      this.poll_status();
      // 设备清单：原版 2 秒一次。插上数据线后界面必须在这个周期内认出设备 ——
      // 认不出就没有选中项，「开始投屏」会一直是灰的（原版靠同一个定时器刷新）。
      this.devicePollTicks += 1;
      if (this.devicePollTicks >= DEVICE_POLL_TICKS) {
        this.devicePollTicks = 0;
        // report_empty = false：自动轮询不写 hint，免得把用户刚看到的失败原因冲掉。
        this.refresh(false);
      }
    }, 500);
  }

  aboutToDisappear(): void {
    // 退出前两件收尾，顺序不能颠倒：
    //   ① 先退出接管 —— 它会把按下的鼠标键/键盘帽全部放掉，否则 iPhone 侧
    //      会以为用户还按着不放（一直拖动）；
    //   ② 再把本地指针放回来 —— 藏指针是全局状态，留在这里不管的话，
    //      用户下次开应用会发现鼠标是看不见的。
    try {
      ReverseControlInput.shared().setHoverSource('main', false);
    } catch (error) {
      console.warn('iPhoneMirror takeover release failed:', (error as BusinessError).message);
    }
    this.restore_pointer_visibility();
    if (this.statsTimer >= 0) {
      clearInterval(this.statsTimer);
      this.statsTimer = -1;
    }
    this.surfaceAttached = false;
    this.attachedSurfaceId = '';
    detachPreview();
    stopCapture();
    // 页面销毁时把 AirPlay 接收端也停掉，否则 RTSP/HTTP 端口一直被占着，
    // 下次进入应用再启动会失败。
    airplayStop();
    airPlayMdns.clear();
    shutdown();
  }

  /**
   * 子窗口统一开窗入口：拿到宿主 Context 后回调 opener，避免每个按钮都写一遍空判断。
   * 对应原版各 MainWindow 命令里 `new XxxWindow(owner, ...)` 后 `Show()` 的那段。
   */
  private launch_subwindow(opener: (ctx: common.Context) => void): void {
    if (this.appContext !== null) {
      opener(this.appContext);
    }
  }

  // ───────────────────────── 核心交互 ─────────────────────────

  /**
   * 设备列表刷新 + 选中回落。
   *
   * 上游是 MainWindow 里 2 秒一次的 DispatcherTimer → RefreshAsync →
   * ReconcileDevices → StableDeviceSelection.ChooseUdid（MainWindow.xaml.cs:356、
   * MainViewModel.cs:2914、StableDeviceSelection.cs:29），回落顺序逐条照搬：
   *   本轮可见顺序 → 仍可见的旧选中 → 正在投屏的那台 → 第一个 → 都没有则清空。
   *
   * 「清空」这一步不能省：设备拔掉后原版 SelectedDevice 变成 null，
   * CaptureActionButton 的 Command 随之 CanExecute=false ⇒ 按钮变灰。此前这里
   * 只在 selectedUdid 为空时才选第一个、从不回退，于是拔线后按钮仍然是亮的。
   *
   * @param report_empty 清单为空时是否写 hint。启动 / 手动刷新传 true（用户按了按钮，
   *   要给明确答复）；2 秒一次的自动轮询传 false，否则状态行每 2 秒被"未发现设备"
   *   淹一次，会把用户刚看到的失败原因冲掉。
   */
  refresh(report_empty: boolean = true): void {
    if (report_empty) {
      // 用户主动刷新（或启动）：绑驱动的重试计数清零，让他能立刻把上一轮的失败结论
      // 推翻一次，而不是等到设备重插、deviceId 变了才重来。
      reset_usb_driver_bind_retry();
    }
    // 环境诊断先刷：它回答的是"设备为什么根本没出现"，而那正是下面这段清单回落
    // 走到"空"时用户会问的问题。只在没有采集会话时探：ohos_probe 会 OH_Usb_Init
    // 并对每台 Apple 设备读一次设备描述符，会话期间每 2 秒来一遍是没必要的打扰
    // （也违背 Core 里"环境轮询应当只读且无副作用"的约定）。
    this.refresh_usb_environment(!this.has_capture_session());

    const capturing: boolean = this.has_capture_session();
    let list: DeviceInfo[] = this.devices;
    if (!capturing) {
      // 有线会话活着时**不重新枚举 usbmux**。上游 RefreshAsync 明确关掉了这条
      // （MainViewModel.cs:2464「must not reopen usbmux and introduce a visible
      // preview hitch」）—— 重开 usbmux 会让预览可见地卡一下，而正在投屏的手机
      // 本来也已经离开普通 usbmux。
      list = refreshDevices();
    }

    // StableDeviceSelection.ChooseUdid 的三段回落，顺序照搬。
    let retained: DeviceInfo | null = find_device(list, this.selectedUdid);
    let next: DeviceInfo[] = list;
    if (retained === null && capturing) {
      // 会话还活着但清单里没有它：把上一轮那张卡片留着（上游 ReconcileDevices 的
      // activeCard 分支），否则会在画面还在投的时候显示成"未选择设备"。
      const snapshot: DeviceInfo | null = this.selectedSnapshot;
      if (snapshot !== null) {
        retained = snapshot;
        next = list.concat([snapshot]);
      }
    }
    // 每 2 秒跑一遍：清单没变就不写 @State，省掉一次无意义的重渲染。
    const signature: string = device_signature(next);
    if (signature !== this.inventorySignature) {
      this.inventorySignature = signature;
      this.devices = next;
    }

    if (retained === null && list.length > 0) {
      retained = list[0];                    // 前两段都没命中 ⇒ 取第一个可见设备
    }
    if (retained === null) {
      // 清单彻底空下来：清空选中（原版 SetSelectedDevice(null)）⇒ 「开始投屏」随之变灰。
      this.clear_selection();
      // Strings: EnvironmentNeedsApple
      this.driverState = '需要启动 Apple 设备服务并连接 iPhone 或 iPad。';
      if (report_empty) {
        this.hint = `未发现设备：${lastError()}`;
      }
      return;
    }
    this.select_device(retained);
    this.driverState = 'USB 采集就绪';                     // Strings: DriverCaptureReady
  }

  /**
   * 刷新 USB 环境诊断与驱动扩展状态。
   *
   * probe=true 时向 Core 要一次环境探测结论；false 时只更新驱动扩展那条（读一个
   * 小文件，很便宜）。之所以让调用方决定，是因为探测本身会 OH_Usb_Init 并对每台
   * Apple 设备读一次设备描述符 —— 会话期间不该按 2 秒的节奏来一遍。
   */
  refresh_usb_environment(probe: boolean): void {
    const ctx: common.Context | null = this.appContext;
    if (ctx !== null) {
      const state: UsbDriverState = read_driver_state(ctx.filesDir);
      // 把当前的绑定阶段一并传进去：状态文件里的记录会跨进程存活，绑定失败时那条
      // 「已拉起」必然来自更早的一次运行，需要由这句话主动说明，否则两句会互相矛盾。
      const note: string = describe_driver_state(state, usb_driver_bind_state().phase);
      if (note !== this.usbDriverNote) {
        this.usbDriverNote = note;
      }
      if (state.present !== this.usbDriverReady) {
        this.usbDriverReady = state.present;
      }
    }

    // 系统侧视图：不经过 DDK，不受驱动框架与 ACL 影响，所以它永远要在（否则
    // "DDK 里没有设备"就分不清是系统也没认到，还是只对我们不可见）。
    const host: UsbHostScan = scan_usb_host();
    if (host.summary !== this.usbHostSummary) {
      this.usbHostSummary = host.summary;
    }
    if (host.appleCount !== this.usbHostAppleCount) {
      this.usbHostAppleCount = host.appleCount;
    }
    if (host.ok !== this.usbHostOk) {
      this.usbHostOk = host.ok;
    }

    // 权限授予状态：同样与 DDK 无关（问的是令牌账本），所以无条件刷。
    // 它回答的是"OH_Usb_Init 失败到底是 201 还是 27400002"里的前一半。
    const grant: DdkPermissionGrant = check_ddk_usb_permission();
    if (grant.summary !== this.usbPermissionNote) {
      this.usbPermissionNote = grant.summary;
    }
    if (grant.granted !== this.usbPermissionGranted) {
      this.usbPermissionGranted = grant.granted;
    }
    if (grant.ok !== this.usbPermissionOk) {
      this.usbPermissionOk = grant.ok;
    }

    // 驱动绑定状态：纯读一次（真正的绑定请求只在空闲态发起，见下）。
    const bind: DriverBindState = usb_driver_bind_state();
    if (bind.summary !== this.usbDriverBindNote) {
      this.usbDriverBindNote = bind.summary;
    }
    if ((bind.phase === 'bound') !== this.usbDriverBindOk) {
      this.usbDriverBindOk = bind.phase === 'bound';
    }

    if (!probe) {
      return;
    }

    // 空闲、且系统 USB 服务确实看得到 Apple 设备时，才去请求绑定外部设备驱动。
    // 调用是幂等的，重复调不会重复绑定。
    //
    // 绑定的意义，按 2026-09-19 的实测重新表述（原先这里照抄文档措辞，写的是
    // "USB DDK 只在驱动扩展的生命周期内可用"，那句话把两件事混成了一件）：
    //   · "驱动扩展是懒加载的、没有客户端 bind 就不会起来" —— **成立**，且已被
    //     证实：onConnect 的时间戳正好落在第一次 bind 之后。
    //   · "DDK 只能在扩展里用" —— **不成立**：入口 Ability 里 OH_Usb_Init() 返回 0
    //     （USB_DDK_SUCCESS），从来没有出现过文档/注释里预告的 27400002。
    // 所以绑定真正的作用是让 module.json5 里声明的 VID/PID「驱动配置信息」生效，
    // 使 OH_Usb_GetDevices 不再把 iPhone 过滤掉。别再把 DDK 调用点往扩展里搬。
    if (this.usbHostOk && this.usbHostAppleCount > 0) {
      // try/catch 是**第三道防线**，不是为了替 binder 兜它的错误：
      // 2026-09-19 10:14:58 那次崩溃就是 bindDevice 同步抛 BusinessError，异常从这里
      // 一路冒到 aboutToAppear，框架判定 uncatchable ⇒ 进程被杀（寿命 1 秒）。这里
      // 保的是"任何 UI 心跳路径上的异常都不许杀死 App"，具体原因仍由 binder 记账。
      try {
        ensure_usb_driver_bound();
      } catch (error) {
        const failure: BusinessError = error as BusinessError;
        // Strings: DriverBindCrashGuard
        this.usbDriverBindNote =
          `绑定外部设备驱动时抛出未捕获异常（${failure.code}）：${failure.message}`;
      }
    }
    const environment: EnvironmentDiagnostics = getEnvironment();
    if (environment.status !== 0) {
      // 取不到就说取不到。把空串当"没问题"显示，正是这类诊断最容易犯的假成功。
      const text: string = `环境诊断失败（${environment.status}）：${lastError()}`;
      if (text !== this.environmentDiagnostic) {
        this.environmentDiagnostic = text;
      }
      this.environmentStatus = environment.status;
      return;
    }
    if (environment.diagnostic !== this.environmentDiagnostic) {
      this.environmentDiagnostic = environment.diagnostic;
    }
    this.environmentStatus = 0;
  }

  select_device(device: DeviceInfo): void {
    this.selectedUdid = device.udid;
    this.selectedName = device.name.length > 0 ? device.name : device.udid;
    this.selectedModel = device.productType;
    this.selectedOs = `iOS ${device.osVersion}`;
    // ConnectionState：0 Offline、1 Usb、2 Network（见 CoreApi.h）
    // Strings: ConnectionDisconnected / ConnectionConnected
    this.selectedConnection = device.state === 0 ? '未连接' : '已连接';
    this.selectedSnapshot = device;
  }

  /**
   * 对齐原版 SetSelectedDevice(null)：设备消失后选中一并清空。
   * 三个回落值取上游 SelectedName/SelectedModel/SelectedOs/SelectedConnection
   * 的空值分支（MainViewModel.cs:718-722）。
   */
  clear_selection(): void {
    this.selectedUdid = '';
    this.selectedName = '';            // → 界面显示 NoDeviceSelected「未选择设备」
    this.selectedModel = '—';
    this.selectedOs = '—';
    this.selectedConnection = 'USB';
    this.selectedSnapshot = null;
  }

  poll_status(): void {
    // 子窗口打开失败的原因（由 SubWindowHost.open 写进 AppStorage）。放在最前面：
    // 它与采集状态无关，不能被下面任何早退（state 缺失 / state < 0）吞掉。
    this.sync_window_error();

    // 蓝牙反控：同样放在所有早退之前 —— 它是独立于投屏链路的开关，
    // 不该因为"还没投屏"就停止上报（否则广播失败的原因永远看不见）。
    this.refresh_bluetooth_status();
    this.sync_reverse_control_source();
    // 本窗口此刻有没有可操控的画面（两个条件都要）：两条投屏链路都要算
    // （USB 采集 + 无线镜像），且画面已挪到独立窗口时这里只剩占位图。
    // 每轮报一次，是为了让"鼠标已停在画面上、画面随后才出现"也能自动接管。
    ReverseControlInput.shared().setPictureAvailable(
      'main', this.has_preview_picture() && !this.standaloneOpen);
    // 通道状态与画面状态随时可能被别处改掉（iPhone 断开、绑定器停了外设、
    // 画面被挪到独立窗口），每轮重算一次接管态，避免停在一个过期值上
    // （该释放不释放 / 该接管不接管）。
    ReverseControlInput.shared().refreshChannel();
    // 本地指针可见性自愈：必须排在 refresh_bluetooth_status 之后 —— 后者会把
    // 「通道被别处停掉」这类情况下的接管态复位，藏/显要按复位后的真实状态算。
    this.apply_pointer_visibility();
    // 键盘焦点自愈：与"藏指针"同一套纪律 —— 只在"进入接管时抢一次"是不够的，
    // 焦点被别的窗口夺走、或因标识写法失效而从未拿到时，键盘会永久哑掉且无提示。
    // 每轮重算：还在接管又没拿到焦点，就再要一次。（requestFocus 失败不抛异常，
    // 只返回 false，所以必须看返回值 —— 见 focus_preview_input。）
    if (ReverseControlInput.shared().isTakingOver()
      && !ReverseControlInput.shared().keyboardFocusOk()) {
      this.focus_preview_input();
    }
    // 独立预览窗口：同样放在早退之前。它要处理两种"窗口没了"的路径（我们关的、
    // 被别处销毁的），以及投屏设置窗口发来的开窗请求 —— 都不该受采集状态影响。
    this.sync_standalone_state();

    // 无线链路：先把待广播/待注销的服务消化掉，再取一次状态。
    // 放在采集状态之前，mDNS 的成败不会因为采集查询提前 return 而漏报。
    // mDNS 这边抛异常也不能把后面的状态读取带崩——否则整个界面会永远停在
    // 上一帧（曾经就是这么表现成「状态行卡在正在读取…」的）。
    try {
      airPlayMdns.pump();
    } catch (error) {
      const failure = error as BusinessError;
      console.warn('iPhoneMirror mDNS pump failed:', failure.message);
    }
    // ★ 只在快照**真的变了**时才换 @State 的引用：换了引用 = 整树重渲染，
    //   而空闲时（没在投屏）这一整包字段一个都不会变，没必要每秒重建两次。
    const apFresh: AirPlayStatus | null = airplayGetStatus();
    if (!status_snapshot_equal(this.airplay, apFresh)) {
      this.airplay = apFresh;
    }

    // AirPlay 实测解码帧率：相邻两轮轮询的 decodedFrames 差分（500ms 轮询周期，
    // EMA 平滑抗抖动）。分辨率/延迟直接取状态里的实测值，只有帧率需要本地算。
    {
      const apNow: AirPlayStatus | null = apFresh;
      if (apNow !== null && apNow.running !== 0 && apNow.clients > 0) {
        const nowMs: number = Date.now();
        if (this.prevAirplayDecoded >= 0 && this.prevAirplayPollMs > 0) {
          const dtSec: number = (nowMs - this.prevAirplayPollMs) / 1000;
          if (dtSec >= 0.2) {
            const instant: number = (apNow.decodedFrames - this.prevAirplayDecoded) / dtSec;
            if (instant >= 0 && instant < 240) {
              this.airplayFps = this.airplayFps > 0
                ? (this.airplayFps * 0.7 + instant * 0.3)
                : instant;
            }
          }
        }
        this.prevAirplayDecoded = apNow.decodedFrames;
        this.prevAirplayPollMs = nowMs;
      } else {
        this.airplayFps = 0;
        this.prevAirplayDecoded = -1;
        this.prevAirplayPollMs = 0;
      }
    }
    // 同上：USB 采集状态空闲时也不变，别用"新对象"骗 ArkUI 重建整棵树。
    const capFresh: CaptureStatus | null = getCaptureStatus();
    if (!status_snapshot_equal(this.capture, capFresh)) {
      this.capture = capFresh;
    }
    const status: CaptureStatus | null = capFresh;
    // 状态查询本身失败（state < 0 是 JsGetCaptureStatus 如实给的 -1）不做跃迁判定。
    if (status === null || status.state < 0) {
      return;
    }
    const prevState: number = this.lastCaptureState;
    const state: number = status.state;
    // 有线诊断：会话不在（Idle）时清空，避免把上一轮的记录当成本次结果；
    // 其余状态（含 Error / Stopped）都照实读，失败现场因此得以保留在屏幕上。
    this.usbDiagnostic = state === 0 ? '' : usbDiagnostics();
    // 有线投屏协议切换：排队中的重启。必须在状态跃迁处理之前做掉，
    // 否则「刚停稳又被当成意外停止」的告警会先弹出来。
    if (this.pendingRestartMode >= 0) {
      if (state === 6) {
        // 停稳了：按新模式重新开始（原版 RestartUsbSessionAsync 的效果）。
        this.pendingRestartMode = -1;
        this.start();
      } else if (state === 7) {
        // 停不下来：不硬来，如实说明新模式没接上。
        this.pendingRestartMode = -1;
        this.settingsStatus = `未能按新模式重新连接：${status.message}`;
      }
    }
    if (state === 7 && prevState !== 7) {
      // CaptureState::Error：采集失败跃迁，弹错误提示（no-ping 超时再弹专属向导）。
      this.on_capture_error(status.message);
    } else if (state === 6 && prevState !== 6) {
      // CaptureState::Stopped：仅当「流中（Streaming/Stopping）意外结束」且非用户主动停止才提示。
      if (!this.userInitiatedStop && (prevState === 4 || prevState === 5)) {
        this.on_capture_stopped();
      }
      this.userInitiatedStop = false;
    }
    this.lastCaptureState = state;
  }

  /**
   * 把"子窗口打开失败"的原因从 AppStorage 提到界面上。
   *
   * 这条通道是必须的：子窗口失败时只会在 hilog 里留一行，而 hilog 读不到，
   * 用户看到的就是"点一下闪退/闪一下"。开窗成功时 SubWindowHost 会清掉这个键，
   * 所以这里只要读到非空且与上次显示的不同，就更新一行。
   */
  private sync_window_error(): void {
    let text: string = '';
    try {
      text = AppStorage.get<string>(SUBWINDOW_ERROR_KEY) ?? '';
    } catch (error) {
      text = '';
    }
    if (text !== this.shownWindowError) {
      this.shownWindowError = text;
      this.windowError = text;
    }
  }

  /** 采集失败：依诊断决定弹「错误提示」还是「连接超时」向导，二者都不假成功。 */
  private on_capture_error(diagnostic: string): void {
    if (this.appContext === null) {
      return;
    }
    const ctx: common.Context = this.appContext;
    if (is_no_ping_timeout(diagnostic)) {
      // 原版 CaptureRecoveryWindow.ShowRecovery()：no-ping 超时走专属向导。
      open_capture_recovery(ctx, true);
    } else {
      // 原版 CaptureStatusNoticeWindow.ShowError(title, body, diagnostic, reverseControl)。
      // 把有线链路的原生诊断接在概括性异常文案后面：这条链路上连续几步都可能是
      // 失败点（认领接口 / 0x52 / 重枚举 / 端点），只给结论等于让人去猜。
      const usb: string = this.usbDiagnostic.length > 0
        ? `\n\nUSB 链路：${this.usbDiagnostic}`
        : '';
      show_capture_error(ctx, '投屏错误', '', `${diagnostic}${usb}`, false);
    }
  }

  /** 流中意外停止：对应原版 CaptureStatusNoticeWindow.ShowStoppedThen()。 */
  private on_capture_stopped(): void {
    if (this.appContext === null) {
      return;
    }
    show_capture_stopped_then(this.appContext, '投屏已停止',
      '检测到投屏会话已结束，可重新选择设备开始投屏。', (): void => {
        // 意外停止后预览 surface 已失效，下一帧重建时再挂载。
        this.surfaceAttached = false;
        this.attachedSurfaceId = '';
      });
  }

  /** 启动失败：对应原版 StartupErrorWindow（原生组件加载失败等）。 */
  private show_startup_error(detail: string): void {
    if (this.appContext === null) {
      return;
    }
    open_startup_error(this.appContext, {
      summary: '',
      detail: detail,
      logPath: '',
      nativeLoadFailure: true,
    });
  }

  /**
   * 组装这次采集要用的全部设置。
   *
   * 必须一次带全：im_start_capture_with_options 会把 Core 里的采集偏好**整份替换**
   * （CoreApi.cpp:983 的 preferences_from_options），没带的字段会被重置成 0。
   * 上游也是整份传的（MainViewModel.CaptureSessionStartSettings:4931 →
   * CreateDeviceSession → im_session_create，NativeCore.cs:754）。
   */
  private capture_options(): StartCaptureOptions {
    const volume_percent: number = this.volume < 0 ? 0
      : (this.volume > 100 ? 100 : this.volume);
    const options: StartCaptureOptions = {
      requestedWidth: RESOLUTION_WIDTH[this.resolutionPreset],
      requestedHeight: RESOLUTION_HEIGHT[this.resolutionPreset],
      targetFps: FRAME_RATE_VALUES[this.frameRateIndex],
      playAudio: this.audioEnabled ? 1 : 0,
      audioVolume: volume_percent / 100.0,
      // 高级模式的自定义 HPD1 尺寸：界面还没有那个入口（原版要先连点版本号 5 次），
      // 按"未开高级模式"传 0/0。
      usbWidth: 0,
      usbHeight: 0,
      usbProjectionMode: this.usbMode,          // 卡片 3「有线投屏协议」
      decoderPreference: this.decoderPreference,
      // 色彩输出偏好：界面还没有这个选项，取 1 = SDR tone-map —— 既是 Core 里
      // CapturePreferences 的默认值（ForceSdrToneMap，ICaptureSession.h:92），
      // 也是上游写死的那个 1（NativeCore.cs 的 CreateDeviceSession(..., 1U)）。
      // 传 0（自动）会与默认行为不一致。
      colorOutputPreference: 1,
    };
    return options;
  }

  start(): void {
    if (!this.can_start()) {
      // 按钮此时是灰的（原版 Command CanExecute=false 连点都点不动）。真走到这里
      // 只能说明状态与按钮不同步，如实说出原因，不写"已请求开始投屏"。
      this.hint = this.selectedUdid.length === 0
        ? '请先选择设备'                                   // Strings: 无对应键，沿用原版语义
        : '当前已有投屏会话，请先停止投屏';
      return;
    }
    // 走 with_options 而不是 startCapture(udid)：有线投屏模式、解码器偏好、色彩偏好
    // 在 C ABI 里只有这一条入口（没有对应 setter），不带就等于没选。
    const result: number = startCaptureWithOptions(this.selectedUdid, this.capture_options());
    if (result === 0) {
      this.hint = '已请求开始投屏';                        // Strings: StartRequested
      this.usbDiagnostic = usbDiagnostics();
      // 建好会话后立刻把画面调节重新推一次。with_options 换掉了 Core 的整个
      // preferences 结构（含 brightness/contrast/saturation/gamma 四项），不补这一下，
      // 用户在开始投屏前调好的画面对比度/饱和度会在这一瞬间被打回默认值。
      setImageAdjustments(this.appliedAdjustments[0], this.appliedAdjustments[1],
        this.appliedAdjustments[2], this.appliedAdjustments[3]);
    } else {
      // 同步失败时状态机可能一直停在 Idle，poll_status 那条路径不会来读诊断，
      // 所以这里显式取一次 —— 否则"点了开始就失败"会是完全无信息的一次失败。
      this.hint = `开始投屏失败：${lastError()}`;          // Strings: StartFailedFormat
      this.usbDiagnostic = usbDiagnostics();
    }
  }

  /** 停止采集。返回 ABI 的 Result 码（0 = Ok）—— 「切模式重启」那条路径要拿它判断。 */
  stop(): number {
    this.userInitiatedStop = true;
    const result: number = stopCapture();
    if (result === 0) {
      this.hint = '投屏已停止，会话资源已释放';            // Strings: StopSessionReleased
    } else {
      this.hint = `停止投屏失败：${lastError()}`;          // Strings: StopFailedFormat
    }
    return result;
  }

  /** XComponent onLoad 时 surface 已就绪，surfaceId 由 controller 同步取回。 */
  on_surface_ready(): void {
    const surfaceId: string = this.xcController.getXComponentSurfaceId();
    if (surfaceId.length === 0) {
      this.hint = '未取到 surfaceId';
      return;
    }
    // 先无条件记录：这是主窗口**当前**有效的 surface，独立窗口关掉之后要靠它接回来。
    this.mainSurfaceId = surfaceId;
    // 独立窗口开着的时候画面归它 —— 此刻绝不许把主窗口的 surface 挂上去，
    // 那等于把画面从独立窗口抢回来（系统重建 surface 时会走到这里）。
    if (this.standaloneOpen) {
      return;
    }
    this.attach_main_preview();
  }

  /**
   * 把预览接回**主窗口**的 surface（幂等）。
   *
   * 什么时候会被调到：① 正常 onLoad 挂载；② 独立预览窗口关闭之后
   * （上游对应 OnIndependentPreviewClosed → QueueMainPreviewHostSync）。
   * 幂等是靠 attachedSurfaceId 比对做到的 —— 已经挂着同一个 surface 就什么都不做，
   * 否则渲染器会把 EGL 上下文销毁重建一遍（画面会闪一下）。
   */
  private attach_main_preview(): void {
    const surfaceId: string = this.mainSurfaceId;
    if (surfaceId.length === 0) {
      return;
    }
    // 同一个 surface 重复 onLoad 不必重挂；换了 surface（上面的重建场景）
    // 必须重挂，否则渲染器还握着一个已失效的 EGLSurface。
    if (surfaceId === this.attachedSurfaceId) {
      return;
    }
    const result: number = attachPreview(surfaceId);
    if (result === 0) {
      this.attachedSurfaceId = surfaceId;
      this.surfaceAttached = true;
    } else {
      // 挂载失败时清掉记录：下次 onLoad 还有机会重试，不会被 id 比对挡掉。
      this.attachedSurfaceId = '';
      this.hint = `挂载预览失败：${lastError()}`;
    }
  }

  /**
   * 标题区域的窗口拖动。
   * 上游是 WPF 的自绘标题栏（ExtendsContentIntoTitleBar="True" + WindowChrome），
   * 鸿蒙对应 window.startMoving()；由 EntryAbility 关掉系统窗口装饰后生效。
   */
  async start_window_drag(): Promise<void> {
    try {
      const ctx: common.Context = this.getUIContext().getHostContext() as common.Context;
      const win: window.Window = await window.getLastWindow(ctx);
      await win.startMoving();
    } catch (error) {
      const failure = error as BusinessError;
      console.warn('iPhoneMirror start_window_drag failed:', failure.message);
    }
  }

  // ───────────────────────── 派生显示值 ─────────────────────────

  /** CaptureState::Streaming == 4；@State 空值收窄不跨方法调用成立，先取局部变量。 */
  is_streaming(): boolean {
    const status: CaptureStatus | null = this.capture;
    return status !== null && status.state === 4;
  }

  /**
   * 原版 HasCaptureSession（MainViewModel.cs:673 = 会话句柄 != 0）。
   *
   * 本移植用的是单会话 ABI（im_start_capture / im_stop_capture），没有句柄可查，
   * 于是按状态映射：ActivatingUsb(1)/WaitingForDevice(2)/Handshaking(3)/
   * Streaming(4)/Stopping(5) 都算"已有会话"，Idle(0)/Stopped(6)/Error(7) 不算。
   * 这条决定了按钮显示「开始投屏」还是「停止投屏」—— 原版一旦建了会话就显示停止，
   * 不再等画面出来。
   */
  has_capture_session(): boolean {
    const status: CaptureStatus | null = this.capture;
    if (status === null) {
      return false;
    }
    const state: number = status.state;
    return state >= 1 && state <= 5;
  }

  /** 原版 CanStopCurrentCapture：HasSession && !IsStopping ⇒ Stopping(5) 时按钮变灰。 */
  can_stop(): boolean {
    const status: CaptureStatus | null = this.capture;
    if (status === null) {
      return false;
    }
    const state: number = status.state;
    return state >= 1 && state <= 4;
  }

  /**
   * 原版 StartCommand.CanExecute（MainViewModel.cs:1164）：
   *   SelectedDevice is not null && !HasCaptureSession && !IsCapturing &&
   *   !IsMediaCasting && CanQueueSessionLifecycleOperation(SelectedDevice)
   * 后三项（IsCapturing / IsMediaCasting / 会话生命周期串行闸）给的都是"已有会话或
   * 正在忙"的情形，在本移植里已被 has_capture_session()（1..5）覆盖 —— 不另造状态。
   * 于是剩下的一条就是：有选中的设备、且当前没有会话。
   */
  can_start(): boolean {
    return this.selectedUdid.length > 0 && !this.has_capture_session();
  }

  /** 原版 WaitingForDeviceState 的可见条件：SelectedDevice == null */
  has_device(): boolean {
    return this.selectedUdid.length > 0;
  }

  device_count_text(): string {
    return `${this.devices.length} 个来源`;                // Strings: DeviceCountFormat
  }

  capture_status_text(): string {
    const status: CaptureStatus | null = this.capture;
    if (status === null || status.state < 0 || status.state >= STATE_NAMES.length) {
      return STATE_NAMES[0];
    }
    return STATE_NAMES[status.state];
  }

  /**
   * 分辨率：USB 走 CaptureStatus；AirPlay 只认解码器 OnStreamChanged 上报的
   * **实际流尺寸**（first-hand），拿不到就显示「—」。
   *
   * ★ 2026-10-04：原来这里有一层回落 `d.lastStreamWidth : p.lastFrameWidth`
   *   （渲染帧尺寸），已去掉。理由：渲染帧尺寸在 decoded_width_ 为 0 时取的是
   *   `format_.width` —— 那是 **Configure 的配置尺寸**（ProcessMirrorPacket 里
   *   甚至硬编码传的是 1920×1080 提示值），不是码流真实尺寸。回落显示出来的
   *   数字看着有值、实则可能是配置值或窗口/显示器尺寸（曾出现过把 21:9
   *   显示器尺寸 3440×1440 读成"视频分辨率"的情况），会把排查带偏。
   *   宁可显示「—」，也不要给一个不标注来源的数字。
   */
  resolution_value(): string {
    const status: CaptureStatus | null = this.capture;
    if (status !== null && status.width > 0) {
      return `${status.width}×${status.height}`;
    }
    const ap: AirPlayStatus | null = this.airplay;
    if (ap !== null && ap.running !== 0 && ap.clients > 0) {
      const d = ap.decoderDiag;
      if (d.lastStreamWidth > 0 && d.lastStreamHeight > 0) {
        return `${d.lastStreamWidth}×${d.lastStreamHeight}`;
      }
      // 解码器还没上报流尺寸。这是**有信息量的状态**而不是"没数据"：
      // 说明要么码流还没开始解码，要么解码器没走 OnStreamChanged。
      return d.pushedInputs > 0 ? '解码中' : '—';
    }
    return '—';
  }

  fps_value(): string {
    const status: CaptureStatus | null = this.capture;
    if (status !== null && status.state === 4) {
      return `${status.fps.toFixed(1)} fps`;
    }
    // AirPlay：轮询差分实测的解码帧率（见 poll_status 的 airplayFps）。
    if (this.airplayFps > 0) {
      return `${this.airplayFps.toFixed(1)} fps`;
    }
    return '—';
  }

  latency_value(): string {
    const status: CaptureStatus | null = this.capture;
    if (status !== null && status.state === 4) {
      return `${status.latencyMs.toFixed(1)} ms`;
    }
    // AirPlay：C++ 侧实测「收包入队 → 解码出帧」的 EMA 延迟（不含 iPhone
    // 编码与网络前段 —— 那段只有发送端知道，如实按这个口径展示）。
    const ap: AirPlayStatus | null = this.airplay;
    if (ap !== null && ap.videoLatencyMs > 0) {
      return `${ap.videoLatencyMs} ms`;
    }
    return '—';
  }

  /** "48000Hz/2ch/16bit" → "48 kHz · 2 ch"（解析失败返回空串）。 */
  parse_audio_short(format: string): string {
    const match: RegExpMatchArray | null = format.match(/(\d+)Hz\/(\d+)ch/);
    if (match === null) {
      return '';
    }
    const khz: number = Number(match[1]) / 1000;
    const ch: number = Number(match[2]);
    return `${khz.toFixed(khz % 1 === 0 ? 0 : 1)} kHz · ${ch} ch`;
  }

  /**
   * 音频：真值优先 —— 渲染器在播且拿到格式串时显示实测格式；
   * 没在播就如实「—」（此前的"开关开着就恒显 48 kHz·2 ch"是假数据）。
   */
  audio_value(): string {
    const ap: AirPlayStatus | null = this.airplay;
    if (ap !== null && ap.running !== 0 && ap.audioRendererActive === 1
      && ap.audioFormat.length > 0) {
      const short: string = this.parse_audio_short(ap.audioFormat);
      if (short.length > 0) {
        return short;
      }
      return ap.audioFormat;
    }
    return '—';
  }

  target_resolution_text(): string {
    return `渲染上限 ${RESOLUTION_SHORT[this.resolutionPreset]}`;  // Strings: RenderLimitFormat
  }

  target_fps_text(): string {
    return `本地上限 ${FRAME_RATE_LABELS[this.frameRateIndex]} fps`; // Strings: TargetFpsFormat
  }

  /**
   * 收包是否还在走 —— 「已收 N 帧」是**累计值**，停住不动时彻底分不清
   * "iPhone 不发了"与"我们的收包路径死了"。这一格直接回答"距最后一个视频包多久"。
   *
   * 为什么必须单独有它（1.0.52 的教训）：那次 `已收 204 帧`后再无进展、
   * 解码器 0 输出，我第一反应是"参数集/喂帧问题"，翻了三轮才发现根因是
   * **上游 NAL 改写循环死循环**，收包线程整个卡住 —— 而这只要看一眼
   * "多久没收到包了"就能立刻定案。
   *
   *   -1       = 本会话还没收到过视频包（连了但 iPhone 没推，或推了但没到这层）
   *   >3000ms  = 收包停滞：iPhone 停发（锁屏/切走）或我们的收包线程卡死
   */
  airplay_rx_stale_text(ap: AirPlayStatus): string {
    if (ap.videoRxStaleMs < 0) {
      return ' · 尚未收到视频包';
    }
    if (ap.videoRxStaleMs > 3000) {
      return ` · ★收包已停滞 ${(ap.videoRxStaleMs / 1000).toFixed(1)}s（iPhone 停发或收包线程卡死）`;
    }
    return ` · ${ap.videoRxStaleMs}ms 前收包`;
  }

  decode_status_text(): string {
    // AirPlay 路径：用视频帧/解码帧/错误数三个指标判断，USB 路径才看 capture.state。
    const ap: AirPlayStatus | null = this.airplay;
    if (ap !== null && ap.running !== 0 && ap.clients > 0) {
      if (ap.videoDecodeErrors > 0) {
        // Strings: DecoderStatusAirPlayErrorFormat "AirPlay 解码器已失败：OnError×{0}（{1}）"
        return `AirPlay 解码器已失败：OnError×${ap.videoDecodeErrors}（${ap.videoDecoderLastError}）`;
      }
      if (ap.videoFrames > 0 && ap.decodedFrames === 0) {
        const d = ap.decoderDiag;
        // 三种情况分别给一行诊断：根因不同。
        let why = '';
        if (d.pushedInputs === 0) {
          why = `配置后未收到 input_buffer（pushed=0）`;
        } else if (d.outputCallbacks === 0) {
          // 推了帧但零输出回调：策略链会自动换档（硬件+编码尺寸 → 硬件+显示尺寸
          // → 软件解码器）。上一轮四档全试完仍 callback=0，说明根因不在"宽高口径"
          // 而在四档共用的**喂帧方式**，所以这里把喂帧方式的每个可疑点单独亮出来：
          // push 是否真成功、有没有关键帧、参数集有没有 in-band、缓冲够不够大。
          const cfgSrc: string = d.spsParseFailures > 0 ? '回退提示值!' : 'SPS真值';
          const spsText: string = d.lastSpsEncWidth > 0
            ? `SPS=${d.lastSpsEncWidth}x${d.lastSpsEncHeight}→显${d.lastSpsDispWidth}x${d.lastSpsDispHeight}`
            : 'SPS未解析成功';
          const head: string = '首帧头=' +
            d.firstInputB03.toString(16).padStart(8, '0') + ' ' +
            d.firstInputB47.toString(16).padStart(8, '0');
          // 参数集本体，与首帧头分开看：首帧头是"参数集 + 首帧"拼完的样子，
          // 集头才是 Configure 真正用的那一段（判断 SPS 在不在就看它）。
          const cfgHead: string = '集头=' +
            d.configHeadB03.toString(16).padStart(8, '0') + ' ' +
            d.configHeadB47.toString(16).padStart(8, '0') +
            (d.configures > 1 ? `(换了${d.configures}次)` : '');
          const feed: string =
            `真推${d.pushedInputs}(IDR${d.idrFrames}/标记${d.syncFlagged}/参数集${d.inbandParamSets})` +
            (d.pushFailures > 0 ? `、推送失败${d.pushFailures}(err${d.lastPushError})` : '') +
            (d.setattrFailures > 0 ? `、属性失败${d.setattrFailures}` : '') +
            `、末帧${d.lastInputSize}B/容量${d.inputCapacity}B`;
          why = `已推 ${d.pushedInputs} 帧、callback=0、cfg=${d.lastConfigWidth}x${d.lastConfigHeight}(${cfgSrc})、${spsText}、${feed}、${head}、${cfgHead}、` +
            `解码器=${d.decoderName || '未创建'}·档${d.strategy}/4·切换${d.strategySwitches}` +
            (d.inputTooLarge > 0 ? `、过大丢弃=${d.inputTooLarge}` : '');
        } else if (d.outputWithPixels === 0) {
          const need = Math.ceil(d.lastOutputWidth * d.lastOutputHeight * 3 / 2);
          why = `callback=${d.outputCallbacks}、pushed=${d.pushedInputs}、` +
            `${d.outputNoPixels - d.outputTooSmall} 个空像素 / ${d.outputTooSmall} 个 size 不够 ` +
            `(w=${d.lastOutputWidth} h=${d.lastOutputHeight} size=${d.lastAttrSize} need≥${need})` +
            (d.inputTooLarge > 0 ? `、过大丢弃=${d.inputTooLarge}` : '');
        }
        return `AirPlay 解码器未产出像素：${why}`;
      }
      if (ap.decodedFrames > 0) {
        const d = ap.decoderDiag;
        // 解码已通 → 断点只可能在「解码帧 → 上屏」这一段。渲染器那条链上的
        // 失败原本全是静默的，这里把每个分支都亮出来，一眼分辨是
        // "surface 没挂上" 还是 "挂了但每帧被丢" 还是 "画了但 EGL 层没生效"。
        const p = ap.previewDiag;
        const render: string = `渲染=${p.attached === 1 ? '已挂载' : '未挂载'}` +
          `·present${p.presentCalls}·draw${p.drawCalls}/成${p.drawOk}` +
          (p.dropNoDisplay > 0 ? `、无surface丢${p.dropNoDisplay}` : '') +
          (p.dropNotNv12 > 0 ? `、非NV12丢${p.dropNotNv12}` : '') +
          (p.dropEmpty > 0 ? `、空数据丢${p.dropEmpty}` : '') +
          (p.dropZeroDim > 0 ? `、零尺寸丢${p.dropZeroDim}` : '') +
          (p.dropTooSmall > 0 ? `、字节不足丢${p.dropTooSmall}` : '') +
          (p.makeCurrentFailures > 0
            ? `、上下文未就绪${p.makeCurrentFailures}` : '') +
          (p.swapFailures > 0
            ? `、swap失败${p.swapFailures}(egl0x${p.lastEglError.toString(16)})` : '') +
          (p.lastGlError !== 0 ? `、glErr${p.lastGlError}` : '') +
          `、surface=${p.surfaceWidth}x${p.surfaceHeight}` +
          `、末帧${p.lastFrameWidth}x${p.lastFrameHeight}·${p.lastFrameBytes}B·fmt${p.lastFrameFormat}` +
          `、attach${p.attachCalls}/败${p.attachFailures}` +
          (p.reattachAttempts > 0 ? `·自愈重挂${p.reattachAttempts}` : '') +
          // 挂载失败原因必须显示：它原本只写进预览区的状态遮罩，而 AirPlay 镜像时
          // 遮罩是让开的 —— 等于失败原因根本看不到。
          (p.attachFailures > 0 && p.lastError.length > 0
            ? `、挂载失败=${p.lastError.substring(0, 80)}` : '');
        // 解码器身份（hw/sw）与重同步账本必须摊在第一行：帧率低的第一分叉是
        // "软解扛不动这个分辨率"还是"硬解但收包/丢帧策略问题"。
        //
        // ★ 2026-10-04：分辨率这里必须**同时摊出三个口径**，且都标注清楚来源。
        //   只有 lastStreamWidth（OnStreamChanged 上报）才是码流真实尺寸；
        //   lastOutputWidth 是解码输出缓冲尺寸、lastConfigWidth 是 Configure
        //   用的配置尺寸（ProcessMirrorPacket 传的是 1920×1080 提示值）。
        //   以前状态栏那一格在 lastStreamWidth=0 时回落到渲染帧尺寸，于是出现过
        //   "3440×1440"这种显示器尺寸被当成视频分辨率读数、据此误判"软解扛不住"。
        const dims: string = `流尺寸=${d.lastStreamWidth}x${d.lastStreamHeight}` +
          `、解码输出=${d.lastOutputWidth}x${d.lastOutputHeight}` +
          `、配置=${d.lastConfigWidth}x${d.lastConfigHeight}` +
          (d.lastStreamWidth > 0 ? '' : '★流尺寸未上报(别用后两个当分辨率)');
        const decode: string = `解码器=${d.decoderName.length > 0 ? d.decoderName : '未创建'}` +
          `·档${d.strategy}/4换${d.strategySwitches}` +
          `、${dims}` +
          `、队列${ap.videoQueueDepth}` +
          (ap.videoResyncs > 0
            ? `、重同步${ap.videoResyncs}次/跳${ap.videoResyncFrames}帧` +
              (ap.videoResyncTimeouts > 0 ? `·超时${ap.videoResyncTimeouts}` : '')
            : '') +
          // ★ 解码器内部堆积（1.0.49）。videoQueueDepth 量的是"收包→解码线程"，
          //   量不到"解码线程→解码器"那一段——延迟与帧率的真根因在那儿。
          //   溢出>0 或解码耗时 > 一帧预算(16667µs) 都是"解码跟不上实时"的直证。
          (ap.videoPendingOverflow > 0
            ? `、★解码器内堆积${ap.videoPendingOverflow}次(峰值${ap.videoFillPeak})` : '') +
          (ap.videoDecoderIdrRequests > 0
            ? `、★内部溢出重同步${ap.videoDecoderIdrRequests}次` : '') +
          // ★ 1.0.55 起这个读数的口径变了：以前是"每帧阻塞等输出等了多久"
          //   （含等待上限，不是解码耗时）；改成非阻塞取帧后量的是"两次真出
          //   像素之间的间隔"= 解码器多久吐一帧。文案必须跟着改，否则拿到的
          //   又是一个"看着有值、含义不对"的读数。
          (ap.videoDecodeUs > 0
            ? `、出帧间隔${(ap.videoDecodeUs / 1000).toFixed(0)}ms` +
              (ap.videoDecodeUs > 16667 ? '(慢于一帧)' : '')
            : '') +
          // ★ 延迟归因账（1.0.56）。非阻塞取帧后出帧属于上一个包，延迟必须
          //   按帧自己的输入包算；对不上的帧直接不计入 EMA，在这里留个数 ——
          //   否则"延迟显示「—」"分不清是"还没量到"还是"永远量不到"。
          (ap.videoLatencyUnmatched > 0
            ? `、延迟未归因${ap.videoLatencyUnmatched}` +
              (ap.videoLatencyMs > 0 ? '' : '(★延迟读数不可信)')
            : '') +
          // ★ 绿屏诊断（1.0.57）。NV12 的 UV 全零 ⇒ 渲染出来是纯绿，这类废帧
          //   已丢弃不上屏（也不算"出过像素"），所以"屏幕没画面"要读它：>0 说明
          //   解码器吐的帧本身就是废的，不是渲染侧的问题。
          (d.chromaEmptyFrames > 0 ? `、★绿屏废帧${d.chromaEmptyFrames}` : '') +
          (d.lowLatencyDisabled > 0 ? `、已自动关低延迟${d.lowLatencyDisabled}次` : '') +
          // ★ 冻结读数（1.0.50）。冻结期间队列被清空 ⇒ 延迟读数反而很低，
          //   不显式说出来就会被读成"延迟已经好了"，而实际画面是定住的。
          (ap.videoFrozenMs > 0 ? `、★画面冻结中${ap.videoFrozenMs}ms(在等关键帧)` : '') +
          (ap.videoSingleDrops > 0 ? `、单次丢帧${ap.videoSingleDrops}` : '');
        // 判读指引：软解出帧间隔超一帧预算时直接给结论，省得用户自己算。
        const verdict: string = (ap.videoDecodeUs > 16667 &&
          d.decoderName.indexOf('(sw)') >= 0)
          ? '；★软解扛不住这个分辨率（本机无硬解可用或硬解档已试尽）'
          : '';
        return `AirPlay 解码器已生效：已解码 ${ap.decodedFrames} 帧；${decode}${verdict}；${render}`;
      }
      return 'AirPlay 解码器已就绪，等待首帧';
    }
    const status: CaptureStatus | null = this.capture;
    if (status !== null && status.state === 4) {
      // Strings: DecoderStatusAppliedFormat "解码器已生效：策略 {0}；实际 {1}。"
      return `解码器已生效：策略 ${DECODER_PREFERENCE_LABELS[this.decoderPreference]}；实际 硬件加速。`;
    }
    return '解码器状态：正在读取实际解码链路...';          // Strings: DecoderStatusDetecting
  }

  /**
   * 无线 AirPlay 卡片的实况行。
   *
   * 原来是写死的「当前声明：xxx」——那句话只反映下拉框选了什么，接收端根本
   * 没被启动过，属于典型的假成功。现在如实反映接收端 + mDNS 的真实状态，
   * 包括"广播失败"和"已连接并实时解码镜像"。
   */
  wireless_applied_text(): string {
    // Strings: WirelessReceiverReading
    const ap: AirPlayStatus | null = this.airplay;
    if (ap === null) {
      return '接收端状态：正在读取…';
    }
    if (ap.running === 0) {
      // Strings: WirelessReceiverIdleFormat
      return `接收端未启动（声明 ${WIRELESS_PROFILE_LABELS[this.wirelessProfile]}）`;
    }
    // 关键分支：原生响应器没起来 → iPhone 必然搜不到。把原因摆出来，别再谎称"已在广播"。
    if (ap.mdnsActive === 0) {
      const reason: string = ap.mdnsError.length > 0
        ? ap.mdnsError
        : '原生 mDNS 响应器启动失败（无更多错误信息）';
      return `mDNS 广播未生效：${reason}；已退回 @ohos.net.mdns，但该设备不把记录发到网上，iPhone 搜不到属正常`;
    }
    // 响应器活着、但运行中判到异常（目前只有"宣告风暴熔断"一种）：也必须说出来，
    // 否则界面会继续显示"已在广播"，而实际上已经停止发包了。
    if (ap.mdnsError.length > 0) {
      return `广播异常：${ap.mdnsError}`;                    // Strings: WirelessMdnsStormThrottled
    }
    // 后台保活没拿到：App 一切到后台进程就被冻结，响应器随之停摆。
    // 这是"App 里看一切正常、一拿 iPhone 就搜不到"的头号嫌疑，必须优先报出来。
    if (this.keepAliveError.length > 0) {
      return `后台保活未生效：${this.keepAliveError} → App 切到后台后 iPhone 会搜不到，请保持本窗口在前台`;
    }
    if (ap.mdnsFailed > 0) {
      const reason: string = ap.lastError.length > 0 ? ap.lastError : '未知原因';
      return `mDNS 广播失败：${reason}`;                    // Strings: WirelessMdnsFailedFormat
    }
    if (ap.mdnsPending > 0 || ap.mdnsRegistered === 0) {
      return '接收端已启动，正在向局域网广播…';              // Strings: WirelessMdnsPublishing
    }
    // 广播着却没有本机 IPv4 → A 记录写不出来，iPhone 拿不到地址。
    // 这种"看着在广播、其实解析不到"的状态必须单独说，不能混进正常文案里。
    if (ap.mdnsLocalIp.length === 0) {
      return '已在广播服务名，但没解析到本机 IPv4（A 记录为空）→ iPhone 搜到也连不上，请先确认本机 Wi-Fi 已连上';
    }
    if (ap.clients > 0) {
      // 视频解码已接入（Task 26）：收到帧即送 OH_VideoDecoder 解码并 present 到预览窗口。
      // 现在叠加两路指标区分"连上但黑屏"的几种病：
      //   videoFrames > 0 但 decodedFrames == 0      → 解码器没产出像素（超时/错误/SPS 没配上）
      //   decodedFrames 稳步上涨                    → 解码链路 OK，画面应出
      //   videoDecodeErrors > 0                     → OH_VideoDecoder 主动 OnError，必须报原因
      const decodeErr: string = ap.videoDecodeErrors > 0
        ? ` · 解码器 OnError×${ap.videoDecodeErrors}（${ap.videoDecoderLastError}）`
        : '';
      // 「解码跟不上收包」的直接证据。区别于 OnError：解码器没坏，只是不够快 ——
      // 卡顿到底是网络、解码还是渲染，靠这一个计数就能先分掉一类。
      const dropNote: string = ap.videoQueueDropped > 0
        ? ` · 解码滞后丢弃 ${ap.videoQueueDropped} 包`
        : '';
      const audioNote: string = ` · ${this.airplay_audio_text(ap)}`;
      if (ap.videoFrames > 0 && ap.decodedFrames === 0) {
        // 解码器没产出，但 raop 视频帧在来 → 链路某段不通，必须讲清楚。
        // ★ 把断点判据直接摊在状态行上：一张截图就能定位，不用再翻镜像面板。
        //   三段式判读：
        //   参数集=0                     → 解码器从未配置（SPS/PPS 没来，
        //                                  数据帧在 ProcessMirrorPacket 里被静默丢）
        //   参数集>0 · 真推=0            → configure 之后一个 input_buffer 都没拿到
        //   真推>0 · 回调=0 / 有像素=0   → 解码器收了帧但不吐（档位/尺寸/喂帧方式）
        const d = ap.decoderDiag;
        // ★ 参数集本体：00000001 67… = SPS 开头（正常）；…28… = 只有 PPS，SPS 缺席。
        //   这一格是 1.0.45 新增的最关键证据 —— 上一轮黑屏的根就在这里。
        const cfgHead: string =
          `集头=` + d.configHeadB03.toString(16).padStart(8, '0') +
          ' ' + d.configHeadB47.toString(16).padStart(8, '0');
        // NAL 账本：slice 在涨而 IDR 恒 0 = 一直等不到关键帧；
        //           slice/IDR 都是 0 且 none 在涨 = 帧里压根没有 H.264 结构。
        const nalNote: string =
          `slice${ap.videoNalSlice}/IDR${ap.videoNalIdr}/SPS${ap.videoNalSps}/PPS${ap.videoNalPps}/无NAL${ap.videoNalNone}`;
        const paramNote: string =
          `补全参数集帧内${ap.videoParamFromFrames}/包内${ap.videoParamFromConfig}` +
          `·重配${ap.videoParamReconfigures}` +
          (ap.videoWaitingParam > 0 ? `·缺集待解${ap.videoWaitingParam}` : '') +
          // ★ 配置包只有 PPS、没有 SPS = **上游给的参数集本身残缺**，不是我们的
          //   解码器/丢帧策略问题。此前这条只表现为"缺集待解 N"，看不出区别。
          (ap.videoParamPpsOnly > 0
            ? `、★配置包只有PPS没有SPS(${ap.videoParamPpsOnly}次·上游参数集残缺)` : '');
        const readout: string =
          `参数集${ap.videoConfigPackets}` +
          ` · 真推${d.pushedInputs}/回调${d.outputCallbacks}/有像素${d.outputWithPixels}` +
          ` · 太小${d.outputTooSmall} · SPS失败${d.spsParseFailures}` +
          ` · cfg=${d.lastConfigWidth}x${d.lastConfigHeight}` +
          ` · 档${d.strategy}/4换${d.strategySwitches} · 丢${ap.videoQueueDropped}` +
          ` · ${nalNote} · ${paramNote} · ${cfgHead}`;
        // ★ 收包停滞读数必须在这里出现：这一支正是"帧数停住不动"的场景，
        //   没有它就只能猜"iPhone 停发"还是"我们收包线程卡死"。
        const rxNote: string = this.airplay_rx_stale_text(ap);
        return `iPhone 已连接 · 已收 ${ap.videoFrames} 帧但解码器 0 帧输出（解码链未通）` +
          ` · ${readout}${decodeErr}${rxNote}${audioNote}`;
      }
      return `iPhone 已连接 · 实时镜像中（已收 ${ap.videoFrames} 帧 / 解码 ${ap.decodedFrames} 帧）`
        + `${dropNote}${decodeErr}${this.airplay_rx_stale_text(ap)}${audioNote}`;
    }
    // 已确认广播中：把应答里用的本机 IP 与已应答查询数摊给用户，便于排查"搜到连不上"——
    // 之前那次就是 A 记录里的 IP 写死成了 iPhone 自己，导致它点到自己连不上。
    const ipNote: string = ap.mdnsLocalIp.length > 0 ? ` · 本机 ${ap.mdnsLocalIp}` : '';
    const answeredNote: string = ` · 已应答 ${ap.mdnsAnswered} 次查询`;
    return `已在局域网广播（RAOP ${ap.raopPort} / AirPlay ${ap.airplayPort}）${ipNote}${answeredNote}，等待 iPhone 连接`;
  }

  airplay_running(): boolean {
    const ap: AirPlayStatus | null = this.airplay;
    return ap !== null && ap.running !== 0;
  }

  /**
   * AirPlay 音频的一句话判据 ——「有没有声音」必须能自证，不能靠用户听。
   *
   * ★ 判据必须成对读（audioPackets 与 audioFramesPlayed 一起看），只有这样才分得开：
   *     packets 涨 / played 不涨 → 数据进来了但没人取（渲染链不通）
   *     packets 也不涨           → raop 侧就没有音频数据（iPhone 没送或没协商上）
   *     audioOpenFailures > 0    → 音频流压根没建起来，audioError 里有确切原因
   *   单看任一个都会把"没数据"和"没出端点"混成同一句话，这正是本工程反复踩的坑。
   */
  airplay_audio_text(ap: AirPlayStatus): string {
    if (ap.audioError.length > 0) {
      return `音频未出声：${ap.audioError}`;
    }
    if (ap.audioPackets === 0) {
      return '音频未收到数据';
    }
    if (ap.audioFramesPlayed === 0) {
      return `音频已收 ${ap.audioPackets} 包但0帧播放（渲染链未取到数据）`;
    }
    const format: string = ap.audioFormat.length > 0 ? ` ${ap.audioFormat}` : '';
    const underrun: string = ap.audioUnderruns > 0 ? ` · 欠载 ${ap.audioUnderruns}` : '';
    // 增益必须亮出来：RAOP 音量单位是 dB（-144..0），0.0 增益 = iPhone 侧
    // 拉到 -30dB 以下/静音 —— 这与"数据在播但听不见"是两回事。
    const gainPct: number = Math.round(ap.audioGain * 100);
    const gain: string = gainPct <= 0
      ? ' · 音量 0%（iPhone 侧静音或音量极低）'
      : ` · 音量 ${gainPct}%`;
    return `音频播放中${format}（已播 ${ap.audioFramesPlayed} 帧）${gain}${underrun}`;
  }

  /**
   * 是否正在经 AirPlay 出画面（有 iPhone 已连上并推流）。
   *
   * ★ 为什么必须单独有这个判断：预览区的遮罩原本只看 `is_streaming()`，而它读的是
   *   **USB 采集状态机**（`CaptureStatus.state === 4`）。AirPlay 走的是另一条路 ——
   *   vendored 协议库的 raop 回调 → Annex-B 解码 → `OhosPreviewRenderer.present()`，
   *   全程不碰 CaptureState。于是 iPhone 镜像连上、帧也解出来了，画面却被
   *   「等待设备」那层遮罩盖住（此时 `has_device()` 也是 false，因为没选 USB 设备），
   *   表现为"连上了但一片黑"。这里把 `clients > 0` 认定为"正在出画面"，让遮罩让开。
   */
  airplay_mirroring(): boolean {
    const ap: AirPlayStatus | null = this.airplay;
    return ap !== null && ap.running !== 0 && ap.clients > 0;
  }

  /**
   * 接收端在跑、但还没在网上广播成功时，把原生层的最后一条消息摊给用户看。
   *
   * 为什么需要：状态行只能表达"待广播 / 已广播 / 广播失败"三种结论，而 iPhone
   * 搜不到设备时最需要的是**过程**——是 mDNS 被系统拒了，还是协议栈自己没起来。
   * 失败原因已经写在状态行里，这里不重复；其余情况给最后一条协议库日志。
   */
  airplay_verbose(): string {
    const ap: AirPlayStatus | null = this.airplay;
    if (ap === null || ap.running === 0) {
      return '';
    }
    if (ap.mdnsFailed > 0) {
      return '';                                  // 状态行里已经写了失败原因
    }
    const detail: string = ap.lastLog.length > 0 ? ap.lastLog : ap.lastError;
    if (detail.length === 0) {
      return '';
    }
    // 协议库的日志可能带长路径，截断，避免把卡片撑开。
    return detail.length > 140
      ? `原生：${detail.substring(0, 140)}…`
      : `原生：${detail}`;
  }

  /**
   * 发现层诊断行 —— 专治"已应答 N 次、iPhone 却搜不到"。
   *
   * ★ 为什么必须把它摊到界面上：这条链有两处让外部观测失效的设计 ——
   *   ① 本机开着 IP_MULTICAST_LOOP=0（防自反馈环的必需措施），我们自己发的组播
   *      包**不回环**，本机任何抓包工具都看不到；
   *   ② 来源为本机的包会被主动丢弃，于是 `tools/airplay_responder_probe.py
   *      --unicast` 这类本机探针敲出来恒为「0 应答」，**看不出响应器是死是活**。
   *   两条加在一起 ⇒ 排障只剩"在进程里记账、再摊到界面"这一条路。
   *
   * 判读（逐字段）：
   *   · 宣告「成功 0」      → 从来没宣告出去过，iPhone 无从发现；
   *   · 宣告「失败 >0」     → sendto 就失败，网卡/路由问题；
   *   · 出向组播网卡不是本机 Wi-Fi 地址 → 宣告从虚拟网卡出去了（空口收不到），
   *                          而单播应答照常，症状正是"已应答却搜不到"；
   *   · 最近应答来源若是 iPhone 的地址 → 它问过、我们也答了，问题在应答**内容**。
   *
   * ★ 后三行（已宣告服务 / 查询分类 / 最近一条查询）专治"两个病症状一模一样"：
   *   iPhone 的「屏幕镜像」列表只认 `_airplay._tcp` 的 PTR，但它顺手也会问
   *   `_raop._tcp`（找音频目标），这两条我们**都答得上**，`mdnsAnswered` 照样涨。
   *   所以「已应答 N 次却搜不到」其实是两种病：
   *     a) 问了 _airplay，我们手里却没有这个服务  → 注册环节掉的；
   *     b) 只问了 _raop，_airplay 的查询压根没来  → 宣告没出去/网络环节掉的。
   *   判读：
   *     · 查询分类里 `_airplay 0`            → 走 b)：iPhone 从没看见我们的 _airplay；
   *     · 有 `_airplay N` 但没有「答」        → 走 a)：我们手里没注册上这个服务；
   *     · 「已宣告服务」里缺 `_airplay._tcp`  → 走 a)，且这一条最直接；
   *     · 两者都正常却仍搜不到                → 只剩"应答内容"（A 记录/端口/TXT/model）。
   */
  airplay_diagnostics(): string {
    const ap: AirPlayStatus | null = this.airplay;
    if (ap === null || ap.running === 0) {
      return '';
    }
    const iface: string = ap.mdnsOutIface.length > 0 ? ap.mdnsOutIface : '未设置';
    const from: string = ap.mdnsLastFrom.length > 0
      ? `${ap.mdnsLastFrom}（回的 A 记录=${ap.mdnsLastAnswerIp.length > 0 ? ap.mdnsLastAnswerIp : '空'}）`
      : '还没有人问过';
    const dropped: string = ap.mdnsDroppedSelf > 0
      ? ` · 已丢弃本机来源包 ${ap.mdnsDroppedSelf} 个（本机探针会因此得到 0 应答，属正常）`
      : '';
    // 音频自己的账本：收包数只说明数据到手，播放帧数才是"真出声"的证据。
    // 两个数摊在一起，才能一眼看出卡在哪一段（喂不进去 / 建不了流 / 没人取）。
    const audioDiag: string = `\n音频：收包 ${ap.audioPackets} · 播放 ${ap.audioFramesPlayed} 帧`
      + ` · 喂入 ${ap.audioBytesFed} 字节`
      + ` · 格式 ${ap.audioFormat.length > 0 ? ap.audioFormat : '未确定'}`
      + (ap.audioRendererActive !== 0 ? ' · 流已建立' : ' · 流未建立')
      + (ap.audioUnderruns > 0 ? ` · 欠载 ${ap.audioUnderruns}` : '')
      + (ap.audioDroppedFrames > 0 ? ` · 丢旧帧 ${ap.audioDroppedFrames}` : '')
      + (ap.audioDecodeErrors > 0 ? ` · AAC解码错误 ${ap.audioDecodeErrors}（这些包补静音）` : '')
      + (ap.audioFlushes > 0 ? ` · flush ${ap.audioFlushes}` : '')
      + (ap.audioOpenFailures > 0 ? ` · 建流失败 ${ap.audioOpenFailures}` : '')
      + (ap.audioError.length > 0 ? ` · 错误 ${ap.audioError}` : '');
    return `发现层诊断：宣告 成功 ${ap.mdnsAnnounceSent} / 失败 ${ap.mdnsAnnounceFailed}`
      + ` · 出向组播网卡 ${iface} · 最近被应答的查询来自 ${from}${dropped}`
      + `\n已宣告服务：${ap.mdnsServices}`
      + `\n查询分类：${ap.mdnsQueryCounts}`
      + `\n最近一条查询：${ap.mdnsLastQuery}`
      + audioDiag;
  }

  /**
   * 「应用 / 停止」按钮：真开关 AirPlay 接收端。
   * 改名或改分辨率时必须先停再起，否则新名字不会重新广播（mDNS 记录是旧的）。
   */
  apply_wireless(): void {
    if (this.airplay_running()) {
      airplayStop();
      airPlayMdns.clear();
      this.stop_keep_alive();
      this.airplay = airplayGetStatus();
      this.settingsStatus = 'AirPlay 接收端已停止';         // Strings: WirelessReceiverStopped
      return;
    }

    const code: number = airplayStart(this.wirelessName, '');
    if (code !== 0) {
      const failed: AirPlayStatus = airplayGetStatus();
      this.settingsStatus = `AirPlay 接收端启动失败：${failed.lastError}`;
      return;
    }
    // 投屏期间必须保活：没有长时任务，App 一进后台进程就被系统冻结，
    // mDNS 响应器线程随之停摆 —— 表现为"App 里看一切正常、一拿 iPhone 就搜不到"。
    this.start_keep_alive();
    // 立刻 pump 一轮：让"正在广播…"马上可见，而不是等下一个 500ms。
    // 同样吞掉异常（publish 内部已逐条回报失败），别让 mDNS 把启动流程带崩。
    try {
      airPlayMdns.pump();
    } catch (error) {
      const failure = error as BusinessError;
      console.warn('iPhoneMirror mDNS pump failed:', failure.message);
    }
    this.airplay = airplayGetStatus();
    this.settingsStatus = 'AirPlay 接收端已启动，正在向局域网广播…';
  }

  /**
   * 申请后台长时任务（DATA_TRANSFER）。
   *
   * 失败不阻断投屏，但**必须把原因显示出来**：保活静默失败的话，"App 一进后台
   * 进程被冻结、iPhone 搜不到"会变成一个永远查不出来的故障 —— 前台一切正常，
   * 切走就哑，而 answered 计数还挂着历史值。
   */
  private start_keep_alive(): void {
    if (this.appContext === null) {
      this.keepAliveError = '拿不到 UIAbilityContext';
      return;
    }
    const ctx: common.UIAbilityContext = this.appContext as common.UIAbilityContext;
    BackgroundKeepAlive.shared().start(ctx).then((ok: boolean) => {
      this.keepAliveError = ok ? '' : BackgroundKeepAlive.shared().errorText();
    });
  }

  private stop_keep_alive(): void {
    this.keepAliveError = '';
    if (this.appContext === null) return;
    const ctx: common.UIAbilityContext = this.appContext as common.UIAbilityContext;
    BackgroundKeepAlive.shared().stop(ctx);
  }

  version_text(): string {
    return `iPhoneMirror 鸿蒙版 · 核心 ABI v${apiVersion()}`;
  }

  /**
   * 原版按钮 IsEnabled="{Binding CanUseVisualPreviewTools}" 的等价判断。
   *
   * 上游定义（MainViewModel.cs:683-685）：
   *   (HasCaptureSession || IsMediaCasting) && !IsAudioOnlyAirPlay && !IsVideoProtected
   *
   * ★ 2026-09-20 纠错：这里原先只写 `is_streaming()`，口径**窄了两圈**，把两条路
   *   都挡在门外：
   *     · USB 侧：上游要的是 HasCaptureSession（**建了会话**就算），不必等到出画面；
   *       state 1/2/3（激活/等待设备/握手）期间画面还没出来，按钮却是该可用的。
   *     · AirPlay 侧：镜像**完全不碰** CaptureState（见 airplay_mirroring 的注释），
   *       iPhone 明明连上并在出画面，这个按钮却恒灰 —— 点击只回一句
   *       「该操作需先开始投屏」，表现就是"独立窗口根本不能用"。
   *   本移植没有媒体投放（IsMediaCasting）与纯音频/受保护内容这三条分支，
   *   所以剩下两项：有采集会话 **或** 正在经 AirPlay 出画面。
   */
  can_use_visual_tools(): boolean {
    return this.has_capture_session() || this.airplay_mirroring();
  }

  // ═══════════════════════════ 左侧导航（NavigationView） ═══════════════════════════

  /**
   * 原版 ApplyWorkspacePanelState() 的三行：
   *   MirroringPanelToggle.IsActive = showMirroring;
   *   DevicePanelToggle.IsActive    = showDevices;
   *   SettingsPanelToggle.IsActive  = showSettings;
   * 其余导航项（设备绑定器 / 输出 / 驱动 / 关于）**从不**被置为激活。
   */
  private is_nav_active(key: string): boolean {
    if (key === 'mirroring') return this.showMirroringPanel;
    if (key === 'devices') return this.showDevicePanel;
    if (key === 'settings') return this.showControlPanel;
    return false;
  }

  /**
   * 原版 NavigationViewItem —— 逐条照抄 ShellNavigationItem 的 ControlTemplate
   * （MainWindow.xaml:132–244）：
   *
   *   NavigationItemRoot   Grid  Height = MinHeight = 44
   *   InteractionBackground Border Margin="4,0" CornerRadius=7     ← 左右各内缩 4
   *   ActiveIndicator      Border Width=3 Height=18 CornerRadius=2
   *                               Margin="4,0,0,0" 左对齐 垂直居中，激活时 Opacity=1
   *   NavigationIcon       ContentPresenter 在 ColumnDefinition Width="48" 内居中
   *   PaneItemText         Margin="8,0,12,0"  FontSize=13
   *
   * 三者是**同一个 Grid 单元里的叠加层**：ActiveIndicator 不占位、不推挤图标。
   * 所以这里用 Stack 把「背景层 / 强调条 / 内容层」叠起来，而不是串成 Row。
   *
   * 激活态配色也照触发器来（原版 MultiTrigger）：
   *   IsActive 且 pane 展开 → InteractionBackground = ControlFillBrush
   *   IsActive 且 pane 收起 → InteractionBackground = Transparent（只剩强调条）
   *   非激活               → Transparent（hover 时由 hoverEffect 接管）
   * 原版此处另有「激活时文字 SemiBold + AccentBrush 前景」，一并还原。
   */
  @Builder
  nav_item(entry: NavEntry) {
    Stack({ alignContent: Alignment.Center }) {
      // ① 背景层：原版 InteractionBackground，左右内缩 4、圆角 7。
      Row()
        .width(this.navRailWidth - NAV_ITEM_BG_INSET * 2)
        .height('100%')
        .borderRadius(7)
        .backgroundColor(this.nav_item_background(entry.key))

      // ② 强调条：原版 ActiveIndicator（3×18 圆角 2、左 4、垂直居中）。
      Row()
        .width(NAV_ACTIVE_BAR_WIDTH)
        .height(NAV_ACTIVE_BAR_HEIGHT)
        .borderRadius(2)
        .backgroundColor(this.themePalette().ACCENT)
        .opacity(this.is_nav_active(entry.key) ? 1 : 0)
        .position({ x: NAV_ITEM_BG_INSET, y: (NAV_ITEM_HEIGHT - NAV_ACTIVE_BAR_HEIGHT) / 2 })

      // ③ 内容层：图标列固定 48 且图标居中，文字 Margin "8,0,12,0"。
      Row() {
        Stack({ alignContent: Alignment.Center }) {
          FluentSymbol({
            iconName: entry.iconName,
            iconSize: entry.iconSize,
            iconColor: this.is_nav_active(entry.key)
              ? this.themePalette().ACCENT : this.themePalette().MUTED_TEXT,
          })
        }
        .width(NAV_ICON_COLUMN)
        .height('100%')

        if (this.navExpanded) {
          Text(entry.label)
            .fontSize(13)
            .fontWeight(this.is_nav_active(entry.key) ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.is_nav_active(entry.key)
              ? this.themePalette().ACCENT : this.themePalette().MUTED_TEXT)
            .margin({ left: 8, right: 12 })
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height(NAV_ITEM_HEIGHT)
    .margin({ top: 2, bottom: 2 })              // 原版 ShellNavigationItem Margin="0,2"
    .hoverEffect(HoverEffect.Highlight)
    .onHover((isHover: boolean): void => {
      // 原版每个 ui:NavigationViewItem 都设了 ToolTip（NavXxxDescription），
      // hover 由 WPF 内建弹出；这里按同样的时序驱动 nav_tooltip。
      if (isHover) {
        this.nav_tip_enter(entry.key);
      } else {
        this.nav_tip_leave(entry.key);
      }
    })
    .bindPopup(this.navTipKey === entry.key, this.nav_popup(entry))
    .onClick((): void => {
      this.on_nav(entry.key);
    })
  }

  /** 原版 InteractionBackground 的四种取值（见 nav_item 注释里的触发器表）。 */
  private nav_item_background(key: string): ResourceColor {
    if (!this.is_nav_active(key)) {
      return Color.Transparent;
    }
    return this.navExpanded ? this.themePalette().CONTROL_FILL : Color.Transparent;
  }

  // ───────────── 导航项名称气泡（原版 ToolTip；WPF 内建行为，非工程自写） ─────────────

  /**
   * hover 进入某一项：按 WPF ToolTipService 的默认时序延时弹出。
   *
   * 若气泡刚在别处消失不到 100ms（BetweenShowDelay），则立即弹出 —— 这正是原版
   * 「鼠标沿图标条划过时气泡紧跟着换」的观感来源；首次进入则要等满 1 秒。
   */
  private nav_tip_enter(key: string): void {
    if (this.navTipTimer !== -1) {
      clearTimeout(this.navTipTimer);
      this.navTipTimer = -1;
    }
    if (this.navTipKey === key) {
      return;
    }
    const withinBetween: boolean = this.navTipLastHideMs > 0 &&
      (Date.now() - this.navTipLastHideMs) < NAV_TOOLTIP_BETWEEN_DELAY_MS;
    if (withinBetween) {
      this.navTipKey = key;
      return;
    }
    this.navTipTimer = setTimeout((): void => {
      this.navTipTimer = -1;
      this.navTipKey = key;
    }, NAV_TOOLTIP_INITIAL_DELAY_MS);
  }

  /**
   * hover 移出：气泡立即消失（原版也是移开即关），并记下时刻供 BetweenShowDelay 判定。
   * 若气泡压根没弹出来（停留不足 1 秒就走了），不记时刻 —— 下一项仍需重新等满 1 秒。
   */
  private nav_tip_leave(key: string): void {
    if (this.navTipTimer !== -1) {
      clearTimeout(this.navTipTimer);
      this.navTipTimer = -1;
    }
    if (this.navTipKey === key) {
      this.navTipKey = '';
      this.navTipLastHideMs = Date.now();
    }
  }

  /**
   * 气泡本体：WPF-UI 4.3.0 DefaultToolTipStyle 的自绘复刻
   * （#2C2C2C 底 / 1px 边框 / 圆角 4 / 内边距 12 / 字号 12 / 行高 16 / 最大宽 260）。
   */
  @Builder
  nav_tooltip(text: string) {
    Text(text)
      .fontSize(NAV_TOOLTIP_FONT_SIZE)
      .lineHeight(NAV_TOOLTIP_LINE_HEIGHT)
      .fontColor(this.themePalette().TOOLTIP_FOREGROUND)
      .constraintSize({ maxWidth: NAV_TOOLTIP_MAX_WIDTH })
      .padding(NAV_TOOLTIP_PADDING)
      .backgroundColor(this.themePalette().TOOLTIP_BACKGROUND)
      .border({ width: 1, color: this.themePalette().TOOLTIP_BORDER })
      .borderRadius(NAV_TOOLTIP_RADIUS)
  }

  /**
   * 气泡的弹出参数。
   *
   * 单独抽成方法而不是内联字面量：`CustomPopupOptions.shadow` 的类型是
   * `ShadowOptions | ShadowStyle`，ArkTS 严格模式下 union 里的**裸对象字面量**
   * 无法确定要按哪个分支推断（工程内也没有别的 shadow 先例）。这里先把 shadow
   * 标成已声明的 ShadowOptions，再作为值传进去，完全规避该推断问题。
   */
  private nav_popup(entry: NavEntry): CustomPopupOptions {
    const shadow: ShadowOptions = {
      radius: NAV_TOOLTIP_SHADOW_RADIUS,
      color: NAV_TOOLTIP_SHADOW_COLOR,
      offsetX: 0,
      offsetY: NAV_TOOLTIP_SHADOW_OFFSET_Y,
    };
    const options: CustomPopupOptions = {
      builder: (): void => { this.nav_tooltip(entry.tooltip) },
      // 原版未设 ToolTipService.Placement，由 WPF 按鼠标位置自动放置；这里固定
      // 在导航项右侧、垂直居中（收起态观感与 Windows 一致）。
      placement: Placement.Right,
      enableArrow: false,
      mask: false,
      autoCancel: false,
      radius: NAV_TOOLTIP_RADIUS,
      shadow: shadow,
    };
    return options;
  }

  /**
   * 原版各 OnNavigateXxxClick 的逐条还原：
   *
   *   OnNavigateMirroringClick  → SetLeftWorkspacePanel(
   *                                 _leftWorkspacePanel == Mirroring ? None : Mirroring)
   *   OnNavigateDevicesClick    → SetLeftWorkspacePanel(
   *                                 _leftWorkspacePanel == Devices ? None : Devices)
   *   OnNavigateSettingsClick   → SetSettingsPanelVisible(!_isSettingsPanelVisible)
   *   OnNavigateReverseControlClick → new DeviceBindingWindow(...).Show()
   *   OnNavigateOutputClick     → OnMediaOutputSettingsRequested() → new MediaOutputSettingsWindow
   *   OnNavigateDriverClick     → OpenDriverManagerCommand → 启动独立的驱动管理器进程
   *   OnNavigateAboutClick      → OnAboutClick → App.ShowAboutWindow(this, _viewModel)
   *
   * 注意「投屏 / 投屏来源」是**再点一次收起**（None = 两个左侧面板都关），
   * 不是简单的互斥显示。
   */
  on_nav(key: string): void {
    if (key === 'mirroring') {
      const next: boolean = !this.showMirroringPanel;
      this.showMirroringPanel = next;
      this.showDevicePanel = false;
    } else if (key === 'devices') {
      const next: boolean = !this.showDevicePanel;
      this.showDevicePanel = next;
      this.showMirroringPanel = false;
    } else if (key === 'settings') {
      this.showControlPanel = !this.showControlPanel;
    } else if (key === 'binding') {
      // 原版 OnNavigateReverseControlClick：已开则前置，否则 new DeviceBindingWindow。
      // 子窗口的「已开则前置」由 SubWindowHost.open 的 window.findWindow 分支负责。
      this.launch_subwindow((ctx: common.Context): void => {
        open_device_binding(ctx, []);
      });
    } else if (key === 'output') {
      // 原版 OnNavigateOutputClick → OnMediaOutputSettingsRequested()。
      this.launch_subwindow((ctx: common.Context): void => {
        open_media_output_settings(ctx, false);
      });
    } else if (key === 'about') {
      // 原版 OnNavigateAboutClick → OnAboutClick → ShowAboutWindow（默认第 0 页）。
      this.launch_subwindow((ctx: common.Context): void => {
        open_about(ctx, 0);
      });
    } else if (key === 'driver') {
      // 原版 OpenDriverManagerCommand 启动**独立的驱动管理器进程**（DriverInstaller.exe，
      // 自带 MainWindow + DeviceTrust/FailureHelp/Prompt/RequiredAction 四个窗口），
      // 本仓库没有该工程。
      //
      // 这里曾经写着"鸿蒙系统无需外部采集驱动" —— 那句话是错的。鸿蒙上访问 USB 必须
      // 声明**扩展外设驱动**（DriverExtensionAbility + VID 匹配），而官方对
      // OH_Usb_GetDevices 的说明是"设备 ID 已通过驱动配置信息中的 vid 进行筛选过滤"。
      // 缺了它，枚举恒为空列表，症状与"驱动没装"完全一样。所以这一项改成如实报告。
      this.showControlPanel = true;
      const environment: string = this.environmentDiagnostic.length > 0
        ? this.environmentDiagnostic : '环境诊断尚未取到（核心可能未初始化）';
      const driver: string = this.usbDriverNote.length > 0
        ? this.usbDriverNote : '驱动扩展状态未取到';
      const host: string = this.usbHostSummary.length > 0
        ? this.usbHostSummary : '系统 USB 视图未取到';
      this.settingsStatus = `鸿蒙侧的"驱动"指本应用向系统注册的扩展外设驱动` +
        `（Apple VID 0x05AC），不是上游的 DriverInstaller.exe。\n` +
        `系统侧：${host}\n驱动扩展：${driver}\nDDK：${environment}`;
    }
  }

  @Builder
  nav_rail() {
    Column() {
      // 原版 PaneToggleButton（IsPaneToggleVisible="True"）。WPF-UI 4.3.0 的模板里
      // 图标恒为 LineHorizontal320 汉堡（不随展开切换成箭头），但 BasePaneButtonStyle
      // 给图标挂了 ScaleTransform：**按下时横向压到 0.66、松开弹回**（各 80ms），
      // 这就是"点三横线时图标会变化"的出处（NavigationViewBasePaneButtonStyle.xaml）。
      Row() {
        FluentSymbol({ iconName: 'Navigation20', iconSize: 28, iconColor: this.themePalette().TEXT })
          .scale({ x: this.navTogglePressed ? NAV_TOGGLE_PRESSED_SCALE : 1 })
      }
      .width('100%')
      .height(44)
      .padding({ left: 14 })
      .hoverEffect(HoverEffect.Highlight)
      .onTouch((event: TouchEvent): void => {
        // 复刻 WPF EventTrigger：PreviewMouseLeftButtonDown/Up 驱动 IconScaleTransform。
        if (event.type === TouchType.Down) {
          this.getUIContext().animateTo({ duration: NAV_TOGGLE_PRESSED_MS, curve: Curve.EaseOut },
            (): void => { this.navTogglePressed = true; });
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.getUIContext().animateTo({ duration: NAV_TOGGLE_PRESSED_MS, curve: Curve.EaseOut },
            (): void => { this.navTogglePressed = false; });
        }
      })
      .onClick((): void => {
        // 原版点 PaneToggleButton 翻转 IsPaneOpen；WPF-UI 的 PaneStates Storyboard 是
        // **160ms**（PaneGrid Width 48↔208，AccelerationRatio 0.4 = 先加速后匀速）。
        // 这里用 animateTo 复刻：逻辑真值立刻翻转（文字/强调条随之切换），宽度做插值。
        const expand: boolean = !this.navExpanded;
        this.navExpanded = expand;
        this.getUIContext().animateTo({
          duration: NAV_EXPAND_ANIM_MS,
          curve: Curve.EaseInOut,
        }, (): void => {
          this.navRailWidth = expand ? NAV_RAIL_OPEN : NAV_RAIL_COMPACT;
        });
      })

      ForEach(nav_main(), (entry: NavEntry, index: number): void => {
        // 原版在「设备绑定器」与「输出」之间有 NavigationViewItemSeparator
        if (index === NAV_SEPARATOR_AT) {
          Divider().color(this.themePalette().CONTROL_DIVIDER).margin({ top: 6, bottom: 6 })
        }
        this.nav_item(entry)
      }, (entry: NavEntry): string => entry.key)

      Blank()

      // FooterMenuItems
      Divider().color(this.themePalette().CONTROL_DIVIDER).margin({ bottom: 6 })
      this.nav_item(nav_footer())
    }
    .width(this.navRailWidth)
    .height('100%')
    // 水平方向不留内边距：原版条目宽度就等于 pane 宽度（CompactPaneLength/OpenPaneLength），
    // 高亮背景的左右 4 内缩由 nav_item 自己的 InteractionBackground 层负责。
    .padding({ left: 0, right: 0, top: 6, bottom: 10 })
    .backgroundColor(this.themePalette().SIDEBAR)
  }

  // ═══════════════════════════ HeaderPanel ═══════════════════════════

  @Builder
  header() {
    Row() {
      Column() {
        Text('iPhoneMirror')
          .fontSize(24)                                  // 原版 FontSize=24 SemiBold
          .fontWeight(FontWeight.Medium)
          .fontColor(this.themePalette().TEXT)
        // Strings: AppSubtitleConnectivity（Windows → HarmonyOS，见文件头替换清单）
        Text('HarmonyOS USB 低延迟与 AirPlay 无线投屏')
          .fontSize(12)                                  // 原版 FontSize=12
          .fontColor(this.themePalette().MUTED_TEXT)
          .margin({ top: 4 })
      }
      .alignItems(HorizontalAlign.Start)
      // 原版可拖动区域（WindowChrome）；鸿蒙用 window.startMoving()
      .onMouse((event: MouseEvent): void => {
        if (event.action === MouseAction.Press) {
          this.start_window_drag();
        }
      })

      Blank()

      // 原版：Ellipse 6×6 Fill=WarningBrush + 8px 间距 + DriverState（MaxWidth 360）
      Row() {
        Circle({ width: 6, height: 6 })
          .fill(this.devices.length > 0 ? this.themePalette().SUCCESS : this.themePalette().WARNING)
        Text(this.driverState)
          .fontSize(12)
          .fontColor(this.themePalette().TEXT)
          .margin({ left: 8 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .constraintSize({ maxWidth: 360 })
      .margin({ right: 14 })

      // 原版 CaptureActionButton（MainWindow.xaml:698-760）：
      //   Width 132 / Height 40 / MinHeight 40 / Padding 16,8 / CornerRadius 12 /
      //   BorderThickness 1；文字不单独设 FontSize，继承基础 Button 样式的
      //   FontSize=14 / SemiBold（App.xaml:44-45）。
      //   无会话 → CaptureStartBrush「开始投屏」+ StartCommand；
      //   有会话 → CaptureStopBrush「停止投屏」+ StopCommand（DataTrigger HasCaptureSession）。
      //   模板触发器：hover 0.88 / pressed 0.72 / **IsEnabled=False → Opacity 0.34**。
      //   WPF 里 Command 绑定会按 CanExecute 自动置 IsEnabled，所以「不可用」的外观
      //   就是整块（底色+描边+文字）按 0.34 淡化 —— 这里照此实现，并且禁用时不响应点击。
      if (this.has_capture_session()) {
        Text(t('停止投屏'))                                 // Strings: StopMirroring
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.themePalette().CAPTURE_ACTION_TEXT)
          .textAlign(TextAlign.Center)
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .width(CAPTURE_ACTION_WIDTH)
          .height(CAPTURE_ACTION_HEIGHT)
          .borderRadius(CAPTURE_ACTION_RADIUS)
          .backgroundColor(this.themePalette().CAPTURE_STOP)
          .border({ width: 1, color: this.themePalette().CAPTURE_STOP_BORDER })
          .opacity(this.can_stop() ? 1.0 : 0.34)
          .hoverEffect(this.can_stop() ? HoverEffect.Highlight : HoverEffect.None)
          .onClick((): void => {
            if (this.can_stop()) {
              this.stop();
            }
          })
      } else {
        Text(t('开始投屏'))                                 // Strings: StartMirroring
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.themePalette().CAPTURE_ACTION_TEXT)
          .textAlign(TextAlign.Center)
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .width(CAPTURE_ACTION_WIDTH)
          .height(CAPTURE_ACTION_HEIGHT)
          .borderRadius(CAPTURE_ACTION_RADIUS)
          .backgroundColor(this.themePalette().CAPTURE_START)
          .border({ width: 1, color: this.themePalette().CAPTURE_START_BORDER })
          .opacity(this.can_start() ? 1.0 : 0.34)
          .hoverEffect(this.can_start() ? HoverEffect.Highlight : HoverEffect.None)
          .onClick((): void => {
            // 原版 Command 在 CanExecute=false 时根本不触发；这里显式挡一次，
            // 不再往 hint 里写"请先选择设备"——按钮已经是灰的，原因由状态行说明。
            if (this.can_start()) {
              this.start();
            }
          })
      }

      // 给系统窗口三键让位。三键由系统画在窗口右上角并浮在内容之上，
      // 这里在 header 右侧留出同宽空白，避免状态点 / 投屏按钮被压住。
      Column().width(TITLE_BUTTON_RESERVED_WIDTH)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .margin({ bottom: 14 })
  }

  // ═══════════════════════════ LeftPanelHost（DevicePanel） ═══════════════════════════

  // device_row 已改为模块级的 DeviceRow 组件（见文件开头）：@Builder 的参数按值
  // 传递、且传的不是对象字面量，行内的 this.selectedUdid 判断不会刷新 ——
  // 症状是点设备不会移动选中高亮。

  @Builder
  device_panel() {
    Column() {
      // 标题行：DevicesTitle + DeviceCount + 关闭（Dismiss20 / 16）
      Row() {
        Text(t('投屏来源'))                                  // Strings: DevicesTitle
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.themePalette().TEXT)
        Blank()
        Text(this.device_count_text())
          .fontSize(11)
          .fontColor(this.themePalette().MUTED_TEXT)
          .margin({ right: 8 })
        Row() {
          FluentSymbol({ iconName: 'Dismiss20', iconSize: 16, iconColor: this.themePalette().MUTED_TEXT })
        }
        .width(32)
        .height(32)
        .justifyContent(FlexAlign.Center)
        .borderRadius(6)
        .hoverEffect(HoverEffect.Highlight)
        .onClick((): void => {
          this.showDevicePanel = false;
        })
      }
      .width('100%')
      .margin({ bottom: 12 })

      // 当前设备卡片
      Column() {
        Row() {
          Text('当前设备').fontSize(11).fontColor(this.themePalette().MUTED_TEXT)   // Strings: CurrentDevice
          Blank()
          Text(this.selectedConnection).fontSize(10).fontColor(this.themePalette().MUTED_TEXT)
        }
        .width('100%')

        Text(this.selectedName.length > 0 ? this.selectedName : '未选择设备') // Strings: NoDeviceSelected
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.themePalette().TEXT)
          .margin({ top: 9 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.selectedModel.length > 0 ? this.selectedModel : '型号读取中') // Strings: ModelLoading
          .fontSize(11)
          .fontColor(this.themePalette().MUTED_TEXT)
          .margin({ top: 3 })
          .width('100%')
        Text(this.selectedOs).fontSize(11).fontColor(this.themePalette().MUTED_TEXT).width('100%')
        Text(this.selectedUdid)
          .fontSize(9)
          .fontColor(this.themePalette().MUTED_TEXT)
          .margin({ top: 7 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding(12)
      .backgroundColor(this.themePalette().PANEL_ALT)
      .borderRadius(10)
      .border({ width: 1, color: this.themePalette().BORDER_SOFT })

      Divider().color(this.themePalette().CONTROL_DIVIDER).margin({ top: 12, bottom: 12 })

      // 设备列表（原版 ListBox ItemsSource=Devices）
      List({ space: 4 }) {
        ForEach(this.devices, (device: DeviceInfo): void => {
          ListItem() {
            DeviceRow({
              devName: device.name.length > 0 ? device.name : device.udid,
              devModel: device.productType,
              devOs: `iOS ${device.osVersion}`,
              devStatus: device.status,
              selected: this.selectedUdid === device.udid,
              on_pick: (): void => { this.select_device(device); },
            })
          }
          // ★ key 里必须带上「是否选中」与「连接状态」：ArkUI 的 ForEach **只按 key
          //   决定复用与否**，key 不变就直接复用旧节点、不重跑这一项的更新。设备列表
          //   每轮轮询都会重新赋值 this.devices，但 udid 始终是同一个 —— 只靠 @Prop
          //   下发选中态的话，点一下设备高亮不会动。这与按钮那两处不同根因、同一个表象。
        }, (device: DeviceInfo): string =>
          `${device.udid}|${device.status}|${this.selectedUdid === device.udid ? 'S' : '-'}`)
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto)

      // 原版 RefreshDevicesButton（Background=ControlFillBrush）+ KeepUnlocked
      Column() {
        Text('刷新设备')                                  // Strings: RefreshDevices
          .fontSize(13)
          .fontColor(this.themePalette().TEXT)
          .textAlign(TextAlign.Center)
          .width('100%')
          .height(34)
          .borderRadius(6)
          .backgroundColor(this.themePalette().CONTROL_FILL)
          .onClick((): void => {
            this.refresh();
          })
        Text('连接后请保持 Apple 设备解锁')               // Strings: KeepUnlocked
          .fontSize(11)
          .fontColor(this.themePalette().MUTED_TEXT)
          .textAlign(TextAlign.Center)
          .width('100%')
          .margin({ top: 9 })
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .width(DEVICE_PANEL_WIDTH)
    .height('100%')
    .padding(16)
    .workspace_card(this.themePalette())
  }

  // ═══════════════════════════ LeftPanelHost（MirroringPanel） ═══════════════════════════

  /**
   * 按钮当前不可用时的点击反馈。
   *
   * 尺寸与禁用态取值仍照原版（MainWindow.xaml 的 ToolButton 样式 :89–97 与基础
   * Button 模板 App.xaml:39–93：FontSize=12、MinHeight=36、Padding="8,7"、
   * CornerRadius=11、禁用态 Opacity=0.34），但**渲染不再是 @Builder** ——
   * 见 ToolPanelButton / QuickBarButton 的说明：按值传参的 @Builder 不会动态刷新，
   * 可用性会冻在首帧。
   *
   * 两条出口都要给确切答复（不静默假装成功）：未实现的动作弹「敬请期待」，
   * 已实现但条件不足的明说缺什么。
   */
  private block_action(action: string): void {
    if (NOT_IMPLEMENTED_ACTIONS.includes(action)) {
      this.show_not_implemented(action);
    } else {
      // 已实现但当前不满足条件（例如还没开始投屏）。
      this.settingsStatus = '该操作需先开始投屏';
    }
  }

  // ═══════════════ 未实现功能的统一反馈 ═══════════════

  /**
   * 弹一条「敬请期待」，并把确切原因同时写进设置面板的状态行。
   *
   * 两件事都要做：用户要的是即时反馈（浮层），排查与交代需要的是确切成因
   * （面板里那行字）。只写面板 = 用户看不见；只弹浮层 = 事后无从查证。
   */
  private show_coming_soon(feature: string, reason: string): void {
    this.comingSoonText = `${feature}：敬请期待`;
    this.settingsStatus = `${feature}：敬请期待 —— ${reason}`;
    if (this.comingSoonTimer >= 0) {
      clearTimeout(this.comingSoonTimer);
    }
    this.comingSoonTimer = setTimeout((): void => {
      this.comingSoonText = '';
      this.comingSoonTimer = -1;
    }, COMING_SOON_DURATION_MS);
  }

  /**
   * 动作 → 未实现说明。列在这里的动作，UI 层都没有接上真实实现（以代码事实为准，
   * 不是"看起来像"）：录制推流需要编码管线，鸿蒙版尚未接。
   *
   * 其余动作（image/refresh/bluetooth/window/screenshot/fullscreen）都已接真实实现，
   * 走各自的 run_tool_action / run_quick_action 分支，不会再落进这里。
   */
  private show_not_implemented(action: string): void {
    if (action === 'media') {
      this.show_coming_soon(t('录制与推流'),
        '鸿蒙版尚未实现（上游 Windows 走 Media Foundation / FFmpeg 管线）。');
    } else {
      this.show_coming_soon('该功能', '鸿蒙版尚未实现。');
    }
  }

  /** 全屏预览开关：true = 主窗口正处于沉浸全屏。 */
  private fullscreenOn: boolean = false;

  /**
   * 截图（原版 ScreenshotCommand）：截取预览 XComponent（id='preview'）当前画面，
   * 编码成 PNG 后写入**应用私有目录**（filesDir/iPhoneMirror/Screenshots/）。
   *
   * ★ 为什么不用 photoAccessHelper 写系统相册：写相册需要
   *   ohos.permission.WRITE_IMAGEVIDEO，而它在 SDK 的 availableLevel 其实是
   *   **system_basic**（1.0.25 一度误标成 normal）。system_basic 权限必须进签名
   *   profile 的 acls.allowed-acls 才能装包，本工程调试 profile 由 AGC 签发、本地
   *   改不了 ⇒ 带上它安装直接报 9568289。故截图改存应用私有目录（无需任何权限即可写），
   *   用户在文件管理 / 关于页「打开日志目录」同级的 Screenshots 文件夹里取走。
   *   待拿到带该 ACL 的 profile 再改回写相册。
   *
   * ★ 为什么用 componentSnapshot 而不是直接拿解码帧：AirPlay 无线镜像不走 Core 的
   *   capture_session（im_copy_latest_video_frame 会回 CaptureBackendUnavailable），
   *   而无线才是主力路径；componentSnapshot 截的是 ArkUI 真正渲染的那一帧，USB 与
   *   AirPlay 都涵盖，不必改原生管线。
   *
   * ★ 已知边界（不假成功）：XComponent 是 SURFACE 类型，个别 API 版本/设备上
   *   componentSnapshot 可能截不到 surface 内容（得黑图）。实测是黑图再告诉我。
   *
   * ★ 独立窗口开着时主窗口预览区是空的，此时在主窗口截图无意义 —— 可用性已据此关掉。
   */
  private async capture_screenshot(): Promise<void> {
    let pixelMap: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      pixelMap = await componentSnapshot.get('preview');
      if (pixelMap === null) {
        this.settingsStatus = '截图失败：未能取到预览画面（componentSnapshot 返回空）';
        return;
      }
      packer = image.createImagePacker();
      const data: ArrayBuffer = await packer.packToData(pixelMap, {
        format: 'image/png',
        quality: 100,
      });
      const context: common.Context | null = this.appContext;
      if (context === null) {
        this.settingsStatus = '截图保存失败：拿不到应用上下文';
        return;
      }
      const dir: string = context.filesDir + '/iPhoneMirror/Screenshots';
      try {
        fs.mkdirSync(dir, true);
      } catch (e) {
        // 目录已存在等情况忽略
      }
      const stamp: string = this.screenshot_timestamp();
      const path: string = `${dir}/${stamp}.png`;
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
      try {
        fs.writeSync(file.fd, data);
      } finally {
        fs.closeSync(file);
      }
      this.settingsStatus = `截图已保存到应用目录：${path}`;
    } catch (error) {
      const failure = error as BusinessError;
      this.settingsStatus = `截图失败：${failure.code} ${failure.message}`;
    } finally {
      if (packer !== null) {
        await packer.release();
      }
      if (pixelMap !== null) {
        pixelMap.release();
      }
    }
  }

  /** 截图文件名用的时间戳：YYYYMMDD_HHMMSS（本地时区）。 */
  private screenshot_timestamp(): string {
    const d: Date = new Date();
    const pad = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
    return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}` +
      `_${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
  }

  /**
   * 全屏预览（原版 FullscreenCommand）：切换主窗口的沉浸全屏。
   *
   * 实现是 window.setWindowLayoutFullScreen + setWindowSystemBarEnable（隐藏/
   * 恢复状态栏与导航栏），而不是真去改窗口的 free-window 模式 —— 主应用窗口
   * 走这条更稳，且不会触发 relaunch。
   */
  private toggle_fullscreen(): void {
    const ctx: common.Context | null = this.appContext;
    if (ctx === null) {
      this.settingsStatus = '全屏预览失败：拿不到应用上下文';
      return;
    }
    const target: boolean = !this.fullscreenOn;
    const bars: Array<'status' | 'navigation'> = target ? [] : ['status', 'navigation'];
    window.getLastWindow(ctx)
      .then((win: window.Window): Promise<void> => {
        return win.setWindowLayoutFullScreen(target);
      })
      .then((): Promise<window.Window> => {
        return window.getLastWindow(ctx);
      })
      .then((win: window.Window): Promise<void> => {
        return win.setWindowSystemBarEnable(bars);
      })
      .then((): void => {
        this.fullscreenOn = target;
        this.settingsStatus = target ? '已进入全屏预览（再次点击退出）' : '已退出全屏预览';
      })
      .catch((error: BusinessError): void => {
        this.settingsStatus = `全屏预览失败：${error.code} ${error.message}`;
      });
  }

  /**
   * 打开画面调节子窗口（原版 MoreImageSettingsCommand）。
   *
   * 传**当前生效值**而不是默认值：否则窗口里的滑杆会和画面实际状态对不上，
   * 用户一按「应用」画面就跳变。
   */
  private open_image_settings_window(): void {
    const a: number[] = this.appliedAdjustments;
    this.launch_subwindow((ctx: common.Context): void => {
      open_image_settings(ctx, {
        brightness: a[0] * 100, contrast: a[1] * 100,
        saturation: a[2] * 100, gamma: a[3] * 100,
      });
    });
  }

  /** 原版 MirroringPanel 五个 ToolButton 的 Click 处理。 */
  run_tool_action(action: string): void {
    if (action === 'image') {
      // 原版 MoreImageSettingsCommand → 画面调节子窗口。
      // 这里此前写的是「鸿蒙版待接入 GLES 色彩矩阵」——过时文案：色彩矩阵早已落地
      // （OhosPreviewRenderer 的 brightness/contrast/saturation/gamma 四路 uniform），
      // 子窗口也是现成的。已改为真的打开它。
      this.open_image_settings_window();
    } else if (action === 'refresh') {
      // 原版 OnRefreshPreviewClick。
      // 此前这里只写一句「预览渲染器已刷新」——不论渲染器死活都报成功，是假成功。
      // 现在真调一次 ABI，并把它的真实结果（含"尚未挂载 surface"）如实显示。
      const result: number = forcePreviewRefresh();
      this.settingsStatus = result === 0
        ? '预览渲染器已刷新'                              // Strings: PreviewRefreshed
        : `刷新预览失败：${lastError()}`;
    } else if (action === 'window') {
      // 独立窗口（投屏面板里的那个 ToolButton）。
      // 它现在与「刷新画面」同一个口径：需要真有画面才有意义（上游
      // CanUseVisualPreviewTools），而不是"未实现"那个假门槛。
      if (this.standaloneOpen) {
        this.focus_standalone_window();
      } else {
        this.open_standalone_window();
      }
    } else if (action === 'screenshot') {
      // 截图（原版 ScreenshotCommand）。可用性由按钮的 usable 决定（需真有画面）。
      this.capture_screenshot();
    } else if (action === 'fullscreen') {
      // 全屏预览（原版 FullscreenCommand）。
      this.toggle_fullscreen();
    } else {
      this.show_not_implemented(action);
    }
  }

  @Builder
  mirroring_panel() {
    Column() {
      Row() {
        Text(t('投屏'))                                      // Strings: NavMirroring
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.themePalette().TEXT)
        Blank()
        Row() {
          FluentSymbol({ iconName: 'Dismiss20', iconSize: 16, iconColor: this.themePalette().MUTED_TEXT })
        }
        .width(32)
        .height(32)
        .justifyContent(FlexAlign.Center)
        .borderRadius(6)
        .hoverEffect(HoverEffect.Highlight)
        .onClick((): void => {
          this.showMirroringPanel = false;
        })
      }
      .width('100%')
      .margin({ bottom: 12 })

      // Strings: ProjectionSettingsDescription
      // 平台替换：原句是「…开始投屏后可使用画面、窗口和截图功能。」——本移植的「截图」
      // 尚未实现（按钮恒灰 + 点击给「敬请期待」），不能再在说明里承诺它可用。
      // 画面/窗口两项现在都是真功能，照留。
      Text('按需展开常用投屏操作；开始投屏后可使用画面与窗口功能。')
        .fontSize(11)
        .fontColor(this.themePalette().MUTED_TEXT)
        .width('100%')
        .margin({ bottom: 14 })

      // 原版 5 个 ToolButton，顺序与图标字号逐条对照。
      // 已实现的：「调节画面」（可点即开窗口）、「独立窗口」（有画面时可开，画面会被
      // 移到独立窗口）、「刷新画面」（按投屏状态可用）、「截图」（截预览帧存相册）、
      // 「全屏预览」（主窗口沉浸全屏）。后两项的可用性由真实条件决定（需先有画面、
      // 且画面在主窗口而非独立窗口），不再是"未实现"。
      //
      // ★ 状态驱动的三项（label / icon / usable）一律走 @Prop 下发，见 ToolPanelButton
      //   的说明：写成 @Builder 参数的话这些值会冻在首帧，「独立窗口」「刷新画面」
      //   投屏开始了也还是灰的。
      ToolPanelButton({
        btnLabel: t('调节画面'), iconName: 'ImageEdit20', iconSize: 16, usable: true,
        on_action: (): void => { this.run_tool_action('image'); },
        on_blocked: (): void => { this.block_action('image'); },
      })
      ToolPanelButton({
        btnLabel: t('独立窗口'), iconName: 'WindowNew20', iconSize: 15,
        usable: this.can_use_visual_tools(),
        on_action: (): void => { this.run_tool_action('window'); },
        on_blocked: (): void => { this.block_action('window'); },
      })
      ToolPanelButton({
        btnLabel: '截图', iconName: 'Screenshot20', iconSize: 15,
        usable: this.can_use_visual_tools() && !this.standaloneOpen,
        on_action: (): void => { this.run_tool_action('screenshot'); },
        on_blocked: (): void => { this.block_action('screenshot'); },
      })
      ToolPanelButton({
        btnLabel: t('刷新画面'), iconName: 'ArrowClockwise20', iconSize: 15,
        usable: this.can_use_visual_tools(),
        on_action: (): void => { this.run_tool_action('refresh'); },
        on_blocked: (): void => { this.block_action('refresh'); },
      })
      ToolPanelButton({
        btnLabel: t('全屏预览'), iconName: 'FullScreenMaximize20', iconSize: 15,
        usable: this.can_use_visual_tools() && !this.standaloneOpen,
        on_action: (): void => { this.run_tool_action('fullscreen'); },
        on_blocked: (): void => { this.block_action('fullscreen'); },
      })
    }
    .width(DEVICE_PANEL_WIDTH)
    .height('100%')
    .padding(16)
    .workspace_card(this.themePalette())
  }

  @Builder
  left_panel() {
    // 原版 LeftPanelHost 固定 Width=300，内部 DevicePanel / MirroringPanel 互斥
    // （各自的 Visibility 由导航切换）。
    // ★ 调用点（build 的 MainContentGrid）只在**两个面板有一个开着时**才渲染本列：
    //   两个都收起时，连容器带间隔一并撤掉，中间画面区自动占满。上游亦然 ——
    //   LeftPanelHost 关闭时 Width=0 + Visibility=Collapsed、LeftGapColumn.Width=0。
    //   （此前这里写着"两个都收起时仍占位、与原版一致"，那是错的，已按上游改正。）
    Column() {
      if (this.showDevicePanel) {
        this.device_panel()
      } else if (this.showMirroringPanel) {
        this.mirroring_panel()
      }
    }
    .width(DEVICE_PANEL_WIDTH)
    .height('100%')
  }

  // ═══════════════════════════ CenterPanel ═══════════════════════════

  /** 原版 PreviewQuickActions 六个按钮的行为。 */
  run_quick_action(action: string): void {
    if (action === 'image') {
      // 已实现（同 run_tool_action 的说明）。
      this.open_image_settings_window();
    } else if (action === 'bluetooth') {
      this.toggle_bluetooth_control();
    } else if (action === 'window') {
      // 独立预览窗口（上游 PreviewQuickActions 里的独立窗口按钮）。
      // 已经开着就只把它前置（上游同 UDID 再点不重开，而是 Activate()；
      // SubWindowHost.open 对已存在的窗口也只做 showWindow —— 同一个语义）。
      if (this.standaloneOpen) {
        this.focus_standalone_window();
      } else {
        this.open_standalone_window();
      }
    } else if (action === 'screenshot') {
      this.capture_screenshot();
    } else if (action === 'fullscreen') {
      this.toggle_fullscreen();
    } else {
      this.show_not_implemented(action);
    }
  }

  /**
   * 把已经开着的独立窗口前置（对应上游对已存在窗口的 Activate()）。
   *
   * ★ 独立窗口现在是**独立 UIAbility**，主窗口拿不到它的 Window 对象 ——
   *   `window.findWindow` 只认我们自己 createSubWindowWithOptions 过的子窗名，
   *   而独立 Ability 的窗口名不在这里面。
   *   改成**再 startAbility 一次**：那个 Ability 是 launchType=singleton，
   *   重复拉起不会新开实例，而是走它的 onNewWant，由它把自己的窗口置前。
   */
  private focus_standalone_window(): void {
    const ctx: common.Context | null = this.appContext;
    if (ctx === null) {
      return;
    }
    try {
      const abilityCtx: common.UIAbilityContext = ctx as common.UIAbilityContext;
      abilityCtx.startAbility({
        bundleName: abilityCtx.abilityInfo.bundleName,
        abilityName: STANDALONE_ABILITY,
      }).catch((error: BusinessError): void => {
        console.warn('iPhoneMirror focus standalone preview failed:', error.message);
      });
    } catch (error) {
      const failure = error as BusinessError;
      console.warn('iPhoneMirror focus standalone preview failed:', failure.message);
    }
  }

  /**
   * 蓝牙反向控制的开关（原版 BluetoothControlLabel 那个按钮）。
   *
   * 上游有三个并列入口 ——「无线控制 / 有线控制 / 蓝牙控制」—— 对应三条**完全
   * 不同**的技术通道。鸿蒙版只做蓝牙这条，理由是可验证的：
   *
   *   · 蓝牙 = 标准 BLE HID 外设（HOGP）：鸿蒙 API 齐备，
   *     `ble.createGattServer()` + `ble.startAdvertising()` 就能复刻上游的
   *     WinRT `GattServiceProvider`；
   *   · 有线 / 无线 = 上游靠**外部 Python 桥**（iPhoneMirror/tools/
   *     usb_touch_bridge.py，2182 行，走 pymobiledevice3 的 CoreDevice /
   *     RemoteServiceDiscovery / UniversalHID）。它要求先完成 usbmux 会话、
   *     lockdownd 的 `Pair`、再挂载 Apple 的开发者磁盘镜像 —— 在鸿蒙上等于把
   *     整条 Apple 私有链路从 USB 端点重写一遍，不是本轮能交付的东西。
   *
   * 所以按钮只承诺蓝牙这条，不做"三个都能用"的假象。
   */
  private toggle_bluetooth_control(): void {
    try {
      const hid = BluetoothHidPeripheral.shared();
      if (this.bluetoothOn || hid.isAdvertising()) {
        hid.stop();
        ReverseControlInput.shared().setEnabled(false);
        // ★ 记下"这是用户显式停的"。没有这一笔，鼠标一移回画面就会自动
        //   重新广播 —— 那个停止按钮在用户看来就是坏的。
        this.set_reverse_disabled(true);
        this.bluetoothOn = false;
        this.bluetoothControlText = reverse_label('未启用');
        this.bluetoothStatus = '';
        this.settingsStatus = '蓝牙反向控制已停止（再点一下恢复；恢复后鼠标移到画面上即可操控）';
        // 上游关掉反控时会顺手关掉提示窗口（MainViewModel.cs:1594/1699
        // BluetoothControlNoticeWindow.TryCloseActive()）。
        this.close_bluetooth_notice();
        return;
      }
      const ctx: common.Context | null = this.appContext;
      if (ctx === null) {
        this.bluetoothOn = false;
        this.settingsStatus = '开启蓝牙反向控制失败：拿不到应用上下文';
        return;
      }
      // ★ 必须走 start(ctx) 这条异步路：ACCESS_BLUETOOTH 是 **user_grant**，
      //   start() 内部会先调 requestPermissionsFromUser 弹系统授权框，拿到授权
      //   才去 createGattServer/addService。此前调的是同步版 start()，权限从未
      //   申请过，addService 立刻回 201 —— 界面上就是
      //   「注册 BLE HID 服务失败：201 BusinessError 201: Permission denied.」。
      // 用户主动开启 ⇒ 清掉"显式停用"标志，恢复成可自动启动的状态。
      this.set_reverse_disabled(false);
      this.bluetoothStarting = true;
      hid.start(ctx).then((started: boolean): void => {
        // 回调里一行都不能裸奔：抛异常就是未捕获异常 → 整个应用被结束。
        this.bluetoothStarting = false;
        this.after_bluetooth_start(started);
      }).catch((error: BusinessError): void => {
        this.bluetoothStarting = false;
        this.bluetoothOn = false;
        this.bluetoothControlText = reverse_label('未启用');
        this.settingsStatus = `开启蓝牙反向控制异常：${error.code} ${error.message}`;
      });
    } catch (error) {
      const failure = error as BusinessError;
      this.bluetoothOn = false;
      this.settingsStatus = `蓝牙反向控制异常：${failure.code} ${failure.message}`;
    }
  }

  /**
   * 自动启动蓝牙反控通道（鼠标第一次落到预览画面上时触发）。
   *
   * ── 为什么不再等用户点按钮 ──────────────────────────────────────────────
   * 诉求是"无感"：鼠标放到窗口上就能操控。而"能操控"的前提是通道已经在广播、
   * iPhone 已经连上 —— 把这一步留给用户，等于每次开机都要先找到设置面板点一下，
   * 那正是要取消掉的动作。
   *
   * ── 为什么是"惰性"而不是应用启动时就做 ─────────────────────────────────
   * 首次必然要弹一次蓝牙权限框（ACCESS_BLUETOOTH 是 user_grant，不申请的话
   * GATT 服务连注册都会被拒：201）。放在应用启动时，用户只要打开应用就会看到
   * 一个莫名其妙的权限框，哪怕他根本没打算用反控 —— 那是最典型的打扰。
   * 放到"鼠标第一次落到画面上"这一刻，申请时机与用户意图正好重合。
   * 成功之后外设会一直广播，此后每次悬停都是即时的。
   */
  private auto_start_bluetooth(): void {
    try {
      if (this.bluetoothStarting) {
        return;
      }
      const ctx: common.Context | null = this.appContext;
      if (ctx === null) {
        return;
      }
      const hid = BluetoothHidPeripheral.shared();
      this.bluetoothStarting = true;
      hid.start(ctx).then((started: boolean): void => {
        // Promise 回调里一行都不能裸奔：抛出去就是未捕获异常 → 应用被结束。
        this.bluetoothStarting = false;
        this.after_bluetooth_start(started, false);
      }).catch((error: BusinessError): void => {
        this.bluetoothStarting = false;
        this.settingsStatus = `蓝牙反向控制自动启动异常：${error.code} ${error.message}`;
      });
    } catch (error) {
      this.bluetoothStarting = false;
      console.warn('iPhoneMirror auto start bluetooth failed:', (error as BusinessError).message);
    }
  }

  /**
   * start(ctx) 的异步结果收尾（原同步分支原样搬过来）。
   *
   * 整段包 try/catch：它是 Promise 回调，抛出去会变成未捕获异常结束整个应用。
   *
   * @param interactive true = 用户主动点的按钮（失败/等待都要弹窗，符合上游
   *   ShowFailure / ShowWaiting 的行为）；false = 悬停触发的自动启动，只写状态行
   *   不弹窗 —— 用户只是把鼠标扫过画面，不该被两个窗口拦住。
   */
  private after_bluetooth_start(started: boolean, interactive: boolean = true): void {
    try {
      const hid = BluetoothHidPeripheral.shared();
      if (!started) {
        // 失败必须原样报出来。最常见的是 201（蓝牙权限被拒）与 801（设备不支持
        // BLE 外设角色）—— 两者处置完全不同，含糊成"开启失败"等于让用户白试。
        this.bluetoothOn = false;
        this.bluetoothControlText = reverse_label('未启用');
        this.refresh_bluetooth_status();
        this.settingsStatus = `开启蓝牙反向控制失败：${hid.errorText()}`;
        // 上游 ShowFailure(owner, error.Message)：把确切原因摆到用户面前。
        // 自动启动时不弹窗（用户没提出请求），但状态行照样写死原因 —— 不静默。
        const ctx: common.Context | null = this.appContext;
        if (ctx !== null && interactive) {
          open_bluetooth_control_failure(ctx, hid.errorText());
        }
        return;
      }
      ReverseControlInput.shared().setEnabled(true);
      ReverseControlInput.shared().setSensitivity(this.bluetoothSensitivity);
      this.bluetoothOn = true;
      this.refresh_bluetooth_status();
      // ★ 启动成功不等于没问题：回读不到 GATT 特征（getService/getServices 是
      //   @since 22 的接口，低版本设备上不存在）时必须把"校验不了"说出来，
      //   否则用户遇到"iPhone 连上却没反应"时会以为功能正常。
      // ★ 也不等于可用：这条状态行是"开启成功"的措辞，但反控本身仍在实现阶段，
      //   所以措辞里带上（实验·开发中），别让"已开启"独占整句话的意思。
      const hidWarning: string = hid.warningText();
      this.settingsStatus = hidWarning.length > 0
        ? `蓝牙反向控制已开启（实验·开发中），但有隐患：${hidWarning}`
        : '蓝牙反向控制已开启（实验·开发中，不保证可用）：请在 iPhone 上打开「设置 → 辅助功能 → 触控 → 辅助触控」，再连接这台电脑';
      // 上游 ShowWaiting(owner, suggestedDeviceName)（MainViewModel.cs:1413）：
      // 开广播之后弹「等待连接」提示，连上时它会自己切成「已连接」并倒计时关闭。
      const waitCtx: common.Context | null = this.appContext;
      if (waitCtx !== null && interactive) {
        open_bluetooth_control_waiting(waitCtx, this.selectedName);
      }
      this.lastBluetoothConnected = false;
    } catch (error) {
      const failure = error as BusinessError;
      this.bluetoothOn = false;
      this.settingsStatus = `蓝牙反向控制异常：${failure.code} ${failure.message}`;
    }
  }

  /** 关掉蓝牙反控提示窗口（上游 TryCloseActive）。 */
  private close_bluetooth_notice(): void {
    try {
      SubWindowHost.close(BLUETOOTH_NOTICE_WINDOW);
    } catch (error) {
      const failure = error as BusinessError;
      console.warn('iPhoneMirror close bluetooth notice failed:', failure.message);
    }
  }

  /**
   * 本地系统指针的可见性（每轮 poll_status 重算一次）。
   *
   * ── 为什么要藏 ──────────────────────────────────────────────────────────
   * 接管期间屏幕上若同时存在两个指针（本地的 + iPhone 画面里的），用户根本
   * 不知道该看哪个、该信哪个。参考实现都藏本地那个：macOS 的「iPhone 镜像」
   * 如此，上游 Windows 版也如此（Strings.zh-CN「反向控制期间 Windows 光标会
   * 隐藏」，MainViewModel.cs 同一段逻辑）。
   *
   * ── 为什么要"每轮重算"而不是"进入时藏、离开时显" ────────────────────────
   * 后者只要漏掉任意一条退出路径（异常、窗口被别处销毁、通道被设备绑定器
   * 停掉、回调没跑到），指针就永久停在隐藏态 —— 那是用户连电脑都用不下去的
   * 状态，比功能不可用严重得多。这里每轮拿真实接管态重算，任何意外都会在
   * 下一次轮询（500ms）内自动纠正。
   */
  private apply_pointer_visibility(): void {
    if (this.pointerHideUnsupported) {
      return;
    }
    try {
      // ★ 偏好位关着 ⇒ shouldHide 恒为 false ⇒ 顺带把"上一轮藏起来的"恢复
      //   回来（下面那句 setPointerVisibleSync 会在状态不一致时真去调一次）。
      //   所以这里**不能**因为偏好关就早退 —— 早退就等于放弃自愈。
      const wantHide: boolean = AppStorage.get<boolean>(HIDE_POINTER_ON_TAKEOVER_KEY)
        ?? this.hidePointerOnTakeover;
      const shouldHide: boolean = wantHide && ReverseControlInput.shared().isTakingOver();
      if (shouldHide === this.pointerHidden) {
        return;
      }
      pointer.setPointerVisibleSync(!shouldHide);
      this.pointerHidden = shouldHide;
    } catch (error) {
      const failure = error as BusinessError;
      // 藏指针只是锦上添花：拿不到就干脆不要这个特性，绝不能让一行可选的
      // 装饰把整个应用拖垮（能力不支持的设备上这个接口会直接抛）。
      this.pointerHideUnsupported = true;
      this.pointerHidden = false;
      console.warn('iPhoneMirror pointer visibility failed:', failure.message);
    }
  }

  /** 强制恢复本地指针（退出/销毁路径上的兜底，不依赖接管态是否已经复位）。 */
  private restore_pointer_visibility(): void {
    if (this.pointerHideUnsupported || !this.pointerHidden) {
      return;
    }
    try {
      pointer.setPointerVisibleSync(true);
    } catch (error) {
      const failure = error as BusinessError;
      console.warn('iPhoneMirror restore pointer failed:', failure.message);
    }
    this.pointerHidden = false;
  }

  /** 写「用户是否显式停用了反向控制」这个跨窗口标志（见 WindowServices 的说明）。 */
  private set_reverse_disabled(disabled: boolean): void {
    try {
      AppStorage.setOrCreate<boolean>(REVERSE_CONTROL_DISABLED_KEY, disabled);
    } catch (error) {
      console.warn('iPhoneMirror reverse-disabled flag write failed:',
        (error as BusinessError).message);
    }
  }

  /**
   * 读该标志。读不到一律按"没被停用"处理 —— 默认值是"可以自动启动"，
   * 这与"无感"的取向一致：只有用户明确说过不要，才不自动。
   */
  private reverse_disabled(): boolean {
    try {
      const flag: boolean | undefined = AppStorage.get<boolean>(REVERSE_CONTROL_DISABLED_KEY);
      return flag === true;
    } catch (error) {
      return false;
    }
  }

  /**
   * 预览区此刻是否**真的有画面**可操控。
   *
   * 两条判据都要算，缺一不可：USB 采集走 is_streaming()，而无线镜像**完全不
   * 经过**采集状态机（见 airplay_mirroring 的注释）—— 只读前者的结果是
   * "AirPlay 投屏时永远接管不了"。
   *
   * 这个判断不能省：没有画面时接管等于把鼠标吸走、却指着"等待设备"那张占位图
   * 操作，用户看到的现象就是"鼠标突然失灵了"。
   */
  private has_preview_picture(): boolean {
    return this.is_streaming() || this.airplay_mirroring();
  }

  /**
   * 指针进入/离开预览画面 → 进入/退出接管。
   *
   * 这就是"无感"的开关：没有按钮，没有"先点一下画面"，鼠标放到画面上就操控。
   * 是否真的接管由 setTakeover 判定（通道没就绪时它会拒绝并返回 false），
   * 所以"iPhone 还没连上"时鼠标照常是普通鼠标，不会掉进
   * 「鼠标不动了、但手机也没反应」那种最糟的中间态。
   *
   * ★ 接管成立就**要键盘焦点**（见下面 focus_preview_input 的调用）。早先的写法是
   *   "不在这里抢焦点、让用户先点一下画面"，理由是不想夺走用户在别处的键盘 ——
   *   那个理由在"接管已经成立"这一刻不成立：接管成立 = 指针确实在这块画面上、
   *   用户此刻就是要操控它，而键盘事件**只发给有焦点的节点**，不主动要焦点就等于
   *   键盘永久哑掉（现象与"通道没通"一模一样）。不再要求用户多点一下。
   */
  private on_preview_hover(isHover: boolean): void {
    try {
      const input = ReverseControlInput.shared();
      if (isHover) {
        // 通道惰性启动（理由见 auto_start_bluetooth）：第一次悬停时把蓝牙权限
        // 与广播一并做掉，此后常驻，后续每次悬停都不再有任何前置动作。
        // 用户显式停用过则不自动启动 —— 否则那个停止按钮等于失灵。
        const hid = BluetoothHidPeripheral.shared();
        if (!hid.isAdvertising() && !this.bluetoothStarting && !this.reverse_disabled()) {
          this.auto_start_bluetooth();
        }
      }
      // 悬停状态一律登记，"此刻有没有画面"（等待设备 / 已挪到独立窗口）由
      // poll_status 每轮单独报（见 setPictureAvailable）—— 那件事随时会变，
      // 在这里判一次就会出现"鼠标停在画面上不动、画面来了却不接管"
      // （那一次 hover 早就过去了，只能靠移开再移回来重生效，很反直觉）。
      input.setHoverSource('main', isHover);
      input.refreshChannel();
      // 走同一条自愈路径，让指针状态立刻跟上，不必等下一次轮询。
      this.apply_pointer_visibility();
      if (isHover && input.isTakingOver()) {
        // ★ 接管成功就把键盘焦点要过来。
        //   键盘事件只发给**有焦点**的节点，原先靠"点一下画面"来拿焦点；但点击
        //   能否落到那一层取决于命中测试是否把透明承接层当鼠标目标，一旦不算，
        //   用户就永远拿不到焦点、键盘全哑。而"接管已经成立"本身就说明指针确实
        //   在画面上、用户就是想操控它 —— 此刻要焦点与"移上去就接管"是同一件事，
        //   不该再要求用户多点一下。
        this.focus_preview_input();
      }
      if (isHover && !input.isTakingOver() && input.isEnabled()) {
        // 悬停但没接管成功 = 通道在、iPhone 没连上。必须说出来 ——
        // 否则用户只看到"鼠标放上去没反应"，无从判断是坏了还是没连。
        this.bluetoothStatus = '等待 iPhone 连接后才能操控：请在 iPhone 上打开'
          + '「设置 → 辅助功能 → 触控 → 辅助触控」，再与本机蓝牙配对。';
      }
    } catch (error) {
      const failure = error as BusinessError;
      console.warn('iPhoneMirror preview hover failed:', failure.message);
    }
  }

  /** 每轮 poll_status 刷新蓝牙反控状态与计数（打开时才显示详细行）。 */
  private refresh_bluetooth_status(): void {
    try {
      const hid = BluetoothHidPeripheral.shared();
      const input = ReverseControlInput.shared();
      const connected: boolean = hid.isConnected();
      // ★ 必须每轮从外设回读开关状态，不能用「本窗口点过按钮」推出来的值：
      //   外设是单例，设备绑定器窗口的蓝牙配网流程（原版 ConnectBluetoothClick 的
      //   StartBluetoothPeripheralForConfigurationAsync / Stop...Async）启停的是
      //   **同一个**外设（上游也是同一个 _bluetoothControl）。不回读的话，那边一停，
      //   这里的按钮会一直停在「停止蓝牙反向控制」，而实际上什么都没在广播。
      const advertising: boolean = hid.isAdvertising();
      if (this.bluetoothOn && !advertising) {
        // 被别处停掉了：输入路由也得跟着停，否则还在往一个不存在的连接里塞事件。
        ReverseControlInput.shared().setEnabled(false);
      }
      this.bluetoothOn = advertising;
      // 「刚连上」的跃迁 → 上游 ShowConnected（MainViewModel.cs:1746）。
      // 提示窗口是复用同一个窗口改状态的（@StorageLink），所以这里只需触发一次。
      if (connected && !this.lastBluetoothConnected) {
        const ctx: common.Context | null = this.appContext;
        if (ctx !== null && hid.isAdvertising()) {
          open_bluetooth_control_connected(ctx);
        }
      }
      this.lastBluetoothConnected = connected;
      if (connected) {
        this.bluetoothControlText = reverse_label('已连接');
      } else if (hid.isAdvertising()) {
        // ★ 只如实报"GATT 服务在广播"，不暗含"能用" —— 见 reverse_label()。
        this.bluetoothControlText = reverse_label('已广播');
      } else {
        this.bluetoothControlText = reverse_label('未启用');
      }
      if (hid.isAdvertising() || hid.isConnected()) {
        const d = hid.diag();
        const r = input.diag();
        // 布局文本每轮同步（只在真的变了才写 @State —— 每 500ms 无脑赋值会让
        // 整棵子树白刷一遍）。
        const layoutText: string = hid.layoutText();
        if (layoutText !== this.hidLayoutText) {
          this.hidLayoutText = layoutText;
        }
        // 「特征 N」这一项必须带上它的可信度：回读不可用时那个 0 是"没查到"，
        // 不是"没注册"。不加这一笔，界面就在用一个坏探针的读数骗人。
        // 另外把**回读法**一并报出来：>1 次 = 首次回读是空的、靠沉降才对上
        // （证明 addService 之后确实有"服务还查不到"的窗口，而不是服务没注册）。
        const settleNote: string = d.readbackAttempts > 1
          ? `(沉降${d.readbackAttempts}次)`
          : '';
        const charNote: string = d.readbackAvailable !== 0
          ? `特征${d.serviceChars}/${d.expectedChars}${settleNote}`
          : `特征未知(回读不可用：${d.readbackError})`;
        this.bluetoothStatus = hid.statusText() +
          // 布局要一并报出来：它是"投递落点可不可控"的直接前提，切换布局后
          // 用户回报读数时必须带上这一项，否则无法判断到底试的是哪一套。
          ` · 布局${hid.layoutText()}` +
          ` · ${charNote}` +
          ` · 报表 鼠${d.mouseReports}/键${d.keyboardReports}` +
          // 协议模式：iOS 在订阅前会写 1（Report Protocol）。它是"iOS 认下了这台
          // 设备是 HID"的握手证据 —— 只有为 1，后面的报表才有被解析的前提；
          // 若恒为 0，说明 iOS 根本没走 HID 握手，那时再怎么发都不会有反应。
          ` · 协议${d.protocolMode}` +
          // ★★ 主机侧账本（2026-09-24）：这三项是"iPhone 上到底有没有指针"的分水岭。
          //   读0 ⇒ 主机连上了却什么都没读（配对/加密/广播内容的问题，不是服务内容）；
          //   读N 订0 ⇒ 主机读到了 Report Map 却不订阅 Report 特征（描述符/加密）；
          //   订阅1 之后，才轮得到"报表投递落点"那一类问题。
          ` · 主机 读${d.hostReads} 写${d.hostWrites} 订阅${d.subscribed}` +
          (d.hostReadTally !== '' ? `(${d.hostReadTally})` : '') +
          // 应答失败数必须可见：它 >0 时"主机没来"这个结论是**不可信**的 ——
          // 我们可能收到了请求但没能回话（对端照样超时）。
          (d.respondFailures > 0 ? ` · 应答失败${d.respondFailures}` : '') +
          // 已配对台数 / 当前客户端是否命中：iOS 对 HID 要求加密链路，
          // 而鸿蒙声明不了"要求加密"，所以绑定与否只能靠这一项观察。
          (d.pairedCount >= 0 ? ` · 已配对${d.pairedCount}台${d.pairedHit !== 0 ? '(命中)' : ''}` : '') +
          (d.readbackDescUuids !== '' ? ` · 描述符${d.readbackDescUuids}` : '') +
          (d.lastHostEvent !== '' ? ` · 最近主机动作${d.lastHostEvent}` : '') +
          // 接管态：这是用户判断"鼠标放上去到底生效没有"的唯一凭据。
          (r.takeover !== 0 ? ' · ★操控中' : '') +
          (r.takeovers > 0 ? ` · 接管${r.takeovers}次` : '') +
          // rawΔ = 最近一次鼠标硬件原始计数。它就是校准灵敏度滑杆的依据：
          // 记下"在画面上横划一个来回"时这个值的累计量，再对照 iPhone 侧
          // 光标走过的距离，该调大还是调小就一目了然。
          (r.rawEvents > 0 ? ` · rawΔ ${r.rawDx},${r.rawDy}` : '') +
          // ★ 「收到多少次移动」必须与 rawΔ 分开报：rawΔ 恒为 0 时既可能是鼠标
          //   没动，也可能是事件根本没递到承接层。两者处置完全不同，混成一个
          //   读数就会把"事件层断了"看成"用户没动鼠标"。接管中而这一项为 0，
          //   就是"事件没到"的直接证据。
          (r.takeover !== 0 ? ` · 移动${r.moveEvents}` : '') +
          (r.rawUsable === 0 ? ' · 原始位移不可用(已改差分)' : '') +
          // 整条链路都走降级路径时要能一眼看出来：那说明这台设备的
          // MouseEvent 不带 rawDelta，手感上的已知缺陷（边缘卡住）都会出现。
          (r.rawFallbacks > 0 ? ` · 降级(无rawΔ)${r.rawFallbacks}次` : '') +
          // 换算基准缺失 ⇒ 差分路径一步都算不出来（与"落在黑边"是两回事）
          (r.sizeMissingDrops > 0 ? ` · 缺尺寸${r.sizeMissingDrops}` : '') +
          // 兜底承接路径被用到的次数（>0 说明主路径确实收不到事件）
          (r.dedupDrops > 0 ? ` · 去重${r.dedupDrops}` : '') +
          (d.connectCount > 0 ? ` · 连接${d.connectCount}/断开${d.disconnectCount}` : '') +
          (d.mouseDropped > 0 ? ` · 未连接丢弃${d.mouseDropped}` : '') +
          (d.notifyFailures > 0 ? ` · 发送失败${d.notifyFailures}` : '') +
          (d.notifyTimeouts > 0 ? ` · 超时${d.notifyTimeouts}` : '') +
          (r.blackBarDrops > 0 ? ` · 黑边丢弃${r.blackBarDrops}` : '') +
          (d.lastNotifyError !== '' ? ` · ${d.lastNotifyError}` : '');
        // 隐患（回读不可用 / 注册不全）要一直挂在状态里，而不是只在点击那一瞬。
        if (d.lastWarning !== '') {
          this.bluetoothStatus = `${this.bluetoothStatus} · 隐患：${d.lastWarning}`;
        }
        // rawDelta 的判定结论（含依据）也要一直挂着：它是"手感为什么不对"的答案。
        if (r.rawNote !== '') {
          this.bluetoothStatus = `${this.bluetoothStatus} · ${r.rawNote}`;
        }
      } else if (hid.errorText() !== '') {
        // 起不来的原因必须一直挂着，直到下次成功为止（不能只在点击那一瞬显示）
        this.bluetoothStatus = `蓝牙反控错误：${hid.errorText()}`;
        this.reverseShortDiag = `⚠ ${hid.errorText()}`;
      } else {
        this.bluetoothStatus = '';
        this.reverseShortDiag = '';
      }
      // ★ 短摘要：把"主机 读N 写N 订阅S + 配对命中W + 应答失败X"抽出来单
      //   独一行展示。这一行是"iPhone 端配对/订阅 vs 投递问题"的分水岭，
      //   用户一进来就该看见，不用去读 200 字的长串。
      if (hid.isAdvertising() || hid.isConnected()) {
        const dd = hid.diag();
        const shortDiag: string =
          // ★ 前缀带成熟度：这一行是"链路走到哪一步了"的读数，不是"能用"的读数。
          //   不写这一笔，`订阅1` 会被当成功劳簿上的勾。
          `反控（实验·开发中） · 主机 读${dd.hostReads} 写${dd.hostWrites} 订阅${dd.subscribed}`
          + (dd.respondFailures > 0 ? ` 应答失败${dd.respondFailures}` : '')
          + (dd.pairedCount >= 0
            ? ` · 已配对${dd.pairedCount}台${dd.pairedHit !== 0 ? '(命中)' : ''}`
            : '');
        if (shortDiag !== this.reverseShortDiag) {
          this.reverseShortDiag = shortDiag;
        }
      }
    } catch (error) {
      const failure = error as BusinessError;
      this.bluetoothStatus = `蓝牙反控状态读取异常：${failure.message}`;
    }
  }

  /**
   * 切换 HID 布局（单 Report 特征 ⇄ 5 个 Report 特征）。
   *
   * 为什么需要这个入口（见 BluetoothHidPeripheral 文件头的「HID 布局模式」）：
   * 鸿蒙的 `notifyCharacteristicChanged` 只能给 `(serviceUuid, characteristicUuid)`，
   * 没有描述符、没有特征句柄 —— 而 HOGP 的标准布局是 5 个共用 0x2A4D 的 Report
   * 特征，通知落到哪一个由协议栈决定。单特征布局（默认）是唯一让投递确定的走法。
   * 留这个开关，是为了让"到底是布局问题、还是别的问题"能靠**一次切换**直接判定，
   * 而不是继续猜。
   *
   * 代价必须说出来：切换要重建 GATT 服务 ⇒ iPhone 会断开一次，需要重新连接。
   */
  private async switch_hid_layout(): Promise<void> {
    if (this.hidLayoutSwitching) {
      return;
    }
    this.hidLayoutSwitching = true;
    try {
      const hid = BluetoothHidPeripheral.shared();
      const next: number = hid.layoutMode() === HID_LAYOUT_SINGLE
        ? HID_LAYOUT_MULTI
        : HID_LAYOUT_SINGLE;
      const restarted: boolean = await hid.setLayoutMode(next);
      this.hidLayoutText = hid.layoutText();
      if (restarted) {
        this.settingsStatus = `已切到「${hid.layoutText()}」布局并重新广播：`
          + 'iPhone 会断开一次，请在手机上重新连接后再把鼠标移到画面上试';
      } else {
        // 没重启成功（多半是没存到上下文，或 addService/广播又失败）——
        // 如实报出原因，并告诉用户下一步该做什么。
        this.settingsStatus = `已切到「${hid.layoutText()}」布局，但没能自动重启：`
          + `${hid.errorText() !== '' ? hid.errorText() : '未知原因'}`
          + '（请在下面重新点「开启蓝牙反向控制」）';
      }
      this.refresh_bluetooth_status();
    } catch (error) {
      const failure = error as BusinessError;
      this.settingsStatus = `切换 HID 布局异常：${failure.code} ${failure.message}`;
    } finally {
      this.hidLayoutSwitching = false;
    }
  }

  /**
   * 把「反控诊断」整段写进剪贴板。
   *
   * 为什么必须有这个按钮：上一轮把读数放在条带上，结果一条反馈都没收到 —— 让用户
   * 在六个短句里找数字，不如让他**一次复制**发过来。诊断文本把"输入侧 / HID 侧"
   * 两段分开写，缺哪一段就直接指向哪一段的故障面。
   *
   * ⚠️ 用 `createPlainTextData` 而不是 `createData`：后者是 **@since 24**，本工程
   *    `compileSdkVersion` 是 **6.1.0(23)** ⇒ 用了会构建失败。前者虽标了
   *    deprecated since 9，但在 23 上是可用 API（开发者工具窗口一直这么用）。
   * ⚠️ `setData` 是 Promise，链上异常必须接住：按钮驱动，抛出去会结束整个应用。
   */
  private copy_diagnosis(): void {
    try {
      const text: string = ReverseControlInput.shared().diagnosisText();
      const data: pasteboard.PasteData = pasteboard.createPlainTextData(text);
      pasteboard.getSystemPasteboard().setData(data)
        .then((): void => {
          this.settingsStatus = '反控诊断已复制到剪贴板 —— 直接粘贴发我，就能定位缺哪一段';
        })
        .catch((error: BusinessError): void => {
          this.settingsStatus = `复制诊断失败：${error.code} ${error.message}`;
        });
    } catch (error) {
      const failure = error as BusinessError;
      this.settingsStatus = `复制诊断异常：${failure.code} ${failure.message}`;
    }
  }

  /**
   * 主动向已连接的 iPhone 发起配对（等价于 iPhone 侧"配对"的另一种走法）。
   *
   * 为什么值得做个按钮：iOS 对 HID 设备要求加密链路，而鸿蒙的 `GattProperties`
   * **没有"要求加密"这一项**（无法像上游 Windows 那样用 ReadProtectionLevel 逼
   * iOS 配对）⇒ 只能靠"用户在 iPhone 上配对"或"我们从这侧发起"。后者一次点击
   * 即可验证，失败也只会如实报出来。
   */
  private async pair_with_iphone(): Promise<void> {
    try {
      const message: string = await BluetoothHidPeripheral.shared().pair_client();
      this.settingsStatus = message;
      this.refresh_bluetooth_status();
    } catch (error) {
      const failure = error as BusinessError;
      this.settingsStatus = `发起配对异常：${failure.code} ${failure.message}`;
    }
  }

  /**
   * 把"当前画面尺寸"喂给反控的坐标换算。
   *
   * 为什么必须用渲染器实测的帧尺寸、而不是界面上写的分辨率：
   * 反控要算的是"鼠标在预览区里划过一段距离 ↔ iPhone 上光标走多远"，
   * 这个换算的基准是**实际出来的那一帧**有多大（旋转、缩放、AirPlay 自适应
   * 分辨率都会改变它）。渲染器的 lastFrameWidth/Height 是唯一的第一手数据。
   */
  private sync_reverse_control_source(): void {
    try {
      const input = ReverseControlInput.shared();
      if (!input.isEnabled()) {
        return;
      }
      const size: number[] = this.source_frame_size();
      if (size[0] > 0 && size[1] > 0) {
        input.setSourceSize(size[0], size[1]);
      }
    } catch (error) {
      const failure = error as BusinessError;
      console.warn('iPhoneMirror reverse-control source sync failed:', failure.message);
    }
  }

  /**
   * 当前画面尺寸（渲染器实测的首帧/末帧），拿不到时返回 [0, 0]。
   *
   * 读取口径只此一处：反控的坐标换算与独立窗口的初始宽高比都用它。
   */
  private source_frame_size(): number[] {
    const status: AirPlayStatus | null = this.airplay;
    if (status === null || status === undefined) {
      return [0, 0];
    }
    const diag = status.previewDiag;
    if (diag === null || diag === undefined) {
      return [0, 0];
    }
    if (diag.lastFrameWidth > 0 && diag.lastFrameHeight > 0) {
      return [diag.lastFrameWidth, diag.lastFrameHeight];
    }
    return [0, 0];
  }

  /**
   * 独立窗口要用的设备名 —— 上游 `device.DisplayName`
   * （MultiDevicePreviewManager.cs:152-153 用它拼窗口标题）。
   *
   * ★ 为什么要在两个来源之间合并：上游的 SelectedDevice 是统一设备模型，有线和
   *   无线是**同一个列表**里的条目；本移植的 USB 设备列表与 AirPlay 客户端是两套
   *   完全独立的状态，所以这里显式按优先级合一次：
   *     ① 选中了 USB 设备 → 用它（用户明确选的那个，标题就该是它）；
   *     ② 否则正在经 AirPlay 出画面 → 用 AirPlayStatus.name（对端报上来的设备名）；
   *     ③ 都没有 → 空串，等价于上游的 `device is null`，调用方据此拒绝开窗。
   *
   *   注意第 ② 条要求 `clients > 0`：接收端只是开着、没有 iPhone 连上来时，
   *   没有任何画面可搬，开一个空窗口出来才是假的。
   */
  private standalone_device_name(): string {
    if (this.has_device()) {
      return this.selectedName;
    }
    const ap: AirPlayStatus | null = this.airplay;
    if (ap !== null && ap.running !== 0 && ap.clients > 0 && ap.name.length > 0) {
      return ap.name;
    }
    return '';
  }

  /**
   * 当前该套用的显示轮廓（机型外形适配）—— 上游
   * `MultiDevicePreviewManager.cs:148` 的 `DeviceCornerProfileResolver.Resolve(...)`。
   *
   * 两个入参的口径：
   *   · ProductType 取选中 USB 设备的真值（`selectedModel`）。AirPlay 拿不到
   *     ProductType（那要 lockdown 信息），留空 → 走几何兜底，正是上游
   *     "未知新设备按画面比例保守回退"那条路。
   *   · 帧尺寸优先用渲染器**实测**值；拿不到才回退上游硬编码的 1206×2622，保证
   *     "未知机型"的结论与上游一致。口径集中在 resolve_corner_profile_for_frame。
   *
   * ★ `looks_like_product_type` 那一步不能省：界面上没选设备时 `selectedModel`
   *   是占位符 `'—'`，而"非空且不认识 ⇒ 直角"是上游的既定规则，直接传进去会把
   *   机型拟合整个吃掉。
   */
  private current_corner_profile(): DeviceCornerProfile {
    const productType: string = this.current_product_type();
    const size: number[] = this.source_frame_size();
    const profile: DeviceCornerProfile =
      resolve_corner_profile_for_frame(productType, size[0], size[1]);
    log_corner_profile(profile, productType);
    return profile;
  }

  /**
   * 当前设备的 ProductType —— 但**只在它真的长得像 ProductType 时**才返回。
   *
   * 见 current_corner_profile 的注释：`selectedModel` 在"没选设备"时是占位符
   * `'—'`，那个值不能当成机型标识用。
   */
  private current_product_type(): string {
    return looks_like_product_type(this.selectedModel) ? this.selectedModel : '';
  }

  // ═══════════════════ 独立预览窗口（上游 NativePreviewWindow） ═══════════════════

  /**
   * 打开独立预览窗口。
   *
   * 上游 MainWindow.xaml.cs:5014-5041（OpenPreviewWindowAsync 的设备分支）与
   * 这里逐条对应：
   *   ① 没有选中设备 → 直接返回（原版 `if (device is null) return;`）；
   *   ② **蓝牙反控开着就先关掉**（:5028-5029 DisableBluetoothControlAsync）——
   *      反控的输入只该由"当前真正持有画面的那个窗口"承接；
   *   ③ 开窗成功后主窗口预览让位（:5035 QueueMainPreviewHostSync）。
   *
   * ★ 关于 ①：上游的 `device` 是**统一设备模型** —— 有线与无线都在同一个列表里
   *   （:5031 `device.IsWireless ? "wireless" : "wired"`），所以 AirPlay 镜像时它
   *   照样有个 SelectedDevice。本移植的设备列表只装 USB 设备，AirPlay 客户端是另
   *   一套状态（AirPlayStatus），因此这里必须显式把无线那一路补上，否则
   *   「iPhone 正在无线镜像 + 点独立窗口」会被 ① 直接挡掉。判别交给
   *   standalone_device_name()：它为空才等于上游的 `device is null`。
   *
   * 差异：原版还允许"媒体投放"分支（:5018-5024），本移植没有媒体投放模式，
   * 所以只有设备这一条路（与 Index 的其余部分一致）。
   */
  private open_standalone_window(): void {
    const ctx: common.Context | null = this.appContext;
    if (ctx === null) {
      this.settingsStatus = '打开独立预览失败：拿不到应用上下文';
      return;
    }
    const deviceName: string = this.standalone_device_name();
    if (deviceName.length === 0) {
      this.settingsStatus = this.airplay_running()
        ? '请先等 iPhone 连上并开始镜像，再打开独立窗口'
        : '请先在设备列表里选择一个设备';
      return;
    }
    // ② ★ 与上游**不同**：这里**不关**蓝牙反控（上游 :5028-5029 是关的）。
    //   上游要关，是因为 Windows 版的反控输入由"当前持有画面的那个窗口"承接，
    //   换窗口就得把通道重建一次。鸿蒙这边不需要：两个窗口都常驻输入承接层，
    //   "谁在悬停"由 ReverseControlInput 按**来源**登记（setHoverSource('main'
    //   /'standalone')），"此刻有没有画面"另由 setPictureAvailable 单独报 ——
    //   窗口切换期间那次可能的误判已经被这两个量分掉了，通道本身没必要动。
    //   关掉的代价却很实在：要经历"停广播 → 关 GATT 服务 → 重新 addService →
    //   重新广播 → iPhone 重新连接"，**而独立窗口恰恰是用户要操控手机的那个
    //   窗口** —— 在进窗那一刻把反控停掉，等于让最该工作的场景从零重来。
    //   （2026-09-22 现场：独立窗口里指针能藏、却控制不了手机。）
    const size: number[] = this.source_frame_size();
    const profile: DeviceCornerProfile = this.current_corner_profile();
    try {
      // ★ 不再传 on_closed 回调：独立窗口已经是独立 Ability，跨 Ability 调主窗口的
      //   闭包没有保证。改成由 sync_standalone_state 轮询 STANDALONE_ALIVE_KEY，
      //   发现它没了就自己执行 on_standalone_closed() —— 收尾逻辑留在主窗口。
      open_standalone_preview(ctx, deviceName, size[0], size[1], profile);
      // 立刻让预览区让位；真正的开窗失败会由 WindowServices.standalone_preview_open
      // 在下一轮 poll 里复位（open_standalone_preview 的 catch 已经把它清掉了）。
      this.standaloneOpen = true;
      this.standaloneMissingTicks = 0;
      this.standaloneSeen = false;   // 新的一轮：等 findWindow 真的见过它再开始计缺失
      // 上游 PreviewWindowOpened 只有一句「已在独立窗口打开」；这里额外摊出外形
      // 拟合的判定结果 —— 轮廓是个"看着不对但说不清哪不对"的东西，不写出来
      // 用户就无从反馈（是 ProductType 没认出来，还是几何兜底判成了直角）。
      this.settingsStatus =
        `已打开独立预览窗口 · ${describe_corner_profile(profile, this.current_product_type())}`;
    } catch (error) {
      const failure = error as BusinessError;
      this.standaloneOpen = false;
      // Strings: PreviewWindowOpenFailedFormat「打开独立预览失败：{0}」
      this.settingsStatus = `打开独立预览失败：${failure.message}`;
    }
  }

  /** 关闭独立预览窗口（把画面接回主窗口）。 */
  private close_standalone_window(): void {
    // ★ 独立窗口现在是独立 Ability，主窗口没有它的 Window 对象可关。
    //   改成写一条"请关闭"的请求：独立窗口用 @StorageLink 响应式收到后自己
    //   terminateSelf()。它的 finish() 会把 STANDALONE_ALIVE_KEY 置 false，
    //   sync_standalone_state 下一轮就会把画面接回来。
    //
    //   为什么还要留 sync_standalone_state 那条兜底：如果独立窗口已经不在了
    //   （比如被系统回收），这条请求没人接，只能靠轮询发现。
    try {
      AppStorage.setOrCreate<boolean>(STANDALONE_CLOSE_REQUEST_KEY, true);
    } catch (error) {
      const failure = error as BusinessError;
      console.warn('iPhoneMirror close standalone preview failed:', failure.message);
    }
  }

  /**
   * 独立窗口关闭后的收尾 —— 上游 MainWindow.xaml.cs:884-889
   * `OnIndependentPreviewClosed` 只做一件事：`QueueMainPreviewHostSync()`。
   *
   * ★ 这里**绝不能** stopCapture()：上游 MultiDevicePreviewManager.cs:198 写得很明白
   *   `if (_disposing || !started.Created) return;` —— **会话不是这个窗口建的，
   *   就不许停它**。本移植的会话永远归主窗口，所以关独立窗口只搬画面，不停投屏。
   */
  private on_standalone_closed(): void {
    this.standaloneOpen = false;
    this.standaloneMissingTicks = 0;
    this.standaloneSeen = false;
    // ★ 必须先清掉 attachedSurfaceId 再重挂，否则画面回不来。
    //
    //   原因：渲染器只有**一个** EGLSurface（OhosPreviewRenderer.cpp:575-589 在渲染
    //   线程里 destroy_gl() → create_gl(新 id)）。独立窗口开着的这段时间里，它挂的
    //   是**独立窗口**的 surface（StandalonePreviewWindow.on_surface_ready 调的
    //   attachPreview），而这里记的 attachedSurfaceId 仍是主窗口那个旧值 ——
    //   两者相等 ⇒ attach_main_preview() 判定"已经挂着了"直接 return，
    //   渲染器就一直对着一个已经销毁的 surface 画。表现：关掉独立窗口后
    //   主窗口预览一片黑，而且状态指标看起来"一切正常"。
    //   上游这里是无条件 QueueMainPreviewHostSync()，本移植用"清账再挂"对齐。
    // 兜底：窗口被系统直接销毁时不会走 StandalonePreviewWindow.finish()，
    // 渲染器上那个"为独立窗口算的"圆角就会留着，主窗口预览会一直顶着它。
    // 这里无条件清零一次（幂等，重复调用无副作用）。
    try {
      setPreviewCornerProfile(0, 2.0);
    } catch (error) {
      const failure = error as BusinessError;
      console.warn('iPhoneMirror reset preview corners failed:', failure.message);
    }
    this.attachedSurfaceId = '';
    this.attach_main_preview();
    this.settingsStatus = '独立窗口已关闭，预览已接回主窗口';
  }

  /**
   * 每轮 poll 同步独立窗口的状态（放在所有早退之前，与蓝牙反控同理）。
   *
   * 两件事：
   *   ① 把 WindowServices.standalone_preview_open 镜像到界面状态；
   *   ② 消化投屏设置窗口「独立窗口」按钮的请求（出参总线）。
   */
  private sync_standalone_state(): void {
    const flag: boolean = WindowServices.standalone_preview_open;

    // ★ 独立窗口是独立 Ability，主窗口这边**没有它的 Window 对象**，
    //   所以"还在不在"只能读它自己维护的存活标志（AppStorage）。
    //   （子窗口时代这里用的是 window.findWindow(STANDALONE_WINDOW_NAME)，
    //    对独立 Ability 的窗口不适用 —— findWindow 只认我们自己建过的子窗名。）
    let exists: boolean = false;
    try {
      const alive: boolean | undefined = AppStorage.get<boolean>(STANDALONE_ALIVE_KEY);
      exists = alive === true;
    } catch (error) {
      exists = false;
    }

    // 「还开着」以**标志位**为准：标志位在窗口创建之前就置位了，若用窗口对象判定，
    // 开窗那一瞬间会被误判成"没开"，占位会闪一下。
    if (this.standaloneOpen !== flag) {
      this.standaloneOpen = flag;
      // 这里**不**注销 'main' 的悬停来源：画面在不在交给 poll_status 每轮的
      // setPictureAvailable('main', … && !standaloneOpen) 判定，更准确也更稳 ——
      // 一旦在这里把来源注销掉，画面再挪回主窗口时鼠标若还停在原处，
      // 就得等用户移开再移回来才会恢复接管。
    }
    // 但「窗口不在了」必须以**窗口对象**为准：标志位还挂着 true 而窗口已经没了，
    // 说明它被别的路径销毁了，这里补上收尾，保证画面一定回得来。
    if (flag && !exists) {
      if (this.standaloneSeen) {
        this.standaloneMissingTicks += 1;
        if (this.standaloneMissingTicks >= 2) {
          WindowServices.standalone_preview_open = false;
          this.on_standalone_closed();
        }
      }
      // 还没见过窗口 → 可能只是还没创建完，不计数（见 standaloneSeen 的说明）。
    } else {
      this.standaloneMissingTicks = 0;
      if (exists) {
        this.standaloneSeen = true;
      }
    }

    // 投屏设置窗口的「独立窗口」按钮：它是子窗口，不能直接调主窗口的方法，
    // 所以走出参总线（与 start/stop 请求同一套做法）。
    try {
      const requested: boolean =
        AppStorage.get<boolean>(OUT_KEY_SEPARATE_WINDOW_REQUESTED) ?? false;
      if (requested) {
        AppStorage.setOrCreate<boolean>(OUT_KEY_SEPARATE_WINDOW_REQUESTED, false);
        if (!this.standaloneOpen) {
          this.open_standalone_window();
        }
      }
    } catch (error) {
      const failure = error as BusinessError;
      console.warn('iPhoneMirror separate-window request read failed:', failure.message);
    }
  }

  /** 原版 EnvironmentPanel（Padding 10,9,10,9，Margin 0,0,0,14）+ PreviewQuickActions。 */
  @Builder
  environment_panel() {
    Row() {
      Blank()
      // 原版 PreviewQuickActions 的六项，顺序与图标字号逐条对照。
      // 已实现：调节画面 / 蓝牙反控 / 独立窗口 / 截图 / 全屏预览。
      // 「录制与推流」是剩下的唯一未实现项，恒灰 + 点击给「敬请期待」。
      // 「调节画面」「蓝牙反控」恒可点；「独立窗口」「截图」「全屏预览」按真实条件
      // （需先有画面、且画面在主窗口而非独立窗口）决定是否可点。
      // 蓝牙反控恒可点 —— 它是一个开关，不依赖投屏状态（上游的蓝牙通道与投屏
      // 链路完全独立，三种场景都能用）。
      //
      // ★ 同理：蓝牙那条的文案（bluetoothControlText）与「独立窗口」的可用性都是
      //   状态驱动的，必须经 @Prop 下发 —— 否则蓝牙连上了这里还写着「未启用」。
      QuickBarButton({
        btnLabel: this.bluetoothControlText, iconName: 'Cursor20', iconSize: 15, usable: true,
        on_action: (): void => { this.run_quick_action('bluetooth'); },
        on_blocked: (): void => { this.block_action('bluetooth'); },
      })
      QuickBarButton({
        btnLabel: t('录制与推流'), iconName: 'VideoRecording20', iconSize: 16, usable: false,
        on_action: (): void => { this.run_quick_action('media'); },
        on_blocked: (): void => { this.block_action('media'); },
      })
      QuickBarButton({
        btnLabel: t('调节画面'), iconName: 'ImageEdit20', iconSize: 16, usable: true,
        on_action: (): void => { this.run_quick_action('image'); },
        on_blocked: (): void => { this.block_action('image'); },
      })
      QuickBarButton({
        btnLabel: t('独立窗口'), iconName: 'WindowNew20', iconSize: 14,
        usable: this.can_use_visual_tools(),
        on_action: (): void => { this.run_quick_action('window'); },
        on_blocked: (): void => { this.block_action('window'); },
      })
      QuickBarButton({
        btnLabel: '', iconName: 'Screenshot20', iconSize: 15,
        usable: this.can_use_visual_tools() && !this.standaloneOpen,
        on_action: (): void => { this.run_quick_action('screenshot'); },
        on_blocked: (): void => { this.block_action('screenshot'); },
      })
      QuickBarButton({
        btnLabel: '', iconName: 'FullScreenMaximize20', iconSize: 15,
        usable: this.can_use_visual_tools() && !this.standaloneOpen,
        on_action: (): void => { this.run_quick_action('fullscreen'); },
        on_blocked: (): void => { this.block_action('fullscreen'); },
      })
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 9, bottom: 9 })
    .backgroundColor(this.themePalette().CARD)
    .borderRadius(12)
    .border({ width: 1, color: this.themePalette().BORDER_SOFT })
    .margin({ bottom: 14 })
  }

  /**
   * 原版 WaitingForDeviceState（MainWindow.xaml:1294–1322）：
   *   Border Width=92 Height=92 CornerRadius=46
   *   Path   Width=38 Height=48 StrokeThickness=2 StrokeLineCap=Round Stretch=Uniform
   *   TextBlock FontSize=21 SemiBold  Margin="0,20,0,0"
   *   TextBlock FontSize=12           Margin="0,8,0,0"
   *
   * 这里原先是 132 / 56×71 / 26 / 24 / 13 —— 整组比原版大一圈（圆的直径多 43%）。
   * 现已按上面声明值逐条归位。
   */
  @Builder
  preview_waiting_device() {
    Column() {
      // 圆形容器用 Stack + alignContent(Center)。此前用 Column 包裹时，
      // FluentSymbol（内部是 Shape 自绘组件）在 Column 里没有被水平/垂直居中，
      // 图标会贴在圆的左上角 —— 这就是用户看到的「图标明显偏了」。
      Stack({ alignContent: Alignment.Center }) {
        FluentSymbol({
          iconName: 'DeviceOutline',
          // 原版这个轮廓不是 SymbolIcon 而是裸 Path，盒子就是 Width=38 Height=48；
          // 而 DeviceOutline 字形的 viewBox 恰好也是 38×48（坐标与上游 Data 逐字相同）
          // ⇒ 盒子取 38×48 即与原版一致。（一处 8% 的差异见文件末尾说明。）
          iconSize: 38,
          iconHeight: 48,
          iconColor: this.themePalette().PREVIEW_MUTED_TEXT,
          iconOutline: true,
          iconOutlineWidth: 2,
        })
          // FluentSymbol 内部根节点是 Shape（自绘组件），父容器对它的测量值可能为 0，
          // 导致居中失效、图标贴左上角。这里显式给组件在父布局里的尺寸，保证可测量。
          .width(38)
          .height(48)
      }
      .width(92)
      .height(92)
      .borderRadius(46)
      .backgroundColor(this.themePalette().PREVIEW_PANEL_ALT)
      .border({ width: 1, color: this.themePalette().PREVIEW_BORDER })

      Text('等待设备连接')                                // Strings: StatusWaitingDevice
        .fontSize(21)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.themePalette().PREVIEW_TEXT)
        .margin({ top: 20 })
      Text('连接后请保持 Apple 设备解锁')                 // Strings: KeepUnlocked
        .fontSize(12)
        .fontColor(this.themePalette().PREVIEW_MUTED_TEXT)
        .textAlign(TextAlign.Center)
        .margin({ top: 8 })
      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(11)
          .fontColor(this.themePalette().PREVIEW_MUTED_TEXT)
          .textAlign(TextAlign.Center)
          .margin({ top: 6 })
          .constraintSize({ maxWidth: 440 })
      }
      // 开发者模式（调试入口）：连点版本号 7 次开启后，下面这些有线链路诊断才会显示。
      if (this.devMode) {
      // 有线链路的原生诊断（认领接口 / 厂商 0x52 / 重枚举 / 端点）。
      // 必须内联 Text：@Builder 的参数按值传递，走方法参数的话状态变化不会刷新。
      if (this.usbDiagnostic.length > 0) {
        Text(this.usbDiagnostic.length > 220
          ? `原生：${this.usbDiagnostic.substring(0, 220)}…`
          : `原生：${this.usbDiagnostic}`)
          .fontSize(10)
          .fontColor(this.themePalette().PREVIEW_MUTED_TEXT)
          .textAlign(TextAlign.Center)
          .margin({ top: 8 })
          .constraintSize({ maxWidth: 460 })
      }
      // 系统侧 USB 视图（不经 DDK）。放在最前面：它是"最外层"的证据 ——
      // 系统自己都没看到 Apple 设备时，下面几条驱动/权限诊断都无从谈起。
      if (this.usbHostSummary.length > 0) {
        Text(this.usbHostSummary.length > 200
          ? `系统 USB：${this.usbHostSummary.substring(0, 200)}…`
          : `系统 USB：${this.usbHostSummary}`)
          .fontSize(10)
          .fontColor(this.usbHostOk && this.usbHostAppleCount > 0
            ? this.themePalette().PREVIEW_MUTED_TEXT : this.themePalette().WARNING)
          .textAlign(TextAlign.Center)
          .margin({ top: 8 })
          .constraintSize({ maxWidth: 460 })
      }
      // USB 权限授予状态。紧挨着环境诊断放：环境诊断那条会报出 OH_Usb_Init 的
      // **具体返回码**（201 / 27400002），这一条正好把"201 那一半"钉死 ——
      // 两行合起来读，"权限根本没给"与"DDK 用错了地方"就分得开，不必再猜。
      if (this.usbPermissionNote.length > 0) {
        Text(`USB 权限：${this.usbPermissionNote}`)
          .fontSize(10)
          // 查询本身失败（ok=false）属于"不知道"，用中性色；查到了且已授予算正常；
          // 只有"明确未授予"才是真问题 —— 把不知道标成警告会让警告失去意义。
          .fontColor(!this.usbPermissionOk
            ? this.themePalette().PREVIEW_MUTED_TEXT
            : (this.usbPermissionGranted
              ? this.themePalette().PREVIEW_MUTED_TEXT : this.themePalette().WARNING))
          .textAlign(TextAlign.Center)
          .margin({ top: 8 })
          .constraintSize({ maxWidth: 460 })
      }
      // 环境诊断：Core 的 ohos_probe::probe() 原话。它把"看不到设备"分成互斥的
      // 几种结论（DDK 权限没放行 / 驱动配置里没有 Apple VID / DDK 正常但确实没有
      // 设备）。放在这里是因为"等待设备连接"正是用户遇到识别不到时盯着的那一屏，
      // 而在此之前这条结论只存在于进程内，界面上根本看不到。
      // 同样必须内联 Text：@Builder 的参数按值传递，状态变化不会刷新。
      if (this.environmentDiagnostic.length > 0) {
        Text(this.environmentDiagnostic.length > 260
          ? `环境诊断：${this.environmentDiagnostic.substring(0, 260)}…`
          : `环境诊断：${this.environmentDiagnostic}`)
          .fontSize(10)
          .fontColor(this.environmentStatus === 0
            ? this.themePalette().PREVIEW_MUTED_TEXT : this.themePalette().WARNING)
          .textAlign(TextAlign.Center)
          .margin({ top: 8 })
          .constraintSize({ maxWidth: 460 })
      }
      // 外部设备驱动的绑定状态。放在驱动扩展状态之前：绑定是"扩展能不能起来"的
      // 直接原因（懒加载驱动只有客户端 bind 才会启动），而下面那条只说明
      // "有没有收到扩展的上报"。
      if (this.usbDriverBindNote.length > 0) {
        Text(`驱动绑定：${this.usbDriverBindNote}`)
          .fontSize(10)
          // 只有"系统看得到 Apple 设备、却绑不上驱动"才是真异常。
          .fontColor(this.usbDriverBindOk || this.usbHostAppleCount === 0
            ? this.themePalette().PREVIEW_MUTED_TEXT : this.themePalette().WARNING)
          .textAlign(TextAlign.Center)
          .margin({ top: 8 })
          .constraintSize({ maxWidth: 460 })
      }
      // 驱动扩展状态。它是鸿蒙这条链路上最不直观的一环：枚举结果被驱动配置里的
      // vid 过滤，而那份配置要等扩展被 bind 之后才生效 —— 系统到底有没有按
      // VID 0x05AC 把我们拉起来，只有这里能看出来。
      if (this.usbDriverNote.length > 0) {
        Text(this.usbDriverNote.length > 220
          ? `USB 驱动：${this.usbDriverNote.substring(0, 220)}…`
          : `USB 驱动：${this.usbDriverNote}`)
          .fontSize(10)
          // 只有「系统明明看得到 Apple 设备、驱动扩展却没被拉起」才是真异常。
          // 一根线都没插的时候扩展本来就不该在，标成警告只会让警告失去意义。
          .fontColor(this.usbDriverReady || this.usbHostAppleCount === 0
            ? this.themePalette().PREVIEW_MUTED_TEXT : this.themePalette().WARNING)
          .textAlign(TextAlign.Center)
          .margin({ top: 8 })
          .constraintSize({ maxWidth: 460 })
      }
      // 子窗口（关于 / 高级设置 / 输出…）打开失败的原因。
      // 与上一行同理：子窗口失败只留 hilog，读不到，必须回传到主界面。
      if (this.windowError.length > 0) {
        Text(this.windowError.length > 200
          ? `窗口：${this.windowError.substring(0, 200)}…`
          : `窗口：${this.windowError}`)
          .fontSize(10)
          .fontColor(this.themePalette().WARNING)
          .textAlign(TextAlign.Center)
          .margin({ top: 8 })
          .constraintSize({ maxWidth: 460 })
      }
      }
    }
    .constraintSize({ maxWidth: 440 })
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /** 原版 ReadyToMirrorState：84×126 手机外框（圆角 12、边框 2、顶部 30×4 横条）。 */
  @Builder
  preview_ready_to_mirror() {
    Column() {
      // 原版是 Grid + VerticalAlignment="Top" Margin="0,8,0,0" 的横条，
      // 与 Grid 居中显示的 SelectedConnection。这里用 Stack 叠加：
      // 横条放在铺满的 Column 里顶部居中，文字单独居中。
      Stack() {
        Text(this.selectedConnection)                   // SelectedConnection
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.themePalette().PREVIEW_MUTED_TEXT)

        Column() {
          Column()
            .width(30)
            .height(4)
            .borderRadius(2)
            .backgroundColor(this.themePalette().PREVIEW_BORDER)
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ top: 8 })
      }
      .width(84)
      .height(126)
      .borderRadius(12)
      .border({ width: 2, color: this.themePalette().PREVIEW_BORDER })

      Text(this.selectedName)                           // SelectedName
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.themePalette().PREVIEW_TEXT)
        .textAlign(TextAlign.Center)
        .margin({ top: 20 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.capture_status_text())                  // CaptureStatus
        .fontSize(12)
        .fontColor(this.themePalette().PREVIEW_MUTED_TEXT)
        .textAlign(TextAlign.Center)
        .margin({ top: 8 })
    }
    .constraintSize({ maxWidth: 440 })
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // ═══════════ 反向控制：预览区输入事件 → BLE HID ═══════════

  /**
   * 预览区尺寸变化 → 交给坐标换算。
   *
   * 尺寸单位是 vp（ArkUI 事件的 x/y 也是 vp，同一把尺子），所以这里不做 px 换算：
   * 黑边比例与绝对单位无关。真正需要物理口径的是"源帧多大"，那个由渲染器实测
   * 回传（见 sync_reverse_control_source）。
   */
  private on_preview_area_change(area: Area): void {
    try {
      // 用 length_to_vp 而不是 Number()：Area 的宽高是 Length，允许是
      // "402.00vp" 这样的字符串，Number() 会给 NaN，被守卫挡掉之后画面区
      // 尺寸就永远停在 0 —— 那是"接管了却一步都送不出去"的静默成因之一。
      const width = ReverseControlInput.length_to_vp(area.width);
      const height = ReverseControlInput.length_to_vp(area.height);
      if (width > 0 && height > 0) {
        ReverseControlInput.shared().setSurfaceSize('main', width, height);
      }
    } catch (error) {
      const failure = error as BusinessError;
      console.warn('iPhoneMirror preview area change failed:', failure.message);
    }
  }

  /**
   * 鼠标 → 反向控制。
   *
   * 翻译本身在 ReverseControlInput.handle_mouse 里（主窗口与独立窗口共用一份：
   * 移动优先走 rawDelta，取不到才退回绝对坐标差分）。这里只做窗口侧那件事 ——
   * 把事件交给单例，于是两个窗口不会各写一份而慢慢走偏。
   */
  private on_preview_mouse(event: MouseEvent): void {
    ReverseControlInput.shared().handle_mouse(event);
  }

  /** 滚轮：ArkUI 把滚轮归到轴事件（onAxisEvent），不是 onMouse。 */
  private on_preview_axis(event: AxisEvent): void {
    ReverseControlInput.shared().handle_axis(event);
  }

  /** 键盘：鸿蒙 KeyCode → HID usage 的映射在 ReverseControlInput 里。 */
  private on_preview_key(event: KeyEvent): void {
    ReverseControlInput.shared().handle_key(event);
  }

  /**
   * 让输入层拿到焦点（不拿焦点就收不到键盘事件）。
   *
   * ★ 两个容易踩的点：
   *   ① `UIContext.getFocusController().requestFocus(key)` 的返回值是 **`void`**
   *      —— 没有"成功/失败"可读，所以**不能**靠它判断"到底拿到没有"；焦点的真值
   *      由组件自己的 `onFocus` / `onBlur` 回报（挂在那层透明承接层上，见预览区）。
   *   ② 参数是组件的**可寻址标识**，对应组件上的 `.id()`。老写法 `.key()` 在新版
   *      SDK 上已不再承担这个作用（真构建警告 "`key` can only be used for testing
   *      directories"）⇒ 用 `.key()` 的话这个调用会永远找不到组件、键盘静默哑掉。
   */
  private focus_preview_input(): void {
    try {
      this.getUIContext().getFocusController().requestFocus('preview_input');
    } catch (error) {
      ReverseControlInput.shared().noteKeyboardFocus(false);
      const failure = error as BusinessError;
      // 这个函数会被每轮 poll_status 再叫一次（焦点自愈），同一条失败原因就别
      // 每 500ms 重写一遍状态 —— 状态没变却反复赋值会让界面白刷。
      const message: string = `预览区获取焦点失败：${failure.message}`;
      if (this.bluetoothStatus !== message) {
        this.bluetoothStatus = message;
      }
    }
  }

  /**
   * 独立窗口占位 —— 上游 `IndependentPreviewSurface`（MainWindow.xaml:1471-1495）。
   *
   * 逐项对照：整块铺满预览区、底色 PreviewChromeBrush、Panel.ZIndex=3、
   * **IsHitTestVisible="False"**（不拦点击）；里面是居中的一列（MaxWidth 440）：
   *   · 84×84 的框，CornerRadius=42（正圆），底色 PreviewPanelAltBrush，
   *     边框 1px PreviewBorderBrush；
   *   · 里面 WindowNew20，FontSize 34，前景 PreviewTextBrush；
   *   · 下面 `IndependentPreviewOpened`「已在独立窗口打开」，
   *     FontSize 21 / SemiBold / Wrap / Margin 0,20,0,0。
   *
   * 上游这里没有按钮（关闭要在独立窗口自己身上做），这里照做 —— 不给多余的入口。
   */
  @Builder
  preview_in_standalone() {
    Column() {
      Column() {
        Stack({ alignContent: Alignment.Center }) {
          FluentSymbol({
            iconName: 'WindowNew20',
            iconSize: 34,
            iconColor: this.themePalette().PREVIEW_TEXT,
          })
        }
        .width(84)
        .height(84)
        .borderRadius(42)
        .backgroundColor(this.themePalette().PREVIEW_PANEL_ALT)
        .border({ width: 1, color: this.themePalette().PREVIEW_BORDER })

        // Strings: IndependentPreviewOpened
        Text('已在独立窗口打开')
          .fontSize(21)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.themePalette().PREVIEW_TEXT)
          .textAlign(TextAlign.Center)
          .width('100%')
          .margin({ top: 20 });

        // 独立窗口报上来的异常说明。它自己那条栏只有窗口宽度的 8% 高，写不下整句，
        // 只放得下 4~6 个字的短徽标 —— 完整原因必须在这里落地，否则故障就只剩
        // 一个"看不懂的短词"（本工程纪律：失败必须能被看见，且要看得懂）。
        if (this.standaloneChromeNotice.length > 0) {
          Text(this.standaloneChromeNotice)
            .fontSize(12)
            .fontColor(this.themePalette().WARNING)
            .textAlign(TextAlign.Center)
            .width('100%')
            .margin({ top: 12 });
        }
        if (this.standaloneNotice.length > 0) {
          Text(this.standaloneNotice)
            .fontSize(12)
            .fontColor(this.themePalette().WARNING)
            .textAlign(TextAlign.Center)
            .width('100%')
            .margin({ top: 8 });
        }
      }
      .constraintSize({ maxWidth: 440 })
      .alignItems(HorizontalAlign.Center);
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.themePalette().PREVIEW_CHROME);
  }

  /** 原版 PreviewPanel：圆角 16、边框 1、ClipToBounds，内含多层状态。 */
  @Builder
  preview_area() {
    Stack() {
      // 预览画布：Core 经 NAPI 拿到 surface 后用 EGL + GLES 渲染 NV12
      XComponent({
        id: 'preview',
        type: XComponentType.SURFACE,
        controller: this.xcController,
      })
        .onLoad((): void => {
          this.on_surface_ready();
        })
        .width('100%')
        .height('100%')

      // ── 反向控制的输入承接层 ──────────────────────────────────────────
      // 一层**透明**的兄弟节点，且**常驻**（不再随开关增删）。
      //
      // 为什么不直接往 XComponent 上挂事件：XComponent(SURFACE) 的 surface 交给
      // 原生渲染器直接消费，通用指针事件投递到它上面并不保证稳定；铺一层透明
      // 兄弟节点是确定的做法，顺便还能用 onAreaChange 拿到预览区的真实尺寸 ——
      // 坐标换算需要它（黑边位置就是按控件尺寸算出来的）。
      //
      // ★ 为什么必须常驻：接管由 onHover 触发，而 onHover 只有组件**已经存在**
      //   时才收得到 —— 挂成 `if (bluetoothOn)` 的话，鼠标移上来的那一刻这一层
      //   还不存在，事件根本无人承接，"悬停即操控"就永远等不到第一次悬停
      //   （只能靠先点一下把它创建出来，那又回到要手动操作的老路）。
      //   常驻之后：未接管时它只是一层透明的、不转发任何东西的普通节点。
      //   是否真的转发由 ReverseControlInput 的接管态决定，不看这一层在不在。
      Column()
        .id('preview_input')
        .focusable(true)
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        // 焦点的**真值**由组件自己报：UIContext 的 FocusController.requestFocus()
        // 返回 void（没有成功/失败可读），所以"接管了但键盘是哑的"这件事只能靠
        // onFocus/onBlur 落到账本里（requestFocus 用的 'preview_input' 正是这里的
        // `.id()` —— 老写法 `.key()` 在新版 SDK 上已不再作为可寻址的组件标识，
        // 真构建会警告 "`key` can only be used for testing directories"）。
        .onFocus((): void => {
          ReverseControlInput.shared().noteKeyboardFocus(true);
        })
        .onBlur((): void => {
          ReverseControlInput.shared().noteKeyboardFocus(false);
        })
        .onAreaChange((_oldArea: Area, newArea: Area): void => {
          this.on_preview_area_change(newArea);
        })
        .onHover((isHover: boolean): void => {
          this.on_preview_hover(isHover);
        })
        .onMouse((event: MouseEvent): void => {
          this.on_preview_mouse(event);
        })
        .onAxisEvent((event: AxisEvent): void => {
          this.on_preview_axis(event);
        })
        .onKeyEvent((event: KeyEvent): void => {
          this.on_preview_key(event);
        })
        .onClick((): void => {
          // 点一下把焦点交给这一层：不拿焦点就收不到键盘事件（原版靠
          // GetForegroundWindow 判定，鸿蒙这边靠焦点）。鼠标不需要这一步，
          // 所以只在这里拿焦点，不在 onHover 里抢。
          this.focus_preview_input();
        })

      // 非投屏态时盖住画布：未选设备 → 等待态；已选设备 → 就绪态（与原版两个状态的
      // SelectedDevice 条件一致）
      //
      // AirPlay 镜像中也要让开：它不经 USB 采集状态机，只看 is_streaming() 的话
      // iPhone 连上后画面会被"等待设备"盖住（详见 airplay_mirroring 的注释）。
      if (!this.is_streaming() && !this.airplay_mirroring()) {
        Column() {
          if (this.has_device()) {
            this.preview_ready_to_mirror()
          } else {
            this.preview_waiting_device()
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.themePalette().PREVIEW_CHROME)
      }

      // 独立预览窗口开着时：主窗口预览让位，显示占位。
      //
      // 上游对应 IndependentPreviewSurface + `MainPreviewHost.SetPresentationVisible(false)`
      // （MainWindow.xaml.cs:5984-5990），注释点明原因：
      //   "HwndHost owns native airspace and cannot be covered by the WPF independent-
      //    window notice. Collapsing the host removes that child HWND from composition."
      // 本移植不需要 Collapsed 那一步：渲染器同一时刻只有**一个** EGLSurface，
      // 独立窗口 onLoad 时已经把 surface 换成它自己的了，主窗口这个 XComponent
      // 此刻本来就是空的 —— 这里盖一层不底板等价于上游的 Collapsed。
      //
      // 放在 Stack 的**最后**（等同于上游的 Panel.ZIndex=3）：它必须压在
      // 「等待设备 / 就绪」那层之上，否则没在投屏时占位会被那两个状态遮住。
      if (this.standaloneOpen) {
        this.preview_in_standalone()
      }
    }
    .width('100%')
    .layoutWeight(1)
    .backgroundColor(this.themePalette().PREVIEW_CHROME)
    .borderRadius(16)
    .border({ width: 1, color: this.themePalette().BORDER })
    .clip(true)
    // ── 反向控制的**兜底**承接（与上面那层透明承接层双保险） ────────────────
    // 这里再在画面区**容器**上挂一份接口。为什么容器也值得挂：
    //   · 容器与承接层几何完全重合（承接层是 100%×100% 的子节点）⇒ 两者的局部
    //     坐标一致，转发语义一字不差；
    //   · 但它是"有子节点的容器"，属于命中测试里最不会漏的一类节点。万一某版本
    //     把"透明的空容器"不当鼠标命中目标，事件仍会在容器这一层被接住
    //     （鼠标事件沿命中路径冒泡 —— MouseEvent 上存在 stopPropagation 即证明）。
    // 同一次事件被两处各收一次时，handle_mouse 按事件指纹去重，不会发两遍；
    // 去重次数进诊断（dedupDrops），所以这条兜底路径有没有在被用，是看得见的。
    .onMouse((event: MouseEvent): void => {
      this.on_preview_mouse(event);
    })
    .onAxisEvent((event: AxisEvent): void => {
      this.on_preview_axis(event);
    })
  }

  // ═══════════════════════════ StatsPanel ═══════════════════════════

  // stat_cell 已改为模块级的 StatCell 组件（见文件开头），原因是 @Builder 的
  // 按值传参不会动态刷新 —— 四格统计会冻在首帧。

  @Builder
  stats_panel() {
    Column() {
      // 解码器实际状态行
      Row() {
        Circle({ width: 6, height: 6 })
          .fill(this.is_streaming() || this.airplay_mirroring()
            ? this.themePalette().STATUS_APPLIED : this.themePalette().WARNING)
        Text(this.decode_status_text())
          .fontSize(11)
          .fontColor(this.themePalette().MUTED_TEXT)
          .margin({ left: 8 })
          .layoutWeight(1)
          // 4 行：黑屏排查时这一行要同时承载推帧、配置、SPS、渲染四段信息，
          // 2 行会把最关键的渲染段截掉。
          .maxLines(4)
      }
      .width('100%')
      .padding({ left: 13, right: 13, top: 10, bottom: 10 })

      Divider().color(this.themePalette().CONTROL_DIVIDER)

      // 四格统计：分辨率 / 帧率 / 延迟 / 音频（原版顺序不可改）
      // ★ 三个参数（label/value/detail）都是状态驱动的（值来自 this.capture /
      //   AirPlay 状态），必须用 StatCell 组件经 @Prop 下发 —— 写成 @Builder 参数
      //   的话这四格会永远停在首帧的「—」，看起来像"统计功能坏了"。
      Row() {
        StatCell({
          cellLabel: t('分辨率'), cellValue: this.resolution_value(),
          cellDetail: this.target_resolution_text(),
        })
        Divider().vertical(true).height(34).color(this.themePalette().CONTROL_DIVIDER)
        StatCell({
          cellLabel: t('帧率'), cellValue: this.fps_value(),
          cellDetail: this.target_fps_text(),
        })
        Divider().vertical(true).height(34).color(this.themePalette().CONTROL_DIVIDER)
        StatCell({ cellLabel: t('延迟'), cellValue: this.latency_value(), cellDetail: t('端到端') })
        Divider().vertical(true).height(34).color(this.themePalette().CONTROL_DIVIDER)
        StatCell({ cellLabel: t('音频'), cellValue: this.audio_value(), cellDetail: '48 kHz PCM' })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .workspace_card(this.themePalette())
    .margin({ top: 14 })
  }

  @Builder
  center_panel() {
    Column() {
      this.environment_panel()
      this.preview_area()
      this.stats_panel()
    }
    .layoutWeight(1)
    .height('100%')
  }

  // ═══════════════════════════ ControlPanel ═══════════════════════════

  @Builder
  section_title(title: string, trailing: string) {
    Row() {
      Text(title).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.themePalette().TEXT)
      Blank()
      if (trailing.length > 0) {
        Text(trailing).fontSize(10).fontColor(this.themePalette().SUCCESS)
      }
    }
    .width('100%')
  }

  @Builder
  field_label(text: string) {
    Text(text)
      .fontSize(11)
      .fontColor(this.themePalette().MUTED_TEXT)
      .width('100%')
      .margin({ top: 10, bottom: 5 })
  }

  @Builder
  hint_text(text: string) {
    Text(text)
      .fontSize(9)
      .fontColor(this.themePalette().MUTED_TEXT)
      .margin({ top: 6 })
      .width('100%')
  }

  @Builder
  control_panel() {
    Column() {
      Row() {
        Text('投屏设置')                                  // Strings: ControlTitle
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.themePalette().TEXT)
        Blank()
        Row() {
          FluentSymbol({ iconName: 'Dismiss20', iconSize: 16, iconColor: this.themePalette().MUTED_TEXT })
        }
        .width(32)
        .height(32)
        .justifyContent(FlexAlign.Center)
        .borderRadius(6)
        .hoverEffect(HoverEffect.Highlight)
        .onClick((): void => {
          this.showControlPanel = false;
        })
      }
      .width('100%')
      .margin({ bottom: 12 })

      Scroll() {
        Column() {
          // ── 卡片 1：无线 AirPlay ──
          Column() {
            this.section_title('无线 AirPlay', '常驻')    // Strings: WirelessReceiverTitle + WirelessServiceAlwaysOn
            this.field_label('连接分辨率')                // Strings: WirelessResolutionLabel
            Select(WIRELESS_PROFILE_OPTIONS)
              .optionFontColor(this.themePalette().TEXT)
              .selectedOptionFontColor(this.themePalette().TEXT)
              .selected(this.wirelessProfile)
              .value(WIRELESS_PROFILE_LABELS[this.wirelessProfile])
              .width('100%')
              .fontColor(this.themePalette().TEXT)
              .onSelect((index: number): void => {
                this.wirelessProfile = index;
              })
            // Strings: WirelessResolutionHelp
            this.hint_text('应用后将重新声明 AirPlay 接收能力；弱网请选择 720p 或 540p。')

            Row() {
              TextInput({ text: this.wirelessName, placeholder: '接收端名称' })
                .fontSize(12)
                .fontColor(this.themePalette().TEXT)
                .placeholderColor(this.themePalette().MUTED_TEXT)
                .height(34)
                .layoutWeight(1)
                .onChange((value: string): void => {
                  this.wirelessName = value;
                })
              // 正在运行时按钮变成「停止」：接收端只有一个，改名字必须先停再起。
              Text(this.airplay_running() ? '停止' : '应用')  // Strings: ApplyWirelessSettings / StopWirelessReceiver
                .fontSize(12)
                .fontColor(this.themePalette().TEXT)
                .textAlign(TextAlign.Center)
                .width(60)
                .height(34)
                .borderRadius(6)
                .backgroundColor(this.themePalette().CONTROL_FILL)
                .margin({ left: 8 })
                .onClick((): void => {
                  this.apply_wireless();
                })
            }
            .width('100%')
            .margin({ top: 10 })

            // ⚠️ 这里**必须内联 Text**，不能写成 this.hint_text(this.wireless_applied_text())：
            // @Builder 的参数是「按值传递」，状态变量变化不会刷新 builder 内部的 Text
            // （ArkUI 明确规定：按值传参时状态变量的改变不引起 @Builder 内的 UI 刷新）。
            // 实测症状就是这个状态行永远停在首帧的「接收端状态：正在读取…」，
            // 而同一张卡片里内联的「应用/停止」按钮却能正常跟着状态变——即此坑。
            Text(this.wireless_applied_text())
              .fontSize(9)
              .fontColor(this.themePalette().MUTED_TEXT)
              .margin({ top: 6 })
              .width('100%')

            // 原生层最后一条消息（协议库日志 / mDNS 失败原因）。接收端在跑、
            // 但 iPhone 搜不到时，这行能直接区分"卡在广播"还是"卡在协议栈"。
            if (this.airplay_verbose().length > 0) {
              Text(this.airplay_verbose())
                .fontSize(9)
                .fontColor(this.themePalette().MUTED_TEXT)
                .margin({ top: 3 })
                .width('100%')
            }

            // 发现层诊断（宣告成败 / 出向组播网卡 / 是谁在问我们）。
            // 必须内联 Text 而不是 @Builder：状态驱动的文本过 @Builder 参数不刷新。
            if (this.airplay_diagnostics().length > 0) {
              Text(this.airplay_diagnostics())
                .fontSize(9)
                .fontColor(this.themePalette().MUTED_TEXT)
                .margin({ top: 3 })
                .width('100%')
            }
          }
          .control_card(this.themePalette())

          // ── 卡片 2：有线投屏协议 ──
          Column() {
            this.section_title('有线投屏协议', '')        // Strings: UsbProjectionModeTitle
            Row() {
              // 原版 ListBox ItemsPanel=UniformGrid Rows=1 Columns=3，
              // 因此三项等宽、不可伸缩；UsbModeTabItem 的 Margin=2 由每项自己带。
              ForEach(USB_PROJECTION_MODES, (option: UsbProjectionModeOption, index: number): void => {
                Stack({ alignContent: Alignment.Center }) {
                  // 原版 TextBlock：FontSize 9 SemiBold 居中换行，Margin="0,0,20,0"
                  Text(option.label)              // Label（UsbModeDemoLabel / AirPlay / Aisi）
                    .fontSize(9)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.usbMode === index
                      ? this.themePalette().ON_ACCENT : this.themePalette().MUTED_TEXT)
                    .textAlign(TextAlign.Center)
                    .width('100%')
                    .padding({ left: 2, right: USB_MODE_LABEL_RIGHT_MARGIN })

                  // 原版 OnUsbProjectionModeInfoClick：
                  //   new UsbProjectionModeInfoWindow(option) { Owner = this }.ShowDialog();
                  // 即把**该项**（含 Advantage/Disadvantage/Notice）交给信息窗口。
                  Row() {
                    Row() {
                      Text('!')                   // 原版 UsbModeInfoButton 的 TextBlock
                        .fontSize(11)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(this.themePalette().MUTED_TEXT)
                    }
                    .width(USB_MODE_INFO_BUTTON_SIZE)
                    .height(USB_MODE_INFO_BUTTON_SIZE)
                    .borderRadius(USB_MODE_INFO_BUTTON_RADIUS)
                    .backgroundColor(this.themePalette().CONTROL_FILL)
                    .border({ width: 1, color: this.themePalette().MUTED_TEXT })
                    .justifyContent(FlexAlign.Center)
                    .alignItems(VerticalAlign.Center)
                    .hoverEffect(HoverEffect.Highlight)
                    .onClick((): void => {
                      this.launch_subwindow((ctx: common.Context): void => {
                        open_usb_projection_mode_info(ctx, option.mode);
                      });
                    })
                  }
                  .width('100%')
                  .justifyContent(FlexAlign.End)
                  .padding({ right: 3 })
                }
                .layoutWeight(1)
                .padding({ left: 7, right: 7, top: 6, bottom: 6 })
                .constraintSize({ minHeight: 38 })
                .borderRadius(USB_MODE_ITEM_CORNER)
                .border({
                  width: 1,
                  color: this.usbMode === index ? this.themePalette().ACCENT : Color.Transparent,
                })
                .backgroundColor(this.usbMode === index
                  ? this.themePalette().ACCENT : Color.Transparent)
                .margin(USB_MODE_ITEM_MARGIN)
                .hoverEffect(HoverEffect.Highlight)
                .onClick((): void => {
                  // 原版 SelectedUsbProjectionMode setter（MainViewModel.cs:903-928）：
                  //   选中项相同、或没有设备 ⇒ 直接返回；否则记下选择，
                  //   若该设备已经有会话（Handle != 0），提示"正在按新模式重新连接"
                  //   并重启会话 —— 因为协议模式是在建会话时一次性下发的，改不了活动会话。
                  if (this.usbMode === index || this.selectedUdid.length === 0) {
                    return;
                  }
                  this.usbMode = index;
                  // Strings: UsbProjectionModeSelectedFormat
                  this.settingsStatus = `已选择：${option.label}`;
                  if (this.has_capture_session()) {
                    // Strings: UsbProjectionModeRestarting
                    this.settingsStatus = '正在按新模式重新连接当前有线设备...';
                    // 单会话 ABI 必须先停稳再起：这里只登记目标模式，
                    // 等 poll_status 看到 Stopped(6) 再按新协议重新开始（见 poll_status）。
                    this.pendingRestartMode = this.usbMode;
                    if (this.stop() !== 0) {
                      // 停都停不下来，就别把"重启"挂在那儿等着某次正常停止后突然冒出来。
                      this.pendingRestartMode = -1;
                    }
                  }
                })
              }, (option: UsbProjectionModeOption): string => option.label)
            }
            .width('100%')
            .padding(2)
            .margin({ top: 9 })
            .backgroundColor(this.themePalette().CONTROL_FILL)
            .borderRadius(10)
            .border({ width: 1, color: this.themePalette().BORDER })

            this.hint_text('仅应用于当前选中的有线设备。')  // Strings: UsbProjectionPerDeviceHint
          }
          .control_card(this.themePalette())

          // ── 卡片 3：画面与声音 ──
          Column() {
            this.section_title('画面与声音', '')          // Strings: ImageAndSound
            // Strings: RenderLimitHelp（Windows → 本地，见文件头替换清单）
            this.hint_text('只限制本地渲染；不会改变来源分辨率，也不会强制 iOS 固定输出帧率')

            this.field_label('渲染分辨率上限')            // Strings: RenderResolutionLimit
            Select(RESOLUTION_PRESETS)
              .optionFontColor(this.themePalette().TEXT)
              .selectedOptionFontColor(this.themePalette().TEXT)
              .selected(this.resolutionPreset)
              .value(RESOLUTION_PRESETS[this.resolutionPreset].value)
              .width('100%')
              .fontColor(this.themePalette().TEXT)
              .onSelect((index: number): void => {
                this.resolutionPreset = index;
              })

            this.field_label('本地渲染帧率上限')          // Strings: TargetFrameRate
            Select(FRAME_RATE_OPTIONS)
              .optionFontColor(this.themePalette().TEXT)
              .selectedOptionFontColor(this.themePalette().TEXT)
              .selected(this.frameRateIndex)
              .value(FRAME_RATE_LABELS[this.frameRateIndex])
              .width('100%')
              .fontColor(this.themePalette().TEXT)
              .onSelect((index: number): void => {
                this.frameRateIndex = index;
              })

            this.field_label('解码器')                    // Strings: DecoderPreferenceLabel
            Select(DECODER_PREFERENCE_OPTIONS)
              .optionFontColor(this.themePalette().TEXT)
              .selectedOptionFontColor(this.themePalette().TEXT)
              .selected(this.decoderPreference)
              .value(DECODER_PREFERENCE_LABELS[this.decoderPreference])
              .width('100%')
              .fontColor(this.themePalette().TEXT)
              .onSelect((index: number): void => {
                this.decoderPreference = index;
              })

            // Strings: VideoPipelinePreferenceHelp（D3D → 鸿蒙，见文件头替换清单）
            this.hint_text('软件兼容会关闭视频解码硬件加速，但鸿蒙预览仍会使用 GPU。解码器切换通常在下一关键帧生效。')

            Row() {
              Column() {
                Text('应用画面设置')                      // Strings: ApplyVideoSettings
                  .fontSize(13)
                  .fontColor(this.themePalette().TEXT)
                  .textAlign(TextAlign.Center)
                  .width('100%')
                  .height(34)
                  .borderRadius(8)
                  .backgroundColor(this.themePalette().CONTROL_FILL)
                  .onClick((): void => {
                    // 原版 ApplyVideoSettingsCommand：会话活着就立即应用，否则留给下次开始。
                    // im_set_video_preferences 正是这个语义（CoreApi.cpp:1303 会同时改
                    // 活动会话的 target fps 与预览渲染器的尺寸/帧率上限）。
                    const code: number = setVideoPreferences(
                      RESOLUTION_WIDTH[this.resolutionPreset],
                      RESOLUTION_HEIGHT[this.resolutionPreset],
                      FRAME_RATE_VALUES[this.frameRateIndex]);
                    if (code === 0) {
                      // Strings: VideoSettingsAppliedFormat "设置已提交：{0} · {1} fps · {2}"
                      this.settingsStatus =
                        `设置已提交：${RESOLUTION_SHORT[this.resolutionPreset]} · ${FRAME_RATE_LABELS[this.frameRateIndex]} fps · ${DECODER_PREFERENCE_LABELS[this.decoderPreference]}`;
                      // 解码器偏好只有开始采集时才带得进去（C ABI 无对应 setter），
                      // 正在投屏时如实说明它不会立即生效，而不是让人以为已经切了。
                      if (this.has_capture_session() && this.decoderPreference !== 0) {
                        this.settingsStatus += '；解码器偏好将在下次开始投屏时生效';
                      }
                    } else {
                      this.settingsStatus = `画面设置未生效：${lastError()}`;
                    }
                  })
              }
              .layoutWeight(1)
              Column().width(8)
              Column() {
                Text('更多设置')                          // Strings: MoreImageSettingsButton
                  .fontSize(13)
                  .fontColor(this.themePalette().TEXT)
                  .textAlign(TextAlign.Center)
                  .width('100%')
                  .height(34)
                  .borderRadius(8)
                  .backgroundColor(this.themePalette().CONTROL_FILL)
                  .onClick((): void => {
                    // 原版 MoreImageSettingsButton → 画面调节子窗口。
                    // 这里此前写的是「待接入 GLES 色彩矩阵」，属过时文案：
                    // 色彩矩阵与子窗口都已就绪，点了应该真的打开。
                    this.open_image_settings_window();
                  })
              }
              .layoutWeight(1)
            }
            .width('100%')
            .margin({ top: 10 })

            // 同上：动态文本必须内联。走 this.hint_text(this.settingsStatus) 的话，
            // 「AirPlay 接收端已启动，正在向局域网广播…」这类提示永远不会显示出来。
            if (this.settingsStatus.length > 0) {
              Text(this.settingsStatus)
                .fontSize(9)
                .fontColor(this.themePalette().MUTED_TEXT)
                .margin({ top: 6 })
                .width('100%')
            }

            Divider().color(this.themePalette().CONTROL_DIVIDER).margin({ top: 12, bottom: 11 })

            Row() {
              Checkbox({ name: 'audio_playback', group: 'audio' })
                .select(this.audioEnabled)
                .onChange((checked: boolean): void => {
                  this.audioEnabled = checked;
                  const result: number = setAudioEnabled(checked);
                  if (result !== 0) {
                    // Strings: AudioStateUpdateFailed
                    this.settingsStatus = `无法更新声音播放状态：${lastError()}`;
                  }
                })
              // Strings: PlayAudioWindows（Windows → 本机，见文件头替换清单）
              Text('在本机播放声音').fontSize(12).fontColor(this.themePalette().TEXT).margin({ left: 8 })
            }
            .width('100%')

            Row() {
              Text('播放音量').fontSize(10).fontColor(this.themePalette().MUTED_TEXT)  // Strings: PlaybackVolume
              Blank()
              Text(`${this.volume.toFixed(0)}%`).fontSize(10).fontColor(this.themePalette().ACCENT_HOVER)
            }
            .width('100%')
            .margin({ top: 9 })

            Slider({ value: this.volume, min: 0, max: 100, step: 1 })
              .onChange((value: number, mode: SliderChangeMode): void => {
                this.volume = value;
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  setAudioVolume(value / 100.0);
                }
              })
              .width('100%')
              .margin({ top: 4 })
          }
          .control_card(this.themePalette())

          // ── 卡片 4：蓝牙反控鼠标设置 ──
          // 此前整卡压暗并写着"鸿蒙版尚未实现"。现在 BLE HID 外设已经落地
          // （ets/common/BluetoothHidPeripheral.ets），所以取消灰化、换成真开关：
          //
          // ★ 但**取消灰化 ≠ 宣布可用**：这一版反控仍在实现阶段（iPhone 侧可能
          //   始终不出现指针），所以卡片里必须有一条显眼的成熟度声明，按钮上的
          //   「已广播」也只报"GATT 服务真的起来了"。两者不做区分就是典型的假成功。
          //   · 开关：真的建 GATT 服务 + 开广播，失败原因原样报出
          //     （801 = 本机蓝牙不支持外设角色，重试无用，必须让用户看见）
          //   · 灵敏度：对应上游 AppliedBluetoothMouseSensitivity，
          //     换算口径见 ReverseControlInput 文件头的说明
          //   · 状态行：每轮 poll_status 刷新 —— 广播中/连上了谁/发了多少报表/
          //     发送失败几次，都在这一行。反控"没反应"时这是唯一的定位出口。
          Column() {
            this.section_title('蓝牙反控鼠标设置', '')    // Strings: BluetoothMouseSettingsTitle

            // ★ 成熟度声明（**必须在这里，且必须显眼**）。
            //   这一版反控仍在实现阶段：GATT 服务能起来、iPhone 能在蓝牙列表里连上，
            //   但 iPhone 侧至今可能**完全不出现指针**。卡片下面那些"真的建了 GATT
            //   服务 / 真的在广播"的表述如果单独存在，会被读成"功能可用" ——
            //   这条声明就是那一句的反面。WARNING 色 + 加粗，不做次要文案。
            //   静态文案（不随状态变）⇒ 直接内联 Text，不需要 @Component 包装。
            Text('⚠ 实验性功能（开发中）：反向控制仍在实现阶段，本版本不保证可用。'
              + '请以「投屏 / 音频」为本版本的主要功能；反控遇到不能操控属当前预期，'
              + '欢迎带「复制诊断」的输出提 issue。')
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.themePalette().WARNING)
              .width('100%')
              .margin({ top: 6 })

            this.hint_text('把本机蓝牙作为 BLE HID 鼠标/键盘向 iPhone 广播。★ 手机上必须做两件事：①「设置 → 辅助功能 → 触控 → 辅助触控」开启（不开则 iOS 完全不显示指针）；② 在该页面「设备 → 蓝牙设备」里配对电脑广播出来的 HID 设备。蓝牙通道只支持单指指针与键盘，不能注入多指触控。')

            Row() {
              Button(this.bluetoothOn ? '停止蓝牙反向控制' : '开启蓝牙反向控制')
                .fontSize(13)
                .fontColor(this.themePalette().TEXT)
                .backgroundColor(this.themePalette().CONTROL_FILL)
                .borderRadius(8)
                .onClick((): void => {
                  this.toggle_bluetooth_control();
                })
            }
            .width('100%')
            .margin({ top: 10 })

            Row() {
              Text('鼠标灵敏度').fontSize(10).fontColor(this.themePalette().MUTED_TEXT)
              Blank()
              Text(`${this.bluetoothSensitivity.toFixed(0)}%`)
                .fontSize(10)
                .fontColor(this.themePalette().ACCENT_HOVER)
            }
            .width('100%')
            .margin({ top: 12 })

            Slider({ value: this.bluetoothSensitivity, min: 20, max: 300, step: 5 })
              .onChange((value: number, mode: SliderChangeMode): void => {
                this.bluetoothSensitivity = value;
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  ReverseControlInput.shared().setSensitivity(value);
                }
              })
              .width('100%')
              .margin({ top: 4 })

            // ── HID 布局（工程对照开关）──
            // 为什么要有这一行：鸿蒙发通知只能给 (serviceUuid, characteristicUuid)，
            // 而 HOGP 的标准布局是 5 个共用 0x2A4D 的 Report 特征 ⇒ 通知落到哪一个
            // 由协议栈决定。单特征布局（默认）是唯一让投递确定的走法；留切换入口是
            // 为了让"到底是不是布局的问题"能被一次点击证伪。
            // 文案是状态驱动的 ⇒ 内联 Text/Button（@Builder 按值传递会冻在首帧）。
            Row() {
              Text(`HID 布局：${this.hidLayoutText}`)
                .fontSize(10)
                .fontColor(this.themePalette().MUTED_TEXT)
              Blank()
              Button(this.hidLayoutSwitching ? '切换中…' : '切换布局')
                .fontSize(11)
                .fontColor(this.themePalette().TEXT)
                .backgroundColor(this.themePalette().CONTROL_FILL)
                .borderRadius(8)
                .enabled(!this.hidLayoutSwitching)
                .onClick((): void => {
                  this.switch_hid_layout();
                })
            }
            .width('100%')
            .margin({ top: 12 })

            this.hint_text('单特征（默认）= 所有 report 共用一个 Report 特征、载荷首字节带 report id；多特征 = 上游 Windows 的 5 特征布局。鸿蒙发通知只能按 UUID 定位特征，只有单特征能让落点确定。切换会重建蓝牙服务，iPhone 需重连一次。')

            // ★ 短摘要：第一眼该看见的一行。fontSize 12 + 强调色 + 加粗 ⇒ 比
            //   下面 fontSize 9 的长串诊断醒目得多。"主机 读N 写N 订阅S + 配对
            //   命中W" 是分水岭 —— 这一行不动笔就知道该不该再读下面那一长串。
            //   订阅1 ⇒ 绿（链路通了）；其余 ⇒ 橙（要往下看 / 要点"与 iPhone 配对"）；
            //   未启动/没开权限时显示"当前未开启蓝牙反向控制"作为占位。
            Text(this.reverseShortDiag.length > 0
              ? this.reverseShortDiag
              : (this.bluetoothStatus !== ''
                ? this.bluetoothStatus.split('·')[0]
                : '当前未开启蓝牙反向控制（点上方按钮启用）'))
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.reverseShortDiag.indexOf('订阅1') !== -1
                ? this.themePalette().SUCCESS
                : this.themePalette().WARNING)
              .margin({ top: 10 })
              .width('100%')

            // ── 取证与配对的三个动作 ──
            // 「复制诊断」是这一轮的关键交付：上一轮把读数放在条带上，结果一条反馈都
            // 没收到。一整段文本一次复制，用户不必在几个短句里找数字。
            // 「与 iPhone 配对」补的是"鸿蒙声明不了要求加密"这个缺口：iOS 对 HID
            // 要求加密链路，我们这侧没有 protection level 可设，只能主动发起或由
            // 用户在手机上配对。
            Row() {
              Button('复制诊断')
                .fontSize(11)
                .fontColor(this.themePalette().TEXT)
                .backgroundColor(this.themePalette().CONTROL_FILL)
                .borderRadius(8)
                .layoutWeight(1)
                .onClick((): void => {
                  this.copy_diagnosis();
                })
              Button('与 iPhone 配对')
                .fontSize(11)
                .fontColor(this.themePalette().TEXT)
                .backgroundColor(this.themePalette().CONTROL_FILL)
                .borderRadius(8)
                .margin({ left: 8 })
                .layoutWeight(1)
                .onClick((): void => {
                  this.pair_with_iphone();
                })
            }
            .width('100%')
            .margin({ top: 10 })

            this.hint_text('若 iPhone 上始终没有指针：先在手机端确认「辅助触控」已开启，再点「复制诊断」把一段文本发我 —— 里面「主机: 读N 写N 订阅S」三项能直接区分"手机没来枚举"与"来了但不订阅"。')

            // ★ 多行可换行（maxLines=10）：旧实现单行 + fontSize 9 的状态行
            //   把所有诊断读数用 · 拼成一长串，单行截断后用户根本看不到 "主机
            //   读N 写N 订阅S" 这一段 —— 上一轮"按钮找不到/没反应"的一半原因就
            //   是这里。现在拆成两段：① 长串原文（多行可换行，能看全）②
            //   "主机: 读X 写Y 订阅Z + 配对命中W" 这一行独立抽出来，**永远**
            //   显示，让"iPhone 端配置问题 vs 投递问题"能一眼区分。
            if (this.bluetoothStatus.length > 0) {
              Text(this.bluetoothStatus)
                .fontSize(9)
                .fontColor(this.themePalette().MUTED_TEXT)
                .margin({ top: 6 })
                .width('100%')
                .maxLines(10)
            }
          }
          .control_card(this.themePalette())

          // ── 卡片 5：视频应用投屏 ──
          Column() {
            this.section_title('视频应用投屏', '常驻')    // Strings: MediaCastTitle + WirelessServiceAlwaysOn
            // Strings: MediaCastDescription
            this.hint_text('接收视频 App 内“投屏”按钮发送的影片，不是控制中心的屏幕镜像。')
            this.hint_text('鸿蒙版尚未实现（上游由 UxPlay 子进程 + FFmpeg 承担）。')
          }
          .control_card(this.themePalette())
          .opacity(NOT_IMPLEMENTED_CARD_OPACITY)

          // ── 卡片 6：应用设置 ──
          Column() {
            this.section_title('应用设置', '')            // Strings: AppPreferencesTitle
            // 原版把「应用模式」放在**应用设置卡片内部**、排在最前，而非独立卡片：
            // MainWindow.xaml 的 AdvancedSettingsCard 里 ApplicationModeLabel → 语言 → 主题
            // （三者的 DetailLabel Margin 都是 0,10,0,5，本文件对应 field_label）。
            // 此前把「应用模式」做成了顶部独立卡片 1，顺序与原版不一致，现按原版收进本卡片。
            this.field_label(t('应用模式'))                  // Strings: ApplicationModeLabel
            Select(APPLICATION_MODE_OPTIONS)
              .optionFontColor(this.themePalette().TEXT)
              .selectedOptionFontColor(this.themePalette().TEXT)
              .selected(this.appMode)
              .value(APPLICATION_MODE_LABELS[this.appMode])
              .width('100%')
              .fontColor(this.themePalette().TEXT)
              .onSelect((index: number): void => {
                this.appMode = index;
              })
            this.field_label(t('界面语言'))                  // Strings: LanguageToolTip
            Select(language_options())
              .optionFontColor(this.themePalette().TEXT)
              .selectedOptionFontColor(this.themePalette().TEXT)
              .selected(this.languageIndex)
              .value(language_labels()[this.languageIndex])
              .width('100%')
              .fontColor(this.themePalette().TEXT)
              .onSelect((index: number): void => {
                this.languageIndex = index;
                // ★ set_language() 现在**只写内存**（AppStorage + 解析缓存），
                //   不再碰 i18n.System.setAppPreferredLanguage() —— 那个调用会触发
                //   全局配置更新 + 整树 rebuild，是"切一次语言卡一下"的根因。
                //   系统层对齐挪到下次启动（EntryAbility.onCreate），成本为零。
                set_language(index);
                // 落盘（putSync+flushSync）延后一拍：磁盘 I/O 别排在整树重渲染前面。
                setTimeout((): void => {
                  save_language_preference(index);
                }, 0);
              })
            this.field_label(t('应用主题'))                  // Strings: ThemeTitle
            Select(THEME_OPTIONS)
              .optionFontColor(this.themePalette().TEXT)
              .selectedOptionFontColor(this.themePalette().TEXT)
              .selected(this.themeIndex)
              .value(THEME_LABELS[this.themeIndex])
              .width('100%')
              .fontColor(this.themePalette().TEXT)
              .onSelect((index: number): void => {
                this.themeIndex = index;

                AppStorage.setOrCreate(THEME_PREF_KEY, index);

                recomputeThemeScheme();
                // 同步给系统，让系统三键跟着换色（不然深色下三键是深色的，看不见）。
                this.sync_system_color_mode();
              })

            // ── 反控接管时是否收起本地指针 ──
            // ★ 默认「保持可见」：反控这条链路还是实验性的，对端指针不一定动得
            //   起来，藏掉本地指针就等于把唯一的位置反馈也拿走（用户明确要求
            //   「反控时鼠标不要消失」）。想要上游那种观感的自己打开。
            Row() {
              Text(`${t('反控接管时收起指针')}：${this.hidePointerOnTakeover ? '开' : '关'}`)
                .fontSize(10)
                .fontColor(this.themePalette().MUTED_TEXT)
              Blank()
              Button(this.hidePointerOnTakeover ? '关闭' : '开启')
                .fontSize(11)
                .fontColor(this.themePalette().TEXT)
                .backgroundColor(this.themePalette().CONTROL_FILL)
                .borderRadius(8)
                .onClick((): void => {
                  this.hidePointerOnTakeover = !this.hidePointerOnTakeover;
                  // 关掉的那一拍必须立刻恢复：只改状态不调用的话，要等下一次
                  // 500ms 轮询才自愈，中间那半秒鼠标是消失的。
                  AppStorage.setOrCreate<boolean>(HIDE_POINTER_ON_TAKEOVER_KEY,
                    this.hidePointerOnTakeover);
                  save_hide_pointer_preference(this.hidePointerOnTakeover);
                  this.apply_pointer_visibility();
                })
            }
            .width('100%')
            .margin({ top: 12 })

            // ── 半透明窗口 ──
            // 对齐 Windows 11 原生深色界面的 Acrylic 观感。文案是状态驱动的
            // ⇒ 内联 Text/Button（@Builder 按值传递会冻在首帧）。
            Row() {
              Text(`半透明窗口：${this.acrylicOn ? '开' : '关'}`)
                .fontSize(10)
                .fontColor(this.themePalette().MUTED_TEXT)
              Blank()
              Button(this.acrylicOn ? '关闭' : '开启')
                .fontSize(11)
                .fontColor(this.themePalette().TEXT)
                .backgroundColor(this.themePalette().CONTROL_FILL)
                .borderRadius(8)
                .onClick((): void => {
                  this.acrylicOn = !this.acrylicOn;
                  // ★ 立刻写盘（putSync + flushSync）：拖到 Ability 收尾才刷，
                  //   用户关掉/杀进程时就来不及了 ⇒ 选完重启又回默认。
                  save_acrylic_preferences(this.acrylicOn, this.acrylic_alpha_hex());
                  this.refresh_window_acrylic_readout();
                })
            }
            .width('100%')
            .margin({ top: 12 })

            // ── 浓度档位（只在半透明开启时可选）──
            // 选中态进 ForEach 的 key（ArkUI 只按 key 复用组件，不进 key 不会重绘）。
            if (this.acrylicOn) {
              Row() {
                Text('浓度')
                  .fontSize(10)
                  .fontColor(this.themePalette().MUTED_TEXT)
                Blank()
                ForEach(ACRYLIC_ALPHA_OPTIONS, (item: AcrylicAlphaOption): void => {
                  Button(item.label)
                    .fontSize(11)
                    .fontColor(item.hex === this.acrylicAlpha
                      ? '#FFFFFF'
                      : this.themePalette().TEXT)
                    .backgroundColor(item.hex === this.acrylicAlpha
                      ? this.themePalette().ACCENT
                      : this.themePalette().CONTROL_FILL)
                    .borderRadius(8)
                    .margin({ left: 6 })
                    .onClick((): void => {
                      this.acrylicAlpha = item.hex;
                      save_acrylic_preferences(this.acrylicOn, item.hex);
                      this.refresh_window_acrylic_readout();
                    })
                }, (item: AcrylicAlphaOption): string =>
                  `${item.hex}${item.hex === this.acrylicAlpha ? '-on' : '-off'}`)
              }
              .width('100%')
              .margin({ top: 8 })
            }

            // ── 参数读数（仅开发者模式）──
            // 这是排查用的内部账本（窗口透明与否、容器配色 4 组探测的成功/失败码），
            // 正常使用者看到只会困惑 ⇒ 只在开发者模式下显示。
            if (this.devMode && this.windowAcrylicReadout.length > 0) {
              Text(this.windowAcrylicReadout)
                .fontSize(9)
                .fontColor(this.themePalette().MUTED_TEXT)
                .width('100%')
                .margin({ top: 4 })
                // 这是一份账本（窗口属性 + 容器配色 4 组探测 + 偏好读写），行数按内容增长：
                // 截断就等于读不到 ⇒ 宁可放宽（现在最长约 6 行，留两行余量）。
                .maxLines(8)
            }

            this.hint_text('窗口底色半透明，对齐 Windows 原生深色观感；浓度可在上面选档。若观感不合适，点「关闭」即回到原纯色背景。')
          }
          .control_card(this.themePalette())

          // ── 卡片 7：设置中心（打开各子窗口）──
          Column() {
            this.section_title('设置中心', '')            // Strings: SettingsCenterTitle
            Column() {
              SecondaryButton({
                label: '画面调节',
                on_action: (): void => {
                  // 走同一个入口：传当前生效值，避免窗口滑杆与画面实际状态不一致。
                  this.open_image_settings_window();
                },
              })
              SecondaryButton({
                label: t('高级设置'),
                on_action: (): void => {
                  this.launch_subwindow((ctx: common.Context): void => {
                    open_advanced_settings(ctx, { width: 1280, height: 720, previewOnly: false });
                  });
                },
              })
              SecondaryButton({
                label: t('关于'),
                on_action: (): void => {
                  this.launch_subwindow((ctx: common.Context): void => { open_about(ctx, 0); });
                },
              })
              SecondaryButton({
                label: t('开发者工具'),
                on_action: (): void => {
                  this.launch_subwindow((ctx: common.Context): void => { open_developer_tools(ctx); });
                },
              })
              SecondaryButton({
                label: '媒体输出设置',
                on_action: (): void => {
                  this.launch_subwindow((ctx: common.Context): void => { open_media_output_settings(ctx, false); });
                },
              })
              SecondaryButton({
                label: '投影设置',
                on_action: (): void => {
                  this.launch_subwindow((ctx: common.Context): void => { open_projection_settings(ctx); });
                },
              })
              SecondaryButton({
                label: '快捷键设置',
                on_action: (): void => {
                  this.launch_subwindow((ctx: common.Context): void => { open_shortcut_settings(ctx); });
                },
              })
              SecondaryButton({
                label: '蓝牙客户端绑定',
                on_action: (): void => {
                  this.launch_subwindow((ctx: common.Context): void => {
                    // 真实客户端来自 BLE HID 外设当前的 GATT 连接（原版
                    // BluetoothHidMouseService._clientStates）。一个都没有时窗口自己会
                    // 退回演示数据并**在界面上标注**那是演示数据。
                    open_bluetooth_client_binding(ctx, this.selectedName, clients_from_hid(),
                      '', (selectedId: string | null): void => {
                        this.settingsStatus = selectedId === null
                          ? '蓝牙客户端绑定已取消'
                          : `已选择蓝牙客户端：${selectedId}`;
                      });
                  });
                },
              })
              SecondaryButton({
                label: '设备绑定',
                on_action: (): void => {
                  this.launch_subwindow((ctx: common.Context): void => { open_device_binding(ctx, []); });
                },
              })
            }
            .width('100%')
            .margin({ top: 8 })
          }
          .control_card(this.themePalette())
        }
        .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto)
    }
    .width(DEVICE_PANEL_WIDTH)
    .height('100%')
    .padding(16)
    .workspace_card(this.themePalette())
  }

  // ═══════════════════════════ FooterPanel ═══════════════════════════

  @Builder
  footer() {
    Row() {
      Text('本机 USB / AirPlay，无云端中转')              // Strings: FooterConnectivity
        .fontSize(10)
        .fontColor(this.themePalette().MUTED_TEXT)
      Blank()
      Text(this.version_text()).fontSize(10).fontColor(this.themePalette().MUTED_TEXT)
    }
    .width('100%')
    .margin({ top: 16 })
  }

  // ═══════════════════════════ 组装（AppShell） ═══════════════════════════

  /**
   * 开发者模式开关变化 ⇒ 重算窗口参数读数。
   * 为什么需要：读数只在开发者模式下显示，而开发者模式是**运行中**才开的
   * （关于页连点版本号）；不重算的话，开完回到主界面读数区会是空的。
   */
  private on_dev_mode_changed(): void {
    this.refresh_window_acrylic_readout();
  }

  /**
   * 回读主窗属性，把「系统给不给透明」变成一行能读的数字。
   *
   * ★ 为什么必须有这行：半透明磨砂有两种失败路径 —— ① 系统根本不给透明窗口
   *   （isTransparent=false，UI 的 alpha 底色只是叠在不透明窗口背景上，混出来和
   *   原色差几个亮度值，肉眼"根本没变化"）；② 给了透明但模糊采不到桌面。
   *   两种的下一步完全不同，靠猜区分不开，只能读真值。
   */
  private refresh_window_acrylic_readout(): void {
    const ctx: common.Context | null = this.appContext;
    if (ctx === null) {
      this.windowAcrylicReadout = '窗口属性回读失败：拿不到应用上下文';
      return;
    }
    try {
      window.getLastWindow(ctx)
        .then((win: window.Window): void => {
          try {
            const props: window.WindowProperties = win.getWindowProperties();
            const container: string = AppStorage.get<string>(WINDOW_ACRYLIC_RESULT_KEY) ?? '';
            const shadow: string = AppStorage.get<string>(WINDOW_SHADOW_RESULT_KEY) ?? '';
            const persisted: string = AppStorage.get<string>(PERSIST_READ_RESULT_KEY) ?? '';
            const persistedWrite: string = AppStorage.get<string>(PERSIST_WRITE_RESULT_KEY) ?? '';
            this.windowAcrylicReadout =
              `窗口透明=${props.isTransparent ? '是' : '否'} · 类型=${props.type} · 全屏=${props.isFullScreen ? '是' : '否'}`
              + ` · 底浓度=${Math.round(parseInt(this.acrylic_alpha_hex(), 16) / 255 * 100)}%`
              // 「存档」两字是偏好读写的结果：读=启动时从磁盘取回的值，写=最近一次落盘。
              // 持久化失败与"用户没改过"同形（都回到默认），只能靠这两个读数区分。
              + (persisted.length > 0 ? ` ｜ ${persisted}` : '')
              + (persistedWrite.length > 0 ? ` ｜ ${persistedWrite}` : '')
              + (container.length > 0 ? ` ｜ ${container}` : '')
              + (shadow.length > 0 ? ` ｜ ${shadow}` : '');
          } catch (readError) {
            const readFailure = readError as BusinessError;
            this.windowAcrylicReadout = `窗口属性回读失败：${readFailure.message}`;
          }
        })
        .catch((error: BusinessError): void => {
          this.windowAcrylicReadout = `窗口属性回读失败：${error.code} ${error.message}`;
        });
    } catch (error) {
      const failure = error as BusinessError;
      this.windowAcrylicReadout = `窗口属性回读失败：${failure.message}`;
    }
  }

  /**
   * 根容器背景色：磨砂开 = 带 alpha 的 Fluent 底色（窗口背景已在 EntryAbility 设为
   * 全透明，alpha 部分直接混到桌面，即 Win11 原生观感的来路）；关 = 原实色。
   * 基色与 WINDOW_BACKGROUND 同源（#1F1F1F / #F3F3F5），只把 alpha 提到
   * ROOT_ACRYLIC_ALPHA_HEX。★ 现在容器色与内容区背景都已**全透**，这一层的 alpha
   * 就是**唯一**决定"透多少"的量 —— 想更透就把它调小（00=全透、FF=实色）。
   */
  /**
   * 当前浓度 alpha（两位十六进制串）。
   *
   * ★ 防脏值：档位来自 AppStorage，若被人写入非法串（长度不对 / 非十六进制），
   *   `#${x}1F1F1F` 会拼出非法颜色 ⇒ 根容器着色异常。这里统一校验后回退默认值。
   */
  private acrylic_alpha_hex(): string {
    const value: string = this.acrylicAlpha;
    if (value.length !== 2) {
      return ROOT_ACRYLIC_ALPHA_HEX;
    }
    const parsed: number = parseInt(value, 16);
    if (Number.isNaN(parsed)) {
      return ROOT_ACRYLIC_ALPHA_HEX;
    }
    return value;
  }

  private root_background_color(): string {
    if (!this.acrylicOn) {
      return this.themePalette().BACKGROUND;
    }
    return this.scheme === 'dark'
      ? `#${this.acrylic_alpha_hex()}1F1F1F`
      : `#${this.acrylic_alpha_hex()}F3F3F5`;
  }

  build() {
    // 根容器用 Stack：主内容照旧，底部叠一层「敬请期待」浮层
    // （未实现功能的统一反馈，见 show_coming_soon）。
    Stack({ alignContent: Alignment.Bottom }) {
      Row() {
        this.nav_rail()

        Column() {
          this.header()

          // 原版 MainContentGrid：DeviceColumn(300) | LeftGap(18) | Center(*) | RightGap | ControlColumn
          Row() {
            // ★ 左侧面板与右侧设置面板同纪律：**收起时整列连同间隔一并撤掉**，
            //   中间画面区自动占满。此前左列无论开合都占着 300 + 间隔，于是关掉
            //   「投屏 / 投屏来源」后中间区左边留一条空白，而关右侧却能拉伸。
            //   上游即如此（MainWindow.xaml.cs）：showLeftPanel = (左面板 != None)，
            //   LeftPanelHost 关闭时 Width=0 + Visibility=Collapsed，LeftGapColumn=0。
            if (this.showDevicePanel || this.showMirroringPanel) {
              this.left_panel()
              Column().width(COLUMN_GAP)
            }

            this.center_panel()

            if (this.showControlPanel) {
              Column().width(COLUMN_GAP)
              this.control_panel()
            }
          }
          .width('100%')
          .layoutWeight(1)
          .alignItems(VerticalAlign.Top)

          this.footer()
        }
        .layoutWeight(1)
        .height('100%')
        .padding({ left: 18, right: 18, top: 16, bottom: 12 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.root_background_color())
      // 磨砂：radius=0 时等于没有模糊。模糊能否作用到窗口外的桌面取决于
      // 系统合成器 —— 窗口 surface 内没有内容可采时，这里大概率只是无操作；
      // 半透明的观感由 root_background_color() 的 alpha 底色承担，两者叠加。
      .backgroundEffect({
        radius: this.acrylicOn ? 32 : 0,
        color: this.root_background_color(),
        saturation: this.scheme === 'dark' ? 0.2 : 0.35,
        brightness: 1.0,
      })

      if (this.comingSoonText.length > 0) {
        this.coming_soon_toast()
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 「敬请期待」浮层。
   * 配色与导航项气泡共用同一组 TOOLTIP_* 色键，观感统一；不遮罩、不拦点击，
   * 到时间自己消失（见 show_coming_soon 的定时器）。
   */
  @Builder
  coming_soon_toast() {
    Text(this.comingSoonText)
      .fontSize(13)
      .fontColor(this.themePalette().TOOLTIP_FOREGROUND)
      .padding({ left: 18, right: 18, top: 11, bottom: 11 })
      .backgroundColor(this.themePalette().TOOLTIP_BACKGROUND)
      .border({ width: 1, color: this.themePalette().TOOLTIP_BORDER })
      .borderRadius(8)
      .margin({ bottom: 34 })
  }
}
