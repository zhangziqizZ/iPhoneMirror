// ImageSettingsWindow.ets —— 子窗口 2/20：画面调节
//
// 逐项对照上游 src/App/Windows/ImageSettingsWindow.xaml（129 行）
//              src/App/Windows/ImageSettingsWindow.xaml.cs（147 行）
//
// ── 窗口属性（XAML 根元素 <ui:FluentWindow>）────────────────────────────────
//   Title="{DynamicResource MoreImageSettingsTitle}"  → 「画面调节」
//   Width="560" Height="650" MinWidth="520" MinHeight="600"
//   WindowStartupLocation="CenterOwner"  → SubWindowHost.open 里算居中
//   ResizeMode="CanResize"               → resizable: true
//   ExtendsContentIntoTitleBar="True"    → decorEnabled: false + 自绘表头
//   PreviewKeyDown="OnPreviewKeyDown"    → Esc 关窗（见下面 KEYCODE_ESCAPE）
//   Closing="OnWindowClosing"            → SubWindowHost.register_close_hook
//   Background="{DynamicResource AppBackgroundBrush}" → shell 默认底色
//
// ── 行定义（Grid.RowDefinitions，7 行）──────────────────────────────────────
//   Row Auto : SubWindowHeader（标题「画面调节」+ 副标题）
//   Row 16   : 间隔
//   Row Auto : 提示条（WarningSurface / WarningBrush / 圆角 12 / Padding 14,11）
//   Row 12   : 间隔
//   Row *    : Border Style=SettingsSection Padding="20,16"  ← 四个滑杆
//   Row Auto : FeedbackText（WarningBrush 11 Wrap, Margin 0,8,0,10）
//   Row Auto : 按钮行 Grid（Auto / * / Auto / 10 / Auto）
//
// ── 四个滑杆（值域照搬，一个不改）──────────────────────────────────────────
//   亮度  Brightness  Minimum=-100 Maximum=100  TickFrequency=1  IsSnapToTickEnabled
//   对比度 Contrast   Minimum=0    Maximum=200
//   饱和度 Saturation Minimum=0    Maximum=200
//   伽马   Gamma      Minimum=50   Maximum=200
//   滑块样式来自 App.xaml 第 444–520 行的隐式 Slider 样式（见 Theme.ets）
//
// ── xaml.cs 的行为（逐条复刻）──────────────────────────────────────────────
//   · 构造时 Math.Clamp 四个初值后写进滑杆
//   · 值变化 → 33ms 防抖 → Apply(_preview, Values)（对应 _previewTimer）
//   · OnSaveClick：停表 → Apply(_save) 成功才 _saved=true、_dirty=false、Close()
//   · OnResetClick：四个值回到 (0, 100, 100, 100)
//   · OnBackClick / Esc：Close() —— 会先过 OnWindowClosing
//   · OnWindowClosing：停表；_saved 或 _skipRevertOnClose 则放行；
//                      否则 Apply(_revert, _originalValues)，失败则 e.Cancel = true
//   · SetEditingEnabled(bool)：滑块面板与两个按钮一起禁用；禁用时停表，
//                              启用时若 _dirty 就补一次 preview
//   · CloseForShutdown / CloseForSessionInvalidation：置 _skipRevertOnClose 后关窗
//
// ── 唯一一处平台替换 ───────────────────────────────────────────────────────
//   原版三个委托（preview / save / revert）由调用方通过构造函数注入；鸿蒙子窗口
//   没有这个通道，改为 WindowServices 注册表（见 common/WindowServices.ets）。
//   委托的返回语义 (bool Success, string Message) 一比一保留。

import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KeyCode } from '@ohos.multimodalInput.keyCode';
import {
  SubWindowShell, SubWindowHost, SecondaryButton, PrimaryButton, SettingsSection,
  NoticeBanner,
  SUBWINDOW_ROW_GAP,
  SubWindowSpec,
} from '../../common/SubWindow';
import {
  TEXT, MUTED_TEXT, BORDER_SOFT, WARNING, ACCENT,
  SLIDER_TRACK, SLIDER_TRACK_THICKNESS, SLIDER_THUMB_FILL, SLIDER_THUMB_BORDER,
  SLIDER_THUMB_HOVER, SLIDER_THUMB_SIZE, SLIDER_THUMB_STROKE,
  BUTTON_MIN_HEIGHT, DISABLED_OPACITY,
} from '../../common/Theme';
import {
  WindowServices, ImageAdjustmentValues, ImageAdjustmentResult, ImageSettingsHandle,
} from '../../common/WindowServices';

