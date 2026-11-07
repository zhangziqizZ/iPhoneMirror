// AboutWindow.ets —— 子窗口：关于（应用信息 / 更新设置 / 诊断）
//
// 逐项对照上游 src/App/Windows/AboutWindow.xaml（189 行）
//              src/App/Windows/AboutWindow.xaml.cs（241 行）
//  上游 main（1.8.4）与 linux-port（1.8.1）两份 .xaml / .xaml.cs **逐行相同**，
//  本文件按 main 版还原。
//
// ── 窗口属性（XAML 根元素 <ui:FluentWindow> 那一行）──────────────────────────
//   Title="{DynamicResource AboutTitle}"   → 「关于」
//   Width="760" Height="600" MinWidth="700" MinHeight="520"
//   WindowStartupLocation="CenterOwner"    → SubWindowHost.open 里算居中
//   ResizeMode="CanResize"                 → resizable: true
//   ExtendsContentIntoTitleBar="True"      → decorEnabled: false + 自绘表头
//   WindowBackdropType="Mica" / WindowCornerPreference="Round" → 由系统窗口负责
//   Background="{DynamicResource AppBackgroundBrush}"
//   AutomationProperties.AutomationId="AboutWindow"
//
// ── 行定义（3 行）＋ TabControl（3 个 TabItem）───────────────────────────────
//   Row Auto : Grid Style=SubWindowHeader（MinHeight 44, WindowDragBehavior）
//                StackPanel Margin="0,0,48,0"
//                  TextBlock AboutTitle    / Style=SubWindowTitle
//                  TextBlock AboutSubtitle / Style=SubWindowSubtitle
//                Button SubWindowCloseButton + SymbolIcon Dismiss20/18（Click=OnCloseClick）
//   Row 16   : 间隔                                        → shell 的 gap
//   Row *    : TabControl Style=SubWindowTabControl         → content（layoutWeight 1）
//              ├ TabItem Header=关于
//              ├ TabItem Header=更新设置
//              └ TabItem Header=诊断
//   ★ 原版**没有**底部按钮条：四个操作按钮都在「关于」页里，
//     所以本窗口 hasActions = false。
//
// ── TabItem 1「关于」（ScrollViewer + StackPanel Margin 4,14,0,0）────────────
//   Grid：Col 88（Border 68×68 圆角 14 / PanelAltBrush 底 / BorderBrush 边，
//                内含 Image Assets/iPhoneMirror.png 52×52）
//         Col *（TextBlock "iPhoneMirror" SubWindowTitle
//                TextBlock VersionText Muted 12 SemiBold Margin 0,4,0,0
//                TextBlock AboutDescription SubWindowSubtitle Margin 0,6,0,0）
//   Border Height 1 / BorderSoftBrush / Margin 0,20
//   TextBlock UpdateStatusTitle / SubWindowSectionTitle
//   TextBlock UpdateStatus / SubWindowSubtitle / Margin 0,6,0,14
//   WrapPanel：Button「检查更新」  MinWidth 138（AboutCheckUpdatesButtonStyle）
//              Button「GitHub」     MinWidth 96
//              Button「更新日志」   MinWidth 108
//              Button「许可证信息」 MinWidth 118
//              四个都 Margin="0,0,8,8"
//
// ── TabItem 2「更新设置」─────────────────────────────────────────────────────
//   TextBlock UpdateSettingsTitle / SubWindowSectionTitle
//   TextBlock UpdateSettingsDescription / SubWindowSubtitle / Margin 0,6,0,18
//   CheckBox CheckOnStartup            Margin 0,0,0,14
//   CheckBox AutoDownloadUpdates       Margin 0,0,0,14
//   CheckBox AllowUpdateMirrorFallback Margin 0,0,0,14（ToolTip=…Description）
//   CheckBox NotifyStableReleases      Margin 0,0,0,14
//   CheckBox NotifyPrereleaseReleases
//
// ── TabItem 3「诊断」─────────────────────────────────────────────────────────
//   TextBlock DiagnosticsTitle / SubWindowSectionTitle
//   TextBlock DiagnosticsDescription / SubWindowSubtitle / Margin 0,6,0,18
//   TextBlock DiagnosticsLocation / SubWindowSectionTitle
//   TextBox DiagnosticPath（OneWay / IsReadOnly / Margin 0,9,0,14 / Padding 10,7 / Wrap）
//   TextBlock DiagnosticStatus / SubWindowSubtitle / Margin 0,0,0,14
//   WrapPanel：Button「打开日志目录」MinWidth 126（PrimaryButton）
//              Button「清理日志和更新缓存」MinWidth 126
//              两个都 Margin="0,0,8,8"
//   Border Height 1 / BorderSoftBrush / Margin 0,12,0,18
//   Grid：TextBlock LiveLogHeader（左，SubWindowSectionTitle）
//         Button「清空视图」（右，Padding 10,5 / MinHeight 32 / FontSize 11）
//   TextBlock LogPathDisplay（Consolas 10 / Muted / 单行省略 / Margin 0,10,0,7）
//   Border PreviewChromeBrush 底 / BorderBrush 边 / 圆角 10 / ClipToBounds
//     └ TextBox LiveLogTextBox（IsReadOnly / Consolas 10 / Height 180 / Padding 10 /
//               不换行 / 纵向滚动 / TextChanged=OnLiveLogTextChanged 自动滚到底）
//
// ── 文案来源 Strings.zh-CN.xaml（逐字取用）────────────────────────────────
//   AboutTitle                        「关于」
//   AboutSubtitle                     「应用信息、更新和诊断」
//   AboutDescription                  「低延迟 iPhone 屏幕投射、录制、直播与虚拟摄像头。」
//   UpdateStatusTitle                 「更新状态」
//   UpdateStatusReady                 「可随时检查 GitHub Release 更新。」
//   CheckForUpdates                   「检查更新」
//   Changelog                         「更新日志」
//   LicenseInformation                「许可证信息」
//   UpdateSettingsTitle               「更新设置」
//   UpdateSettingsDescription         「控制后台检查、自动下载、镜像加速和发布通道。」
//   CheckOnStartup                    「启动时检查更新」
//   AutoDownloadUpdates               「发现更新后自动开始下载」
//   AllowUpdateMirrorFallback         「自动选择最快更新下载线路」
//   AllowUpdateMirrorFallbackDescription
//                                     「测试 GitHub 和全部镜像，仅对可达线路进行 256 KB
//                                       下载测速；下载内容仍必须通过官方发布摘要中的
//                                       SHA-256 校验。」
//   NotifyStableReleases              「提醒正式版更新」
//   NotifyPrereleaseReleases          「提醒 Beta 预览版更新」
//   DiagnosticsTitle                  「诊断」
//   DiagnosticsDescription            「应用错误、投屏核心和更新流程会写入本地日志，
//                                       便于排查其他电脑上的问题。」
//   DiagnosticsLocation               「日志位置」
//   DiagnosticsRetentionSummary       「日志自动限制为单文件 8–16 MB，并清理超过 14 天
//                                       或总量超过 64 MB 的旧文件。」
//   OpenLogs                          「打开日志目录」
//   CleanLogs                         「清理日志和更新缓存」
//   DiagnosticsCleanedFormat          「清理完成：删除 {0} 个文件，释放 {1}；{2} 个正在
//                                       使用或无权限的文件已跳过。」
//   DiagnosticsCleanupFailedFormat    「清理失败：{0}」
//   LiveLogHeader                     「实时日志  ·  Ctrl+L」
//   ClearView                         「清空视图」
//   LogViewCleared                    「日志视图已清空（不会删除磁盘日志）」
//   CheckingForUpdates                「正在连接更新服务检查新版本…」
//   AlreadyUpToDate                   「当前已是所选发布通道的最新版本。」
//   UpdateAvailableFormat             「发现新版本 {0}。」
//   UpdateCheckCancelled              「更新检查已取消。」
//   UpdateCheckFailedFormat           「无法检查更新：{0}」
//   UpdateNetworkUnavailable          「所有更新线路暂时不可用，请检查网络连接后重试。」
//   UpdateRequestTimedOut             「连接更新服务超时，请稍后重试。」
//
// ── 平台替换（原版机制在鸿蒙没有对应物，逐条列出）──────────────────────────
//   1. 【VersionText】原版 VersionManager.DisplayVersion 读程序集
//      AssemblyInformationalVersionAttribute。鸿蒙改读
//      bundleManager.getBundleInfoForSelf().versionName（真做，前面加 v）。
//   2. 【应用图标】原版是 pack://application:,,,/Assets/iPhoneMirror.png（52×52）。
//      鸿蒙工程资源里没有同名位图 → 用已有的 FluentSymbol('PhoneDesktop24') 占住
//      同样的 68×68 圆角 14 容器，尺寸与配色不变。
//   3. 【检查更新】原版 _app.CheckForUpdatesAsync(manual: true) 打 GitHub Releases
//      API（含镜像测速与 SemanticVersion 比较）。鸿蒙版尚未接入该检查管线 →
//      「检查更新」按钮保留原版文案，点击后**不假装检查成功**，而是明写
//      「鸿蒙版尚未接入 GitHub Release 检查」，并提示可点「更新日志」直接看发布页。
//   4. 【GitHub / 更新日志 / 许可证】原版 Process.Start(UseShellExecute=true)，
//      本地 CHANGELOG.md / LICENSE 存在时优先用 explorer 打开。鸿蒙侧：
//        · 三个按钮都改为用系统浏览器打开发布页/仓库页（startAbility +
//          ACTION_VIEW，真做）；
//        · 原版「本地文件优先、回退到 URL」的分支在鸿蒙不成立（应用安装包内没有
//          随包 CHANGELOG/LICENSE，且没有 explorer），一律走 URL。
//   5. 【打开日志目录】原版 Open(DiagnosticLogger.DirectoryPath) → explorer.exe。
//      鸿蒙**没有**可由应用拉起的文件管理器接口 → 按钮保留原版文案，点击后
//      明写原因，并把完整沙箱路径保留在上方「日志位置」文本框里。
//   6. 【清理日志和更新缓存】原版 DiagnosticLogger.Cleanup(includeActiveLogs:true)
//      + GitHubReleaseClient.CleanupOldDownloads(includeCompleted:true)。
//      鸿蒙侧**真做**前半段（诊断日志目录），按原版口径统计
//      「删除文件数 / 释放字节 / 跳过文件数」并用 DiagnosticsCleanedFormat 展示；
//      更新缓存目录在鸿蒙侧不存在（见 3），这部分恒为 0，脚注里明说。
//   7. 【实时日志】原版 MainViewModel.LogText 由 DiagnosticLogger 供数、500 ms
//      轮询（DispatcherTimer）。鸿蒙侧**真做**：读取诊断日志文件尾部，
//      同样 500 ms 刷新一次（setInterval / clearInterval），
//      字体用 'monospace' 近似 Consolas。
//   8. 【清空视图】原版 ClearLogCommand 只清视图不动磁盘（LogViewCleared 已写明）。
//      鸿蒙侧一致：只把视图文本清空，不删除任何文件。
//   9. 【更新设置的持久化】原版写 %LOCALAPPDATA%\iPhoneMirror\settings.json
//      （UpdateSettingsStore，带 tmp + File.Move 的原子写）。鸿蒙侧改存
//      AppStorage（见 SETTINGS_KEY_*），不新增文件写入逻辑——与本项目其它
//      子窗口（AdvancedSettingsWindow）的通道一致。
//  10. 【TabControl】ArkUI 有 Tabs/TabContent，可一一对应原版的三个 TabItem；
//      页签文字与原版 Header 相同。
//  11. 【ShowDiagnostics()】原版 AboutTabs.SelectedIndex = 2。鸿蒙侧由
//      open_about(ctx, tabIndex) 指定初始页（2 = 诊断页）。
//
// ── 不做假成功 ─────────────────────────────────────────────────────────────
//   「检查更新」不会回报「已是最新」（那是假成功）；能真做的只有「打开浏览器」、
//   「写/清/读日志」与「读应用版本号」，其余全部明写原因。

