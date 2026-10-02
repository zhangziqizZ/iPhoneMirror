// StandalonePreviewWindow.ets —— 独立预览窗口
//
// 逐项对照上游 src/App/Windows/NativePreviewWindow.cs（1349 行）
//        + src/App/Services/MultiDevicePreviewManager.cs:123-200（ShowCoreAsync）
//        + src/App/MainWindow.xaml.cs:5014-5045（OpenPreviewWindowAsync 设备分支）
//                                  :5973-5996（SynchronizeMainPreviewHost）
//                                  :884-889（OnIndependentPreviewClosed）
//
// ────────────────────────────────────────────────────────────────────────────
// ★★ 2026-09-21 结构性改动：它不再是「子窗口」，而是**独立 UIAbility 的主窗口**
// ────────────────────────────────────────────────────────────────────────────
// 起因是用户三条要求：① 主窗口最小化后独立窗口还要能显示；② 要一条带三键
// （最小化/放大/关闭）的栏，而且栏可以隐藏；③ 独立窗口只能等比例放大缩小。
//
// 这三条里，① 和 ③ 用子窗口**都做不到**：
//   · ① 子窗由 `mainWindow.createSubWindowWithOptions()` 建，生命周期挂在主窗口上
//     —— 主窗口转入后台/最小化，子窗跟着不显示。官方给的「独立子窗」解法是
//     API 26 的 `SubWindowOptions.zLevelAboveParentLoosened`（"不跟随主窗前后台的
//     切换，仅跟随主窗一起销毁"），而本工程 compileSdkVersion = 6.1.0(23)。
//   · ③ 「只能等比例缩放」的平台级做法是 `setContentAspectRatio()`，而它的生效
//     条件是**主窗口 + 自由悬浮窗（FLOATING）**—— 子窗口调它无效。
//
// 于是改成 `StandalonePreviewAbility`（见 entryability/ 下那个文件）：它是系统里
// 独立的一条窗口，主窗口最小化不影响它；它的窗口是主窗，比例锁得住。
// 代价：跨 Ability 之后「模块级单例共享」不再有保证 ⇒ 入参改走 want.parameters +
// AppStorage，关闭信号改走 AppStorage（见 WindowServices 里的那组常量）。
//
// ── 它为什么不是「WPF 窗口」──────────────────────────────────────────────────
// 上游注释（NativePreviewWindow.cs:15-19）：
//   "Native top-level DirectComposition preview. WS_EX_NOREDIRECTIONBITMAP keeps
//    DWM from allocating a second WPF redirection surface, allowing the native
//    renderer to attach its visual tree directly to this HWND."
// 也就是说它压根不是 WPF Window，而是**裸 Win32 顶层 HWND**（HwndSource），
// 把原生 D3D11 渲染器的可视化树直接挂上去。
//
// ── 窗口属性（NativePreviewWindow.cs:294-348）────────────────────────────────
//   标题    : $"iPhoneMirror — {device.DisplayName}"
//   尺寸    : Width=720 Height=900（:297-298）→ 随后交给 AspectRatioWindowController
//             按工作区 82% 贴合
//   窗口样式: WsPopup | WsThickFrame | WsSysMenu | WsMinimizeBox | ...（:301-303）
//   圆角    : DwmDoNotRound + DwmBorderColor=NONE（:330-336）
//
// ── 尺寸跟随（AspectRatioWindowController）──────────────────────────────────
//   minWidthDips=320 / minHeightDips=240；宽高比取自源帧，未知时回退 201/437。
//
// ── 打开它时上游做过的三件事（MainWindow.xaml.cs:5014-5041）─────────────────
//   ① 没有选中设备就直接返回；
//   ② **如果蓝牙反控开着，先关掉它**（:5028-5029 DisableBluetoothControlAsync）；
//   ③ 开窗成功后 `QueueMainPreviewHostSync()` —— 主窗口的预览让位。
//
// ── 关闭时（MainWindow.xaml.cs:884-889）─────────────────────────────────────
//   `OnIndependentPreviewClosed` → `QueueMainPreviewHostSync()` 把画面接回主窗口。
//   另有一条容易漏的语义（MultiDevicePreviewManager.cs:198）：
//     `if (_disposing || !started.Created) return;` —— **会话不是这个窗口建的，
//     关窗就不许停它**。本移植里会话永远是主窗口建的（单会话），所以关独立窗口
//     只把画面接回主窗口，**绝不 stopCapture()**。
//
// ──┬────────────────────────────────────────────────────────────────────────
//   │ 2026-09-21：顶部控制栏（对齐 macOS「iPhone 镜像」）
// ──┴────────────────────────────────────────────────────────────────────────
// 上游是**无边框**窗口（WS_POPUP，没有 WS_CAPTION），靠右键菜单 + 双击进全屏；
// 鸿蒙这边系统装饰已被 Ability 关掉，用户总得有办法搬动/最小化/关闭它，所以自绘
// 一条栏。第一版把它做成**浮层**（压在画面上），实测两个问题（用户 2026-09-21
// 截图反馈）：① 它把手机画面顶部压住了；② 系统标题栏还在，屏幕上同时有两套控件。
//
// 现在这条栏是**预留条带**，不再压画面：
//
//   · 布局 = Column{ 条带 ; 画面 }，条带**永远占位**，只有里面的按钮会淡入淡出。
//     这样 hover 显隐不会引起 XComponent 尺寸变化（否则每次鼠标划过都要重建
//     surface，画面会闪）。
//   · 条带高度 = 窗口宽度 × STANDALONE_STRIP_FRACTION —— **必须按宽度取比例**，
//     否则「窗口内容区比例是常数」与「画面比例不被破坏」两条无法同时成立，
//     推导见 WindowServices.standalone_content_aspect 的注释。
//     副产品：整窗（含条带）一起等比缩放，正好就是用户要的「只能等比例放大缩小」。
//   · 三键 = 关闭（Dismiss20）/ 最小化（Subtract20），**不做放大** —— 用户明确
//     要求去掉（2in1 上放大/还原对这个画面窗口没意义）；顺序对齐 macOS 左上角
//     三键（macOS 是 关闭/最小化/放大 三个，这里只剩前两个）。图标是单色 Fluent
//     符号，顺序是唯一能表达"哪个是哪个"的手段。
//   · 鼠标移到窗口顶部热区时浮出，移开后延时自动隐藏；「常驻」可钉住。
//
// ★ 与项目既有铁律的关系：「窗口三键由系统绘制，绝不自绘」那条针对的是**主窗口
//   沉浸式标题栏**。这里不同：Ability 已经把系统装饰与系统三键区**都**关掉了
//   （见 StandalonePreviewAbility.apply_system_chrome），系统根本不画三键 ——
//   不自绘就没有三键。所以自绘是**必须**，且只在这个窗口里发生。
//
// ── 与原版的差异（不假装一致）───────────────────────────────────────────────
//   ① **右键菜单**（置顶/固定/旋转/静音/投屏设置…）未实现 —— 它们各自需要
//      独立的窗口 API，本轮不承诺。
//      ★ 例外：「圆角」做了 —— README 明确点名，且鸿蒙侧只差接线。入口在浮层栏上
//        （本工程此前刻意没引入 bindContextMenu，见 DeviceBindingWindow.ets）。
//        语义照搬上游：关掉 = 归一化半径传 0。
//   ② **本窗口不承接反控输入**：上游会先关掉蓝牙反控再开这个窗口，之后可在右键
//      菜单里单独重开（按窗口路由）。本移植没有按窗口路由，所以如实不给入口。

