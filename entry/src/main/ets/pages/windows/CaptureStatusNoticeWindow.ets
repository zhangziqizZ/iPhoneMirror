// CaptureStatusNoticeWindow.ets —— 子窗口：投屏状态通知（错误 / USB 配置 / 已停止）
//
// 逐项对照上游 src/App/Windows/CaptureStatusNoticeWindow.xaml（156 行）
//              src/App/Windows/CaptureStatusNoticeWindow.xaml.cs（121 行）
//
// 上游两份的差异（main 1.8.4 / linux-port 1.8.1）：linux 版**没有**
// `IsReverseControl`（也没有 ShowDeveloperReverseControlErrorPreview），
// 徽标固定取 CaptureNoticeErrorBadge。main 版多了反控一支 → 本文件按 main 版还原。
//
// ── 窗口属性（XAML 根元素 <ui:FluentWindow> 那一行）──────────────────────────
//   Width="440" SizeToContent="Height" MinHeight="210"  → 见「平台替换 1」
//   ResizeMode="NoResize"                               → resizable: false
//   WindowStartupLocation="CenterOwner"                 → SubWindowHost.open 里算居中
//   WindowStyle="None" ExtendsContentIntoTitleBar="True" → decorEnabled: false + 自绘表头
//   WindowBackdropType="None" WindowCornerPreference="Round" → 由系统窗口负责
//   Background="{DynamicResource WindowBackgroundBrush}"  ← 被下面那层 Border 盖住，
//                                                          实际可见底色是 Border 的
//                                                          DialogSurfaceBrush
//   ShowInTaskbar="False"                                → 子窗口天然不在任务栏
//
// ── 内容根（原版注释解释了为什么不用圆角）────────────────────────────────────
//   <Border Style="{StaticResource ModernDialogSurface}"
//           Background="{DynamicResource DialogSurfaceBrush}"
//           Margin="0" Padding="20" BorderThickness="0" CornerRadius="0" Effect="{x:Null}">
//   → 页面内边距是 20（不是 SubWindowPageRoot 的 24,20），底色 DIALOG_SURFACE，无圆角。
//
// ── 行定义（5 行，没有 Height="*" 的行）──────────────────────────────────────
//   Row Auto : Grid Style=SubWindowHeader（MinHeight 44, WindowDragBehavior）
//                TextBlock SubWindowTitle  Text="{Binding TitleText}" Margin="0,0,48,0"
//                Button Style=SubWindowCloseButton + SymbolIcon Dismiss20/18
//   Row 16   : 间隔                                        → shell 的 gap
//   Row Auto : Border（提示条）                              → content 顶部（见平台替换 2）
//                BorderThickness 1 / CornerRadius 12 / Padding 14
//                底色+边框色由 DataTrigger IsWarning 切 Error/Warning 两套
//                Grid 两列 = 38 / *
//                  列 0：Border 30×30 CornerRadius 15（底色随 IsWarning；
//                        内部三个 SymbolIcon 互斥，见下）
//                        · ErrorCircle20 / 17 / OnAccentBrush  默认可见，IsStopped 时 Collapsed
//                        · Warning20     / 17 / OnAccentBrush  IsStopped 时 Visible
//                        · UsbPlug20     / 17 / OnAccentBrush  IsUsbConfiguration 时 Visible
//                  列 1：StackPanel Margin="8,0,0,0"
//                        TextBlock BadgeText  FontSize 12 / SemiBold
//                        TextBlock BodyText   MutedTextBrush / 12 / Wrap / Margin 0,5,0,0
//   Row 12   : 间隔                                        → content 内部
//   Row Auto : Grid 两列 = * / Auto                          → content 底部
//                列 0：Border ControlFillBrush / BorderSoftBrush / 1px / CornerRadius 15
//                      Padding 10,5 / 垂直居中
//                      StackPanel 横向：SymbolIcon ArrowClockwise20 / 14 / Muted /
//                                      Margin 0,0,5,0 + TextBlock HintText 11 Muted
//                列 1：Button Content=Close Style=PrimaryButton
//                      MinWidth 80 / Height 36 / Margin 12,0,0,0
//
// ── 文案来源 Strings.zh-CN.xaml（逐字取用）────────────────────────────────
//   CaptureNoticeErrorBadge        「投屏未能继续」
//   ReverseControlNoticeErrorBadge 「反控未能继续」
//   CaptureNoticeUsbBadge          「USB 投屏配置未完成」
//   CaptureNoticeStoppedBadge      「投屏已停止」
//   CaptureNoticeErrorHint         「请检查设备和连接后重试」
//   CaptureNoticeUsbHint           「请重新插拔数据线后重试」
//   CaptureNoticeStoppedHint       「重启设备后可再次投屏」
//   Close                          「关闭」
//   CaptureActionRestartDevice     「请重启 iPhone 或 iPad 后再试。」
//   CaptureActionReconnectDevice   「请保持设备解锁，重新插拔数据线后再试。」
//   CaptureActionRetry             「请停止投屏后重新开始；仍失败时重新连接设备。」
//   DeviceCaptureErrorTitleFormat       「{0} 投屏错误」
//   DeviceSessionClosedWarningTitleFormat「{0} 投屏已停止」
//   DeviceSessionClosedWarningBody 「检测到您已经在控制中心点击了停止镜像，下一次该设备有线镜像需重启 iPhone/iPad」
//   CaptureUsbConfigurationTitle   「USB 投屏配置错误」
//   ReverseControlErrorTitle       「反向控制错误」
//   ReverseControlErrorBodyFormat  「{0}反向控制发生错误：{1}」
//   DeveloperPreviewDeviceName     「预览设备」
//
// ── 关联服务（只搬本窗口用得到的那部分，逐条注明）────────────────────────────
//   ① src/App/Services/CaptureErrorGuidance.cs
//      · IsUsbConfigurationFailure(diagnostic)：命中两个稳定标记
//          "[set_configuration] could not set config"
//          "initialize libusb0 QuickTime configuration"
//        → 本文件 `is_usb_configuration_failure()`，用于自动把通知切成 UsbConfiguration 种类。
//      · UserMessage(diagnostic)：NoPing("sent no PING") → CaptureActionRestartDevice；
//        UsbConfigurationFailure → CaptureActionReconnectDevice；否则 CaptureActionRetry
//        → 本文件 `capture_error_guidance_message()`，body 留空时按原版口径补出正文。
//      · ErrorCodeText / FailureKindText / FailureStageText 属于主窗口的错误详情块，
//        本窗口不显示（原版也只传 title+body），故不搬。
//   ② src/App/Services/CaptureShutdownCoordinator.cs
//      · StopAndDisposeOnceAsync 用 Interlocked.Exchange 保证「只做一次」。
//        本窗口的对应物是 ShowStoppedThen 的 afterShown：原版用 started 标志，
//        这里同样用一次性标志（见 run_after_shown_once），语义一致。
//   ③ src/App/Services/MediaRecoveryBackoff.cs
//      · 250 ms × 2^min(n-1,5)、最多 12 次、稳定播放 10 s 归零。
//        这是**媒体管线**的重试退避，本窗口不参与退避决策，只展示它算出来的
//        那句话（CaptureAction* 文案），故不搬算法，仅在此注明以免误以为遗漏。
//
// ── 平台替换（原版机制在鸿蒙没有对应物，逐条列出）──────────────────────────
//   1. SizeToContent="Height"：ArkUI 子窗口必须在创建时给固定矩形，没有
//      「按内容量高度」的窗口模式。这里取 Height=300（≥ MinHeight=210，按
//      表头 44 + 16 + 提示条 ~88 + 12 + 36 + 20×2 页边距算出，可容纳约 3 行正文），
//      并把提示条与底行放进可纵向滚动的容器，正文再长也不会被裁掉。
//   2. 原版 5 行里**没有 Height="*" 的行**，而 SubWindowShell 的 content 槽固定
//      layoutWeight(1)。所以把「提示条 + 12 + 底行」整段放进 content 槽（顶部对齐、
//      可滚动），hasNotice 关掉 —— 行顺序与原版完全一致。
//   3. ShowDialog() → SubWindowHost.open(modal: true)；Show()（开发者预览）
//      → SubWindowHost.open(modal: false)。ShowDialog 的同步返回值在原版也没人用
//      （本窗口全部入口都返回 void），所以没有结果回传通道要补。
//   4. ShowStoppedThen 的 ContentRendered + Dispatcher.InvokeAsync(ContextIdle)
//      → setTimeout(0)（ArkUI 里最接近「上屏之后」的时机）。失败按原版
//      DiagnosticLogger.Exception("capture","capture_notice_after_shown_failed",…)
//      的口径走 hilog.error，不弹二次提示。
//   5. 原版三个 SymbolIcon 用 DataTrigger 互斥显隐；ArkUI 没有 DataTrigger，
//      改成在代码里按 IsStopped / IsUsbConfiguration 选一个图标名（见 disc_icon）。
//   6. 原版 BodyText 走 DataContext 绑定；鸿蒙侧窗参经 AppStorage 传入
//      （与 AdvancedSettingsWindow 同一套路），见 ARG_KEY_*。
//
// ── 不做假成功 ─────────────────────────────────────────────────────────────
//   本窗口没有「执行动作」的按钮，只有「关闭」；afterShown 失败会写 hilog 并在
//   状态里如实报出，不会假装清理已完成。

