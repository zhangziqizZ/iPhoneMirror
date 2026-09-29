// ProjectionSettingsWindow.ets —— 子窗口 12/20：投屏设置（浮层控制台）
//
// 逐项对照上游 src/App/Windows/ProjectionSettingsWindow.xaml（231 行）
//              src/App/Windows/ProjectionSettingsWindow.xaml.cs（67 行）
//   两侧对照：main（1.8.4，本文件以它为准）；linux-port（1.8.1）已读过，
//   差异只有一处：linux 的「无线 AirPlay」卡片没有 WirelessBackendLabel 那个 ComboBox
//   （没有WirelessReceiverBackends 数据源）。本文件按 main 保留该下拉框。
//
// ── 窗口属性（XAML 根元素 <ui:FluentWindow>）────────────────────────────────
//   Title="{DynamicResource ProjectionSettingsTitle}"  → 「投屏设置」
//   Width="500" Height="760" MinWidth="460" MinHeight="620"
//   WindowStartupLocation="CenterOwner"                → SubWindowHost.open 里算居中
//   ResizeMode="CanResize"                             → resizable: true
//   ExtendsContentIntoTitleBar="True"                  → decorEnabled: false + 自绘表头
//   WindowBackdropType="Mica" / WindowCornerPreference="Round" → 系统窗口负责
//   Background="{DynamicResource AppBackgroundBrush}"   → shell 默认底色
//   animations:PageTransition.IsEnabled="True"          → 入场过场，界面层不复现
//
// ── 行定义（Grid.RowDefinitions，仅 3 行；本窗口没有底部按钮条）──────────────
//   Row Auto : Grid Style=SubWindowHeader，列 = * / Auto / 10 / Auto
//                列 0：StackPanel
//                        TextBlock ProjectionSettingsTitle    Style=SubWindowTitle
//                        TextBlock {Binding SelectedName}     Style=SubWindowSubtitle
//                        TextBlock {Binding SelectedConnection} FontSize 10 / Muted
//                列 1：StackPanel Orientation=Horizontal, VCenter
//                        Button StartMirroring「开始投屏」Style=ToolButton MinWidth 72
//                               Margin 0,0,8,0 + WindowChrome.IsHitTestVisibleInChrome
//                        Button StopMirroring「停止投屏」Style=ToolButton MinWidth 72
//                列 3：Button Style=SubWindowCloseButton + SymbolIcon Dismiss20/18
//   Row 16   : 间隔
//   Row *    : Border Style=CardBorder Padding="18,4,10,18"
//                ScrollViewer Vertical=Auto / Horizontal=Disabled
//                  StackPanel Margin="0,0,8,0"
//
// ── 局部样式（只在本文档 XAML 里出现，故在文件内复刻）────────────────────────
//   DetailLabel         : MutedTextBrush / 11 / Margin 0,13,0,3
//   ControlSectionCard  : 透明底 / BorderSoftBrush **只上边** 1px / Padding 0,14,0,0
//                         / Margin 0,14,0,0
//   ControlSectionTitle : TextBrush / 13 / SemiBold
//   ToolButton          : PanelAltBrush 底 / TextBrush 字 / 12 / MinHeight 36
//                         / Padding 8,7
//   CardBorder（App.xaml）：CardBrush 底 / BorderBrush 1px / 圆角 16 / Padding 18
//                         / DropShadowEffect BlurRadius 18（阴影在 ArkUI 无等价物，略）
//
// ── 卡片 1..4（ScrollViewer 里的四个 Border）────────────────────────────────
//   ① ApplicationModeLabel「应用模式」+ ComboBox SelectedValuePath=Tag
//      （Tag 取 updater:ApplicationDisplayMode 的 Lightweight / Complete）
//      两个 ComboBoxItem 文案 = ApplicationModeLightweight「轻量模式」/
//      ApplicationModeComplete「完整模式」；ComboBox Margin 0,10,0,0
//   ② Visibility={Binding WirelessTopSettingsVisibility}
//      WirelessReceiverTitle「无线 AirPlay」
//        WirelessBackendLabel「接收方案」+ ComboBox WirelessReceiverBackends
//        （DisplayMemberPath=Label，AutomationId=WirelessBackendComboBox）      ← main 专有
//        TextBlock {Binding AppliedWirelessBackendDisplay} 10 / Wrap / Muted / 0,5,0,0
//        WirelessResolutionLabel「连接分辨率」+ ComboBox WirelessDisplayProfiles
//        Grid Margin 0,10,0,0 列=* /8/ Auto
//          列 0：TextBox {Binding WirelessReceiverName} MaxLength 63 Height 36
//          列 2：Button ApplyWirelessSettings「应用」
//        TextBlock {Binding WirelessStatus} 10 / Wrap / Muted / 0,7,0,0
//   ③ Visibility={Binding VideoSettingsVisibility}
//      ImageAndSound「画面与声音」
//        StackPanel Visibility={Binding WiredVideoLimitSettingsVisibility}
//          RenderResolutionLimit「渲染分辨率上限」+ ComboBox ResolutionPresets
//          TargetFrameRate「本地渲染帧率上限」+ ComboBox FrameRates
//          （两者 IsEnabled={Binding CanChangeVideoPipeline}）
//        DecoderPreferenceLabel「解码器」+ ComboBox DecoderPreferences
//          （IsEnabled={Binding CanChangeDecoderPipeline}）
//        Grid Margin 0,11,0,0 列=* /8/ *
//          Button ApplyVideoSettings「应用画面设置」/ Button MoreImageSettingsButton「更多设置」
//        TextBlock {Binding SettingsStatus}  /  {Binding DecoderStatus}（后者带 Visibility）
//        Border Height 1 BorderSoftBrush Margin 0,14,0,12        ← 分隔线
//        CheckBox PlayAudio「在此设备播放声音」
//        Grid Margin 0,10,0,0 列=* / Auto：PlaybackVolume 标签 + {0:F0}% 数值
//        Slider Minimum 0 Maximum 100 Value={Binding PlaybackVolume} Margin 0,5,0,0
//   ④ Border 默认 Collapsed，Visibility 由两个 DataTrigger 打开
//      （HasCaptureSession=True 或 IsMediaCasting=True）
//      PreviewAndObs「预览与 OBS」
//        UniformGrid Columns=2 Margin 0,10,0,0，边距按 4px 半格排布
//          RefreshFrame「刷新画面」/ FullScreenPreview「全屏预览」
//          SeparateWindow「独立窗口」/ Screenshot「截图」
//        Button MediaOutputButton「录制与推流」HorizontalAlignment=Stretch
//               MinHeight 44 / FontSize 13 / Margin 0,10,0,0
//
// ── xaml.cs 的行为 ────────────────────────────────────────────────────────
//   构造函数收 (object dataContext, Func<Task> refresh, Func<Task> fullScreen,
//   Func<Task> separateWindow, Func<Task> screenshot, Action mediaOutput) 六个实参。
//   OnRefreshClick / OnFullScreenClick / OnSeparateWindowClick / OnScreenshotClick
//     都走 `private static async Task RunAsync(Func<Task> action)`：try/catch 后
//     只 DiagnosticLogger.Exception("window", "projection_action_failed", error)
//     ——原版注释写得很清楚：主窗口自己会发布本地化的 UI 与诊断信息，浮层面板
//       必须保持可用，所以这里吞异常、不在浮层上显示错误。
//   OnMediaOutputClick → _mediaOutput()   OnCloseClick → Close()
//   ShowDeveloperPreview(owner, dataContext)：五个委托全换成空实现，用 Show() 打开。
//
// ── 平台替换 ──────────────────────────────────────────────────────────────
//   ① 五个构造函数委托（refresh / fullScreen / separateWindow / screenshot / mediaOutput）
//      → 鸿蒙子窗口只能传页面路径字符串，没法塞委托；沿用本工程的 AppStorage 总线 +
//        模块级导出函数。其中 **两处是真做** 的：
//          · mediaOutput「录制与推流」→ 直接 open_media_output_settings() 打开
//            同级子窗口（MediaOutputSettingsWindow），属于本工程真实存在的页面；
//          · moreImageSettings「更多设置」→ 直接 open_image_settings() 打开
//            ImageSettingsWindow（本工程真实存在）。
//   ② separateWindow「独立窗口」→ AspectRatioWindowController.cs 的**移植版真做**：
//      原版用 SetWindowPos / WM_SIZING 把一个原生 HWND 预览窗的客户区锁在源视频宽高比上；
//      鸿蒙没有「ArkTS 创建原生预览窗」，于是把同一套比例换算施加到宿主主窗口上
//      ——ValidAspect(0.05..20)、兜底 201/437、InitialWorkAreaFraction 0.82、
//      ChangedWorkAreaFraction 0.92、旋转时保持可视面积这几条常量与算式全部照搬。
//      差异：WM_SIZING 没有 ArkTS 等价物，所以只能在「应用时」把窗口调整为正确比例，
//            无法在用户拖拽过程中逐帧纠偏。这一点在文件头写清楚，不假装一致。
//   ③ DeviceCornerProfile.cs / DeviceCornerProfileResolver.cs：源文件的圆角（Jetpack
//      GetGdiRadius，短边比例 + 6px 抗锯齿下限）由 GDI 画出来的自绘窗口描边实现；
//      鸿蒙窗口圆角由系统绘制，不对三方应用开放圆角半径接口，故本窗口不复刻。
//   ④ PlayAudioWindows 的原文是「在 Windows 播放声音」——写死宿主操作系统名，
//      按本工程规矩改成事实描述「在此设备播放声音」。这是唯一一处文案改写。
//   ⑤ StableDeviceSelection.cs 的 ChooseUdid 是纯策略，可以直接移植，下面
//      choose_udid() 就是它的一比一移植，用来决定本面板正对着哪台设备。
//      UsbDeviceRefreshPolicy.IsUsbTransitionState（ActivatingUsb / WaitingForDevice /
//      Handshaking / Stopping）是上游 ViewModel 里算出 CanChangeVideoPipeline 的输入，
//      属于 Host 侧；本文件只消费算好的布尔值。
//   ⑥ 表头里的「开始投屏 / 停止投屏」两个按钮：上游是 WindowChrome.
//      IsHitTestVisibleInChrome="True" 把它们 **(标题栏内可点)**；共享外壳的标题栏
//      只暴露 title/subtitle/关闭按钮，所以这两个按钮挪到了表头下面同一行的右端。
//      SelectedConnection（FontSize 10）同行左端，原版在表头第三行。
//
// ── 文案来源 Strings.zh-CN.xaml（逐字取用）────────────────────────────────
//   ProjectionSettingsTitle「投屏设置」ApplicationModeLabel「应用模式」
//   ApplicationModeLightweight「轻量模式」ApplicationModeComplete「完整模式」
//   WirelessReceiverTitle「无线 AirPlay」WirelessBackendLabel「接收方案」
//   WirelessResolutionLabel「连接分辨率」ApplyWirelessSettings「应用」
//   ImageAndSound「画面与声音」RenderResolutionLimit「渲染分辨率上限」
//   TargetFrameRate「本地渲染帧率上限」DecoderPreferenceLabel「解码器」
//   ApplyVideoSettings「应用画面设置」MoreImageSettingsButton「更多设置」
//   PlaybackVolume「播放音量」PreviewAndObs「预览与 OBS」
//   RefreshFrame「刷新画面」FullScreenPreview「全屏预览」SeparateWindow「独立窗口」
//   Screenshot「截图」MediaOutputButton「录制与推流」
//   StartMirroring「开始投屏」StopMirroring「停止投屏」
//
// ── AppStorage 键名 ───────────────────────────────────────────────────────
//   入参 im.projection.*（selectedName / selectedConnection / visibleUdids /
//        previousUdid / activeCaptureUdid / newlyConnectedWirelessUdid /
//        appMode / wireless* / video* / resolutionIndex / frameRateIndex /
//        decoderIndex / settingsStatus / decoderStatus / playAudio / playbackVolume /
//        hasCaptureSession / isMediaCasting / sourceWidth / sourceHeight）
//   出参 im.projection.*Request（start / stop / applyVideo / applyWireless /
//        separateWindow / aspectRatio）

