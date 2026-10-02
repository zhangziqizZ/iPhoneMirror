// SubWindow.ets —— 子窗口共用外壳与开窗/关窗
//
// 数据源（逐条对应，值一个不改）：
//   src/SharedUI/Controls/ModernControls.xaml
//     · SubWindowPageRoot      Margin="24,20"
//     · SubWindowHeader        MinHeight="44"
//     · SubWindowTitle         TextBrush / FontSize 21 / SemiBold / Wrap / VCenter
//     · SubWindowSubtitle      MutedTextBrush / FontSize 12 / LineHeight 18 / Wrap / Margin="0,5,0,0"
//     · SubWindowSectionTitle  TextBrush / FontSize 14 / SemiBold
//     · SubWindowCloseButton   Width/Height/MinHeight 40 / FontSize 18 / 右上角 / ToolTip=Close
//     · TitleBarCloseButton    模板：圆角 8，hover 底色 DangerBrush + 文字 DangerButtonTextBrush
//     · ButtonSymbolIcon       图标前景继承 Button.Foreground
//     · SettingsSection        CardBrush 底 / 1px BorderBrush 边 / 圆角 16 / Padding 18
//   src/App/App.xaml
//     · 隐式 Button            圆角 11 / Padding 18,10 / MinHeight 42 / FontSize 14 / SemiBold
//                              hover ControlHoverBrush+ComboBorderHoverBrush；按下 ControlPressedBrush + 缩放 0.96
//     · PrimaryButton          圆角 12 / PrimaryAction* 一组色
//     · RoundedTextBox         圆角 10 / Padding 10,5 / MinHeight 40 / FontSize 12
//
// 原版 20 个子窗口的根元素都是 <ui:FluentWindow>，内容一律是
//   <Grid Style="{StaticResource SubWindowPageRoot}">，行结构固定为
//   Auto(表头) / 16 或 14 / 内容… / 14 / Auto(按钮条)
// 所以这里把外壳抽出来做一次，每个子窗口只填 content 与 actions。
//
// ★ 为什么按钮做成 @Component 而不是 @Builder：
//   ArkTS 的全局 @Builder 收「函数参数」（回调）支持情况不牢靠（本项目在 Index.ets
//   里已经栽过一次，改成了 action: string 标识 + 分发表）。所以凡是需要回调的
//   可复用件，一律用 @Component + 普通函数属性（赋值即回调），不用 @Builder。
//   纯样式复用走 @Styles，纯文本复用走 @Builder（只收字符串，安全）。
//
// 表头原版带 animations:WindowDragBehavior.IsEnabled="True"（整条表头可拖动窗口）。
// 鸿蒙侧等价物是 window.startMoving()。这里**故意只把拖动挂在标题块上、不挂整条表头**：
// 关闭按钮与标题块在同一个 Grid 单元里重叠，整条挂拖动会让点"关闭"时同时触发拖动。
// 标题块右侧本来就有 48px 让位（原版 Margin="0,0,48,0"），实际可拖区域与观感一致。

import window from '@ohos.window';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display } from '@kit.ArkUI';
import { FluentSymbol } from './FluentIcon';
import {
  APP_BACKGROUND, TEXT, MUTED_TEXT, CARD, BORDER, BORDER_SOFT,
  TEXT_SELECTION,
  CONTROL_FILL, CONTROL_HOVER, COMBO_BACKGROUND,
  ACCENT, ERROR, WARNING, WARNING_SURFACE,
  PRIMARY_ACTION, PRIMARY_ACTION_BORDER, PRIMARY_ACTION_TEXT,
  PRIMARY_ACTION_DISABLED, PRIMARY_ACTION_DISABLED_TEXT,
  DANGER, DANGER_BUTTON_TEXT,
  BUTTON_CORNER, BUTTON_PADDING_H, BUTTON_PADDING_V, BUTTON_MIN_HEIGHT, BUTTON_FONT_SIZE,
  PRIMARY_BUTTON_CORNER, DISABLED_OPACITY,
  SETTINGS_SECTION_CORNER, SETTINGS_SECTION_PADDING,
  TEXTBOX_CORNER, TEXTBOX_PADDING_H, TEXTBOX_PADDING_V, TEXTBOX_MIN_HEIGHT, TEXTBOX_FONT_SIZE,
  TEXTBOX_READONLY_OPACITY,
  DARK, LIGHT, ThemeColors,
} from './Theme';
import { THEME_SCHEME_KEY } from './theme_manager';
import { t } from './i18n';

const TAG: string = 'im_subwindow';
const DOMAIN: number = 0x0100;

// ───────────────────── 共享样式里的尺寸口径 ─────────────────────

