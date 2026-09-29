// AppPromptWindow.ets —— 子窗口 7/20：通用确认 / 告知提示框
//
// 逐项对照上游 src/App/Windows/AppPromptWindow.xaml（44 行）
//              src/App/Windows/AppPromptWindow.xaml.cs（109 行）
//
// 这个窗口是全项目复用度最高的一个：题头、正文、按钮文案全部来自绑定，
// 所以它既是「确认框」也是「告知框」。
//
// ── 窗口属性（XAML 根元素 <ui:FluentWindow>）────────────────────────────────
//   Width="520" SizeToContent="Height" MinHeight="250" MaxHeight="540"
//     → 高度自适应内容，250 起、540 封顶。鸿蒙侧高度必须显式给，取 MinHeight=250；
//       正文超过可视区时靠 ScrollViewer（MaxHeight 300）滚动，行为与原版一致。
//   ResizeMode="NoResize" WindowStartupLocation="CenterOwner"
//   WindowStyle="None" + ExtendsContentIntoTitleBar="True" → decorEnabled: false + 自绘表头
//   WindowBackdropType="None"            → 实色底
//   Background="{DynamicResource WindowBackgroundBrush}"
//   ShowInTaskbar="False"
//   ★ 没有 Title 属性；表头文字走绑定 PromptTitle。
//
// ── 内容根 ────────────────────────────────────────────────────────────────
//   <Border Style="{StaticResource ModernDialogSurface}" Margin="0"
//           Effect="{x:Null}" CornerRadius="0" BorderThickness="0">
//   ModernDialogSurface = Background DialogSurfaceBrush / BorderBrush 1px /
//                         CornerRadius 20 / Padding 26
//   这里只覆盖了 Effect / CornerRadius / BorderThickness —— **Padding 仍是 26**，
//   Background 仍是 DialogSurfaceBrush。
//   （注意与 ProtectedContentNoticeWindow 的区别：那个把 Padding 覆盖成了 20。）
//
// ── 行定义（5 行）─────────────────────────────────────────────────────────
//   Row Auto : SubWindowHeader（TextBlock PromptTitle，Margin 0,0,48,0；关闭按钮 Click=OnCancelClick）
//   Row 16   : 间隔
//   Row Auto : Border SettingsSection **Padding="16"**（覆盖默认 18）
//                └ ScrollViewer VerticalScrollBarVisibility=Auto MaxHeight=300
//                    └ TextBlock PromptBody / Wrap / FontSize 13 / LineHeight 21
//   Row 20   : 间隔
//   Row Auto : 靠右的按钮条
//                取消（Content=CancelText / MinWidth 92 / Margin 0,0,8,0 / Visibility 绑定）
//                确认（Content=ConfirmText / MinWidth 118 / PrimaryButton）
//
// ── xaml.cs 的行为（逐条复刻）──────────────────────────────────────────────
//   ConfirmText = Get(showCancel ? "Continue" : "Close")
//   CancelText  = Get("Cancel")
//   CancelVisibility = showCancel ? Visible : Collapsed
//   Confirm(title, body) → showDialog() == true
//   Inform(title, body)  → 只弹，不关心结果
//   InformThen(title, body, afterShown)：
//       窗口上屏（ContentRendered）之后才跑 afterShown，且只跑一次。
//       原版注释：让提示先真正画到屏幕上，再去执行这次警告要求的 USB/会话清理。
//       afterShown 抛异常走 DiagnosticLogger.Exception("capture",
//                                    "prompt_after_shown_action_failed", error)
//   OnConfirmClick → Complete(true)；OnCancelClick → Complete(false)
//   Complete(result)：_previewOnly 时只 Close()，否则 DialogResult = result
//     （开发者预览里确定/取消都不执行应用操作）