import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { bundleManager, Want } from '@kit.AbilityKit';
import { SegmentButton, SegmentButtonItemTuple, SegmentButtonOptions, UIContext, uiMaterial } from '@kit.ArkUI';
import { fileIo, ReadTextOptions } from '@kit.CoreFileKit';
import {
  SubWindowShell, SubWindowHost, SecondaryButton, PrimaryButton, RoundedTextBox,
  section_title, hint_text,
  SUBWINDOW_ROW_GAP, SubWindowSpec,
} from '../../common/SubWindow';
import {
  ACCENT, DARK, ON_ACCENT, PRIMARY_ACTION,
} from '../../common/Theme';
import { FluentSymbol } from '../../common/FluentIcon';
import { DEVELOPER_MODE_KEY, GLOW_ENABLED_KEY, GLOW_DEGRADED_KEY } from '../../common/WindowServices';
import { save_developer_mode_preference } from '../../common/AppPreferences';
import { t } from '../../common/i18n';
import { open_first_run } from './FirstRunSetupWindow';
import {
  UPDATE_OUTCOME_FAILED, UPDATE_OUTCOME_HAS_UPDATE, UPDATE_OUTCOME_NO_RELEASE,
  UPDATE_OUTCOME_UP_TO_DATE, UpdateCheckResult, check_latest_release,
} from '../../common/GithubReleaseCheck';

const TAG: string = 'im_about';
const DOMAIN: number = 0x0100;

/** 窗口名 —— 用 XAML 的类名，window.findWindow 也用它。 */
export const WINDOW_NAME: string = 'AboutWindow';
/** 页面路径。 */
export const PAGE_PATH: string = 'pages/windows/AboutWindow';

/** 原版 internal AboutWindow(App app, MainViewModel vm) + ShowDiagnostics() 的入参键。 */
export const ARG_KEY_TAB_INDEX: string = 'im.about.tabIndex';

/** 原版 UpdateSettings 五个开关的持久化键（平台替换 9）。 */
export const SETTINGS_KEY_CHECK_ON_STARTUP: string = 'im.updateSettings.checkOnStartup';
export const SETTINGS_KEY_AUTO_DOWNLOAD: string = 'im.updateSettings.autoDownload';
export const SETTINGS_KEY_ALLOW_MIRROR: string = 'im.updateSettings.allowMirrorFallback';
export const SETTINGS_KEY_NOTIFY_STABLE: string = 'im.updateSettings.notifyStableReleases';
export const SETTINGS_KEY_NOTIFY_PRERELEASE: string = 'im.updateSettings.notifyPrereleaseReleases';

/** 原版 GitHubReleaseClient 的三个链接（xaml.cs 里的字面量）。 */
const GITHUB_REPO_URL: string = 'https://github.com/zhangziqizZ/iPhoneMirror';
const GITHUB_RELEASES_URL: string = 'https://github.com/zhangziqizZ/iPhoneMirror/releases';
const GITHUB_LICENSE_URL: string = 'https://github.com/zhangziqizZ/iPhoneMirror/blob/main/LICENSE';

/** Strings（逐键标注）。 */
const S_TITLE = (): string => t('关于');                                    // AboutTitle
const S_SUBTITLE = (): string => t('应用信息、更新和诊断');// AboutSubtitle
const S_DESCRIPTION = (): string => t('低延迟 iPhone 屏幕投射、录制、直播与虚拟摄像头。');// AboutDescription
/**
 * 一个版本的更新记录（关于页「版本更新」展示的**最新一版**）。
 *
 * 为什么在代码里存一份而不是读文件：鸿蒙 App 安装包里没有随包可读的
 * CHANGELOG.md（也没有 explorer 打开本地文件），所以关于页直接内嵌这份常量。
 * **每次改版本号时，必须同步更新这里和 CHANGELOG.md**，二者内容一致；
 * 版本号本身只认 AppScope/app.json5 的 versionName（经 bundleManager 读）。
 */
export class ChangelogRelease {
  /** 版本号（与 app.json5 的 versionName 一致）。 */
  readonly version: string;
  /** 该版本的发布日期（YYYY-MM-DD）。 */
  readonly date: string;
  /** 该版本的变更条目（与 CHANGELOG.md 该节逐条对应）。 */
  readonly items: string[];

  constructor(version: string, date: string, items: string[]) {
    this.version = version;
    this.date = date;
    this.items = items;
  }
}

/**
 * 最新版本的变更说明（CHANGELOG.md 顶节的镜像）。
 *
 * ★ 应用内**只展示最新一版**（用户 2026-11-07 要求）：不展示历史更新。
 *   历史逐版记录留在仓库的 CHANGELOG.md 与 docs/CHANGELOG-archive.md，
 *   应用内通过「更新日志」按钮跳 GitHub Releases 查看 —— 那里本来就是按
 *   版本分的完整档案，比在应用里摊一长列表更清楚。
 *
 * 发新版本时**只替换这一个常量**（版本号、日期、条目整体换成新版），
 * 旧版条目不要往这里堆。
 */