/** SubWindowPageRoot: Margin="24,20" */
export const SUBWINDOW_PAGE_MARGIN_H: number = 24;
export const SUBWINDOW_PAGE_MARGIN_V: number = 20;
/** SubWindowHeader: MinHeight="44" */
export const SUBWINDOW_HEADER_MIN_HEIGHT: number = 44;
/** SubWindowTitle: FontSize 21 / SemiBold */
export const SUBWINDOW_TITLE_SIZE: number = 21;
/** SubWindowSubtitle: FontSize 12 / LineHeight 18 / Margin="0,5,0,0" */
export const SUBWINDOW_SUBTITLE_SIZE: number = 12;
export const SUBWINDOW_SUBTITLE_LINE_HEIGHT: number = 18;
export const SUBWINDOW_SUBTITLE_MARGIN_TOP: number = 5;
/** SubWindowSectionTitle: FontSize 14 / SemiBold */
export const SUBWINDOW_SECTION_TITLE_SIZE: number = 14;
/** 表头里标题块右侧让位 48（原版 Margin="0,0,48,0"） */
export const SUBWINDOW_HEADER_TEXT_END: number = 48;
/** SubWindowCloseButton: 40×40 / FontSize 18 / 圆角 8 */
export const SUBWINDOW_CLOSE_SIZE: number = 40;
export const SUBWINDOW_CLOSE_ICON_SIZE: number = 18;
export const SUBWINDOW_CLOSE_CORNER: number = 8;
/** 行间距：各子窗口的行定义里写 16 或 14 */
export const SUBWINDOW_ROW_GAP: number = 16;
export const SUBWINDOW_ROW_GAP_NARROW: number = 14;

// ───────────────────── 纯文本复用（@Builder，只收字符串，安全） ─────────────────────
//
// ⚠ @Styles / @Extend 是**文件作用域**的：在别的 .ets 里 import 过来用会在
//   CompileArkTS 报 `Property 'xxx' does not exist on type 'YyyAttribute'`。
//   要跨文件复用样式，只能包成 @Component（内容用 @BuilderParam 传进来）。
//   所以下面没有 @Styles，只有 @Component 与「只收字符串的 @Builder」。

/** SubWindowSectionTitle —— 卡片里的小标题。 */
@Builder
export function section_title(text: string) {
  Text(text)
    .fontSize(SUBWINDOW_SECTION_TITLE_SIZE)
    .fontWeight(FontWeight.Bold)
    .fontColor(TEXT);
}

/** 卡片内的说明文字（原版：MutedTextBrush / FontSize 11 / Wrap）。 */
@Builder
export function hint_text(text: string) {
  Text(text)
    .fontSize(11)
    .fontColor(MUTED_TEXT)
    .width('100%');
}

/** 字段标签（原版：MutedTextBrush / FontSize 11）。 */
@Builder
export function field_label(text: string) {
  Text(text)
    .fontSize(11)
    .fontColor(MUTED_TEXT);
}

// ───────────────────── 可复用控件（@Component + 函数属性传回调） ─────────────────────

/**
 * SettingsSection —— 子窗口里的设置卡片外壳。
 * 对应 ModernControls.xaml 的 `<Style x:Key="SettingsSection">`：
 *   CardBrush 底 / 1px BorderBrush 边 / 圆角 16 / Padding 18
 * 14 个子窗口都在用它包内容。少数窗口在用例处覆盖了 Padding
 * （如 ImageSettingsWindow 写 Padding="20,16"），所以留 padH/padV 两个口子。
 */
@Component
export struct SettingsSection {
  @Prop padH: number = SETTINGS_SECTION_PADDING;
  @Prop padV: number = SETTINGS_SECTION_PADDING;

  @Builder
  empty_slot() {}

  @BuilderParam content: () => void = this.empty_slot;

  build() {
    Column() {
      this.content();
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: this.padH, right: this.padH, top: this.padV, bottom: this.padV })
    .borderRadius(SETTINGS_SECTION_CORNER)
    .backgroundColor(CARD)
    .border({ width: 1, color: BORDER });
  }
}

/** 普通按钮 —— App.xaml 隐式 Button 样式（「关闭高级模式」「取消」等）。 */
@Component
export struct SecondaryButton {
  /**
   * ★ 配色必须自取主题（`@StorageLink` + 调色板），不能用模块级静态常量：
   *   `TEXT`/`CONTROL_FILL` 等是 **DarkTheme.xaml 的静态值**（近白文字 + 白 8% 底），
   *   浅色模式下画在浅色卡片上 ⇒ 白字白底、几乎看不见（用户 2026-10-02 截图：
   *   主窗「设置中心」一列按钮全部隐形）。主窗/子窗共用本组件，主题键在
   *   AppStorage 全局一份 ⇒ 这里自取即可与宿主页面同进退。
   */
  @StorageLink(THEME_SCHEME_KEY) scheme: string = 'dark';
  @Prop label: string = '';
  @Prop buttonWidth: number = 0;
  /** 原版按钮常写 MinWidth="88" / MinWidth="120" 而不是 Width；0 表示不限制。 */
  @Prop minButtonWidth: number = 0;
  @Prop buttonHeight: number = BUTTON_MIN_HEIGHT;
  @State hovered: boolean = false;
  on_action: () => void = () => {};