import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  SubWindowShell, SubWindowHost, BadgeChip, PrimaryButton,
  SUBWINDOW_ROW_GAP, SubWindowSpec,
} from '../../common/SubWindow';
import {
  TEXT, MUTED_TEXT, ERROR, ERROR_SURFACE, WARNING, WARNING_SURFACE,
  ON_ACCENT, DIALOG_SURFACE,
} from '../../common/Theme';
import { FluentSymbol } from '../../common/FluentIcon';
import { t } from '../../common/i18n';

const TAG: string = 'im_capture_status_notice';
const DOMAIN: number = 0x0100;

/** 窗口名 —— 用 XAML 的类名，window.findWindow 也用它。 */
export const WINDOW_NAME: string = 'CaptureStatusNoticeWindow';
/** 页面路径。 */
export const PAGE_PATH: string = 'pages/windows/CaptureStatusNoticeWindow';

/** 原版构造参数经 AppStorage 传入（平台替换 6）。 */
export const ARG_KEY_TITLE: string = 'im.captureStatusNotice.title';
export const ARG_KEY_BODY: string = 'im.captureStatusNotice.body';
export const ARG_KEY_KIND: string = 'im.captureStatusNotice.kind';
export const ARG_KEY_REVERSE_CONTROL: string = 'im.captureStatusNotice.reverseControl';
export const ARG_KEY_MODAL: string = 'im.captureStatusNotice.modal';

