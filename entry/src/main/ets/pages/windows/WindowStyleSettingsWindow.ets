// WindowStyleSettingsWindow.ets —— 子窗口：独立窗口风格（透明度 + 悬停不透明）
//
// 逐项对照上游 src/App/Windows/WindowStyleSettingsWindow.xaml（63 行）
//              src/App/Windows/WindowStyleSettingsWindow.xaml.cs
//
// ── 平台替换（必须逐条列明）──────────────────────────────────────────────────
//   1. 【作用于哪个窗口】上游的「独立窗口」是 WPF 独立顶层窗（NativePreviewWindow
//      那一支）。本移植里等价物是 StandalonePreviewWindow —— 但它已经改成了独立的
//      StandalonePreviewAbility 主窗口（主窗口最小化也不影响它）。透明度经由
//      window.Window.setWindowOpacity 施加在该 Ability 的 MainWindow 上，键从
//      AppPreferences 走 AppStorage 共享给独立 Ability。
//   2. 【滑块 10–100%】原版 Slider Minimum=10 Maximum=100 Value=100，OnOpacityChanged
//      写入偏好并实时套用。本窗口用 ArkUI Slider，onChange 即存即生效
//      （独立窗口侧用 @StorageLink + @Watch 实时重设不透明度）。
//   3. 【悬停变不透明】原版 OpaqueOnHoverCheckBox：透明度 < 100% 时，鼠标移到窗口上
//      临时全不透明，移开恢复。本窗口只管存开关；真正的「悬停覆盖」由
//      StandalonePreviewWindow 的 .onHover 实现（指针在窗口内时 setWindowOpacity(1.0)，
//      移开回到设定值）。
//   4. 【重置】原版把透明度与悬停开关都还原默认（100% / 关）。本窗口同样做。
//   5. 【FeedbackText / 错误反馈】上游在非法值时给红色提示。本移植透明度是受控滑块
//      （已夹在 10–100），不会越界，故省略错误反馈，只保留重置/关闭。
//
// ── 与偏好的关系 ─────────────────────────────────────────────────────────────
//   偏好落在 AppPreferences：independent_window_opacity（10..100，默认 100）与
//   independent_window_opaque_on_hover（默认 false），各带 load/save 成对。
//   保存时同步写 AppStorage，独立预览窗口侧 @Watch 立即重设；持久化走 preferences。

import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  SubWindowShell, SubWindowHost, SecondaryButton, PrimaryButton,
  SUBWINDOW_ROW_GAP, SubWindowSpec,
} from '../../common/SubWindow';
import {
  ACCENT, DARK, CARD, RADIUS_CARD,
} from '../../common/Theme';
import {
  INDEPENDENT_OPACITY_KEY, INDEPENDENT_OPAQUE_ON_HOVER_KEY,
  INDEPENDENT_OPACITY_MIN, INDEPENDENT_OPACITY_MAX,
  save_independent_window_opacity, save_independent_window_opaque_on_hover,
} from '../../common/AppPreferences';
import { t } from '../../common/i18n';

const TAG: string = 'im_window_style';
const DOMAIN: number = 0x0100;

/** 窗口名 —— 用 XAML 的类名，window.findWindow 也用它。 */
export const WINDOW_NAME: string = 'WindowStyleSettingsWindow';
/** 页面路径。 */
export const PAGE_PATH: string = 'pages/windows/WindowStyleSettingsWindow';

/** 按原版打开这个子窗口。 */
export function open_window_style(ctx: common.Context): void {
  const spec: SubWindowSpec = {
    name: WINDOW_NAME,
    page: PAGE_PATH,
    title: t('独立窗口风格'),
    width: 482,
    height: 462,
    resizable: true,                // ResizeMode=CanResize 等价
    minWidth: 422,
    minHeight: 422,
    modal: false,                  // CenterOwner 等价（非模态设置窗）
  };
  // ★ .catch 里不允许再抛异常：拒绝回调里的 undefined 取 .message 会二次抛错、
  //   被运行时当成未捕获异常结束应用（与 open_about / open_first_run 同律）。
  SubWindowHost.open(ctx, spec).catch((error: BusinessError): void => {
    const reason: string = error !== undefined && error !== null && error.message !== undefined
      ? error.message : '未知原因';
    hilog.error(DOMAIN, TAG, '打开窗口风格设置失败: %{public}s', reason);
  });
}