const LATEST_RELEASE: ChangelogRelease = new ChangelogRelease('1.1.1', '2026-11-07', [
    '新增：iOS 有线文件浏览（AFC）—— 侧边栏「文件」入口直连 iPhone 内部存储，支持面包屑路径、目录进退、下载到沙箱 Downloads、删除、新建目录、重命名。链路自己实现（上游 Windows 版走 Apple AMDS 本地 socket，没有这条）',
    '修复：usbmux 隧道被设备 RST —— 伪 TCP 头的 th_off 是 4 bit 数据偏移、占 tcphdr 高 4 位，20 字节头的正确编码是 0x50 而我们写的是 0x05，设备按高 4 位算出"头长 = 0"判为坏包直接 RST。已用 static_assert 把这条不变量钉死',
    '修复：设备 SYN|ACK 的 seq 可能不是 0，确认号改为按设备 seq 计算（收到 SYN|ACK 时 tx_ack = seq + 1，收数据后 tx_ack = seq + len(payload)），不再假定设备 seq 为 0',
    '新增：USB 第二通道 —— USB DDK 需要 ACCESS_DDK_USB 进签名 profile 的 ACL，外部安装拿不到；现在走 usbManager.requestRight 弹一次设备级授权窗（不查 ACL），getFileDescriptor 拿标准 usbfs 节点的 fd，native 直接在 fd 上做 bulk / 控制传输，授权一次长期有效',
    '新增：认领 USB 接口后调用 clear_halt（USBDEVFS_CLEAR_HALT）重置主机侧 DATA toggle，避免重开链路时第一个包被静默丢弃',
    '新增：收包按设备报的 th_off 切载荷（不再写死 20 字节），并按 (sport, dport) 校验连接配对 —— 设备同时开着别的连接时，串台的报文不再被误判成"本隧道被重置"',
    '修复：真机上点首启向导弹 401 创建失败 —— 根因不是 createSubWindow 参数，而是页面没注册进 main_pages.json，setUIContent 在 LoadContent 阶段找不到路由。补注册 4 个漏掉的页面（首启向导 / 键盘映射编辑器 / 键盘映射 / 窗口风格设置），并给子窗口加 401 分级降级链',
    '移除：安卓相关代码与本地终端 —— 删掉 ADB 探测与匹配常量、侧边栏「终端」入口、终端窗口页面与六个本地 shell native 导出，HAP 内 ADB / DeX / Miracast / 三星 关键字 0 命中；「文件」入口（iOS AFC）保留',
    '新增：首启向导窗口、繁体中文（台湾）语言档、窗口风格设置窗口（独立预览窗口透明度 + 悬停不透明）、键盘映射管理器与编辑器向导、独立预览窗口改华为多屏协同风格（画面铺满 + 上下毛玻璃浮层栏）',
    '修复：42 个 ArkTS 编译错误已清，hvigor assembleHap BUILD SUCCESSFUL',
    '修复：i18n 表内重复键（"取消"与"下一步"在 ZH2EN/ZH2HK 各重复定义，前者被后者静默覆盖）',
    '修复（原生）：USB 批量读按 memmap 实际容量裁剪长度 —— 驱动报出异常大的 transferedLength 时会越界读',
    '修复（原生）：音频渲染器 set_volume/set_enabled 裸读句柄与 stop() 的 Release 并发即 UAF；帧可用通知与"持 capture_mutex 析构解码器"构成 ABBA —— 两处都改为锁内只摘指针、锁外销毁',
    '依赖：新增 OpenSSL 3（libssloh.so.3 / libcryptooh.so.3）随 HAP 分发 —— AFC 的两条 TLS 会话需要，NDK 不带 OpenSSL',
  ]);

/** 「最新」标记文案（标在最新版本的版本行上）。 */
const S_LATEST_TAG = (): string => t('最新');
/** 「版本更新」区块标题（只展示最新一版的更新内容）。 */
const S_WHATS_NEW = (): string => t('版本更新');

/**
 * 最新一版的变更内容（「版本更新」区块的唯一一块）。
 *
 * ★ 只展示最新版本（用户 2026-11-07 要求）：应用内不再摊历史更新，
 *   所以这里不需要「按版本分组 + 折叠/展开」那套交互 —— 只有一块内容，
 *   直接铺开显示即可。
 */
@Component
struct ChangelogGroup {
  @Prop version: string = '';
  @Prop date: string = '';
  @Prop items: string[] = [];

  build(): void {
    Column() {
      Row() {
        Text(this.version)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(DARK.TEXT);
        Text(this.date)
          .fontSize(11)
          .fontColor(DARK.MUTED_TEXT)
          .margin({ left: 8, top: 1 });
        Text(S_LATEST_TAG())
          .fontSize(10)
          .fontColor(ON_ACCENT)   // 亮蓝 ACCENT 底上的文字走 ON_ACCENT token（Apple 口径：亮底深字）
          .backgroundColor(ACCENT)
          .borderRadius(4)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .margin({ left: 8 });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 11, bottom: 11 });

      ForEach(this.items, (item: string): void => {
        Row() {
          Text('•')
            .fontSize(12)
            .fontColor(ACCENT)
            .margin({ right: 8 });
          Text(item)
            .fontSize(12)
            .fontColor(DARK.MUTED_TEXT)
            .lineHeight(18)
            .layoutWeight(1);
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .margin({ bottom: 4 });
      }, (item: string): string => item);
    }
    .width('100%');
  }
}

const S_UPDATE_STATUS_TITLE = (): string => t('更新状态');// UpdateStatusTitle
const S_UPDATE_STATUS_READY = (): string => t('可随时检查 GitHub Release 更新。');// UpdateStatusReady
const S_CHECK_UPDATES = (): string => t('检查更新');// CheckForUpdates
const S_CHANGELOG = (): string => t('更新日志');// Changelog
const S_LICENSE = (): string => t('许可证信息');// LicenseInformation
const S_TAB_ABOUT = (): string => t('关于');// AboutTitle（TabItem Header）

/** 页签「无悬停」哨兵值（原版 SubWindowTabItem 的 IsMouseOver 触发器需要区分未悬停）。 */
const NAV_TAB_NONE: number = -1;
const S_TAB_UPDATE_SETTINGS = (): string => t('更新设置');// UpdateSettingsTitle
const S_TAB_DIAGNOSTICS = (): string => t('诊断');// DiagnosticsTitle
const S_UPDATE_SETTINGS_TITLE = (): string => t('更新设置');// UpdateSettingsTitle
const S_UPDATE_SETTINGS_DESC = (): string => t('控制后台检查、自动下载、镜像加速和发布通道。');// UpdateSettingsDescription
const S_CHECK_ON_STARTUP = (): string => t('启动时检查更新');// CheckOnStartup
const S_AUTO_DOWNLOAD = (): string => t('发现更新后自动开始下载');// AutoDownloadUpdates
const S_ALLOW_MIRROR = (): string => t('自动选择最快更新下载线路');// AllowUpdateMirrorFallback
const S_ALLOW_MIRROR_DESC: string =
  '测试 GitHub 和全部镜像，仅对可达线路进行 256 KB 下载测速；下载内容仍必须通过官方' +
  '发布摘要中的 SHA-256 校验。';                                     // AllowUpdateMirrorFallbackDescription
const S_NOTIFY_STABLE = (): string => t('提醒正式版更新');// NotifyStableReleases
const S_NOTIFY_PRERELEASE = (): string => t('提醒 Beta 预览版更新');// NotifyPrereleaseReleases
const S_DIAGNOSTICS_TITLE = (): string => t('诊断');// DiagnosticsTitle
const S_DIAGNOSTICS_DESC: string =
  '应用错误、投屏核心和更新流程会写入本地日志，便于排查其他电脑上的问题。';  // DiagnosticsDescription
const S_DIAGNOSTICS_LOCATION = (): string => t('日志位置');// DiagnosticsLocation
const S_RETENTION: string =
  '日志自动限制为单文件 8–16 MB，并清理超过 14 天或总量超过 64 MB 的旧文件。';  // DiagnosticsRetentionSummary
const S_OPEN_LOGS = (): string => t('打开日志目录');// OpenLogs
const S_CLEAN_LOGS = (): string => t('清理日志和更新缓存');// CleanLogs
const S_LIVE_LOG = (): string => t('实时日志  ·  Ctrl+L');// LiveLogHeader
const S_CLEAR_VIEW = (): string => t('清空视图');// ClearView
const S_LOG_VIEW_CLEARED = (): string => t('日志视图已清空（不会删除磁盘日志）');// LogViewCleared
/** DiagnosticsCleanedFormat：{0} 文件数 / {1} 释放体积 / {2} 跳过数。 */
const S_CLEANED = (): string => t('清理完成：删除 %d 个文件，释放 %s；%d 个正在使用或无权限的文件已跳过。');
/** DiagnosticsCleanupFailedFormat：{0} = 错误。 */
const S_CLEAN_FAILED = (): string => t('清理失败：%s');

/**
 * 更新状态那一行的默认文案（还没查过 / 查完之后也能回到这句的含义）。
 *
 * 说明历史：1.0.45 之前这里写的是「鸿蒙版尚未接入 GitHub Release 检查」，
 * 因为当时点按钮确实什么都查不到 —— 不假装检查成功是对的，但用户点它永远
 * 得不到结果。现在它是真检查，默认文案改成"可随时点"。
 */
const S_UPDATE_STATUS_READY_ONLINE: string =
  '点「检查更新」查询 GitHub Releases API 的最新 tag，并与本机版本比较。';
const S_UPD_CHECKING = (): string => t('正在查询 GitHub Releases…');
const S_UPD_CHECKING_LABEL = (): string => t('检查中…');
const S_UPD_FAILED_PREFIX = (): string => t('无法检查更新：');
const S_UPD_NEW_FOUND = (): string => t('发现新版本');
const S_UPD_PREVIEW = (): string => t('预览版');
const S_UPD_GO_DOWNLOAD = (): string => t('点「更新日志」去 GitHub 下载。');
const S_UPD_UP_TO_DATE = (): string => t('已是最新：本机 ');
const S_UPD_GITHUB_LATEST = (): string => t('，GitHub 最新 ');
const S_UPD_REPO = (): string => t('仓库 ');
const S_UPD_NO_RELEASE = (): string => t(' 还没有发布任何 Release');
const S_UPD_LOCAL = (): string => t('（本机 ');

