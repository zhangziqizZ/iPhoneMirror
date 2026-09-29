// StandalonePreviewAbility.ets —— 独立预览窗口的**专属 UIAbility**
//
// ────────────────────────────────────────────────────────────────────────────
// 为什么独立窗口不能继续当「子窗口」（2026-09-21 改）
// ────────────────────────────────────────────────────────────────────────────
// 用户报的是「主窗口最小化后独立窗口也要能显示」。这一条**子窗口做不到**：
//
//   · 子窗口是 `mainWindow.createSubWindowWithOptions()` 建的，生命周期挂在**主
//     窗口**上：主窗口转入后台/最小化，子窗口跟着一起不再显示。
//   · 官方「子窗口开发指导」给出的解法是 API 26 的「独立子窗」—— 建窗时把
//     `SubWindowOptions.zLevelAboveParentLoosened` 置 true，于是子窗
//     **不跟随主窗前后台的切换，仅跟随主窗一起销毁**。
//     但本工程 `compileSdkVersion = 6.1.0(23)`（API 23），**没有这个字段**。
//
// 唯一剩下的正路 = **再开一个 UIAbility**：它的窗口在系统里是独立的一条
// （不同的 mission/窗口），主窗口最小化、甚至主窗口被销毁，都不影响它继续显示。
//
// ── 换成独立 Ability 之后，哪些前提不再保底 ────────────────────────────────
//   ① 模块级单例（`WindowServices.pending_standalone_preview` 那套）能共享，
//      是因为「同一个 ArkTS 运行时」；跨 Ability 文档里没给保证 ⇒ 一律改走
//      **want.parameters**（官方跨 Ability 传参）+ **AppStorage**（应用级状态）。
//   ② 原来主窗口用 `window.findWindow('StandalonePreviewWindow')` 判"还在不在"，
//      对独立 Ability 的窗口**不适用**（findWindow 找的是我们注册过的子窗名）⇒
//      改读独立窗口自己维护的 `STANDALONE_ALIVE_KEY`。
//   ③ 渲染器（libim_core.so 的预览单例）必须还是同一个 —— 所以本 Ability
//      **刻意不声明 `process`**：不声明就跑在默认进程（同 EntryAbility），
//      于是 `im_attach_preview_window()` 能把画面挂到本窗口的 XComponent。
//      一旦给它配了独立进程，渲染器就是另一份，画面根本过不来。
//
// ── 本 Ability 负责的三件窗口属性 ──────────────────────────────────────────
//   ① 去掉系统装饰 —— 注意是**两个**调用：`setWindowDecorVisible(false)` 只隐藏
//      标题栏，2in1 上系统三键区会保留并下沉到内容区（华为开发者文档专门有一篇
//      「自由多窗模式下，应用页面与标题栏三键区域重叠」讲这个）；所以还要
//      `setWindowTitleButtonVisible(false, false, false)` 把三键区也关掉。
//      两件事做完，屏幕上就只剩页面自绘的那一条栏（见 StandalonePreviewWindow.ets），
//      不会出现两套三键。★ 且**必须在 loadContent 成功之后调**，否则不生效。
//   ② `setContentAspectRatio()`：锁宽高比，实现用户要的「只能等比例放大缩小」。
//      ★ 它是**主窗专属 + 仅自由悬浮窗（FLOATING）生效**的接口 —— 这也正是独立
//        窗口必须从子窗升级为主窗的第二个理由（子窗调它无效）。
//        module.json5 里本 Ability 的 `supportWindowMode` 只给 ["floating"]，
//        就是为了让这个约束真的生效。
//      ★ 锁的是**内容区**比例，而内容区 = 顶部条带 + 画面，所以传进去的不是源
//        画面比例，而是换算后的 K（推导见 WindowServices.standalone_content_aspect）。
//   ③ 初始尺寸：主窗不能用 createSubWindow 的 windowRect，改用 resizeAsync
//      （同样只在 FLOATING 下生效）。

