// StartupErrorWindow.ets —— 子窗口：启动错误
//
// 逐项对照上游 src/App/Windows/StartupErrorWindow.xaml（66 行）
//              src/App/Windows/StartupErrorWindow.xaml.cs（61 行）
//
// 上游两份的差异（main 1.8.4 / linux-port 1.8.1）**只在文案来源**：
//   · main 版：全部走 LocalizationService.Get("StartupError…") 资源键；
//   · linux 版：同一批文案写成内联三语（zh-HK / zh-CN / en-US）三元表达式，
//     字面值与 main 版资源键的 zh-CN 值**完全相同**。
//   → 本文件按 main 版的资源键 + Strings.zh-CN.xaml 的简体原文还原。
//
// ── 窗口属性（XAML 根元素 <ui:FluentWindow> 那一行）──────────────────────────
//   Title="iPhoneMirror"                              → 原版是硬编码，不是资源键
//   Width="680" Height="440" MinWidth="620" MinHeight="400"
//   ResizeMode="CanResize"                            → resizable: true
//   WindowStartupLocation="CenterScreen"              → SubWindowHost.open 里算居中
//   ExtendsContentIntoTitleBar="True"                 → decorEnabled: false + 自绘表头
//   WindowBackdropType="Mica" / WindowCornerPreference="Round" → 由系统窗口负责
//   Background="{DynamicResource AppBackgroundBrush}" → SubWindowShell 默认底色
//   AutomationProperties.AutomationId="StartupErrorWindow"
//
// ── 行定义（9 行）逐条落到 SubWindowShell 的四个槽位 ─────────────────────────
//   Row Auto : Grid Style=SubWindowHeader（MinHeight 44, WindowDragBehavior）
//                TextBlock x:Name=HeadingText / Style=SubWindowTitle / Margin="0,0,48,0"
//                Button Style=SubWindowCloseButton + SymbolIcon Dismiss20/18（Click=OnCloseClick）
//   Row 16   : 间隔                                        → shell 的 gap
//   Row Auto : TextBlock x:Name=SummaryText  FontSize 14 / MutedTextBrush / Wrap
//                                                          → notice（noticeGap 20）
//   Row 20   : 间隔                                        → noticeGap
//   Row Auto : StackPanel                                  → content 顶部（固定高）
//                TextBlock x:Name=LogLabelText  FontSize 12 / Margin 0,0,0,7
//                TextBox x:Name=LogPathTextBox  Style=RoundedTextBox / IsReadOnly
//                        MinHeight 38 / VerticalContentAlignment=Center
//   Row 14   : 间隔                                        → content 内部
//   Row *    : Expander x:Name=DetailsExpander  IsExpanded=False / Header=错误详情
//                └ Border Style=SettingsSection CornerRadius 12 / Padding 0 / Margin 0,8,0,0
//                    └ TextBox IsReadOnly / 透明底 / Muted 前景 / Consolas 11 /
//                      TextWrapping=NoWrap / 双向滚动条 / Padding 10
//   Row 20   : 间隔                                        → actionGap
//   Row Auto : StackPanel Orientation=Horizontal / 靠右     → actions
//                Button x:Name=OpenLogButton  MinWidth 132 / Margin 0,0,8,0
//                Button x:Name=CloseButton    MinWidth 96 / PrimaryButton / IsDefault
//
// ── 文案来源 Strings.zh-CN.xaml（逐字取用）────────────────────────────────
//   StartupErrorHeading  「iPhoneMirror 无法启动」
//   StartupErrorLogLabel 「诊断日志」
//   StartupErrorDetails  「错误详情」
//   StartupErrorOpenLog  「打开日志位置」
//   StartupErrorClose    「关闭」
//
// ── SummaryText 的两种取值（src/App/Services/StartupDiagnostics.cs:108-134）──
//   原生组件加载失败（DllNotFoundException / BadImageFormatException /
//   FileNotFoundException 任一在异常链上）：
//     「无法加载程序所需的原生组件。请重新安装最新的完整安装包；详细诊断已写入下方日志。」
//   其它：
//     「iPhoneMirror 启动时遇到错误。详细诊断已写入下方日志。」
//   原版按 LocalizationService.StartupCultureName 选 zh-HK / zh-CN / en-US；
//   鸿蒙侧固定走 zh-CN 一支（本工程只还原简体）。
//
// ── 平台替换（原版机制在鸿蒙没有对应物，逐条列出）──────────────────────────
//   1. StartupErrorWindow 在 xaml.cs 里**只接收已经写好的日志**（构造参数 logPath
//      由 App 侧 StartupDiagnostics.Write() 先落盘再传入）。鸿蒙侧没有
//      AppDomain.UnhandledException / TaskScheduler.UnobservedTaskException 这类
//      全局兜底，也拿不到宿主的启动异常对象，所以本窗口在 aboutToAppear 里
//      **自己把错误详情追加写进日志文件**（fileIo，真做），
//      保持「用户能看到一份可带走的诊断记录」这一原版目的不变。
//   2. 日志目录：原版 Environment.SpecialFolder.LocalApplicationData +
//      "iPhoneMirror/Logs/startup.log"（Windows: %LOCALAPPDATA%）。
//      鸿蒙改成应用沙箱 ctx.filesDir + "/iPhoneMirror/Logs/startup.log"。
//   3. OnOpenLogClick 走 `explorer.exe /select,"<path>"`。鸿蒙**没有**可以由应用
//      拉起并定位到沙箱文件的文件管理器接口 → 该按钮保留原版文案「打开日志位置」，
//      点击后不再假装打开了什么，而是把确切原因与完整路径写在状态行。
//   4. Expander 在 ArkUI 里没有对应控件 → 用「标题行 + Add20/Subtract20 图标」的
//      可折叠块局部实现，展开态与原版一致（圆角 12 卡片 + 只读等宽文本）。
//   5. 原版详情框 TextWrapping="NoWrap" + 横向滚动条。ArkUI 的 Scroll 只能单向
//      滚动，这里保留纵向滚动并改为自动换行（等宽字体用 'monospace' 近似
//      Consolas），错误堆栈的信息量不变。
//   6. 原版 CloseButton.IsDefault="True"（回车即关闭）。ArkUI 子窗口没有默认按钮
//      概念，此处不实现；两个按钮的排列与宽度保持原样。
//
// ── 不做假成功 ─────────────────────────────────────────────────────────────
//   「打开日志位置」点下去不会假装打开了文件管理器：写日志是**真做**，
//   定位是**做不到并明说**。