/** 平台替换 5：点「打开日志目录」后的确切原因。 */
const S_OPEN_LOGS_REASON: string =
  '鸿蒙没有 explorer.exe 的等价能力，应用无法拉起文件管理器打开沙箱目录。' +
  '完整路径见上方「日志位置」。';
/** 平台替换 6：更新缓存那部分恒为 0 的说明。 */
const S_NO_UPDATE_CACHE: string =
  '注：鸿蒙版没有「更新下载缓存」目录（见文件头的平台替换 3），清理只覆盖诊断日志。';

/** 原版 internal void ShowDiagnostics() → AboutTabs.SelectedIndex = 2。 */
export const ABOUT_TAB_INDEX: number = 0;
export const UPDATE_SETTINGS_TAB_INDEX: number = 1;
export const DIAGNOSTICS_TAB_INDEX: number = 2;

/** 按原版打开这个子窗口。tabIndex 见 *_TAB_INDEX（ShowDiagnostics 传 2）。 */
export function open_about(ctx: common.Context, tabIndex: number): void {
  host_ctx = ctx;
  AppStorage.setOrCreate<number>(ARG_KEY_TAB_INDEX, tabIndex);

  const spec: SubWindowSpec = {
    name: WINDOW_NAME,
    page: PAGE_PATH,
    title: S_TITLE(),
    width: 760,
    height: 600,
    resizable: true,                // ResizeMode="CanResize"
    minWidth: 700,
    minHeight: 520,
    modal: true,                    // WindowStartupLocation="CenterOwner"
  };
  // ★ 这个 .catch 里**不允许再抛异常**：Promise 的拒绝回调抛出的错误没人接管，
  //   会被运行时当成未捕获异常，直接把应用结束掉（表现为"点一下闪退"）。
  //   而拒绝原因可能是 undefined（不是每个实现都给 Error 对象），
  //   所以取 .message 之前必须先判空。
  SubWindowHost.open(ctx, spec).catch((error: BusinessError): void => {
    const failure: BusinessError = error as BusinessError;
    const reason: string = failure !== undefined && failure !== null && failure.message !== undefined
      ? failure.message : '未知原因';
    hilog.error(DOMAIN, TAG, '打开失败: %{public}s', reason);
  });
}

/**
 * 开窗时记下的宿主 Context。
 * 原版子窗口是进程内对象，天然拿得到 App；鸿蒙侧页面拿不到构造参数，
 * 所以在 open_about() 里记一份（与 pending_request 同一个思路）。
 *
 * ⚠ 这只是一条**快路**，不能当成唯一来源：子窗口页面真正可用的是
 *   `this.getUIContext().getHostContext()`（见 AboutWindow.ability_context()，
 *   Index.ets 的 start_window_drag 用的也是这个）。页面里一律走那条路，
 *   模块级的 ui_context() 只服务确实拿不到 UI 实例的地方（open_url）。
 */
let host_ctx: common.Context | null = null;

/**
 * 取 UIAbility 上下文（模块级兜底）。
 *
 * 历史坑：这里原来写的是 `host_ctx !== null ? host_ctx : getContext()`，然后直接
 * `ui_context().filesDir` —— 一旦两条路都拿不到（页面级函数里调无参 getContext()
 * 在新 SDK 上已废弃），`.filesDir` 就是对 undefined 取属性，抛出的 TypeError 若
 * 发生在 aboutToAppear / setInterval 回调里没有任何人接管，**整个应用会被结束**。
 * 所以这里改成"拿不到就返回 null"，由调用方决定怎么退让。
 */
function resolve_context(uic: UIContext | null): common.Context | null {
  if (host_ctx !== null) {
    return host_ctx;
  }
  if (uic !== null) {
    const hosted: common.Context | undefined = uic.getHostContext();
    if (hosted !== undefined && hosted !== null) {
      return hosted;
    }
  }
  // 无参 getContext() 是已废弃的兜底写法，某些版本上可能直接抛错 —— 包一层。
  try {
    const legacy: common.Context | undefined = getContext() as common.Context;
    return legacy !== undefined && legacy !== null ? legacy : null;
  } catch (error) {
    hilog.warn(DOMAIN, TAG, 'getContext() 不可用: %{public}s', (error as BusinessError).message);
    return null;
  }
}

/** 平台替换 4：真做 —— 用系统浏览器打开 URL。 */
function open_url(url: string): boolean {
  const ctx: common.Context | null = resolve_context(null);
  if (ctx === null) {
    hilog.error(DOMAIN, TAG, 'open_url: 取不到 Ability 上下文');
    return false;
  }
  try {
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: url,
    };
    (ctx as common.UIAbilityContext).startAbility(want).catch((error: BusinessError): void => {
      hilog.error(DOMAIN, TAG, 'startAbility 失败: %{public}s', error.message);
    });
    return true;
  } catch (error) {
    hilog.error(DOMAIN, TAG, 'open_url 失败: %{public}s', (error as BusinessError).message);
    return false;
  }
}

/**
 * 平台替换 2/7：诊断日志目录（Windows: %LOCALAPPDATA%\iPhoneMirror\Logs）。
 * 取不到上下文时返回空串 —— 调用方按"没有日志目录"处理，绝不抛异常。
 */
function diagnostic_dir(ctx: common.Context | null): string {
  if (ctx === null) {
    return '';
  }
  const files: string = (ctx as common.UIAbilityContext).filesDir;
  return files !== undefined ? files + '/PhoneMirror/Logs' : '';
}

/** 原版 FormatBytes(long bytes)。 */
function format_bytes(bytes: number): string {
  if (bytes >= 1024 * 1024) {
    return (bytes / 1024 / 1024).toFixed(1) + ' MB';
  }
  if (bytes >= 1024) {
    return Math.round(bytes / 1024).toString() + ' KB';
  }
  return bytes.toString() + ' B';
}

/** 原版 CleanupResult：删除文件数 / 删除字节 / 跳过文件数。 */
class CleanupResult {
  deletedFiles: number = 0;
  deletedBytes: number = 0;
  skippedFiles: number = 0;
}

/** 平台替换 6：真做 —— 清掉诊断日志目录里的文件。 */
function cleanup_logs(ctx: common.Context | null): CleanupResult {
  const result: CleanupResult = new CleanupResult();
  const directory: string = diagnostic_dir(ctx);
  if (directory.length === 0) {
    return result;
  }
  let names: string[] = [];
  try {
    if (!fileIo.accessSync(directory)) {
      return result;
    }
    names = fileIo.listFileSync(directory);
  } catch (error) {
    hilog.error(DOMAIN, TAG, 'listFileSync 失败: %{public}s', (error as BusinessError).message);
    return result;
  }
  for (const name of names) {
    const path: string = directory + '/' + name;
    try {
      result.deletedBytes += fileIo.statSync(path).size;
      fileIo.unlinkSync(path);
      result.deletedFiles += 1;
    } catch (error) {
      // 原版口径：正在使用或无权限的文件计入 skipped。
      result.skippedFiles += 1;
      hilog.warn(DOMAIN, TAG, '跳过 %{public}s: %{public}s', name,
        (error as BusinessError).message);
    }
  }
  return result;
}

/** 日志面板一次最多读多少**字节**（尾部）。文件再大也只读这么多。 */
const LOG_TAIL_BYTES: number = 16 * 1024;
/** 日志面板最终显示多少**字符**（对应原版 TextBox 高度 180 的可视量）。 */
const LOG_TAIL_CHARS: number = 8000;

/**
 * 平台替换 7：真做 —— 读诊断日志目录里最新一个日志文件的尾部。
 *
 * ★ 整个函数体必须在 try 内：它由 `setInterval` 每 500 ms 调一次，而
 *   **定时器回调里抛出的异常没有任何人接管**，会被运行时当成未捕获异常
 *   直接结束应用。所以连"取目录"这一步也要放在 try 里（原实现把它放在了 try 外面）。
 */
