// DeveloperToolsWindow.ets —— 子窗口：开发者工具（页面/弹窗预览 + 运行期参数 + 检查器）
//
// 逐项对照上游 src/App/Windows/DeveloperToolsWindow.xaml（236 行）
//              src/App/Windows/DeveloperToolsWindow.xaml.cs（315 行）
//
// 上游两份的差异（main 1.8.4 / linux-port 1.8.1）：只有 WindowItems 少了三项
// （reverse-control-wired-prerequisite / -wireless-prerequisite / reverse-control-error）。
// → 本文件按 main 版的 6 + 18 项还原。
//
// ── 窗口属性（XAML 根元素 <ui:FluentWindow> 那一行）──────────────────────────
//   Title="{DynamicResource DeveloperToolsTitle}"   → 「开发者工具」
//   Width="980" Height="760"                        → SubWindowSpec 980×760
//   MinWidth="820" MinHeight="620"                  → minWidth/minHeight（可缩放）
//   WindowStartupLocation="CenterScreen"            → 见平台替换 1
//   WindowStyle="None" ExtendsContentIntoTitleBar="True" → decorEnabled: false + 自绘表头
//   ResizeMode="CanResize"                          → resizable: true
//   WindowBackdropType="None" WindowCornerPreference="Round" → 由系统窗口负责
//   Background="{DynamicResource DialogSurfaceBrush}" → shellBackground = DIALOG_SURFACE
//   ShowInTaskbar="False" Topmost="False"           → 子窗口天然不在任务栏
//
// ── 行定义（3 行）───────────────────────────────────────────────────────────
//   Row Auto : Grid x:Name=HeaderDragSurface Style=SubWindowHeader（MinHeight 44）
//                StackPanel Margin="0,0,52,0"
//                  StackPanel 横向：SubWindowTitle + 「只读预览」徽标（见平台替换 2）
//                  TextBlock SubWindowSubtitle
//                Button SubWindowCloseButton + Dismiss20/18
//   Row *    : ScrollViewer（Margin 0,12,0,0）→ 四张 SettingsSection 卡片（+ 本工程
//              新增的诊断日志卡，见平台替换 7）
//   Row Auto : Grid（Margin 0,12,0,0）StatusText（左，Muted/Wrap）+ 「关闭」主按钮
//              （右，MinWidth 96）
//
// ── 卡片逐条对照 ────────────────────────────────────────────────────────────
//   卡 1「工作区页面」：SubWindowSectionTitle + SubWindowSubtitle +
//        ItemsControl WorkspaceItems（WrapPanel，6 项，按钮 MinWidth 180 / Height 54 /
//        Margin 0,0,8,8；列 28 + *：SymbolIcon 16 + 标题 13 SemiBold + 描述 10 Muted 省略号）
//   卡 2「子窗口与弹窗」：同上，ItemsControl WindowItems（18 项）
//   卡 3「运行期参数」：Grid 两列 * / 18 / *
//        左：DetailLabel（Muted 11 / Margin 0,13,0,3）「应用主题」+ ComboBox（System/Light/Dark）
//            DetailLabel（Margin 0,14,0,0）「界面语言」+ ComboBox（system/zh-CN/zh-HK/en-US）
//        右：DetailLabel「主窗口透明度」+ Slider（0.72–1，TickFrequency 0.01，吸附）
//            + OpacityText（Muted 11 / Margin 0,2,0,0）
//            CheckBox「主窗口置顶」（Margin 0,14,0,0）
//            DetailLabel「窗口预设」（Margin 0,14,0,0）+ 三个按钮（紧凑/默认/最大化，MinWidth 94）
//        末行（靠右）：「重置参数」MinWidth 116 + 「刷新检查」PrimaryButton MinWidth 116
//   卡 4「窗口检查器」：DiagnosticsText（Cascadia Mono/Consolas 11 Muted Wrap，Margin 0,10,0,0）
//        + ItemsControl OpenWindows（每行：标题* + 「激活」MinWidth 76/MinHeight 30 +
//          8 + 「关闭」MinWidth 64/MinHeight 30）
//
// ── 文案来源 Strings.zh-CN.xaml（逐字取用）────────────────────────────────
//   DeveloperToolsTitle/Subtitle/PreviewBadge/WorkspaceSection/WorkspaceHint/
//   WindowsSection/WindowsHint/ParametersSection/ParametersHint/InspectorSection
//   DeveloperMirroring/Devices/Settings/Output/Driver/About（+ 各自的 Description）
//   DeveloperAdvancedSettings/Prompt/ReverseControlWiredPrerequisite/…/NativePreview
//   DeveloperParamTheme/Language/Opacity/Topmost/WindowPreset
//   DeveloperThemeSystem/Light/Dark；DeveloperLanguageSystem/Simplified/Traditional/English
//   DeveloperPresetCompact/Default/Maximize；DeveloperResetParameters/Refresh
//   DeveloperActivate/Close/RuntimeVersion/Culture/Theme/Dpi/Windows
//   DeveloperSurfaceOpened/SurfaceOpenFailed/ParametersReset；Close
//
// ── 关联服务（逐条注明搬到哪里 / 为什么搬不动）────────────────────────────────
//   ① src/App/Services/DiagnosticLogger.cs
//      · DirectoryPath = %LOCALAPPDATA%\iPhoneMirror\Logs；单文件上限 8 MB、
//        保留 4 个归档、14 天/64 MB 清理上限。
//        → 鸿蒙等价物：ctx.filesDir + '/iPhoneMirror/Logs'（与 AboutWindow 的
//          平台替换 2/6 完全同一路径口径），见 diagnostic_dir()。
//      · FormatEntry：`<ISO8601> level=… pid=… tid=… category=… event=… k=v …`
//        → 本文件 format_entry() 按同样顺序拼（pid/tid 在 ArkTS 拿不到，写 0）。
//      · Initialize() 写 session_start、Shutdown() 写 session_end
//        → 本窗口打开时写一条 developer_tools_opened（真做，见 write_log）。
//   ② src/App/Services/AppLog.cs
//      · Sanitize() 把 URL、主机、IPv4、MAC、Apple UDID、长 Hex、Windows/Unix 路径、
//        口令类键值替换成占位符；Message() = Limit(Sanitize(v), 2048)。
//        → 本文件 sanitize_message() 只搬两条与本窗口相关的：URL 与长 Hex（设备
//          标识）。其余（Authorization/Cookie/IPv4…）本窗口不会接到这类字符串，
//          搬进来只会制造未使用的代码，故不搬，仅在此注明。
//      · 单条上限 2048 字符 → MAX_MESSAGE_CHARS。
//   ③ src/App/Services/NativeLogTailReader.cs
//      · ReadNewLinesAsync：按字节偏移增量读，单次上限 256 KB，单行上限 16 K 字符，
//        文件被截断则回退到 0；IsUiEventLine 过滤 UI 回显。
//        → 本窗口的日志视图改由 AppStorage 的日志缓冲直接供数（见 LOG_KEY），
//          不需要增量读（原生日志在鸿蒙由 hilog 承载，不再单独落 capture.log），
//          所以 NativeLogTailReader 在鸿蒙侧没有对应物 —— 平台替换 7 已写明。
//   ④ src/App/Services/RuntimeBinaryIntegrity.cs
//      · VerifyWirelessDirectory 校验 6 个 Windows DLL（airplay2dll/avcodec-58/
//        avutil-56/dnssd/swresample-3/swscale-5）与 ffmpeg 的 SHA-256；
//        VerifyUsbTouchBridgeRuntime 校验 iUsbBridge.runtime.json 清单。
//        → 鸿蒙**没有**这些 DLL、没有 PyInstaller onedir 负载、没有 iUsbBridge.exe，
//          校验对象不存在。本窗口在检查器里如实显示这一结论（见 integrity_text），
//          不伪造一个「校验通过」。
//   ⑤ src/Core/tools/{LibUsb0Probe,PipelineSwitchProbe,UsbConfigurationSwitch}.cpp
//      · 三个 Windows libusb0 诊断小工具（探测 libusb0 过滤器、切换管道、切换
//        USB 配置）。鸿蒙没有 libusb0 / WinUSB 驱动栈，也没有可执行子进程
//        （ArkTS 不能 Process.Start）→ 不可移植，见平台替换 8。
//
// ── 平台替换（原版机制在鸿蒙没有对应物，逐条列出）──────────────────────────
//   1. WindowStartupLocation="CenterScreen"：SubWindowHost.open 只实现了
//      「在主窗口矩形上居中」（原版 20 个子窗口都是 CenterOwner）。这里沿用，
//      与原版的差异是居中基准（主窗口 vs 屏幕），已在 SubWindow.ets 注明。
//   2. 表头里「SubWindowTitle + 只读预览徽标」是**同一个横向 StackPanel**。
//      SubWindowShell 的 title 只收字符串，没有内联徽标插槽 → 徽标下移一行，
//      放进 notice 槽（文案「只读预览」、WarningSurface 底 / WarningBrush 1px 边 /
//      圆角 8 / Padding 8,3 / 11 SemiBold 全部不变）。
//      另外原版标题块 Margin="0,0,52,0"，外壳固定让位 48（SUBWINDOW_HEADER_TEXT_END）。
//   3. 原版 24 个预览按钮统一回调 `_owner.OpenDeveloperSurface(key)`（主窗口持有
//      实现）。鸿蒙版**主窗口没有这个入口**，所以除「投屏状态通知」四个预览
//      （本工程确有对应页面，真开窗）外，其余点下去如实报出缺哪个入口，
//      不静默假装打开。
//   4. DispatcherTimer（750 ms 刷新检查器）→ setInterval / clearInterval，周期相同。
//   5. ComboBox（WPF）→ ArkUI 的 Select（下拉选择，视觉最接近）；
//      CheckBox → Toggle(ToggleType.Checkbox)；WrapPanel → Flex(wrap: Wrap)。
//   6. 【主窗口透明度】WPF 的 Window.Opacity 在鸿蒙没有等价物（@ohos.window 不
//      提供窗口不透明度设置）→ Slider 保留原版区间 0.72–1，拖动后如实说明。
//      【主窗口置顶】WPF 的 Window.Topmost 同样没有等价物 → 同上。
//      【界面语言】原版 LocalizationService.SetLanguage 切换资源字典；鸿蒙版只有
//      一套 zh-CN 内置文案（本项目所有窗口都把文案内联成常量）→ 选非简体时如实说明。
//      【窗口预设】compact 1280×700 / default 1540×900 / maximize —— **真做**：
//      @ohos.window 有 resize(w,h) 与 maximize()。
//   7. 【诊断日志卡】上游把日志视图放在 AboutWindow（LiveLogHeader + 诊断页），
//      DeveloperToolsWindow 本身没有日志视图。本工程按移植要求把它并到开发者
//      工具里（服务 ①②③ 的正确落点），并在此注明：这一段是**新增**，不是
//      上游 DeveloperToolsWindow 的原有内容。
//      日志用 hilog + AppStorage（键见 LOG_KEY）承载，「导出日志」用
//      @kit.CoreFileKit 的 fileIo 真写到 ctx.filesDir，「复制诊断信息」用
//      @ohos.pasteboard 真写剪贴板。
//   8. 【原生诊断工具】服务 ⑤ 的三个 .cpp 工具不可移植，本窗口不提供入口，
//      只在检查器文本里写明原因（不摆三个点了会失败的按钮）。
//
// ── 不做假成功 ─────────────────────────────────────────────────────────────
//   开不了的预览 → 说清缺哪个入口；改不了的透明度/置顶/语言 → 说清鸿蒙少了什么；
//   复制 / 导出 / 清理 → 真做，失败时把错误原样显示出来。