  private palette(): ThemeColors {
    return this.scheme === 'dark' ? DARK : LIGHT;
  }

  build() {
    Text(this.label)
      .fontSize(BUTTON_FONT_SIZE)
      .fontWeight(FontWeight.Bold)
      .fontColor(this.palette().TEXT)
      .textAlign(TextAlign.Center)
      .height(this.buttonHeight)
      .width(this.buttonWidth > 0 ? this.buttonWidth : undefined)
      .padding({
        left: BUTTON_PADDING_H, right: BUTTON_PADDING_H,
        top: this.buttonWidth > 0 ? 0 : BUTTON_PADDING_V,
        bottom: this.buttonWidth > 0 ? 0 : BUTTON_PADDING_V,
      })
      .borderRadius(BUTTON_CORNER)
      .backgroundColor(this.hovered ? this.palette().CONTROL_HOVER : this.palette().CONTROL_FILL)
      .border({ width: 1, color: this.palette().BORDER })
      .constraintSize({ minWidth: this.minButtonWidth })
      .onHover((isHover: boolean): void => { this.hovered = isHover; })
      .onClick((): void => { this.on_action(); });
  }
}

/** 主按钮 —— App.xaml PrimaryButton 样式（「应用」「确定」）。 */
@Component
export struct PrimaryButton {
  @Prop label: string = '';
  @Prop buttonWidth: number = 0;
  /** 原版按钮常写 MinWidth；0 表示不限制。 */
  @Prop minButtonWidth: number = 0;
  @Prop buttonHeight: number = BUTTON_MIN_HEIGHT;
  // ⚠ 不能叫 `enabled`：CommonMethod 里已经有 `enabled()`，会报 TS2416。
  //    与 iconOutline 是同一类坑（见 FluentIcon.ets 顶部注释）。
  @Prop actionEnabled: boolean = true;
  on_action: () => void = () => {};

  build() {
    Text(this.label)
      .fontSize(BUTTON_FONT_SIZE)
      .fontWeight(FontWeight.Bold)
      .fontColor(this.actionEnabled ? PRIMARY_ACTION_TEXT : PRIMARY_ACTION_DISABLED_TEXT)
      .textAlign(TextAlign.Center)
      .height(this.buttonHeight)
      .width(this.buttonWidth > 0 ? this.buttonWidth : undefined)
      .padding({
        left: BUTTON_PADDING_H, right: BUTTON_PADDING_H,
        top: this.buttonWidth > 0 ? 0 : BUTTON_PADDING_V,
        bottom: this.buttonWidth > 0 ? 0 : BUTTON_PADDING_V,
      })
      .borderRadius(PRIMARY_BUTTON_CORNER)
      .constraintSize({ minWidth: this.minButtonWidth })
      .backgroundColor(this.actionEnabled ? PRIMARY_ACTION : PRIMARY_ACTION_DISABLED)
      .border({ width: 1, color: this.actionEnabled ? PRIMARY_ACTION_BORDER : PRIMARY_ACTION_DISABLED })
      .opacity(this.actionEnabled ? 1 : DISABLED_OPACITY)
      .hoverEffect(HoverEffect.Highlight)
      .onClick((): void => {
        if (this.actionEnabled) {
          this.on_action();
        }
      });
  }
}

/** RoundedTextBox —— 圆角输入框（Combo* 一组色）。 */
@Component
export struct RoundedTextBox {
  @Prop label: string = '';
  @Prop text: string = '';
  @Prop readOnly: boolean = false;
  @Prop fontSize: number = TEXTBOX_FONT_SIZE;
  @Prop boxHeight: number = 0;
  on_text_change: (value: string) => void = () => {};

  build() {
    Column() {
      if (this.label.length > 0) {
        Text(this.label)
          .fontSize(11)
          .fontColor(MUTED_TEXT)
          .margin({ bottom: 5 });
      }
      TextInput({ text: this.text })
        .fontSize(this.fontSize)
        .fontColor(TEXT)
        .caretColor(TEXT)
        .selectedBackgroundColor(TEXT_SELECTION)
        .backgroundColor(COMBO_BACKGROUND)
        .border({ width: 1, color: BORDER })
        .borderRadius(TEXTBOX_CORNER)
        .padding({
          left: TEXTBOX_PADDING_H, right: TEXTBOX_PADDING_H,
          top: TEXTBOX_PADDING_V, bottom: TEXTBOX_PADDING_V,
        })
        .height(this.boxHeight > 0 ? this.boxHeight : TEXTBOX_MIN_HEIGHT)
        .width('100%')
        .enabled(!this.readOnly)
        .opacity(this.readOnly ? TEXTBOX_READONLY_OPACITY : 1)
        .onChange((value: string): void => { this.on_text_change(value); });
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%');
  }
}

/** 校验出错时的红字（原版：ErrorBrush / FontSize 11 / Wrap）。 */
@Builder
export function error_text(text: string) {
  Text(text)
    .fontSize(11)
    .fontColor(ERROR)
    .width('100%');
}

// ───────────────────── 子窗口外壳 ─────────────────────

/** 关闭按钮 —— SubWindowCloseButton（hover 底色转 DangerBrush）。 */
@Component
export struct SubWindowCloseButton {
  @Prop windowName: string = '';
  @State hovered: boolean = false;

