// CaptureRecoveryWindow.ets —— 子窗口 4/20：投屏连接超时恢复向导
//
// 逐项对照上游 src/App/Windows/CaptureRecoveryWindow.xaml（108 行）
//              src/App/Windows/CaptureRecoveryWindow.xaml.cs（18 行）
//
// ── 窗口属性（XAML 根元素 <ui:FluentWindow>）────────────────────────────────
//   Width="620" Height="500"             → SubWindowSpec 620×500
//   ResizeMode="NoResize"                → resizable: false
//   WindowStartupLocation="CenterOwner"  → SubWindowHost.open 里算居中
//   WindowStyle="None" + ExtendsContentIntoTitleBar="True" → decorEnabled: false + 自绘表头
//   WindowBackdropType="Acrylic"         → 由系统窗口负责
//   WindowCornerPreference="Round"       → 由系统窗口负责
//   这个窗口**没有 Title 属性**（Title 由 xaml.cs 走默认，界面上不显示），
//   所以 SubWindowSpec.title 只传给系统窗口，界面表头用的是 CaptureNoPingTitle。
//   Background="{DynamicResource AppBackgroundBrush}" 被下面那层 Border 盖住了——
//   实际可见底色是 Border 的 DialogSurfaceBrush。
//
// ── 内容根（原版注释解释了为什么不用 ModernDialogSurface）──────────────────
//   <!-- Keep the window's DWM/Windows corner treatment. The previous
//        ModernDialogSurface added a second rounded border and produced a
//        bright ring around the native window corners. -->
//   <Border Background="{DynamicResource DialogSurfaceBrush}"
//           Margin="0" Padding="26" BorderThickness="0"
//           CornerRadius="0" Effect="{x:Null}">
//   → 所以页面内边距是 26（不是 SubWindowPageRoot 的 24,20），底色是 DIALOG_SURFACE，
//     并且没有圆角（交给系统窗口的 WindowCornerPreference）。
//
// ── 行定义（Grid.RowDefinitions，7 行）──────────────────────────────────────
//   Row Auto : SubWindowHeader（标题 CaptureNoPingTitle，关闭按钮 ToolTip=Close）
//   Row 16   : 间隔
//   Row Auto : TextBlock CaptureNoPingSummary（Muted 14 / LineHeight 22 / Wrap）
//   Row 18   : 间隔
//   Row *    : 三张卡片（两张黄色步骤卡 + 一张灰色提示卡，卡间距 12）
//   Row 18   : 间隔
//   Row Auto : Button Close（PrimaryButton / MinWidth 120 / 靠右）
//
// ── 步骤卡（上面两张，样式一致）────────────────────────────────────────────
//   Border WarningSurfaceBrush 底 / WarningBrush 1px 边 / 圆角 16 / Padding 18,16
//   Grid 两列 = 48 / *
//     列 0：Border 34×34 圆角 17 底色 WarningBrush，里面是居中大写数字
//           （数字 OnAccentBrush / FontSize 18 / Bold / 水平垂直居中）
//     列 1：步骤文字 TextBrush / FontSize 19 / SemiBold / Wrap / 垂直居中
//   第二张卡 Margin="0,12,0,0"
//
// ── 提示卡（下面一张）──────────────────────────────────────────────────────
//   Border ControlFillBrush 底 / BorderBrush 1px 边 / 圆角 12 / Padding 14,11
//   TextBlock CaptureNoPingUnlockHint / FontSize 13 / SemiBold / Wrap / TextAlignment Center
//   卡 Margin="0,12,0,0"
//
// ── xaml.cs 的行为 ────────────────────────────────────────────────────────
//   ShowRecovery()      → 以 Application.Current.MainWindow 为 Owner 的 ShowDialog()
//   ShowDeveloperPreview(owner) → Show()（非模态）
//   OnCloseClick        → Close()

import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  SubWindowShell, SubWindowHost, PrimaryButton,
  SUBWINDOW_ROW_GAP,
  SubWindowSpec,
} from '../../common/SubWindow';
import {
  TEXT, MUTED_TEXT, WARNING, WARNING_SURFACE, ON_ACCENT,
  CONTROL_FILL, BORDER, BORDER_SOFT, DIALOG_SURFACE,
} from '../../common/Theme';
import { t } from '../../common/i18n';

const TAG: string = 'im_capture_recovery';
const DOMAIN: number = 0x0100;

export const WINDOW_NAME: string = 'CaptureRecoveryWindow';
export const PAGE_PATH: string = 'pages/windows/CaptureRecoveryWindow';

/** 卡间距：原版第二、三张卡都写 Margin="0,12,0,0"。 */
const CARD_GAP: number = 12;
/** 步骤圆：34×34 / 圆角 17 / FontSize 18 / Bold。 */
const STEP_DISC_SIZE: number = 34;
const STEP_DISC_CORNER: number = 17;
const STEP_NUMBER_SIZE: number = 18;
/** 步骤文字列宽 48（Grid.ColumnDefinitions 的第一列）。 */
const STEP_COLUMN_WIDTH: number = 48;