import window from '@ohos.window';
import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  SubWindowShell, SubWindowHost, RoundedTextBox, SubWindowSpec, SUBWINDOW_ROW_GAP,
} from '../../common/SubWindow';
import {
  TEXT, MUTED_TEXT, CARD, BORDER, BORDER_SOFT, PANEL_ALT, CONTROL_FILL, ACCENT,
  DISABLED_OPACITY, SLIDER_TRACK, SLIDER_THUMB_FILL, SLIDER_TRACK_THICKNESS,
  SLIDER_THUMB_BORDER, SLIDER_THUMB_STROKE,
} from '../../common/Theme';
import {
  open_image_settings, ImageSettingsArgs,
} from './ImageSettingsWindow';
import {
  open_media_output_settings,
} from './MediaOutputSettingsWindow';

const TAG: string = 'im_projection_settings';
const DOMAIN: number = 0x0100;

export const WINDOW_NAME: string = 'ProjectionSettingsWindow';
export const PAGE_PATH: string = 'pages/windows/ProjectionSettingsWindow';

// ── AppStorage：原版 DataContext（MainViewModel）的绑定通道 ──

/** {Binding SelectedName} —— SubWindowSubtitle */
export const ARG_KEY_SELECTED_NAME: string = 'im.projection.selectedName';
/** {Binding SelectedConnection} —— 表头第三行，FontSize 10 */
export const ARG_KEY_SELECTED_CONNECTION: string = 'im.projection.selectedConnection';
/** StableDeviceSelection 的四个入参（见平台替换 ⑤） */
export const ARG_KEY_VISIBLE_UDIDS: string = 'im.projection.visibleUdids';
export const ARG_KEY_PREVIOUS_UDID: string = 'im.projection.previousUdid';
export const ARG_KEY_ACTIVE_CAPTURE_UDID: string = 'im.projection.activeCaptureUdid';
export const ARG_KEY_NEWLY_CONNECTED_WIRELESS_UDID: string =
  'im.projection.newlyConnectedWirelessUdid';