  build() {
    Row() {
      FluentSymbol({
        iconName: 'Dismiss20',
        iconSize: SUBWINDOW_CLOSE_ICON_SIZE,
        iconColor: this.hovered ? DANGER_BUTTON_TEXT : TEXT,
      })
    }
    .width(SUBWINDOW_CLOSE_SIZE)
    .height(SUBWINDOW_CLOSE_SIZE)
    .borderRadius(SUBWINDOW_CLOSE_CORNER)
    .backgroundColor(this.hovered ? DANGER : Color.Transparent)
    .justifyContent(FlexAlign.Center)
    .onHover((isHover: boolean): void => { this.hovered = isHover; })
    .onClick((): void => { SubWindowHost.close(this.windowName); });
  }
}

/**
 * 子窗口外壳 —— 20 个子窗口共用的那一层。
 *
 * 原版每个窗口的行定义都是「Auto / 间距 / 若干块 / 间距 / Auto」，把 20 个窗口的行
 * 定义摊开看，只会出现下面这四种块，顺序固定：
 *
 *   表头(Auto) → 间距 → [提示条(Auto)] → [间距] → 主体(*) → [间距] → [脚注(Auto)] → [间距] → [按钮条(Auto)]
 *
 * 所以外壳给出四个可选槽位，窗口按自己原版的行定义去填：
 *   · notice   —— 提示条（WarningSurface / ErrorSurface 那种圆角块，或一段副说明）
 *   · content  —— 主体，固定 layoutWeight(1)（对应原版 Height="*" 那一行）
 *   · footer   —— 按钮条上方的脚注（如 ImageSettingsWindow 的 FeedbackText）
 *   · actions  —— 按钮条
 * 没这个块的窗口把 hasXxx 设成 false，外壳就完全不渲染那一段（含它前后的间距）。
 *
 * 用法（见 pages/windows/AdvancedSettingsWindow.ets）：
 *   SubWindowShell({ windowName: '…', title: '…', subtitle: '…',
 *                    content: this.body, actions: this.actions })
 */
@Component
export struct SubWindowShell {
  /** 窗口名，关窗时按名字找（window.findWindow）。 */
  @Prop windowName: string = '';
  @Prop title: string = '';
  /** 副标题；空字符串表示这个子窗口没有 SubWindowSubtitle。 */
  @Prop subtitle: string = '';
  /** 标题块右侧是否给关闭按钮让位 48px（原版统一让位）。 */
  @Prop reserveCloseSlot: boolean = true;
  @Prop pageMarginH: number = SUBWINDOW_PAGE_MARGIN_H;
  @Prop pageMarginV: number = SUBWINDOW_PAGE_MARGIN_V;
  /**
   * 页面底色。多数窗口是 AppBackgroundBrush；ProtectedContentNoticeWindow 用
   * WindowBackgroundBrush（#FF1F1F1F 实色）、CaptureRecoveryWindow 用 DialogSurfaceBrush。
   * ⚠ 不能叫 `background`：CommonMethod 里已有 `background()`，会报 TS2416。
   */
  @Prop shellBackground: string = APP_BACKGROUND;
  /** 表头 ↔ 第一块的间距（原版行定义里紧跟表头的那个固定高度）。 */
  @Prop gap: number = SUBWINDOW_ROW_GAP;
  /** 是否有提示条（原版表头下面那个 Auto 行）。 */
  @Prop hasNotice: boolean = false;
  /** 提示条 ↔ 主体 的间距。 */
  @Prop noticeGap: number = 0;
  /** 是否有脚注（原版按钮条上面那个 Auto 行）。 */
  @Prop hasFooter: boolean = false;
  /** 主体 ↔ 脚注 的间距。 */
  @Prop footerGap: number = 0;
  /** 是否有独立的按钮条。false 表示按钮画在主体里（如 ProtectedContentNoticeWindow）。 */
  @Prop hasActions: boolean = true;
  /** 最后一块 ↔ 按钮条 的间距。 */
  @Prop actionGap: number = SUBWINDOW_ROW_GAP;
  /**
   * 按钮条布局。原版有些子窗口是一个按钮靠左、一个靠右（如 AdvancedSettingsWindow 的
   * 「关闭高级模式」+「应用」），有些是全部靠右。false = 全靠右；true = 两端对齐。
   */
  @Prop actionsSplit: boolean = false;

  @Builder
  empty_slot() {}

  @BuilderParam notice: () => void = this.empty_slot;
  @BuilderParam content: () => void = this.empty_slot;
  @BuilderParam footer: () => void = this.empty_slot;
  @BuilderParam actions: () => void = this.empty_slot;

