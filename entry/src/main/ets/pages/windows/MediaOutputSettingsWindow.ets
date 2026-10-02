// MediaOutputSettingsWindow.ets —— 子窗口 11/20：输出设置（录制 / 直播推流 / 虚拟摄像头）
//
// 逐项对照上游 src/App/Windows/MediaOutputSettingsWindow.xaml（236 行）
//              src/App/Windows/MediaOutputSettingsWindow.xaml.cs（335 行）
//
// ── 窗口属性（XAML 根元素 <ui:FluentWindow>）────────────────────────────────
//   Title="{DynamicResource MediaOutputTitle}"        → 「输出设置」
//   Width="560" Height="660" MinWidth="500" MinHeight="560"
//   WindowStartupLocation="CenterOwner"               → SubWindowHost.open 里算居中
//   ResizeMode="CanResize"                            → resizable: true
//   ExtendsContentIntoTitleBar="True"                 → decorEnabled: false + 自绘表头
//   WindowBackdropType="Mica" / WindowCornerPreference="Round"
//                                                     → 由系统窗口负责，界面层无需复现
//   Background="{DynamicResource AppBackgroundBrush}" → SubWindowShell 的默认底色
//   animations:PageTransition.IsEnabled="True"        → 入场过场，界面层不复现
//
// ── 行定义（Grid.RowDefinitions，4 行）──────────────────────────────────────
//   Row Auto : Grid Style=SubWindowHeader（MinHeight 44，WindowDragBehavior）
//                StackPanel Margin="0,0,48,0"
//                  TextBlock Text=MediaOutputTitle          Style=SubWindowTitle
//                  TextBlock Text={Binding SelectedName}    Style=SubWindowSubtitle
//                  TextBlock Text={Binding MediaOutputCapabilitiesText}
//                            FontSize 10 / MutedTextBrush / Wrap / Margin 0,5,0,0
//                  Button Style=SubWindowCloseButton + SymbolIcon Dismiss20/18
//   Row 16   : 间隔（原版写死 16）
//   Row *    : TabControl Style=SubWindowTabControl
//                TabItem RecordTab        → ScrollViewer + Border Style=SectionCard
//                TabItem StreamTab        → 同上
//                TabItem VirtualCameraTab → 同上
//   Row Auto : Grid Margin="0,14,0,0"，列 = * / 8 / Auto
//                列 0：FeedbackText Text={Binding MediaOutputStatus}
//                      MutedTextBrush / 11 / Wrap / VCenter
//                列 2：Button 停止输出 Click=OnStopClick Style=ToolButton
//                      IsEnabled={Binding CanStopMediaOutput} MinWidth="110"
//
// ── 资源里的两处局部样式（其它窗口同名 Key 的值与本窗口不同，故局部复刻）────
//   DetailLabel  : MutedTextBrush / FontSize 11 / Margin 0,12,0,4
//   ToolButton   : PanelAltBrush 底 / TextBrush 字 / FontSize 12
//                  MinHeight 36 / Padding 10,7
//   SectionCard  : CardBrush 底 / BorderSoftBrush 1px 边 / 圆角 16
//                  Padding 16 / Margin 0,12,0,0
//   SubWindowTabControl（ModernControls.xaml）：
//      表头容器 ControlFillBrush 底 + BorderSoftBrush 1px 边 + 圆角 10 + Padding 2，
//      ItemsPanel = UniformGrid Rows=1（等宽）；表头文本取 SubWindowTabItem：
//      FontSize 14 / SemiBold / Padding 14,8 / Margin 2 / 未选中 MutedTextBrush
//
// ── 各 TabItem 内的控件（逐行）──────────────────────────────────────────────
//   录制：
//     TextBlock RecordDescription（Muted 12 Wrap）
//     Grid Margin="0,12,0,0" 列=* /8/ *：DetailLabel OutputWidth + RecordWidthBox
//                                        DetailLabel OutputHeight + RecordHeightBox
//     Grid 列=* /8/ *：DetailLabel OutputFps + RecordFpsBox
//                      DetailLabel OutputBitrate + RecordBitrateBox
//     Button StartRecording「开始录制」Click=OnStartRecordingClick
//            Style=PrimaryButton Margin="0,18,0,0" IsEnabled="False"
//   直播推流：
//     TextBlock StreamDescription（Muted 12 Wrap）
//     DetailLabel StreamProtocol + ComboBox StreamProtocolBox（SelectedIndex=0）
//       ComboBoxItem RTMP / SRT / WebRTC / WHIP，IsEnabled 各自绑定 CanStreamXxx
//     DetailLabel StreamDestination + StreamDestinationBox（Height 36）
//     DetailLabel StreamAuthorization + StreamAuthorizationBox（Height 36）
//     Grid 列=* /8/ *：宽、高   Grid 列=* /8/ *：帧率、码率
//     Button StartStreaming「开始直播推流」Click=OnStartStreamingClick
//            Style=PrimaryButton Margin="0,18,0,0" IsEnabled="False"
//   虚拟摄像头：
//     TextBlock VirtualCameraDescription（Muted 12 Wrap）
//     Grid Margin="0,4,0,0" 列=* /8/ *
//       列 0：DetailLabel ResolutionLabel + VirtualCameraResolutionBox
//             （含 Collapsed 的 VirtualCameraCurrentResolutionItem 与四个预设 Tag）
//       列 2：DetailLabel OutputFps + VirtualCameraFpsBox（30 / 60）
//     TextBlock {Binding VirtualCameraStatusText} Muted 12 Wrap Margin 0,14,0,0
//     Button {Binding VirtualCameraInstallActionText} Click=OnInstallVirtualCameraClick
//            PrimaryButton Margin 0,18,0,0 / IsEnabled + Visibility 均绑定
//     Button StartVirtualCamera「启动虚拟摄像头」Click=OnStartVirtualCameraClick
//            PrimaryButton Margin 0,18,0,0 / IsEnabled={Binding CanUseVirtualCamera}
//     Button UninstallVirtualCamera「卸载虚拟摄像头组件」Click=OnUninstallVirtualCameraClick
//            ToolButton Margin 0,10,0,0 / IsEnabled + Visibility 均绑定
//
// ── xaml.cs 的行为（逐条复刻）──────────────────────────────────────────────
//   · OnLoaded：ApplyPreviewOutputDefaults(force: true)
//               RecordFpsBox.Text = StreamFpsBox.Text = "30"
//               RecordBitrateBox.Text = StreamBitrateBox.Text = "6000"
//               VirtualCameraFpsBox.SelectedIndex = 0
//   · _previewOnly：FeedbackText = DeveloperReadOnlyPreview，两个开始键恒不可用
//   · 非预览：EnsureMediaOutputCapabilitiesAsync(force: true) → SelectFirstSupportedProtocol
//   · SelectFirstSupportedProtocol：当前项不支持则挑第一个支持项（顺序 RTMP→SRT→WHIP）
//   · OnStreamProtocolChanged → UpdateStartButtons
//   · TryReadOutputSettings：uint 宽高、int 帧率码率，且 width>=160 && height>=160
//     && fps 10..60 && bitrate 500..50000；否则 FeedbackText = MediaOutputInvalidSettings
//   · TryParseResolution：按 'x' 拆「宽 x 高」，两边都要能 uint 解析
//   · OnStartRecordingClick / OnStartStreamingClick / OnStartVirtualCameraClick
//     / OnInstallVirtualCameraClick / OnUninstallVirtualCameraClick：均以 result.Message 回写 FeedbackText
//   · OnStopClick：StopMediaOutputAsync() → PromptToSaveRecordingAsync()
//   · OnCloseClick：Close()
//
// ── 平台替换（原版机制在鸿蒙没有对应物；逐条对应 cs 里的那段实现）────────────
//   ① FFmpeg 进程管线（cs 依赖 MediaOutputService.StartAsync：Process.Start("ffmpeg")
//      + 命名管道喂 NV12 帧 + libx264/h264_nvenc 编码 + MP4/RTMP/SRT/WHIP 复用）
//      → OpenHarmony 三方应用不能 spawn 外部可执行文件，也没有 FFmpeg 与 264 编码器
//        的情况难以确认；因此「开始录制」「开始直播推流」保留控件与原版文案，点击后把
//        解析通过的参数原样写入下列 OUT_KEY_*，并在 FeedbackText 给出确切原因。
//        （不假成功：不伪造任何「已开始录制/已开始推流」状态。）
//   ② FFmpeg 能力探测 cs: await EnsureMediaOutputCapabilitiesAsync(force: true)
//      （跑 ffmpeg -encoders / -protocols / -muxers 解析 CapabilityScore）
//      → 鸿蒙跑不了外部进程；改为读 AppStorage 的 ARG_KEY_CAN_RTMP/SRT/WHIP
//        与 ARG_KEY_CAPABILITIES_TEXT（由宿主侧注入；未注入 = 全部不支持）。
//   ③ DirectShow / Windows 虚拟摄像头媒体源注册（src/VirtualCamera/** + src/App/Services/
//      VirtualCameraService.cs：regsvr32 / 提权安装 MediaSource，再把 CLSID 注册到系统）
//      → 鸿蒙没有可被第三方 App 注册的系统摄像头驱动框架；
//        安装 / 更新 / 卸载 / 启动四个控件保留，点击后在 FeedbackText 给出确切原因。
//   ④ Microsoft.Win32.SaveFileDialog（cs: PromptToSaveRecordingAsync，
//      InitialDirectory = Environment.SpecialFolder.MyVideos，Filter = RecordMp4Filter）
//      → @ohos.file.picker 的 DocumentViewPicker：这里是**真做**的，
//        用 DocumentSelectMode.FOLDER 让用户选一个目录 URI，结果写入 OUT_KEY_OUTPUT_DIRECTORY。
//        原版把它藏在「停止录制之后」，本移植把它前置成一个可见的「保存位置」行
//        ——因为不能录制，若不前置则用户永远拿不到这一步。
//   ⑤ cs 里的 File.Move(pending, dialog.FileName, overwrite: true) 与 IOException 回退到
//      FileStream.CopyToAsync 的整段保存逻辑 → 没有 pending 文件可搬，不迁移，保留说明。
//   ⑥ 原版三个 PrimaryButton 在能力缺失时是被 IsEnabled 置灰的（用户点不到也看不到原因）；
//      本移植按本工程的硬性要求把「开始录制 / 开始直播推流 / 三个虚拟摄像头按钮」保留可点，
//      点击后在 FeedbackText 里给出确切原因。这是相对 IsEnabled 绑定的唯一一处刻意偏离。
//   ⑦ 原版 ComboBoxItem.IsEnabled 按项禁用协议；ArkUI 的 Select 不支持按项禁用，
//      故三个协议项都可点，选到不支持的协议时走 SelectedProtocolSupported() 的同一判定。
//
// ── 文案来源 Strings.zh-CN.xaml（逐字取用）────────────────────────────────
//   MediaOutputTitle「输出设置」RecordTab「录制」StreamTab「直播推流」
//   VirtualCameraTab「虚拟摄像头」RecordDescription / StreamDescription /
//   VirtualCameraDescription / OutputWidth「宽度」OutputHeight「高度」
//   OutputFps「帧率」OutputBitrate「码率（kbps）」StartRecording「开始录制」
//   StartStreaming「开始直播推流」StreamProtocol「协议」
//   StreamDestination「服务器地址或 WHIP 端点」StreamAuthorization「WHIP Bearer 令牌（可选）」
//   ResolutionLabel「分辨率」StartVirtualCamera「启动虚拟摄像头」
//   UninstallVirtualCamera「卸载虚拟摄像头组件」StopMediaOutput「停止输出」
//   CurrentPreviewResolutionFormat「{0} x {1}（当前预览）」
//   MediaOutputIdle「当前没有媒体输出任务。」MediaOutputChecking「正在检测 FFmpeg 输出能力...」
//   MediaOutputInvalidSettings / MediaOutputInvalidProtocol「请选择受支持的推流协议。」
//   DeveloperReadOnlyPreview「只读预览：不会执行真实输出操作。」
//   VirtualCameraBackendMissing「未安装兼容的 Windows 虚拟摄像头媒体源。…」→ 见 ③ 的鸿蒙改写
// ── AppStorage 键名 ───────────────────────────────────────────────────────
//   入参 im.mediaOutput.*（previewOnly / selectedName / suggestedWidth / suggestedHeight /
//        capabilitiesText / running / canStop / status / canRtmp / canSrt / canWhip /
//        virtualCameraStatusText / virtualCameraInstallActionText / virtualCamera{Install,Start,Uninstall}Visible）
//   出参 im.mediaOutput.request*、im.mediaOutput.stopRequested、
//        im.mediaOutput.outputDirectory、im.mediaOutput.virtualCamera*

