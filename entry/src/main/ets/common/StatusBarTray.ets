// StatusBarTray.ets —— 鸿蒙 PC 的「系统托盘」（状态栏图标方案）
//
// ★★ 为什么原来那套不算托盘（用户 2026-10-18 反馈"你这根本就不是托盘"）★★
//   原实现（common/TrayManager.ets）是**常驻通知 + 最小化到任务栏**：
//     · notificationManager.publish 发一条常驻通知，点通知 WantAgent 拉起 Ability；
//     · 关闭窗口走 windowWillClose → minimize() ⇒ 图标落在 **Dock/任务栏**。
//   这两件事都不是"托盘"：通知是通知中心的一条消息，minimize 是任务栏的一个窗口项。
//   鸿蒙 PC 上真正的托盘 = **系统状态栏图标**（屏幕右上角状态栏里的应用图标）。
//
// ★★ 官方答案（华为开发者论坛同名问题的采纳答案 + 官方行业解决方案文档）★★
//   「当前未提供直接调用即可收起到托盘的接口，开发者可以通过调用
//     addToStatusBar 和 hideAbility 接口来实现。」
//   即两步：
//     ① statusBarManager.addToStatusBar() 把应用图标加进系统状态栏；
//     ② context.hideAbility() 关闭/最小化 Dock 栏图标。
//   恢复：状态栏图标点击事件 → context.showAbility()。
//   （用户转贴的那份"WindowManager / WindowAgent / WindowState.MINIMIZED /
//     WindowFlag.HIDE_WHEN_MINIMIZED / setWindowIcon"答案是**编造的** ——
//     鸿蒙没有这些 API，照抄必然编译不过。）
//
// 官方文档：
//   《应用接入状态栏》      developer.huawei.com/consumer/cn/doc/harmonyos-guides/statusbar-extension-guide
//   《PC应用通过系统托盘后台保活》 .../doccenter-industry-solutions/pc_status_bar-0000002551100435
//   《statusBarManager(状态栏管理服务)》 .../harmonyos-references/statusbar-extension-manager
//
// 交互约定（鸿蒙 PC 托盘明确区分左右键，且不支持代码拦截改映射）：
//   · 左键：本实现把 quickOperation.abilityName 留空 ⇒ 点击不走弹窗 Ability，
//    而是触发 statusBarIconClick 事件，由这里 showAbility() 唤回主窗口；
//   · 右键：statusBarGroupMenu 挂两个菜单项（显示主窗口 / 退出），
//    菜单项设 notifyOnly: true + menuCode ⇒ 点击不回拉 Ability，
//    而是触发 rightMenuClick 事件，由这里自己执行业务。
//
// ★ 本文件只做"纯 UI 托盘"，**不动**现有长时任务保活（BackgroundKeepAlive）。
//   官方那个"用 NEW_PROCESS_ATTACH_TO_STATUS_BAR_ITEM 拉起绑定托盘的新进程"的
//   增强用法在本工程**明确不做**：预览画面来自 libim_core.so 的渲染器单例，
//   换进程就挂不上画面（见 docs/上游1.8.5-pre2对照报告.md § 二·5 的硬冲突分析）。
import common from '@ohos.app.ability.common';
import { statusBarManager } from '@kit.DeskTopExtensionKit';
import { emitter } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { DrawableDescriptor } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@ohos.base';
import { TRAY_AVAILABLE_KEY } from './WindowServices';

const TAG: string = 'StatusBarTray';

/** 右键菜单项的回传编码（与 buildGroupMenu() 里的 menuCode 一一对应）。 */
const MENU_SHOW: string = 'show';
const MENU_QUIT: string = 'quit';

export class StatusBarTray {
  private static instance: StatusBarTray | null = null;

  private context: common.UIAbilityContext | null = null;
  private added: boolean = false;
  /** 能力复核不通过时的降级回调（由调用方注入，通常是拉起通知托盘）。 */
  private onFallback: (() => void) | null = null;

  static shared(): StatusBarTray {
    if (StatusBarTray.instance === null) {
      StatusBarTray.instance = new StatusBarTray();
    }
    return StatusBarTray.instance;
  }