  build() {
    Column() {
      // ── 表头：SubWindowHeader（MinHeight 44），原版整条可拖动窗口 ──
      Stack({ alignContent: Alignment.TopEnd }) {
        Column() {
          Text(this.title)
            .fontSize(SUBWINDOW_TITLE_SIZE)
            .fontWeight(FontWeight.Bold)
            .fontColor(TEXT)
            .width('100%');
          if (this.subtitle.length > 0) {
            Text(this.subtitle)
              .fontSize(SUBWINDOW_SUBTITLE_SIZE)
              .fontColor(MUTED_TEXT)
              .lineHeight(SUBWINDOW_SUBTITLE_LINE_HEIGHT)
              .width('100%')
              .margin({ top: SUBWINDOW_SUBTITLE_MARGIN_TOP });
          }
        }
        .alignItems(HorizontalAlign.Start)
        .justifyContent(FlexAlign.Center)
        .width('100%')
        .padding({ right: this.reserveCloseSlot ? SUBWINDOW_HEADER_TEXT_END : 0 })
        .constraintSize({ minHeight: SUBWINDOW_HEADER_MIN_HEIGHT })
        // WindowDragBehavior.IsEnabled="True" 的等价物。
        .onMouse((event: MouseEvent): void => {
          if (event.action === MouseAction.Press) {
            SubWindowHost.start_drag(this.windowName);
          }
        });

        SubWindowCloseButton({ windowName: this.windowName });
      }
      .width('100%')
      .constraintSize({ minHeight: SUBWINDOW_HEADER_MIN_HEIGHT });

      Column().height(this.gap);

      // ── 可选提示条 ──
      if (this.hasNotice) {
        Column() {
          this.notice();
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start);

        Column().height(this.noticeGap);
      }

      // ── 内容（各子窗口自己填）。对应原版行定义里的 Height="*"，
      //    所以这里由外壳统一给 layoutWeight(1)，窗口只需管内容本身。 ──
      Column() {
        this.content();
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start);

      // ── 可选脚注 ──
      if (this.hasFooter) {
        Column().height(this.footerGap);

        Column() {
          this.footer();
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start);
      }

      // ── 按钮条（原版是 Auto 行里的 StackPanel，靠左或靠右；见 actionsSplit） ──
      if (this.hasActions) {
        Column().height(this.actionGap);

        Row() {
          this.actions();
        }
        .width('100%')
        .justifyContent(this.actionsSplit ? FlexAlign.SpaceBetween : FlexAlign.End)
        .alignItems(VerticalAlign.Center);
      }
    }
    .width('100%')
    .height('100%')
    .padding({
      left: this.pageMarginH, right: this.pageMarginH,
      top: this.pageMarginV, bottom: this.pageMarginV,
    })
    .backgroundColor(this.shellBackground)
    .alignItems(HorizontalAlign.Start);
  }
}

// ───────────────────── 提示条（多个窗口共用的 WarningSurface 块） ─────────────────────

/**
 * NoticeBanner —— 圆角提示条。
 * 对应原版这一族写法（值取自各窗口自己的那几行，此处取的是最通用的形态）：
 *   <Border Background="{DynamicResource WarningSurfaceBrush}"
 *           BorderBrush="{DynamicResource WarningBrush}"
 *           BorderThickness="1" CornerRadius="12" Padding="14,11">
 *     <TextBlock Foreground="{DynamicResource WarningBrush}" FontSize="12"
 *                LineHeight="18" TextWrapping="Wrap"/>
 *   </Border>
 * 底色/边框色/圆角不是常量，由各窗口按自己那几行传进来（原版各窗口并不完全一致）。
 */
@Component
export struct NoticeBanner {
  @Prop noticeText: string = '';
  @Prop noticeTextColor: string = WARNING;
  @Prop surfaceColor: string = WARNING_SURFACE;
  // ⚠ 不能叫 `borderColor`：CommonAttribute 里已经有 `borderColor()`（设边框色），
  //    同名 @Prop 会报 TS2416。与 brightness / contrast 是同一类坑。
  @Prop bannerBorderColor: string = WARNING;
  @Prop bannerCorner: number = 12;
  @Prop padH: number = 14;
  @Prop padV: number = 11;
  @Prop noticeFontSize: number = 12;
  @Prop noticeLineHeight: number = 18;

  build() {
    Text(this.noticeText)
      .fontSize(this.noticeFontSize)
      .fontColor(this.noticeTextColor)
      .lineHeight(this.noticeLineHeight)
      .width('100%')
      .padding({ left: this.padH, right: this.padH, top: this.padV, bottom: this.padV })
      .borderRadius(this.bannerCorner)
      .backgroundColor(this.surfaceColor)
      .border({ width: 1, color: this.bannerBorderColor });
  }
}

/**
 * BadgeChip —— 圆角小徽标（ProtectedContentNoticeWindow 底部的「音频 / 提示」两枚）。
 * 原版：
 *   <Border Background="ControlFillBrush" BorderBrush="BorderSoftBrush"
 *           BorderThickness="1" CornerRadius="15" Padding="10,5">
 *     <StackPanel Orientation="Horizontal">
 *       <ui:SymbolIcon FontSize="14" Margin="0,0,5,0"/>
 *       <TextBlock FontSize="11" VerticalAlignment="Center"/>
 *     </StackPanel>
 *   </Border>
 */
@Component
export struct BadgeChip {
  @Prop iconName: string = '';
  @Prop chipText: string = '';
  /** 右侧外边距（原版第一个徽标 Margin="0,0,6,0"，第二个没有）。 */
  @Prop chipMarginEnd: number = 0;