import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import window from '@ohos.window';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { bundleManager } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { display } from '@kit.ArkUI';
import pasteboard from '@ohos.pasteboard';
import {
  SubWindowShell, SubWindowHost, SettingsSection, PrimaryButton, SecondaryButton,
  section_title, hint_text,
  SubWindowSpec,
} from '../../common/SubWindow';
import {
  TEXT, MUTED_TEXT, BORDER, BORDER_SOFT, CONTROL_FILL, CONTROL_HOVER,
  WARNING, WARNING_SURFACE, ACCENT, DIALOG_SURFACE,
  BUTTON_CORNER, SLIDER_TRACK, SLIDER_THUMB_FILL,
} from '../../common/Theme';
import { FluentSymbol } from '../../common/FluentIcon';
import { THEME_PREF_KEY, recomputeThemeScheme } from '../../common/theme_manager';
import {
  show_developer_error_preview,
  show_developer_reverse_control_error_preview,
  show_developer_stopped_preview,
  show_developer_usb_preview,
} from './CaptureStatusNoticeWindow';

const TAG: string = 'im_developer_tools';
const DOMAIN: number = 0x0100;

/** 窗口名 —— 用 XAML 的类名，window.findWindow 也用它。 */
export const WINDOW_NAME: string = 'DeveloperToolsWindow';
/** 页面路径。 */
export const PAGE_PATH: string = 'pages/windows/DeveloperToolsWindow';

/** 平台替换 7：日志缓冲（AppStorage 键）。 */
export const LOG_KEY: string = 'im.developerTools.logText';
/** 运行期参数的持久化键（原版只影响当前进程，这里同样只影响当前进程）。 */
export const PARAM_KEY_LANGUAGE: string = 'im.developerTools.language';
export const PARAM_KEY_OPACITY: string = 'im.developerTools.opacity';
export const PARAM_KEY_TOPMOST: string = 'im.developerTools.topmost';
/** 导出的诊断日志文件名（原版 DiagnosticLogger 目录里的同类文件）。 */
export const LOG_FILE_NAME: string = 'developer-tools.log';