  /**
   * 接入状态栏托盘。失败只记日志并返回 false —— 调用方应降级回通知方案，
   * 不能让托盘接入失败影响主流程（投屏）。
   *
   * @param context   UIAbilityContext（addToStatusBar / hideAbility 都要它）
   * @param onFallback 可选：异步能力复核发现设备根本不支持状态栏图标时回调，
   *                  让调用方补上通知方案（见 verifyCapability 的说明）
   */
  initialize(context: common.UIAbilityContext, onFallback?: () => void): boolean {
    this.context = context;
    this.onFallback = onFallback ?? null;
    try {
      this.registerEvents();
      this.addIcon();
      this.added = true;
      AppStorage.setOrCreate(TRAY_AVAILABLE_KEY, true);
      hilog.info(0x0000, TAG, '状态栏托盘图标已接入');
      this.verifyCapability();
      return true;
    } catch (error) {
      const failure = error as BusinessError;
      this.added = false;
      AppStorage.setOrCreate(TRAY_AVAILABLE_KEY, false);
      hilog.warn(0x0000, TAG, '状态栏托盘接入失败（降级回通知方案）：%{public}s', failure.message);
      return false;
    }
  }

  /**
   * 异步复核设备是否真的支持状态栏图标接入（官方开发流程第 0 步）。
   *
   * ★ 为什么同步 addToStatusBar 成功了还要复核：官方原话 ——
   *   「如果不支持，则调用 addToStatusBar 后，界面上无效果」。
   *   即**不支持的设备上它不抛错、只是静默什么都不做**。此时 added=true
   *   是个假象：点关闭会走 hideAbility()，Dock 项被收掉、状态栏又没图标、
   *   通知方案也没启用 ⇒ 应用像"蒸发"一样消失，用户没有任何入口能把它唤回。
   * ★ 所以这里用 isStatusBarCapabilitySupported（API 26 起）再确认一次；
   *   确认不支持就自我降级（removeIcon + 回调 onFallback），让通知方案补位。
   * ★ 查询本身失败（老 SDK 没这个方法会抛 TypeError）时**保持已接入**：
   *   宁可保留一次可能无效的接入，也不要因为一次查询失败就推翻主路径。
   */
  private verifyCapability(): void {
    if (this.context === null) {
      return;
    }
    try {
      statusBarManager.isStatusBarCapabilitySupported(this.context).then((supported: boolean): void => {
        if (supported) {
          hilog.info(0x0000, TAG, '设备支持状态栏图标接入，复核通过');
          return;
        }
        hilog.warn(0x0000, TAG, '设备不支持状态栏图标接入，自我降级');
        this.removeIcon();
        if (this.onFallback !== null) {
          this.onFallback();
        }
      }).catch((error: BusinessError): void => {
        hilog.warn(0x0000, TAG, 'isStatusBarCapabilitySupported 查询失败（保持已接入）：%{public}s',
          error.message);
      });
    } catch (error) {
      const failure = error as BusinessError;
      hilog.warn(0x0000, TAG, 'isStatusBarCapabilitySupported 调用抛错（保持已接入）：%{public}s',
        failure.message);
    }
  }

  isAdded(): boolean {
    return this.added;
  }

  // ───────────────────────── 图标 ─────────────────────────