/** xaml.cs: private enum NoticeKind { Error, UsbConfiguration, Stopped } */
export enum CaptureNoticeKind {
  Error = 0,
  UsbConfiguration = 1,
  Stopped = 2,
}

/** Strings（逐键标注）。 */
const S_CLOSE = (): string => t('关闭');// Close
const S_BADGE_ERROR = (): string => t('投屏未能继续');// CaptureNoticeErrorBadge
const S_BADGE_REVERSE_CONTROL = (): string => t('反控未能继续');// ReverseControlNoticeErrorBadge
const S_BADGE_USB = (): string => t('USB 投屏配置未完成');// CaptureNoticeUsbBadge
const S_BADGE_STOPPED = (): string => t('投屏已停止');// CaptureNoticeStoppedBadge
const S_HINT_ERROR = (): string => t('请检查设备和连接后重试');// CaptureNoticeErrorHint
const S_HINT_USB = (): string => t('请重新插拔数据线后重试');// CaptureNoticeUsbHint
const S_HINT_STOPPED = (): string => t('重启设备后可再次投屏');// CaptureNoticeStoppedHint

/** CaptureErrorGuidance 的三条用户动作文案（Strings 原文）。 */
const S_ACTION_RESTART_DEVICE = (): string => t('请重启 iPhone 或 iPad 后再试。');// CaptureActionRestartDevice
const S_ACTION_RECONNECT_DEVICE = (): string => t('请保持设备解锁，重新插拔数据线后再试。');// CaptureActionReconnectDevice
const S_ACTION_RETRY = (): string => t('请停止投屏后重新开始；仍失败时重新连接设备。');// CaptureActionRetry

/** CaptureErrorGuidance.cs 的三个匹配标记（原文，大小写不敏感）。 */
const NO_PING_MARKER: string = 'sent no PING';
const USB_CONFIGURATION_MARKER: string = '[set_configuration] could not set config';
const LIBUSB0_CONFIGURATION_MARKER: string = 'initialize libusb0 QuickTime configuration';

