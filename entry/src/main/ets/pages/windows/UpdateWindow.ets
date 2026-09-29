// UpdateWindow.ets —— 子窗口：发现新版本（Release 详情）
//
// 逐项对照上游 src/App/Windows/UpdateWindow.xaml（135 行）
//              src/App/Windows/UpdateWindow.xaml.cs（185 行）
//  上游 main（1.8.4）与 linux-port（1.8.1）两份 .xaml / .xaml.cs **逐行相同**，
//  本文件按 main 版还原。
//
// ── 窗口属性（XAML 根元素 <ui:FluentWindow> 那一行）──────────────────────────
//   Title="{DynamicResource UpdateWindowTitle}"     → 「发现新版本」
//   Width="760" Height="700" MinWidth="660" MinHeight="580"
//   WindowStartupLocation="CenterOwner"             → SubWindowHost.open 里算居中
//   ResizeMode="CanResize"                          → resizable: true
//   ExtendsContentIntoTitleBar="True"               → decorEnabled: false + 自绘表头
//   WindowBackdropType="Mica" / WindowCornerPreference="Round" → 由系统窗口负责
//   Background="{DynamicResource AppBackgroundBrush}"
//   ShowInTaskbar="False"
//   AutomationProperties.AutomationId="UpdateWindow"
//
// ── 行定义（7 行）逐条落到 SubWindowShell 的四个槽位 ─────────────────────────
//   Row Auto : Grid Style=SubWindowHeader（MinHeight 44, WindowDragBehavior）
//                StackPanel：SubWindowTitle（UpdateWindowTitle）
//                            + SubWindowSubtitle（UpdateWindowSubtitle）
//                Border Col=1：AccentBrush 底 / 圆角 12 / Padding 12,7
//                            + TextBlock LatestVersion（OnAccentBrush / SemiBold）
//                Button Col=3：SubWindowCloseButton（Click=OnLaterClick）
//   Row 16   : 间隔                                        → shell 的 gap
//   Row Auto : Grid 三列（* / 24 / * / 24 / *）             → notice 的下半段
//                CurrentVersionLabel(Muted 11) + CurrentVersion(16 SemiBold)
//                LatestVersionLabel  + LatestVersion
//                PublishedAtLabel    + PublishedAt
//   Row 18   : 间隔                                        → noticeGap→content 之间
//   Row *    : Border Style=SettingsSection Padding="18"    → content（layoutWeight 1）
//                └ Grid：Row Auto = ReleaseName(18 SemiBold Wrap)
//                              + Button「查看完整 Release」（Open20 + 文字，Margin 12,0,0,0）
//                        Row 8  = 间隔
//                        Row *  = FlowDocumentScrollViewer（Markdown 渲染的 Release 说明）
//   Row 18   : 间隔                                        → footerGap
//   Row Auto : Grid 两行                                   → footer + actions
//                Row Auto：StackPanel Visibility=ProgressVisibility
//                          ProgressBar Height 7（Min 0 / Max 100）
//                          + StatusText(左) / SpeedText(右, Muted)
//                Row Auto：StackPanel 靠右 / Margin 0,16,0,0
//                          Button「稍后提醒」MinWidth 112 / Margin 0,0,8,0
//                          Button UpdateActionButton「立即更新」MinWidth 132 / PrimaryButton
//
// ── 版本徽标的落点（唯一一处结构性替换）────────────────────────────────────
//   原版徽标在**表头**里（Grid.Column=1，标题右侧、关闭按钮左侧）。
//   SubWindowShell 的表头只暴露 title / subtitle / 关闭按钮三个槽位，没有第四
//   个可以塞徽标的位置，而本文件不得修改 SubWindow.ets。
//   → 徽标下移到表头正下方一行（右对齐），保留 AccentBrush 底 / 圆角 12 /
//     Padding 12,7 / OnAccentBrush 半粗文字的原样外观，内容仍是 LatestVersion。
//
// ── 文案来源 Strings.zh-CN.xaml（逐字取用）────────────────────────────────
//   UpdateWindowTitle          「发现新版本」
//   UpdateWindowSubtitle       「查看更新内容并一键完成升级」
//   OpenReleasePage            「查看完整 Release」
//   CurrentVersionLabel        「当前版本」
//   LatestVersionLabel         「最新版本」
//   PublishedAtLabel           「发布时间」
//   RemindLater                「稍后提醒」
//   UpdateNow                  「立即更新」
//   DownloadingUpdate          「正在下载更新」
//   PreparingDownload          「正在准备安全下载…」
//   TestingUpdateRoutes        「正在测试 GitHub 和镜像线路…」
//   MeasuringUpdateRoutes      「正在测试可达线路的下载速度…」
//   DownloadProgressFormat     「正在下载更新 {0:F0}%」
//   UpdateVerified             「下载完成，SHA256 校验通过。」
//   UpdateDownloadedNoChecksum 「下载完成；此 Release 未提供 SHA256 校验值。」
//   StartingInstaller          「正在启动安装程序，应用即将安全退出…」
//   UpdateDownloadCancelled    「更新下载已取消，可稍后重新尝试。」
//   UpdateDownloadFailedFormat 「更新失败：{0}」
//   RetryUpdate                「重新下载」
//   UpdateNetworkUnavailable   「所有更新线路暂时不可用，请检查网络连接后重试。」
//   UpdateRequestTimedOut      「连接更新服务超时，请稍后重试。」
//
// ── 平台替换（原版机制在鸿蒙没有对应物，逐条列出）──────────────────────────
//   1. 【当前版本】原版 VersionManager.DisplayVersion 读程序集的
//      AssemblyInformationalVersionAttribute。鸿蒙没有程序集清单 → 改读
//      bundleManager.getBundleInfoForSelf() 的 versionName（真做，读不到时
//      显示 0.0.0 并记 hilog）。
//   2. 【Release 说明】原版 MarkdownFlowDocumentRenderer.Render(release.Body)
//      把 Markdown 渲染成 WPF FlowDocument。鸿蒙没有 FlowDocument，
//      也没有现成的 Markdown 渲染器 → 按原样保留 Markdown 纯文本
//      （去掉 ``` 代码块围栏以外的东西一律不动），放进可滚动的等宽文本区。
//      这是**无损降级**：内容一个字不改，只是不做富文本排版。
//   3. 【立即更新 / 下载安装】原版 DownloadAndInstallAsync 走
//      GitHubReleaseClient.DownloadAsync（含镜像测速 + SHA-256 校验）后
//      UpdateInstallerLauncher.Launch() —— 后者依赖 ShellExecuteExW + PowerShell
//      提权引导 + Inno Setup / ZIP 替换脚本。鸿蒙**不允许**应用自行下载可执行
//      包并静默安装（应用只能由应用市场/系统安装器更新）。
//      → 按钮保留原版文案「立即更新」，点击后：
//         (a) 真做：用系统浏览器打开发布页（startAbility + ACTION_VIEW）；
//         (b) 明说：状态行写出「鸿蒙不允许应用自行下载并静默安装更新包…」。
//         不显示假的下载进度条、不把按钮文案改成「已更新」。
//   4. 【进度条】原版 ProgressBar 跟随下载进度。既然没有真实下载（见 3），
//      进度区只在有状态文本时出现，且只显示不确定态（IsIndeterminate）——
//      这是原版「测速/连接阶段」的同一个表现，不是伪造的百分比。
//   5. 【稍后提醒】原版 OnLaterClick 只 Close()。这里同时往
//      RESULT_KEY_LATER 写 true，供调用方（原版靠 ShowDialog 返回值 /
//      UpdateSettings 的 snooze 逻辑）取用。
//   6. 【readOnlyPreview】原版 previewOnly 时 CanUpdate=false（按钮禁用）。
//      鸿蒙侧保留该标志：只在开发者预览模式把「立即更新」置灰。
//
// ── 不做假成功 ─────────────────────────────────────────────────────────────
//   本窗口唯一的「更新」动作就是打开发布页；凡是鸿蒙做不到的部分都在状态行
//   明写原因，绝不把「已打开发布页」包装成「更新已安装」。