  /**
   * 把应用图标加进系统状态栏。
   *
   * 图标必须是 **white / black 两套** PixelMap（24vp×24vp）：系统按状态栏底色
   * 深浅自动择一渲染，只给一套会在另一档底色下看不见。两套图由
   * resources/base/media/tray_icon_white|black.png 提供（96px，系统自行缩放到 24vp）。
   *
   * quickOperation.abilityName **刻意留空串**：留空时点击不弹自定义弹窗 Ability，
   * 改为触发 statusBarIconClick 事件，由 registerEvents() 里的回调自己处理
   * （我们要的是"点一下把主窗口唤回"，不是一个空弹窗）。
   */
  private addIcon(): void {
    if (this.context === null) {
      throw new Error('StatusBarTray.addIcon: context 未设置');
    }
    const ctx: common.UIAbilityContext = this.context;
    // ★ getDrawableDescriptor / getPixelMap / addToStatusBar 都是**同步抛错**的
    //   API（ArkTS 严格模式逐个报警 "Function may throw exceptions. Special
    //   handling is required."）。initialize() 外层虽有 try-catch 兜底降级，
    //   但就地包一层才能把失败原因写进错误信息（哪一步、什么码），
    //   否则日志里只有一句光秃秃的 BusinessError，排障时对不上号。
    let whiteMap: image.PixelMap | undefined = undefined;
    let blackMap: image.PixelMap | undefined = undefined;
    try {
      const resManager = ctx.resourceManager;
      const whiteDesc: DrawableDescriptor =
        resManager.getDrawableDescriptor($r('app.media.tray_icon_white').id) as DrawableDescriptor;
      const blackDesc: DrawableDescriptor =
        resManager.getDrawableDescriptor($r('app.media.tray_icon_black').id) as DrawableDescriptor;
      whiteMap = whiteDesc.getPixelMap();
      blackMap = blackDesc.getPixelMap();
    } catch (iconError) {
      const failure: BusinessError = iconError as BusinessError;
      throw new Error(`StatusBarTray.addIcon: 托盘图标资源读取失败` +
        `（code=${failure.code}）：${failure.message}`);
    }
    if (whiteMap === undefined || blackMap === undefined) {
      throw new Error('StatusBarTray.addIcon: 托盘图标 PixelMap 为空');
    }

    const item: statusBarManager.StatusBarItem = {
      icons: {
        white: whiteMap,
        black: blackMap,
      },
      quickOperation: {
        title: 'iPhoneMirror',
        height: 1,
        abilityName: '',
        moduleName: 'entry',
      },
      statusBarGroupMenu: this.buildGroupMenu(),
      hoverTips: 'iPhoneMirror — 点击显示主窗口',
    };
    try {
      statusBarManager.addToStatusBar(ctx, item);
    } catch (addError) {
      const failure: BusinessError = addError as BusinessError;
      throw new Error(`StatusBarTray.addIcon: addToStatusBar 失败` +
        `（code=${failure.code}）：${failure.message}`);
    }
  }

  /**
   * 右键菜单：两个一级项，都设 notifyOnly + menuCode。
   *
   * ★ notifyOnly 必须为 true 且必须给 menuCode，点击才会以 rightMenuClick 事件
   *   回传（否则系统会按 menuAction.abilityName 去拉 Ability，拿不到"退出"这种
   *   自定义业务）。官方样例（《应用接入状态栏》）逐字如此：
   *     `let menuCode = data['menuCode'] as string;`
   * ★ menuCode 挂两份（值相同，官方明确"MenuItem 的会覆盖 menuAction 的"）：
   *   StatusBarMenuAction.menuCode 自 6.1.1(24) 起**已废弃**，官方建议改用
   *   StatusBarMenuItem.menuCode（本工程 compileSdk 26 已包含该字段）；
   *   旧字段保留是为兼容更早版本的系统，两份同值不会冲突。
   */
  private buildGroupMenu(): statusBarManager.StatusBarGroupMenu[] {
    const showAction: statusBarManager.StatusBarMenuAction = {
      abilityName: 'EntryAbility',
      notifyOnly: true,
      menuCode: MENU_SHOW,
    };
    const quitAction: statusBarManager.StatusBarMenuAction = {
      abilityName: 'EntryAbility',
      notifyOnly: true,
      menuCode: MENU_QUIT,
    };
    const items: statusBarManager.StatusBarMenuItem[] = [
      { title: '显示主窗口', menuCode: MENU_SHOW, menuAction: showAction },
      { title: '退出', menuCode: MENU_QUIT, menuAction: quitAction },
    ];
    const groups: statusBarManager.StatusBarGroupMenu[] = [];
    groups.push(items);
    return groups;
  }

  // ───────────────────────── 事件 ─────────────────────────

  /**
   * 注册托盘的左右键事件。
   *
   * 左键（statusBarIconClick）：官方说明该事件**当前只回传左键**，
   * 所以不必判断 iconClickType，收到即视为"唤回主窗口"。
   */
  private registerEvents(): void {
    statusBarManager.on('statusBarIconClick', (): void => {
      hilog.info(0x0000, TAG, '托盘图标被点击 → 唤回主窗口');
      this.showMainWindow();
    });

    statusBarManager.on('rightMenuClick', (eventData: emitter.EventData): void => {
      const data = eventData.data as Record<string, string>;
      const code: string = data['menuCode'];
      hilog.info(0x0000, TAG, '托盘右键菜单：%{public}s', code);
      if (code === MENU_SHOW) {
        this.showMainWindow();
      } else if (code === MENU_QUIT) {
        this.quitApp();
      }
    });
  }