// ───────────────────── Strings（逐键标注） ─────────────────────

const S_TITLE: string = '开发者工具';                        // DeveloperToolsTitle
const S_SUBTITLE: string = '统一预览所有页面、弹窗和运行期参数'; // DeveloperToolsSubtitle
const S_PREVIEW_BADGE: string = '只读预览';                  // DeveloperToolsPreviewBadge
const S_WORKSPACE_SECTION: string = '工作区页面';             // DeveloperToolsWorkspaceSection
const S_WORKSPACE_HINT: string = '快速切换主窗口中的所有工作区状态'; // DeveloperToolsWorkspaceHint
const S_WINDOWS_SECTION: string = '子窗口与弹窗';             // DeveloperToolsWindowsSection
const S_WINDOWS_HINT: string = '打开现有窗口的安全预览；网络、设备和破坏性操作已隔离'; // DeveloperToolsWindowsHint
const S_PARAM_SECTION: string = '运行期参数';                 // DeveloperToolsParametersSection
const S_PARAM_HINT: string = '参数仅影响当前进程，便于检查主题、缩放和窗口协调'; // DeveloperToolsParametersHint
const S_INSPECTOR_SECTION: string = '窗口检查器';             // DeveloperToolsInspectorSection
const S_DIAGNOSTICS_SECTION: string = '诊断日志';             // 本工程新增（平台替换 7）
const S_PARAM_THEME: string = '应用主题';                     // DeveloperParamTheme
const S_PARAM_LANGUAGE: string = '界面语言';                  // DeveloperParamLanguage
const S_PARAM_OPACITY: string = '主窗口透明度';                // DeveloperParamOpacity
const S_PARAM_TOPMOST: string = '主窗口置顶';                  // DeveloperParamTopmost
const S_PARAM_PRESET: string = '窗口预设';                    // DeveloperParamWindowPreset
const S_PRESET_COMPACT: string = '紧凑 1280×700';              // DeveloperPresetCompact
const S_PRESET_DEFAULT: string = '默认 1540×900';              // DeveloperPresetDefault
const S_PRESET_MAXIMIZE: string = '最大化';                   // DeveloperPresetMaximize
const S_RESET: string = '重置参数';                           // DeveloperResetParameters
const S_REFRESH: string = '刷新检查';                         // DeveloperRefresh
const S_ACTIVATE: string = '激活';                            // DeveloperActivate
const S_CLOSE_WINDOW: string = '关闭';                        // DeveloperClose
const S_CLOSE: string = '关闭';                               // Close
const S_SURFACE_OPENED: string = '预览窗口已打开';             // DeveloperSurfaceOpened
const S_SURFACE_OPEN_FAILED: string = '打开预览失败';          // DeveloperSurfaceOpenFailed
const S_PARAMETERS_RESET: string = '参数已恢复默认值';          // DeveloperParametersReset
const S_RUNTIME_VERSION: string = '版本';                     // DeveloperRuntimeVersion
const S_RUNTIME_CULTURE: string = '区域';                     // DeveloperRuntimeCulture
const S_RUNTIME_THEME: string = '主题';                       // DeveloperRuntimeTheme
const S_RUNTIME_DPI: string = '文字缩放';                     // DeveloperRuntimeDpi
const S_RUNTIME_WINDOWS: string = '窗口数';                   // DeveloperRuntimeWindows

/** DeveloperThemeSystem / Light / Dark —— ComboBox 顺序为 System/Light/Dark。 */
const THEME_LABELS: string[] = ['跟随系统', '浅色', '深色'];
/** theme_manager 的口径：0=跟随系统 1=深色 2=浅色（与 ComboBox 顺序不同，需要映射）。 */
const THEME_PREF_BY_INDEX: number[] = [0, 2, 1];
/** DeveloperLanguageSystem / Simplified / Traditional / English。 */
const LANGUAGE_TAGS: string[] = ['system', 'zh-CN', 'zh-HK', 'en-US'];
const LANGUAGE_LABELS: string[] = ['跟随系统', '简体中文', '繁体中文（香港）', 'English'];

/** 平台替换 5：WPF ComboBox → ArkUI 的 Select（下拉选择）。 */
function to_options(labels: string[]): SelectOption[] {
  const options: SelectOption[] = [];
  for (let index: number = 0; index < labels.length; ++index) {
    options.push({ value: labels[index] });
  }
  return options;
}

const THEME_OPTIONS: SelectOption[] = to_options(THEME_LABELS);
const LANGUAGE_OPTIONS: SelectOption[] = to_options(LANGUAGE_LABELS);
/** DeveloperPreset* 对应的窗口尺寸（xaml.cs OnPresetClick / OnResetClick）。 */
const PRESET_COMPACT_WIDTH: number = 1280;
const PRESET_COMPACT_HEIGHT: number = 700;
const PRESET_DEFAULT_WIDTH: number = 1540;
const PRESET_DEFAULT_HEIGHT: number = 900;

/** 平台替换 6：三项做不到的参数的确切原因。 */
const S_REASON_OPACITY: string =
  '鸿蒙 @ohos.window 没有 WPF Window.Opacity 的等价物（无窗口不透明度设置接口），' +
  '主窗口透明度不可调整。';
const S_REASON_TOPMOST: string =
  '鸿蒙 @ohos.window 没有 WPF Window.Topmost 的等价物（无窗口置顶标记接口），' +
  '主窗口置顶不可调整。';
const S_REASON_LANGUAGE: string =
  '鸿蒙版只有一套 zh-CN 内置文案（各窗口已把 Strings.zh-CN.xaml 的原文内联成常量），' +
  '没有 LocalizationService 资源字典可切换。';
/** 平台替换 3：打不开的预览面的确切原因。 */
const S_REASON_NO_SURFACE: string =
  '鸿蒙版主窗口未提供 OpenDeveloperSurface(key) 的等价入口，本工程也没有对应的预览页面。';
/** 平台替换 8 + 服务 ④：运行时完整性校验的结论（原版校验对象不存在）。 */
const S_INTEGRITY_UNAVAILABLE: string =
  '运行时完整性校验不可用：原版校验的 6 个 Windows DLL 与 ffmpeg 在鸿蒙不存在，' +
  '也没有 iUsbBridge 的 onedir 负载清单。';
/** 服务 ⑤：原生诊断工具的结论。 */
const S_NATIVE_TOOLS_UNAVAILABLE: string =
  '原生诊断工具不可用：LibUsb0Probe / PipelineSwitchProbe / UsbConfigurationSwitch ' +
  '依赖 Windows libusb0 驱动栈，且 ArkTS 不能启动子进程。';

// ───────────────────── 预览面目录（xaml.cs 的两张表） ─────────────────────