import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import {
  SubWindowShell, SubWindowHost, SecondaryButton, PrimaryButton, RoundedTextBox,
  SettingsSection, hint_text,
  SUBWINDOW_ROW_GAP, SUBWINDOW_ROW_GAP_NARROW, SubWindowSpec,
} from '../../common/SubWindow';
import { MUTED_TEXT, TEXT } from '../../common/Theme';
import { FluentSymbol } from '../../common/FluentIcon';

const TAG: string = 'im_startup_error';
const DOMAIN: number = 0x0100;

/** 窗口名 —— 用 XAML 的类名，window.findWindow 也用它。 */
export const WINDOW_NAME: string = 'StartupErrorWindow';
/** 页面路径。 */
export const PAGE_PATH: string = 'pages/windows/StartupErrorWindow';

/** 原版 internal StartupErrorWindow(Exception error, string logPath) 的入参键。 */
export const ARG_KEY_SUMMARY: string = 'im.startupError.summary';
export const ARG_KEY_DETAIL: string = 'im.startupError.detail';
export const ARG_KEY_LOG_PATH: string = 'im.startupError.logPath';
/** StartupDiagnostics.UserMessage 的分支标志（异常链里是否有原生组件加载失败）。 */
export const ARG_KEY_NATIVE_LOAD_FAILURE: string = 'im.startupError.nativeLoadFailure';

/** Strings（逐键标注）。 */
const S_TITLE: string = 'iPhoneMirror';                    // 原版硬编码的 Title，不是资源键
const S_HEADING: string = 'iPhoneMirror 无法启动';           // StartupErrorHeading
const S_LOG_LABEL: string = '诊断日志';                     // StartupErrorLogLabel
const S_DETAILS: string = '错误详情';                       // StartupErrorDetails
const S_OPEN_LOG: string = '打开日志位置';                   // StartupErrorOpenLog
const S_CLOSE: string = '关闭';                             // StartupErrorClose

/** StartupDiagnostics.UserMessage 的 zh-CN 两支（原文）。 */
const S_SUMMARY_NATIVE: string =
  '无法加载程序所需的原生组件。请重新安装最新的完整安装包；详细诊断已写入下方日志。';
const S_SUMMARY_GENERIC: string =
  'iPhoneMirror 启动时遇到错误。详细诊断已写入下方日志。';