@Entry
@Component
struct WindowStyleSettingsWindow {
  /** 独立窗口透明度（百分比 10..100），直连 AppStorage（独立窗口侧 @Watch 生效）。 */
  // ★ 成员不能命名成 opacity：CustomComponent 基类自带 opacity 属性方法，同名字段会被判为
  //   覆盖且类型不兼容（number 不能赋给属性方法）⇒ 编译报错。故加 Pct 后缀。
  @StorageLink(INDEPENDENT_OPACITY_KEY) opacityPct: number = INDEPENDENT_OPACITY_MAX;
  /** 悬停变全不透明开关。 */
  @StorageLink(INDEPENDENT_OPAQUE_ON_HOVER_KEY) opaqueOnHover: boolean = false;

  /**
   * 存透明度。@StorageLink 已把新值写进 AppStorage（独立窗口会 @Watch 到），
   * 这里额外落盘到 preferences，关窗后下次启动仍保留。
   */
  private on_opacity_change(value: number): void {
    try {
      save_independent_window_opacity(value);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '保存透明度失败: %{public}s', (error as BusinessError).message);
    }
  }

  /** 存悬停开关（同上，写 AppStorage + 落盘）。 */
  private on_hover_change(checked: boolean): void {
    try {
      save_independent_window_opaque_on_hover(checked);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '保存悬停开关失败: %{public}s', (error as BusinessError).message);
    }
  }

  /** 重置：透明度 100%、悬停关闭。 */
  private reset_all(): void {
    this.opacityPct = INDEPENDENT_OPACITY_MAX;
    this.opaqueOnHover = false;
    this.on_opacity_change(INDEPENDENT_OPACITY_MAX);
    this.on_hover_change(false);
  }

  // ── 透明度卡片 ──
  @Builder
  opacity_card() {
    Column() {
      Row() {
        Text(t('窗口透明度'))
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(DARK.TEXT)
          .layoutWeight(1);
        Text(`${this.opacityPct}%`)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(ACCENT);
      }
      .width('100%')
      .margin({ bottom: 12 });

      Slider({
        value: this.opacityPct,
        min: INDEPENDENT_OPACITY_MIN,
        max: INDEPENDENT_OPACITY_MAX,
        step: 1,
      })
        .width('100%')
        .onChange((value: number): void => {
          this.opacityPct = value;
          this.on_opacity_change(value);
        });

      Text(t('降低透明度可让桌面透出，便于边看投屏边处理其它窗口。'))
        .fontSize(11)
        .fontColor(DARK.MUTED_TEXT)
        .width('100%')
        .lineHeight(16)
        .margin({ top: 10 });
    }
    .width('100%')
    .padding(18)
    .borderRadius(RADIUS_CARD)
    .backgroundColor(CARD)
    .border({ width: 1, color: DARK.BORDER })
    .margin({ bottom: 14 });
  }

  // ── 悬停变不透明卡片 ──
  @Builder
  hover_card() {
    Column() {
      Toggle({ type: ToggleType.Switch, isOn: this.opaqueOnHover })
        .onChange((checked: boolean): void => {
          this.opaqueOnHover = checked;
          this.on_hover_change(checked);
        });
      Text(t('鼠标移到窗口上时暂时恢复全不透明，移开后再回到设定值。'))
        .fontSize(11)
        .fontColor(DARK.MUTED_TEXT)
        .width('100%')
        .lineHeight(16)
        .margin({ top: 8 });
    }
    .width('100%')
    .padding(18)
    .borderRadius(RADIUS_CARD)
    .backgroundColor(CARD)
    .border({ width: 1, color: DARK.BORDER });
  }

  /** 内容区。 */
  @Builder
  content() {
    Column() {
      this.opacity_card();
      this.hover_card();
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start);
  }

  /** 底部按钮条：重置（左）+ 关闭（右）。 */
  @Builder
  actions() {
    Row() {
      SecondaryButton({
        label: t('重置'),
        minButtonWidth: 96,
        on_action: (): void => { this.reset_all(); },
      });
      Row() {
        PrimaryButton({
          label: t('关闭'),
          minButtonWidth: 96,
          on_action: (): void => { SubWindowHost.close(WINDOW_NAME); },
        });
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.End);
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Center);
  }

  build() {
    Column() {
      SubWindowShell({
        windowName: WINDOW_NAME,
        title: t('独立窗口风格'),
        subtitle: t('调整独立预览窗口的透明度与悬停行为。'),
        gap: SUBWINDOW_ROW_GAP,
        hasNotice: false,
        hasFooter: false,
        hasActions: true,
        content: (): void => { this.content(); },
        actions: (): void => { this.actions(); },
      });
    }
  }
}
