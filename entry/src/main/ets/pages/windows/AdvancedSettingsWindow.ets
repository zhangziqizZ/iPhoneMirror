// AdvancedSettingsWindow.ets —— 子窗口 1/20：高级 USB 设置
//
// 逐项对照上游 src/App/Windows/AdvancedSettingsWindow.xaml（41 行）
//              src/App/Windows/AdvancedSettingsWindow.xaml.cs（校验逻辑）
//
// ── 窗口属性（XAML 根元素 <ui:FluentWindow> 那一行）──────────────────────────
//   Title="{DynamicResource AdvancedSettingsTitle}"  → 「高级 USB 设置」
//   Width="520" Height="450"                          → SubWindowSpec 520×450
//   WindowStartupLocation="CenterOwner"               → SubWindowHost.open 里算居中
//   ResizeMode="NoResize"                             → resizable: false
//   ExtendsContentIntoTitleBar="True"                 → decorEnabled: false + 自绘表头
//   WindowBackdropType="Mica" / WindowCornerPreference="Round"
//                                                     → 由系统窗口负责，界面层无需复现
//   Background="{DynamicResource AppBackgroundBrush}" → SubWindowShell 的底色
//
// ── 控件级对照 ─────────────────────────────────────────────────────────────
//   Grid Style=SubWindowPageRoot（Margin 24,20）
//     Row Auto : Grid Style=SubWindowHeader（MinHeight 44, WindowDragBehavior）
//                  StackPanel Margin="0,0,48,0"
//                    TextBlock Style=SubWindowTitle     → shell 的 title
//                    TextBlock Style=SubWindowSubtitle  → shell 的 subtitle
//                  Button Style=SubWindowCloseButton + SymbolIcon Dismiss20/18
//     Row 16   : 间隔（原版写死 16）
//     Row *    : Border Style=SettingsSection（圆角 16 / Padding 18 / 卡片底）
//                  TextBlock AdvancedUsbResolution（SemiBold）
//                  TextBlock AdvancedUsbResolutionHelp（Muted 11 Wrap, Margin 0,6,0,12）
//                  Grid Margin="0,5,0,0"  列 = * / 18 / *
//                    高度标签 + HeightBox    ← 注意：左是「高度」，原版顺序不可改
//                    TextBlock "×"（Muted / 居中 / 底对齐 / Margin 0,0,0,10）
//                    宽度标签 + WidthBox
//                  TextBlock ErrorText（ErrorBrush 11 Wrap, Margin 0,10,0,0）
//     Row 16   : 间隔
//     Row Auto : Button「关闭高级模式」150×40 靠左；Button「应用」112×40 靠右（PrimaryButton）
//
// ── 文案来源 Strings.zh-CN.xaml（逐字取用）────────────────────────────────
//   AdvancedSettingsTitle      「高级 USB 设置」
//   AdvancedSettingsIntro      「此设置仅作用于当前选中的设备，并直接写入 QuickTime USB 分辨率请求。」
//   AdvancedUsbResolution      「USB 请求分辨率」
//   AdvancedUsbResolutionHelp  「输入例如 1920×1080。应用后将忽略普通画面预设；关闭高级模式后恢复普通预设。」
//   HeightLabel / WidthLabel   「高度」/「宽度」
//   DisableAdvancedMode        「关闭高级模式」
//   Apply                      「应用」
//   AdvancedResolutionInvalid  「请输入 16–8192 范围内的有效宽度和高度。」
//
// ── 与原版行为一致的校验 ────────────────────────────────────────────────────
//   xaml.cs: uint.TryParse 且 16 ≤ 值 ≤ 8192，否则只显示 ErrorText、不关窗。
//
// ── 唯一一处平台替换（原版机制在鸿蒙没有对应物）────────────────────────────
//   原版结果通过 WPF 的 `DialogResult` 回传给调用方；鸿蒙子窗口没有等价机制。
//   这里改用 AppStorage 里三个键承载同样的三个结果字段
//   （RequestedWidth / RequestedHeight / DisableAdvancedModeRequested），
//   键名见下面 RESULT_KEY_*。主窗口读这三个键，语义与原版一致。