import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { bundleManager, Want } from '@kit.AbilityKit';
import {
  SubWindowShell, SubWindowHost, SecondaryButton, PrimaryButton,
  SUBWINDOW_ROW_GAP, SubWindowSpec,
} from '../../common/SubWindow';
import {
  ACCENT, ON_ACCENT, MUTED_TEXT, TEXT, CARD, BORDER,
  PREVIEW_CHROME, PREVIEW_TEXT, SETTINGS_SECTION_CORNER, SETTINGS_SECTION_PADDING,
} from '../../common/Theme';
import { FluentSymbol } from '../../common/FluentIcon';

const TAG: string = 'im_update';
const DOMAIN: number = 0x0100;

/** 窗口名 —— 用 XAML 的类名，window.findWindow 也用它。 */
export const WINDOW_NAME: string = 'UpdateWindow';
/** 页面路径。 */
export const PAGE_PATH: string = 'pages/windows/UpdateWindow';

/**
 * 原版 internal UpdateWindow(ReleaseInfo release, GitHubReleaseClient client,
 *                            bool autoDownload, bool allowMirrorFallback,
 *                            bool readOnlyPreview) 的入参键。
 */
export const ARG_KEY_TAG: string = 'im.update.tagName';
export const ARG_KEY_NAME: string = 'im.update.releaseName';
export const ARG_KEY_PUBLISHED_AT: string = 'im.update.publishedAt';
export const ARG_KEY_BODY: string = 'im.update.body';
export const ARG_KEY_RELEASE_URL: string = 'im.update.releaseUrl';
export const ARG_KEY_ALLOW_MIRROR: string = 'im.update.allowMirrorFallback';
export const ARG_KEY_READ_ONLY: string = 'im.update.readOnlyPreview';
/** 原版 DialogResult / _installationStarted 语义的回传键。 */
export const RESULT_KEY_LATER: string = 'im.update.remindLater';
export const RESULT_KEY_OPENED: string = 'im.update.releasePageOpened';