/** xaml.cs: public sealed record DeveloperSurfaceItem(Key, Icon, Title, Description)。 */
export class DeveloperSurfaceItem {
  key: string = '';
  icon: string = '';
  title: string = '';
  description: string = '';

  constructor(key: string, icon: string, title: string, description: string) {
    this.key = key;
    this.icon = icon;
    this.title = title;
    this.description = description;
  }
}

/**
 * 图标名映射：原版用 Fluent System Icons 的 SymbolRegular，本工程
 * common/FluentIcon.ets 里只有 30 个图标，没有的取形状最接近的那个：
 *   WrenchScrewdriver20 → Settings24   QuestionCircle20 → Info24
 *   Phone20 → PhoneDesktop24           Settings20 → Settings24
 *   ProjectionScreen20 → ProjectionScreen24   Image20 → ImageEdit20
 *   Window20 → WindowNew20             ArrowDownload20 → Open20
 *   Speaker220 / UsbPlug20 / ErrorCircle20 / Warning20 / Info20(→Info24) 同名可用。
 */
function build_workspace_items(): DeveloperSurfaceItem[] {
  return [
    new DeveloperSurfaceItem('workspace-mirroring', 'ProjectionScreen24',
      '投屏控制', '主工作区与预览状态'),
    new DeveloperSurfaceItem('workspace-devices', 'PhoneDesktop24',
      '投屏来源', '设备列表和连接面板'),
    new DeveloperSurfaceItem('workspace-settings', 'Settings24',
      '投屏设置', 'AirPlay、语言和主题'),
    new DeveloperSurfaceItem('workspace-output', 'VideoRecording20',
      '输出设置', '录制、推流和虚拟摄像头'),
    new DeveloperSurfaceItem('driver-manager', 'Settings24',
      '驱动管理', '打开独立驱动管理器'),
    new DeveloperSurfaceItem('about', 'Info24',
      '关于与更新', '版本、诊断和更新信息'),
  ];
}

function build_window_items(): DeveloperSurfaceItem[] {
  return [
    new DeveloperSurfaceItem('advanced-settings', 'Settings24',
      '高级 USB 设置', '分辨率输入验证'),
    new DeveloperSurfaceItem('prompt', 'Info24',
      '确认提示框', '标准确认和信息布局'),
    new DeveloperSurfaceItem('reverse-control-wired-prerequisite', 'UsbPlug20',
      '有线控制前置提示', '开发者模式、USB 信任和 DDI 说明'),
    new DeveloperSurfaceItem('reverse-control-wireless-prerequisite', 'Info24',
      '无线控制前置提示', '开发者模式、配对和局域网说明'),
    new DeveloperSurfaceItem('reverse-control-error', 'ErrorCircle20',
      '反向控制错误弹窗', '反向控制桥接失败时的错误信息'),
    new DeveloperSurfaceItem('capture-error', 'ErrorCircle20',
      '投屏错误弹窗', '视频流失败后的错误提示'),
    new DeveloperSurfaceItem('session-closed', 'ErrorCircle20',
      '投屏已停止弹窗', '从控制中心停止镜像后的提示'),
    new DeveloperSurfaceItem('usb-config-error', 'UsbPlug20',
      'USB 配置错误弹窗', 'USB 投屏配置失败后的提示'),
    new DeveloperSurfaceItem('capture-recovery', 'Warning20',
      '采集恢复提示', '无响应时的恢复说明'),
    new DeveloperSurfaceItem('image-settings', 'ImageEdit20',
      '图像设置', '亮度、对比度和伽马滑块'),
    new DeveloperSurfaceItem('projection-settings', 'ProjectionScreen24',
      '投屏设置窗口', '设备状态和快捷操作'),
    new DeveloperSurfaceItem('media-output', 'Speaker220',
      '媒体输出窗口', '录制、直播和摄像头标签页'),
    new DeveloperSurfaceItem('usb-mode', 'UsbPlug24',
      'USB 模式详情', '模式说明和注意事项'),
    new DeveloperSurfaceItem('startup-error', 'ErrorCircle20',
      '启动错误窗口', '错误摘要和诊断日志'),
    new DeveloperSurfaceItem('update', 'Open20',
      '更新窗口', '版本信息和发布说明'),
    new DeveloperSurfaceItem('instance-conflict', 'Warning20',
      '实例冲突窗口', '只读的多实例提示'),
    new DeveloperSurfaceItem('protected-content', 'Warning20',
      '受保护视频提示', 'DRM/FairPlay 黑屏检查提示'),
    new DeveloperSurfaceItem('native-preview', 'WindowNew20',
      '独立预览窗口', '原生窗口圆角和菜单外壳'),
  ];
}

/** 服务 ④/⑤ 的结论合并成一行，显示在检查器里。 */
const INTEGRITY_LINES: string[] = [S_INTEGRITY_UNAVAILABLE, S_NATIVE_TOOLS_UNAVAILABLE];

// ───────────────────── 日志（服务 ①②，平台替换 7） ─────────────────────

/** AppLog.Message 的上限（MaximumEventCharacters = 2048）。 */
const MAX_MESSAGE_CHARS: number = 2048;
/** 日志缓冲上限（原版按字节轮转，这里按行近似）。 */
const MAX_LOG_LINES: number = 200;

let host_ctx: common.Context | null = null;

function ui_context(): common.Context {
  const ctx: common.Context = host_ctx !== null ? host_ctx : getContext() as common.Context;
  return ctx;
}

/** 服务 ①：DiagnosticLogger.DirectoryPath 的鸿蒙等价物。 */
function diagnostic_dir(): string {
  return ui_context().filesDir + '/iPhoneMirror/Logs';
}

/** 服务 ②：AppLog.Sanitize 里与本窗口相关的两条（URL 与长 Hex 设备标识）。 */
function sanitize_message(value: string): string {
  let text: string = value;
  const lower: string = text.toLowerCase();
  const urlAt: number = lower.indexOf('://');
  if (urlAt > 0) {
    text = '<url>';
  }
  const hexMatch: boolean = /[0-9a-f]{20,}/.test(lower);
  if (hexMatch) {
    text = '<device-id>';
  }
  return text.length > MAX_MESSAGE_CHARS
    ? text.substring(0, MAX_MESSAGE_CHARS - 3) + '...'
    : text;
}

/** 服务 ①：DiagnosticLogger.FormatEntry 的顺序（pid/tid 在 ArkTS 取不到，写 0）。 */
function format_entry(level: string, category: string, eventName: string,
                      fields: string): string {
  let line: string = new Date().toISOString()
    + ' level=' + level
    + ' pid=0 tid=0'
    + ' category=' + category
    + ' event=' + eventName;
  if (fields.length > 0) {
    line = line + ' ' + fields;
  }
  return line;
}

/**
 * 服务 ①：写一条日志 —— hilog + AppStorage 缓冲（真做）。
 * 返回当前缓冲的完整文本，便于调用方直接刷新视图。
 */
