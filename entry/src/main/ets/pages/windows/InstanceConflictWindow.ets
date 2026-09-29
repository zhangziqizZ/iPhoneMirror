// InstanceConflictWindow.ets —— 子窗口：实例冲突（iPhoneMirror 已在运行）
//
// 逐项对照上游 src/App/Windows/InstanceConflictWindow.xaml（109 行）
//              src/App/Windows/InstanceConflictWindow.xaml.cs（128 行）
//  上游 main（1.8.4）与 linux-port（1.8.1）两份 .xaml / .xaml.cs **逐行相同**，
//  本文件按 main 版还原。
//
// ── 窗口属性（XAML 根元素 <ui:FluentWindow> 那一行）──────────────────────────
//   Title="{DynamicResource InstanceConflictTitle}"  → 「iPhoneMirror 已在运行」
//   Width="560" SizeToContent="Height" MinHeight="320" MaxHeight="480"
//       → 宽 560；鸿蒙子窗口必须显式给高度（没有 SizeToContent），这里取 380：
//         表头 44 + 16 + 警示条 ≈ 92 + 14 + 状态行 20 + 20 + 按钮条 42 + 上下 Padding 40
//         ≈ 288，原版 MinHeight 320 / MaxHeight 480，380 落在区间内且给错误行留出余量。
//   ResizeMode="NoResize"                            → resizable: false
//   WindowStartupLocation="CenterScreen"             → SubWindowHost.open 里算居中
//   WindowStyle="None" + ExtendsContentIntoTitleBar="True" → decorEnabled: false + 自绘表头
//   WindowBackdropType="None"                        → 实色底，无 Mica
//   Background="{DynamicResource DialogSurfaceBrush}" → shellBackground = DIALOG_SURFACE
//   ShowInTaskbar="True"
//   Closing="OnWindowClosing"                        → SubWindowHost.register_close_hook
//
// ── 内容根 ─────────────────────────────────────────────────────────────────
//   <Border x:Name="WindowSurface" Style="{StaticResource ModernDialogSurface}"
//           Margin="0" BorderThickness="0" Effect="{x:Null}" CornerRadius="0">
//   → 只保留了底色与零圆角（DIALOG_SURFACE + 外壳 Padding 24,20），
//     阴影/圆角由系统窗口负责。
//
// ── 行定义（7 行）逐条落到 SubWindowShell 的四个槽位 ─────────────────────────
//   Row Auto : Grid Style=SubWindowHeader（MinHeight 44, WindowDragBehavior）
//                TextBlock InstanceConflictTitle / Style=SubWindowTitle / Margin="0,0,48,0"
//                Button x:Name=HeaderCloseButton（SubWindowCloseButton, Dismiss20/18）
//                  Click=OnCloseCurrentClick  → 与「关闭当前窗口」同一结果
//   Row 16   : 间隔                                        → shell 的 gap
//   Row Auto : 警示条（WarningSurfaceBrush 底 / WarningBrush 边 / 圆角 14 / Padding 18,16）
//                └ 圆 34（半径 17，WarningBrush 底）+ SymbolIcon Warning20/16（OnAccent）
//                └ TextBlock InstanceConflictBody   FontSize 13 / LineHeight 21 / Wrap
//                └ TextBlock InstanceConflictHint   Muted 11 / LineHeight 18 / Wrap / Margin 0,8,0,0
//   Row 14   : 间隔                                        → noticeGap
//   Row Auto : Grid MinHeight="20"                         → 主体（layoutWeight 1）
//                StackPanel x:Name=BusyPanel（旋转 ArrowClockwise20 + ClosingOtherInstances）
//                TextBlock x:Name=ErrorText（ErrorBrush 12 / LineHeight 18 / Wrap）
//   Row 20   : 间隔                                        → actionGap
//   Row Auto : StackPanel Orientation=Horizontal / 靠右     → actions
//                Button 关闭其他窗口  MinWidth 150 / Margin 0,0,8,0
//                Button 关闭当前窗口  MinWidth 150 / PrimaryButton / IsDefault
//
// ── 文案来源 Strings.zh-CN.xaml（逐字取用）────────────────────────────────
//   InstanceConflictTitle             「iPhoneMirror 已在运行」
//   InstanceConflictBody              「检测到另一个 iPhoneMirror 程序正在运行。请选择要保留的窗口。」
//   InstanceConflictHint              「关闭其他窗口后，当前窗口会继续启动；关闭当前窗口不会影响已经运行的投屏。」
//   CloseOtherInstances               「关闭其他窗口」
//   CloseCurrentInstance              「关闭当前窗口」
//   ClosingOtherInstances             「正在安全关闭其他 iPhoneMirror 窗口…」
//   CloseOtherInstancesFailedFormat   「仍有 {0} 个 iPhoneMirror 实例未能关闭。请在任务栏或任务管理器中关闭后重试。」
//   DeveloperInstanceConflict         「实例冲突窗口」（开发者预览入口的菜单文案）
//
// ── xaml.cs 行为映射 ───────────────────────────────────────────────────────
//   ContinueWithCurrentInstance（public getter）→ RESULT_KEY_CONTINUE + on_result 回调
//   ShowDeveloperPreview(owner)               → open_instance_conflict_preview()
//   OnCloseOtherInstancesClick                → on_close_other()
//   OnCloseCurrentClick                       → on_close_current()
//   OnWindowClosing（busy 时 e.Cancel=true）  → 关窗钩子；本窗口从不忙，始终允许关闭
//
// ── 平台替换（原版机制在鸿蒙没有对应物，逐条列出）──────────────────────────
//   1. SingleInstanceCoordinator.CloseOtherInstancesAsync 依赖
//      Process.GetProcessesByName / Process.CloseMainWindow / Process.Kill(entireProcessTree)
//      与命名 Mutex + 命名 EventWaitHandle。鸿蒙**不提供**枚举其它应用进程、
//      关闭其窗口或结束其进程的能力（沙箱 + 进程隔离），也没有命名内核对象。
//      → 「关闭其他窗口」按钮**保留原版文案**，点击后不再播放旋转转圈动画
//        （原版 SetBusy(true) 会先转圈再等 20 秒），而是立刻给出确切原因：
//        错误行用 CloseOtherInstancesFailedFormat 报剩余实例数，
//        下面一行说明鸿蒙侧做不到什么、用户该去哪里关。
//        不做「转圈 20 秒然后失败」的假动效。
//   2. 错误文案里的「任务栏或任务管理器」是 Windows 事实 → 改成「最近任务列表」，
//      并在同一行补上「（鸿蒙不允许应用结束其它应用进程）」。
//   3. 原版靠 WPF 的 DialogResult 回传结果 → 改 AppStorage 键 + 一次性回调
//      （见 RESULT_KEY_CONTINUE / InstanceConflictRequest.on_result）。
//   4. 原版 WindowStyle="None" 的自定义拖动区由 WindowDragBehavior 提供；
//      鸿蒙侧由 SubWindowShell 的表头起拖（startMoving），行为一致。
//
// ── 不做假成功 ─────────────────────────────────────────────────────────────
//   「关闭其他窗口」点下去不会假装已经关掉：ContinueWithCurrentInstance 保持 false，
//   窗口不关，用户必须显式选「关闭当前窗口」或用右上角 X（两者结果相同）。