/** 平台替换 3：点击「打开日志位置」后的确切原因。 */
const S_OPEN_LOG_REASON: string =
  '鸿蒙没有 explorer.exe /select 的等价能力，应用无法拉起文件管理器定位沙箱文件。' +
  '诊断日志已写入下列路径，可在系统「文件管理」应用中按此路径查看。';

/**
 * 原版 Exception → 用户摘要（StartupDiagnostics.UserMessage 的 zh-CN 一支）。
 * nativeLoadFailure=true 对应异常链里有 DllNotFoundException /
 * BadImageFormatException / FileNotFoundException。
 */
export function startup_error_summary(nativeLoadFailure: boolean): string {
  return nativeLoadFailure ? S_SUMMARY_NATIVE : S_SUMMARY_GENERIC;
}

/** 原版构造函数入参。 */
export interface StartupErrorArgs {
  /** 留空时按 nativeLoadFailure 取 StartupDiagnostics.UserMessage 的 zh-CN 文案。 */
  summary: string;
  /** 原版 DetailsTextBox.Text = error.ToString()。 */
  detail: string;
  /** 留空时取应用沙箱下的默认日志路径（见 default_log_path）。 */
  logPath: string;
  nativeLoadFailure: boolean;
}

/** 平台替换 2：Windows 的 %LOCALAPPDATA%\iPhoneMirror\Logs\startup.log 的鸿蒙对应物。 */
function default_log_path(ctx: common.Context): string {
  return ctx.filesDir + '/iPhoneMirror/Logs/startup.log';
}

/** 平台替换 1：把错误详情追加写进日志（真做）。返回是否写成功。 */
function append_log(path: string, text: string): boolean {
  // 原版 StartupDiagnostics.Write 写的条目格式：
  //   分隔线 / Timestamp (UTC) / Stage / Version / OS / Process architecture /
  //   Base directory / Native runtime inventory / Exception
  // 鸿蒙侧拿不到 OS 描述、进程架构、安装基目录与原生组件清单，
  // 保留能拿到的三行（分隔线 / 时间戳 / Stage）+ Exception。
  const entry: string = '============================================================\n'
    + 'Timestamp (UTC): ' + new Date().toISOString() + '\n'
    + 'Stage: startup\n'
    + 'Exception:\n' + text + '\n';
  try {
    const directory: string = path.substring(0, path.lastIndexOf('/'));
    if (directory.length > 0 && !fileIo.accessSync(directory)) {
      fileIo.mkdirSync(directory, true);
    }
    const file: fileIo.File = fileIo.openSync(path,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.APPEND | fileIo.OpenMode.READ_WRITE);
    try {
      fileIo.writeSync(file.fd, entry);
    } finally {
      fileIo.closeSync(file);
    }
    return true;
  } catch (error) {
    hilog.error(DOMAIN, TAG, 'append_log 失败: %{public}s', (error as BusinessError).message);
    return false;
  }
}

/** 按原版打开这个子窗口：先把构造参数放进 AppStorage，再开窗。 */
export function open_startup_error(ctx: common.Context, args: StartupErrorArgs): void {
  AppStorage.setOrCreate<string>(ARG_KEY_SUMMARY, args.summary);
  AppStorage.setOrCreate<string>(ARG_KEY_DETAIL, args.detail);
  const logPath: string = args.logPath.length > 0 ? args.logPath : default_log_path(ctx);
  AppStorage.setOrCreate<string>(ARG_KEY_LOG_PATH, logPath);
  AppStorage.setOrCreate<boolean>(ARG_KEY_NATIVE_LOAD_FAILURE, args.nativeLoadFailure);

  const spec: SubWindowSpec = {
    name: WINDOW_NAME,
    page: PAGE_PATH,
    title: S_TITLE,
    width: 680,
    height: 440,
    resizable: true,                // ResizeMode="CanResize"
    minWidth: 620,
    minHeight: 400,
    modal: true,                    // WindowStartupLocation="CenterScreen" 的启动错误框
  };
  SubWindowHost.open(ctx, spec).catch((error: BusinessError): void => {
    hilog.error(DOMAIN, TAG, '打开失败: %{public}s', error.message);
  });
}

/**
 * Expander 的替身（平台替换 4）：标题行 + 展开/折叠图标，展开后是原版那个
 * 圆角 12、Padding 0 的 SettingsSection 卡片。
 */
@Component
struct DetailsExpander {
  @Prop headerText: string = '';
  @Prop detailText: string = '';
  @State expanded: boolean = false;