function write_log(level: string, category: string, eventName: string,
                   fields: string): string {
  const line: string = format_entry(level, category, eventName, sanitize_message(fields));
  if (level === 'ERROR') {
    hilog.error(DOMAIN, TAG, '%{public}s', line);
  } else if (level === 'WARN') {
    hilog.warn(DOMAIN, TAG, '%{public}s', line);
  } else {
    hilog.info(DOMAIN, TAG, '%{public}s', line);
  }
  const buffered: string = AppStorage.get<string>(LOG_KEY) ?? '';
  const lines: string[] = buffered.length > 0 ? buffered.split('\n') : [];
  lines.push(line);
  while (lines.length > MAX_LOG_LINES) {
    lines.shift();
  }
  const text: string = lines.join('\n');
  AppStorage.setOrCreate<string>(LOG_KEY, text);
  return text;
}

// ───────────────────── 开窗入口 ─────────────────────

/** 原版 internal DeveloperToolsWindow(MainWindow owner) + Show()。 */
export function open_developer_tools(ctx: common.Context): void {
  host_ctx = ctx;
  // 服务 ①：原版 Initialize() 会写一条 session_start，这里等价写一条打开记录。
  write_log('INFO', 'ui', 'developer_tools_opened', '');

  const spec: SubWindowSpec = {
    name: WINDOW_NAME,
    page: PAGE_PATH,
    title: S_TITLE,
    width: 980,                       // Width="980"
    height: 760,                      // Height="760"
    resizable: true,                  // ResizeMode="CanResize"
    minWidth: 820,                    // MinWidth="820"
    minHeight: 620,                   // MinHeight="620"
    modal: false,                     // ShowInTaskbar="False" 的非模态工具窗
  };
  SubWindowHost.open(ctx, spec).catch((error: BusinessError): void => {
    hilog.error(DOMAIN, TAG, '打开失败: %{public}s', error.message);
  });
}

// ───────────────────── 局部控件 ─────────────────────

/**
 * 预览面按钮 —— 原版 ItemsControl 里的那个 Button：
 *   MinWidth 180 / Height 54 / Margin 0,0,8,8 / HorizontalContentAlignment Stretch
 *   Grid 两列 28 + *：SymbolIcon 16 垂直居中 + 标题 13 SemiBold + 描述 10 Muted 省略号
 */
@Component
struct SurfaceButton {
  @Prop iconName: string = '';
  @Prop itemTitle: string = '';
  @Prop itemDescription: string = '';
  @State hovered: boolean = false;
  on_action: () => void = () => {};

  build() {
    Row() {
      FluentSymbol({
        iconName: this.iconName,
        iconSize: 16,
        iconColor: TEXT,
      })
        .width(28);

      Column() {
        Text(this.itemTitle)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
        Text(this.itemDescription)
          .fontSize(10)
          .fontColor(MUTED_TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 2 });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);
    }
    .width('100%')
    .height(54)
    .padding({ left: 12, right: 12 })
    .borderRadius(BUTTON_CORNER)
    .backgroundColor(this.hovered ? CONTROL_HOVER : CONTROL_FILL)
    .border({ width: 1, color: BORDER })
    .alignItems(VerticalAlign.Center)
    .onHover((isHover: boolean): void => { this.hovered = isHover; })
    .onClick((): void => { this.on_action(); });
  }
}

/** DetailLabel 样式：MutedTextBrush / FontSize 11 / Margin "0,13,0,3"。 */
@Builder
function detail_label(text: string) {
  Text(text)
    .fontSize(11)
    .fontColor(MUTED_TEXT)
    .margin({ top: 13, bottom: 3 });
}

@Entry
@Component
struct DeveloperToolsWindow {
  @State statusText: string = '';
  @State diagnosticsText: string = '';
  @State versionText: string = '读取中';
  @State opacityValue: number = 1;
  @State opacityText: string = '100%';
  @State topmostOn: boolean = false;
  @State themeIndex: number = 0;
  @State languageIndex: number = 1;
  @State logText: string = '';
  @State openWindowNames: string[] = [];

  private workspaceItems: DeveloperSurfaceItem[] = build_workspace_items();
  private windowItems: DeveloperSurfaceItem[] = build_window_items();
  /** 平台替换 4：原版 DispatcherTimer(750 ms) → setInterval。 */
  private timerId: number = -1;

  aboutToAppear(): void {
    const storedLanguage: number = AppStorage.get<number>(PARAM_KEY_LANGUAGE) ?? 1;
    this.languageIndex = storedLanguage;
    this.opacityValue = AppStorage.get<number>(PARAM_KEY_OPACITY) ?? 1;
    this.topmostOn = AppStorage.get<boolean>(PARAM_KEY_TOPMOST) ?? false;
    const pref: number = AppStorage.get<number>(THEME_PREF_KEY) ?? 0;
    this.themeIndex = pref === 2 ? 1 : pref === 1 ? 2 : 0;
    this.opacityText = this.format_percent(this.opacityValue);
    this.logText = AppStorage.get<string>(LOG_KEY) ?? '';

    this.load_version();
    this.refresh_diagnostics();

    this.timerId = setInterval((): void => { this.refresh_diagnostics(); }, 750);
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    write_log('INFO', 'ui', 'developer_tools_closed', '');
  }

  // ── 运行期参数 ──

  private format_percent(value: number): string {
    return Math.round(value * 100).toString() + '%';
  }

  /** 平台替换 6（能真做的那部分）：主题切换 —— 写 themePref 并重算方案。 */
  private on_theme_changed(index: number): void {
    this.themeIndex = index;
    AppStorage.setOrCreate<number>(THEME_PREF_KEY, THEME_PREF_BY_INDEX[index]);
    recomputeThemeScheme();
    this.statusText = '应用主题已切换为「' + THEME_LABELS[index] + '」（当前进程生效）。';
    write_log('INFO', 'ui', 'developer_theme_changed', 'index=' + index.toString());
    this.refresh_diagnostics();
  }

  /** 平台替换 6：语言 —— 只有 zh-CN 一档可用。 */
  private on_language_changed(index: number): void {
    this.languageIndex = index;
    AppStorage.setOrCreate<number>(PARAM_KEY_LANGUAGE, index);
    if (LANGUAGE_TAGS[index] === 'zh-CN') {
      this.statusText = '当前已是简体中文。';
      return;
    }
    this.statusText = S_REASON_LANGUAGE;
  }

  /** 平台替换 6：透明度 —— 做不到，明说。 */
  private on_opacity_changed(value: number): void {
    this.opacityValue = value;
    AppStorage.setOrCreate<number>(PARAM_KEY_OPACITY, value);
    this.opacityText = this.format_percent(value);
    this.statusText = S_REASON_OPACITY;
  }