import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  SubWindowShell, SubWindowHost, SecondaryButton, PrimaryButton,
  SUBWINDOW_ROW_GAP, SubWindowSpec,
} from '../../common/SubWindow';
import {
  DIALOG_SURFACE, WARNING, WARNING_SURFACE, ON_ACCENT, ERROR, MUTED_TEXT, TEXT,
} from '../../common/Theme';
import { FluentSymbol } from '../../common/FluentIcon';

const TAG: string = 'im_instance_conflict';
const DOMAIN: number = 0x0100;

/** 窗口名 —— 用 XAML 的类名，window.findWindow 也用它。 */
export const WINDOW_NAME: string = 'InstanceConflictWindow';
/** 页面路径。 */
export const PAGE_PATH: string = 'pages/windows/InstanceConflictWindow';

/** 原版构造函数入参（SingleInstanceCoordinator 探到的其它实例数）。 */
export const ARG_KEY_OTHER_COUNT: string = 'im.instanceConflict.otherInstanceCount';
/** 原版 bool previewOnly。 */
export const ARG_KEY_PREVIEW_ONLY: string = 'im.instanceConflict.previewOnly';
/** 原版 internal bool ContinueWithCurrentInstance 的回传键。 */
export const RESULT_KEY_CONTINUE: string = 'im.instanceConflict.continueWithCurrent';

/** Strings（逐键标注）。 */
const S_TITLE: string = 'iPhoneMirror 已在运行';                    // InstanceConflictTitle
const S_BODY: string = '检测到另一个 iPhoneMirror 程序正在运行。请选择要保留的窗口。';  // InstanceConflictBody
const S_HINT: string =
  '关闭其他窗口后，当前窗口会继续启动；关闭当前窗口不会影响已经运行的投屏。';          // InstanceConflictHint
