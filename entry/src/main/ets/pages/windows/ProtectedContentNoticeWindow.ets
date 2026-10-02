// ProtectedContentNoticeWindow.ets —— 子窗口 5/20：受保护内容（DRM）提示
//
// 逐项对照上游 src/App/Windows/ProtectedContentNoticeWindow.xaml（99 行）
//              src/App/Windows/ProtectedContentNoticeWindow.xaml.cs（77 行）
//
// ── 窗口属性（XAML 根元素 <ui:FluentWindow>）────────────────────────────────
//   Width="430" SizeToContent="Height" MinHeight="212"
//     → 高度自适应内容，最小 212。鸿蒙侧窗口高度是显式给的，取 212；
//       SizeToContent 的效果由「底部按钮行贴底」来近似（见下）。
//   ResizeMode="NoResize"                → resizable: false
//   WindowStartupLocation="CenterOwner"  → SubWindowHost.open 里算居中
//   WindowStyle="None" + ExtendsContentIntoTitleBar="True" → decorEnabled: false + 自绘表头
//   WindowBackdropType="None"            → 不带 Mica/Acrylic，用实色底
//   Background="{DynamicResource WindowBackgroundBrush}"
//   ShowInTaskbar="False"                → 子窗口本来就不进任务栏（鸿蒙无对应项）
//   ★ 这个窗口没有 Title 属性；标题走绑定 TitleText = CaptureVideoProtectedNoticeTitle，
//     同时表头文字也是它（不是 SubWindowSubtitle）。
//
// ── 内容根 ────────────────────────────────────────────────────────────────
//   <Border Style="{StaticResource ModernDialogSurface}" Margin="0"
//           Effect="{x:Null}" CornerRadius="0" BorderThickness="0" Padding="20">
//   ModernControls.xaml 里 ModernDialogSurface 的定义是：
//     Background = DialogSurfaceBrush / BorderBrush 1px / CornerRadius 20 / Padding 26
//   这里覆盖了 CornerRadius(0) / BorderThickness(0) / Padding(20) / Effect，
//   **没有覆盖 Background**，所以可见底色仍是 DialogSurfaceBrush。
//   → 所以页面底色取 DIALOG_SURFACE，内边距取 20。
//
// ── 行定义（5 行）─────────────────────────────────────────────────────────
//   Row Auto : SubWindowHeader（标题 CaptureVideoProtectedNoticeTitle，Margin 0,0,48,0）
//   Row 16   : 间隔
//   Row Auto : 黄色提示块（WarningSurface / WarningBrush）
//   Row 12   : 间隔
//   Row Auto : 徽标行 + 「关闭」按钮（两列：* / Auto）
//
// ── 黄色提示块 ────────────────────────────────────────────────────────────
//   Border WarningSurfaceBrush 底 / WarningBrush 1px 边 / 圆角 12 / Padding 14
//   Grid 两列 = 38 / *
//     列 0：Border 30×30 圆角 15 底色 WarningBrush，顶部对齐；
//           里面是 SymbolIcon Warning20 / FontSize 17 / Foreground OnAccentBrush / 居中
//     列 1：StackPanel Margin="8,0,0,0"
//             TextBlock VideoStatusText      FontSize 14 / SemiBold
//             TextBlock ProtectionStatusText MutedTextBrush / FontSize 12 / Margin 0,4,0,0
//
// ── 徽标行（Row 4 的左列）─────────────────────────────────────────────────
//   WrapPanel VerticalAlignment="Center" ItemHeight="30"，两枚圆角 15 徽标：
//     ControlFillBrush 底 / BorderSoftBrush 1px 边 / 圆角 15 / Padding 10,5
//     徽标 1 Margin="0,0,6,0" : Speaker220(14, Muted) + AudioBadgeText(11, Muted, VCenter)
//     徽标 2                 : ArrowClockwise20(14, Muted) + HintText(11, Muted, VCenter)
//   右列：Button Close（PrimaryButton / MinWidth 80 / Height 36 / Margin 12,0,0,0）
//
// ── xaml.cs 的行为 ────────────────────────────────────────────────────────
//   AudioBadgeText 随 _audioActive 在两串文案间切换：
//     有音频  ← CaptureVideoProtectedAudioBadgeActive
//     无音频  ← CaptureVideoProtectedAudioBadgeUnavailable
//     ★ 注意 xaml.cs 里引用的是 CaptureVideoProtectedAudioBadge*，
//       而 xaml 里的绑定名是 CaptureVideoProtectedNoticeAudioBadge*，
//       资源字典里存在的键是前者（zh-CN：有音频 / 无音频），这里以后者为准。
//   UpdatePresentation(presentation)：
//       !presentation.IsProtected → 直接 Close()
//       否则若 AudioActive 变了，只刷新 AudioBadgeText
//   OnCloseClick → Close()
//   DeviceUdid 只存不显示（原版界面上没有用到它）
//   ShowDeveloperPreview(owner)：用 DeveloperPreviewDeviceName（「预览设备」）
//       + IsProtected:true / AudioActive:false 打开，非模态