/**
 * 原版 internal static void ShowRecovery()，Owner 是主窗口，模态。
 * 原版还有 internal static void ShowDeveloperPreview(Window owner) 走非模态 Show()，
 * 这里用同一个入口（鸿蒙侧区别只是 isModal）。
 */
export function open_capture_recovery(ctx: common.Context, modal: boolean): void {
  const spec: SubWindowSpec = {
    name: WINDOW_NAME,
    page: PAGE_PATH,
    title: 'iPhone/iPad 投屏连接超时',   // 界面表头用的文案（CaptureNoPingTitle）
    width: 620,
    height: 500,
    resizable: false,                    // ResizeMode="NoResize"
    minWidth: 620,
    minHeight: 500,
    modal: modal,
  };
  SubWindowHost.open(ctx, spec).catch((error: BusinessError): void => {
    hilog.error(DOMAIN, TAG, '打开失败: %{public}s', error.message);
  });
}

@Entry
@Component
struct CaptureRecoveryWindow {
  aboutToAppear(): void {
    hilog.info(DOMAIN, TAG, '投屏连接超时向导已打开');
  }

  /** 原版 OnCloseClick。 */
  private on_close(): void {
    SubWindowHost.close(WINDOW_NAME);
  }

  /**
   * Row Auto（表头下面那行）：CaptureNoPingSummary。
   * MutedTextBrush / FontSize 14 / LineHeight 22 / Wrap。
   */
  @Builder
  notice() {
    Text('设备已连接，但长时间没有响应投屏握手。再次尝试前，请优先完成以下两项操作：')
      .fontSize(14)
      .fontColor(MUTED_TEXT)
      .lineHeight(22)
      .width('100%');
  }

  /** 上面两张步骤卡之一。 */
  @Builder
  step_card(stepNumber: string, stepText: string) {
    Row() {
      // 列 0：圆底 + 居中数字
      Stack() {
        Text(stepNumber)
          .fontSize(STEP_NUMBER_SIZE)
          .fontWeight(FontWeight.Bold)
          .fontColor(ON_ACCENT);
      }
      .width(STEP_DISC_SIZE)
      .height(STEP_DISC_SIZE)
      .borderRadius(STEP_DISC_CORNER)
      .backgroundColor(WARNING)
      .alignContent(Alignment.Center);

      // 列 1：步骤文字
      Text(stepText)
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT)
        .layoutWeight(1)
        .margin({ left: STEP_COLUMN_WIDTH - STEP_DISC_SIZE });
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 16, bottom: 16 })
    .borderRadius(16)
    .backgroundColor(WARNING_SURFACE)
    .border({ width: 1, color: WARNING })
    .alignItems(VerticalAlign.Center);
  }

  /** 下面那张提示卡。 */
  @Builder
  hint_card() {
    Text('重新连接并开始投屏时，请保持设备处于解锁状态。')
      .fontSize(13)
      .fontWeight(FontWeight.Bold)
      .fontColor(TEXT)
      .textAlign(TextAlign.Center)
      .width('100%')
      .padding({ left: 14, right: 14, top: 11, bottom: 11 })
      .borderRadius(12)
      .backgroundColor(CONTROL_FILL)
      .border({ width: 1, color: BORDER });
  }

  /** Row * ：三张卡片。 */
  @Builder
  body() {
    Column() {
      this.step_card('1', '重启 iPhone 或 iPad');                 // CaptureNoPingRestartAction
      Column() {
        this.step_card('2', '更换 Apple 原装或 MFi 认证数据线');      // CaptureNoPingCableAction
      }
      .width('100%')
      .margin({ top: CARD_GAP });
      Column() {
        this.hint_card();
      }
      .width('100%')
      .margin({ top: CARD_GAP });
      // 原版 StackPanel 在 * 行里顶部对齐（VerticalAlignment 默认 Stretch，但内容不满时留在顶部）
      Column().layoutWeight(1);
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  /** Row Auto ：靠右的「关闭」主按钮（MinWidth 120）。 */
  @Builder
  actions() {
    PrimaryButton({
      label: '关闭',                    // Strings: Close
      minButtonWidth: 120,
      on_action: (): void => { this.on_close(); },
    });
  }

  build() {
    Column() {
      SubWindowShell({
      windowName: WINDOW_NAME,
      title: 'iPhone/iPad 投屏连接超时',
      subtitle: '',
      // Border Padding="26"（不是 SubWindowPageRoot 的 24,20），底色是 DialogSurfaceBrush
      pageMarginH: 26,
      pageMarginV: 26,
      shellBackground: DIALOG_SURFACE,
      gap: SUBWINDOW_ROW_GAP,        // 行 1 = 16
      hasNotice: true,               // 行 2 = CaptureNoPingSummary
      noticeGap: 18,                 // 行 3 = 18
      hasFooter: false,
      hasActions: true,
      actionGap: 18,                 // 行 5 = 18
      actionsSplit: false,
      notice: (): void => { this.notice(); },
      content: (): void => { this.body(); },
      actions: (): void => { this.actions(); },
    });
    }
  }
}