const S_CLOSE_OTHER: string = '关闭其他窗口';                        // CloseOtherInstances
const S_CLOSE_CURRENT: string = '关闭当前窗口';                      // CloseCurrentInstance
/** CloseOtherInstancesFailedFormat：{0} = 剩余实例数。 */
const S_CLOSE_OTHER_FAILED: string = '仍有 %d 个 iPhoneMirror 实例未能关闭。';
/** 平台替换 1/2：把原因说清楚，不做假动效。 */
const S_CLOSE_OTHER_REASON: string =
  '鸿蒙不允许应用枚举或结束其它应用进程（原版依赖 Process.GetProcessesByName / Process.Kill ' +
  '与命名 Mutex/Event），本窗口无法代为关闭。请在最近任务列表中手动关闭后重试。';

/**
 * 原版 internal InstanceConflictWindow(SingleInstanceCoordinator coordinator,
 *                                      bool previewOnly = false) 的入参 + 结果通道。
 * 用 class（而非含方法的对象字面量）：ArkTS 禁止把「含方法成员的对象字面量」
 * 赋给 interface（arkts-no-untyped-obj-literals），见 WindowServices.ets 顶部说明。
 */
export class InstanceConflictRequest {
  /** 原版 FindOtherInstances().Count。 */
  otherInstanceCount: number = 1;
  previewOnly: boolean = false;
  /** 原版 ShowDialog() 的 bool? 返回值；false = 关闭当前实例。 */
  on_result: (continueWithCurrent: boolean) => void = () => {};

  constructor(otherInstanceCount: number, previewOnly: boolean,
              on_result: (continueWithCurrent: boolean) => void) {
    this.otherInstanceCount = otherInstanceCount;
    this.previewOnly = previewOnly;
    this.on_result = on_result;
  }
}

/** 待传给下一个实例冲突窗口的入参（对应「每个窗口实例自带一份构造参数」）。 */
let pending_request: InstanceConflictRequest | null = null;

/** 原版 internal static void ShowDeveloperPreview(Window owner)：两个按钮都禁用。 */
export function open_instance_conflict_preview(ctx: common.Context): void {
  open_instance_conflict(ctx, new InstanceConflictRequest(1, true,
    (continueWithCurrent: boolean): void => {}), false);
}

/**
 * 打开实例冲突窗口。
 * 原版是 `new InstanceConflictWindow(coordinator, previewOnly).ShowDialog()`，
 * 同步返回 bool?；鸿蒙开窗是异步的，结果走 on_result（保证恰好回调一次）。
 */
export function open_instance_conflict(ctx: common.Context, request: InstanceConflictRequest,
                                       modal: boolean): void {
  pending_request = request;
  AppStorage.setOrCreate<number>(ARG_KEY_OTHER_COUNT, request.otherInstanceCount);
  AppStorage.setOrCreate<boolean>(ARG_KEY_PREVIEW_ONLY, request.previewOnly);
  AppStorage.setOrCreate<boolean>(RESULT_KEY_CONTINUE, false);

  const spec: SubWindowSpec = {
    name: WINDOW_NAME,
    page: PAGE_PATH,
    title: S_TITLE,
    width: 560,
    height: 380,
    resizable: false,               // ResizeMode="NoResize"
    minWidth: 560,
    minHeight: 380,
    modal: modal,                   // 原版是有 DialogResult 的模态窗
  };
  SubWindowHost.open(ctx, spec).catch((error: BusinessError): void => {
    hilog.error(DOMAIN, TAG, '打开失败: %{public}s', error.message);
  });
}

/** 警示条（原版 Row Auto 的那个 Border）：外壳没有对应件，这里局部定义。 */
@Component
struct ConflictWarningBanner {
  @Prop bodyText: string = '';
  @Prop hintText: string = '';

  build() {
    Row() {
      // 圆 34（CornerRadius 17 / WarningBrush 底）+ SymbolIcon Warning20 / FontSize 16
      Row() {
        FluentSymbol({ iconName: 'Warning20', iconSize: 16, iconColor: ON_ACCENT });
      }
      .width(34)
      .height(34)
      .borderRadius(17)
      .backgroundColor(WARNING)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center);

      Column() {
        Text(this.bodyText)
          .fontSize(13)
          .fontColor(TEXT)
          .lineHeight(21)
          .width('100%');
        Text(this.hintText)
          .fontSize(11)
          .fontColor(MUTED_TEXT)
          .lineHeight(18)
          .width('100%')
          .margin({ top: 8 });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 });
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ left: 18, right: 18, top: 16, bottom: 16 })
    .borderRadius(14)
    .backgroundColor(WARNING_SURFACE)
    .border({ width: 1, color: WARNING });
  }
}