import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import picker from '@ohos.file.picker';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  SubWindowShell, SubWindowHost, PrimaryButton, RoundedTextBox, SubWindowSpec,
  SUBWINDOW_ROW_GAP,
} from '../../common/SubWindow';
import {
  TEXT, MUTED_TEXT, CARD, BORDER, BORDER_SOFT, CONTROL_FILL, PANEL_ALT, DISABLED_OPACITY,
} from '../../common/Theme';
import { t } from '../../common/i18n';

const TAG: string = 'im_media_output';
const DOMAIN: number = 0x0100;

export const WINDOW_NAME: string = 'MediaOutputSettingsWindow';
export const PAGE_PATH: string = 'pages/windows/MediaOutputSettingsWindow';

// ── AppStorage：原版构造函数 / DataContext 的通道 ──

/** cs: internal MediaOutputSettingsWindow(MainViewModel viewModel, bool previewOnly = false) */
export const ARG_KEY_PREVIEW_ONLY: string = 'im.mediaOutput.previewOnly';
/** cs: {Binding SelectedName} —— SubWindowSubtitle */
export const ARG_KEY_SELECTED_NAME: string = 'im.mediaOutput.selectedName';
/** cs: SuggestedMediaOutputSize().Width / .Height（兜底 1280×720，上限 3840×2160） */
export const ARG_KEY_SUGGESTED_WIDTH: string = 'im.mediaOutput.suggestedWidth';
export const ARG_KEY_SUGGESTED_HEIGHT: string = 'im.mediaOutput.suggestedHeight';
/** cs: {Binding MediaOutputCapabilitiesText} */
export const ARG_KEY_CAPABILITIES_TEXT: string = 'im.mediaOutput.capabilitiesText';
/** cs: CanStartMediaOutput && CanRecordMediaOutput / CanStreamRtmp / CanStreamSrt / CanStreamWhip */
export const ARG_KEY_CAN_RTMP: string = 'im.mediaOutput.canRtmp';
export const ARG_KEY_CAN_SRT: string = 'im.mediaOutput.canSrt';
export const ARG_KEY_CAN_WHIP: string = 'im.mediaOutput.canWhip';
/** cs: CanStopMediaOutput */
export const ARG_KEY_CAN_STOP: string = 'im.mediaOutput.canStop';
/** cs: {Binding MediaOutputStatus} */
export const ARG_KEY_STATUS: string = 'im.mediaOutput.status';
/** cs: {Binding VirtualCameraStatusText} / {Binding VirtualCameraInstallActionText} */
export const ARG_KEY_VC_STATUS_TEXT: string = 'im.mediaOutput.virtualCameraStatusText';
export const ARG_KEY_VC_INSTALL_ACTION: string = 'im.mediaOutput.virtualCameraInstallActionText';
/** cs: VirtualCameraInstallVisibility / StartVisibility / UninstallVisibility */
export const ARG_KEY_VC_INSTALL_VISIBLE: string = 'im.mediaOutput.virtualCameraInstallVisible';
export const ARG_KEY_VC_START_VISIBLE: string = 'im.mediaOutput.virtualCameraStartVisible';
export const ARG_KEY_VC_UNINSTALL_VISIBLE: string = 'im.mediaOutput.virtualCameraUninstallVisible';