/** SelectedApplicationDisplayMode（Tag = updater:ApplicationDisplayMode） */
export const ARG_KEY_APP_MODE: string = 'im.projection.appMode';
/** WirelessTopSettingsVisibility */
export const ARG_KEY_WIRELESS_TOP_VISIBLE: string = 'im.projection.wirelessTopVisible';
/** main 专有：WirelessReceiverBackends / 当前项 / AppliedWirelessBackendDisplay */
export const ARG_KEY_WIRELESS_BACKEND_INDEX: string = 'im.projection.wirelessBackendIndex';
export const ARG_KEY_APPLIED_WIRELESS_BACKEND: string = 'im.projection.appliedWirelessBackend';
/** WirelessDisplayProfiles / 当前项 */
export const ARG_KEY_WIRELESS_PROFILE_INDEX: string = 'im.projection.wirelessProfileIndex';
/** WirelessReceiverName（MaxLength 63）/ WirelessStatus */
export const ARG_KEY_WIRELESS_RECEIVER_NAME: string = 'im.projection.wirelessReceiverName';
export const ARG_KEY_WIRELESS_STATUS: string = 'im.projection.wirelessStatus';
/** VideoSettingsVisibility / WiredVideoLimitSettingsVisibility */
export const ARG_KEY_VIDEO_VISIBLE: string = 'im.projection.videoVisible';
export const ARG_KEY_WIRED_VIDEO_LIMIT_VISIBLE: string = 'im.projection.wiredVideoLimitVisible';
/** CanChangeVideoPipeline / CanChangeDecoderPipeline（上游由 UsbDeviceRefreshPolicy 参与算出） */
export const ARG_KEY_CAN_CHANGE_VIDEO: string = 'im.projection.canChangeVideo';
export const ARG_KEY_CAN_CHANGE_DECODER: string = 'im.projection.canChangeDecoder';
/** SelectedResolutionPreset / SelectedFrameRate / SelectedDecoderPreference */
export const ARG_KEY_RESOLUTION_INDEX: string = 'im.projection.resolutionIndex';
export const ARG_KEY_FRAME_RATE_INDEX: string = 'im.projection.frameRateIndex';
export const ARG_KEY_DECODER_INDEX: string = 'im.projection.decoderIndex';
/** SettingsStatus / DecoderStatus / DecoderStatusVisibility */
export const ARG_KEY_SETTINGS_STATUS: string = 'im.projection.settingsStatus';
export const ARG_KEY_DECODER_STATUS: string = 'im.projection.decoderStatus';
export const ARG_KEY_DECODER_STATUS_VISIBLE: string = 'im.projection.decoderStatusVisible';
/** PlayAudio / PlaybackVolume */
export const ARG_KEY_PLAY_AUDIO: string = 'im.projection.playAudio';
export const ARG_KEY_PLAYBACK_VOLUME: string = 'im.projection.playbackVolume';
/** HasCaptureSession / IsMediaCasting —— 卡片 ④ 的两个 DataTrigger */
export const ARG_KEY_HAS_CAPTURE_SESSION: string = 'im.projection.hasCaptureSession';
export const ARG_KEY_IS_MEDIA_CASTING: string = 'im.projection.isMediaCasting';
/** AspectRatioWindowController 的输入：源视频宽高 */
export const ARG_KEY_SOURCE_WIDTH: string = 'im.projection.sourceWidth';
export const ARG_KEY_SOURCE_HEIGHT: string = 'im.projection.sourceHeight';

/** 出参：表头两个 Command 与「应用」系列按钮的总线。 */
export const OUT_KEY_START_REQUESTED: string = 'im.projection.startRequested';
export const OUT_KEY_STOP_REQUESTED: string = 'im.projection.stopRequested';
export const OUT_KEY_APPLY_VIDEO_REQUESTED: string = 'im.projection.applyVideoRequested';
export const OUT_KEY_APPLY_WIRELESS_REQUESTED: string = 'im.projection.applyWirelessRequested';
export const OUT_KEY_SEPARATE_WINDOW_REQUESTED: string = 'im.projection.separateWindowRequested';
export const OUT_KEY_ASPECT_RATIO_WINDOW: string = 'im.projection.aspectRatioWindowSize';

// ── 选项表（与主窗口 pages/Index.ets 第 109-174 行同源，文案逐个一致）──

// Strings: ApplicationModeLightweight / ApplicationModeComplete
const APPLICATION_MODE_LABELS: string[] = ['轻量模式', '完整模式'];
const APPLICATION_MODE_OPTIONS: SelectOption[] =
  [{ value: '轻量模式' }, { value: '完整模式' }];