@Entry
@Component
struct InstanceConflictWindow {
  @State errorText: string = '';
  @State reasonText: string = '';
  private request: InstanceConflictRequest | null = null;
  /** 原版 Complete() 之后不再回调（保证 on_result 只发一次）。 */
  private resolved: boolean = false;

  aboutToAppear(): void {
    const pending: InstanceConflictRequest | null = pending_request;
    pending_request = null;
    if (pending !== null) {
      this.request = pending;
    }
    // 右上角 X 等价于「关闭当前窗口」（原版 HeaderCloseButton Click=OnCloseCurrentClick）。
    SubWindowHost.register_close_hook(WINDOW_NAME, (): boolean => {
      this.complete(false);
      return true;
    });
  }

  aboutToDisappear(): void {
    SubWindowHost.unregister_close_hook(WINDOW_NAME);
  }

  /**
   * 原版 OnCloseOtherInstancesClick。
   * 平台替换 1：鸿蒙没有 CloseOtherInstancesAsync 的等价能力，
   * 所以不播 BusyPanel 转圈，直接给出确切原因。
   */
  private on_close_other(): void {
    if (this.preview_only()) {
      return;
    }
    const count: number = Math.max(this.other_count(), 1);
    this.errorText = S_CLOSE_OTHER_FAILED.replace('%d', count.toString());
    this.reasonText = S_CLOSE_OTHER_REASON;
    hilog.warn(DOMAIN, TAG, 'close_other_instances_unsupported: remaining=%{public}d', count);
  }

  /** 原版 OnCloseCurrentClick：ContinueWithCurrentInstance = false。 */
  private on_close_current(): void {
    this.complete(false);
  }

  /** 原版 Complete(result)：写 ContinueWithCurrentInstance 后关窗。 */
  private complete(continueWithCurrent: boolean): void {
    if (this.resolved) {
      return;
    }
    this.resolved = true;
    const request: InstanceConflictRequest | null = this.request;
    if (request !== null) {
      request.on_result(continueWithCurrent);
    }
    AppStorage.setOrCreate<boolean>(RESULT_KEY_CONTINUE, continueWithCurrent);
    SubWindowHost.close(WINDOW_NAME);
  }

  private preview_only(): boolean {
    const request: InstanceConflictRequest | null = this.request;
    if (request !== null) {
      return request.previewOnly;
    }
    return AppStorage.get<boolean>(ARG_KEY_PREVIEW_ONLY) ?? false;
  }

  private other_count(): number {
    const request: InstanceConflictRequest | null = this.request;
    if (request !== null) {
      return request.otherInstanceCount;
    }
    return AppStorage.get<number>(ARG_KEY_OTHER_COUNT) ?? 1;
  }

  /** Row Auto：BusyPanel（本窗口恒不显示）/ ErrorText。 */
  @Builder
  body() {
    Column() {
      if (this.errorText.length > 0) {
        Text(this.errorText)
          .fontSize(12)
          .fontColor(ERROR)
          .lineHeight(18)
          .width('100%');
        Text(this.reasonText)
          .fontSize(11)
          .fontColor(MUTED_TEXT)
          .lineHeight(18)
          .width('100%')
          .margin({ top: 6 });
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  notice() {
    ConflictWarningBanner({ bodyText: S_BODY, hintText: S_HINT });
  }

  @Builder
  actions() {
    SecondaryButton({
      label: S_CLOSE_OTHER,
      minButtonWidth: 150,
      // 原版 previewOnly 时 CloseOtherInstancesButton.IsEnabled = false
      on_action: (): void => { this.on_close_other(); },
    })
      .margin({ right: 8 })
      .enabled(!this.preview_only());
    PrimaryButton({
      label: S_CLOSE_CURRENT,
      minButtonWidth: 150,
      actionEnabled: !this.preview_only(),
      on_action: (): void => { this.on_close_current(); },
    });
  }

  build() {
    Column() {
      SubWindowShell({
      windowName: WINDOW_NAME,
      title: S_TITLE,
      subtitle: '',                 // 原版表头只有标题，没有 SubWindowSubtitle
      shellBackground: DIALOG_SURFACE,
      gap: SUBWINDOW_ROW_GAP,       // 行 1 = 16
      hasNotice: true,
      noticeGap: 14,                // 行 3 = 14
      hasFooter: false,
      hasActions: true,
      actionGap: 20,                // 行 5 = 20
      actionsSplit: false,          // 两个按钮都靠右
      notice: (): void => { this.notice(); },
      content: (): void => { this.body(); },
      actions: (): void => { this.actions(); },
    });
    }
  }
}