  build() {
    Row() {
      FluentSymbol({
        iconName: this.iconName,
        iconSize: 14,
        iconColor: MUTED_TEXT,
      });
      Text(this.chipText)
        .fontSize(11)
        .fontColor(MUTED_TEXT)
        .margin({ left: 5 });
    }
    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
    .borderRadius(15)
    .backgroundColor(CONTROL_FILL)
    .border({ width: 1, color: BORDER_SOFT })
    .alignItems(VerticalAlign.Center)
    .margin({ right: this.chipMarginEnd });
  }
}

// ───────────────────── 开窗 / 关窗 ─────────────────────

/** 一个子窗口的创建参数（对应原版一个 <ui:FluentWindow> 的那几行属性）。 */
export interface SubWindowSpec {
  /** 窗口名（window.findWindow 的键），用 XAML 的类名。 */
  name: string;
  /** 页面路径（@Entry 页），如 'pages/windows/AdvancedSettingsWindow'。 */
  page: string;
  /** Title="{DynamicResource XxxTitle}" */
  title: string;
  /** Width / Height */
  width: number;
  height: number;
  /** ResizeMode="NoResize" → false；"CanResize" → true */
  resizable: boolean;
  /** MinWidth / MinHeight（仅 resizable 时有意义） */
  minWidth: number;
  minHeight: number;
  /** 是否模态（原版全部是 CenterOwner 的模态对话框）。 */
  modal: boolean;
}

/**
 * 子窗口打开失败的 AppStorage 键。
 *
 * 为什么要有它：这个工程的窗口是**独立窗口**，失败原因只会出现在 hilog 里，
 * 而 hilog 在应用进程外读不到（沙箱 + 用户侧也不方便随手抓）。于是把失败原因
 * 写进 AppStorage，由主窗口 Index.ets 的轮询读出来显示在预览区 —— 与
 * `im_usb_diagnostics()` 走 NAPI 回传是同一个思路：**失败必须能被看见**。
 */
export const SUBWINDOW_ERROR_KEY: string = 'im.subwindow.lastError';

/** 把 reject 原因渲染成一行可读文本（原因可能是 undefined / 非 Error 对象）。 */
function describe_failure(failure: BusinessError): string {
  if (failure === undefined || failure === null) {
    return '未知原因';
  }
  const code: number = failure.code;
  const message: string = failure.message;
  if (message === undefined || message.length === 0) {
    return code !== undefined ? `code ${code}` : '未知原因';
  }
  return code !== undefined && code !== 0 ? `code ${code}：${message}` : message;
}

/** 上报一次开窗失败：写 AppStorage + hilog（两处都写，便于用户界面自查）。 */
function report_open_failure(name: string, stage: string, failure: BusinessError): void {
  const text: string = `${name} 在「${stage}」失败：${describe_failure(failure)}`;
  try {
    AppStorage.setOrCreate<string>(SUBWINDOW_ERROR_KEY, text);
  } catch (error) {
    hilog.warn(DOMAIN, TAG, '写入 %{public}s 失败', SUBWINDOW_ERROR_KEY);
  }
  hilog.error(DOMAIN, TAG, 'open(%{public}s) %{public}s', name, text);
}

/**
 * 上报一条「窗口开出来了，但某项没照原版生效」的软失败。
 *
 * 与 report_open_failure 分开，是因为这类问题不该被当成崩溃，但**必须让用户看见** ——
 * 子窗口的 hilog 在应用进程外读不到（本项目一贯的处理方式：失败原因写 AppStorage，
 * 由主窗口轮询显示）。典型场景：窗口尺寸被系统上限截断。
 */
function report_open_warning(name: string, stage: string, detail: string): void {
  const text: string = `${name} 在「${stage}」未按原版生效：${detail}`;
  try {
    AppStorage.setOrCreate<string>(SUBWINDOW_ERROR_KEY, text);
  } catch (error) {
    hilog.warn(DOMAIN, TAG, '写入 %{public}s 失败', SUBWINDOW_ERROR_KEY);
  }
  hilog.warn(DOMAIN, TAG, 'open(%{public}s) %{public}s', name, text);
}

/**
 * 1 vp 等于多少 px。
 *
 * ★ 为什么必须有它：`window.Rect`（即 SubWindowOptions.windowRect 与
 *   getWindowProperties().windowRect）的单位是 **px**，而原版 WPF 的
 *   `Width` / `Height` 是 DIP —— 鸿蒙里对等的单位是 **vp**。
 *   直接把这几个 DIP 数值塞给窗口 API，窗口就会比原版小一整圈。
 *   实测（1920×1280 截图、密度 1.175）：关于窗口的 760×600 请求得到的是
 *   467×448px（≈397×381vp），位置却按请求生效了 ⇒ 尺寸这一路确实没按 vp 解释。
 *
 * 取 display 的密度（与 DeveloperToolsWindow.read_density 同一写法，同源同值）。
 */
export function vp_to_px_ratio(): number {
  try {
    const density: number = display.getDefaultDisplaySync().densityPixels;
    if (density > 0) {
      return density;
    }
  } catch (error) {
    hilog.warn(DOMAIN, TAG, '取显示密度失败，按 1 处理');
  }
  return 1;
}

export class SubWindowHost {
  /**
   * 关窗前拦截钩子 —— 对应原版窗口 `Closing="OnWindowClosing"` 里 `e.Cancel = true`。
   * 钩子返回 false 表示「这次关窗不作数」，窗口保持打开。
   * 典型用途：ImageSettingsWindow 关闭前要把预览回滚，回滚失败就拒绝关闭。
   */
  private static closeHooks: Map<string, () => boolean> = new Map<string, () => boolean>();