// Strings: WirelessBackendOriginal「原始方案」/ WirelessBackendUxPlay「UxPlay（备用）」
const WIRELESS_BACKEND_LABELS: string[] = ['原始方案', 'UxPlay（备用）'];
const WIRELESS_BACKEND_OPTIONS: SelectOption[] =
  [{ value: '原始方案' }, { value: 'UxPlay（备用）' }];

// 同 Index.ets 的 WIRELESS_PROFILE_LABELS
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

// Strings: ResolutionNative / Resolution1080p / Resolution720p / Resolution540p
const RESOLUTION_PRESETS: SelectOption[] = [
  { value: '原生（不限制渲染尺寸）' },
  { value: '1080p（1920×1080）' },
  { value: '720p（1280×720）' },
  { value: '540p（960×540）' },
];

// 原版 FrameRates 集合：[120, 60, 30, 24]（降序，含 24fps）
const FRAME_RATE_LABELS: string[] = ['120', '60', '30', '24'];
const FRAME_RATE_OPTIONS: SelectOption[] =
  [{ value: '120' }, { value: '60' }, { value: '30' }, { value: '24' }];

// Strings: DecoderAuto / DecoderHardwarePreferred / DecoderSoftwareCompatible
const DECODER_PREFERENCE_LABELS: string[] = ['自动（推荐）', '硬件优先', '软件兼容'];
const DECODER_PREFERENCE_OPTIONS: SelectOption[] =
  [{ value: '自动（推荐）' }, { value: '硬件优先' }, { value: '软件兼容' }];

// ── AspectRatioWindowController.cs 的几个常量（照搬，不改值）──
const INITIAL_WORK_AREA_FRACTION: number = 0.82;
const CHANGED_WORK_AREA_FRACTION: number = 0.92;
const FALLBACK_ASPECT_RATIO: number = 201.0 / 437.0;
const MIN_ASPECT: number = 0.05;
const MAX_ASPECT: number = 20.0;

/** 三个尚未接入的能力的确切原因（不假成功）。 */
const REASON_REFRESH_FRAME: string =
  '刷新画面：鸿蒙版待接入（上游为 NativePreviewWindow 的帧重绘请求）。';
const REASON_FULL_SCREEN: string =
  '全屏预览：鸿蒙版待接入（上游为 Win32 全屏窗口切换）。';
const REASON_SCREENSHOT: string =
  '截图：鸿蒙版待接入（上游依赖 Core 的 BGRA 帧拷贝接口）。';
const REASON_COMMAND_BUS: string =
  '请求已写入 AppStorage 总线，但宿主主窗口尚未订阅该键（原版由 MainWindow 注入 Command）。';

/**
 * Style x:Key="ToolButton"（本窗口版本）—— PanelAltBrush 底 / TextBrush 字 /
 * FontSize 12 / MinHeight 36 / Padding 8,7。表头两个键、②/④ 的五个键都用它。
 */
@Component
struct ToolButton {
  @Prop label: string = '';
  @Prop minButtonWidth: number = 0;
  @Prop boxHeight: number = 36;
  @Prop buttonWidthPct: string = '';
  // ⚠ 不能叫 `enabled` / `width`：CommonMethod 里已有同名方法，会报 TS2416。
  @Prop actionEnabled: boolean = true;
  @State hovered: boolean = false;
  on_action: () => void = () => {};

  build() {
    Text(this.label)
      .fontSize(12)
      .fontColor(TEXT)
      .textAlign(TextAlign.Center)
      .height(this.boxHeight)
      .width(this.buttonWidthPct.length > 0 ? this.buttonWidthPct : undefined)
      .padding({ left: 8, right: 8, top: 7, bottom: 7 })
      .constraintSize({ minWidth: this.minButtonWidth })
      .borderRadius(11)
      .backgroundColor(this.hovered ? CONTROL_FILL : PANEL_ALT)
      .border({ width: 1, color: BORDER })
      .opacity(this.actionEnabled ? 1 : DISABLED_OPACITY)
      .onHover((isHover: boolean): void => { this.hovered = isHover; })
      .onClick((): void => { this.on_action(); });
  }
}

/**
 * Style x:Key="ControlSectionCard" —— 透明底 / BorderSoftBrush **只有上边** 1px /
 * Padding 0,14,0,0 / Margin 0,14,0,0。四张卡片共用。
 */
@Component
struct ControlSectionCard {
  @Prop titleText: string = '';

  @Builder
  empty_slot() {}

  @BuilderParam content: () => void = this.empty_slot;

  build() {
    Column() {
      // Style=ControlSectionTitle：TextBrush / 13 / SemiBold
      Text(this.titleText)
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT)
        .width('100%');
      Column() {
        this.content();
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .margin({ top: 10 });
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ top: 14 })
    .borderWidth({ top: 1, right: 0, bottom: 0, left: 0 })
    .borderColor(BORDER_SOFT)
    .margin({ top: 14 });
  }
}

/**
 * Style x:Key="DetailLabel"（本窗口版本）—— MutedTextBrush / FontSize 11 /
 * Margin 0,13,0,3。
 */
@Builder
function detail_label(text: string) {
  Text(text)
    .fontSize(11)
    .fontColor(MUTED_TEXT)
    .width('100%')
    .margin({ top: 13, bottom: 3 });
}

/** 卡片里那些 FontSize 10 的状态行（SettingsStatus / DecoderStatus / WirelessStatus）。 */
@Builder
function status_line(text: string, topMargin: number) {
  Text(text)
    .fontSize(10)
    .fontColor(MUTED_TEXT)
    .width('100%')
    .margin({ top: topMargin });
}

/**
 * StableDeviceSelection.ChooseUdid 的一比一移植。
 * 优先级：新连上的无线 > 上次选中 > 正在投屏 > 列表第一台。
 */
function choose_udid(visibleOrder: string[], previousSelectionUdid: string,
  activeCaptureUdid: string, newlyConnectedWirelessUdid: string): string {
  let chosen: string = '';
  for (let i: number = 0; i < visibleOrder.length; i++) {
    if (visibleOrder[i] === newlyConnectedWirelessUdid) {
      chosen = visibleOrder[i];
      break;
    }
  }
  if (chosen.length === 0) {
    for (let i: number = 0; i < visibleOrder.length; i++) {
      if (visibleOrder[i] === previousSelectionUdid) {
        chosen = visibleOrder[i];
        break;
      }
    }
  }
  if (chosen.length === 0) {
    for (let i: number = 0; i < visibleOrder.length; i++) {
      if (visibleOrder[i] === activeCaptureUdid) {
        chosen = visibleOrder[i];
        break;
      }
    }
  }
  if (chosen.length === 0 && visibleOrder.length > 0) {
    chosen = visibleOrder[0];
  }
  return chosen;
}