const TAG: string = 'im_image_settings';
const DOMAIN: number = 0x0100;

export const WINDOW_NAME: string = 'ImageSettingsWindow';
export const PAGE_PATH: string = 'pages/windows/ImageSettingsWindow';

/** 原版构造函数 ImageAdjustmentValues originalValues 的四个入参键。 */
export const ARG_KEY_BRIGHTNESS: string = 'im.imageSettings.brightness';
export const ARG_KEY_CONTRAST: string = 'im.imageSettings.contrast';
export const ARG_KEY_SATURATION: string = 'im.imageSettings.saturation';
export const ARG_KEY_GAMMA: string = 'im.imageSettings.gamma';

/** 原版构造函数第一个参数。 */
export interface ImageSettingsArgs {
  brightness: number;
  contrast: number;
  saturation: number;
  gamma: number;
}

/** 原版 ImageSettingsWindow 的默认值：Reset 后的四个值，也是开发者预览的初值。 */
export const DEFAULT_BRIGHTNESS: number = 0;
export const DEFAULT_CONTRAST: number = 100;
export const DEFAULT_SATURATION: number = 100;
export const DEFAULT_GAMMA: number = 100;

/** 原版 _previewTimer.Interval = TimeSpan.FromMilliseconds(33)。 */
const PREVIEW_DEBOUNCE_MS: number = 33;

/** Esc 键码。取值出处：SDK ets/api/@ohos.multimodalInput.keyCode.d.ts（KEYCODE_ESCAPE = 2070）。 */
const ESCAPE_KEY: number = KeyCode.KEYCODE_ESCAPE;

function clamp(value: number, low: number, high: number): number {
  if (value < low) {
    return low;
  }
  if (value > high) {
    return high;
  }
  return value;
}

/** 按原版打开这个子窗口：先把构造参数放进 AppStorage，再开窗。 */
export function open_image_settings(ctx: common.Context, args: ImageSettingsArgs): void {
  AppStorage.setOrCreate<number>(ARG_KEY_BRIGHTNESS, args.brightness);
  AppStorage.setOrCreate<number>(ARG_KEY_CONTRAST, args.contrast);
  AppStorage.setOrCreate<number>(ARG_KEY_SATURATION, args.saturation);
  AppStorage.setOrCreate<number>(ARG_KEY_GAMMA, args.gamma);

  // 原版 ShowDeveloperPreview 传的是 (0, 100, 100, 100)。
  const spec: SubWindowSpec = {
    name: WINDOW_NAME,
    page: PAGE_PATH,
    title: '画面调节',              // Strings: MoreImageSettingsTitle
    width: 560,
    height: 650,
    resizable: true,                // ResizeMode="CanResize"
    minWidth: 520,
    minHeight: 600,
    modal: false,                   // 原版是 Show()，不是 ShowDialog()
  };
  SubWindowHost.open(ctx, spec).catch((error: BusinessError): void => {
    hilog.error(DOMAIN, TAG, '打开失败: %{public}s', error.message);
  });
}

/** 原版 ShowDeveloperPreview(Window owner)：用默认值直接开，不接主窗口的委托。 */
export function open_image_settings_preview(ctx: common.Context): void {
  open_image_settings(ctx, {
    brightness: DEFAULT_BRIGHTNESS,
    contrast: DEFAULT_CONTRAST,
    saturation: DEFAULT_SATURATION,
    gamma: DEFAULT_GAMMA,
  });
}

@Entry
@Component
struct ImageSettingsWindow {
  // 四个滑杆的当前值（原版 BrightnessSlider.Value 等）
  @State brightnessValue: number = DEFAULT_BRIGHTNESS;
  @State contrastValue: number = DEFAULT_CONTRAST;
  @State saturation: number = DEFAULT_SATURATION;
  @State gamma: number = DEFAULT_GAMMA;

  @State feedbackText: string = '';
  @State editingEnabled: boolean = true;

  // 原版：Thumb 在 IsMouseOver / IsDragging 下的填充色不同
  @State brightHover: boolean = false;
  @State brightDrag: boolean = false;
  @State contrastHover: boolean = false;
  @State contrastDrag: boolean = false;
  @State saturationHover: boolean = false;
  @State saturationDrag: boolean = false;
  @State gammaHover: boolean = false;
  @State gammaDrag: boolean = false;