  @Builder
  detail_area() {
    Scroll() {
      Text(this.detailText)
        .fontSize(11)
        .fontColor(MUTED_TEXT)
        .fontFamily('monospace')
        .width('100%');
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Auto)
    .align(Alignment.Top);
  }

  build() {
    Column() {
      // Expander.Header
      Row() {
        Text(this.headerText)
          .fontSize(12)
          .fontColor(TEXT)
          .layoutWeight(1);
        FluentSymbol({
          iconName: this.expanded ? 'Subtract20' : 'Add20',
          iconSize: 14,
          iconColor: MUTED_TEXT,
        });
      }
      .width('100%')
      .height(30)
      .onClick((): void => { this.expanded = !this.expanded; });

      if (this.expanded) {
        Column() {
          SettingsSection({ padH: 0, padV: 0, content: (): void => { this.detail_area(); } });
        }
        .width('100%')
        .height(150)
        .margin({ top: 8 })
        .borderRadius(12)
        .clip(true);
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .layoutWeight(1);
  }
}

@Entry
@Component
struct StartupErrorWindow {
  @State summaryText: string = '';
  @State detailText: string = '';
  @State logPathText: string = '';
  @State statusText: string = '';

  aboutToAppear(): void {
    const summary: string = AppStorage.get<string>(ARG_KEY_SUMMARY) ?? '';
    const detail: string = AppStorage.get<string>(ARG_KEY_DETAIL) ?? '';
    const nativeFailure: boolean = AppStorage.get<boolean>(ARG_KEY_NATIVE_LOAD_FAILURE) ?? false;
    this.summaryText = summary.length > 0 ? summary : startup_error_summary(nativeFailure);
    this.detailText = detail;

    const configured: string = AppStorage.get<string>(ARG_KEY_LOG_PATH) ?? '';
    this.logPathText = configured;
    // 平台替换 1：自己落盘，保证用户有一份可带走的诊断记录。
    const written: boolean = append_log(this.logPathText, this.detailText);
    if (!written) {
      this.statusText = '诊断日志写入失败，上方路径可能不可写。';
    }
  }

  /** 原版 OnOpenLogClick（平台替换 3）。 */
  private on_open_log(): void {
    this.statusText = S_OPEN_LOG_REASON;
  }

  /** 原版 OnCloseClick。 */
  private on_close(): void {
    SubWindowHost.close(WINDOW_NAME);
  }

  /** Row 2：SummaryText（FontSize 14 / Muted / Wrap）。 */
  @Builder
  notice() {
    Text(this.summaryText)
      .fontSize(14)
      .fontColor(MUTED_TEXT)
      .width('100%');
  }

  /** Row 4 + 6：日志路径块（固定高）+ 详情折叠块（吃掉剩余高度）。 */
  @Builder
  body() {
    Column() {
      // StackPanel：LogLabelText（FontSize 12 / Margin 0,0,0,7）+ LogPathTextBox
      Column() {
        Text(S_LOG_LABEL)
          .fontSize(12)
          .fontColor(TEXT);
        RoundedTextBox({
          text: this.logPathText,
          readOnly: true,
          boxHeight: 38,
        })
          .margin({ top: 7 });
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%');

      Column().height(SUBWINDOW_ROW_GAP_NARROW);   // 行 5 = 14

      DetailsExpander({ headerText: S_DETAILS, detailText: this.detailText });

      if (this.statusText.length > 0) {
        Column() {
          hint_text(this.statusText);
        }
        .width('100%')
        .margin({ top: 10 });
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  actions() {
    SecondaryButton({
      label: S_OPEN_LOG,
      minButtonWidth: 132,
      on_action: (): void => { this.on_open_log(); },
    })
      .margin({ right: 8 });
    PrimaryButton({
      label: S_CLOSE,
      minButtonWidth: 96,
      on_action: (): void => { this.on_close(); },
    });
  }

  build() {
    Column() {
      SubWindowShell({
      windowName: WINDOW_NAME,
      title: S_HEADING,
      subtitle: '',                 // 原版表头只有 HeadingText，没有 SubWindowSubtitle
      gap: SUBWINDOW_ROW_GAP,       // 行 1 = 16
      hasNotice: true,
      noticeGap: 20,                // 行 3 = 20
      hasFooter: false,
      hasActions: true,
      actionGap: 20,                // 行 7 = 20
      actionsSplit: false,          // 两个按钮都靠右
      notice: (): void => { this.notice(); },
      content: (): void => { this.body(); },
      actions: (): void => { this.actions(); },
    });
    }
  }
}