/** 按原版打开这个子窗口。 */
export function open_projection_settings(ctx: common.Context): void {
  const spec: SubWindowSpec = {
    name: WINDOW_NAME,
    page: PAGE_PATH,
    title: '投屏设置',              // Strings: ProjectionSettingsTitle
    width: 500,
    height: 760,
    resizable: true,                // ResizeMode="CanResize"
    minWidth: 460,
    minHeight: 620,
    modal: false,                   // Show() —— ShowDeveloperPreview 也是 Show()
  };
  SubWindowHost.open(ctx, spec).catch((error: BusinessError): void => {
    hilog.error(DOMAIN, TAG, '打开失败: %{public}s', error.message);
  });
}

@Entry
@Component
struct ProjectionSettingsWindow {
  // 表头
  @State selectedName: string = '';
  @State selectedConnection: string = '';
  @State targetUdid: string = '';
  // ① 应用模式
  @State appModeIndex: number = 0;
  // ② 无线 AirPlay
  @State wirelessTopVisible: boolean = false;
  @State wirelessBackendIndex: number = 0;
  @State appliedWirelessBackend: string = '';
  @State wirelessProfileIndex: number = 1;
  @State wirelessReceiverName: string = 'iPhoneMirror';
  @State wirelessStatus: string = '';
  // ③ 画面与声音
  @State videoVisible: boolean = true;
  @State wiredVideoLimitVisible: boolean = true;
  @State canChangeVideo: boolean = true;
  @State canChangeDecoder: boolean = true;
  @State resolutionIndex: number = 0;
  @State frameRateIndex: number = 1;
  @State decoderIndex: number = 0;
  @State settingsStatus: string = '';
  @State decoderStatus: string = '';
  @State decoderStatusVisible: boolean = false;
  @State playAudio: boolean = true;
  @State playbackVolume: number = 100;
  // ④ 预览与 OBS
  @State hasCaptureSession: boolean = false;
  @State isMediaCasting: boolean = false;
  // AspectRatioWindowController 的输入
  @State sourceWidth: number = 0;
  @State sourceHeight: number = 0;

  aboutToAppear(): void {
    this.selectedName = AppStorage.get<string>(ARG_KEY_SELECTED_NAME) ?? '';
    this.selectedConnection = AppStorage.get<string>(ARG_KEY_SELECTED_CONNECTION) ?? '';
    this.appModeIndex = AppStorage.get<number>(ARG_KEY_APP_MODE) ?? 0;
    this.wirelessTopVisible = AppStorage.get<boolean>(ARG_KEY_WIRELESS_TOP_VISIBLE) ?? false;
    this.wirelessBackendIndex = AppStorage.get<number>(ARG_KEY_WIRELESS_BACKEND_INDEX) ?? 0;
    this.appliedWirelessBackend = AppStorage.get<string>(ARG_KEY_APPLIED_WIRELESS_BACKEND) ?? '';
    this.wirelessProfileIndex = AppStorage.get<number>(ARG_KEY_WIRELESS_PROFILE_INDEX) ?? 1;
    this.wirelessReceiverName = AppStorage.get<string>(ARG_KEY_WIRELESS_RECEIVER_NAME) ??
      'iPhoneMirror';
    this.wirelessStatus = AppStorage.get<string>(ARG_KEY_WIRELESS_STATUS) ?? '';
    this.videoVisible = AppStorage.get<boolean>(ARG_KEY_VIDEO_VISIBLE) ?? true;
    this.wiredVideoLimitVisible =
      AppStorage.get<boolean>(ARG_KEY_WIRED_VIDEO_LIMIT_VISIBLE) ?? true;
    this.canChangeVideo = AppStorage.get<boolean>(ARG_KEY_CAN_CHANGE_VIDEO) ?? true;
    this.canChangeDecoder = AppStorage.get<boolean>(ARG_KEY_CAN_CHANGE_DECODER) ?? true;
    this.resolutionIndex = AppStorage.get<number>(ARG_KEY_RESOLUTION_INDEX) ?? 0;
    this.frameRateIndex = AppStorage.get<number>(ARG_KEY_FRAME_RATE_INDEX) ?? 1;
    this.decoderIndex = AppStorage.get<number>(ARG_KEY_DECODER_INDEX) ?? 0;
    this.settingsStatus = AppStorage.get<string>(ARG_KEY_SETTINGS_STATUS) ?? '';
    this.decoderStatus = AppStorage.get<string>(ARG_KEY_DECODER_STATUS) ?? '';
    this.decoderStatusVisible = AppStorage.get<boolean>(ARG_KEY_DECODER_STATUS_VISIBLE) ?? false;
    this.playAudio = AppStorage.get<boolean>(ARG_KEY_PLAY_AUDIO) ?? true;
    this.playbackVolume = AppStorage.get<number>(ARG_KEY_PLAYBACK_VOLUME) ?? 100;
    this.hasCaptureSession = AppStorage.get<boolean>(ARG_KEY_HAS_CAPTURE_SESSION) ?? false;
    this.isMediaCasting = AppStorage.get<boolean>(ARG_KEY_IS_MEDIA_CASTING) ?? false;
    this.sourceWidth = AppStorage.get<number>(ARG_KEY_SOURCE_WIDTH) ?? 0;
    this.sourceHeight = AppStorage.get<number>(ARG_KEY_SOURCE_HEIGHT) ?? 0;

    // 平台替换 ⑤：用 StableDeviceSelection.ChooseUdid 决定本面板对着哪台设备。
    const visible: string[] = AppStorage.get<string[]>(ARG_KEY_VISIBLE_UDIDS) ?? [];
    this.targetUdid = choose_udid(visible,
      AppStorage.get<string>(ARG_KEY_PREVIOUS_UDID) ?? '',
      AppStorage.get<string>(ARG_KEY_ACTIVE_CAPTURE_UDID) ?? '',
      AppStorage.get<string>(ARG_KEY_NEWLY_CONNECTED_WIRELESS_UDID) ?? '');
    if (this.selectedName.length === 0 && this.targetUdid.length > 0) {
      this.selectedName = this.targetUdid;
    }
    hilog.info(DOMAIN, TAG, '投屏设置窗口就绪：%{public}s', this.targetUdid);
  }