  /** 平台替换 6：置顶 —— 做不到，明说。 */
  private on_topmost_changed(isOn: boolean): void {
    this.topmostOn = isOn;
    AppStorage.setOrCreate<boolean>(PARAM_KEY_TOPMOST, isOn);
    this.statusText = S_REASON_TOPMOST;
  }

  /** 平台替换 6（真做）：窗口预设。 */
  private on_preset(tag: string): void {
    this.apply_window_preset(tag)
      .then((): void => {
        this.statusText = '窗口预设已应用：' + this.preset_label(tag);
        this.refresh_diagnostics();
      })
      .catch((error: BusinessError): void => {
        this.statusText = '窗口预设应用失败：' + error.message;
      });
  }

  private preset_label(tag: string): string {
    if (tag === 'compact') {
      return S_PRESET_COMPACT;
    }
    return tag === 'maximize' ? S_PRESET_MAXIMIZE : S_PRESET_DEFAULT;
  }

  /**
   * 原版 OnPresetClick：Normal → 改 Width/Height（或 Maximized）。
   * getLastWindow 在本 SDK 的声明里带 throws，包一层 try 把同步抛出转成 reject，
   * 调用方就能统一用 catch 拿到原因。
   */
  private apply_window_preset(tag: string): Promise<void> {
    const ctx: common.Context = ui_context();
    try {
      return window.getLastWindow(ctx).then((target: window.Window): Promise<void> => {
        if (tag === 'maximize') {
          return target.maximize();
        }
        const width: number = tag === 'compact' ? PRESET_COMPACT_WIDTH : PRESET_DEFAULT_WIDTH;
        const height: number = tag === 'compact' ? PRESET_COMPACT_HEIGHT : PRESET_DEFAULT_HEIGHT;
        return target.resize(width, height);
      });
    } catch (error) {
      return Promise.reject(error as BusinessError);
    }
  }

  /** 原版 OnRefreshClick：只 RefreshDiagnostics()。这里补一句状态，便于确认刷新发生。 */
  private on_refresh(): void {
    this.refresh_diagnostics();
    this.logText = AppStorage.get<string>(LOG_KEY) ?? '';
    this.statusText = '窗口检查器已刷新。';
  }

  /** 原版 OnResetClick：主题回 System、语言回系统、透明度 1、置顶 false、1540×900。 */
  private on_reset(): void {
    this.themeIndex = 0;
    AppStorage.setOrCreate<number>(THEME_PREF_KEY, 0);
    recomputeThemeScheme();
    this.languageIndex = 0;
    AppStorage.setOrCreate<number>(PARAM_KEY_LANGUAGE, 0);
    this.opacityValue = 1;
    this.opacityText = this.format_percent(1);
    this.topmostOn = false;
    AppStorage.setOrCreate<boolean>(PARAM_KEY_TOPMOST, false);
    this.apply_window_preset('default')
      .then((): void => {
        this.statusText = S_PARAMETERS_RESET + '（界面语言、主窗口透明度、主窗口置顶'
          + '在鸿蒙无对应能力，未变更。）';
        this.refresh_diagnostics();
      })
      .catch((error: BusinessError): void => {
        this.statusText = S_PARAMETERS_RESET + '（窗口尺寸应用失败：' + error.message + '）';
      });
  }

  // ── 预览面分发（平台替换 3） ──

  /**
   * 只有「投屏状态通知」四个预览在本工程有对应页面（真开窗）；
   * 其余如实报出缺哪个入口。
   */
  private preview_action(key: string): Promise<void> | null {
    const ctx: common.Context = ui_context();
    if (key === 'capture-error') {
      return show_developer_error_preview(ctx);
    }
    if (key === 'reverse-control-error') {
      return show_developer_reverse_control_error_preview(ctx);
    }
    if (key === 'session-closed') {
      return show_developer_stopped_preview(ctx);
    }
    if (key === 'usb-config-error') {
      return show_developer_usb_preview(ctx);
    }
    return null;
  }

  private on_surface_click(item: DeveloperSurfaceItem): void {
    const action: Promise<void> | null = this.preview_action(item.key);
    if (action === null) {
      this.statusText = S_SURFACE_OPEN_FAILED + '：' + S_REASON_NO_SURFACE
        + '（key=' + item.key + '）';
      return;
    }
    action
      .then((): void => {
        this.statusText = S_SURFACE_OPENED + '：' + item.title;
        this.refresh_diagnostics();
      })
      .catch((error: BusinessError): void => {
        this.statusText = S_SURFACE_OPEN_FAILED + '：' + error.message;
      });
  }

  // ── 窗口检查器 ──

  /** 原版 RefreshDiagnostics()：版本 / 区域 / 主题 / 文字缩放 / 窗口数。 */
  private refresh_diagnostics(): void {
    this.openWindowNames = this.detect_open_windows();
    const lines: string[] = [
      S_RUNTIME_VERSION + '：' + this.versionText,
      S_RUNTIME_CULTURE + '：zh-CN',
      S_RUNTIME_THEME + '：' + THEME_LABELS[this.themeIndex],
      S_RUNTIME_DPI + '：' + this.read_density().toFixed(2),
      S_RUNTIME_WINDOWS + '：' + this.openWindowNames.length.toString(),
    ];
    this.diagnosticsText = lines.concat(INTEGRITY_LINES).join('\n');
  }