import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  SubWindowShell, SubWindowHost, SecondaryButton, PrimaryButton, SettingsSection,
  SUBWINDOW_ROW_GAP,
  SubWindowSpec,
} from '../../common/SubWindow';
import { TEXT, DIALOG_SURFACE, SETTINGS_SECTION_CORNER, SETTINGS_SECTION_PADDING } from '../../common/Theme';
import { WindowServices, PromptRequest } from '../../common/WindowServices';

const TAG: string = 'im_app_prompt';
const DOMAIN: number = 0x0100;

export const WINDOW_NAME: string = 'AppPromptWindow';
export const PAGE_PATH: string = 'pages/windows/AppPromptWindow';

/** 原版 MinHeight="250"：SizeToContent=Height 时的下限，这里当窗口高度用。 */
const WINDOW_HEIGHT: number = 250;
/** 原版 <Border Style="SettingsSection" Padding="16"> —— 覆盖了默认的 18。 */
const CARD_PADDING: number = 16;
/** 原版 ScrollViewer MaxHeight="300"。 */
const BODY_MAX_HEIGHT: number = 300;

/** Strings（逐键标注）。 */
const S_CONTINUE: string = '继续';       // Continue
const S_CLOSE: string = '关闭';          // Close
const S_CANCEL: string = '取消';         // Cancel
const S_PREVIEW_TITLE: string = '开发者提示预览';        // DeveloperPreviewPromptTitle
const S_PREVIEW_BODY: string =
  '这是标准确认提示框的安全预览。确认和取消按钮不会执行应用操作。';  // DeveloperPreviewPromptBody

/**
 * 原版 internal static bool Confirm(string title, string body)。
 * 同步返回值改成了回调（鸿蒙开窗是异步的）。
 */
export function confirm_prompt(ctx: common.Context, title: string, body: string,
                               on_result: (confirmed: boolean) => void): void {
  open_prompt(ctx, new PromptRequest(title, body, true, on_result, null), true);
}

/** 原版 internal static void Inform(string title, string body)。 */
export function inform_prompt(ctx: common.Context, title: string, body: string): void {
  open_prompt(ctx, new PromptRequest(title, body, false, (confirmed: boolean): void => {}, null),
    true);
}

/**
 * 原版 internal static void InformThen(string title, string body, Func<Task> afterShown)。
 * afterShown 在窗口上屏之后跑一次。
 */
export function inform_then(ctx: common.Context, title: string, body: string,
                            after_shown: () => void): void {
  open_prompt(ctx, new PromptRequest(title, body, false,
    (confirmed: boolean): void => {}, after_shown), true);
}

/**
 * 原版 internal static void ShowDeveloperPreview(Window owner, string title, string body,
 *                                               bool showCancel)。
 * previewOnly：确定/取消都只关窗，不执行应用操作。
 */
export function open_prompt_preview(ctx: common.Context): void {
  open_prompt(ctx,
    new PromptRequest(S_PREVIEW_TITLE, S_PREVIEW_BODY, true,
      (confirmed: boolean): void => {}, null),
    false);
}

function open_prompt(ctx: common.Context, request: PromptRequest, modal: boolean): void {
  WindowServices.pending_prompt = request;

  const spec: SubWindowSpec = {
    name: WINDOW_NAME,
    page: PAGE_PATH,
    title: request.title,
    width: 520,
    height: WINDOW_HEIGHT,
    resizable: false,                // ResizeMode="NoResize"
    minWidth: 520,
    minHeight: WINDOW_HEIGHT,
    modal: modal,
  };
  SubWindowHost.open(ctx, spec).catch((error: BusinessError): void => {
    hilog.error(DOMAIN, TAG, '打开失败: %{public}s', error.message);
  });
}

@Entry
@Component
struct AppPromptWindow {
  @State promptTitle: string = '';
  @State promptBody: string = '';
  /** 原版 ConfirmText：showCancel 时是「继续」，否则是「关闭」。 */
  @State confirmText: string = S_CLOSE;
  /** 原版 CancelVisibility == Visible。 */
  @State showCancel: boolean = true;