  // ───────────────────────── xaml.cs 的五个动作 ─────────────────────────

  /** cs OnMediaOutputClick → _mediaOutput() —— 平台替换 ①：真开窗。 */
  private on_media_output(): void {
    const ctx: common.Context = getContext(this) as common.Context;
    open_media_output_settings(ctx, false);
  }

  /** cs MoreImageSettingsCommand —— 平台替换 ①：真开窗。 */
  private on_more_image_settings(): void {
    const ctx: common.Context = getContext(this) as common.Context;
    const args: ImageSettingsArgs = { brightness: 0, contrast: 100, saturation: 100, gamma: 100 };
    open_image_settings(ctx, args);
  }

  /** cs OnRefreshClick。 */
  private on_refresh(): void {
    this.settingsStatus = REASON_REFRESH_FRAME;
  }

  /** cs OnFullScreenClick。 */
  private on_full_screen(): void {
    this.settingsStatus = REASON_FULL_SCREEN;
  }

  /** cs OnScreenshotClick。 */
  private on_screenshot(): void {
    this.settingsStatus = REASON_SCREENSHOT;
  }

  /**
   * cs OnSeparateWindowClick → await RunAsync(_separateWindow)。
   * 平台替换 ②：这里把 AspectRatioWindowController 的比例换算真的施加到宿主主窗口上。
   */
  private on_separate_window(): void {
    AppStorage.setOrCreate<boolean>(OUT_KEY_SEPARATE_WINDOW_REQUESTED, true);
    this.apply_aspect_ratio(false);
  }