/** 平台替换 1：SizeToContent="Height" 的固定替代高度（≥ MinHeight 210）。 */
const WINDOW_WIDTH: number = 440;    // Width="440"
const WINDOW_HEIGHT: number = 300;   // SizeToContent="Height" + MinHeight="210"
const WINDOW_MIN_HEIGHT: number = 210;

// ───────────────────── CaptureErrorGuidance 的移植（服务 ①） ─────────────────────

function contains_ignore_case(haystack: string, needle: string): boolean {
  return haystack.toLowerCase().indexOf(needle.toLowerCase()) >= 0;
}

/** CaptureErrorGuidance.IsNoPingTimeout */
export function is_no_ping_timeout(diagnostic: string): boolean {
  return diagnostic.length > 0 && contains_ignore_case(diagnostic, NO_PING_MARKER);
}

/** CaptureErrorGuidance.IsUsbConfigurationFailure */
export function is_usb_configuration_failure(diagnostic: string): boolean {
  return diagnostic.length > 0
    && (contains_ignore_case(diagnostic, USB_CONFIGURATION_MARKER)
      || contains_ignore_case(diagnostic, LIBUSB0_CONFIGURATION_MARKER));
}

/** CaptureErrorGuidance.UserMessage(string? diagnostic) */
export function capture_error_guidance_message(diagnostic: string): string {
  if (is_no_ping_timeout(diagnostic)) {
    return S_ACTION_RESTART_DEVICE();
  }
  if (is_usb_configuration_failure(diagnostic)) {
    return S_ACTION_RECONNECT_DEVICE();
  }
  return S_ACTION_RETRY();
}

// ───────────────────── 开窗入口（对应 xaml.cs 的 internal static 方法） ─────────────────────

/**
 * 原版 ShowStoppedThen 的 afterShown（平台替换 4）。
 * 模块级暂存：setUIContent 只收页面路径字符串，构造参数只能走这种通道
 * （与 WindowServices.pending_* 同一个思路，但本窗口不外泄到注册表）。
 */
let pending_after_shown: (() => void) | null = null;

/** 原版 ShowDeveloperPreview 用的设备名。 */
const S_PREVIEW_DEVICE = (): string => t('预览设备');// DeveloperPreviewDeviceName

function open_notice(ctx: common.Context, title: string, body: string,
                     kind: CaptureNoticeKind, reverseControl: boolean,
                     modal: boolean): Promise<void> {
  AppStorage.setOrCreate<string>(ARG_KEY_TITLE, title);
  AppStorage.setOrCreate<string>(ARG_KEY_BODY, body);
  AppStorage.setOrCreate<number>(ARG_KEY_KIND, kind);
  AppStorage.setOrCreate<boolean>(ARG_KEY_REVERSE_CONTROL, reverseControl);
  AppStorage.setOrCreate<boolean>(ARG_KEY_MODAL, modal);

  const spec: SubWindowSpec = {
    name: WINDOW_NAME,
    page: PAGE_PATH,
    title: title,
    width: WINDOW_WIDTH,
    height: WINDOW_HEIGHT,
    resizable: false,                 // ResizeMode="NoResize"
    minWidth: WINDOW_WIDTH,
    minHeight: WINDOW_MIN_HEIGHT,
    modal: modal,                     // ShowDialog() → true；开发者预览 Show() → false
  };
  return SubWindowHost.open(ctx, spec);
}

/**
 * 原版 internal static void ShowError(string title, string body) 与
 *       internal static void ShowError(string title, string body,
 *           bool usbConfiguration, bool reverseControl = false)。
 * diagnostic 非空时按 CaptureErrorGuidance 补正文并自动判定 USB 配置种类。
 */
export function show_capture_error(ctx: common.Context, title: string, body: string,
                                   diagnostic: string, reverseControl: boolean): void {
  let kind: CaptureNoticeKind = CaptureNoticeKind.Error;
  let text: string = body;
  if (text.length === 0 && diagnostic.length > 0) {
    text = capture_error_guidance_message(diagnostic);
  }
  if (is_usb_configuration_failure(diagnostic)) {
    kind = CaptureNoticeKind.UsbConfiguration;
  }
  open_notice(ctx, title, text, kind, reverseControl, true)
    .catch((error: BusinessError): void => {
      hilog.error(DOMAIN, TAG, 'ShowError 打开失败: %{public}s', error.message);
    });
}