import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  SubWindowShell, SubWindowHost, SecondaryButton, PrimaryButton, RoundedTextBox,
  SettingsSection, field_label, error_text,
  SUBWINDOW_ROW_GAP,
  SubWindowSpec,
} from '../../common/SubWindow';
import { MUTED_TEXT, TEXT } from '../../common/Theme';

const TAG: string = 'im_advanced_settings';
const DOMAIN: number = 0x0100;

/** 窗口名 —— 用 XAML 的类名，window.findWindow 也用它。 */
export const WINDOW_NAME: string = 'AdvancedSettingsWindow';
/** 页面路径（要同时登记到 resources/base/profile/main_pages.json）。 */
export const PAGE_PATH: string = 'pages/windows/AdvancedSettingsWindow';

/** 原版构造函数 (uint width, uint height, bool previewOnly) 的入参键。 */
export const ARG_KEY_WIDTH: string = 'im.advancedSettings.initWidth';
export const ARG_KEY_HEIGHT: string = 'im.advancedSettings.initHeight';
export const ARG_KEY_PREVIEW_ONLY: string = 'im.advancedSettings.previewOnly';

/** 原版三个结果字段（DialogResult 的替代通道）。 */
export const RESULT_KEY_WIDTH: string = 'im.advancedSettings.requestedWidth';
export const RESULT_KEY_HEIGHT: string = 'im.advancedSettings.requestedHeight';
export const RESULT_KEY_DISABLE: string = 'im.advancedSettings.disableRequested';

/** 原版构造函数的参数（width / height / previewOnly）。 */
export interface AdvancedSettingsArgs {
  width: number;
  height: number;
  previewOnly: boolean;
}

/** 按原版打开这个子窗口：先把构造参数放进 AppStorage，再开窗。 */
export function open_advanced_settings(ctx: common.Context, args: AdvancedSettingsArgs): void {
  AppStorage.setOrCreate<number>(ARG_KEY_WIDTH, args.width);
  AppStorage.setOrCreate<number>(ARG_KEY_HEIGHT, args.height);
  AppStorage.setOrCreate<boolean>(ARG_KEY_PREVIEW_ONLY, args.previewOnly);

  const spec: SubWindowSpec = {
    name: WINDOW_NAME,
    page: PAGE_PATH,
    title: '高级 USB 设置',        // Strings: AdvancedSettingsTitle
    width: 520,
    height: 450,
    resizable: false,               // ResizeMode="NoResize"
    minWidth: 520,
    minHeight: 450,
    modal: true,                    // WindowStartupLocation="CenterOwner" 的对话框
  };
  SubWindowHost.open(ctx, spec).catch((error: BusinessError): void => {
    hilog.error(DOMAIN, TAG, '打开失败: %{public}s', error.message);
  });
}

// 校验边界（xaml.cs: width < 16 || height < 16 || width > 8192 || height > 8192）
const MIN_SIDE: number = 16;
const MAX_SIDE: number = 8192;

@Entry
@Component
struct AdvancedSettingsWindow {
  // 原版：WidthBox.Text = width == 0 ? "" : width.ToString()（高度同理）
  @State widthText: string = '';
  @State heightText: string = '';
  @State errorText: string = '';

  aboutToAppear(): void {
    const initWidth: number = AppStorage.get<number>(ARG_KEY_WIDTH) ?? 0;
    const initHeight: number = AppStorage.get<number>(ARG_KEY_HEIGHT) ?? 0;
    this.widthText = initWidth === 0 ? '' : initWidth.toString();
    this.heightText = initHeight === 0 ? '' : initHeight.toString();
  }