  /** 注册关窗前钩子（窗口 aboutToAppear 时调）。 */
  static register_close_hook(name: string, hook: () => boolean): void {
    SubWindowHost.closeHooks.set(name, hook);
  }

  /** 注销（窗口 aboutToDisappear 时调）。 */
  static unregister_close_hook(name: string): void {
    SubWindowHost.closeHooks.delete(name);
  }

  /** 按名字取已存在的子窗口；找不到返回 null。 */
  private static find(name: string): window.Window | null {
    try {
      const found: window.Window = window.findWindow(name);
      return found !== undefined && found !== null ? found : null;
    } catch (error) {
      return null;
    }
  }

  /** 关闭并销毁：window.findWindow(name).destroyWindow()。 */
  static close(name: string): void {
    const hook: (() => boolean) | undefined = SubWindowHost.closeHooks.get(name);
    if (hook !== undefined) {
      if (!hook()) {
        // 与原版 e.Cancel = true 等价：保持窗口打开。
        return;
      }
      SubWindowHost.closeHooks.delete(name);
    }
    const target: window.Window | null = SubWindowHost.find(name);
    if (target === null) {
      return;
    }
    target.destroyWindow().catch((error: BusinessError): void => {
      // 只取 describe_failure 的文本：拒绝原因可能是 undefined，
      // 在 .catch 回调里对它取 .message 会二次抛错（= 未捕获异常，会终止应用）。
      hilog.warn(DOMAIN, TAG, 'destroyWindow(%{public}s) 失败: %{public}s',
        name, describe_failure(error as BusinessError));
    });
  }

  /** 拖动子窗口 —— 表头按下时调用，对应原版 WindowDragBehavior。 */
  static start_drag(name: string): void {
    const target: window.Window | null = SubWindowHost.find(name);
    if (target === null) {
      return;
    }
    target.startMoving().catch((error: BusinessError): void => {
      hilog.warn(DOMAIN, TAG, 'startMoving(%{public}s) 失败: %{public}s',
        name, describe_failure(error as BusinessError));
    });
  }