  private request: PromptRequest | null = null;
  /** 原版 Complete() 之后不再回调（保证 on_result 只发一次）。 */
  private resolved: boolean = false;

  aboutToAppear(): void {
    const pending: PromptRequest | null = WindowServices.pending_prompt;
    WindowServices.pending_prompt = null;
    if (pending !== null) {
      this.request = pending;
      this.promptTitle = pending.title;
      this.promptBody = pending.body;
      this.showCancel = pending.showCancel;
      this.confirmText = pending.showCancel ? S_CONTINUE : S_CLOSE;
    }
    // 右上角 X 等价于「取消」（原版关闭按钮 Click=OnCancelClick）。
    SubWindowHost.register_close_hook(WINDOW_NAME, (): boolean => {
      this.complete(false);
      return true;
    });
  }

  aboutToDisappear(): void {
    SubWindowHost.unregister_close_hook(WINDOW_NAME);
  }

  /** 原版 ContentRendered 里跑 afterShown（只跑一次）。 */
  onPageShow(): void {
    const request: PromptRequest | null = this.request;
    if (request === null || request.after_shown === null) {
      return;
    }
    const action: () => void = request.after_shown;
    request.after_shown = null;      // 只跑一次
    try {
      action();
    } catch (error) {
      // 原版：DiagnosticLogger.Exception("capture", "prompt_after_shown_action_failed", error)
      hilog.error(DOMAIN, TAG, 'prompt_after_shown_action_failed: %{public}s',
        (error as BusinessError).message);
    }
  }

  /** 原版 Complete(result)。 */
  private complete(confirmed: boolean): void {
    if (this.resolved) {
      return;
    }
    this.resolved = true;
    const request: PromptRequest | null = this.request;
    if (request !== null) {
      request.on_result(confirmed);
    }
    SubWindowHost.close(WINDOW_NAME);
  }

  /** Row Auto ：正文块（SettingsSection Padding="16" + 最高 300 的滚动区）。 */
  @Builder
  card_body() {
    Scroll() {
      Text(this.promptBody)
        .fontSize(13)
        .fontColor(TEXT)
        .lineHeight(21)
        .width('100%');
    }
    .width('100%')
    .constraintSize({ maxHeight: BODY_MAX_HEIGHT })
    .scrollBar(BarState.Auto)
    .align(Alignment.Top);
  }

  @Builder
  body() {
    Column() {
      SettingsSection({ padH: CARD_PADDING, padV: CARD_PADDING, content: (): void => { this.card_body(); } });
    }
    .width('100%')
    .layoutWeight(0);
  }

  /** Row Auto ：靠右的按钮条（取消 MinWidth 92 / 确认 MinWidth 118）。 */
  @Builder
  actions() {
    if (this.showCancel) {
      SecondaryButton({
        label: S_CANCEL,
        minButtonWidth: 92,
        on_action: (): void => { this.complete(false); },
      })
        .margin({ right: 8 });
    }
    PrimaryButton({
      label: this.confirmText,
      minButtonWidth: 118,
      on_action: (): void => { this.complete(true); },
    });
  }

  build() {
    Column() {
      SubWindowShell({
      windowName: WINDOW_NAME,
      title: this.promptTitle,
      subtitle: '',
      // Border Padding 仍是 ModernDialogSurface 的 26；底色是 DialogSurfaceBrush
      pageMarginH: 26,
      pageMarginV: 26,
      shellBackground: DIALOG_SURFACE,
      gap: SUBWINDOW_ROW_GAP,          // 行 1 = 16
      hasNotice: false,
      hasFooter: false,
      hasActions: true,
      actionGap: 20,                   // 行 3 = 20
      actionsSplit: false,
      content: (): void => { this.body(); },
      actions: (): void => { this.actions(); },
    });
    }
  }
}