import common from '@ohos.app.ability.common';
import window from '@ohos.window';
import { BusinessError } from '@ohos.base';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Want } from '@kit.AbilityKit';
import { SUBWINDOW_ERROR_KEY, vp_to_px_ratio } from '../../common/SubWindow';
import {
  APP_BACKGROUND, TEXT, MUTED_TEXT, CONTROL_FILL, BORDER_SOFT,
  ACCENT, SELECTION, WARNING,
} from '../../common/Theme';
import { FluentSymbol } from '../../common/FluentIcon';
import { attachPreview, lastError, setPreviewCornerProfile } from 'libim_core.so';
import {
  WindowServices,
  STANDALONE_ABILITY,
  STANDALONE_ALIVE_KEY, STANDALONE_CLOSE_REQUEST_KEY,
  STANDALONE_WINDOW_KEY, STANDALONE_ASPECT_ERROR_KEY,
  STANDALONE_DEVICE_NAME_KEY, STANDALONE_NOTICE_KEY,
  REVERSE_CONTROL_DISABLED_KEY,
  WANT_DEVICE_NAME, WANT_ASPECT_RATIO,
  corner_to_want, corner_from_storage,
  standalone_strip_height,
} from '../../common/WindowServices';
import { CORNER_RECTANGULAR, DeviceCornerProfile } from '../../common/DeviceCornerProfile';
import { ReverseControlInput } from '../../common/ReverseControlInput';
import { BluetoothHidPeripheral } from '../../common/BluetoothHidPeripheral';
import { t } from '../../common/i18n';

const TAG: string = 'im_standalone_preview';
const DOMAIN: number = 0x0100;

/** 页面注册的窗口名（历史遗留：子窗口时代的 findWindow 键，Index 侧还在引用）。 */
export const WINDOW_NAME: string = 'StandalonePreviewWindow';
export const PAGE_PATH: string = 'pages/windows/StandalonePreviewWindow';

/** NativePreviewWindow.cs:294 —— 标题为空时的稳定标题。 */
const STABLE_TITLE: string = 'iPhoneMirror OBS Preview';

/** AspectRatioWindowController.ValidAspect 的判定区间 + 兜底比例（201/437）。 */
const MIN_ASPECT: number = 0.05;
const MAX_ASPECT: number = 20;
const FALLBACK_ASPECT: number = 201 / 437;

/**
 * 条带初始高度（vp）。真正的高度由 on_window_area_change 按窗口宽度算出来，
 * 这个值只在"还没拿到窗口尺寸"的第一帧用一下（见 WindowServices 的比例换算）。
 */
const STRIP_HEIGHT_FALLBACK: number = 40;

/**
 * 鼠标进入窗口顶部多少 vp 以内就浮出栏。
 *
 * 比条带高度给宽一些，是因为鼠标从窗口外移进来时往往不是正好落在条带上 ——
 * 给一条"预判带"，浮出才跟手（macOS 的热区也是这么给的）。
 */
const STRIP_HIT_HEIGHT: number = 64;

/** 鼠标离开热区后，栏保持多久再隐藏（ms）。 */
const STRIP_HIDE_DELAY_MS: number = 1200;

/** 浮层栏淡入淡出时长（ms）。 */
const STRIP_FADE_MS: number = 160;

/** 反控状态轮询周期（与主窗口 poll_status 的 500ms 对齐，便于对照两侧读数）。 */
const REVERSE_POLL_INTERVAL_MS: number = 500;

/** 按钮尺寸区间：条带高度随窗口宽度变，按钮跟着夹在区间内（小窗口也放得下）。 */
const BUTTON_SIZE_MAX: number = 32;
const BUTTON_SIZE_MIN: number = 22;
const BUTTON_ICON_MAX: number = 16;
const BUTTON_ICON_MIN: number = 13;

const CORNER_ON_LABEL: string = '圆角';
const CORNER_OFF_LABEL: string = '直角';
/** 「常驻」开关的两个状态文案：常驻 = 栏不再自动隐藏。 */
const PIN_ON_LABEL: string = '常驻';
const PIN_OFF_LABEL: string = '自动';

// ── 栏上的短徽标（完整原因进 STANDALONE_NOTICE_KEY，见 flag_notice）──
const NOTICE_ASPECT: string = '比例锁未生效';
const NOTICE_PREVIEW_CORNER: string = '画面轮廓未生效';
const NOTICE_WINDOW_CORNER: string = '窗口圆角未生效';
const NOTICE_MINIMIZE: string = '最小化失败';
const NOTICE_REVERSE: string = '反控未就绪';

/**
 * 原版 `_secondaryMirrors.ShowAsync(device)`（MultiDevicePreviewManager.cs:123）。
 *
 * ★ 与旧版的差别：不再走 SubWindowHost.open（子窗），改成 `startAbility` 拉起
 *   StandalonePreviewAbility。原因见文件头 —— 主窗口最小化后子窗会跟着消失，
 *   而本工程是 API 23，没有「独立子窗」那个字段。
 *
 * @param ctx           主窗口的 UIAbilityContext（startAbility 需要它）
 * @param deviceName    设备显示名，用于标题
 * @param sourceWidth   源帧宽（0 表示未知 → 回退 201/437）
 * @param sourceHeight  源帧高
 * @param profile       该设备的显示轮廓拟合（机型外形适配）。会被拆成 5 个标量
 *                      塞进 want.parameters —— 跨 Ability 只能带基本类型。
 */
export function open_standalone_preview(ctx: common.Context,
                                        deviceName: string,
                                        sourceWidth: number,
                                        sourceHeight: number,
                                        profile: DeviceCornerProfile): void {
  const aspect: number = resolve_aspect(sourceWidth, sourceHeight);

  // ★ 与旧版同一个顺序：先置位再开窗。主窗口的预览区要在窗口出现之前就让位，
  //   否则会看到一瞬间「画面还在主窗口」。
  WindowServices.standalone_preview_open = true;
  // 独立窗口的"活着"标志由它自己置 true；开窗前先清零，免得上一轮残留的 true
  // 让主窗口误判"它还在"。
  AppStorage.setOrCreate<boolean>(STANDALONE_ALIVE_KEY, false);
  AppStorage.setOrCreate<string>(STANDALONE_ASPECT_ERROR_KEY, '');

  const params: Record<string, Object> = corner_to_want(profile);
  params[WANT_DEVICE_NAME] = deviceName;
  params[WANT_ASPECT_RATIO] = aspect;

  let bundleName: string = '';
  try {
    const abilityCtx: common.UIAbilityContext = ctx as common.UIAbilityContext;
    bundleName = abilityCtx.abilityInfo.bundleName;
  } catch (error) {
    hilog.warn(DOMAIN, TAG, '读 bundleName 失败: %{public}s',
      (error as BusinessError).message);
  }
  const want: Want = {
    bundleName: bundleName,
    abilityName: STANDALONE_ABILITY,
    parameters: params,
  };

  try {
    const abilityCtx: common.UIAbilityContext = ctx as common.UIAbilityContext;
    abilityCtx.startAbility(want).then((): void => {
      hilog.info(DOMAIN, TAG, '已拉起独立预览 Ability，设备=%{public}s', deviceName);
    }).catch((error: BusinessError): void => {
      // ★ 失败必须能被看见：走 SUBWINDOW_ERROR_KEY —— 主窗口的预览空态本来就
      //   轮询显示这个键（见 Index.poll_status），开窗失败的原因因此一定会出现在
      //   界面上，而不是只留在 hilog 里（hilog 在应用进程外读不到）。
      const text: string = `打开独立预览窗口失败：${error.message}`;
      AppStorage.setOrCreate<string>(SUBWINDOW_ERROR_KEY, text);
      WindowServices.standalone_preview_open = false;
      hilog.error(DOMAIN, TAG, '%{public}s', text);
    });
  } catch (error) {
    const failure = error as BusinessError;
    const text: string = `打开独立预览窗口失败：${failure.message}`;
    AppStorage.setOrCreate<string>(SUBWINDOW_ERROR_KEY, text);
    WindowServices.standalone_preview_open = false;
    hilog.error(DOMAIN, TAG, 'startAbility 异常: %{public}s', failure.message);
  }
}