  /**
   * AspectRatioWindowController.ResizeWindowToAspect(bool fitToWorkArea) 的移植。
   * 常量与算式逐条照搬：`ValidAspect` 的 0.05..20 判定、兜底 201/437、
   * InitialWorkAreaFraction 0.82、ChangedWorkAreaFraction 0.92、
   * 以及 fitToWorkArea=false 时「保持可视面积」那条 clientHeight = sqrt(area / aspect)。
   *
   * 差异（已在文件头写明，不假装一致）：
   *   · HWND + GetWindowRect/GetClientRect 的边框厚度测量没有 ArkTS 等价物，
   *     窗口矩形直接当作客户区来算（FrameWidth = FrameHeight = 0）；
   *   · WM_SIZING 钩子没有 ArkTS 等价物，因此只在「应用时」纠一次比例，
   *     无法像原版那样在用户拖拽边框时逐帧纠偏。
   */
  private apply_aspect_ratio(fitToWorkArea: boolean): void {
    let aspect: number = FALLBACK_ASPECT_RATIO;
    if (this.sourceWidth > 0 && this.sourceHeight > 0) {
      const ratio: number = this.sourceWidth / this.sourceHeight;
      if (ratio >= MIN_ASPECT && ratio <= MAX_ASPECT) {
        aspect = ratio;
      }
    }

    try {
      const ctx: common.Context = getContext(this) as common.Context;
      window.getLastWindow(ctx).then((target: window.Window): Promise<void> => {
        const rect: window.Rect = target.getWindowProperties().windowRect;
        const fraction: number = fitToWorkArea
          ? INITIAL_WORK_AREA_FRACTION : CHANGED_WORK_AREA_FRACTION;
        const availableWidth: number = rect.width * fraction;
        const availableHeight: number = rect.height * fraction;

        let clientWidth: number;
        let clientHeight: number;
        if (fitToWorkArea) {
          clientWidth = availableWidth;
          clientHeight = clientWidth / aspect;
          if (clientHeight > availableHeight) {
            clientHeight = availableHeight;
            clientWidth = clientHeight * aspect;
          }
        } else {
          // 保持可视面积：旋转 90° 时只换长边/短边，不会突然变大变小。
          const currentArea: number = rect.width * rect.height;
          clientHeight = Math.sqrt(currentArea / aspect);
          clientWidth = clientHeight * aspect;
        }
        // 同上：越界时按工作区上界把窗口压回去。
        const scaleDown: number = Math.min(1,
          Math.min(availableWidth / clientWidth, availableHeight / clientHeight));
        clientWidth = clientWidth * scaleDown;
        clientHeight = clientHeight * scaleDown;

        const widthPx: number = Math.max(1, Math.round(clientWidth));
        const heightPx: number = Math.max(1, Math.round(clientHeight));
        AppStorage.setOrCreate<string>(OUT_KEY_ASPECT_RATIO_WINDOW,
          `${widthPx}x${heightPx}`);
        this.settingsStatus = `已按源视频宽高比调整窗口：${widthPx}×${heightPx}（比例 ${aspect.toFixed(4)}）。`;
        return target.resize(widthPx, heightPx);
      }).catch((error: BusinessError): void => {
        hilog.warn(DOMAIN, TAG, '调整窗口比例失败: %{public}s', error.message);
        this.settingsStatus = `无法调整窗口宽高比：${error.message}`;
      });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'getLastWindow 失败: %{public}s',
        (error as BusinessError).message);
      this.settingsStatus = '无法调整窗口宽高比：拿不到宿主窗口。';
    }
  }

  /** 表头「开始投屏」—— StartCommand。 */
  private on_start(): void {
    AppStorage.setOrCreate<boolean>(OUT_KEY_START_REQUESTED, true);
    this.settingsStatus = `开始投屏：${REASON_COMMAND_BUS}`;
  }

  /** 表头「停止投屏」—— StopCommand。 */
  private on_stop(): void {
    AppStorage.setOrCreate<boolean>(OUT_KEY_STOP_REQUESTED, true);
    this.settingsStatus = `停止投屏：${REASON_COMMAND_BUS}`;
  }

  /** cs ApplyVideoSettingsCommand。 */
  private on_apply_video(): void {
    AppStorage.setOrCreate<boolean>(OUT_KEY_APPLY_VIDEO_REQUESTED, true);
    this.settingsStatus = `应用画面设置：${REASON_COMMAND_BUS}`;
  }

  /** cs ApplyWirelessSettingsCommand。 */
  private on_apply_wireless(): void {
    AppStorage.setOrCreate<boolean>(OUT_KEY_APPLY_WIRELESS_REQUESTED, true);
    this.wirelessStatus = `应用：${REASON_COMMAND_BUS}`;
  }

  // ───────────────────────── 界面 ─────────────────────────

  /**
   * 平台替换 ⑥：表头第三行（SelectedConnection，FontSize 10）与两个
   * WindowChrome.IsHitTestVisibleInChrome 按钮合成一行。
   */
  @Builder
  notice() {
    Row() {
      Text(this.selectedConnection)
        .fontSize(10)
        .fontColor(MUTED_TEXT)
        .layoutWeight(1);

      ToolButton({
        label: '开始投屏',                 // Strings: StartMirroring
        minButtonWidth: 72,
        on_action: (): void => { this.on_start(); },
      })
        .margin({ right: 8 });

      ToolButton({
        label: '停止投屏',                 // Strings: StopMirroring
        minButtonWidth: 72,
        on_action: (): void => { this.on_stop(); },
      });
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .margin({ top: 5 });
  }

  /** ① 应用模式。 */
  @Builder
  application_mode_card() {
    ControlSectionCard({ titleText: '应用模式', content: (): void => { this.application_mode_body(); } });
  }

  @Builder
  application_mode_body() {
    Column() {
      Select(APPLICATION_MODE_OPTIONS)
        .selected(this.appModeIndex)
        .value(APPLICATION_MODE_LABELS[this.appModeIndex])
        .fontColor(TEXT)
        .optionFontColor(TEXT)
        .selectedOptionFontColor(TEXT)
        .width('100%')
        .onSelect((index: number): void => {
          this.appModeIndex = index;
          AppStorage.setOrCreate<number>(ARG_KEY_APP_MODE, index);
        });
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .margin({ top: 10 });
  }

  /** ② 无线 AirPlay（Visibility=WirelessTopSettingsVisibility）。 */
  @Builder
  wireless_card() {
    if (this.wirelessTopVisible) {
      ControlSectionCard({ titleText: '无线 AirPlay', content: (): void => { this.wireless_body(); } });
    }
  }

  @Builder
  wireless_body() {
    Column() {
      // ── main 专有：WirelessBackendLabel + 方案下拉 ──
      detail_label('接收方案');
      Select(WIRELESS_BACKEND_OPTIONS)
        .selected(this.wirelessBackendIndex)
        .value(WIRELESS_BACKEND_LABELS[this.wirelessBackendIndex])
        .fontColor(TEXT)
        .optionFontColor(TEXT)
        .selectedOptionFontColor(TEXT)
        .width('100%')
        .onSelect((index: number): void => {
          this.wirelessBackendIndex = index;
          AppStorage.setOrCreate<number>(ARG_KEY_WIRELESS_BACKEND_INDEX, index);
        });
      if (this.appliedWirelessBackend.length > 0) {
        status_line(this.appliedWirelessBackend, 5);
      }

      detail_label('连接分辨率');
      Select(WIRELESS_PROFILE_OPTIONS)
        .selected(this.wirelessProfileIndex)
        .value(WIRELESS_PROFILE_LABELS[this.wirelessProfileIndex])
        .fontColor(TEXT)
        .optionFontColor(TEXT)
        .selectedOptionFontColor(TEXT)
        .width('100%')
        .onSelect((index: number): void => {
          this.wirelessProfileIndex = index;
          AppStorage.setOrCreate<number>(ARG_KEY_WIRELESS_PROFILE_INDEX, index);
        });

      // Grid Margin 0,10,0,0 列 = * / 8 / Auto
      Row() {
        RoundedTextBox({
          text: this.wirelessReceiverName,
          boxHeight: 36,
          on_text_change: (value: string): void => {
            // 原版 MaxLength="63"
            this.wirelessReceiverName = value.length > 63 ? value.substring(0, 63) : value;
          },
        })
          .layoutWeight(1);

        Column().width(8);

        ToolButton({
          label: '应用',                   // Strings: ApplyWirelessSettings
          on_action: (): void => { this.on_apply_wireless(); },
        });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 10 });

      status_line(this.wirelessStatus, 7);
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%');
  }

  /** ③ 画面与声音（Visibility=VideoSettingsVisibility）。 */
  @Builder
  video_card() {
    if (this.videoVisible) {
      ControlSectionCard({ titleText: '画面与声音', content: (): void => { this.video_body(); } });
    }
  }

  @Builder
  video_body() {
    Column() {
      // StackPanel Visibility=WiredVideoLimitSettingsVisibility
      if (this.wiredVideoLimitVisible) {
        detail_label('渲染分辨率上限');
        Select(RESOLUTION_PRESETS)
          .selected(this.resolutionIndex)
          .value(RESOLUTION_PRESETS[this.resolutionIndex].value)
          .fontColor(TEXT)
          .optionFontColor(TEXT)
          .selectedOptionFontColor(TEXT)
          .width('100%')
          .enabled(this.canChangeVideo)
          .opacity(this.canChangeVideo ? 1 : DISABLED_OPACITY)
          .onSelect((index: number): void => {
            this.resolutionIndex = index;
            AppStorage.setOrCreate<number>(ARG_KEY_RESOLUTION_INDEX, index);
          });

        detail_label('本地渲染帧率上限');
        Select(FRAME_RATE_OPTIONS)
          .selected(this.frameRateIndex)
          .value(FRAME_RATE_LABELS[this.frameRateIndex])
          .fontColor(TEXT)
          .optionFontColor(TEXT)
          .selectedOptionFontColor(TEXT)
          .width('100%')
          .enabled(this.canChangeVideo)
          .opacity(this.canChangeVideo ? 1 : DISABLED_OPACITY)
          .onSelect((index: number): void => {
            this.frameRateIndex = index;
            AppStorage.setOrCreate<number>(ARG_KEY_FRAME_RATE_INDEX, index);
          });
      }

      detail_label('解码器');
      Select(DECODER_PREFERENCE_OPTIONS)
        .selected(this.decoderIndex)
        .value(DECODER_PREFERENCE_LABELS[this.decoderIndex])
        .fontColor(TEXT)
        .optionFontColor(TEXT)
        .selectedOptionFontColor(TEXT)
        .width('100%')
        .enabled(this.canChangeDecoder)
        .opacity(this.canChangeDecoder ? 1 : DISABLED_OPACITY)
        .onSelect((index: number): void => {
          this.decoderIndex = index;
          AppStorage.setOrCreate<number>(ARG_KEY_DECODER_INDEX, index);
        });

      // Grid Margin 0,11,0,0 列 = * / 8 / *
      Row() {
        ToolButton({
          label: '应用画面设置',             // Strings: ApplyVideoSettings
          buttonWidthPct: '100%',
          on_action: (): void => { this.on_apply_video(); },
        })
          .layoutWeight(1);

        Column().width(8);

        ToolButton({
          label: '更多设置',                 // Strings: MoreImageSettingsButton
          buttonWidthPct: '100%',
          on_action: (): void => { this.on_more_image_settings(); },
        })
          .layoutWeight(1);
      }
      .width('100%')
      .margin({ top: 11 });

      status_line(this.settingsStatus, 7);
      if (this.decoderStatusVisible) {
        status_line(this.decoderStatus, 5);
      }

      // Border Height 1 / BorderSoftBrush / Margin 0,14,0,12
      Column()
        .width('100%')
        .height(1)
        .backgroundColor(BORDER_SOFT)
        .margin({ top: 14, bottom: 12 });

      // CheckBox PlayAudio —— 平台替换 ④：原文写死 "Windows"，改成事实描述
      Row() {
        Checkbox({ name: 'projection_play_audio', group: 'projection_audio' })
          .select(this.playAudio)
          .unselectedColor(BORDER)
          .selectedColor(ACCENT)
          .onChange((checked: boolean): void => {
            this.playAudio = checked;
            AppStorage.setOrCreate<boolean>(ARG_KEY_PLAY_AUDIO, checked);
          });
        Text('在此设备播放声音')             // Strings: PlayAudioWindows（已去"Windows"）
          .fontSize(12)
          .fontColor(TEXT)
          .margin({ left: 8 });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      // Grid Margin 0,10,0,0 列 = * / Auto
      Row() {
        Text('播放音量')                     // Strings: PlaybackVolume
          .fontSize(11)
          .fontColor(MUTED_TEXT)
          .layoutWeight(1);
        Text(`${Math.round(this.playbackVolume)}%`)   // StringFormat {0:F0}%
          .fontSize(11)
          .fontColor(TEXT);
      }
      .width('100%')
      .margin({ top: 10 })
      .alignItems(VerticalAlign.Center);

      Slider({
        value: this.playbackVolume,
        min: 0,
        max: 100,
        step: 1,
        style: SliderStyle.OutSet,
      })
        .width('100%')
        .height(20)
        .trackThickness(SLIDER_TRACK_THICKNESS)
        .trackColor(SLIDER_TRACK)
        .selectedColor(ACCENT)
        .blockColor(SLIDER_THUMB_FILL)
        .blockBorderColor(SLIDER_THUMB_BORDER)
        .blockBorderWidth(SLIDER_THUMB_STROKE)
        .margin({ top: 5 })
        .onChange((value: number): void => {
          this.playbackVolume = value;
          AppStorage.setOrCreate<number>(ARG_KEY_PLAYBACK_VOLUME, value);
        });
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%');
  }

  /** ④ 预览与 OBS（两个 DataTrigger：HasCaptureSession 或 IsMediaCasting）。 */
  @Builder
  preview_card() {
    if (this.hasCaptureSession || this.isMediaCasting) {
      ControlSectionCard({ titleText: '预览与 OBS', content: (): void => { this.preview_body(); } });
    }
  }

  @Builder
  preview_body() {
    Column() {
      // UniformGrid Columns=2：四个按钮半格边距 ±4
      Row() {
        ToolButton({
          label: '刷新画面',                 // Strings: RefreshFrame
          buttonWidthPct: '100%',
          on_action: (): void => { this.on_refresh(); },
        })
          .layoutWeight(1)
          .margin({ right: 4, bottom: 4 });

        ToolButton({
          label: '全屏预览',                 // Strings: FullScreenPreview
          buttonWidthPct: '100%',
          on_action: (): void => { this.on_full_screen(); },
        })
          .layoutWeight(1)
          .margin({ left: 4, bottom: 4 });
      }
      .width('100%');

      Row() {
        ToolButton({
          label: '独立窗口',                 // Strings: SeparateWindow
          buttonWidthPct: '100%',
          on_action: (): void => { this.on_separate_window(); },
        })
          .layoutWeight(1)
          .margin({ right: 4, top: 4 });

        ToolButton({
          label: '截图',                     // Strings: Screenshot
          buttonWidthPct: '100%',
          on_action: (): void => { this.on_screenshot(); },
        })
          .layoutWeight(1)
          .margin({ left: 4, top: 4 });
      }
      .width('100%');

      ToolButton({
        label: '录制与推流',                 // Strings: MediaOutputButton
        buttonWidthPct: '100%',
        boxHeight: 44,
        on_action: (): void => { this.on_media_output(); },
      })
        .margin({ top: 10 });
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%');
  }

  /** Row * ：Border Style=CardBorder Padding="18,4,10,18" + ScrollViewer。 */
  @Builder
  body() {
    Column() {
      Scroll() {
        Column() {
          this.application_mode_card();
          this.wireless_card();
          this.video_card();
          this.preview_card();
        }
        .width('100%')
        .padding({ right: 8 });            // StackPanel Margin="0,0,8,0"
      }
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring);
    }
    .width('100%')
    .height('100%')
    .padding({ left: 18, right: 10, top: 4, bottom: 18 })
    .borderRadius(16)
    .backgroundColor(CARD)
    .border({ width: 1, color: BORDER });
  }

  build() {
    Column() {
      SubWindowShell({
        windowName: WINDOW_NAME,
        title: '投屏设置',                  // Strings: ProjectionSettingsTitle
        subtitle: this.selectedName,        // {Binding SelectedName}
        gap: SUBWINDOW_ROW_GAP,             // 行 1 = 16
        hasNotice: true,                    // 平台替换 ⑥：连接信息 + 两个 Command 按钮
        noticeGap: 0,
        hasFooter: false,
        hasActions: false,                  // 原版只有 3 行，没有底部按钮条
        notice: (): void => { this.notice(); },
        content: (): void => { this.body(); },
      });
    }
  }
}