  /** 原版 _originalValues（用于关闭时回滚）。 */
  private originalValues: ImageAdjustmentValues =
    { brightness: DEFAULT_BRIGHTNESS, contrast: DEFAULT_CONTRAST,
      saturation: DEFAULT_SATURATION, gamma: DEFAULT_GAMMA };

  /** 原版 _ready：构造期间的值变化不触发预览。 */
  private ready: boolean = false;
  /** 原版 _saved：保存过就不在关闭时回滚。 */
  private saved: boolean = false;
  /** 原版 _skipRevertOnClose：退出/会话失效路径关闭时不回滚。 */
  private skipRevertOnClose: boolean = false;
  /** 原版 _dirty：SetEditingEnabled(true) 时用来决定要不要补一次预览。 */
  private dirty: boolean = false;
  /** 原版 _previewTimer。<= 0 表示没有在等。 */
  private previewTimer: number = -1;

  /** 原版：this 作为窗口句柄暴露给主窗口（主窗口调用 SetEditingEnabled 等）。 */
  private handle: ImageSettingsHandle = new ImageSettingsHandle(
    (enabled: boolean): void => { this.set_editing_enabled(enabled); },
    (): void => { this.close_for_shutdown(); },
    (): void => { this.close_for_session_invalidation(); },
  );

  aboutToAppear(): void {
    const initBrightness: number =
      AppStorage.get<number>(ARG_KEY_BRIGHTNESS) ?? DEFAULT_BRIGHTNESS;
    const initContrast: number =
      AppStorage.get<number>(ARG_KEY_CONTRAST) ?? DEFAULT_CONTRAST;
    const initSaturation: number =
      AppStorage.get<number>(ARG_KEY_SATURATION) ?? DEFAULT_SATURATION;
    const initGamma: number = AppStorage.get<number>(ARG_KEY_GAMMA) ?? DEFAULT_GAMMA;

    // 原版：Math.Clamp(originalValues.X, min, max) 后写进滑杆
    this.originalValues = {
      brightness: clamp(initBrightness, -100, 100),
      contrast: clamp(initContrast, 0, 200),
      saturation: clamp(initSaturation, 0, 200),
      gamma: clamp(initGamma, 50, 200),
    };
    this.brightnessValue = this.originalValues.brightness;
    this.contrastValue = this.originalValues.contrast;
    this.saturation = this.originalValues.saturation;
    this.gamma = this.originalValues.gamma;

    this.ready = true;
    WindowServices.image_window = this.handle;
    SubWindowHost.register_close_hook(WINDOW_NAME, (): boolean => this.on_close_request());
    hilog.info(DOMAIN, TAG, '画面调节窗口就绪');
  }

  aboutToDisappear(): void {
    this.stop_preview_timer();
    SubWindowHost.unregister_close_hook(WINDOW_NAME);
    WindowServices.image_window = null;
  }

  // ───────────────────────── xaml.cs 的行为 ─────────────────────────

  /** 原版 Values => new(Brightness, Contrast, Saturation, Gamma)。 */
  private values(): ImageAdjustmentValues {
    return {
      brightness: this.brightnessValue,
      contrast: this.contrastValue,
      saturation: this.saturation,
      gamma: this.gamma,
    };
  }

  /**
   * 原版 Apply(action, values)：
   *   FeedbackText.Text = result.Success ? "" : result.Message;
   *   return result.Success;
   */
  private apply(action: (values: ImageAdjustmentValues) => ImageAdjustmentResult): boolean {
    const result: ImageAdjustmentResult = action(this.values());
    this.feedbackText = result.success ? '' : result.message;
    return result.success;
  }

  private stop_preview_timer(): void {
    if (this.previewTimer >= 0) {
      clearTimeout(this.previewTimer);
      this.previewTimer = -1;
    }
  }

  /** 原版 OnAdjustmentValueChanged：_dirty = true; 计时器 Stop + Start。 */
  private schedule_preview(): void {
    if (!this.ready) {
      return;
    }
    this.dirty = true;
    this.stop_preview_timer();
    this.previewTimer = setTimeout((): void => {
      this.previewTimer = -1;
      // 原版 OnPreviewTimerTick：停表后 Apply(_preview, Values)
      this.apply((values: ImageAdjustmentValues): ImageAdjustmentResult =>
        WindowServices.apply_image_preview(values));
    }, PREVIEW_DEBOUNCE_MS);
  }