  /** 从托盘唤回主窗口。优先 showAbility()，失败再降级 startAbility()。 */
  showMainWindow(): boolean {
    if (this.context === null) {
      return false;
    }
    try {
      this.context.showAbility().then((): void => {
        hilog.info(0x0000, TAG, 'showAbility 成功，主窗口已唤回');
      }).catch((error: BusinessError): void => {
        hilog.warn(0x0000, TAG, 'showAbility 失败，降级 startAbility：%{public}s', error.message);
        this.startAbilityFallback();
      });
      return true;
    } catch (error) {
      const failure = error as BusinessError;
      hilog.warn(0x0000, TAG, 'showAbility 抛错，降级 startAbility：%{public}s', failure.message);
      this.startAbilityFallback();
      return false;
    }
  }

  private startAbilityFallback(): void {
    if (this.context === null) {
      return;
    }
    try {
      this.context.startAbility({
        bundleName: this.context.abilityInfo.bundleName,
        abilityName: this.context.abilityInfo.name,
      });
    } catch (error) {
      const failure = error as BusinessError;
      hilog.warn(0x0000, TAG, 'startAbility 降级也失败：%{public}s', failure.message);
    }
  }

  /**
   * 收进托盘（官方第二步：hideAbility 关闭/最小化 Dock 栏图标）。
   *
   * ★ 与通知方案 minimize() 的区别：minimize() 只是把窗口收进 Dock/任务栏，
   *   Dock 里仍然留着一个窗口项；hideAbility() 是官方文档给托盘场景指定的动作 ——
   *   Ability 整体退到后台，Dock 项消失，只剩右上角状态栏图标，进程照活。
   *   点状态栏图标 → showAbility() 一键唤回（见 showMainWindow()）。
   *
   * 由 windowWillClose 回调调用：返回 true ⇒ 上层 resolve(true) ⇒ Ability 不被销毁。
   * hideAbility() 是异步的，这里"乐观返回 true"：即便它失败，结果也只是窗口没收起
   * （仍停在桌面上），用户再点一次关闭即可 —— 绝不会出现"点了关闭、应用整个退出"。
   */
  hideToTray(): boolean {
    if (this.context === null) {
      return false;
    }
    try {
      this.context.hideAbility().then((): void => {
        hilog.info(0x0000, TAG, 'hideAbility 成功，已收进托盘');
      }).catch((error: BusinessError): void => {
        hilog.warn(0x0000, TAG, 'hideAbility 失败：%{public}s', error.message);
      });
      return true;
    } catch (error) {
      const failure = error as BusinessError;
      hilog.warn(0x0000, TAG, 'hideAbility 抛错：%{public}s', failure.message);
      return false;
    }
  }

  /**
   * 退出应用（托盘右键「退出」）。
   *
   * 必须先摘掉状态栏图标再 destroy —— 反序的话进程没了、图标还挂在状态栏上，
   * 用户会看到一个点了没反应的死图标，只能重启才能清掉。
   */
  quitApp(): void {
    this.removeIcon();
    if (this.context === null) {
      return;
    }
    try {
      this.context.terminateSelf();
    } catch (error) {
      const failure = error as BusinessError;
      hilog.warn(0x0000, TAG, 'terminateSelf 失败：%{public}s', failure.message);
    }
  }

  /** 摘掉状态栏图标（应用退出/Ability 销毁时调用）。 */
  removeIcon(): void {
    if (this.context === null || !this.added) {
      return;
    }
    try {
      statusBarManager.removeFromStatusBar(this.context);
      this.added = false;
      AppStorage.setOrCreate(TRAY_AVAILABLE_KEY, false);
      hilog.info(0x0000, TAG, '状态栏托盘图标已移除');
    } catch (error) {
      const failure = error as BusinessError;
      hilog.warn(0x0000, TAG, '移除状态栏托盘图标失败：%{public}s', failure.message);
    }
  }
}
