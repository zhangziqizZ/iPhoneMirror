import { AbilityConstant, UIAbility, Want, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { setSystemDark, SYSTEM_DARK_KEY } from '../common/theme_manager';
import { WINDOW_SHADOW_RESULT_KEY, APP_WINDOW_VISIBLE_KEY,
  MINIMIZE_TO_TRAY_KEY } from '../common/WindowServices';
import { open_app_preferences, load_language_preference,
  load_hide_pointer_preference, load_glow_preferences, load_tray_preferences,
  load_first_run_done, FIRST_RUN_DONE_KEY,
  load_independent_window_style, INDEPENDENT_OPACITY_KEY,
  load_keyboard_mapping, load_theme_preference,
  load_developer_mode_preference } from '../common/AppPreferences';
import { vp_to_px_ratio } from '../common/SubWindow';
import { BusinessError } from '@ohos.base';
import { open_instance_conflict, InstanceConflictRequest } from '../pages/windows/InstanceConflictWindow';
import { open_first_run } from '../pages/windows/FirstRunSetupWindow';
import { TrayManager } from '../common/TrayManager';
import { StatusBarTray } from '../common/StatusBarTray';
import { setLogFile, setPairingStoreDirectory } from 'libim_core.so';
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
    // ★ 偏好必须**跨启动保留**：AppStorage 是进程内内存态，进程一退就没了 ⇒
    //   用户选完重启又回默认值（= 没保存）。
    //   ★ 顺序要求：必须在**任何地方访问这些键之前**（尤其 UI 组件里的 @StorageLink）
    //     先把磁盘值读回 AppStorage —— UI 的 @StorageLink 首次读取会**建立**这个键
    //     （用的是它的默认值），一旦它先建了，后面读回来的存档值就盖不住了。
    //   ★ 2026-10-31：开发者模式（DEVELOPER_MODE_KEY）改为持久化 —— 用户原话：
    //     "开发者模式应该开启后就保持开启，重开应用需要再开一遍，太麻烦了"。
    //     它仍是调试入口，只是开着的人不必每次重开（见 AppPreferences 的
    //     load/save_developer_mode_preference）。
    //   ★ 为什么之前用的 PersistentStorage 实测不行：它自己决定何时刷盘，用户直接关掉
    //     /杀进程时来不及 ⇒ 现在换成显式 putSync + flushSync（见 AppPreferences.ets）。
    open_app_preferences(this.context);
    // ★ 把 UIAbilityContext 存进 AppStorage，供各子窗口取用（开子窗需要它）。
    AppStorage.setOrCreate('im.appContext', this.context);
    // ★ 界面语言：把磁盘存档读回 AppStorage —— 同理，必须在任何 UI 装载
    //   **之前**，否则 t() 首次读取会先建键，这里再写就变成普通更新、用户看到的还是默认值。
    load_language_preference();
    // 反控接管时的指针偏好（默认保持可见，见 HIDE_POINTER_ON_TAKEOVER_KEY 的注释）。
    load_hide_pointer_preference();
    load_glow_preferences();
    load_tray_preferences();
    // ★ 开发者模式：同样必须在 UI 装载前读回（否则 AboutWindow 的 @StorageLink
    //   先用默认值 false 建键，存档就盖不住了）。
    load_developer_mode_preference();
    // ★ 首启向导标记：必须在 UI 装载之前读回 AppStorage，否则首帧会用默认值
    //   （false）建立键，这里再写也只是普通更新、首次启动不会弹出向导。
    load_first_run_done();
    // ★ 独立窗口风格偏好（透明度/悬停不透明）：同样必须在 UI 装载前读回 AppStorage，
    //   独立预览 Ability 跨 Ability 共享这份 AppStorage，这里建好键它就能读到。
    load_independent_window_style();
    // ★ 键盘映射设置：同样必须在 UI 装载前读回 AppStorage（含损坏隔离）。
    load_keyboard_mapping();
    // ★ 主题偏好（0=跟随系统 1=深色 2=浅色）：必须在 UI 装载前读回，
    //   主窗的 themeIndex 是 @StorageLink，先建键就会用默认值覆盖存档。
    load_theme_preference();
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
      const logPath: string = this.context.filesDir + '/PhoneMirror/Logs/startup.log';
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
    // ★ 配对记录存储目录：原生侧要把它写进应用沙箱才能实现
    //   「插一次、长期免弹窗」——设备认的是 (HostID + 根 CA 公钥)，
    //   这两个必须跨启动存活，否则每次插线都会被当成新电脑重新弹窗。
    //   路径必须在**任何配对动作之前**交给原生，所以放在启动期（onCreate）。
    //   失败不致命：只是退化成"每次插线都弹窗"，配对本身仍能走通。
    try {
      const pairingDir: string = this.context.filesDir + '/PhoneMirror/Pairing';
      const ok: boolean = setPairingStoreDirectory(pairingDir);
      if (!ok) {
        hilog.warn(0x0000, TAG, '配对记录目录设置失败：%{public}s', pairingDir);
      } else {
        hilog.info(0x0000, TAG, '配对记录目录已设为 %{public}s', pairingDir);
      }
    } catch (error) {
      const failure = error as BusinessError;
      hilog.warn(0x0000, TAG, 'setPairingStoreDirectory 失败（非致命）：%{public}s', failure.message);
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
   * 应用级退出的兜底 —— 现在只记录、**一律放行**（返回 false）。
   *
   * ★★ 2026-10-23 撤回「拦截退出收进托盘」（用户实测：应用关不掉）：
   *   原实现把**所有**系统级终止（Dock 右键关闭、系统托盘菜单自带的「退出」、
   *   关机）统统拦截成 hideToTray —— 这些入口没有一个能穿过它，于是应用除了
   *   任务管理器强杀没有任何退出途径；而且 hideAbility() 会重走窗口阶段，
   *   用户点托盘图标唤回时页面重新加载，看起来就像"退出变成了重启"。
   *   无法区分"用户想真退出"与"想收托盘"（该回调没有来源参数），两害相权：
   *   **能退出是底线**，"Dock 关闭也收托盘"是锦上添花，舍掉。
   *
   * 「收进托盘」现在只由一条路径触发：窗口右上角 × 的 windowWillClose 拦截
   * （见 onWindowStageCreate，受「最小化到托盘」开关控制）——它有明确、独立、
   * 可预期的入口语义，不与任何系统级退出冲突。
   *
   * ★ 返回值语义（官方 API 参考）：true = 取消终止；false = 继续终止。
   * ★ 需要 ohos.permission.PREPARE_APP_TERMINATE —— 已声明于 module.json5。
   *   既然不再拦，这个回调可以整个删掉；保留一个纯放行的实现是留个日志锚点，
   *   排查"应用为什么退出了/没退出"时能看到是哪条路径触发的终止。
   */
  onPrepareToTerminate(): boolean {
    hilog.info(0x0000, TAG, '%{public}s', 'onPrepareToTerminate：系统级退出，放行');
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
            // ★ INACTIVE(3) 是"**失去焦点但仍然可见**"（用户点了别的窗口），
            //   不能当成不可见：一旦判成不可见，Index 的 500ms 心跳就停了，
            //   连带停掉的是采集状态刷新、设备枚举、接管态重算，以及
            //   apply_pointer_visibility() 的指针自愈 —— 反控期间本地指针被
            //   setPointerVisibleSync(false) 藏起来，自愈停了就**再也看不见鼠标**。
            //   真正代表"看不见"的只有 HIDDEN(4) 与 PAUSED(6)。
            const visible: boolean = event === window.WindowStageEventType.SHOWN
              || event === window.WindowStageEventType.ACTIVE
              || event === window.WindowStageEventType.INACTIVE
              || event === window.WindowStageEventType.RESUMED;
            AppStorage.setOrCreate(APP_WINDOW_VISIBLE_KEY, visible);
            hilog.info(0x0000, TAG, '窗口可见性：%{public}s（event=%{public}d）',
              visible ? '可见' : '不可见', event);
          });
        } catch (stageEventError) {
          const seFailure = stageEventError as BusinessError;
          hilog.warn(0x0000, TAG, '订阅 windowStageEvent 失败：%{public}s', seFailure.message);
        }

        // ★ 半透明 / 磨砂已整体移除（2026-10-23，用户要求）：
        //   ① 不再调 setWindowBackgroundColor('#00000000') 把主窗背景设成全透明
        //      —— 退化路径下会让窗口内容区直接露出桌面背景；
        //   ② 不再调 setWindowContainerColor(...) 做焦点/非焦点配色探测
        //      —— 该调用 401 与"设备不支持"同形，读数长期没有分辨力；
        //   ③ 不再向 Index 广播窗口尺寸脉冲（原先只为"动画期临时关磨砂"服务）。
        //   主窗背景改由 Index 根容器的不透明 BACKGROUND 兜底。

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

      // 关闭窗口阴影：阴影不透明，会在窗口边缘糊出一圈灰。
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

      // ★ 首启向导：首次启动（first_run_done 未置位）自动弹出，引导用户完成
      //   连接方式选择 / 连接指引 / 权限提示。窗口任意方式关闭都会经关窗钩子
      //   写标记（见 FirstRunSetupWindow.ets），之后不再自动弹。
      //   放在 loadContent 成功之后：主窗口 stage 已就绪，SubWindowHost.open
      //   才能拿到 getLastWindow 作 owner 居中。整段 try 包住，避免把启动带崩。
      try {
        const firstRunDone: boolean = AppStorage.get<boolean>(FIRST_RUN_DONE_KEY) ?? false;
        if (!firstRunDone) {
          open_first_run(this.context);
        }
      } catch (firstRunError) {
        const frFailure = firstRunError as BusinessError;
        hilog.warn(0x0000, TAG, '首启向导弹出失败（非致命）：%{public}s', frFailure.message);
      }
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
    // ★ 刻意**不**在这里 startAbility 重新拉起：hideAbility() 收托盘同样会走到本
    //  回调，若按「投屏中」去 startAbility，刚收进托盘的应用会被立刻弹回前台，
    //  违背「收进托盘」的意图。系统关闭按钮已由 windowWillClose 拦截（resolve(true)
    //  收起 / 关闭开关时 resolve(false) 真退出），这里无需再兜底。
  }

  onForeground(): void {
    hilog.info(0x0000, TAG, '%{public}s', 'EntryAbility.onForeground');
  }

  onBackground(): void {
    hilog.info(0x0000, TAG, '%{public}s', 'EntryAbility.onBackground');
  }
}