  /** 原版 OnResetClick：四个值回到 (0, 100, 100, 100)。 */
  private on_reset(): void {
    this.brightnessValue = DEFAULT_BRIGHTNESS;
    this.contrastValue = DEFAULT_CONTRAST;
    this.saturation = DEFAULT_SATURATION;
    this.gamma = DEFAULT_GAMMA;
  }

  /** 原版 OnSaveClick。 */
  private on_save(): void {
    this.stop_preview_timer();
    if (!this.apply((values: ImageAdjustmentValues): ImageAdjustmentResult =>
      WindowServices.apply_image_save(values))) {
      return;
    }
    this.saved = true;
    this.dirty = false;
    SubWindowHost.close(WINDOW_NAME);
  }

  /** 原版 OnBackClick / OnPreviewKeyDown（Esc）。 */
  private on_back(): void {
    SubWindowHost.close(WINDOW_NAME);
  }

  /**
   * 原版 OnWindowClosing。返回 false 等价于 e.Cancel = true。
   * 注意：这个钩子由 SubWindowHost.close 在销毁前调用。
   */
  private on_close_request(): boolean {
    this.stop_preview_timer();
    if (this.saved || this.skipRevertOnClose) {
      return true;
    }
    if (this.apply((values: ImageAdjustmentValues): ImageAdjustmentResult =>
      WindowServices.apply_image_revert(this.originalValues))) {
      return true;
    }
    // 回滚失败：保持窗口打开，让用户重试或改为保存（原版注释同此意）。
    return false;
  }

  /** 原版 SetEditingEnabled(bool)。 */
  private set_editing_enabled(enabled: boolean): void {
    this.editingEnabled = enabled;
    if (!enabled) {
      this.stop_preview_timer();
      return;
    }
    if (this.dirty) {
      this.apply((values: ImageAdjustmentValues): ImageAdjustmentResult =>
        WindowServices.apply_image_preview(values));
    }
  }

  /** 原版 CloseForShutdown()。 */
  private close_for_shutdown(): void {
    this.skipRevertOnClose = true;
    SubWindowHost.close(WINDOW_NAME);
  }

  /** 原版 CloseForSessionInvalidation()。 */
  private close_for_session_invalidation(): void {
    this.skipRevertOnClose = true;
    SubWindowHost.close(WINDOW_NAME);
  }

  // ───────────────────────── 界面 ─────────────────────────

  /** AdjustmentLabel：TextBrush / 13 / SemiBold / VCenter。 */
  @Builder
  adjustment_label(text: string) {
    Text(text)
      .fontSize(13)
      .fontWeight(FontWeight.Bold)
      .fontColor(TEXT)
      .width('100%');
  }

  // AdjustmentValue（MutedTextBrush / 12 / 右对齐 / VCenter）已改为**内联 Text**，
  // 四个调用点各自展开。原因见上面第一处的注释：@Builder 按值传参不参与动态刷新。

  /** 四个滑杆之间那根 1px 分隔线：Height 1 / BorderSoftBrush / Margin 0,16。 */
  @Builder
  divider() {
    Column()
      .width('100%')
      .height(1)
      .backgroundColor(BORDER_SOFT)
      .margin({ top: 16, bottom: 16 });
  }