  /** xaml.cs OnApplyClick —— 通过则回传两个尺寸并关窗，否则只显示红字。 */
  private on_apply(): void {
    const width: number = Number.parseInt(this.widthText.trim(), 10);
    const height: number = Number.parseInt(this.heightText.trim(), 10);
    const bad: boolean = Number.isNaN(width) || Number.isNaN(height)
      || width < MIN_SIDE || height < MIN_SIDE
      || width > MAX_SIDE || height > MAX_SIDE;
    if (bad) {
      // Strings: AdvancedResolutionInvalid
      this.errorText = '请输入 16–8192 范围内的有效宽度和高度。';
      return;
    }
    AppStorage.setOrCreate<number>(RESULT_KEY_WIDTH, width);
    AppStorage.setOrCreate<number>(RESULT_KEY_HEIGHT, height);
    AppStorage.setOrCreate<boolean>(RESULT_KEY_DISABLE, false);
    SubWindowHost.close(WINDOW_NAME);
  }

  /** xaml.cs OnDisableClick —— DisableAdvancedModeRequested = true; Complete(false)。 */
  private on_disable(): void {
    AppStorage.setOrCreate<boolean>(RESULT_KEY_DISABLE, true);
    SubWindowHost.close(WINDOW_NAME);
  }

  /** Border Style=SettingsSection 里的内容。 */
  @Builder
  card_body() {
    Column() {
      // TextBlock AdvancedUsbResolution（隐式 TextBlock 无 FontSize → WPF 默认 12）
      Text('USB 请求分辨率')
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT)
        .width('100%');
      // TextBlock AdvancedUsbResolutionHelp：Muted 11 Wrap, Margin 0,6,0,12
      Text('输入例如 1920×1080。应用后将忽略普通画面预设；关闭高级模式后恢复普通预设。')
        .fontSize(11)
        .fontColor(MUTED_TEXT)
        .width('100%')
        .margin({ top: 6, bottom: 12 });

      // Grid Margin="0,5,0,0"，三列 = * / 18 / *
      Row() {
        Column() {
          field_label('高度');
          RoundedTextBox({
            text: this.heightText,
            fontSize: 16,
            boxHeight: 54,
            on_text_change: (value: string): void => { this.heightText = value; },
          })
            .margin({ top: 5 });
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);

        // TextBlock "×"：Muted / 水平居中 / 底对齐 / Margin 0,0,0,10
        Text('×')
          .fontSize(12)
          .fontColor(MUTED_TEXT)
          .textAlign(TextAlign.Center)
          .width(18)
          .margin({ bottom: 10 });

        Column() {
          field_label('宽度');
          RoundedTextBox({
            text: this.widthText,
            fontSize: 16,
            boxHeight: 54,
            on_text_change: (value: string): void => { this.widthText = value; },
          })
            .margin({ top: 5 });
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .margin({ top: 5 });

      // TextBlock ErrorText：ErrorBrush 11 Wrap, Margin 0,10,0,0
      if (this.errorText.length > 0) {
        Column() {
          error_text(this.errorText);
        }
        .width('100%')
        .margin({ top: 10 });
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%');
  }

  @Builder
  body() {
    SettingsSection({ content: (): void => { this.card_body(); } });
  }

  @Builder
  actions() {
    SecondaryButton({
      label: '关闭高级模式',
      buttonWidth: 150,
      buttonHeight: 40,
      on_action: (): void => { this.on_disable(); },
    });
    PrimaryButton({
      label: '应用',
      buttonWidth: 112,
      buttonHeight: 40,
      on_action: (): void => { this.on_apply(); },
    });
  }

  build() {
    Column() {
      SubWindowShell({
      windowName: WINDOW_NAME,
      title: '高级 USB 设置',
      subtitle: '此设置仅作用于当前选中的设备，并直接写入 QuickTime USB 分辨率请求。',
      gap: SUBWINDOW_ROW_GAP,
      actionsSplit: true,   // 左「关闭高级模式」+ 右「应用」
      content: (): void => { this.body(); },
      actions: (): void => { this.actions(); },
    });
    }
  }
}