/** 宽高比：源帧比例合法就用它，否则 201/437（与上游 ValidAspect + 兜底同口径）。 */
function resolve_aspect(sourceWidth: number, sourceHeight: number): number {
  if (sourceWidth > 0 && sourceHeight > 0) {
    const ratio: number = sourceWidth / sourceHeight;
    if (ratio >= MIN_ASPECT && ratio <= MAX_ASPECT) {
      return ratio;
    }
  }
  return FALLBACK_ASPECT;
}

@Entry
@Component
struct StandalonePreviewWindow {
  /** 画面未挂上时的说明（挂上后置空）。 */
  @State hint: string = '';
  @State surfaceAttached: boolean = false;
  /** 浮层栏上的设备名。 */
  @State deviceName: string = '';

  /**
   * 浮层栏是否可见。
   *
   * 初值 true：窗口刚出来时用户还不知道"鼠标移上去会有栏"，先露一下；
   * 之后由鼠标位置驱动（见 on_pointer_move / schedule_hide）。
   */
  @State stripVisible: boolean = true;

  /** 栏被钉住后不再自动隐藏（用户在栏上点「常驻」）。 */
  @State stripPinned: boolean = false;

  /**
   * 主窗口请求关闭（出参总线：主窗口写 AppStorage，这里响应式收到）。
   *
   * 为什么不用模块单例直接回调：跨 Ability 的模块单例共享没有文档保证，
   * 而 AppStorage 是官方定义的**应用级**状态存储，一定通。
   */
  @StorageLink(STANDALONE_CLOSE_REQUEST_KEY) @Watch('on_close_request')
  closeRequested: boolean = false;

  private xcController: XComponentController = new XComponentController();
  private attachedSurfaceId: string = '';
  /** 收尾只允许做一次（对应上游 Closed 事件只触发一次）。 */
  private resolved: boolean = false;
  /** 自动隐藏的延时器句柄（aboutToDisappear 里必须清掉）。 */
  private hideTimer: number = -1;

  /**
   * 反控状态轮询句柄（aboutToDisappear 里必须清掉）。
   *
   * ★ 独立窗口为什么需要自己的轮询：反控的接管判据依赖「此刻有没有画面」
   *   （`setPictureAvailable`）与「通道还在不在」，这两件事随时会变，而原先
   *   只有主窗口在每轮上报 —— 主窗口一旦不在前台/被最小化，这边的接管态就
   *   停在一个过期值上。顺带它还负责刷新栏上那行反控读数（见 reverseDiag）。
   */
  private diagTimer: number = -1;

  /**
   * 栏上那一行反控读数（`反控 接管 移12 原12 Δ3,-2 送3,-2`）。
   *
   * ★ 为什么非要有它：独立窗口是用户实际在用的窗口，而它没有主窗口那条状态行。
   *   「指针藏了却操控不了」必须能**就地看着数字**分出是哪一段坏了 ——
   *   是没接管、接管了但一个事件都没收到、还是我们全发正常而手机不响应。
   *   没有这个读数，用户只能描述"没反应"，我们只能猜。
   */
  @State reverseDiag: string = '';

  /** 轮廓是否套用机型圆角 —— 上游 `NativePreviewWindow._cornersEnabled`。 */
  @State cornersEnabled: boolean = true;

  /**
   * 栏上的**短徽标**（平时为空 = 显示设备名）。
   *
   * ★ 只放 4~6 个字：完整原因写进 AppStorage 的 STANDALONE_NOTICE_KEY，由主窗口
   *   的占位区显示。上一版把整句「窗口圆角未生效：Unauthorized operation. …」
   *   塞在这条栏里，一句话就把栏占满、把画面顶部压掉了（用户 2026-09-21 反馈）。
   */
  @State stripNotice: string = '';

  /**
   * 条带高度（vp）= 窗口宽度 × STANDALONE_STRIP_FRACTION。
   *
   * 由 on_window_area_change 每次窗口尺寸变化时重算 —— 见文件头与
   * WindowServices.standalone_content_aspect 的推导：只有它按宽度取比例，
   * 「窗口比例锁死」和「画面不变形、不被压」才能同时成立。
   */
  @State stripHeight: number = STRIP_HEIGHT_FALLBACK;

  /** 本设备的轮廓拟合（由 AppStorage 的 5 个标量还原）。 */
  private profile: DeviceCornerProfile = CORNER_RECTANGULAR;

  /** 上一次真正设到窗口上的圆角（vp），-1 = 还没设过。 */
  private lastWindowRadius: number = -1;

  /** 窗口内容区的短边（vp）—— 窗口轮廓圆角的换算基准。 */
  private lastShortEdgeVp: number = 0;

  /** 反控通道是否正在本窗口侧启动（防重复触发，见 ensure_reverse_channel）。 */
  private channelStarting: boolean = false;

  aboutToAppear(): void {
    // 入参来自 AppStorage（Ability 把 want.parameters 转存进来的）。
    // 原因：跨 Ability 时模块单例是否共享没有保证，而 AppStorage 是应用级的。
    try {
      const name: string | undefined = AppStorage.get<string>(STANDALONE_DEVICE_NAME_KEY);
      if (name !== undefined && name !== null) {
        this.deviceName = name;
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '读设备名失败: %{public}s', (error as BusinessError).message);
    }
    this.profile = corner_from_storage();

    // ★ 告诉主窗口"我活着" —— 主窗口靠这个键判断要不要把画面接回去。
    //   （取代了子窗口时代主窗口侧 window.findWindow 的判定方式。）
    AppStorage.setOrCreate<boolean>(STANDALONE_ALIVE_KEY, true);
    // 清掉上一轮可能残留的关闭请求，否则新窗口一开就被关掉。
    AppStorage.setOrCreate<boolean>(STANDALONE_CLOSE_REQUEST_KEY, false);
    // 详细说明也清一次：主窗口占位区显示它，留着旧故障会误导人。
    try {
      AppStorage.setOrCreate<string>(STANDALONE_NOTICE_KEY, '');
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '清空独立窗口说明失败');
    }