const FALLBACK_RELEASE_URL: string = 'https://github.com/RayrenSX/iPhoneMirror/releases';
const GITHUB_URL: string = 'https://github.com/RayrenSX/iPhoneMirror';

/** Strings（逐键标注）。 */
const S_TITLE: string = '发现新版本';                 // UpdateWindowTitle
const S_SUBTITLE: string = '查看更新内容并一键完成升级';  // UpdateWindowSubtitle
const S_OPEN_RELEASE: string = '查看完整 Release';     // OpenReleasePage
const S_CURRENT_LABEL: string = '当前版本';            // CurrentVersionLabel
const S_LATEST_LABEL: string = '最新版本';             // LatestVersionLabel
const S_PUBLISHED_LABEL: string = '发布时间';          // PublishedAtLabel
const S_REMIND_LATER: string = '稍后提醒';             // RemindLater
const S_UPDATE_NOW: string = '立即更新';               // UpdateNow

/** 平台替换 3：点击「立即更新」后的确切原因。 */
const S_UPDATE_REASON: string =
  '鸿蒙不允许应用自行下载更新包并静默安装（原版依赖 ShellExecuteExW + PowerShell 提权 + ' +
  'Inno Setup / ZIP 替换脚本）。已改为用系统浏览器打开发布页，请在页面中选择适用于' +
  '鸿蒙的安装方式（应用市场或官方渠道）完成升级。';