/** cs 四个 CSV 出口：这次确认过的输出参数（width/height/fps/bitrate/kind/destination）。 */
export const OUT_KEY_KIND: string = 'im.mediaOutput.requestKind';
export const OUT_KEY_DESTINATION: string = 'im.mediaOutput.requestDestination';
export const OUT_KEY_WIDTH: string = 'im.mediaOutput.requestWidth';
export const OUT_KEY_HEIGHT: string = 'im.mediaOutput.requestHeight';
export const OUT_KEY_FPS: string = 'im.mediaOutput.requestFps';
export const OUT_KEY_BITRATE: string = 'im.mediaOutput.requestBitrate';
/** cs: OnStopClick → StopMediaOutputAsync() */
export const OUT_KEY_STOP_REQUESTED: string = 'im.mediaOutput.stopRequested';
/** 平台替换 ④：DocumentViewPicker 选到的录制输出目录（真做）。 */
export const OUT_KEY_OUTPUT_DIRECTORY: string = 'im.mediaOutput.outputDirectory';
/** cs: StartVirtualCameraAsync(width, height, frameRate) 的三个实参 + 动作名。 */
export const OUT_KEY_VC_WIDTH: string = 'im.mediaOutput.virtualCameraRequestWidth';
export const OUT_KEY_VC_HEIGHT: string = 'im.mediaOutput.virtualCameraRequestHeight';
export const OUT_KEY_VC_FPS: string = 'im.mediaOutput.virtualCameraRequestFps';
export const OUT_KEY_VC_ACTION: string = 'im.mediaOutput.virtualCameraAction';

// ── 三个 TabItem 的下标（TabControl 里的声明顺序）──
const RECORD_TAB_INDEX: number = 0;
const STREAM_TAB_INDEX: number = 1;
const VCAM_TAB_INDEX: number = 2;

/** MediaOutputKind（MediaOutputService.cs 第 10-16 行）。 */
const KIND_RECORDING: number = 0;
const KIND_RTMP: number = 1;
const KIND_SRT: number = 2;
const KIND_WHIP: number = 3;

/** cs: NormalizeOutputWidth / NormalizeOutputHeight 的兜底值与上下限。 */
const FALLBACK_WIDTH: number = 1280;
const FALLBACK_HEIGHT: number = 720;
const MIN_SIDE: number = 160;
const MIN_FPS: number = 10;
const MAX_FPS: number = 60;
const MIN_BITRATE: number = 500;
const MAX_BITRATE: number = 50000;

/** cs OnLoaded 里那两个写死的默认值。 */
const DEFAULT_FPS_TEXT: string = '30';
const DEFAULT_BITRATE_TEXT: string = '6000';

/** 虚拟摄像头四个预设 ComboBoxItem 的 Tag / Content（XAML 第 183-186 行，字一个不改）。 */
const VC_RESOLUTION_TAGS: string[] = ['1280x720', '1920x1080', '720x1280', '1080x1920'];
const VC_RESOLUTION_LABELS: string[] = ['1280 x 720', '1920 x 1080', '720 x 1280', '1080 x 1920'];
/** VirtualCameraFpsBox 两项：30 fps / 60 fps。 */
const VC_FPS_LABELS: string[] = ['30 fps', '60 fps'];
const VC_FPS_OPTIONS: SelectOption[] = [{ value: '30 fps' }, { value: '60 fps' }];