  /**
   * 打开子窗口；已存在则只前置（重复点按钮不会开一堆）。
   * 位置按原版 WindowStartupLocation="CenterOwner"：在主窗口矩形上居中。
   *
   * ★ 这里**不允许任何一个非关键步骤把整条流程带崩**：
   *   1) `setWindowLimits`（限最小/最大尺寸）在部分设备形态上会直接报不支持；
   *      它只是"锦上添花"，失败绝不能挡住后面的 setUIContent/showWindow —— 否则
   *      窗口对象已经建出来了，却永远不显示内容，而且**同名窗口会一直留在窗口
   *      管理器里**，之后每次点击都只把它 showWindow() 出来，用户看到的就是
   *      「点一下闪一下就没了」。
   *   2) 任何一步失败都要把半成品窗口 destroyWindow() 掉，保证下一次点击能
   *      从头再来，而不是复用那个空壳。
   *   3) 失败原因写 AppStorage，主窗口显示（见 SUBWINDOW_ERROR_KEY）。
   */
  static async open(ctx: common.Context, spec: SubWindowSpec): Promise<void> {
    const existing: window.Window | null = SubWindowHost.find(spec.name);
    if (existing !== null) {
      try {
        await existing.showWindow();
      } catch (error) {
        report_open_failure(spec.name, '前置已存在的窗口', error as BusinessError);
      }
      return;
    }

    let sub: window.Window | null = null;
    try {
      // 原版 Width/Height 是 DIP（= vp），窗口 API 收 px ⇒ 先换算再谈尺寸。
      const ratio: number = vp_to_px_ratio();
      const wantWidth: number = Math.round(spec.width * ratio);
      const wantHeight: number = Math.round(spec.height * ratio);

      const owner: window.Window = await window.getLastWindow(ctx);
      let left: number = 0;
      let top: number = 0;
      try {
        // owner 的 windowRect 与 windowRect / setWindowLimits 一样是 **px**，
        // 所以居中算式里必须用 wantWidth/wantHeight（px），不能再拿 spec（vp）来混算。
        const rect: window.Rect = owner.getWindowProperties().windowRect;
        left = Math.round(rect.left + (rect.width - wantWidth) / 2);
        top = Math.round(rect.top + (rect.height - wantHeight) / 2);
        if (left < 0) {
          left = 0;
        }
        if (top < 0) {
          top = 0;
        }
      } catch (error) {
        // 拿不到主窗口矩形就交给系统摆放。
        hilog.warn(DOMAIN, TAG, 'getWindowProperties 失败，交给系统摆放: %{public}s',
          (error as BusinessError).message);
      }

      const options: window.SubWindowOptions = {
        title: spec.title,
        // 原版 ExtendsContentIntoTitleBar="True"：系统装饰关掉，标题栏由外壳自绘。
        decorEnabled: false,
        isModal: spec.modal,
        // windowRect 的单位是 px（不是 vp）：见 @ohos.window 的 Rect 定义，
        // 「单位为px，该参数为整数」。传 vp 数值会让窗口实际尺寸偏小一圈。
        windowRect: { left: left, top: top, width: wantWidth, height: wantHeight },
      };
      sub = await owner.createSubWindowWithOptions(spec.name, options);

      // ResizeMode="NoResize" → 把 min 与 max 钉成同一个值。
      // 只做"尽力而为"：失败不影响窗口能否显示。
      // 单位是 px；isForcible=true 才能把最小值压到系统限制以下
      // （注意：**最大值仍受系统上限约束**，vp 入参时 isForcible 无效）。
      try {
        await sub.setWindowLimits(spec.resizable
          ? {
            minWidth: Math.round(spec.minWidth * ratio),
            minHeight: Math.round(spec.minHeight * ratio),
          }
          : {
            minWidth: wantWidth, maxWidth: wantWidth,
            minHeight: wantHeight, maxHeight: wantHeight,
          }, true);
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'setWindowLimits(%{public}s) 失败，按系统默认尺寸: %{public}s',
          spec.name, (error as BusinessError).message);
      }

      await sub.setUIContent(spec.page);
      await sub.showWindow();

      // ★ showWindow 之后再显式 resize 一次。
      // 实测：createSubWindowWithOptions 的 windowRect 在部分设备形态上只对**位置**
      // 生效、尺寸会被系统默认值覆盖（760×600 的请求得到 467×448px 的小窗），
      // 所以这里补一刀；resizeAsync 与 resize 的单位同样是 px。
      try {
        await sub.resizeAsync(wantWidth, wantHeight);
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'resizeAsync(%{public}s) 失败: %{public}s',
          spec.name, (error as BusinessError).message);
      }

      // 如实校验实际尺寸：尺寸不对就写进 AppStorage 让用户看见，不假装成功
      // （本工程一贯纪律：宁可报出来，也不留一个「看着像好了」的假成功）。
      try {
        const got: window.Rect = sub.getWindowProperties().windowRect;
        const tolW: number = Math.max(8, wantWidth * 0.02);
        const tolH: number = Math.max(8, wantHeight * 0.02);
        if (Math.abs(got.width - wantWidth) > tolW || Math.abs(got.height - wantHeight) > tolH) {
          report_open_warning(spec.name, '设置窗口尺寸',
            `请求 ${wantWidth}×${wantHeight}px（原版 ${spec.width}×${spec.height}DIP），` +
            `实际 ${got.width}×${got.height}px —— 已被系统窗口尺寸上限截断。`);
        } else {
          SubWindowHost.clear_error();
        }
      } catch (error) {
        hilog.warn(DOMAIN, TAG, '读取 %{public}s 实际尺寸失败: %{public}s',
          spec.name, (error as BusinessError).message);
        SubWindowHost.clear_error();
      }
    } catch (error) {
      report_open_failure(spec.name, '创建窗口/加载页面', error as BusinessError);
      // 半成品窗口必须销毁，否则同名空壳会赖在窗口管理器里（见上面 ★ 1）。
      if (sub !== null) {
        try {
          await sub.destroyWindow();
        } catch (inner) {
          hilog.warn(DOMAIN, TAG, '销毁半成品窗口 %{public}s 失败: %{public}s',
            spec.name, (inner as BusinessError).message);
        }
      }
    }
  }

  /** 清掉上一次的失败记录（开窗成功后调，避免旧错误一直挂在界面上）。 */
  static clear_error(): void {
    try {
      AppStorage.setOrCreate<string>(SUBWINDOW_ERROR_KEY, '');
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '清空 %{public}s 失败', SUBWINDOW_ERROR_KEY);
    }
  }
}
