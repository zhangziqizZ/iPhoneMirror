import { AbilityConstant, UIAbility, Want, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { setSystemDark, SYSTEM_DARK_KEY } from '../common/theme_manager';
import { WINDOW_ACRYLIC_RESULT_KEY, WINDOW_SHADOW_RESULT_KEY, APP_WINDOW_VISIBLE_KEY,
  MINIMIZE_TO_TRAY_KEY } from '../common/WindowServices';
import { open_app_preferences, load_acrylic_preferences, load_language_preference,
  load_hide_pointer_preference, load_glow_preferences, load_tray_preferences } from '../common/AppPreferences';
import { vp_to_px_ratio } from '../common/SubWindow';
import { BusinessError } from '@ohos.base';
import { open_instance_conflict, InstanceConflictRequest } from '../pages/windows/InstanceConflictWindow';
import { TrayManager } from '../common/TrayManager';
import { StatusBarTray } from '../common/StatusBarTray';
import { setLogFile, getCaptureStatus, CaptureStatus } from 'libim_core.so';
// ★ 只导入启动期要用的两个入口：`t()` 由页面自己导入，Ability 这里不用
//   （留着未使用的导入在严格模式下就是噪声）。
import { init_language, sync_system_language_at_launch } from '../common/i18n';

const TAG: string = 'iPhoneMirror';

/**
 * 主窗口最小尺寸 —— 原版 src/App/MainWindow.xaml 根元素：
 *   Width="1540" Height="900" MinWidth="1280" MinHeight="700" ResizeMode="CanResize"
 * WPF 的这几个数都是 DIP（设备无关单位），鸿蒙里对等的单位是 **vp**。
 *
 * 为什么要设：主界面是「左侧图标条（收起 48 / 展开 208vp）+ 中间预览 + 右侧控制
 * 面板」三栏布局，不设下限时用户能把窗口拖得很小，三栏互相挤扁、控件重叠变形。
 */
const MAIN_WINDOW_MIN_WIDTH_VP: number = 1280;
const MAIN_WINDOW_MIN_HEIGHT_VP: number = 700;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, TAG, '%{public}s', 'EntryAbility.onCreate');
    // ★ 半透明窗口的两个偏好必须**跨启动保留**：AppStorage 是进程内内存态，
    //   进程一退就没了 ⇒ 用户选完浓度重启又回默认值（= 没保存）。
    //   ★ 顺序要求：必须在**任何地方访问这两个键之前**（尤其 UI 组件里的 @StorageLink）
    //     先把磁盘值读回 AppStorage —— UI 的 @StorageLink 首次读取会**建立**这个键
    //     （用的是它的默认值），一旦它先建了，后面读回来的存档值就盖不住了。
    //   ★ 对照：开发者模式（DEVELOPER_MODE_KEY）**有意**不持久化 —— 它是调试入口，
    //     每次启动都该回到关闭态。
    //   ★ 为什么之前用的 PersistentStorage 实测不行：它自己决定何时刷盘，用户直接关掉
    //     /杀进程时来不及 ⇒ 现在换成显式 putSync + flushSync（见 AppPreferences.ets）。
    open_app_preferences(this.context);
    load_acrylic_preferences();
    // ★ 界面语言：把磁盘存档读回 AppStorage —— 与半透明同理，必须在任何 UI 装载
    //   **之前**，否则 t() 首次读取会先建键，这里再写就变成普通更新、用户看到的还是默认值。
    load_language_preference();
    // 反控接管时的指针偏好（默认保持可见，见 HIDE_POINTER_ON_TAKEOVER_KEY 的注释）。
    load_hide_pointer_preference();
    load_glow_preferences();
    load_tray_preferences();
    // ★ 读回存档后立刻把档位灌进 i18n 的缓存（否则首帧 t() 会用默认值建缓存；
    //   且缓存必须在这里建立 —— 主窗每 500ms 整树重渲染，t() 每秒上千次，
    //   不能每次都去读 AppStorage）。
    init_language();
    // ★ 系统层偏好语言对齐只在这里做一次：它会触发全局配置更新 + 整树 rebuild，
    //   放在启动（UI 还没装载）成本为零；放在点击回调里就是"切一次语言卡一下"。
    sync_system_language_at_launch();
    // 把原生 Core 的诊断日志重定向进应用沙箱，否则它默认写到系统 temp 目录
    // （iPhoneMirror-capture.log），应用读不到 ⇒ 关于页"实时日志"永远空白。
    // 必须在任何原生写入发生之前设置（im_initialize 会立即写首条会话头）。
    // 沙箱目录由 native Logging.cpp 的 create_directories 自行创建，这里不用提前建。
    try {
      const logPath: string = this.context.filesDir + '/iPhoneMirror/Logs/startup.log';
      const code: number = setLogFile(logPath);
      if (code !== 0) {
        hilog.warn(0x0000, TAG, 'setLogFile 返回非零（%{public}d），日志可能仍落 temp', code);
      } else {
        hilog.info(0x0000, TAG, '原生日志已重定向到 %{public}s', logPath);
      }
    } catch (error) {
      const failure = error as BusinessError;
      hilog.warn(0x0000, TAG, 'setLogFile 失败（非致命）：%{public}s', failure.message);
    }
  }

  onDestroy(): void {
    hilog.info(0x0000, TAG, '%{public}s', 'EntryAbility.onDestroy');
    // Ability 真要没了：摘状态栏托盘图标 + 撤常驻通知（fallback 方案）。
    // ★ 托盘右键「退出」已在 StatusBarTray.quitApp() 里先摘过图标，这里对
    //   added=false 是空操作；真正兜的是系统侧 graceful 销毁（关机流程被
    //   onPrepareToTerminate 放行、或用户关掉「最小化到托盘」后的正常退出）——
    //   不摘的话进程死后状态栏会留一个点了没反应的死图标，只能重启才清得掉。
    StatusBarTray.shared().removeIcon();
    TrayManager.shared().remove();
  }

  /**
   * 单实例守护 —— 上游用命名互斥体检测「另一份 iPhoneMirror 已在运行」并弹冲突窗。
   * 鸿蒙 UIAbility 默认 singleton：第二次启动不会新建进程，而是复用本实例并触发
   * onNewWant，这正是「另一份已在运行」的等价信号。直接弹实例冲突窗口（与原版一致）。
   */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, TAG, '%{public}s', 'EntryAbility.onNewWant');
    try {
      open_instance_conflict(this.context, new InstanceConflictRequest(
        1, false,
        (continueWithCurrent: boolean): void => {
          // 鸿蒙只有这一份实例：continueWithCurrent=true 维持现状；false 在原版里是
          // 「关掉当前、切到新实例」，这里没有可切换的实例，仅记录用户选择。
          hilog.info(0x0000, TAG, '实例冲突结果：%{public}s',
            continueWithCurrent ? '继续当前实例' : '用户选择切换（无第二实例可切换）');
        }), true);
    } catch (error) {
      const failure = error as BusinessError;
      hilog.warn(0x0000, TAG, 'open_instance_conflict failed: %{public}s', failure.message);
    }
  }

  /**
   * 应用级退出的兜底拦截 —— Dock 右键「关闭」、关机等**绕过窗口级事件**的整应用退出。
   *
   * ★ 回调优先级（官方《退出应用（PC/2合1设备）》）：
   *   窗口关闭：windowWillClose → windowStageClose → onPrepareToTerminate(Async)。
   *   本工程已注册 windowWillClose ⇒ 点窗口右上角 × 走那条，**不会**走到这里；
   *   这里兜的是从 Dock 右键菜单关闭、从托盘退出、关机这类整应用级退出
   *   （AbilityStage 级 onPrepareTermination 未实现，UIAbility 级这个才会被回调）。
   * ★ 返回值语义（官方 API 参考，极易记反，逐字核对过）：
   *   true  = **取消**本次终止流程，Ability 不退出（之后自行决定何时 terminateSelf）；
   *   false = 继续终止（正常退出）。
   * ★ 配合 hideAbility() = 官方「关闭应用之后，点击托盘，再显示应用界面到前台」
   *   模式：进程留后台、AirPlay/mDNS 线程照跑，状态栏图标仍在，点图标 showAbility() 唤回。
   * ★ 需要 ohos.permission.PREPARE_APP_TERMINATE —— 已声明于 module.json5：
   *   normal + system_grant，安装即授权，不弹框、不走 ACL（不会 9568289）。
   * ★ 官方注明该回调仅在 2in1 / 平板正常回调（本工程 deviceTypes 正是 2in1）。
   */
  onPrepareToTerminate(): boolean {
    const minimizeToTray: boolean = AppStorage.get<boolean>(MINIMIZE_TO_TRAY_KEY) ?? true;
    if (minimizeToTray && StatusBarTray.shared().isAdded()) {
      hilog.info(0x0000, TAG, '%{public}s', 'onPrepareToTerminate：拦截退出，收进托盘');
      StatusBarTray.shared().hideToTray();
      return true;
    }
    hilog.info(0x0000, TAG, '%{public}s', 'onPrepareToTerminate：允许退出');
    return false;
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(0x0000, TAG, '%{public}s', 'EntryAbility.onWindowStageCreate');
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(0x0000, TAG, '%{public}s', 'Succeeded in loading the content.');

      // 上游主窗口是 ui:FluentWindow 且 ExtendsContentIntoTitleBar="True" ——
      // 内容延伸到标题栏，系统只画右上角三键，不画标题栏背景/标题文字。
      //
      // 鸿蒙等价做法 = 沉浸式标题栏：
      //   1) 隐藏窗口装饰栏（本块），应用自绘标题区内容（pages/Index.ets 的 header）；
      //   2) 系统三键（最小化/最大化/关闭）仍由系统画在**右上角**，位置由系统分配，
      //      应用内容需在右侧给它让位（见 Index.ets 的 TITLE_BUTTON_RESERVED_WIDTH）；
      //   3) 三键颜色由系统按**应用的 colorMode** 推导 —— 所以应用切换深浅色时必须
      //      调 ApplicationContext.setColorMode()（见 Index.ets 的 sync_system_color_mode），
      //      否则会出现「应用已是深色、系统三键仍是浅色」而看不见。
      try {
        const mainWindow: window.Window = windowStage.getMainWindowSync();
        mainWindow.setWindowDecorVisible(false);
        // 自定义标题栏：保留系统三键但把它们所在区域抬高一点，避免与自绘标题内容贴太近。
        // 单位 vp（与窗口装饰高度 API 一致）。
        try {
          mainWindow.setWindowDecorHeight(56);
        } catch (decorHeightError) {
          const dhFailure = decorHeightError as BusinessError;
          hilog.warn(0x0000, TAG, 'setWindowDecorHeight failed: %{public}s', dhFailure.message);
        }

        // ── 托盘接入：先试官方「状态栏图标」，失败再降级回常驻通知 ──
        //
        // ★ 2026-10-18：用户反馈"你这根本就不是托盘"。原来的做法是
        //   「常驻通知 + minimize() 到任务栏」—— 通知是通知中心的一条消息、
        //   minimize 是 Dock 里的一个窗口项，两者都不是托盘。
        //   鸿蒙 PC 的官方托盘 = **系统状态栏图标**（屏幕右上角），
        //   官方原话：「当前未提供直接调用即可收起到托盘的接口，开发者可以通过
        //   调用 addToStatusBar 和 hideAbility 接口来实现」。
        //   ⇒ 这里优先走 StatusBarTray（addToStatusBar + hideAbility/showAbility）；
        //     设备不支持或调用失败时，才降级回 TrayManager 的通知方案。
        const trayReady: boolean = StatusBarTray.shared().initialize(this.context, (): void => {
          // 异步能力复核发现设备根本不支持状态栏图标时，由 StatusBarTray 回调到这里
          // 补上通知方案。为什么需要这条异步路径：官方明示「设备不支持时调用
          // addToStatusBar 后界面上无效果」—— **不抛错**，同步返回值全是假的。
          // 不补的话，点关闭会既没托盘图标、Dock 项又被 hideAbility 收掉，
          // 应用像"蒸发"一样消失，用户没有任何入口能把它唤回。
          TrayManager.shared().initialize(this.context, windowStage);
          hilog.warn(0x0000, TAG, '状态栏托盘能力复核未通过，已降级回通知方案');
        });
        if (!trayReady) {
          TrayManager.shared().initialize(this.context, windowStage);
        } else {
          hilog.info(0x0000, TAG, '托盘走状态栏图标方案，通知方案不启用（避免双重入口）');
        }

        // 拦截系统关闭按钮：点关闭 → 收起进托盘，而不是退出应用。
        //
        // ★ 托盘方案下的"收起"= hideAbility()（官方第二步：关闭/最小化 Dock 栏图标），
        //   进程与 AirPlay/mDNS 线程全部活着；点状态栏图标 → showAbility() 唤回。
        //   resolve(true) 表示不关闭；resolve(false)/reject 表示允许关闭。
        try {
          mainWindow.on('windowWillClose', (): Promise<boolean> => {
            return new Promise<boolean>((resolve: (keepOpen: boolean) => void): void => {
              // 设置页「最小化到托盘」开关（默认开，见 Index.ets 的 minimizeToTray）：
              // 关时点关闭 = 真退出，不再收托盘 —— 否则用户会遇上
              // "开关关了、点关闭却退不掉"的反馈与界面不一致。
              const minimizeToTray: boolean = AppStorage.get<boolean>(MINIMIZE_TO_TRAY_KEY) ?? true;
              if (!minimizeToTray) {
                hilog.info(0x0000, TAG, '「最小化到托盘」已关闭，允许退出');
                resolve(false);
                return;
              }
              if (StatusBarTray.shared().isAdded()) {
                const hidden: boolean = StatusBarTray.shared().hideToTray();
                resolve(hidden);
                return;
              }
              const hidden: boolean = TrayManager.shared().hideMainWindow();
              resolve(hidden);
            });
          });
        } catch (closeInterceptError) {
          const ciFailure = closeInterceptError as BusinessError;
          hilog.warn(0x0000, TAG, '拦截窗口关闭事件失败：%{public}s', ciFailure.message);
        }

        // ★ 窗口可见性 → AppStorage（性能用，见 APP_WINDOW_VISIBLE_KEY 的注释）：
        //   最小化后主窗的 500ms 心跳会照跑，用户点开恢复的那一刻这批 JS 正好和
        //   系统恢复动画抢 CPU ⇒ "打开动画掉帧"。这里把可见性广播出去，由 Index
        //   决定停/启心跳，并在恢复瞬间临时关掉全窗磨砂。
        //   枚举：SHOWN=1 / ACTIVE=2 / INACTIVE=3 / HIDDEN=4 / RESUMED=5 / PAUSED=6。
        try {
          windowStage.on('windowStageEvent', (event: window.WindowStageEventType): void => {
            const visible: boolean = event === window.WindowStageEventType.SHOWN
              || event === window.WindowStageEventType.ACTIVE
              || event === window.WindowStageEventType.RESUMED;
            AppStorage.setOrCreate(APP_WINDOW_VISIBLE_KEY, visible);
            hilog.info(0x0000, TAG, '窗口可见性：%{public}s（event=%{public}d）',
              visible ? '可见' : '不可见', event);
          });
        } catch (stageEventError) {
          const seFailure = stageEventError as BusinessError;
          hilog.warn(0x0000, TAG, '订阅 windowStageEvent 失败：%{public}s', seFailure.message);
        }

        // 半透明窗口（对齐 Win11 Acrylic 观感，已转正式特性）：主窗背景设为**全透明**，
        // 让 Index 根容器的带 alpha 底色（root_background_color()）直接混到桌面。
        // ★ 该调用**不需要权限**（@throws 仅 401/1300002），但透明效果能否透出桌面
        //   取决于系统合成器 —— 退化表现是「看不到桌面/只有 UI 自绘色」，不是黑屏：
        //   根容器 100%×100% 全覆盖，UI 半透明区域的兜底色永远是它自己。
        // ★ 开关关闭时根容器回实色 BACKGROUND，这里保持透明无副作用（被 UI 盖住）。
        try {
          mainWindow.setWindowBackgroundColor('#00000000');
        } catch (transparentError) {
          const transparentFailure = transparentError as BusinessError;
          hilog.warn(0x0000, TAG, 'setWindowBackgroundColor(transparent) failed: %{public}s',
            transparentFailure.message);
        }

        // 主窗口最小尺寸（原版 MinWidth="1280" MinHeight="700" DIP）。
        // 窗口 API 收的是 **px**，所以按屏幕密度把 vp 折算过去——与 SubWindowHost.open
        // 共用同一个 vp_to_px_ratio()，避免两处口径漂移；isForcible=true 才能把下限
        // 压到系统默认限制以下。失败只记日志：它只是"防呆"，不该影响启动。
        const ratio: number = vp_to_px_ratio();
        const limits: window.WindowLimits = {
          minWidth: Math.round(MAIN_WINDOW_MIN_WIDTH_VP * ratio),
          minHeight: Math.round(MAIN_WINDOW_MIN_HEIGHT_VP * ratio),
        };
        mainWindow.setWindowLimits(limits, true).then((): void => {
          hilog.info(0x0000, TAG, '主窗口最小尺寸已生效：%{public}s',
            `${limits.minWidth}x${limits.minHeight} px（密度 ${ratio.toFixed(3)}）`);
        }).catch((limitsError: BusinessError): void => {
          hilog.warn(0x0000, TAG, 'setWindowLimits failed: %{public}s', limitsError.message);
        });
      } catch (error) {
        const failure = error as BusinessError;
        hilog.warn(0x0000, TAG, 'setWindowDecorVisible failed: %{public}s', failure.message);
      }

      // 双主题：读取系统当前浅深写入 AppStorage，决定首屏方案。
      // 之后系统主题变化由 onConfigurationUpdate 持续更新（对应原版 ThemeService 监听系统）。
      try {
        const config: Configuration = this.context.config;
        setSystemDark(config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      } catch (error) {
        const failure = error as BusinessError;
        hilog.warn(0x0000, TAG, 'read system colorMode failed: %{public}s', failure.message);
      }

      // ★★ 窗口容器配色（@since 20，SessionManager，需 SET_WINDOW_TRANSPARENT）。
      //    setWindowBackgroundColor 只是**窗口内**兜底色（内容区），内容区透明后真正
      //    决定"能不能透视桌面"的是**容器色**的 Alpha。
      //    ★★ 401 的根因（1.0.33 实测）：官方《控制窗口外观》明写
      //      「该接口**不支持将非焦点态下的主窗口背景设置为透明**」⇒ inactiveColor
      //      必须是**不透明**色。1.0.33 两个参数都传了 #CC…（焦点/非焦点皆半透）
      //      ⇒ 被框架层参数校验拒掉，返回 401（401 **不在** @throws 列表里，
      //      列表只有 201/801/1300002/1300004，所以别照着列表排除可能性）。
      //    ★ 为此做**分级探测**：依次试 4 组取值，每组独立记录成功/失败码，
      //      **最后一次成功的组合生效**。一次构建就能读出「系统接受到哪一级 alpha」，
      //      不用来回试。结果写 AppStorage 由设置面板显示（失败必须可见）。
      //    ★ 放在主题确定**之后**：容器色按当前深浅取，否则深浅反。
      const probeDark: boolean = AppStorage.get<boolean>(SYSTEM_DARK_KEY) ?? true;
      const translucent: string = probeDark ? '#CC1F1F1F' : '#CCF3F3F5';
      const solid: string = probeDark ? '#FF1F1F1F' : '#FFF3F3F5';
      const systemDefault: string = probeDark ? '#FF1A1A1A' : '#FFF0F0F0';
      const probeColors: string[][] = [
        [systemDefault, systemDefault], // ① 基线：全实色——验证"颜色格式本身对不对"
        [translucent, translucent], // ② 1.0.33 的原取值（已实测 401）
        [translucent, solid], // ③ 期望：焦点半透 / 非焦点实色
        ['#00000000', solid], // ④ 极限：焦点全透 / 非焦点主题实色（★ 不能用纯黑：
        //   1.0.34 实测生效的是本组，失焦时容器底变纯黑 ⇒ 整窗发黑；
        //   Win11 失焦窗口是变"实色"而非变黑 ⇒ inactive 用主题实色）。
      ];
      const probeLabels: string[] = ['基线', '双半透', '焦半透', '焦全透'];
      let acrylicLedger: string = '';
      let acrylicApplied: number = -1;
      try {
        const mainWindow: window.Window = windowStage.getMainWindowSync();
        for (let probeIndex: number = 0; probeIndex < probeColors.length; probeIndex++) {
          try {
            mainWindow.setWindowContainerColor(probeColors[probeIndex][0], probeColors[probeIndex][1]);
            acrylicApplied = probeIndex;
            acrylicLedger += `${probeLabels[probeIndex]}=成功 `;
          } catch (probeError) {
            const probeFailure = probeError as BusinessError;
            acrylicLedger += `${probeLabels[probeIndex]}=${probeFailure.code} `;
          }
        }
      } catch (windowError) {
        const windowFailure = windowError as BusinessError;
        acrylicLedger += `取窗=${windowFailure.code} `;
      }
      AppStorage.setOrCreate(WINDOW_ACRYLIC_RESULT_KEY,
        `容器 ${acrylicLedger}｜生效=${acrylicApplied >= 0 ? probeLabels[acrylicApplied] : '无'}`);
      hilog.info(0x0000, TAG, 'setWindowContainerColor 探测：%{public}s', acrylicLedger);

      // 半透明窗口不该带阴影（阴影不透明，会在窗口边缘糊出一圈灰）。
      try {
        windowStage.getMainWindowSync()
          .setWindowShadowEnabled(false)
          .catch((shadowError: BusinessError): void => {
            AppStorage.setOrCreate(WINDOW_SHADOW_RESULT_KEY,
              `阴影关闭=失败 ${shadowError.code} ${shadowError.message}`);
            hilog.warn(0x0000, TAG, 'setWindowShadowEnabled failed: %{public}d %{public}s',
              shadowError.code, shadowError.message);
          });
      } catch (shadowError) {
        const shadowFailure = shadowError as BusinessError;
        AppStorage.setOrCreate(WINDOW_SHADOW_RESULT_KEY,
          `阴影关闭=失败 ${shadowFailure.code} ${shadowFailure.message}`);
      }

      // ★ 托盘初始化已在本块开头的「托盘接入」处按「状态栏图标优先、通知降级」
      //   一次性完成 —— 这里**不能**再调 TrayManager.shared().initialize()：
      //   状态栏托盘接入成功时它会再发一条常驻通知，出现"状态栏图标 + 通知"双入口。
    });
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    hilog.info(0x0000, TAG, '%{public}s', 'EntryAbility.onConfigurationUpdate');
    setSystemDark(newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
  }

  onWindowStageDestroy(): void {
    hilog.info(0x0000, TAG, '%{public}s', 'EntryAbility.onWindowStageDestroy');
    // ★ 刻意**不**在这里摘托盘图标：窗口阶段销毁 ≠ 进程死亡。托盘模式下
    //   hideAbility() 收起应用时，窗口阶段同样会走销毁流程，而状态栏图标
    //   必须继续活着（用户就靠它把界面唤回来）。摘图标的正确时机只有两处：
    //   onDestroy（Ability 真销毁）与托盘右键「退出」（quitApp 先摘再 terminateSelf）。
    // 系统关闭按钮无法拦截：用户点系统三键关闭时这里被触发。投屏中则尽力通过
    // startAbility 重新拉起（进程可能被杀、不可靠但尽力而为）；未投屏则正常退出。
    try {
      const status: CaptureStatus | null = getCaptureStatus();
      if (status !== null && status.state >= 1 && status.state <= 5) {
        hilog.warn(0x0000, TAG, '投屏中窗口被关闭，尝试重新拉起');
        try {
          this.context.startAbility({
            bundleName: this.context.abilityInfo.bundleName,
            abilityName: this.context.abilityInfo.name,
          });
        } catch (startError) {
          const startFailure = startError as BusinessError;
          hilog.warn(0x0000, TAG, '重新拉起失败：%{public}s', startFailure.message);
        }
      } else {
        hilog.info(0x0000, TAG, '未投屏，正常退出');
      }
    } catch (error) {
      const failure = error as BusinessError;
      hilog.warn(0x0000, TAG, '检查投屏状态失败：%{public}s', failure.message);
    }
  }

  onForeground(): void {
    hilog.info(0x0000, TAG, '%{public}s', 'EntryAbility.onForeground');
  }

  onBackground(): void {
    hilog.info(0x0000, TAG, '%{public}s', 'EntryAbility.onBackground');
  }
}