/** StreamProtocolBox 三项的 Content（不翻译，是协议名）。 */
const PROTOCOL_LABELS: string[] = ['RTMP', 'SRT', 'WebRTC / WHIP'];
const PROTOCOL_OPTIONS: SelectOption[] =
  [{ value: 'RTMP' }, { value: 'SRT' }, { value: 'WebRTC / WHIP' }];

// ── 平台替换 ①②⑥ 的确切原因文案（保留原版控件与原版动作名，只替换原因）──

/** 代替 MediaOutputService.StartAsync：鸿蒙侧 spawn 不了 FFmpeg 进程。 */
const REASON_NO_FFMPEG: string =
  '无法开始录制：鸿蒙三方应用不能启动 FFmpeg 子进程并喂帧（原版为 Media Foundation / FFmpeg 外部进程 + H.264 编码器）。';
/** 代替 MediaOutputService.StartAsync 的推流分支。 */
const REASON_NO_STREAM: string =
  '无法开始直播推流：鸿蒙侧没有可用的 FFmpeg 复用器（原版依赖 FFmpeg 的 rtmp / srt / whip 协议输出）。';
/** 代替 VirtualCameraService.InstallAsync / UninstallAsync / StartAsync。 */
const REASON_NO_VCAM_INSTALL: string =
  '无法安装 / 更新虚拟摄像头组件：鸿蒙没有可供三方应用注册的系统摄像头驱动框架（原版为提权注册 Windows DirectShow 媒体源）。';
const REASON_NO_VCAM_START: string =
  '无法启动虚拟摄像头：鸿蒙不向三方应用开放虚拟摄像头设备注册接口，会议软件无法把它选成摄像头。';
const REASON_NO_VCAM_UNINSTALL: string =
  '无需卸载虚拟摄像头组件：鸿蒙侧从未安装过任何虚拟摄像头设备。';

/**
 * Style x:Key="ToolButton"（本窗口版本）—— PanelAltBrush 底 / TextBrush 字 /
 * FontSize 12 / MinHeight 36 / Padding 10,7。
 * 「停止输出」「卸载虚拟摄像头组件」「选择…」三處用。
 */
@Component
struct ToolButton {
  @Prop label: string = '';
  @Prop minButtonWidth: number = 0;
  @Prop boxHeight: number = 36;
  // ⚠ 不能叫 `enabled`：CommonMethod 里已有 `enabled()`，会报 TS2416。
  @Prop actionEnabled: boolean = true;
  @State hovered: boolean = false;
  on_action: () => void = () => {};

