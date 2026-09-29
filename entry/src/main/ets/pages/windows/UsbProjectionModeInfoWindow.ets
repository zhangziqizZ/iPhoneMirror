// UsbProjectionModeInfoWindow.ets —— 子窗口 6/20：有线投屏模式说明
//
// 逐项对照上游 src/App/Windows/UsbProjectionModeInfoWindow.xaml（78 行）
//              src/App/Windows/UsbProjectionModeInfoWindow.xaml.cs（18 行）
//
// ── 窗口属性（XAML 根元素 <ui:FluentWindow>）────────────────────────────────
//   Title="{DynamicResource UsbModeDetailsTitle}"  → 「有线投屏模式说明」
//   Width="540" Height="620" MinWidth="540" MinHeight="620"
//   WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
//   ExtendsContentIntoTitleBar="True"   → decorEnabled: false + 自绘表头
//   Background="{DynamicResource AppBackgroundBrush}" → shell 默认底色
//
// ── 行定义（5 行）─────────────────────────────────────────────────────────
//   Row Auto : SubWindowHeader
//                StackPanel Margin="0,0,48,0"：
//                  TextBlock x:Name="ModeTitle"（Style=SubWindowTitle）← 由 cs 填 option.Label
//                  TextBlock Text="{DynamicResource UsbModeDetailsTitle}"（SubWindowSubtitle）
//   Row 16   : 间隔
//   Row *    : ScrollViewer（VerticalScrollBarVisibility=Auto / Horizontal=Disabled / Padding 0,0,8,0）
//                └ Border Style=SettingsSection
//   Row 18   : 间隔
//   Row Auto : Button Close（Width 112 / Height 40 / PrimaryButton / 靠右 / IsDefault + IsCancel）
//
// ── 卡片内（StackPanel）───────────────────────────────────────────────────
//   TextBlock UsbModeAdvantageTitle   Style=SubWindowSectionTitle（14 / SemiBold）
//   TextBlock x:Name="AdvantageText"  Style=SubWindowSubtitle（Muted 12）+ LineHeight 19
//                                     + Margin 0,6,0,0
//   Border Height=1 BorderSoftBrush Margin 0,18,0,16      ← 分隔线
//   TextBlock UsbModeDisadvantageTitle  Style=SubWindowSectionTitle
//   TextBlock x:Name="DisadvantageText" 同上
//   Border WarningSurfaceBrush 底 / WarningBrush 1px 边 / 圆角 12 / Padding 14 / Margin 0,18,0,0
//     Grid 两列 = 24 / *
//       列 0：Border 18×18 圆角 9、WarningBrush 1px 边（**无底色**）、顶部对齐，
//             里面是 TextBlock "!"（WarningBrush 11 Bold，水平垂直居中）
//       列 1：TextBlock x:Name="NoticeText"（Muted 11 / Wrap / LineHeight 18）
//
// ── xaml.cs 的行为 ────────────────────────────────────────────────────────
//   构造函数收一个 UsbProjectionModeOption，把四段文案分别填进
//   ModeTitle / AdvantageText / DisadvantageText / NoticeText。
//   OnCloseClick → Close()
//
// ── 平台替换 ──────────────────────────────────────────────────────────────
//   原版直接传 UsbProjectionModeOption 对象进构造函数；鸿蒙开窗只能给页面路径，
//   所以本轮改用 SubWindowHost 的通用「窗口参数」通道：调用方把模式枚举放进
//   AppStorage，窗口 aboutToAppear 里取出并查 USB_PROJECTION_MODES。
//   （对象本身是静态常量表，传枚举就够了。）

import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  SubWindowShell, SubWindowHost, PrimaryButton, SettingsSection,
  SUBWINDOW_ROW_GAP,
  SubWindowSpec,
} from '../../common/SubWindow';
import {
  TEXT, MUTED_TEXT, WARNING, WARNING_SURFACE, BORDER_SOFT, SETTINGS_SECTION_PADDING,
} from '../../common/Theme';
import { UsbProjectionMode, UsbProjectionModeOption, usb_projection_mode_option } from '../../common/UsbProjectionMode';

const TAG: string = 'im_usb_mode_info';
const DOMAIN: number = 0x0100;

export const WINDOW_NAME: string = 'UsbProjectionModeInfoWindow';
export const PAGE_PATH: string = 'pages/windows/UsbProjectionModeInfoWindow';

/** 原版构造函数入参 UsbProjectionMode option 的传递键。 */
export const ARG_KEY_MODE: string = 'im.usbModeInfo.mode';

/** 原版 <Button ... Width="112" Height="40"> */
const CLOSE_BUTTON_WIDTH: number = 112;
const CLOSE_BUTTON_HEIGHT: number = 40;

/**
 * 原版 `new UsbProjectionModeInfoWindow(option) { Owner = this }.ShowDialog()`。
 * 用模式枚举当入参（文案表是静态常量，不需要传对象）。
 */
export function open_usb_projection_mode_info(ctx: common.Context, mode: UsbProjectionMode): void {
  AppStorage.setOrCreate<number>(ARG_KEY_MODE, mode);

  const spec: SubWindowSpec = {
    name: WINDOW_NAME,
    page: PAGE_PATH,
    title: '有线投屏模式说明',        // Strings: UsbModeDetailsTitle
    width: 540,
    height: 620,
    resizable: false,                // ResizeMode="NoResize"
    minWidth: 540,
    minHeight: 620,
    modal: true,                     // ShowDialog()
  };
  SubWindowHost.open(ctx, spec).catch((error: BusinessError): void => {
    hilog.error(DOMAIN, TAG, '打开失败: %{public}s', error.message);
  });
}