import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@ohos.base';
import { display } from '@kit.ArkUI';
import {
  STANDALONE_PAGE, STANDALONE_ALIVE_KEY, STANDALONE_WINDOW_KEY,
  STANDALONE_DEVICE_NAME_KEY, STANDALONE_ASPECT_KEY,
  STANDALONE_ASPECT_ERROR_KEY, STANDALONE_CHROME_NOTICE_KEY,
  STANDALONE_CORNER_ID_KEY, STANDALONE_CORNER_ROUNDED_KEY,
  STANDALONE_CORNER_RADIUS_KEY, STANDALONE_CORNER_CURVE_KEY,
  STANDALONE_CORNER_GDI_KEY,
  WANT_DEVICE_NAME, WANT_ASPECT_RATIO,
  WANT_CORNER_ID, WANT_CORNER_ROUNDED, WANT_CORNER_RADIUS,
  WANT_CORNER_CURVE, WANT_CORNER_GDI,
  read_want_string, read_want_number,
  standalone_content_aspect,
} from '../common/WindowServices';

const TAG: string = 'im_standalone_ability';
const DOMAIN: number = 0x0101;

/** 宽高比合法区间（与页面侧 fit_initial_size 的 MIN/MAX_ASPECT 同口径）。 */
const MIN_ASPECT: number = 0.05;
const MAX_ASPECT: number = 20;
/** AspectRatioWindowController 的兜底比例（201/437）。 */
const FALLBACK_ASPECT: number = 201 / 437;

/** AspectRatioWindowController.InitialWorkAreaFraction。 */
const INITIAL_WORK_AREA_FRACTION: number = 0.82;
/** 兜底初始尺寸（拿不到屏幕时用）—— 上游 NativePreviewWindow.cs:297-298 的 720×900。 */
const FALLBACK_WIDTH_DIPS: number = 720;
const FALLBACK_HEIGHT_DIPS: number = 900;

/** 首次隐藏系统装饰后，隔多久再下发一次（时序兜底，见 schedule_chrome_retry）。 */
const CHROME_RETRY_DELAY_MS: number = 600;

/** 1 vp 折算多少 px（与 SubWindow.vp_to_px_ratio 同口径）。 */
function density_ratio(): number {
  try {
    const density: number = display.getDefaultDisplaySync().densityPixels;
    if (density > 0) {
      return density;
    }
  } catch (error) {
    hilog.warn(DOMAIN, TAG, '取屏幕密度失败，按 1 处理: %{public}s',
      (error as BusinessError).message);
  }
  return 1;
}