  @Builder
  card_body() {
    Column() {
      // ── 亮度：-100 … 100 ──
      Stack({ alignContent: Alignment.Start }) {
        this.adjustment_label('亮度');
        Row() {
          // ⚠️ 必须内联：adjustment_value 是按值传参的 @Builder，状态变量改变
          //    不会引起它内部的 UI 刷新 —— 滑杆拖动后这里的数字会不动。
          Text(Math.round(this.brightnessValue).toString())
            .fontSize(12)
            .fontColor(MUTED_TEXT)
            .textAlign(TextAlign.End)
            .width('100%');
        }
        .width('100%')
        .justifyContent(FlexAlign.End);
      }
      .width('100%');

      Slider({
        value: this.brightnessValue,
        min: -100,
        max: 100,
        step: 1,
        style: SliderStyle.OutSet,
      })
        .width('100%')
        .height(20)
        .trackThickness(SLIDER_TRACK_THICKNESS)
        .trackColor(SLIDER_TRACK)
        .selectedColor(ACCENT)
        .blockColor(this.brightDrag ? ACCENT
          : (this.brightHover ? SLIDER_THUMB_HOVER : SLIDER_THUMB_FILL))
        .blockBorderColor(SLIDER_THUMB_BORDER)
        .blockBorderWidth(SLIDER_THUMB_STROKE)
        .margin({ top: 8 })
        .enabled(this.editingEnabled)
        .opacity(this.editingEnabled ? 1 : 0.4)
        .onHover((isHover: boolean): void => { this.brightHover = isHover; })
        .onChange((value: number, mode: SliderChangeMode): void => {
          this.brightDrag = mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving;
          this.brightnessValue = value;
          this.schedule_preview();
        });

      this.divider();

      // ── 对比度：0 … 200 ──
      Stack({ alignContent: Alignment.Start }) {
        this.adjustment_label('对比度');
        Row() {
          // ⚠️ 必须内联：adjustment_value 是按值传参的 @Builder，状态变量改变
          //    不会引起它内部的 UI 刷新 —— 滑杆拖动后这里的数字会不动。
          Text(Math.round(this.contrastValue).toString() + '%')
            .fontSize(12)
            .fontColor(MUTED_TEXT)
            .textAlign(TextAlign.End)
            .width('100%');
        }
        .width('100%')
        .justifyContent(FlexAlign.End);
      }
      .width('100%');

      Slider({
        value: this.contrastValue,
        min: 0,
        max: 200,
        step: 1,
        style: SliderStyle.OutSet,
      })
        .width('100%')
        .height(20)
        .trackThickness(SLIDER_TRACK_THICKNESS)
        .trackColor(SLIDER_TRACK)
        .selectedColor(ACCENT)
        .blockColor(this.contrastDrag ? ACCENT
          : (this.contrastHover ? SLIDER_THUMB_HOVER : SLIDER_THUMB_FILL))
        .blockBorderColor(SLIDER_THUMB_BORDER)
        .blockBorderWidth(SLIDER_THUMB_STROKE)
        .margin({ top: 8 })
        .enabled(this.editingEnabled)
        .opacity(this.editingEnabled ? 1 : 0.4)
        .onHover((isHover: boolean): void => { this.contrastHover = isHover; })
        .onChange((value: number, mode: SliderChangeMode): void => {
          this.contrastDrag = mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving;
          this.contrastValue = value;
          this.schedule_preview();
        });

      this.divider();

      // ── 饱和度：0 … 200 ──
      Stack({ alignContent: Alignment.Start }) {
        this.adjustment_label('饱和度');
        Row() {
          // ⚠️ 必须内联：adjustment_value 是按值传参的 @Builder，状态变量改变
          //    不会引起它内部的 UI 刷新 —— 滑杆拖动后这里的数字会不动。
          Text(Math.round(this.saturation).toString() + '%')
            .fontSize(12)
            .fontColor(MUTED_TEXT)
            .textAlign(TextAlign.End)
            .width('100%');
        }
        .width('100%')
        .justifyContent(FlexAlign.End);
      }
      .width('100%');

      Slider({
        value: this.saturation,
        min: 0,
        max: 200,
        step: 1,
        style: SliderStyle.OutSet,
      })
        .width('100%')
        .height(20)
        .trackThickness(SLIDER_TRACK_THICKNESS)
        .trackColor(SLIDER_TRACK)
        .selectedColor(ACCENT)
        .blockColor(this.saturationDrag ? ACCENT
          : (this.saturationHover ? SLIDER_THUMB_HOVER : SLIDER_THUMB_FILL))
        .blockBorderColor(SLIDER_THUMB_BORDER)
        .blockBorderWidth(SLIDER_THUMB_STROKE)
        .margin({ top: 8 })
        .enabled(this.editingEnabled)
        .opacity(this.editingEnabled ? 1 : 0.4)
        .onHover((isHover: boolean): void => { this.saturationHover = isHover; })
        .onChange((value: number, mode: SliderChangeMode): void => {
          this.saturationDrag = mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving;
          this.saturation = value;
          this.schedule_preview();
        });

      this.divider();

      // ── 伽马：50 … 200 ──
      Stack({ alignContent: Alignment.Start }) {
        this.adjustment_label('伽马');
        Row() {
          // ⚠️ 必须内联：adjustment_value 是按值传参的 @Builder，状态变量改变
          //    不会引起它内部的 UI 刷新 —— 滑杆拖动后这里的数字会不动。
          Text(Math.round(this.gamma).toString() + '%')
            .fontSize(12)
            .fontColor(MUTED_TEXT)
            .textAlign(TextAlign.End)
            .width('100%');
        }
        .width('100%')
        .justifyContent(FlexAlign.End);
      }
      .width('100%');

      Slider({
        value: this.gamma,
        min: 50,
        max: 200,
        step: 1,
        style: SliderStyle.OutSet,
      })
        .width('100%')
        .height(20)
        .trackThickness(SLIDER_TRACK_THICKNESS)
        .trackColor(SLIDER_TRACK)
        .selectedColor(ACCENT)
        .blockColor(this.gammaDrag ? ACCENT
          : (this.gammaHover ? SLIDER_THUMB_HOVER : SLIDER_THUMB_FILL))
        .blockBorderColor(SLIDER_THUMB_BORDER)
        .blockBorderWidth(SLIDER_THUMB_STROKE)
        .margin({ top: 8 })
        .enabled(this.editingEnabled)
        .opacity(this.editingEnabled ? 1 : 0.4)
        .onHover((isHover: boolean): void => { this.gammaHover = isHover; })
        .onChange((value: number, mode: SliderChangeMode): void => {
          this.gammaDrag = mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving;
          this.gamma = value;
          this.schedule_preview();
        });
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%');
  }

  /** Row * ：SettingsSection Padding="20,16"，卡片撑满这一行。 */
  @Builder
  body() {
    Column() {
      SettingsSection({ padH: 20, padV: 16, content: (): void => { this.card_body(); } });
    }
    .width('100%')
    .layoutWeight(1);
  }

  /** 提示条（Row Auto）：WarningSurface / WarningBrush / 圆角 12 / Padding 14,11。 */
  @Builder
  notice() {
    NoticeBanner({
      noticeText: '仅对本地预览生效，无法应用到推流、虚拟摄像头、录屏或截图画面。',
      noticeTextColor: WARNING,
      surfaceColor: '#22FFC55C',
      bannerBorderColor: WARNING,
      bannerCorner: 12,
      padH: 14,
      padV: 11,
      noticeFontSize: 12,
      noticeLineHeight: 18,
    });
  }

  /**
   * 脚注（Row Auto）：FeedbackText。
   * 原版这个 TextBlock 无论有没有内容都占位（Margin 0,8,0,10），所以这里也一直渲染。
   */
  @Builder
  footer() {
    Text(this.feedbackText)
      .fontSize(11)
      .fontColor(WARNING)
      .width('100%')
      .margin({ top: 8, bottom: 10 });
  }

  /** 按钮行 Grid：Auto(重置) / *(空) / Auto(返回) / 10 / Auto(保存)。 */
  @Builder
  actions() {
    Row() {
      SecondaryButton({
        label: '重置',
        buttonWidth: 108,
        buttonHeight: BUTTON_MIN_HEIGHT,
        on_action: (): void => { this.on_reset(); },
      })
        .enabled(this.editingEnabled)
        .opacity(this.editingEnabled ? 1 : DISABLED_OPACITY);

      Column().layoutWeight(1);

      SecondaryButton({
        label: '返回',
        buttonWidth: 96,
        buttonHeight: BUTTON_MIN_HEIGHT,
        on_action: (): void => { this.on_back(); },
      });

      Row() {
        PrimaryButton({
          label: '保存',
          buttonWidth: 108,
          buttonHeight: BUTTON_MIN_HEIGHT,
          actionEnabled: this.editingEnabled,
          on_action: (): void => { this.on_save(); },
        });
      }
      .margin({ left: 10 });
    }
    .width('100%')
    .alignItems(VerticalAlign.Center);
  }

  build() {
    Column() {
      SubWindowShell({
        windowName: WINDOW_NAME,
        title: '画面调节',
        subtitle: '为当前设备微调本地预览画面。',
        gap: SUBWINDOW_ROW_GAP,       // 行 1 = 16
        hasNotice: true,              // 行 2 = 提示条
        noticeGap: 12,                // 行 3 = 12
        hasFooter: true,              // 行 5 = FeedbackText
        footerGap: 0,                 // 原版 FeedbackText 自带 Margin 0,8,0,10
        hasActions: true,
        actionGap: 0,                 // 原版按钮行紧贴 FeedbackText
        actionsSplit: false,
        notice: (): void => { this.notice(); },
        content: (): void => { this.body(); },
        footer: (): void => { this.footer(); },
        actions: (): void => { this.actions(); },
      });
    }
    .width('100%')
    .height('100%')
    // 原版 PreviewKeyDown="OnPreviewKeyDown"：Esc 关窗。
    .focusable(true)
    .defaultFocus(true)
    .onKeyEvent((event: KeyEvent): void => {
      if (event.type === KeyType.Down && event.keyCode === ESCAPE_KEY) {
        this.on_back();
      }
    });
  }
}