function read_log_tail(ctx: common.Context | null): string {
  try {
    const directory: string = diagnostic_dir(ctx);
    if (directory.length === 0) {
      return '';
    }
    if (!fileIo.accessSync(directory)) {
      return '';
    }
    const names: string[] = fileIo.listFileSync(directory);
    if (names.length === 0) {
      return '';
    }
    // 原生 Core 现在固定写 startup.log（见 EntryAbility.onCreate 的 setLogFile 重定向）。
    // 优先选它；万一出现日志轮转产生的 startup.log.1 等，也不要被它"按文件名排在后面"
    // 而误读旧文件。兜底仍取列表最后一个，保持原行为。
    let chosen: string = names[names.length - 1];
    if (names.indexOf('startup.log') >= 0) {
      chosen = 'startup.log';
    }
    const path: string = directory + '/' + chosen;
    // ★★ 只读尾部（1.0.47）：旧实现是 `readTextSync(path)` 整本读进来再截 8000 字。
    //   startup.log 是**无上限增长**的（原生 Core 一直在写），跑一阵子就是几 MB；
    //   而这个调用每 500ms 一次 ⇒ 每秒两次"读几 MB + 造一个几 MB 的字符串"，
    //   全在 JS 主线程上同步跑 —— 这是"整个软件发闷"的底噪之一，且与投屏画质无关。
    //   现在先 statSync 拿大小，再按 offset/length 只把尾部 16KB 读进来。
    let size: number = 0;
    try {
      size = Number(fileIo.statSync(path).size);   // size 是 bigint，必须 Number() 折算
    } catch (statError) {
      hilog.warn(DOMAIN, TAG, 'stat 日志失败: %{public}s', (statError as BusinessError).message);
      return '';
    }
    const wantBytes: number = size > LOG_TAIL_BYTES ? LOG_TAIL_BYTES : size;
    const offset: number = size - wantBytes;
    const options: ReadTextOptions = { offset: offset, length: wantBytes, encoding: 'utf-8' };
    const text: string = fileIo.readTextSync(path, options);
    // 从字节中间切开，首行大概率是半行 ⇒ 丢掉它，避免第一行永远是一截乱码。
    const firstBreak: number = text.indexOf('\n');
    const tailed: string = (offset > 0 && firstBreak >= 0)
      ? text.substring(firstBreak + 1) : text;
    // 原版 TextBox 高度 180，取尾部即可（超出部分由滚动条承担）。
    return tailed.length > LOG_TAIL_CHARS ? tailed.substring(tailed.length - LOG_TAIL_CHARS) : tailed;
  } catch (error) {
    hilog.warn(DOMAIN, TAG, 'read_log_tail 失败: %{public}s', (error as BusinessError).message);
    return '';
  }
}

/**
 * 应用图标位（68×68 大图标底座）。
 *
 * 原版（AboutWindow.xaml:55–62）是
 *   Border Width=68 Height=68 CornerRadius=14  →  里面 Image Width=52 Height=52
 * 圆角按 Apple 比例分级归卡片档 12（原版 14 介于 12 与 16 之间，取 12 保持
 * 「圆角方块」观感；68 高的底座用 16 会接近正圆的观感）。
 * 这里按「平台替换 2」用 Fluent 字形顶替那张 Logo 位图，所以盒子尺寸要按墨迹比例折算：
 * 位图的图面会**填满** 52×52；而 PhoneDesktop24 字形的墨迹只占 em 框的 20/24 ≈ 0.833
 * （见 FluentIcon.ets 的取证表）。要让墨迹正好 52，字号取 52 ÷ 0.833 ≈ 62。
 *
 * 取 44 时墨迹只有 36.7 —— 比原版小 29%，正是这轮「图标普遍偏小」的一部分。
 */
@Component
struct AboutAppIcon {
  build() {
    Row() {
      FluentSymbol({ iconName: 'PhoneDesktop24', iconSize: 62, iconColor: DARK.TEXT });
    }
    .width(68)
    .height(68)
    .borderRadius(12)   // Apple 圆角分级：68×68 大图标底座 → 12（RADIUS_CARD），原 14 最近的方块档
    .backgroundColor(DARK.PANEL_ALT)
    .border({ width: 1, color: DARK.BORDER })
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center);
  }
}

/** 「更新设置」页的一个 CheckBox（原版 Margin 0,0,0,14 + 可选 ToolTip）。 */
@Component
struct SettingsToggle {
  @Prop toggleLabel: string = '';
  @Prop checked: boolean = false;
  @Prop toggleMarginBottom: number = 14;
  on_toggle: (value: boolean) => void = () => {};

  build() {
    Row() {
      Checkbox({ name: this.toggleLabel, group: 'aboutUpdateSettings' })
        .select(this.checked)
        .selectedColor(ACCENT)
        .width(20)
        .height(20)
        .onChange((value: boolean): void => { this.on_toggle(value); });
      Text(this.toggleLabel)
        .fontSize(12)
        .fontColor(DARK.TEXT)
        .margin({ left: 10 });
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .margin({ bottom: this.toggleMarginBottom });
  }
}

@Entry
@Component
struct AboutWindow {
  /**
   * 官方分段按钮（SegmentButton，@kit.ArkUI）—— 系统设置「应用 | 元服务」同款胶囊控件。
   * 选中滑块、hover 光斑（沉浸光感）、形变动画全部由系统渲染，不再自绘。
   *
   * ★ 单一数据源：selectedIndexes 是 @Link（双向同步），点击 *和拖拽* 都会由组件
   *   写回这个数组。正文区一律以它为准（currentTabIndex）── 之前额外维护一个
   *   aboutTabIndex 只在 onItemClicked 里同步，导致「拖拽蓝块时正文不跟着切」
   *   （拖拽不触发点击回调）。
   */
  @State aboutTabIndexes: number[] = [ABOUT_TAB_INDEX];