import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  SubWindowShell, SubWindowHost, PrimaryButton, BadgeChip,
  SUBWINDOW_ROW_GAP,
  SubWindowSpec,
} from '../../common/SubWindow';
import { FluentSymbol } from '../../common/FluentIcon';
import {
  TEXT, MUTED_TEXT, WARNING, WARNING_SURFACE, ON_ACCENT, DIALOG_SURFACE,
} from '../../common/Theme';
import {
  WindowServices, ProtectedContentPresentation, ProtectedContentHandle, ProtectedContentRequest,
} from '../../common/WindowServices';
import { t } from '../../common/i18n';

const TAG: string = 'im_protected_notice';
const DOMAIN: number = 0x0100;

export const WINDOW_NAME: string = 'ProtectedContentNoticeWindow';
export const PAGE_PATH: string = 'pages/windows/ProtectedContentNoticeWindow';

/** 原版 MinHeight="212"：SizeToContent=Height 下这就是实际高度。 */
const WINDOW_HEIGHT: number = 212;
/** Grid.ColumnDefinitions 第一列 = 38。 */
const ICON_COLUMN_WIDTH: number = 38;
/** 图标圆：30×30 / 圆角 15 / 图标 FontSize 17。 */
const ICON_DISC_SIZE: number = 30;
const ICON_DISC_CORNER: number = 15;
const ICON_SIZE: number = 17;

/** Strings （键名与取值逐条标注）。 */
const S_TITLE = (): string => t('请确认当前视频投放是否正常？');               // CaptureVideoProtectedNoticeTitle
const S_VIDEO = (): string => t('检测到当前视频画面持续为黑屏');// CaptureVideoProtectedNoticeVideo
const S_PROTECTION: string =
  '这可能与 DRM / FairPlay 或其他内容保护机制有关';                    // CaptureVideoProtectedNoticeProtection
const S_HINT = (): string => t('画面恢复后自动关闭');// CaptureVideoProtectedNoticeHint
const S_AUDIO_ACTIVE = (): string => t('有音频');// CaptureVideoProtectedAudioBadgeActive
const S_AUDIO_UNAVAILABLE = (): string => t('无音频');// CaptureVideoProtectedAudioBadgeUnavailable
const S_CLOSE = (): string => t('关闭');// Close
const S_PREVIEW_DEVICE = (): string => t('预览设备');// DeveloperPreviewDeviceName

/**
 * 原版 internal static void Show(Window owner, string deviceUdid, ProtectedContentPresentation)。
 * 原版没有把 Show 包成静态方法，而是由 MainWindow 直接 new；这里给一个统一入口。
 */
export function open_protected_content_notice(ctx: common.Context,
                                               deviceUdid: string,
                                               presentation: ProtectedContentPresentation,
                                               modal: boolean): void {
  WindowServices.pending_protected_content =
    new ProtectedContentRequest(deviceUdid, presentation);

  const spec: SubWindowSpec = {
    name: WINDOW_NAME,
    page: PAGE_PATH,
    title: S_TITLE(),
    width: 430,
    height: WINDOW_HEIGHT,
    resizable: false,                // ResizeMode="NoResize"
    minWidth: 430,
    minHeight: WINDOW_HEIGHT,
    modal: modal,
  };
  SubWindowHost.open(ctx, spec).catch((error: BusinessError): void => {
    hilog.error(DOMAIN, TAG, '打开失败: %{public}s', error.message);
  });
}

/**
 * 原版 internal static void ShowDeveloperPreview(Window owner)。
 *   new ProtectedContentPresentation(IsProtected: true, AudioActive: false,
 *                                    AudioSampleRate: 0, AudioChannels: 0)
 *   设备名用 DeveloperPreviewDeviceName（「预览设备」）
 */