export default class StandalonePreviewAbility extends UIAbility {
  /**
   * 把 want.parameters 转存进 AppStorage。
   *
   * 为什么多这一步：页面拿不到 Want（loadContent 只收路径字符串），而 AppStorage
   * 是应用级的，页面用 `AppStorage.get` 就能读到。跨 Ability 传参只支持基本类型，
   * 所以轮廓（DeviceCornerProfile）在主窗口侧拆成 5 个标量带过来，这里原样转存。
   */
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const params: Record<string, Object> =
      want.parameters !== undefined && want.parameters !== null ? want.parameters : {};
    try {
      AppStorage.setOrCreate<string>(STANDALONE_DEVICE_NAME_KEY,
        read_want_string(params, WANT_DEVICE_NAME, ''));
      AppStorage.setOrCreate<number>(STANDALONE_ASPECT_KEY,
        read_want_number(params, WANT_ASPECT_RATIO, 0));
      AppStorage.setOrCreate<string>(STANDALONE_CORNER_ID_KEY,
        read_want_string(params, WANT_CORNER_ID, 'rectangular'));
      AppStorage.setOrCreate<number>(STANDALONE_CORNER_ROUNDED_KEY,
        read_want_number(params, WANT_CORNER_ROUNDED, 0));
      AppStorage.setOrCreate<number>(STANDALONE_CORNER_RADIUS_KEY,
        read_want_number(params, WANT_CORNER_RADIUS, 0));
      AppStorage.setOrCreate<number>(STANDALONE_CORNER_CURVE_KEY,
        read_want_number(params, WANT_CORNER_CURVE, 2));
      AppStorage.setOrCreate<number>(STANDALONE_CORNER_GDI_KEY,
        read_want_number(params, WANT_CORNER_GDI, 0));
    } catch (error) {
      // 存不进去也要让窗口起来（画面能挂上就行），所以只记日志。
      hilog.warn(DOMAIN, TAG, '写入独立窗口入参失败: %{public}s',
        (error as BusinessError).message);
    }
    hilog.info(DOMAIN, TAG, '独立预览 Ability 已创建');
  }

  /**
   * 已经开着时主窗口再拉一次 = 请求把它前置。
   *
   * 对应上游 `MainWindow.xaml.cs` 里"同 UDID 再点不重开，而是 Activate()"。
   * 本 Ability 是 `launchType: singleton`，所以重复 startAbility 不会新开实例，
   * 而是走这里 —— 主窗口那边（Index.focus_standalone_window）正是靠这个行为
   * 把独立窗口叫到前面的。
   */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      const stored: window.Window | undefined = AppStorage.get<window.Window>(STANDALONE_WINDOW_KEY);
      if (stored !== undefined && stored !== null) {
        stored.showWindow().catch((error: BusinessError): void => {
          hilog.warn(DOMAIN, TAG, '前置独立预览窗口失败: %{public}s', error.message);
        });
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '处理前置请求失败: %{public}s',
        (error as BusinessError).message);
    }
    hilog.info(DOMAIN, TAG, 'onNewWant');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageCreate');
    windowStage.loadContent(STANDALONE_PAGE, (err: BusinessError): void => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, '加载独立预览页失败: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, '独立预览页已加载');
      // ★ 窗口整形**必须**放在 loadContent 成功之后（2026-09-21 改）。
      //   实测：在 loadContent 之前调 setWindowDecorVisible(false) 不生效 ——
      //   用户截图里系统标题栏「iPhoneMirror 独立预览」照旧画着，我们的自绘栏
      //   被压在它下面，屏幕上同时出现**两套三键**。
      //   EntryAbility 一直写在 loadContent 回调里，那边确实生效，这里对齐它。
      this.apply_window_shape(windowStage);
    });
  }

  /**
   * 去掉系统装饰（标题栏 + 三键区）+ 锁比例 + 定初始尺寸。
   *
   * 三步都"尽力而为"：任何一步失败都不许挡住窗口显示（本工程子窗口铁律第 3 条
   * 的同款要求 —— 窗口开着却不显示内容，是最难排查的故障形态）。
   * 但失败**必须能被看见**：结果一路写进 AppStorage，由主窗口的占位区显示。
   */
  private apply_window_shape(windowStage: window.WindowStage): void {
    let win: window.Window | null = null;
    try {
      win = windowStage.getMainWindowSync();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'getMainWindowSync 失败: %{public}s',
        (error as BusinessError).message);
      AppStorage.setOrCreate<string>(STANDALONE_CHROME_NOTICE_KEY,
        `取窗口失败：${(error as BusinessError).message}`);
      return;
    }
    if (win === null || win === undefined) {
      return;
    }

    // ⓪ 把窗口对象交给页面（页面要在最小化/设圆角时用，见 STANDALONE_WINDOW_KEY）。
    try {
      AppStorage.setOrCreate<window.Window>(STANDALONE_WINDOW_KEY, win);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '暂存窗口对象失败: %{public}s',
        (error as BusinessError).message);
    }

    // ① 系统装饰与系统三键区全部关掉（两件事，缺一不可 —— 见 apply_system_chrome）。
    this.apply_system_chrome(win);

    // ② 锁内容区宽高比。注意语义：ratio = 宽/高，且是**内容区**（不含装饰）。
    //    因为顶部要留一条自绘栏的条带，窗口比例不等于画面比例 —— 换算见
    //    WindowServices.standalone_content_aspect 的推导。
    const sourceAspect: number = this.read_aspect();
    const contentAspect: number = standalone_content_aspect(sourceAspect);
    try {
      win.setContentAspectRatio(contentAspect, true, false).then((): void => {
        hilog.info(DOMAIN, TAG, '已锁定窗口宽高比 %{public}s（源画面 %{public}s）',
          contentAspect.toFixed(4), sourceAspect.toFixed(4));
      }).catch((error: BusinessError): void => {
        // 最常见的失败原因是窗口不是 FLOATING 形态 —— 必须让用户看见，
        // 否则会表现为"能随便拉、比例锁不住"而不知为何。
        hilog.warn(DOMAIN, TAG, 'setContentAspectRatio 失败: %{public}s', error.message);
        AppStorage.setOrCreate<string>(STANDALONE_ASPECT_ERROR_KEY, error.message);
      });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'setContentAspectRatio 异常: %{public}s',
        (error as BusinessError).message);
    }

    // ③ 初始尺寸：主窗没有 windowRect 可用，只能建完再 resize（px）。
    //    resizeAsync 与 setContentAspectRatio 一样只在 FLOATING 下生效，失败无害
    //    （系统会给一个默认尺寸），所以只记日志。
    const size: number[] = this.fit_initial_size(contentAspect);
    const ratio: number = density_ratio();
    try {
      win.resizeAsync(Math.round(size[0] * ratio), Math.round(size[1] * ratio))
        .catch((error: BusinessError): void => {
          hilog.warn(DOMAIN, TAG, 'resizeAsync 失败: %{public}s', error.message);
        });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'resizeAsync 异常: %{public}s',
        (error as BusinessError).message);
    }

    // ④ 兜底重试一次：首次调用有可能正好打在"窗口尚未真正就绪"的缝里
    //    （首条命令被吞、系统随后又把装饰画回来）。600ms 后再下发一遍，仍然
    //    以回读结果为准，不影响窗口显示。
    this.schedule_chrome_retry(win);
  }

  /**
   * 关掉系统装饰 + 系统三键区，并把结果写进 AppStorage（主窗口显示）。
   *
   * ── 为什么是**两个**调用 ────────────────────────────────────────────────────
   * 官方在 2in1 上的语义是：`setWindowDecorVisible(false)` 只隐藏**标题栏**
   * （应用图标 + 名称），**右上角三键区会保留并下沉到内容区**——华为开发者文档
   * 「自由多窗模式下，应用页面与标题栏三键区域重叠」那条讲的就是这个，给出的
   * 办法是让页面 padding 避让。本工程不想让位给一套重复的三键，于是再补一刀
   * `setWindowTitleButtonVisible(false, false, false)`（@since 14）把三键区整个
   * 关掉，系统这边就一点装饰都不剩，屏幕上的三键只有我们自绘的那一条。
   *
   * ── 判据（本工程纪律：探针本身也可能是坏的）────────────────────────────────
   *   · 装饰：`getWindowDecorVisible()`（@since 18）回读真值。回读**抛异常**
   *     只说明"这台设备没有该探针"，记「回读不可用」，**不能**据此判失败。
   *   · 三键：SDK 没有对应的读取接口 ⇒ 只有"调用抛了明确错误码"才算证据；
   *     返回成功就按"已下发"记，不假装验证过。
   */
  private apply_system_chrome(win: window.Window): void {
    let problem: string = '';

    try {
      win.setWindowDecorVisible(false);
    } catch (error) {
      const failure: BusinessError = error as BusinessError;
      problem = `系统标题栏隐藏失败(${failure.code})`;
      hilog.warn(DOMAIN, TAG, 'setWindowDecorVisible 失败: %{public}s', failure.message);
    }
    // 回读真值（探针不可用不算失败证据）。★ 用追加而不是覆盖：调用本身抛错时
    //   已经把错误码记下来了，回读再补一句，两条信息都要留着。
    try {
      if (win.getWindowDecorVisible()) {
        const text: string = '系统标题栏仍可见';
        problem = problem.length > 0 ? `${problem}；${text}` : text;
      }
    } catch (error) {
      hilog.info(DOMAIN, TAG, 'getWindowDecorVisible 回读不可用（本机不支持该探针）');
    }

    try {
      win.setWindowTitleButtonVisible(false, false, false);
    } catch (error) {
      const failure: BusinessError = error as BusinessError;
      const text: string = `系统三键隐藏失败(${failure.code})`;
      problem = problem.length > 0 ? `${problem}；${text}` : text;
      hilog.warn(DOMAIN, TAG, 'setWindowTitleButtonVisible 失败: %{public}s', failure.message);
    }

    try {
      AppStorage.setOrCreate<string>(STANDALONE_CHROME_NOTICE_KEY, problem);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '写系统装饰结果失败');
    }
    hilog.info(DOMAIN, TAG, '系统装饰处理结果: %{public}s',
      problem.length > 0 ? problem : '已全部隐藏');
  }

  /** 600ms 后再下发一次系统装饰隐藏（时序兜底）。 */
  private schedule_chrome_retry(win: window.Window): void {
    try {
      setTimeout((): void => {
        // 定时器回调里一行都不能裸奔：抛出去就是应用被结束。
        try {
          this.apply_system_chrome(win);
        } catch (error) {
          hilog.warn(DOMAIN, TAG, '重试隐藏系统装饰失败: %{public}s',
            (error as BusinessError).message);
        }
      }, CHROME_RETRY_DELAY_MS);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '无法安排重试: %{public}s',
        (error as BusinessError).message);
    }
  }

  /** 读主窗口传来的**源画面**宽高比；没传或不合法就用 201/437 兜底。 */
  private read_aspect(): number {
    let raw: number = 0;
    try {
      const stored: number | undefined = AppStorage.get<number>(STANDALONE_ASPECT_KEY);
      if (stored !== undefined && stored !== null) {
        raw = stored;
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '读取宽高比失败，走兜底');
    }
    if (raw >= MIN_ASPECT && raw <= MAX_ASPECT) {
      return raw;
    }
    return FALLBACK_ASPECT;
  }

  /**
   * 按内容区宽高比与工作区 82% 算首次尺寸（vp）—— 与页面侧原 fit_initial_size 同算式。
   *
   * 入参是**内容区**比例 K（= 条带 + 画面），不是源画面比例 —— 见调用点。
   */
  private fit_initial_size(aspect: number): number[] {
    const ratio: number = density_ratio();
    let areaWidth: number = FALLBACK_WIDTH_DIPS / INITIAL_WORK_AREA_FRACTION;
    let areaHeight: number = FALLBACK_HEIGHT_DIPS / INITIAL_WORK_AREA_FRACTION;
    try {
      const screen: display.Display = display.getDefaultDisplaySync();
      if (screen.width > 0 && screen.height > 0 && ratio > 0) {
        areaWidth = screen.width / ratio;
        areaHeight = screen.height / ratio;
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '取屏幕尺寸失败，按 720×900 起');
    }
    let width: number = areaWidth * INITIAL_WORK_AREA_FRACTION;
    let height: number = width / aspect;
    const maxHeight: number = areaHeight * INITIAL_WORK_AREA_FRACTION;
    if (height > maxHeight) {
      height = maxHeight;
      width = height * aspect;
    }
    return [Math.round(width), Math.round(height)];
  }

  onWindowStageDestroy(): void {
    // Ability 销毁 = 窗口真的没了。主窗口靠这个键判断"要不要把画面接回去"，
    // 所以**两个销毁入口都要写**（页面 aboutToDisappear 是另一处）。
    try {
      AppStorage.setOrCreate<boolean>(STANDALONE_ALIVE_KEY, false);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '写存活标志失败');
    }
    hilog.info(DOMAIN, TAG, 'onWindowStageDestroy');
  }

  onDestroy(): void {
    try {
      AppStorage.setOrCreate<boolean>(STANDALONE_ALIVE_KEY, false);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '写存活标志失败');
    }
    hilog.info(DOMAIN, TAG, 'onDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'onBackground');
  }
}