  /** 当前页签下标：直接取 SegmentButton 回写的选中态，点击/拖拽都覆盖。 */
  private currentTabIndex(): number {
    return this.aboutTabIndexes.length > 0 ? this.aboutTabIndexes[0] : ABOUT_TAB_INDEX;
  }
  /**
   * 官方构造方式：SegmentButtonOptions 是 @Observed 类，**不能用对象字面量**（会触发
   * arkts-no-untyped-obj-literals，且缺 fontColor/selectedFontColor 等十来个必填字段），
   * 必须走静态工厂 SegmentButtonOptions.capsule(...)。
   * 同时 options 在 SegmentButton 里是 @ObjectLink，这里的字段必须是 @State（不能是普通成员）。
   */
  @State aboutTabOptions: SegmentButtonOptions = SegmentButtonOptions.capsule({
    // buttons 的数组字面量要显式 as SegmentButtonItemTuple，否则
    // arkts-no-noninferrable-arr-literals（元素类型不可推断）。
    buttons: [
      { text: S_TAB_ABOUT() },
      { text: S_TAB_UPDATE_SETTINGS() },
      { text: S_TAB_DIAGNOSTICS() },
    ] as SegmentButtonItemTuple,
    multiply: false,
    // 关于窗口背景固定深色，未选中/选中文字保持浅色；选中背景与「检查更新」主按钮蓝色统一。
    fontColor: DARK.MUTED_TEXT,
    selectedFontColor: DARK.TEXT,
    selectedBackgroundColor: PRIMARY_ACTION,
  });
  /**
   * 官方沉浸光感材质（API 26 起 SegmentButtonOptions 新增 backgroundSystemMaterial）。
   * 挂在胶囊底板上，得到系统「应用 | 元服务」那样的玻璃质感 + 光斑跟随。
   */
  private readonly tabMaterial: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.REGULAR,
    interactive: true,
    lightEffect: { color: Color.White },
  });
  @State versionText: string = 'v0.0.0';
  @State updateStatus: string = S_UPDATE_STATUS_READY_ONLINE;
  /** 「检查更新」是否正在查（按钮据此自禁用，避免连点打出好几个请求）。 */
  @State checkingUpdates: boolean = false;
  @State diagnosticPath: string = '';
  @State diagnosticStatus: string = S_RETENTION;
  @State logText: string = '';
  @State liveLogPath: string = '';
  @State checkOnStartup: boolean = true;
  @State autoDownload: boolean = false;
  @State allowMirrorFallback: boolean = true;
  @State notifyStableReleases: boolean = true;
  @State notifyPrereleaseReleases: boolean = false;
  /**
   * 开发者模式（调试入口，非持久化）：连点上方版本号 7 次开启，再点一次关闭。
   * 开启后主界面空状态会显示有线链路诊断（原生/系统 USB/权限/环境/驱动/窗口）。
   * 经 AppStorage 由 @StorageLink 跨窗口联动（关于子窗这里写 ↔ 主窗 Index 读）。
   */
  @StorageLink(DEVELOPER_MODE_KEY) devMode: boolean = false;
  @StorageLink(GLOW_ENABLED_KEY) glowEnabled: boolean = true;
  @StorageLink(GLOW_DEGRADED_KEY) glowDegraded: boolean = false;
  /** 版本号连点计数，达到 7 即触发开发者模式开启；未开启时每点一次 +1。 */
  @State versionTapCount: number = 0;
  private logTimer: number = -1;
  /** 启动时更新检查的延时句柄（只为等版本号读回来，见 aboutToAppear）。 */
  private startupCheckTimer: number = -1;
  /**
   * 窗口是否已销毁。网络检查是异步的：关窗后 promise 才回来时，
   * 写 @State 就是写已销毁组件（ArkUI 会报错/丢帧，严重时崩进程）。
   */
  private destroyed: boolean = false;

  /**
   * 本页所在的 Ability 上下文。
   *
   * 这是**页面自己**拿上下文的正路（与 Index.ets 的 start_window_drag 同一写法）：
   * UI 实例 → UIContext → getHostContext()。不依赖模块级变量，也不依赖已废弃的
   * 无参 getContext()，所以在子窗口页面里同样成立。
   */
  private ability_context(): common.Context | null {
    // 这个函数会被生命周期与 500 ms 定时器反复调用，**它自己绝不能抛**：
    // 定时器/生命周期里抛出的异常没人接管，会被运行时当成未捕获异常结束应用。
    let uic: UIContext | null = null;
    try {
      uic = this.getUIContext();
    } catch (error) {
      uic = null;
    }
    try {
      return resolve_context(uic);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '取 Ability 上下文失败: %{public}s',
        (error as BusinessError).message);
      return null;
    }
  }

  /**
   * ★ 生命周期里抛出的异常没人接管，会被运行时当成未捕获异常直接结束应用
   *   （用户看到的就是"点一下闪退"）。所以这里整块用 try 包住：
   *   版本号读不到、日志目录取不到，都只是少一行信息，**绝不能把窗口带崩**。
   */
  aboutToAppear(): void {
    try {
      // 打开时可直接指定页签（例如主界面「诊断」直达）：写进 selectedIndexes，
      // 正文区与蓝块都以它为唯一数据源。
      this.aboutTabIndexes = [AppStorage.get<number>(ARG_KEY_TAB_INDEX) ?? ABOUT_TAB_INDEX];
      // 光感底板：backgroundSystemMaterial 是 API 26 新增的可写属性（Read-Only = No），
      // 放在这里赋值而不是塞进 capsule() 的构造参数，避开构造选项类型不含该字段的风险。
      this.aboutTabOptions.backgroundSystemMaterial = this.tabMaterial;
      this.checkOnStartup = AppStorage.get<boolean>(SETTINGS_KEY_CHECK_ON_STARTUP) ?? true;
      this.autoDownload = AppStorage.get<boolean>(SETTINGS_KEY_AUTO_DOWNLOAD) ?? false;
      this.allowMirrorFallback = AppStorage.get<boolean>(SETTINGS_KEY_ALLOW_MIRROR) ?? true;
      this.notifyStableReleases = AppStorage.get<boolean>(SETTINGS_KEY_NOTIFY_STABLE) ?? true;
      this.notifyPrereleaseReleases = AppStorage.get<boolean>(SETTINGS_KEY_NOTIFY_PRERELEASE) ?? false;
    } catch (error) {
      hilog.error(DOMAIN, TAG, '读取更新设置失败: %{public}s', (error as BusinessError).message);
    }

    try {
      const ctx: common.Context | null = this.ability_context();
      const dir: string = diagnostic_dir(ctx);
      this.diagnosticPath = dir.length > 0 ? dir
        : '（取不到应用沙箱路径：Ability 上下文不可用）';
      this.liveLogPath = dir.length > 0 ? dir + '/startup.log' : '';
    } catch (error) {
      hilog.error(DOMAIN, TAG, '解析日志目录失败: %{public}s', (error as BusinessError).message);
    }

    this.load_version();
    // 「启动时检查更新」：开关开着就在进页面时静默查一次，结果直接落在下面那行
    // 状态文案上（查不到 / 失败也都照实写）。为什么放在 aboutToAppear 而不是真的
    // App 启动：关于页才是用户看结果的地方，且这样不会给每次冷启动挂一次网络请求。
    // 版本号可能还没从 bundleManager 回来 ⇒ 延后 1.2 秒再查，避开"本机版号 0.0.0"。
    if (this.checkOnStartup) {
      this.startupCheckTimer = setTimeout((): void => {
        try {
          this.run_startup_update_check();
        } catch (error) {
          hilog.warn(DOMAIN, TAG, '启动时更新检查失败: %{public}s',
            (error as BusinessError).message);
        }
      }, 1200);
    }
    // 首次刷新也要包住：它在 aboutToAppear 里同步执行，抛出去同样会终止应用。
    try {
      this.refresh_logs();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '首次刷新日志失败: %{public}s', (error as BusinessError).message);
    }
    // 平台替换 7：原版 DispatcherTimer 500 ms 轮询 RefreshLogsAsync。
    // 回调里再包一层 try：定时器异常同样会终止应用（见 read_log_tail 的注释）。
    // ★ 500ms → 1000ms（1.0.47）：日志面板要的是"看着在动"，不是逐帧同步。
    //   配合 read_log_tail 的"只读尾部 16KB"和 refresh_logs 的"内容没变不赋值"，
    //   把这一路从"每秒两次读几 MB + 重建 8000 字 Text"降到几乎无成本。
    this.logTimer = setInterval((): void => {
      try {
        this.refresh_logs();
      } catch (error) {
        hilog.warn(DOMAIN, TAG, '刷新日志失败: %{public}s', (error as BusinessError).message);
      }
    }, 1000);
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    if (this.logTimer >= 0) {
      clearInterval(this.logTimer);
      this.logTimer = -1;
    }
    // 延时触发的启动检查也要取消：窗口都关了再写 @State 没有意义（还可能踩
    // 已销毁组件）。漏掉这一条就是"定时器回调异常把应用带崩"的典型来源。
    if (this.startupCheckTimer >= 0) {
      clearTimeout(this.startupCheckTimer);
      this.startupCheckTimer = -1;
    }
    // 原版 OnClosing 里 _app.SaveUpdateSettings()；这里落回 AppStorage（平台替换 9）。
    try {
      AppStorage.setOrCreate<boolean>(SETTINGS_KEY_CHECK_ON_STARTUP, this.checkOnStartup);
      AppStorage.setOrCreate<boolean>(SETTINGS_KEY_AUTO_DOWNLOAD, this.autoDownload);
      AppStorage.setOrCreate<boolean>(SETTINGS_KEY_ALLOW_MIRROR, this.allowMirrorFallback);
      AppStorage.setOrCreate<boolean>(SETTINGS_KEY_NOTIFY_STABLE, this.notifyStableReleases);
      AppStorage.setOrCreate<boolean>(SETTINGS_KEY_NOTIFY_PRERELEASE, this.notifyPrereleaseReleases);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '保存更新设置失败: %{public}s', (error as BusinessError).message);
    }
  }

  /** 平台替换 1：真做 —— 读 bundleManager 的 versionName。 */
  private load_version(): void {
    try {
      bundleManager.getBundleInfoForSelf(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
        .then((info: bundleManager.BundleInfo): void => {
          this.versionText = 'v' + info.versionName;
        })
        .catch((error: BusinessError): void => {
          const failure: BusinessError = error as BusinessError;
          hilog.error(DOMAIN, TAG, 'getBundleInfoForSelf 失败: %{public}s',
            failure !== undefined && failure !== null && failure.message !== undefined
              ? failure.message : '未知原因');
        });
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'getBundleInfoForSelf 抛错: %{public}s',
        (error as BusinessError).message);
    }
  }

  private refresh_logs(): void {
    const fresh: string = read_log_tail(this.ability_context());
    // ★ 内容没变就别赋值：@State 一赋值就是整窗重渲染，而这里挂着一个 8000 字的
    //   Text —— 每 500ms 无差别重建一次纯属白烧 CPU（投屏还在跑时日志一直在涨，
    //   那时才真的需要刷新）。
    if (fresh !== this.logText) {
      this.logText = fresh;
    }
  }

  /**
   * 平台替换 3（1.0.45）：真检查。
   *
   * 判据必须是"查到什么说什么"，不许在查不到时说"已是最新"：
   *   * 拿到远端 tag 且比本机新 ⇒ 报版本号/日期/预发布标记 + 说明摘要；
   *   * 拿到远端 tag 但不比本机新 ⇒ 明说"本机 X 已是最新（远端 Y）"；
   *   * 仓库还没有 Release（404）⇒ 明说"仓库暂无 Release"；
   *   * 网络/超时/JSON 解析失败 ⇒ 明说失败原因。
   *
   * ★ 整个 async 链必须自己接住异常：这里是从 UI 点击回调进来的 async 函数，
   *   未接住的 reject 没人接管 ⇒ 应用被结束（子窗口铁律 1）。
   */
  private on_check_updates(): void {
    this.checkingUpdates = true;
    this.updateStatus = S_UPD_CHECKING();
    // 版本号此时可能还没从 bundleManager 读回来（UI 装载早于 promise 完成时写字串），
    // 取不到就用关于页显示的默认值，保证比较始终有本机这一侧的值。
    const local: string = this.versionText.startsWith('v')
      ? this.versionText.substring(1) : this.versionText;
    try {
      check_latest_release(local)
        .then((result: UpdateCheckResult): void => {
          if (this.destroyed) return;      // 窗口已关：别再写已销毁组件
          this.checkingUpdates = false;
          this.updateStatus = this.describe_update_result(result);
          if (result.outcome !== UPDATE_OUTCOME_FAILED) {
            hilog.info(DOMAIN, TAG, 'update_check: %{public}s', this.updateStatus);
          } else {
            hilog.warn(DOMAIN, TAG, 'update_check_failed: %{public}s', result.reason);
          }
        })
        .catch((error: BusinessError): void => {
          if (this.destroyed) return;
          this.checkingUpdates = false;
          const reason: string = error !== undefined && error !== null && error.message !== undefined
            ? error.message : '未知原因';
          this.updateStatus = `${S_UPD_FAILED_PREFIX()}${reason}`;
          hilog.error(DOMAIN, TAG, 'update_check_rejected: %{public}s', reason);
        });
    } catch (error) {
      this.checkingUpdates = false;
      const reason: string = (error as BusinessError).message;
      this.updateStatus = `${S_UPD_FAILED_PREFIX()}${reason}`;
      hilog.error(DOMAIN, TAG, 'update_check_threw: %{public}s', reason);
    }
  }

  /**
   * 启动时静默检查：只在拿到远端版本且确认更新时才换掉那行默认文案。
   *
   * 为什么失败要沉默（而不是像手动检查那样写到状态行）：自动检查是"顺便做"的，
   * 把网络错误摊到状态行会让用户以为按钮坏了 —— 那是一条假警报。但结果仍写进
   * hilog，用户也可以随时手动再点一次。
   */
  private run_startup_update_check(): void {
    const local: string = this.versionText.startsWith('v')
      ? this.versionText.substring(1) : this.versionText;
    if (local.length === 0 || local === '0.0.0') return; // 版本号还没读到，不查
    check_latest_release(local)
      .then((result: UpdateCheckResult): void => {
        if (result.outcome === UPDATE_OUTCOME_HAS_UPDATE) {
          this.updateStatus = this.describe_update_result(result);
        }
      })
      .catch((error: BusinessError): void => {
        hilog.warn(DOMAIN, TAG, 'startup_update_check_failed: %{public}s',
          error !== undefined && error !== null && error.message !== undefined
            ? error.message : '未知原因');
      });
  }

  /** 把检查结果拼成一行用户能核对的文字（不许含糊的"已是最新"）。 */
  private describe_update_result(result: UpdateCheckResult): string {
    const dateNote: string = result.remoteDate.length > 0 ? `（${result.remoteDate}）` : '';
    const channelNote: string = result.remotePrerelease ? `${S_UPD_PREVIEW()} ` : '';
    switch (result.outcome) {
      case UPDATE_OUTCOME_HAS_UPDATE:
        return `${S_UPD_NEW_FOUND()} ${result.remoteVersion}${dateNote}：${channelNote}` +
          (result.remoteNotes.length > 0 ? result.remoteNotes : S_UPD_LOCAL() + result.localVersion) +
          ` ${S_UPD_GO_DOWNLOAD()}`;
      case UPDATE_OUTCOME_UP_TO_DATE:
        return `${S_UPD_UP_TO_DATE()}${result.localVersion}` +
          `${S_UPD_GITHUB_LATEST()}${result.remoteVersion}${dateNote}。`;
      case UPDATE_OUTCOME_NO_RELEASE:
        return `${S_UPD_REPO()}${result.remoteUrl}${S_UPD_NO_RELEASE()}` +
          `${S_UPD_LOCAL()}${result.localVersion}）`;
      default:
        return `${S_UPD_FAILED_PREFIX()}${result.reason}` +
          `${S_UPD_LOCAL()}${result.localVersion}）`;
    }
  }

  /** 平台替换 4：OnGitHubClick。 */
  private on_github(): void {
    open_url(GITHUB_REPO_URL);
  }

  /** 平台替换 4：OnChangelogClick（原版本地 CHANGELOG.md 优先，鸿蒙一律走 URL）。 */
  private on_changelog(): void {
    open_url(GITHUB_RELEASES_URL);
  }

  /** 平台替换 4：OnLicenseClick（原版本地 LICENSE 优先，鸿蒙一律走 URL）。 */
  private on_license(): void {
    open_url(GITHUB_LICENSE_URL);
  }

  /** 平台替换 5：不假装打开了文件管理器。 */
  private on_open_logs(): void {
    this.diagnosticStatus = S_OPEN_LOGS_REASON;
  }

  /** 平台替换 6：真做 —— 清诊断日志并统计。 */
  private on_clean_logs(): void {
    try {
      const logs: CleanupResult = cleanup_logs(this.ability_context());
      // 更新缓存目录在鸿蒙侧不存在，两项目恒为 0（原版是 logs + updates 相加）。
      this.diagnosticStatus = S_CLEANED()
        .replace('%d', logs.deletedFiles.toString())
        .replace('%s', format_bytes(logs.deletedBytes))
        .replace('%d', logs.skippedFiles.toString())
        + S_NO_UPDATE_CACHE;
      hilog.info(DOMAIN, TAG, 'manual_cleanup_complete: %{public}d 个文件',
        logs.deletedFiles);
    } catch (error) {
      const failure: BusinessError = error as BusinessError;
      const reason: string = failure !== undefined && failure !== null && failure.message !== undefined
        ? failure.message : '未知原因';
      hilog.error(DOMAIN, TAG, 'manual_cleanup_failed: %{public}s', reason);
      this.diagnosticStatus = S_CLEAN_FAILED().replace('%s', reason);
    }
  }

  /** 平台替换 8：只清视图，不动磁盘。 */
  private on_clear_view(): void {
    this.logText = '';
    this.diagnosticStatus = S_LOG_VIEW_CLEARED();
  }

  // ── TabItem 1「关于」────────────────────────────────────────────────────
  @Builder
  about_tab() {
    Scroll() {
      Column() {
        // Grid：Col 88 图标 + Col * 文字
        Row() {
          AboutAppIcon();
          Column() {
            Text('iPhoneMirror')
              .fontSize(21)
              .fontWeight(FontWeight.Bold)
              .fontColor(DARK.TEXT)
              .width('100%');
            Text(this.versionText)
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(DARK.MUTED_TEXT)
              .width('100%')
              .margin({ top: 4 })
              .onClick((): void => {
                // 开发者模式调试入口：连点版本号 7 次开启，已开启时再点一次关闭。
                // 2026-10-31 起持久化（save_developer_mode_preference）：开启后
                // 重开应用仍保持，用户不必每次连点。
                // 整段 try 包住：点击回调里抛异常没人接管，会把整个应用带崩。
                try {
                  if (this.devMode) {
                    // 已开启 → 再点一次即关闭，并重置计数。
                    this.devMode = false;
                    AppStorage.setOrCreate<boolean>(DEVELOPER_MODE_KEY, false);
                    save_developer_mode_preference(false);
                    this.versionTapCount = 0;
                  } else {
                    this.versionTapCount += 1;
                    if (this.versionTapCount >= 7) {
                      this.devMode = true;
                      AppStorage.setOrCreate<boolean>(DEVELOPER_MODE_KEY, true);
                      save_developer_mode_preference(true);
                      this.versionTapCount = 0;
                    }
                  }
                } catch (error) {
                  hilog.warn(DOMAIN, TAG, '版本号连点处理失败: %{public}s',
                    (error as BusinessError).message);
                }
              });
            Text(S_DESCRIPTION())
              .fontSize(12)
              .fontColor(DARK.MUTED_TEXT)
              .lineHeight(18)
              .width('100%')
              .margin({ top: 6 });
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .margin({ left: 20 });
        }
        .width('100%')
        .alignItems(VerticalAlign.Center);

        // ── 版本更新（只展示最新一版）────────────────────────────────
        // 应用内不展示历史更新（用户 2026-11-07 要求）：历史逐版记录在仓库
        // CHANGELOG.md 与 GitHub Releases 里，页脚的「更新日志」按钮可跳转。
        section_title(S_WHATS_NEW());
        ChangelogGroup({
          version: LATEST_RELEASE.version,
          date: LATEST_RELEASE.date,
          items: LATEST_RELEASE.items,
        });

        // Border Height 1 / BorderSoftBrush / Margin 0,20
        Column()
          .height(1)
          .width('100%')
          .backgroundColor(DARK.BORDER_SOFT)
          .margin({ top: 20, bottom: 20 });

        section_title(S_UPDATE_STATUS_TITLE());
        Text(this.updateStatus)
          .fontSize(12)
          .fontColor(DARK.MUTED_TEXT)
          .lineHeight(18)
          .width('100%')
          .margin({ top: 6, bottom: 14 });

        // WrapPanel：四个按钮，都 Margin 0,0,8,8
        Flex({ wrap: FlexWrap.Wrap }) {
          PrimaryButton({
            label: this.checkingUpdates ? S_UPD_CHECKING_LABEL() : S_CHECK_UPDATES(),
            minButtonWidth: 138,
            // 查询进行中禁用：连点会打出好几个 HTTP 请求，而每次结果都会覆盖上一版文案。
            actionEnabled: !this.checkingUpdates,
            on_action: (): void => { this.on_check_updates(); },
          })
            .margin({ right: 8, bottom: 8 });
          SecondaryButton({
            label: 'GitHub',
            minButtonWidth: 96,
            on_action: (): void => { this.on_github(); },
          })
            .margin({ right: 8, bottom: 8 });
          SecondaryButton({
            label: S_CHANGELOG(),
            minButtonWidth: 108,
            on_action: (): void => { this.on_changelog(); },
          })
            .margin({ right: 8, bottom: 8 });
          SecondaryButton({
            label: S_LICENSE(),
            minButtonWidth: 118,
            on_action: (): void => { this.on_license(); },
          })
            .margin({ right: 8, bottom: 8 });
          // 首启向导：随时可重看（不依赖首启标记，见 FirstRunSetupWindow.ets）。
          SecondaryButton({
            label: t('首启向导'),
            minButtonWidth: 108,
            on_action: (): void => {
              try {
                open_first_run(this.ability_context() as common.Context);
              } catch (error) {
                hilog.warn(0x0000, 'im_about', '首启向导重开失败: %{public}s',
                  (error as BusinessError).message);
              }
            },
          })
            .margin({ right: 8, bottom: 8 });
        }
        .width('100%');
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%');
    }
    .width('100%')
    // 三个页签原本挂在 TabContent 下（由它提供确定的可用高度，Scroll 才能滚动）。
    // 现在改用自绘内容区（Column + layoutWeight），必须显式把高度交给 Scroll，
    // 否则它会按内容高度伸展、滚不动。
    .height('100%')
    .scrollBar(BarState.Auto)
    .align(Alignment.Top);
  }

  // ── TabItem 2「更新设置」────────────────────────────────────────────────
  @Builder
  update_settings_tab() {
    Scroll() {
      Column() {
        section_title(S_UPDATE_SETTINGS_TITLE());
        Text(S_UPDATE_SETTINGS_DESC())
          .fontSize(12)
          .fontColor(DARK.MUTED_TEXT)
          .lineHeight(18)
          .width('100%')
          .margin({ top: 6, bottom: 18 });

        SettingsToggle({
          toggleLabel: S_CHECK_ON_STARTUP(),
          checked: this.checkOnStartup,
          on_toggle: (value: boolean): void => { this.checkOnStartup = value; },
        });
        SettingsToggle({
          toggleLabel: S_AUTO_DOWNLOAD(),
          checked: this.autoDownload,
          on_toggle: (value: boolean): void => { this.autoDownload = value; },
        });
        SettingsToggle({
          toggleLabel: S_ALLOW_MIRROR(),
          checked: this.allowMirrorFallback,
          on_toggle: (value: boolean): void => { this.allowMirrorFallback = value; },
        });
        // 原版 ToolTip=AllowUpdateMirrorFallbackDescription；ArkUI 无 ToolTip，
        // 以常驻说明文字呈现同样内容（平台替换 10 的同族处理）。
        Column() {
          hint_text(S_ALLOW_MIRROR_DESC);
        }
        .width('100%')
        .margin({ bottom: 14 });
        SettingsToggle({
          toggleLabel: S_NOTIFY_STABLE(),
          checked: this.notifyStableReleases,
          on_toggle: (value: boolean): void => { this.notifyStableReleases = value; },
        });
        SettingsToggle({
          toggleLabel: S_NOTIFY_PRERELEASE(),
          checked: this.notifyPrereleaseReleases,
          toggleMarginBottom: 0,
          on_toggle: (value: boolean): void => { this.notifyPrereleaseReleases = value; },
        });
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%');
    }
    .width('100%')
    // 三个页签原本挂在 TabContent 下（由它提供确定的可用高度，Scroll 才能滚动）。
    // 现在改用自绘内容区（Column + layoutWeight），必须显式把高度交给 Scroll，
    // 否则它会按内容高度伸展、滚不动。
    .height('100%')
    .scrollBar(BarState.Auto)
    .align(Alignment.Top);
  }

  // ── TabItem 3「诊断」────────────────────────────────────────────────────
  @Builder
  diagnostics_tab() {
    Scroll() {
      Column() {
        section_title(S_DIAGNOSTICS_TITLE());
        Text(S_DIAGNOSTICS_DESC)
          .fontSize(12)
          .fontColor(DARK.MUTED_TEXT)
          .lineHeight(18)
          .width('100%')
          .margin({ top: 6, bottom: 18 });

        section_title(S_DIAGNOSTICS_LOCATION());
        RoundedTextBox({
          text: this.diagnosticPath,
          readOnly: true,
          boxHeight: 40,
        })
          .margin({ top: 9, bottom: 14 });

        Text(this.diagnosticStatus)
          .fontSize(12)
          .fontColor(DARK.MUTED_TEXT)
          .lineHeight(18)
          .width('100%')
          .margin({ bottom: 14 });

        Flex({ wrap: FlexWrap.Wrap }) {
          PrimaryButton({
            label: S_OPEN_LOGS(),
            minButtonWidth: 126,
            on_action: (): void => { this.on_open_logs(); },
          })
            .margin({ right: 8, bottom: 8 });
          SecondaryButton({
            label: S_CLEAN_LOGS(),
            minButtonWidth: 126,
            on_action: (): void => { this.on_clean_logs(); },
          })
            .margin({ right: 8, bottom: 8 });
        }
        .width('100%');

        // Border Height 1 / BorderSoftBrush / Margin 0,12,0,18
        Column()
          .height(1)
          .width('100%')
          .backgroundColor(DARK.BORDER_SOFT)
          .margin({ top: 12, bottom: 18 });

        // Grid：LiveLogHeader（左）+「清空视图」（右，Padding 10,5 / MinHeight 32 / 11）
        Row() {
          section_title(S_LIVE_LOG());
          Row() {
            Text(S_CLEAR_VIEW())
              .fontSize(11)
              .fontColor(DARK.TEXT);
          }
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .constraintSize({ minHeight: 32 })
          .borderRadius(10)   // Apple 圆角分级：32 高按钮 → 10（RADIUS_CONTROL），原 16 偏药丸
          .border({ width: 1, color: DARK.BORDER })
          .alignItems(VerticalAlign.Center)
          .hoverEffect(HoverEffect.Highlight)
          .onClick((): void => { this.on_clear_view(); });
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center);

        Text(this.liveLogPath)
          .fontSize(10)
          .fontColor(DARK.MUTED_TEXT)
          .fontFamily('monospace')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 10, bottom: 7 });

        // Border PreviewChromeBrush / 圆角 10 / 内嵌只读 TextBox（Height 180）
        Scroll() {
          Text(this.logText)
            .fontSize(10)
            .fontColor(DARK.PREVIEW_TEXT)
            .fontFamily('monospace')
            .width('100%')
            .copyOption(CopyOptions.LocalDevice);
        }
        .width('100%')
        .height(180)
        .padding(10)
        .borderRadius(12)   // Apple 圆角分级：180 高日志文本区 → 12（RADIUS_CARD）
        .backgroundColor(DARK.PREVIEW_CHROME)
        .border({ width: 1, color: DARK.BORDER })
        .scrollBar(BarState.Auto)
        .align(Alignment.Top);
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%');
    }
    .width('100%')
    // 三个页签原本挂在 TabContent 下（由它提供确定的可用高度，Scroll 才能滚动）。
    // 现在改用自绘内容区（Column + layoutWeight），必须显式把高度交给 Scroll，
    // 否则它会按内容高度伸展、滚不动。
    .height('100%')
    .scrollBar(BarState.Auto)
    .align(Alignment.Top);
  }

  /**
   * 正文区。原版 body 是 TabControl（`SubWindowTabControl`）。
   * 页签行用官方 SegmentButton（@kit.ArkUI）：系统设置「应用 | 元服务」同款胶囊控件，
   * 选中滑块 / hover 光斑（沉浸光感）/ 形变动画全部系统渲染；组件不支持通用属性，
   * 宽度自动取满可用区域、按按钮个数等分，正好对应原版 UniformGrid Rows=1 的等宽行为。
   * 原版 TabItem 样式（ModernControls.xaml：SemiBold 14 / Muted→Accent / SelectionBrush
   * 选中底 / IconButtonHoverBrush 悬停底）交由系统胶囊控件自行呈现。
   */
  @Builder
  body() {
    Column() {
      // SegmentButton 不支持通用属性（不能直接 .margin()），用容器包一层拿间距；
      // 底部 12vp 让页签行与正文卡片拉开，视觉上页签整体上移。
      Column() {
        SegmentButton({
          options: this.aboutTabOptions,
          selectedIndexes: this.aboutTabIndexes,
          // 官方属性动画（API 24+）：选中态切换的滑块过渡交给组件，不再自己 animateTo。
          enableStateAnimation: true,
        })
      }
      .width('100%')
      .margin({ bottom: 12 })

      // 内容区（原版 ContentPresenter Grid.Row=1）。三个 tab 自带 Scroll，
      // 用 layoutWeight 占满剩余高度，它们才能正确滚动。
      Column() {
        if (this.currentTabIndex() === ABOUT_TAB_INDEX) {
          this.about_tab();
        } else if (this.currentTabIndex() === UPDATE_SETTINGS_TAB_INDEX) {
          this.update_settings_tab();
        } else {
          this.diagnostics_tab();
        }
      }
      .width('100%')
      .layoutWeight(1);
    }
    .width('100%')
    .height('100%');
  }

  build() {
    Column() {
      SubWindowShell({
      windowName: WINDOW_NAME,
      title: S_TITLE(),
      subtitle: S_SUBTITLE(),
      gap: SUBWINDOW_ROW_GAP,       // 行 1 = 16
      hasNotice: false,
      hasFooter: false,
      hasActions: false,            // 原版没有底部按钮条，四个按钮在「关于」页里
      content: (): void => { this.body(); },
    });
    }
  }
}