@Entry
@Component
struct UsbProjectionModeInfoWindow {
  /** 原版 ModeTitle.Text = option.Label */
  @State modeLabel: string = '';
  /** 原版 AdvantageText.Text = option.Advantage */
  @State advantageText: string = '';
  /** 原版 DisadvantageText.Text = option.Disadvantage */
  @State disadvantageText: string = '';
  /** 原版 NoticeText.Text = option.Notice */
  @State noticeText: string = '';

  aboutToAppear(): void {
    const mode: number = AppStorage.get<number>(ARG_KEY_MODE) ?? UsbProjectionMode.Demo;
    const option: UsbProjectionModeOption = usb_projection_mode_option(mode as UsbProjectionMode);
    this.modeLabel = option.label;
    this.advantageText = option.advantage;
    this.disadvantageText = option.disadvantage;
    this.noticeText = option.notice;
    hilog.info(DOMAIN, TAG, '模式说明已载入：%{public}s', option.label);
  }

  /** 原版 OnCloseClick。 */
  private on_close(): void {
    SubWindowHost.close(WINDOW_NAME);
  }

  /** XAML 里 Height="1" / BorderSoftBrush / Margin="0,18,0,16" 的分隔线。 */
  @Builder
  divider() {
    Column()
      .width('100%')
      .height(1)
      .backgroundColor(BORDER_SOFT)
      .margin({ top: 18, bottom: 16 });
  }

  /**
   * SubWindowSubtitle 样式（MutedTextBrush / FontSize 12）在本窗口被加了
   * LineHeight="19" 与 Margin="0,6,0,0"。
   */
  @Builder
  section_body(text: string) {
    Text(text)
      .fontSize(12)
      .fontColor(MUTED_TEXT)
      .lineHeight(19)
      .width('100%')
      .margin({ top: 6 });
  }

  /** SubWindowSectionTitle 样式：14 / SemiBold / TextBrush。 */
  @Builder
  section_heading(text: string) {
    Text(text)
      .fontSize(14)
      .fontWeight(FontWeight.Bold)
      .fontColor(TEXT)
      .width('100%');
  }

  /** 注意事项块：WarningSurface / WarningBrush / 圆角 12 / Padding 14。 */
  @Builder
  notice_block() {
    Row() {
      // 列 0（宽 24）：18×18 圆角 9 的描边圈 + 居中 "!"
      Stack() {
        Text('!')
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor(WARNING);
      }
      .width(18)
      .height(18)
      .borderRadius(9)
      .border({ width: 1, color: WARNING })
      .alignContent(Alignment.Center)
      .alignSelf(ItemAlign.Start);

      // 列 1：Muted 11 / Wrap / LineHeight 18
      Text(this.noticeText)
        .fontSize(11)
        .fontColor(MUTED_TEXT)
        .lineHeight(18)
        .layoutWeight(1)
        .margin({ left: 6 });
    }
    .width('100%')
    .padding(14)
    .borderRadius(12)
    .backgroundColor(WARNING_SURFACE)
    .border({ width: 1, color: WARNING })
    .alignItems(VerticalAlign.Top);
  }

  /** Border Style=SettingsSection 里的那个 StackPanel。 */
  @Builder
  card_body() {
    Column() {
      this.section_heading('优点');                 // Strings: UsbModeAdvantageTitle
      this.section_body(this.advantageText);

      this.divider();

      this.section_heading('缺点');                 // Strings: UsbModeDisadvantageTitle
      this.section_body(this.disadvantageText);

      Column() {
        this.notice_block();
      }
      .width('100%')
      .margin({ top: 18 });
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%');
  }

  /** Row * ：ScrollViewer（Padding 0,0,8,0）里放卡片。 */
  @Builder
  body() {
    Scroll() {
      Column() {
        SettingsSection({ padH: SETTINGS_SECTION_PADDING, padV: SETTINGS_SECTION_PADDING,
          content: (): void => { this.card_body(); } });
      }
      .width('100%')
      .padding({ right: 8 });     // 原版 ScrollViewer Padding="0,0,8,0"
    }
    .width('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring);
  }

  /** Row Auto ：靠右的「关闭」主按钮（Width 112 / Height 40）。 */
  @Builder
  actions() {
    PrimaryButton({
      label: '关闭',                    // Strings: Close
      buttonWidth: CLOSE_BUTTON_WIDTH,
      buttonHeight: CLOSE_BUTTON_HEIGHT,
      on_action: (): void => { this.on_close(); },
    });
  }

  build() {
    Column() {
      SubWindowShell({
      windowName: WINDOW_NAME,
      title: this.modeLabel,           // 原版 ModeTitle 由 cs 填 option.Label
      subtitle: '有线投屏模式说明',      // Strings: UsbModeDetailsTitle
      gap: SUBWINDOW_ROW_GAP,          // 行 1 = 16
      hasNotice: false,
      hasFooter: false,
      hasActions: true,
      actionGap: 18,                   // 行 3 = 18
      actionsSplit: false,
      content: (): void => { this.body(); },
      actions: (): void => { this.actions(); },
    });
    }
  }
}