/**
 * 原版 internal static void ShowStoppedThen(string title, string body,
 *                                            Func<Task> afterShown)。
 * 原版挂 ContentRendered，等 Dispatcher 空闲后跑 afterShown（平台替换 4）。
 */
export function show_capture_stopped_then(ctx: common.Context, title: string,
                                          body: string, afterShown: () => void): void {
  pending_after_shown = afterShown;
  open_notice(ctx, title, body, CaptureNoticeKind.Stopped, false, true)
    .catch((error: BusinessError): void => {
      hilog.error(DOMAIN, TAG, 'ShowStoppedThen 打开失败: %{public}s', error.message);
    });
}

/**
 * 原版 ShowDeveloperErrorPreview：DeviceCaptureErrorTitleFormat + CaptureActionVideoRetry。
 * ⚠ 四个开发者预览入口**返回 Promise 而不自己 catch**：开发者工具窗口要靠
 *   then/catch 如实回报「打开成功 / 打开失败」，自己吞掉异常就会变成假成功。
 *   单独调用这四个函数时请自行 catch。
 */
export function show_developer_error_preview(ctx: common.Context): Promise<void> {
  return open_notice(ctx, S_PREVIEW_DEVICE() + ' 投屏错误', S_ACTION_RETRY(),
    CaptureNoticeKind.Error, false, false);
}

/**
 * 原版 ShowDeveloperReverseControlErrorPreview（**只有 main 1.8.4 有**）：
 * ReverseControlErrorTitle + ReverseControlErrorBodyFormat。
 * 正文里的 {0} 用 ReverseControlTransportWired、{1} 用
 * DeveloperPreviewReverseControlUnavailable（「开发者服务未就绪（开发者工具预览）」）。
 */
export function show_developer_reverse_control_error_preview(ctx: common.Context): Promise<void> {
  return open_notice(ctx, '反向控制错误',
    '有线反向控制发生错误：开发者服务未就绪（开发者工具预览）',
    CaptureNoticeKind.Error, true, false);
}

/** 原版 ShowDeveloperStoppedPreview：DeviceSessionClosedWarningTitleFormat + Body。 */
export function show_developer_stopped_preview(ctx: common.Context): Promise<void> {
  return open_notice(ctx, S_PREVIEW_DEVICE() + ' 投屏已停止',
    '检测到您已经在控制中心点击了停止镜像，下一次该设备有线镜像需重启 iPhone/iPad',
    CaptureNoticeKind.Stopped, false, false);
}

/** 原版 ShowDeveloperUsbPreview：CaptureUsbConfigurationTitle + CaptureActionReconnectDevice。 */
export function show_developer_usb_preview(ctx: common.Context): Promise<void> {
  return open_notice(ctx, 'USB 投屏配置错误', S_ACTION_RECONNECT_DEVICE(),
    CaptureNoticeKind.UsbConfiguration, false, false);
}

@Entry
@Component
struct CaptureStatusNoticeWindow {
  @State titleText: string = '';
  @State bodyText: string = '';
  @State kindValue: number = CaptureNoticeKind.Error;
  @State reverseControl: boolean = false;

  aboutToAppear(): void {
    this.titleText = AppStorage.get<string>(ARG_KEY_TITLE) ?? '';
    this.bodyText = AppStorage.get<string>(ARG_KEY_BODY) ?? '';
    this.kindValue = AppStorage.get<number>(ARG_KEY_KIND) ?? CaptureNoticeKind.Error;
    this.reverseControl = AppStorage.get<boolean>(ARG_KEY_REVERSE_CONTROL) ?? false;

    // 平台替换 4 + 服务 ②：afterShown 只跑一次（对应原版 started 标志）。
    const after: (() => void) | null = pending_after_shown;
    pending_after_shown = null;
    if (after !== null) {
      setTimeout((): void => {
        try {
          after();
        } catch (error) {
          // 原版 DiagnosticLogger.Exception("capture","capture_notice_after_shown_failed",…)
          hilog.error(DOMAIN, TAG, 'after_shown 失败: %{public}s',
            (error as BusinessError).message);
        }
      }, 0);
    }
  }