export function open_protected_content_preview(ctx: common.Context): void {
  open_protected_content_notice(ctx, S_PREVIEW_DEVICE(),
    { isProtected: true, audioActive: false, audioSampleRate: 0, audioChannels: 0 },
    false);
}

@Entry
@Component
struct ProtectedContentNoticeWindow {
  /** 原版 DeviceUdid：只存不显示。 */
  private deviceUdid: string = '';
  /** 原版 _audioActive，决定 AudioBadgeText 取哪一串文案。 */
  @State audioActive: boolean = false;

  /** 原版 this 作为窗口句柄暴露给主窗口（主窗口调 UpdatePresentation）。 */
  private handle: ProtectedContentHandle = new ProtectedContentHandle(
    (presentation: ProtectedContentPresentation): void => {
      this.update_presentation(presentation);
    },
  );

  aboutToAppear(): void {
    const pending: ProtectedContentRequest | null = WindowServices.pending_protected_content;
    WindowServices.pending_protected_content = null;
    if (pending !== null) {
      this.deviceUdid = pending.deviceUdid;
      this.audioActive = pending.presentation.audioActive;
    }
    WindowServices.protected_content_window = this.handle;
    hilog.info(DOMAIN, TAG, '受保护内容提示已打开，audioActive=%{public}s',
      this.audioActive ? 'true' : 'false');
  }

  aboutToDisappear(): void {
    WindowServices.protected_content_window = null;
  }

  /** 原版 UpdatePresentation(presentation)。 */
  private update_presentation(presentation: ProtectedContentPresentation): void {
    if (!presentation.isProtected) {
      // 原版：画面不再受保护就直接关窗。
      SubWindowHost.close(WINDOW_NAME);
      return;
    }
    // 原版只在「音频状态真的变了」时刷新徽标文案；@State 赋值天然满足这一点。
    this.audioActive = presentation.audioActive;
  }

  /** 原版 OnCloseClick。 */
  private on_close(): void {
    SubWindowHost.close(WINDOW_NAME);
  }

  /** Row Auto：黄色提示块。 */
  @Builder
  notice() {
    Row() {
      // 列 0：圆底 + 居中警示图标（顶部对齐）
      Stack() {
        FluentSymbol({
          iconName: 'Warning20',
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

      // 列 1：两行文字
      Column() {
        Text(S_VIDEO())
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT)
          .width('100%');
        Text(S_PROTECTION)
          .fontSize(12)
          .fontColor(MUTED_TEXT)
          .width('100%')
          .margin({ top: 4 });
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

  /**
   * Row Auto（最后一行）：左边两枚徽标、右边「关闭」按钮。
   * ⚠ 这里用 actionsSplit=true 走 SpaceBetween：左侧徽标（包一层 Row）贴着左边，
   *   右侧按钮贴着右边，与原来那两列 `* / Auto` 的效果一致。
   */
  @Builder
  actions() {
    Row() {
      BadgeChip({
        iconName: 'Speaker220',
        chipText: this.audioActive ? S_AUDIO_ACTIVE() : S_AUDIO_UNAVAILABLE(),
        chipMarginEnd: 6,
      });
      BadgeChip({
        iconName: 'ArrowClockwise20',
        chipText: S_HINT(),
        chipMarginEnd: 0,
      });
    }
    .alignItems(VerticalAlign.Center);

    Row() {
      PrimaryButton({
        label: S_CLOSE(),
        minButtonWidth: 80,
        buttonHeight: 36,
        on_action: (): void => { this.on_close(); },
      });
    }
    .margin({ left: 12 });
  }

  build() {
    Column() {
      SubWindowShell({
      windowName: WINDOW_NAME,
      title: S_TITLE(),
      subtitle: '',                    // 原版表头只有标题
      // Border Padding="20"（覆盖了 ModernDialogSurface 的 26）；底色是 DialogSurfaceBrush
      pageMarginH: 20,
      pageMarginV: 20,
      shellBackground: DIALOG_SURFACE,
      gap: SUBWINDOW_ROW_GAP,          // 行 1 = 16
      hasNotice: true,                 // 行 2 = 黄色提示块
      noticeGap: 12,                   // 行 3 = 12
      hasFooter: false,
      hasActions: true,
      actionGap: 0,                    // 原版最后一行紧接提示块（中间是 12 的间隔已计入 noticeGap）
      actionsSplit: true,              // 徽标靠左、按钮靠右
      notice: (): void => { this.notice(); },
      actions: (): void => { this.actions(); },
    });
    }
  }
}