/** 原版 ReleaseInfo 的鸿蒙对应物（由调用方在开窗前填好放进 AppStorage）。 */
export interface ReleaseInfoArgs {
  /** ReleaseInfo.TagName */
  tagName: string;
  /** ReleaseInfo.Name */
  releaseName: string;
  /** ReleaseInfo.PublishedAt 的 yyyy-MM-dd 形式（原版 .LocalDateTime.ToString("yyyy-MM-dd")）。 */
  publishedAt: string;
  /** ReleaseInfo.Body —— 原版交给 MarkdownFlowDocumentRenderer 的原文。 */
  body: string;
  /** ReleaseInfo.ReleaseUrl.AbsoluteUri */
  releaseUrl: string;
  /** 原版 allowMirrorFallback */
  allowMirrorFallback: boolean;
  /** 原版 readOnlyPreview：true 时「立即更新」禁用。 */
  readOnlyPreview: boolean;
}

/**
 * 开窗时记下的宿主 Context（与 AboutWindow / InstanceConflictWindow 同一个思路）。
 */
let host_ctx: common.Context | null = null;

/** 取 UIAbility 上下文：优先用开窗时记下的那份，取不到再退回 getContext()。 */
function ui_context(): common.UIAbilityContext {
  const ctx: common.Context = host_ctx !== null ? host_ctx : getContext() as common.Context;
  return ctx as common.UIAbilityContext;
}

/** 按原版打开这个子窗口。 */
export function open_update_window(ctx: common.Context, args: ReleaseInfoArgs): void {
  host_ctx = ctx;
  AppStorage.setOrCreate<string>(ARG_KEY_TAG, args.tagName);
  AppStorage.setOrCreate<string>(ARG_KEY_NAME, args.releaseName);
  AppStorage.setOrCreate<string>(ARG_KEY_PUBLISHED_AT, args.publishedAt);
  AppStorage.setOrCreate<string>(ARG_KEY_BODY, args.body);
  AppStorage.setOrCreate<string>(ARG_KEY_RELEASE_URL, args.releaseUrl);
  AppStorage.setOrCreate<boolean>(ARG_KEY_ALLOW_MIRROR, args.allowMirrorFallback);
  AppStorage.setOrCreate<boolean>(ARG_KEY_READ_ONLY, args.readOnlyPreview);
  AppStorage.setOrCreate<boolean>(RESULT_KEY_LATER, false);
  AppStorage.setOrCreate<boolean>(RESULT_KEY_OPENED, false);

  const spec: SubWindowSpec = {
    name: WINDOW_NAME,
    page: PAGE_PATH,
    title: S_TITLE,
    width: 760,
    height: 700,
    resizable: true,                // ResizeMode="CanResize"
    minWidth: 660,
    minHeight: 580,
    modal: true,                    // WindowStartupLocation="CenterOwner"
  };
  SubWindowHost.open(ctx, spec).catch((error: BusinessError): void => {
    hilog.error(DOMAIN, TAG, '打开失败: %{public}s', error.message);
  });
}

/** 平台替换 3(a)：真做 —— 用系统浏览器打开 URL。 */
function open_url(url: string): boolean {
  try {
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: url,
    };
    ui_context().startAbility(want).catch((error: BusinessError): void => {
      hilog.error(DOMAIN, TAG, 'startAbility 失败: %{public}s', error.message);
    });
    return true;
  } catch (error) {
    hilog.error(DOMAIN, TAG, 'open_url 失败: %{public}s', (error as BusinessError).message);
    return false;
  }
}