  /** 原版 VisualTreeHelper.GetDpi(this).PixelsPerDip 的等价物（真做）。 */
  private read_density(): number {
    try {
      return display.getDefaultDisplaySync().densityPixels;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'getDefaultDisplaySync 失败: %{public}s',
        (error as BusinessError).message);
      return 1;
    }
  }

  /**
   * 原版 Application.Current.Windows（枚举进程内所有 WPF 窗口）。
   * 鸿蒙没有「枚举窗口」的 API，只有按名字查的 window.findWindow →
   * 这里按本工程已知的 17 个子窗口名逐个查，效果等价于原版列表（真做）。
   */
  private detect_open_windows(): string[] {
    const known: string[] = [
      'AdvancedSettingsWindow', 'ImageSettingsWindow', 'AirPlayDeviceSelectionWindow',
      'CaptureRecoveryWindow', 'ProtectedContentNoticeWindow', 'UsbProjectionModeInfoWindow',
      'AppPromptWindow', 'AboutWindow', 'StartupErrorWindow', 'UpdateWindow',
      'InstanceConflictWindow', 'BluetoothClientBindingWindow', 'BluetoothConnectionWindow',
      'BluetoothControlNoticeWindow', 'CaptureStatusNoticeWindow', 'DeviceBindingWindow',
    ];
    const found: string[] = [];
    for (let index: number = 0; index < known.length; ++index) {
      const name: string = known[index];
      try {
        const target: window.Window = window.findWindow(name);
        if (target !== undefined && target !== null) {
          found.push(name);
        }
      } catch (error) {
        // findWindow 对不存在的名字会抛错（SubWindowHost.find 同样是这么处理的）。
      }
    }
    return found;
  }

  /** 原版 OnActivateWindowClick：item.Window.Activate() + Focus()。 */
  private on_activate_window(name: string): void {
    try {
      const target: window.Window = window.findWindow(name);
      target.showWindow()
        .then((): void => { this.statusText = '已激活窗口：' + name; })
        .catch((error: BusinessError): void => {
          this.statusText = '激活失败：' + error.message;
        });
    } catch (error) {
      this.statusText = '激活失败：' + (error as BusinessError).message;
    }
  }

  /** 原版 OnCloseWindowClick（排除了 owner，这里排除自己）。 */
  private on_close_window(name: string): void {
    try {
      const target: window.Window = window.findWindow(name);
      target.destroyWindow()
        .then((): void => {
          this.statusText = '已关闭窗口：' + name;
          this.refresh_diagnostics();
        })
        .catch((error: BusinessError): void => {
          this.statusText = '关闭失败：' + error.message;
        });
    } catch (error) {
      this.statusText = '关闭失败：' + (error as BusinessError).message;
    }
  }

  private load_version(): void {
    try {
      bundleManager.getBundleInfoForSelf(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
        .then((info: bundleManager.BundleInfo): void => {
          this.versionText = 'v' + info.versionName;
          this.refresh_diagnostics();
        })
        .catch((error: BusinessError): void => {
          this.versionText = '未知';
          hilog.error(DOMAIN, TAG, 'getBundleInfoForSelf 失败: %{public}s', error.message);
        });
    } catch (error) {
      this.versionText = '未知';
      hilog.error(DOMAIN, TAG, 'getBundleInfoForSelf 抛错: %{public}s',
        (error as BusinessError).message);
    }
  }

  // ── 诊断日志（平台替换 7，真做） ──

  private on_copy_diagnostics(): void {
    const payload: string = this.diagnosticsText + '\n\n' + this.logText;
    try {
      const data: pasteboard.PasteData = pasteboard.createPlainTextData(payload);
      pasteboard.getSystemPasteboard().setData(data)
        .then((): void => {
          this.statusText = '已复制诊断信息（' + payload.length.toString() + ' 个字符）到剪贴板。';
        })
        .catch((error: BusinessError): void => {
          this.statusText = '复制失败：' + error.message;
        });
    } catch (error) {
      this.statusText = '复制失败：' + (error as BusinessError).message;
    }
  }

  /** 服务 ①：日志落盘（真做，写到 ctx.filesDir）。 */
  private on_export_logs(): void {
    const directory: string = diagnostic_dir();
    const path: string = directory + '/' + LOG_FILE_NAME;
    const payload: string = this.diagnosticsText + '\n\n' + this.logText + '\n';
    try {
      if (!fileIo.accessSync(directory)) {
        fileIo.mkdirSync(directory, true);
      }
      const file: fileIo.File = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.READ_WRITE);
      try {
        fileIo.writeSync(file.fd, payload);
      } finally {
        fileIo.closeSync(file);
      }
      this.statusText = '已导出日志：' + path + '（' + payload.length.toString() + ' 字节）。';
      write_log('INFO', 'logging', 'developer_logs_exported', 'bytes=' + payload.length.toString());
    } catch (error) {
      this.statusText = '导出失败：' + (error as BusinessError).message;
    }
  }

  /** 与原版「清空视图」一致：只清视图，不动磁盘。 */
  private on_clear_log_view(): void {
    AppStorage.setOrCreate<string>(LOG_KEY, '');
    this.logText = '';
    this.statusText = '日志视图已清空（不会删除磁盘日志）';
  }

  // ── 构建 ──

  /** 平台替换 2：下移一行的「只读预览」徽标。 */
  @Builder
  preview_badge() {
    Text(S_PREVIEW_BADGE)
      .fontSize(11)
      .fontWeight(FontWeight.Bold)
      .fontColor(WARNING)
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .borderRadius(8)
      .backgroundColor(WARNING_SURFACE)
      .border({ width: 1, color: WARNING });
  }

  /** 卡 1 / 卡 2 共用的 WrapPanel 按钮区。 */
  @Builder
  surface_grid(items: DeveloperSurfaceItem[]) {
    Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
      ForEach(items, (item: DeveloperSurfaceItem): void => {
        SurfaceButton({
          iconName: item.icon,
          itemTitle: item.title,
          itemDescription: item.description,
          on_action: (): void => { this.on_surface_click(item); },
        })
          .width(286)
          .margin({ right: 8, bottom: 8 });
      }, (item: DeveloperSurfaceItem): string => item.key);
    }
    .width('100%')
    .margin({ top: 12 });
  }

  @Builder
  workspace_card() {
    Column() {
      section_title(S_WORKSPACE_SECTION);
      hint_text(S_WORKSPACE_HINT);
      this.surface_grid(this.workspaceItems);
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%');
  }

  @Builder
  windows_card() {
    Column() {
      section_title(S_WINDOWS_SECTION);
      hint_text(S_WINDOWS_HINT);
      this.surface_grid(this.windowItems);
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%');
  }

  @Builder
  parameters_left() {
    Column() {
      detail_label(S_PARAM_THEME);
      Select(THEME_OPTIONS)
        .selected(this.themeIndex)
        .value(THEME_LABELS[this.themeIndex])
        .fontColor(TEXT)
        .optionFontColor(TEXT)
        .selectedOptionFontColor(TEXT)
        .width('100%')
        .onSelect((index: number): void => { this.on_theme_changed(index); });

      Text(S_PARAM_LANGUAGE)
        .fontSize(11)
        .fontColor(MUTED_TEXT)
        .margin({ top: 14, bottom: 3 });
      Select(LANGUAGE_OPTIONS)
        .selected(this.languageIndex)
        .value(LANGUAGE_LABELS[this.languageIndex])
        .fontColor(TEXT)
        .optionFontColor(TEXT)
        .selectedOptionFontColor(TEXT)
        .width('100%')
        .onSelect((index: number): void => { this.on_language_changed(index); });
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1);
  }

  @Builder
  parameters_right() {
    Column() {
      detail_label(S_PARAM_OPACITY);
      Slider({
        value: this.opacityValue,
        min: 0.72,
        max: 1,
        step: 0.01,
        style: SliderStyle.OutSet,
      })
        .width('100%')
        .trackColor(SLIDER_TRACK)
        .blockColor(SLIDER_THUMB_FILL)
        .selectedColor(ACCENT)
        .margin({ top: 8 })
        .onChange((value: number): void => { this.on_opacity_changed(value); });
      Text(this.opacityText)
        .fontSize(11)
        .fontColor(MUTED_TEXT)
        .margin({ top: 2 });

      Row() {
        // 平台替换 5：WPF CheckBox → ArkUI 的 Checkbox（与 AboutWindow 的
        // SettingsToggle 同一种写法）。
        Checkbox({ name: S_PARAM_TOPMOST, group: 'developerToolsParameters' })
          .select(this.topmostOn)
          .selectedColor(ACCENT)
          .width(20)
          .height(20)
          .onChange((value: boolean): void => { this.on_topmost_changed(value); });
        Text(S_PARAM_TOPMOST)
          .fontSize(12)
          .fontColor(TEXT)
          .margin({ left: 8 });
      }
      .width('100%')
      .margin({ top: 14 });

      Text(S_PARAM_PRESET)
        .fontSize(11)
        .fontColor(MUTED_TEXT)
        .margin({ top: 14, bottom: 3 });
      Row() {
        SecondaryButton({
          label: S_PRESET_COMPACT,
          minButtonWidth: 94,
          on_action: (): void => { this.on_preset('compact'); },
        })
          .margin({ right: 6 });
        SecondaryButton({
          label: S_PRESET_DEFAULT,
          minButtonWidth: 94,
          on_action: (): void => { this.on_preset('default'); },
        })
          .margin({ right: 6 });
        SecondaryButton({
          label: S_PRESET_MAXIMIZE,
          minButtonWidth: 94,
          on_action: (): void => { this.on_preset('maximize'); },
        });
      }
      .width('100%');
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1);
  }

  @Builder
  parameters_card() {
    Column() {
      section_title(S_PARAM_SECTION);
      hint_text(S_PARAM_HINT);

      Row() {
        this.parameters_left();
        Column().width(18);
        this.parameters_right();
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .margin({ top: 14 });

      Row() {
        SecondaryButton({
          label: S_RESET,
          minButtonWidth: 116,
          on_action: (): void => { this.on_reset(); },
        })
          .margin({ right: 8 });
        PrimaryButton({
          label: S_REFRESH,
          minButtonWidth: 116,
          on_action: (): void => { this.on_refresh(); },
        });
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: 14 });
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%');
  }

  @Builder
  open_window_row(name: string) {
    Row() {
      Text(name)
        .fontSize(12)
        .fontColor(TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1);
      SecondaryButton({
        label: S_ACTIVATE,
        minButtonWidth: 76,
        buttonHeight: 30,
        on_action: (): void => { this.on_activate_window(name); },
      });
      SecondaryButton({
        label: S_CLOSE_WINDOW,
        minButtonWidth: 64,
        buttonHeight: 30,
        on_action: (): void => { this.on_close_window(name); },
      })
        .margin({ left: 8 });
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .margin({ top: 3 });
  }

  @Builder
  inspector_card() {
    Column() {
      section_title(S_INSPECTOR_SECTION);
      Text(this.diagnosticsText)
        .fontSize(11)
        .fontColor(MUTED_TEXT)
        .fontFamily('monospace')
        .width('100%')
        .margin({ top: 10 });

      if (this.openWindowNames.length > 0) {
        Column() {
          ForEach(this.openWindowNames, (name: string): void => {
            this.open_window_row(name);
          }, (name: string): string => name);
        }
        .width('100%')
        .margin({ top: 10 });
      } else {
        Text('当前没有其它已打开的 iPhoneMirror 子窗口。')
          .fontSize(11)
          .fontColor(MUTED_TEXT)
          .width('100%')
          .margin({ top: 10 });
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%');
  }

  /** 平台替换 7：诊断日志卡（本工程新增）。 */
  @Builder
  diagnostics_card() {
    Column() {
      section_title(S_DIAGNOSTICS_SECTION);
      hint_text('日志由 hilog 与 AppStorage 键 ' + LOG_KEY + ' 承载；'
        + '「导出日志」写入 ' + diagnostic_dir() + '/' + LOG_FILE_NAME + '。');

      Scroll() {
        Text(this.logText.length > 0 ? this.logText : '（暂无日志）')
          .fontSize(11)
          .fontColor(MUTED_TEXT)
          .fontFamily('monospace')
          .width('100%');
      }
      .width('100%')
      .height(150)
      .margin({ top: 10 })
      .padding(10)
      .borderRadius(10)
      .backgroundColor(CONTROL_FILL)
      .border({ width: 1, color: BORDER_SOFT })
      .scrollBar(BarState.Auto)
      .align(Alignment.Top);

      Row() {
        SecondaryButton({
          label: '复制诊断信息',
          minButtonWidth: 116,
          on_action: (): void => { this.on_copy_diagnostics(); },
        })
          .margin({ right: 8 });
        SecondaryButton({
          label: '导出日志',
          minButtonWidth: 116,
          on_action: (): void => { this.on_export_logs(); },
        })
          .margin({ right: 8 });
        SecondaryButton({
          label: '清空视图',
          minButtonWidth: 116,
          on_action: (): void => { this.on_clear_log_view(); },
        });
      }
      .width('100%')
      .margin({ top: 12 });
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%');
  }

  @Builder
  body() {
    Scroll() {
      Column() {
        SettingsSection({ padH: 16, padV: 16, content: (): void => { this.workspace_card(); } });
        SettingsSection({ padH: 16, padV: 16, content: (): void => { this.windows_card(); } })
          .margin({ top: 12 });
        SettingsSection({ padH: 16, padV: 16, content: (): void => { this.parameters_card(); } })
          .margin({ top: 12 });
        SettingsSection({ padH: 16, padV: 16, content: (): void => { this.inspector_card(); } })
          .margin({ top: 12 });
        SettingsSection({ padH: 16, padV: 16, content: (): void => { this.diagnostics_card(); } })
          .margin({ top: 12 });
      }
      .width('100%');
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Auto)
    .align(Alignment.Top);
  }

  /** Row 2：左 = StatusText，右 = 「关闭」主按钮（MinWidth 96）。 */
  @Builder
  actions() {
    Text(this.statusText)
      .fontSize(12)
      .fontColor(MUTED_TEXT)
      .maxLines(3)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .layoutWeight(1);
    PrimaryButton({
      label: S_CLOSE,
      minButtonWidth: 96,
      on_action: (): void => { SubWindowHost.close(WINDOW_NAME); },
    });
  }

  build() {
    Column() {
      SubWindowShell({
      windowName: WINDOW_NAME,
      title: S_TITLE,
      subtitle: S_SUBTITLE,
      shellBackground: DIALOG_SURFACE,   // Background="DialogSurfaceBrush"
      gap: 12,                           // ScrollViewer Margin="0,12,0,0"
      hasNotice: true,                   // 平台替换 2：下移一行的「只读预览」徽标
      noticeGap: 12,
      hasFooter: false,
      hasActions: true,
      actionGap: 12,                     // Row 2 的 Grid Margin="0,12,0,0"
      actionsSplit: false,               // StatusText 用 layoutWeight(1) 顶到左侧
      notice: (): void => { this.preview_badge(); },
      content: (): void => { this.body(); },
      actions: (): void => { this.actions(); },
    });
    }
  }
}