    // 机型外形适配：把轮廓套上去。放在这里（而不是等 surface 挂好）是因为渲染器
    // 那两个设置是**粘性**的 —— CoreApi.h:365 原文 "The setting is retained across
    // preview-window reattachment"，draw 时读，与 attach 的先后无关。
    this.apply_preview_corners();

    // 锁比例若失败了，Ability 把原因写进了这个键。栏上只给短徽标，完整原因走
    // STANDALONE_NOTICE_KEY（主窗口占位区显示）—— 失败必须能被看见，但不能把栏吃掉。
    try {
      const aspectError: string | undefined = AppStorage.get<string>(STANDALONE_ASPECT_ERROR_KEY);
      if (aspectError !== undefined && aspectError.length > 0) {
        this.flag_notice(NOTICE_ASPECT, `窗口比例锁未生效：${aspectError}`);
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '读比例锁失败原因失败');
    }

    hilog.info(DOMAIN, TAG, '独立预览窗口已创建，设备=%{public}s 轮廓=%{public}s',
      this.deviceName.length > 0 ? this.deviceName : '(未命名)', this.profile.id);

    this.start_diag_timer();
  }

  aboutToDisappear(): void {
    // ★ 必须先注销本窗口这一路悬停来源再收尾：窗口是被销毁的，不会再有
    //   hover=false 事件送进来。不注销的话，接管态会永久停在"操控中"，
    //   于是本地系统指针一直藏着回不来 —— 那是用户连电脑都用不下去的状态。
    try {
      ReverseControlInput.shared().setHoverSource('standalone', false);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '注销反控来源失败: %{public}s',
        (error as BusinessError).message);
    }
    this.cancel_hide_timer();
    this.stop_diag_timer();
    this.finish();
  }

  // ── 反控状态轮询（独立窗口自己那一路） ────────────────────────────────────

  private start_diag_timer(): void {
    if (this.diagTimer >= 0) {
      return;
    }
    this.diagTimer = setInterval((): void => {
      this.poll_reverse_state();
    }, REVERSE_POLL_INTERVAL_MS);
  }

  private stop_diag_timer(): void {
    if (this.diagTimer >= 0) {
      clearInterval(this.diagTimer);
      this.diagTimer = -1;
    }
  }

  /**
   * 每轮重算本窗口这一路的反控状态，并刷新栏上读数。
   *
   * ★ 整个回调包 try：定时器里抛出的异常**没有人接管**，会被当成未捕获异常
   *   直接结束整个应用（项目铁律）。
   */
  private poll_reverse_state(): void {
    try {
      const input = ReverseControlInput.shared();
      // 「有没有可操控的画面」与「指针在不在上面」是两件事，前者随时会变，
      // 所以每轮上报一次（而不是只在 hover 时算一回）—— 否则"鼠标先停在画面上、
      // 画面随后才挂好"就不会自动生效。
      input.setPictureAvailable('standalone', this.surfaceAttached);
      input.refreshChannel();
      // 键盘焦点自愈：还在接管却没拿到焦点就再要一次（请求失败只返回 false、
      // 不抛异常，所以不看返回值就等于永远不知道键盘为什么哑）。
      if (input.isTakingOver() && !input.keyboardFocusOk()) {
        this.focus_input();
      }
      const text: string = input.readoutText();
      // 只在真的变了才写 @State：每 500ms 无脑赋值会让整棵子树白刷一遍。
      if (text !== this.reverseDiag) {
        this.reverseDiag = text;
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '反控状态轮询失败: %{public}s',
        (error as BusinessError).message);
    }
  }

  /** 主窗口要求关闭（@Watch 回调）。 */
  on_close_request(): void {
    if (this.closeRequested) {
      this.close_window();
    }
  }

  /**
   * 收尾：清渲染器圆角 + 通知主窗口"我不在了"。
   *
   * ★ 这里**不**调用 StandalonePreviewRequest.on_closed：那是主窗口的闭包，
   *   跨 Ability 调它没有保证。改成由主窗口在自己的 500ms 轮询里发现
   *   STANDALONE_ALIVE_KEY 变 false，自己执行「画面接回」—— 收尾逻辑留在主窗口。
   * ★ 也**不**动采集会话 —— 上游 MultiDevicePreviewManager.cs:198 明确：
   *   会话不是这个窗口建的就绝不许停（本移植的会话永远归主窗口）。
   */
  private finish(): void {
    if (this.resolved) {
      return;
    }
    this.resolved = true;
    // 先把渲染器的圆角复位，再交还画面。顺序不能反：渲染器的设置是全局粘性的
    // （CoreApi.h:365 "retained across preview-window reattachment"），不复位的话
    // 主窗口预览会顶着一个"为独立窗口算的"圆角。
    this.reset_preview_corners();
    try {
      AppStorage.setOrCreate<boolean>(STANDALONE_ALIVE_KEY, false);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '写存活标志失败');
    }
    // 模块单例若真的共享，主窗口下一轮 poll 就能直接看到；不共享也不影响
    // （主窗口另有 alive 键兜底）。两处都写，不赌其中之一。
    WindowServices.standalone_preview_open = false;
    hilog.info(DOMAIN, TAG, '独立预览窗口已关闭');
  }

  // ── 机型外形适配（上游 _cornerItem → ToggleCorners + 两处 SetXxxCornerProfile）──

  /**
   * 记一条故障：栏上只放短徽标，完整原因写进 AppStorage（主窗口占位区显示）。
   *
   * 为什么拆两处：栏高只有窗口宽度的 8%，一整句
   * 「窗口圆角未生效：Unauthorized operation. …」就能把它占满、把设备名挤没
   * （用户 2026-09-21 的截图正是这样）。短徽标负责"有事发生"，详细原因负责"是什么事"。
   */
  private flag_notice(short: string, detail: string): void {
    this.stripNotice = short;
    try {
      AppStorage.setOrCreate<string>(STANDALONE_NOTICE_KEY, detail);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '写详细说明失败');
    }
  }

  /** 故障恢复：**只清掉自己那一条**，别把别的路径写的说明顺手抹了。 */
  private clear_notice(short: string): void {
    if (this.stripNotice !== short) {
      return;
    }
    this.stripNotice = '';
    try {
      AppStorage.setOrCreate<string>(STANDALONE_NOTICE_KEY, '');
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '清详细说明失败');
    }
  }

  /** 把当前轮廓套到**画面**上（关掉时传 0，与上游 `_cornersEnabled ? r : 0` 一致）。 */
  private apply_preview_corners(): void {
    const radius: number = this.cornersEnabled ? this.profile.preview_radius() : 0;
    try {
      const code: number = setPreviewCornerProfile(radius, this.profile.curveExponent);
      if (code !== 0) {
        this.flag_notice(NOTICE_PREVIEW_CORNER, `画面轮廓未生效：渲染器返回 ${code}`);
        hilog.warn(DOMAIN, TAG, 'setPreviewCornerProfile 返回 %{public}d', code);
      } else {
        this.clear_notice(NOTICE_PREVIEW_CORNER);
      }
    } catch (error) {
      const failure = error as BusinessError;
      this.flag_notice(NOTICE_PREVIEW_CORNER, `画面轮廓未生效：${failure.message}`);
      hilog.warn(DOMAIN, TAG, 'setPreviewCornerProfile 异常: %{public}s', failure.message);
    }
  }

  /** 把渲染器圆角清零（关窗时用）。同样不能裸奔。 */
  private reset_preview_corners(): void {
    try {
      setPreviewCornerProfile(0, 2.0);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '复位渲染器圆角失败: %{public}s',
        (error as BusinessError).message);
    }
  }

  /**
   * 把轮廓套到**窗口本身**上 —— 上游 `im_session_set_window_corner_profile` 那一路
   * （NativePreviewWindow.cs:404 初始化、:1139 每次尺寸变化重算）。
   *
   * 平台差异（写清楚，不假装一致）：鸿蒙的 `window.setWindowCornerRadius(vp)`
   * **只收一个圆角值，没有超椭圆指数** —— 画面那层仍是超椭圆（2.08~2.36），
   * 窗口这层只能是正圆角。半径算式照搬上游 `GetGdiRadius`。
   */
  private apply_window_corners(shortEdgeVp: number): void {
    const radius: number = this.cornersEnabled
      ? this.profile.window_radius(shortEdgeVp, vp_to_px_ratio())
      : 0;
    if (radius === this.lastWindowRadius) {
      return;
    }
    this.lastWindowRadius = radius;
    const target: window.Window | null = this.peek_window();
    if (target === null) {
      return;
    }
    try {
      target.setWindowCornerRadius(radius).then((): void => {
        this.clear_notice(NOTICE_WINDOW_CORNER);
      }).catch((error: BusinessError): void => {
        this.flag_notice(NOTICE_WINDOW_CORNER, `窗口圆角未生效：${error.message}`);
        hilog.warn(DOMAIN, TAG, 'setWindowCornerRadius(%{public}d) 失败: %{public}s',
          radius, error.message);
      });
    } catch (error) {
      const failure = error as BusinessError;
      this.flag_notice(NOTICE_WINDOW_CORNER, `窗口圆角未生效：${failure.message}`);
      hilog.warn(DOMAIN, TAG, 'setWindowCornerRadius 异常: %{public}s', failure.message);
    }
  }

  /** 栏上的「圆角/直角」开关（上游右键菜单里那一项的等价入口）。 */
  private on_toggle_corners(): void {
    this.cornersEnabled = !this.cornersEnabled;
    // 换开关等于重新判定一次，先把上一次的结论清掉（各自清各自那条）。
    this.clear_notice(NOTICE_PREVIEW_CORNER);
    this.clear_notice(NOTICE_WINDOW_CORNER);
    this.apply_preview_corners();
    this.apply_window_corners(this.lastShortEdgeVp);
  }

  /**
   * 窗口尺寸变化 → 重算窗口轮廓圆角 + 重算条带高度。
   *
   * 对应上游 `NativePreviewWindow.cs:1139`：窗口收到 WM_SIZE 时重设 region，
   * 所以"拖动、等比例缩放"之后轮廓依然贴合（README 明确承诺了这一点）。
   *
   * ★ 条带高度也在这里算：它是窗口宽度的固定比例（见文件头推导），窗口一变就
   *   跟着变；而**鼠标划过不改变它** —— 这样 hover 显隐栏不会引起 XComponent
   *   尺寸变化，也就不会反复重建 surface。
   */
  private on_window_area_change(area: Area): void {
    try {
      const width: number = Number(area.width);
      const height: number = Number(area.height);
      if (Number.isNaN(width) || Number.isNaN(height) || width <= 0 || height <= 0) {
        return;
      }
      this.lastShortEdgeVp = Math.min(width, height);
      this.apply_window_corners(this.lastShortEdgeVp);
      const strip: number = standalone_strip_height(width);
      if (strip !== this.stripHeight) {
        this.stripHeight = strip;
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '窗口尺寸读取失败: %{public}s',
        (error as BusinessError).message);
    }
  }

  // ── 窗口对象与三键 ────────────────────────────────────────────────────────

  /** 同步取本窗口对象（由 Ability 存进 AppStorage）。取不到返回 null。 */
  private peek_window(): window.Window | null {
    try {
      const found: window.Window | undefined = AppStorage.get<window.Window>(STANDALONE_WINDOW_KEY);
      return found !== undefined && found !== null ? found : null;
    } catch (error) {
      return null;
    }
  }

  /** 最小化。 */
  private minimize_window(): void {
    const target: window.Window | null = this.peek_window();
    if (target === null) {
      this.flag_notice(NOTICE_MINIMIZE, '最小化失败：拿不到窗口对象');
      return;
    }
    try {
      target.minimize().then((): void => {
        this.clear_notice(NOTICE_MINIMIZE);
      }).catch((error: BusinessError): void => {
        this.flag_notice(NOTICE_MINIMIZE, `最小化失败：${error.message}`);
        hilog.warn(DOMAIN, TAG, 'minimize 失败: %{public}s', error.message);
      });
    } catch (error) {
      const failure = error as BusinessError;
      this.flag_notice(NOTICE_MINIMIZE, `最小化失败：${failure.message}`);
      hilog.warn(DOMAIN, TAG, 'minimize 异常: %{public}s', failure.message);
    }
  }

  // ★ 这里**没有**「放大/还原」：2026-09-21 用户明确要求去掉（2in1 上把这个画面
  //   窗口最大化没有意义 —— 比例锁会把它撑成屏幕内最大的等比矩形，视觉上等同
  //   于直接拖大）。窗口仍然可以被系统手势最大化，我们只是不提供这个按钮。

  /** 关闭：收尾 + 结束本 Ability（它的窗口随之消失）。 */
  private close_window(): void {
    this.finish();
    try {
      const ctx: common.Context | undefined = this.getUIContext().getHostContext();
      if (ctx === undefined || ctx === null) {
        return;
      }
      const abilityCtx: common.UIAbilityContext = ctx as common.UIAbilityContext;
      abilityCtx.terminateSelf().catch((error: BusinessError): void => {
        hilog.warn(DOMAIN, TAG, 'terminateSelf 失败: %{public}s', error.message);
      });
    } catch (error) {
      const failure = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'terminateSelf 异常: %{public}s', failure.message);
    }
  }

  // ── 浮层栏的显示/隐藏 ────────────────────────────────────────────────────

  private cancel_hide_timer(): void {
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
  }

  /** 带淡入淡出地切换栏的可见性。 */
  private set_strip_visible(visible: boolean): void {
    if (this.stripVisible === visible) {
      return;
    }
    animateTo({ duration: STRIP_FADE_MS }, (): void => {
      this.stripVisible = visible;
    });
  }

  /**
   * 鼠标在窗口里移动 → 判断是否该浮出栏。
   *
   * 用 `windowY`（相对窗口顶部）判断；拿不到就退化成"动了就显示"。
   * ★ 整个回调包 try：项目铁律 —— 定时器和事件回调里抛异常没人接管，
   *   会被当成未捕获异常直接结束应用。
   */
  private on_pointer_move(event: MouseEvent): void {
    try {
      let y: number = Number(event.windowY);
      if (Number.isNaN(y)) {
        y = Number(event.y);
      }
      if (Number.isNaN(y)) {
        return;
      }
      if (y <= STRIP_HIT_HEIGHT) {
        this.cancel_hide_timer();
        this.set_strip_visible(true);
        return;
      }
      if (this.stripPinned) {
        return;
      }
      this.cancel_hide_timer();
      this.hideTimer = setTimeout((): void => {
        try {
          this.hideTimer = -1;
          if (!this.stripPinned) {
            this.set_strip_visible(false);
          }
        } catch (error) {
          hilog.warn(DOMAIN, TAG, '隐藏浮层栏失败: %{public}s',
            (error as BusinessError).message);
        }
      }, STRIP_HIDE_DELAY_MS);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '处理鼠标移动失败: %{public}s',
        (error as BusinessError).message);
    }
  }

  // ═══════════ 反向控制：画面区输入 → BLE HID ═══════════
  //
  // 独立窗口才是用户日常真正在用的那个（主窗口让位显示占位），所以反控必须
  // 在这里也能用 —— 只做在主窗口等于没做。
  //
  // 与主窗口共用同一套规矩：事件翻译在 ReverseControlInput 里（各写一份必然
  // 会慢慢走偏），这里只负责把本窗口的事件递过去、把本窗口的画面区尺寸报上去。
  // 悬停按**来源**登记（'standalone'）：两个窗口交替发 hover 时到达顺序不定，
  // 单一布尔量会被一句过期的"离开"覆盖掉，接管状态就与事实相反。

  /** 画面区尺寸变化 → 换算基准（按来源记账，两个窗口的画面区大小不同）。 */
  private on_input_area_change(area: Area): void {
    try {
      // Length 可能是带单位的字符串（"402.00vp"），Number() 会给 NaN 并被守卫
      // 挡掉 —— 那样画面区尺寸永远停在 0，而它既是灵敏度换算的基准，也是差分
      // 路径能否工作的前置条件（缺它 = 接管了却一步都送不出去，且毫无提示）。
      const width = ReverseControlInput.length_to_vp(area.width);
      const height = ReverseControlInput.length_to_vp(area.height);
      if (width > 0 && height > 0) {
        ReverseControlInput.shared().setSurfaceSize('standalone', width, height);
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '反控尺寸同步失败: %{public}s',
        (error as BusinessError).message);
    }
  }

  /**
   * 指针进入/离开画面 → 进入/退出接管。
   *
   * 通道的惰性启动在这里也要做一次：用户完全可能先把画面挪到独立窗口、鼠标
   * 直接落在这一侧，主窗口的预览区一次都没被悬停过 —— 若只由主窗口负责启动，
   * 这里就会永远停在"未就绪"。（并发由外设内部的守卫兜住，重复调用是安全的。）
   */
  private on_input_hover(isHover: boolean): void {
    try {
      if (isHover) {
        // 通道是常驻设施：不管画面挂没挂上，先把它起起来（早点起来对后面有利）。
        this.ensure_reverse_channel();
      }
      const input = ReverseControlInput.shared();
      // 悬停一律登记，"此刻有没有画面"另报（见 setPictureAvailable）——
      // 那样"鼠标先停在画面上、画面随后才挂好"也能自动接管，不需要用户
      // 为了让它生效而先把鼠标移开再移回来。
      input.setPictureAvailable('standalone', this.surfaceAttached);
      const granted: boolean = input.setHoverSource('standalone', isHover);
      input.refreshChannel();
      if (isHover && granted) {
        // ★ 接管成立就把键盘焦点要过来。键盘事件只发给**有焦点**的节点，原先
        //   靠"点一下画面"拿焦点；而点击能否落到承接层取决于命中测试是否把
        //   透明承接层当鼠标目标，一旦不算就永远拿不到焦点、键盘全哑。
        //   "接管已成立"本身就说明指针确实在画面上、用户就是想操控它，
        //   此刻要焦点与"移上去就接管"是同一件事，不该再要求多点一下。
        this.focus_input();
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '反控悬停处理失败: %{public}s',
        (error as BusinessError).message);
    }
  }

  /**
   * 惰性启动蓝牙反控通道（只在"没在广播、也没有启动在途"时才动手）。
   *
   * 本窗口看不到主窗口那些状态变量，所以"是不是已经在跑"一律从外设单例回读 ——
   * 这正是单例该有的用法：状态在谁身上就问谁，别各自记一个布尔量。
   */
  private ensure_reverse_channel(): void {
    const hid = BluetoothHidPeripheral.shared();
    if (hid.isAdvertising() || this.channelStarting) {
      return;
    }
    // 用户显式停用过（主窗口那个按钮）就不再自动启动。标志放在 AppStorage 里，
    // 两个 Ability 读的是同一个值 —— 否则会出现"主窗口停了、这边又活了"。
    try {
      if (AppStorage.get<boolean>(REVERSE_CONTROL_DISABLED_KEY) === true) {
        return;
      }
    } catch (error) {
      // 读不到按键没过停用处理（默认允许自动启动）。不能让一次读失败
      // 把功能整个关掉 —— 那是"探针坏了反而把功能关了"的经典错。
    }
    // 取宿主上下文：拿不到就**返回**，绝不解引用（项目铁律）。
    // 用 undefined 而不是 null 做初值，是为了不依赖 getHostContext 的确切
    // 返回类型 —— 它在不同 SDK 上可能是 Context 也可能是 Context|undefined。
    let ctx: common.Context | undefined = undefined;
    try {
      ctx = this.getUIContext().getHostContext();
    } catch (error) {
      ctx = undefined;
    }
    if (ctx === undefined || ctx === null) {
      // 拿不到上下文就明确说，别默默什么都不做（那会被当成"功能坏了"）。
      this.flag_notice(NOTICE_REVERSE, '反控通道未启动：拿不到应用上下文');
      return;
    }
    this.channelStarting = true;
    hid.start(ctx).then((started: boolean): void => {
      // 回调里一行都不能裸奔：抛出即未捕获异常，整个应用会被结束。
      this.channelStarting = false;
      if (!started) {
        this.flag_notice(NOTICE_REVERSE, `反控通道未启动：${hid.errorText()}`);
      } else {
        this.clear_notice(NOTICE_REVERSE);
      }
    }).catch((error: BusinessError): void => {
      this.channelStarting = false;
      this.flag_notice(NOTICE_REVERSE, `反控通道启动异常：${error.code} ${error.message}`);
    });
  }

  /**
   * 让输入层拿到焦点（不拿焦点就收不到键盘事件）。
   *
   * ★ 两个容易踩的点：
   *   ① `requestFocus(key)` 返回 **`void`** —— 没有成功/失败可读，别拿返回值判断；
   *      焦点的真值由那层透明承接层的 `onFocus` / `onBlur` 回报。
   *   ② 参数是组件的可寻址标识，对应 `.id()`；`.key()` 在新版 SDK 上不再承担这个
   *      作用（真构建警告 "`key` can only be used for testing directories"），
   *      用错就会永远找不到组件、键盘静默哑掉。
   */
  private focus_input(): void {
    try {
      this.getUIContext().getFocusController().requestFocus('standalone_input');
    } catch (error) {
      ReverseControlInput.shared().noteKeyboardFocus(false);
      hilog.warn(DOMAIN, TAG, '输入层获取焦点失败: %{public}s',
        (error as BusinessError).message);
    }
  }

  /**
   * XComponent onLoad → surfaceId → 挂到渲染器。
   *
   * ★ 这一步就是「独立窗口拿到画面」的全部：渲染器只有**一个** EGLSurface，
   *   attach 一个新的等于把旧的销毁重建（OhosPreviewRenderer.cpp:579-580 在
   *   渲染线程里 destroy_gl() → create_gl(新 id)）。主窗口那边因此**什么都不用做**，
   *   只需要让位显示占位 —— 与上游 MainPreviewHost.Collapsed 是同一个语义。
   */
  on_surface_ready(): void {
    const surfaceId: string = this.xcController.getXComponentSurfaceId();
    if (surfaceId.length === 0) {
      this.hint = '未取到 surfaceId';
      return;
    }
    if (surfaceId === this.attachedSurfaceId) {
      return;
    }
    const result: number = attachPreview(surfaceId);
    if (result === 0) {
      this.attachedSurfaceId = surfaceId;
      this.surfaceAttached = true;
      this.hint = '';
      // 画面到位了要立刻重算一次接管态：鼠标可能早就停在画面上了（挂载是异步的，
      // 那一次 hover 已经过去），不重算就得等用户把鼠标移开再移回来才生效。
      try {
        const input = ReverseControlInput.shared();
        input.setPictureAvailable('standalone', true);
        input.refreshChannel();
      } catch (error) {
        hilog.warn(DOMAIN, TAG, '画面就绪后重算接管态失败: %{public}s',
          (error as BusinessError).message);
      }
    } else {
      // 失败原因必须原样报出来（本工程纪律：不留"看着像好了"的假成功）。
      this.attachedSurfaceId = '';
      this.surfaceAttached = false;
      this.hint = `挂载预览失败：${lastError()}`;
      try {
        ReverseControlInput.shared().setPictureAvailable('standalone', false);
      } catch (error) {
        hilog.warn(DOMAIN, TAG, '登记画面不可用失败');
      }
    }
  }

  // ── 界面 ─────────────────────────────────────────────────────────────────

  /** 按钮边长（vp）：跟着条带高度走，小窗口也放得下。 */
  private button_size(): number {
    return Math.min(BUTTON_SIZE_MAX, Math.max(BUTTON_SIZE_MIN, this.stripHeight - 6));
  }

  /** 按钮图标边长（vp）：比按钮小 16 左右，避免图标顶到边。 */
  private button_icon_size(): number {
    return Math.max(BUTTON_ICON_MIN,
      Math.min(BUTTON_ICON_MAX, this.button_size() - 16));
  }

  /** 一个图标按钮（关闭/最小化共用同一套观感）。 */
  @Builder
  icon_button(iconName: string, size: number, iconSize: number, on_click: () => void) {
    Row() {
      FluentSymbol({ iconName: iconName, iconSize: iconSize, iconColor: TEXT });
    }
    .width(size)
    .height(size)
    .justifyContent(FlexAlign.Center)
    .borderRadius(6)
    .hoverEffect(HoverEffect.Highlight)
    .onClick((): void => {
      on_click();
    });
  }

  /** 栏上的文字开关（圆角/直角、常驻/自动 共用）。 */
  @Builder
  text_toggle(label: string, active: boolean, width: number, on_click: () => void) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor(active ? ACCENT : MUTED_TEXT);
    }
    .width(width)
    .height(26)
    .justifyContent(FlexAlign.Center)
    .borderRadius(6)
    .backgroundColor(active ? SELECTION : CONTROL_FILL)
    .margin({ left: 4 })
    .hoverEffect(HoverEffect.Highlight)
    .onClick((): void => {
      on_click();
    });
  }

  /**
   * 顶部条带：设备名/短徽标 + 常驻 + 圆角 + 关闭/最小化；拖动挂在整条上。
   *
   * ★ 两层结构：外层**永远占位**（高度 = stripHeight，底色是窗口 chrome），内层
   *   才是可以隐藏的内容。这样隐藏时条带不会塌掉 → 画面区尺寸不变 →
   *   XComponent 不重建 surface。若把整条设成 Hidden，虽然布局空间还在，但
   *   拖动/悬停这些交互也会一起失效，所以要分开。
   */
  @Builder
  strip() {
    Row() {
      Row() {
        // 两键**靠左、顺序为 关闭 → 最小化** —— 对齐 macOS「iPhone 镜像」窗口
        // 左上角三键（用户明确要求参考它，并要求**去掉"放大"那个**）。图标是单色
        // Fluent 符号，顺序是唯一能表达"哪个是哪个"的手段。
        this.icon_button('Dismiss20', this.button_size(), this.button_icon_size(), (): void => {
          this.close_window();
        });
        this.icon_button('Subtract20', this.button_size(), this.button_icon_size(), (): void => {
          this.minimize_window();
        });
        // 有故障先说故障（只放短徽标，完整原因在主窗口），否则显示设备名。
        // ★ 表达式直接内联在 Text 里（不抽方法/getter）：ArkTS 自定义 getter 会被
        //   静默剥离，而把状态读取放进 build 的表达式，改动才一定会触发刷新。
        Text(this.stripNotice.length > 0
          ? this.stripNotice
          : (this.deviceName.length > 0 ? this.deviceName : STABLE_TITLE))
          .fontSize(12)
          .fontColor(this.stripNotice.length > 0 ? WARNING : MUTED_TEXT)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 8 });

        // ── 反控读数（就地可读的真值） ──────────────────────────────────
        // 这一行是"指针藏了却操控不了"时的**唯一现场证据**（独立窗口没有主窗口
        // 那条状态行）。四段账各自独立，缺哪一段就指向哪一段的问题：
        //   `广1连0`          = 广播着但 iPhone 没连上（去手机上配对）—— 最容易被
        //                       漏判的一格：没连上时一切都是静默的
        //   `待机`            = 悬停没换成接管（指针不在这块画面 / 这里没画面）
        //   `接管 移0 无事件`  = 接管判据过了，但一个移动事件都没递到承接层
        //   `接管 移N 原0`     = 事件到了、原始位移不可用（应自动标"改差分"）
        //   `送X,Y` 在变       = 我们这侧一切正常，问题在手机/协议一侧
        //   `鼠N` 不涨         = notify 没成功；在涨而手机不动 ⇒ 手机侧不理这份报表
        //   `单特征/多特征`     = 当前 HID 布局（投递落点是否确定的前提）
        //   `读N` / `订S`      = ★★ 主机侧账本：主机来读了几次、订阅了没有。
        //                        这是"手机上到底有没有指针"的分水岭 ——
        //                        `广1连1 读0` = 主机连上了却什么都没读（配对/加密）；
        //                        `读N 订0`   = 读到了却不订阅（描述符/加密）；
        //                        `订1` 之后才轮到"报表投递落点"那一类问题。
        // ★ 只在真的有内容时占位：从没用过反控（没接管过、也没在广播）时返回空串。
        //   一旦用过，哪怕后来被停掉也要继续显示（"未启用"本身就是用户要知道的事）。
        if (this.reverseDiag.length > 0) {
          Text(this.reverseDiag)
            .fontSize(11)
            .fontColor(MUTED_TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            // 读数变长了（多了 读/订 两格与布局、广播-连接），宽度跟着放宽；
            // 仍然是单行 + 省略号 —— 条带是标题栏，不能因为诊断把画面挤下去。
            .constraintSize({ maxWidth: 400 })
            .margin({ left: 8 });
        }

        // 「常驻」：钉住后条带内容不再自动隐藏（要拖动窗口时很实用）。
        this.text_toggle(this.stripPinned ? PIN_ON_LABEL : PIN_OFF_LABEL, this.stripPinned, 52,
          (): void => {
            this.stripPinned = !this.stripPinned;
            if (this.stripPinned) {
              this.cancel_hide_timer();
              this.set_strip_visible(true);
            }
          });
        // 「圆角/直角」—— 上游右键菜单里那一项（README：「用户也可以通过右键菜单
        // 手动去除或恢复圆角」）。入口换了，语义没换：off = 半径传 0。
        this.text_toggle(this.cornersEnabled ? CORNER_ON_LABEL : CORNER_OFF_LABEL,
          this.cornersEnabled, 52, (): void => {
            this.on_toggle_corners();
          });
      }
      .width('100%')
      .height('100%')
      .padding({ left: 8, right: 8 })
      .alignItems(VerticalAlign.Center)
      // ★ 用 visibility 而不只是 opacity：opacity 0 的组件**仍然会响应点击**，
      //   那样内容隐藏后在条带上点一下就会误触按钮。
      .visibility(this.stripVisible ? Visibility.Visible : Visibility.Hidden)
      .opacity(this.stripVisible ? 1 : 0);
    }
    .width('100%')
    .height(this.stripHeight)
    .backgroundColor(CONTROL_FILL)
    // ★ 鼠标停在条带上时不许隐藏：否则"点按钮"会变成追着栏跑。
    .onHover((isHover: boolean): void => {
      try {
        if (isHover) {
          this.cancel_hide_timer();
          this.set_strip_visible(true);
        }
      } catch (error) {
        hilog.warn(DOMAIN, TAG, '处理悬停失败: %{public}s', (error as BusinessError).message);
      }
    })
    .onMouse((event: MouseEvent): void => {
      // 拖动只挂在条带上，不挂画面区（否则反控/点击会跟拖动打架）。
      if (event.action === MouseAction.Press) {
        const target: window.Window | null = this.peek_window();
        if (target !== null) {
          try {
            target.startMoving().catch((error: BusinessError): void => {
              hilog.warn(DOMAIN, TAG, 'startMoving 失败: %{public}s', error.message);
            });
          } catch (error) {
            hilog.warn(DOMAIN, TAG, 'startMoving 异常: %{public}s',
              (error as BusinessError).message);
          }
        }
      }
    });
  }

  /** 画面没挂上时的遮罩（对齐主窗口 preview_waiting_device 的写法）。 */
  @Builder
  attachment_notice() {
    Column() {
      Text(this.hint.length > 0 ? this.hint : '正在挂载预览…')
        .fontSize(12)
        .fontColor(MUTED_TEXT)
        .width('100%')
        .textAlign(TextAlign.Center);
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(APP_BACKGROUND);
  }

  build() {
    // ★ 布局是**上下两块**，不是浮层：条带永远占位，画面只拿剩下那块。
    //   条带高度 = 窗口宽度 × STANDALONE_STRIP_FRACTION，而 Ability 锁的内容区
    //   比例 K = 1/(1/R + f) 正是按这个前提算的 —— 所以画面区恰好是 W × W/R，
    //   手机画面既不被压住也不变形（推导见 WindowServices 里的注释）。
    Column() {
      // ① 顶部条带
      this.strip()

      // ② 画面
      Stack({ alignContent: Alignment.TopStart }) {
        XComponent({
          id: 'standalone_preview',
          type: XComponentType.SURFACE,
          controller: this.xcController,
        })
          .onLoad((): void => {
            this.on_surface_ready();
          })
          .width('100%')
          .height('100%')

        if (!this.surfaceAttached) {
          this.attachment_notice()
        }

        // ── 反向控制的输入承接层（与主窗口同一套规矩） ──────────────────
        // 常驻的透明层，铺满整个画面区：鼠标落到手机上就接管，移开就释放。
        //
        // ★ 常驻是必须的 —— onHover 只有组件**已经存在**时才触发，挂成条件
        //   渲染就永远等不到第一次悬停（只能先点一下把它创建出来，那又回到
        //   要手动操作的老路）。是否真的转发由 ReverseControlInput 的接管态
        //   决定，与这一层在不在无关。
        // ★ 不挂在 XComponent 上：它的 surface 由原生渲染器直接消费，通用
        //   指针事件的投递不保证稳定（主窗口那边已实测过，同一套做法）。
        Column()
          .id('standalone_input')
          .focusable(true)
          .width('100%')
          .height('100%')
          .backgroundColor(Color.Transparent)
          // 焦点真值由组件自己报（requestFocus 返回 void，没有成功/失败可读）：
          // 主窗口若还开着，"接管了但键盘哑掉"和"通道没通"现象一模一样，
          // 必须让焦点也进账本。requestFocus 找的正是这里的 `.id()`。
          .onFocus((): void => {
            ReverseControlInput.shared().noteKeyboardFocus(true);
          })
          .onBlur((): void => {
            ReverseControlInput.shared().noteKeyboardFocus(false);
          })
          .onAreaChange((_oldArea: Area, newArea: Area): void => {
            this.on_input_area_change(newArea);
          })
          .onHover((isHover: boolean): void => {
            this.on_input_hover(isHover);
          })
          .onMouse((event: MouseEvent): void => {
            ReverseControlInput.shared().handle_mouse(event);
          })
          .onAxisEvent((event: AxisEvent): void => {
            ReverseControlInput.shared().handle_axis(event);
          })
          .onKeyEvent((event: KeyEvent): void => {
            ReverseControlInput.shared().handle_key(event);
          })
          .onClick((): void => {
            // 点一下把焦点交给这一层：不拿焦点就收不到键盘事件。
            this.focus_input();
          })
      }
      .width('100%')
      .layoutWeight(1)
      // ── 反向控制的**兜底**承接（与里面那层透明承接层双保险） ────────────
      // 画面区容器与承接层几何完全重合（承接层是 100%×100% 的子节点）⇒ 两者的
      // 局部坐标一致，转发语义一字不差；但容器是"有子节点的容器"，属于命中测试
      // 里最不会漏的一类节点。万一某版本把"透明的空容器"不当鼠标命中目标，
      // 事件仍会在容器这一层被接住（鼠标事件沿命中路径冒泡 —— MouseEvent 上
      // 存在 stopPropagation 即证明它冒泡）。同一事件被两处各收一次时由
      // handle_mouse 按事件指纹去重，不会发两遍，去重次数进诊断。
      .onMouse((event: MouseEvent): void => {
        ReverseControlInput.shared().handle_mouse(event);
      })
      .onAxisEvent((event: AxisEvent): void => {
        ReverseControlInput.shared().handle_axis(event);
      })
    }
    .width('100%')
    .height('100%')
    // 鼠标移到顶部热区 → 浮出条带内容；移开 → 延时隐藏（macOS「iPhone 镜像」的行为）。
    .onMouse((event: MouseEvent): void => {
      this.on_pointer_move(event);
    })
    // 窗口尺寸变化时重算窗口轮廓圆角与条带高度（对应上游 WM_SIZE → :1139）。
    .onAreaChange((_oldArea: Area, newArea: Area): void => {
      this.on_window_area_change(newArea);
    })
    // 上游设备模式 HWND 没有设背景刷 ⇒ 客户区底色是黑的；这里照做。
    .backgroundColor(Color.Black)
    .border({ width: 1, color: BORDER_SOFT });
  }
}