/** 平台替换 2：去掉 Markdown 的代码围栏与 HTML 注释以外的东西一律不动。 */
function plain_release_notes(body: string): string {
  return body.replace(/```/g, '').replace(/<!--[\s\S]*?-->/g, '').trim();
}

/** 表头下方的版本徽标（见「版本徽标的落点」）。 */
@Component
struct VersionBadge {
  @Prop badgeText: string = '';

  build() {
    Text(this.badgeText)
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor(ON_ACCENT)
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .borderRadius(12)
      .backgroundColor(ACCENT);
  }
}

/** Row Auto 的三列版本信息（* / 24 / * / 24 / *）。 */
@Component
struct VersionField {
  @Prop labelText: string = '';
  @Prop valueText: string = '';

  build() {
    Column() {
      Text(this.labelText)
        .fontSize(11)
        .fontColor(MUTED_TEXT)
        .width('100%');
      Text(this.valueText)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT)
        .width('100%')
        .margin({ top: 4 });
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1);
  }
}

@Entry
@Component
struct UpdateWindow {
  @State currentVersion: string = '0.0.0';
  @State latestVersion: string = '';
  @State releaseName: string = '';
  @State publishedAt: string = '';
  @State releaseBody: string = '';
  @State releaseUrl: string = '';
  @State statusText: string = '';
  @State readOnlyPreview: boolean = false;

  aboutToAppear(): void {
    this.latestVersion = AppStorage.get<string>(ARG_KEY_TAG) ?? '';
    this.releaseName = AppStorage.get<string>(ARG_KEY_NAME) ?? '';
    this.publishedAt = AppStorage.get<string>(ARG_KEY_PUBLISHED_AT) ?? '';
    this.releaseBody = AppStorage.get<string>(ARG_KEY_BODY) ?? '';
    this.releaseUrl = AppStorage.get<string>(ARG_KEY_RELEASE_URL) ?? '';
    this.readOnlyPreview = AppStorage.get<boolean>(ARG_KEY_READ_ONLY) ?? false;
    this.load_current_version();
  }

  /** 平台替换 1：读 bundleManager 的 versionName（真做）。 */
  private load_current_version(): void {
    try {
      bundleManager.getBundleInfoForSelf(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
        .then((info: bundleManager.BundleInfo): void => {
          this.currentVersion = info.versionName;
        })
        .catch((error: BusinessError): void => {
          hilog.error(DOMAIN, TAG, 'getBundleInfoForSelf 失败: %{public}s', error.message);
        });
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'getBundleInfoForSelf 抛错: %{public}s',
        (error as BusinessError).message);
    }
  }

  /** 原版 OnOpenReleaseClick：用浏览器打开发布页（真做）。 */
  private on_open_release(): void {
    const target: string = this.releaseUrl.length > 0 ? this.releaseUrl : FALLBACK_RELEASE_URL;
    open_url(target);
  }

  /**
   * 原版 OnUpdateClick → DownloadAndInstallAsync。
   * 平台替换 3：不做下载/静默安装，改为打开发布页 + 明写原因。
   */
  private on_update(): void {
    if (this.readOnlyPreview) {
      return;
    }
    const target: string = this.releaseUrl.length > 0 ? this.releaseUrl : GITHUB_URL;
    const opened: boolean = open_url(target);
    AppStorage.setOrCreate<boolean>(RESULT_KEY_OPENED, opened);
    this.statusText = S_UPDATE_REASON;
  }

  /** 原版 OnLaterClick。 */
  private on_later(): void {
    AppStorage.setOrCreate<boolean>(RESULT_KEY_LATER, true);
    SubWindowHost.close(WINDOW_NAME);
  }

  /** 版本号行的三列。 */
  @Builder
  version_row() {
    Row() {
      VersionField({ labelText: S_CURRENT_LABEL, valueText: 'v' + this.currentVersion });
      Column().width(24);
      VersionField({ labelText: S_LATEST_LABEL, valueText: this.latestVersion });
      Column().width(24);
      VersionField({ labelText: S_PUBLISHED_LABEL, valueText: this.publishedAt });
    }
    .width('100%')
    .alignItems(VerticalAlign.Top);
  }

  /** notice：徽标行（右对齐）+ 版本三列（见「版本徽标的落点」）。 */
  @Builder
  notice() {
    Column() {
      Row() {
        VersionBadge({ badgeText: this.latestVersion });
      }
      .width('100%')
      .justifyContent(FlexAlign.End);

      this.version_row();
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%');
  }

  /** Border Style=SettingsSection Padding="18" 里的 Release 说明。 */
  //
  // ⚠ 这里没有直接用 SettingsSection 组件：原版这个卡片里的
  //   FlowDocumentScrollViewer 是 Height="*"（吃掉卡片剩余高度），
  //   而 SettingsSection 的根 Column 高度是自适应内容的，
  //   把 layoutWeight(1) 的 Scroll 塞进去会塌陷成 0。
  //   所以这里按 SettingsSection 的**同一份视觉规格**
  //   （CARD 底 / 1px BORDER 边 / 圆角 16 / Padding 18）直接铺在外层 Column 上，
  //   内部 Scroll 用 layoutWeight(1)，观感与行为都与原版一致。
  @Builder
  body() {
    Column() {
      // Grid Row 0：ReleaseName（18 SemiBold Wrap）+「查看完整 Release」按钮
      Row() {
        Text(this.releaseName)
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(TEXT)
          .layoutWeight(1);
        Row() {
          FluentSymbol({ iconName: 'Open20', iconSize: 14, iconColor: TEXT });
          Text(S_OPEN_RELEASE)
            .fontSize(12)
            .fontColor(TEXT)
            .margin({ left: 6 });
        }
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .borderRadius(8)
        .onClick((): void => { this.on_open_release(); })
        .margin({ left: 12 });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      Column().height(8);            // Grid Row 1 = 8

      // Grid Row 2：Release 说明（原版是 Markdown → FlowDocument，见平台替换 2）
      Scroll() {
        Text(plain_release_notes(this.releaseBody))
          .fontSize(12)
          .fontColor(PREVIEW_TEXT)
          .lineHeight(19)
          .width('100%');
      }
      .width('100%')
      .layoutWeight(1)
      .padding(10)
      .borderRadius(10)
      .backgroundColor(PREVIEW_CHROME)
      .scrollBar(BarState.Auto)
      .align(Alignment.Top);
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({
      left: SETTINGS_SECTION_PADDING, right: SETTINGS_SECTION_PADDING,
      top: SETTINGS_SECTION_PADDING, bottom: SETTINGS_SECTION_PADDING,
    })
    .borderRadius(SETTINGS_SECTION_CORNER)
    .backgroundColor(CARD)
    .border({ width: 1, color: BORDER });
  }

  /** Row Auto 的第一行：进度区（原版 ProgressVisibility）。 */
  @Builder
  footer() {
    if (this.statusText.length > 0) {
      Column() {
        // 平台替换 4：只显示不确定态，不显示伪造的百分比
        Progress({ value: 0, total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(7)
          .color(ACCENT);
        Text(this.statusText)
          .fontSize(12)
          .fontColor(TEXT)
          .width('100%')
          .margin({ top: 8 });
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%');
    }
  }

  @Builder
  actions() {
    SecondaryButton({
      label: S_REMIND_LATER,
      minButtonWidth: 112,
      on_action: (): void => { this.on_later(); },
    })
      .margin({ right: 8 });
    PrimaryButton({
      label: S_UPDATE_NOW,
      minButtonWidth: 132,
      actionEnabled: !this.readOnlyPreview,
      on_action: (): void => { this.on_update(); },
    });
  }

  build() {
    Column() {
      SubWindowShell({
      windowName: WINDOW_NAME,
      title: S_TITLE,
      subtitle: S_SUBTITLE,
      gap: SUBWINDOW_ROW_GAP,       // 行 1 = 16
      hasNotice: true,
      noticeGap: 18,                // 行 3 = 18
      hasFooter: true,              // 行 6 的第一行（无状态时高度 0）
      footerGap: 18,                // 行 5 = 18
      hasActions: true,
      actionGap: 16,                // 原版按钮条 Margin="0,16,0,0"
      actionsSplit: false,          // 两个按钮都靠右
      notice: (): void => { this.notice(); },
      content: (): void => { this.body(); },
      footer: (): void => { this.footer(); },
      actions: (): void => { this.actions(); },
    });
    }
  }
}