  build() {
    Text(this.label)
      .fontSize(12)
      .fontColor(TEXT)
      .textAlign(TextAlign.Center)
      .height(this.boxHeight)
      .padding({ left: 10, right: 10, top: 7, bottom: 7 })
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
 * Style x:Key="SectionCard" —— CardBrush 底 / BorderSoftBrush 1px 边 / 圆角 16 /
 * Padding 16 / Margin 0,12,0,0。三个 TabItem 的 ScrollViewer 里各放一张。
 */
@Component
struct SectionCard {
  @Builder
  empty_slot() {}

  @BuilderParam content: () => void = this.empty_slot;

  build() {
    Column() {
      this.content();
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(16)
    .borderRadius(16)
    .backgroundColor(CARD)
    .border({ width: 1, color: BORDER_SOFT })
    .margin({ top: 12 });
  }
}

/**
 * Style x:Key="DetailLabel"（本窗口版本）—— MutedTextBrush / FontSize 11 /
 * Margin 0,12,0,4。注意它自带上间距，所以两个 Grid 之间不需要再留 Grid.Margin。
 */
@Builder
function detail_label(text: string) {
  Text(text)
    .fontSize(11)
    .fontColor(MUTED_TEXT)
    .width('100%')
    .margin({ top: 12, bottom: 4 });
}

/** cs: TryParseResolution —— 按 'x' 拆「宽 x 高」，两边都要能解析成 uint。 */
function parse_resolution(value: string): number[] | null {
  const parts: string[] = value.split('x');
  if (parts.length !== 2) {
    return null;
  }
  const width: number = Number.parseInt(parts[0].trim(), 10);
  const height: number = Number.parseInt(parts[1].trim(), 10);
  if (Number.isNaN(width) || Number.isNaN(height) || width < 0 || height < 0) {
    return null;
  }
  return [width, height];
}

/** 按原版打开这个子窗口：先把入参放进 AppStorage，再开窗。 */
export function open_media_output_settings(ctx: common.Context, previewOnly: boolean): void {
  AppStorage.setOrCreate<boolean>(ARG_KEY_PREVIEW_ONLY, previewOnly);

  const spec: SubWindowSpec = {
    name: WINDOW_NAME,
    page: PAGE_PATH,
    title: '输出设置',              // Strings: MediaOutputTitle
    width: 560,
    height: 660,
    resizable: true,                // ResizeMode="CanResize"
    minWidth: 500,
    minHeight: 560,
    modal: false,                   // 原版从工具栏 / 开发者面板用 Show() 打开
  };
  SubWindowHost.open(ctx, spec).catch((error: BusinessError): void => {
    hilog.error(DOMAIN, TAG, '打开失败: %{public}s', error.message);
  });
}

@Entry
@Component
struct MediaOutputSettingsWindow {
  // 表头
  @State selectedName: string = '';
  @State capabilitiesText: string = '';
  // 页签
  @State activeTabIndex: number = RECORD_TAB_INDEX;
  // 录制页（RecordWidthBox / RecordHeightBox / RecordFpsBox / RecordBitrateBox）
  @State recordWidthText: string = '';
  @State recordHeightText: string = '';
  @State recordFpsText: string = DEFAULT_FPS_TEXT;
  @State recordBitrateText: string = DEFAULT_BITRATE_TEXT;
  /** 平台替换 ④：DocumentViewPicker 选中的录制输出目录 URI。 */
  @State outputDirectory: string = '';
  // 推流页
  @State streamWidthText: string = '';
  @State streamHeightText: string = '';
  @State streamFpsText: string = DEFAULT_FPS_TEXT;
  @State streamBitrateText: string = DEFAULT_BITRATE_TEXT;
  @State streamDestinationText: string = '';
  @State streamAuthorizationText: string = '';
  @State streamProtocolIndex: number = 0;
  // 虚拟摄像头页
  @State vcResolutionIndex: number = 0;
  @State vcFpsIndex: number = 0;
  // 底部一行
  @State feedbackText: string = '';
  @State canStop: boolean = false;
  // cs 的两个入参镜像
  @State previewOnly: boolean = false;
  @State canRtmp: boolean = false;
  @State canSrt: boolean = false;
  @State canWhip: boolean = false;
  @State vcStatusText: string = '';
  @State vcInstallActionText: string = '安装虚拟摄像头组件';  // Strings: InstallVirtualCamera
  @State vcInstallVisible: boolean = true;
  @State vcStartVisible: boolean = true;
  @State vcUninstallVisible: boolean = false;

  aboutToAppear(): void {
    this.previewOnly = AppStorage.get<boolean>(ARG_KEY_PREVIEW_ONLY) ?? false;
    this.outputDirectory = AppStorage.get<string>(OUT_KEY_OUTPUT_DIRECTORY) ?? '';
    this.selectedName = AppStorage.get<string>(ARG_KEY_SELECTED_NAME) ?? '';
    this.capabilitiesText = AppStorage.get<string>(ARG_KEY_CAPABILITIES_TEXT) ?? '';
    this.canStop = AppStorage.get<boolean>(ARG_KEY_CAN_STOP) ?? false;
    this.feedbackText = AppStorage.get<string>(ARG_KEY_STATUS) ?? '';
    this.canRtmp = AppStorage.get<boolean>(ARG_KEY_CAN_RTMP) ?? false;
    this.canSrt = AppStorage.get<boolean>(ARG_KEY_CAN_SRT) ?? false;
    this.canWhip = AppStorage.get<boolean>(ARG_KEY_CAN_WHIP) ?? false;
    this.vcStatusText = AppStorage.get<string>(ARG_KEY_VC_STATUS_TEXT) ?? '';
    this.vcInstallActionText = AppStorage.get<string>(ARG_KEY_VC_INSTALL_ACTION) ??
      '安装虚拟摄像头组件';
    this.vcInstallVisible = AppStorage.get<boolean>(ARG_KEY_VC_INSTALL_VISIBLE) ?? true;
    this.vcStartVisible = AppStorage.get<boolean>(ARG_KEY_VC_START_VISIBLE) ?? true;
    this.vcUninstallVisible = AppStorage.get<boolean>(ARG_KEY_VC_UNINSTALL_VISIBLE) ?? false;

    // cs OnLoaded → ApplyPreviewOutputDefaults(force: true)
    this.apply_preview_output_defaults(true);
    this.recordFpsText = DEFAULT_FPS_TEXT;
    this.streamFpsText = DEFAULT_FPS_TEXT;
    this.recordBitrateText = DEFAULT_BITRATE_TEXT;
    this.streamBitrateText = DEFAULT_BITRATE_TEXT;
    this.vcFpsIndex = 0;

    if (this.previewOnly) {
      // Strings: DeveloperReadOnlyPreview
      this.feedbackText = '只读预览：不会执行真实输出操作。';
      return;
    }
    // cs: SelectFirstSupportedProtocol() —— 当前项不支持就挑第一个支持项。
    this.select_first_supported_protocol();
  }

  // ───────────────────────── cs 的行为 ─────────────────────────

  /**
   * cs ApplyPreviewOutputDefaults(bool force)。
   * 原版靠 `_lastDefaultSize` 判断用户是否动过输入框；这里 force=true 只在
   * aboutToAppear 调一次，与 OnLoaded 的调用点一致，故 `_lastDefaultSize` 的
   * 「用户改过就不覆盖」语义不会在本移植里被触发，不再复刻该字段。
   */
  private apply_preview_output_defaults(force: boolean): void {
    if (!force) {
      return;
    }
    // SuggestedMediaOutputSize()：源尺寸 → 渲染尺寸 → 预设 → 1280×720，再压到 3840×2160。
    let width: number = AppStorage.get<number>(ARG_KEY_SUGGESTED_WIDTH) ?? 0;
    let height: number = AppStorage.get<number>(ARG_KEY_SUGGESTED_HEIGHT) ?? 0;
    if (width <= 0 || height <= 0) {
      width = FALLBACK_WIDTH;
      height = FALLBACK_HEIGHT;
    }
    const widthText: string = width.toString();
    const heightText: string = height.toString();
    this.recordWidthText = widthText;
    this.recordHeightText = heightText;
    this.streamWidthText = widthText;
    this.streamHeightText = heightText;
    // SelectVirtualCameraResolution(size.Width, size.Height, true)
    const suggested: string = `${width}x${height}`;
    let matched: number = -1;
    for (let i: number = 0; i < VC_RESOLUTION_TAGS.length; i++) {
      if (VC_RESOLUTION_TAGS[i] === suggested) {
        matched = i;
        break;
      }
    }
    // 没命中预设时原版会把 VirtualCameraCurrentResolutionItem 显示成
    // CurrentPreviewResolutionFormat「{0} x {1}（当前预览）」并选中它；
    // 这里用同一句话改写 index 0 的候选文案，再选中它——可选集合的粒度差异。
    if (matched >= 0) {
      this.vcResolutionIndex = matched;
    } else {
      this.vcResolutionIndex = 0;
    }
  }

  /** cs: VirtualCameraCurrentResolutionItem.Content 的写法（命中不到预设时）。 */
  private vc_current_resolution_text(): string {
    const width: number = AppStorage.get<number>(ARG_KEY_SUGGESTED_WIDTH) ?? FALLBACK_WIDTH;
    const height: number = AppStorage.get<number>(ARG_KEY_SUGGESTED_HEIGHT) ?? FALLBACK_HEIGHT;
    return `${width} x ${height}（当前预览）`;   // Strings: CurrentPreviewResolutionFormat
  }

  private vc_resolution_label(index: number): string {
    return this.vc_resolution_label_at(index);
  }

  private vc_resolution_label_at(index: number): string {
    return index === 0 && !this.vc_has_preset_match() ?
      this.vc_current_resolution_text() : VC_RESOLUTION_LABELS[index];
  }

  private vc_has_preset_match(): boolean {
    const width: number = AppStorage.get<number>(ARG_KEY_SUGGESTED_WIDTH) ?? 0;
    const height: number = AppStorage.get<number>(ARG_KEY_SUGGESTED_HEIGHT) ?? 0;
    return width > 0 && height > 0 &&
      VC_RESOLUTION_TAGS.indexOf(`${width}x${height}`) >= 0;
  }

  /** cs SelectFirstSupportedProtocol()。 */
  private select_first_supported_protocol(): void {
    if (this.selected_protocol_supported()) {
      return;
    }
    if (this.canRtmp) {
      this.streamProtocolIndex = 0;
    } else if (this.canSrt) {
      this.streamProtocolIndex = 1;
    } else if (this.canWhip) {
      this.streamProtocolIndex = 2;
    }
  }

  /** cs SelectedProtocolSupported()。 */
  private selected_protocol_supported(): boolean {
    if (this.streamProtocolIndex === 0) {
      return this.canRtmp;
    }
    if (this.streamProtocolIndex === 1) {
      return this.canSrt;
    }
    if (this.streamProtocolIndex === 2) {
      return this.canWhip;
    }
    return false;
  }

  /** cs StreamProtocolBox.SelectedIndex switch → MediaOutputKind。 */
  private selected_kind(): number {
    if (this.streamProtocolIndex === 1) {
      return KIND_SRT;
    }
    if (this.streamProtocolIndex === 2) {
      return KIND_WHIP;
    }
    return KIND_RTMP;
  }

  /**
   * cs TryReadOutputSettings(...) —— uint 宽高 / int 帧率码率，
   * width >= 160 && height >= 160 && fps 10..60 && bitrate 500..50000。
   * 注：MediaOutputInvalidSettings 的中文文案提到「偶数输出尺寸」，
   * 而 cs 这里只判 >= 160；偶数化是 cis378 侧 NormalizeOutputWidth 做的
   * （value & ~1U），本移植照搬 cs 的判定口径。
   */
  private try_read_output_settings(widthText: string, heightText: string,
    fpsText: string, bitrateText: string): boolean {
    const width: number = Number.parseInt(widthText.trim(), 10);
    const height: number = Number.parseInt(heightText.trim(), 10);
    const fps: number = Number.parseInt(fpsText.trim(), 10);
    const bitrate: number = Number.parseInt(bitrateText.trim(), 10);
    if (Number.isNaN(width) || Number.isNaN(height) || Number.isNaN(fps) ||
      Number.isNaN(bitrate) || width < MIN_SIDE || height < MIN_SIDE ||
      fps < MIN_FPS || fps > MAX_FPS || bitrate < MIN_BITRATE || bitrate > MAX_BITRATE) {
      // Strings: MediaOutputInvalidSettings
      this.feedbackText = '请输入偶数输出尺寸、10-60 fps 帧率以及 500-50000 kbps 码率。';
      return false;
    }
    return true;
  }

  /** cs OnStartRecordingClick。 */
  private on_start_recording(): void {
    if (!this.try_read_output_settings(this.recordWidthText, this.recordHeightText,
      this.recordFpsText, this.recordBitrateText)) {
      return;
    }
    const width: number = Number.parseInt(this.recordWidthText.trim(), 10);
    const height: number = Number.parseInt(this.recordHeightText.trim(), 10);
    AppStorage.setOrCreate<number>(OUT_KEY_KIND, KIND_RECORDING);
    AppStorage.setOrCreate<string>(OUT_KEY_DESTINATION,
      AppStorage.get<string>(OUT_KEY_OUTPUT_DIRECTORY) ?? '');
    AppStorage.setOrCreate<number>(OUT_KEY_WIDTH, width);
    AppStorage.setOrCreate<number>(OUT_KEY_HEIGHT, height);
    AppStorage.setOrCreate<number>(OUT_KEY_FPS, Number.parseInt(this.recordFpsText.trim(), 10));
    AppStorage.setOrCreate<number>(OUT_KEY_BITRATE,
      Number.parseInt(this.recordBitrateText.trim(), 10));
    this.feedbackText = REASON_NO_FFMPEG;
  }

  /** cs OnStartStreamingClick。 */
  private on_start_streaming(): void {
    if (!this.try_read_output_settings(this.streamWidthText, this.streamHeightText,
      this.streamFpsText, this.streamBitrateText)) {
      return;
    }
    if (!this.selected_protocol_supported()) {
      // Strings: MediaOutputInvalidProtocol
      this.feedbackText = '请选择受支持的推流协议。';
      return;
    }
    AppStorage.setOrCreate<number>(OUT_KEY_KIND, this.selected_kind());
    AppStorage.setOrCreate<string>(OUT_KEY_DESTINATION, this.streamDestinationText.trim());
    AppStorage.setOrCreate<number>(OUT_KEY_WIDTH,
      Number.parseInt(this.streamWidthText.trim(), 10));
    AppStorage.setOrCreate<number>(OUT_KEY_HEIGHT,
      Number.parseInt(this.streamHeightText.trim(), 10));
    AppStorage.setOrCreate<number>(OUT_KEY_FPS, Number.parseInt(this.streamFpsText.trim(), 10));
    AppStorage.setOrCreate<number>(OUT_KEY_BITRATE,
      Number.parseInt(this.streamBitrateText.trim(), 10));
    this.feedbackText = REASON_NO_STREAM;
  }

  /** cs OnStartVirtualCameraClick。 */
  private on_start_virtual_camera(): void {
    const size: number[] | null = parse_resolution(VC_RESOLUTION_TAGS[this.vcResolutionIndex]);
    if (size === null) {
      // Strings: MediaOutputInvalidSettings
      this.feedbackText = '请输入偶数输出尺寸、10-60 fps 帧率以及 500-50000 kbps 码率。';
      return;
    }
    AppStorage.setOrCreate<string>(OUT_KEY_VC_ACTION, 'start');
    AppStorage.setOrCreate<number>(OUT_KEY_VC_WIDTH, size[0]);
    AppStorage.setOrCreate<number>(OUT_KEY_VC_HEIGHT, size[1]);
    AppStorage.setOrCreate<number>(OUT_KEY_VC_FPS,
      this.vcFpsIndex === 0 ? 30 : 60);
    this.feedbackText = REASON_NO_VCAM_START;
  }

  /** cs OnInstallVirtualCameraClick。 */
  private on_install_virtual_camera(): void {
    AppStorage.setOrCreate<string>(OUT_KEY_VC_ACTION, 'install');
    this.feedbackText = REASON_NO_VCAM_INSTALL;
  }

  /** cs OnUninstallVirtualCameraClick。 */
  private on_uninstall_virtual_camera(): void {
    AppStorage.setOrCreate<string>(OUT_KEY_VC_ACTION, 'uninstall');
    this.feedbackText = REASON_NO_VCAM_UNINSTALL;
  }

  /** cs OnStopClick：StopMediaOutputAsync() 之后还会 PromptToSaveRecordingAsync()。 */
  private on_stop(): void {
    AppStorage.setOrCreate<boolean>(OUT_KEY_STOP_REQUESTED, true);
    if (!this.canStop) {
      // Strings: MediaOutputIdle
      this.feedbackText = '当前没有媒体输出任务。';
      return;
    }
    this.feedbackText = REASON_NO_FFMPEG;
  }

  /**
   * 平台替换 ④：原版是「停止录制之后」弹 Microsoft.Win32.SaveFileDialog 让用户给
   * MP4 选保存位置；鸿蒙侧不能录制，所以把这一步前置成可见的「选择…」按钮，
   * 用 DocumentViewPicker 的 FOLDER 模式真选一个目录 URI。
   */
  private pick_output_directory(): void {
    try {
      const documentPicker: picker.DocumentViewPicker =
        new picker.DocumentViewPicker(getContext(this) as common.Context);
      const options: picker.DocumentSelectOptions = {
        selectMode: picker.DocumentSelectMode.FOLDER,
        maxSelectNumber: 1,
      };
      const self: MediaOutputSettingsWindow = this;
      documentPicker.select(options).then((uris: string[]): void => {
        if (uris.length > 0) {
          AppStorage.setOrCreate<string>(OUT_KEY_OUTPUT_DIRECTORY, uris[0]);
          self.outputDirectory = uris[0];
          self.feedbackText = uris[0];
          return;
        }
        // Strings: RecordingPendingSave（未做选择时沿用原版「尚未选定位置」的语义）
        this.feedbackText = '上一段录制已完成但尚未保存，请先选择保存位置和文件名。';
      }).catch((error: BusinessError): void => {
        hilog.warn(DOMAIN, TAG, '选择输出目录失败: %{public}s', error.message);
        this.feedbackText = `无法选择保存位置：${error.message}`;
      });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'DocumentViewPicker 不可用: %{public}s',
        (error as BusinessError).message);
      this.feedbackText = '无法选择保存位置：当前环境不支持文件选择器。';
    }
  }

  // ───────────────────────── 界面 ─────────────────────────

  /** SubWindowTabItem：FontSize 14 / SemiBold / Padding 14,8 / Margin 2。 */
  @Builder
  tab_item(text: string, index: number) {
    Text(text)
      .fontSize(14)
      .fontWeight(FontWeight.Bold)
      .fontColor(this.activeTabIndex === index ? TEXT : MUTED_TEXT)
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .borderRadius(8)
      .backgroundColor(this.activeTabIndex === index ? CONTROL_FILL : Color.Transparent)
      .margin(2);
  }

  /** 两个 * /8/ * 的两列 Grid（XAML 在录制页与推流页各写了两次）。 */
  @Builder
  two_columns(leftLabel: string, leftText: string, leftChange: (value: string) => void,
    rightLabel: string, rightText: string, rightChange: (value: string) => void) {
    Row() {
      Column() {
        detail_label(leftLabel);
        RoundedTextBox({
          text: leftText,
          boxHeight: 36,
          on_text_change: leftChange,
        });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);

      Column().width(8);

      Column() {
        detail_label(rightLabel);
        RoundedTextBox({
          text: rightText,
          boxHeight: 36,
          on_text_change: rightChange,
        });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom);
  }

  /** 录制页：ScrollViewer + SectionCard。 */
  @Builder
  record_tab() {
    Scroll() {
      Column() {
        SectionCard({ content: (): void => { this.record_card(); } });
      }
      .width('100%');
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring);
  }

  @Builder
  record_card() {
    Column() {
      // TextBlock RecordDescription：Muted 12 Wrap
      Text('点击后立即开始录制当前投屏画面。结束录制并完成 MP4 封装后，再选择保存位置和文件名。')
        .fontSize(12)
        .fontColor(MUTED_TEXT)
        .width('100%');

      // Grid Margin="0,12,0,0"：宽度 / 高度
      Column() {
        this.two_columns(
          '宽度', this.recordWidthText,
          (value: string): void => { this.recordWidthText = value; },
          '高度', this.recordHeightText,
          (value: string): void => { this.recordHeightText = value; });
      }
      .width('100%')
      .margin({ top: 12 });

      // Grid：帧率 / 码率（kbps）
      this.two_columns(
        '帧率', this.recordFpsText,
        (value: string): void => { this.recordFpsText = value; },
        '码率（kbps）', this.recordBitrateText,
        (value: string): void => { this.recordBitrateText = value; });

      // 平台替换 ④：新增的「保存位置」一行（原版藏在 OnStopClick 之后）。
      detail_label('保存位置');
      Row() {
        RoundedTextBox({
          text: this.outputDirectory,
          readOnly: true,
          boxHeight: 36,
        })
          .layoutWeight(1);
        ToolButton({
          label: '选择…',
          minButtonWidth: 72,
          on_action: (): void => { this.pick_output_directory(); },
        })
          .margin({ left: 8 });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      PrimaryButton({
        label: '开始录制',                 // Strings: StartRecording
        on_action: (): void => { this.on_start_recording(); },
      })
        .margin({ top: 18 });
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%');
  }

  /** 推流页。 */
  @Builder
  stream_tab() {
    Scroll() {
      Column() {
        SectionCard({ content: (): void => { this.stream_card(); } });
      }
      .width('100%');
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring);
  }

  @Builder
  stream_card() {
    Column() {
      Text('通过 RTMP、SRT 或 WebRTC WHIP 端点发送当前投屏画面。')
        .fontSize(12)
        .fontColor(MUTED_TEXT)
        .width('100%');

      detail_label('协议');
      Select(PROTOCOL_OPTIONS)
        .selected(this.streamProtocolIndex)
        .value(PROTOCOL_LABELS[this.streamProtocolIndex])
        .fontColor(TEXT)
        .optionFontColor(TEXT)
        .selectedOptionFontColor(TEXT)
        .width('100%')
        .onSelect((index: number): void => {
          this.streamProtocolIndex = index;
          // cs OnStreamProtocolChanged → UpdateStartButtons；本移植在这里同步把
          // 选中的 MediaOutputKind 写进总线。
          this.refresh_bus_state();
        });

      detail_label('服务器地址或 WHIP 端点');
      RoundedTextBox({
        text: this.streamDestinationText,
        boxHeight: 36,
        on_text_change: (value: string): void => { this.streamDestinationText = value; },
      });

      detail_label('WHIP Bearer 令牌（可选）');
      RoundedTextBox({
        text: this.streamAuthorizationText,
        boxHeight: 36,
        on_text_change: (value: string): void => { this.streamAuthorizationText = value; },
      });

      this.two_columns(
        '宽度', this.streamWidthText,
        (value: string): void => { this.streamWidthText = value; },
        '高度', this.streamHeightText,
        (value: string): void => { this.streamHeightText = value; });

      this.two_columns(
        '帧率', this.streamFpsText,
        (value: string): void => { this.streamFpsText = value; },
        '码率（kbps）', this.streamBitrateText,
        (value: string): void => { this.streamBitrateText = value; });

      PrimaryButton({
        label: '开始直播推流',             // Strings: StartStreaming
        on_action: (): void => { this.on_start_streaming(); },
      })
        .margin({ top: 18 });
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%');
  }

  /** 虚拟摄像头页。 */
  @Builder
  vcam_tab() {
    Scroll() {
      Column() {
        SectionCard({ content: (): void => { this.vcam_card(); } });
      }
      .width('100%');
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring);
  }

  @Builder
  vcam_card() {
    Column() {
      Text('将当前投屏画面注册为会议和录制软件可选择的摄像头设备。')
        .fontSize(12)
        .fontColor(MUTED_TEXT)
        .width('100%');

      // Grid Margin="0,4,0,0"：分辨率 / 帧率
      Row() {
        Column() {
          detail_label('分辨率');
          Select(this.vc_resolution_options())
            .selected(this.vcResolutionIndex)
            .value(this.vc_resolution_label(this.vcResolutionIndex))
            .fontColor(TEXT)
            .optionFontColor(TEXT)
            .selectedOptionFontColor(TEXT)
            .width('100%')
            .onSelect((index: number): void => { this.vcResolutionIndex = index; });
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);

        Column().width(8);

        Column() {
          detail_label('帧率');
          Select(VC_FPS_OPTIONS)
            .selected(this.vcFpsIndex)
            .value(VC_FPS_LABELS[this.vcFpsIndex])
            .fontColor(TEXT)
            .optionFontColor(TEXT)
            .selectedOptionFontColor(TEXT)
            .width('100%')
            .onSelect((index: number): void => { this.vcFpsIndex = index; });
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .margin({ top: 4 });

      // TextBlock {Binding VirtualCameraStatusText}：Muted 12 Wrap, Margin 0,14,0,0
      Text(this.vcStatusText)
        .fontSize(12)
        .fontColor(MUTED_TEXT)
        .width('100%')
        .margin({ top: 14 });

      if (this.vcInstallVisible) {
        PrimaryButton({
          label: this.vcInstallActionText,
          on_action: (): void => { this.on_install_virtual_camera(); },
        })
          .margin({ top: 18 });
      }

      if (this.vcStartVisible) {
        PrimaryButton({
          label: '启动虚拟摄像头',         // Strings: StartVirtualCamera
          on_action: (): void => { this.on_start_virtual_camera(); },
        })
          .margin({ top: 18 });
      }

      if (this.vcUninstallVisible) {
        ToolButton({
          label: '卸载虚拟摄像头组件',     // Strings: UninstallVirtualCamera
          on_action: (): void => { this.on_uninstall_virtual_camera(); },
        })
          .width('100%')
          .margin({ top: 10 });
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%');
  }

  /** 合成虚拟摄像头分辨率下拉项；未命中预设时把第 0 项换成「{0} x {1}（当前预览）」。 */
  private vc_resolution_options(): SelectOption[] {
    const options: SelectOption[] = [];
    options.push({ value: this.vc_resolution_label_at(0) });
    options.push({ value: VC_RESOLUTION_LABELS[1] });
    options.push({ value: VC_RESOLUTION_LABELS[2] });
    options.push({ value: VC_RESOLUTION_LABELS[3] });
    return options;
  }

  /** cs OnStreamProtocolChanged → UpdateStartButtons 在本移植里的等价动作。 */
  private refresh_bus_state(): void {
    AppStorage.setOrCreate<number>(OUT_KEY_KIND, this.selected_kind());
  }

  /** 表头第三行（原文在 SubWindowHeader 里，字号 10）—— 见文件头「行定义」。 */
  @Builder
  notice() {
    Text(this.capabilitiesText)
      .fontSize(10)
      .fontColor(MUTED_TEXT)
      .width('100%')
      .margin({ top: 5 });
  }

  /** Row * ：TabControl Style=SubWindowTabControl。 */
  @Builder
  body() {
    Tabs({ barPosition: BarPosition.Start, index: this.activeTabIndex }) {
      TabContent() {
        this.record_tab();
      }
      .tabBar(this.tab_item('录制', RECORD_TAB_INDEX));

      TabContent() {
        this.stream_tab();
      }
      .tabBar(this.tab_item('直播推流', STREAM_TAB_INDEX));

      TabContent() {
        this.vcam_tab();
      }
      .tabBar(this.tab_item('虚拟摄像头', VCAM_TAB_INDEX));
    }
    .width('100%')
    .height('100%')
    .barHeight(44)
    .onChange((index: number): void => { this.activeTabIndex = index; });
  }

  /** Row Auto：Grid 列 = * / 8 / Auto，整体 Margin 0,14,0,0。 */
  @Builder
  actions() {
    Row() {
      Text(this.feedbackText)
        .fontSize(11)
        .fontColor(MUTED_TEXT)
        .textAlign(TextAlign.Start)
        .layoutWeight(1);

      Column().width(8);

      ToolButton({
        label: '停止输出',                 // Strings: StopMediaOutput
        minButtonWidth: 110,
        actionEnabled: this.canStop,
        on_action: (): void => { this.on_stop(); },
      });
    }
    .width('100%')
    .margin({ top: 14 })
    .alignItems(VerticalAlign.Center);
  }

  build() {
    Column() {
      SubWindowShell({
        windowName: WINDOW_NAME,
        title: '输出设置',                  // Strings: MediaOutputTitle
        subtitle: this.selectedName,        // {Binding SelectedName}
        gap: SUBWINDOW_ROW_GAP,             // 行 1 = 16
        hasNotice: true,                    // 表头第三行（能力文案）挪到这，字号仍是 10
        noticeGap: 0,
        hasFooter: false,
        hasActions: true,
        actionGap: 0,                       // Grid 自带 Margin 0,14,0,0
        actionsSplit: false,
        notice: (): void => { this.notice(); },
        content: (): void => { this.body(); },
        actions: (): void => { this.actions(); },
      });
    }
  }
}