  /** xaml.cs OnCloseClick。 */
  private on_close(): void {
    SubWindowHost.close(WINDOW_NAME);
  }

  /** xaml.cs: IsStopped / IsUsbConfiguration / IsWarning。 */
  private is_stopped(): boolean {
    return this.kindValue === CaptureNoticeKind.Stopped;
  }

  private is_usb_configuration(): boolean {
    return this.kindValue === CaptureNoticeKind.UsbConfiguration;
  }

  private is_warning(): boolean {
    return this.is_stopped() || this.is_usb_configuration();
  }

  /** xaml.cs BadgeText。 */
  private badge_text(): string {
    if (this.is_stopped()) {
      return S_BADGE_STOPPED();
    }
    if (this.is_usb_configuration()) {
      return S_BADGE_USB();
    }
    return this.reverseControl ? S_BADGE_REVERSE_CONTROL() : S_BADGE_ERROR();
  }

  /** xaml.cs HintText。 */
  private hint_text(): string {
    if (this.is_stopped()) {
      return S_HINT_STOPPED();
    }
    if (this.is_usb_configuration()) {
      return S_HINT_USB();
    }
    return S_HINT_ERROR();
  }

  /** 平台替换 5：三个 DataTrigger 互斥图标 → 代码里选一个。 */
  private disc_icon(): string {
    if (this.is_usb_configuration()) {
      return 'UsbPlug20';
    }
    return this.is_stopped() ? 'Warning20' : 'ErrorCircle20';
  }

  /** Row 2：提示条（圆角 12 / Padding 14 / 两列 38 + *）。 */
  @Builder
  notice_card() {
    Row() {
      // 列 0：30×30 圆底 + 图标（OnAccentBrush）
      Stack() {
        FluentSymbol({
          iconName: this.disc_icon(),
          iconSize: 17,
          iconColor: ON_ACCENT,
        });
      }
      .width(30)
      .height(30)
      .borderRadius(15)
      .backgroundColor(this.is_warning() ? WARNING : ERROR)
      .alignContent(Alignment.Center);

      // 列 1：StackPanel Margin="8,0,0,0"
      Column() {
        Text(this.badge_text())
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT)
          .width('100%');
        Text(this.bodyText)
          .fontSize(12)
          .fontColor(MUTED_TEXT)
          .width('100%')
          .margin({ top: 5 });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 8 });
    }
    .width('100%')
    .padding(14)
    .borderRadius(12)
    .backgroundColor(this.is_warning() ? WARNING_SURFACE : ERROR_SURFACE)
    .border({ width: 1, color: this.is_warning() ? WARNING : ERROR })
    .alignItems(VerticalAlign.Top);
  }

  /**
   * 平台替换 2：原版行 2（提示条）+ 行 3（12）+ 行 4（徽标 + 关闭）整段放进
   * content 槽（顶部对齐、可滚动），hasNotice / hasActions 都关掉。
   */
  @Builder
  body() {
    Scroll() {
      Column() {
        this.notice_card();

        Column().height(12);          // 行 3 = 12

        Row() {
          BadgeChip({
            iconName: 'ArrowClockwise20',
            chipText: this.hint_text(),
          });
          PrimaryButton({
            label: S_CLOSE(),
            minButtonWidth: 80,
            buttonHeight: 36,
            on_action: (): void => { this.on_close(); },
          })
            .margin({ left: 12 });
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center);
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%');
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Auto)
    .align(Alignment.Top);
  }

  build() {
    Column() {
      SubWindowShell({
      windowName: WINDOW_NAME,
      title: this.titleText,
      subtitle: '',                   // 原版表头只有 SubWindowTitle，没有 SubWindowSubtitle
      // Border Padding="20"（不是 SubWindowPageRoot 的 24,20），底色 DialogSurfaceBrush
      pageMarginH: 20,
      pageMarginV: 20,
      shellBackground: DIALOG_SURFACE,
      gap: SUBWINDOW_ROW_GAP,         // 行 1 = 16
      hasNotice: false,               // 行 2/4 都落在 content 里（平台替换 2）
      hasFooter: false,
      hasActions: false,              // 「关闭」画在 content 里，紧跟着提示条
      content: (): void => { this.body(); },
    });
    }
  }
}
