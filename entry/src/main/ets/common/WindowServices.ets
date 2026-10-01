// WindowServices.ets —— 子窗口与主窗口之间的服务注册表
//
// ── 为什么需要它 ────────────────────────────────────────────────────────────
// 原版子窗口大量用「构造函数注入委托」的方式跟主窗口通信，例如
// ImageSettingsWindow：
//
//   internal ImageSettingsWindow(ImageAdjustmentValues originalValues,
//       Func<ImageAdjustmentValues, (bool Success, string Message)> preview,
//       Func<ImageAdjustmentValues, (bool Success, string Message)> save,
//       Func<ImageAdjustmentValues, (bool Success, string Message)> revert)
//
// 鸿蒙的子窗口是用 window.createSubWindowWithOptions() + setUIContent() 建的，
// 没有「把 C# 委托塞进构造函数」这种通道（setUIContent 只收页面路径字符串）。
//
// 但子窗口页面与主窗口页面跑在**同一个 ArkTS 运行时**（同一个 UIAbility 进程），
// 所以模块级的单例是被共享的。于是这里把原版那些通道原样搬成一组静态字段：
// 主窗口在启动时注入实现，子窗口直接调用——语义与原版一致
// （都是「谁开窗谁提供实现」），只是注入点从构造函数挪到了启动时。
//
// ⚠ 这不是行为变更：原版每个委托的**返回值语义**（(bool Success, string Message)）
//   在下面用 ImageAdjustmentResult 一比一复刻，校验不通过时照样把 Message 返回给
//   窗口显示，窗口照样不关。
//
// ── 本文件提供三类通道 ─────────────────────────────────────────────────────
//   ① 服务注册（register_* / *_window）：主窗口 → 子窗口 的反向调用
//      （原版是主窗口持有窗口对象直接调 internal 方法）
//   ② 开窗入参（pending_*）：调用方 → 子窗口（原版是构造函数实参）
//   ③ 关窗结果（DeviceSelectionRequest.on_result）：子窗口 → 调用方
//      （原版是 ShowDialog() 的同步返回值）
//
// ── 与原版的一处必然差异 ────────────────────────────────────────────────────
// 原版是「一个窗口一份委托实例」，因为每次 new 都传入新的闭包；这里注册表是全局
// 一份。对这些窗口而言，同一时刻只有一个实例在跑（SubWindowHost.open 会复用已开
// 的窗口），所以不产生可观察差异。若将来出现同一类窗口多实例，需要改成按窗口名
// 存一份。

import { DeviceViewModel } from './DeviceViewModel';
import { CORNER_RECTANGULAR, DeviceCornerProfile } from './DeviceCornerProfile';

// ───────────────────── 画面调节（ImageSettingsWindow） ─────────────────────

/** 画面调节的四个值 —— 对应原版 ImageSettingsWindow.xaml.cs 的 ImageAdjustmentValues。 */
export interface ImageAdjustmentValues {
  brightness: number;
  contrast: number;
  saturation: number;
  gamma: number;
}

/** 原版每个委托的返回类型 (bool Success, string Message)。 */
export interface ImageAdjustmentResult {
  success: boolean;
  message: string;
}

/** 原版 Func<ImageAdjustmentValues, (bool Success, string Message)>。 */
export type ImageAdjustmentAction = (values: ImageAdjustmentValues) => ImageAdjustmentResult;

/**
 * 画面调节窗口对外暴露的三个入口 —— 对应原版 ImageSettingsWindow 的三个 internal 方法：
 *   SetEditingEnabled(bool) / CloseForShutdown() / CloseForSessionInvalidation()
 * 原版是主窗口拿着窗口对象直接调；鸿蒙侧子窗口是独立页面，所以由窗口自己注册进来，
 * 主窗口通过 WindowServices.image_window 反向调用。
 */
/**
 * 画面调节窗口对外的入口 —— 对应原版 ImageSettingsWindow 的三个 internal 方法。
 * 用 class（而非 interface + 对象字面量）承载：本 SDK 的 ArkTS 编译器禁止把「含方法成员
 * 的对象字面量」赋给 interface 类型(arkts-no-untyped-obj-literals)，所以窗口侧必须
 * `new ImageSettingsHandle(...)` 传入闭包，而不能写 `{ set_editing_enabled: ... }`。
 */
export class ImageSettingsHandle {
  private readonly onSetEditingEnabled: (enabled: boolean) => void;
  private readonly onCloseForShutdown: () => void;
  private readonly onCloseForSessionInvalidation: () => void;

  constructor(onSetEditingEnabled: (enabled: boolean) => void,
              onCloseForShutdown: () => void,
              onCloseForSessionInvalidation: () => void) {
    this.onSetEditingEnabled = onSetEditingEnabled;
    this.onCloseForShutdown = onCloseForShutdown;
    this.onCloseForSessionInvalidation = onCloseForSessionInvalidation;
  }

  set_editing_enabled(enabled: boolean): void {
    this.onSetEditingEnabled(enabled);
  }
  close_for_shutdown(): void {
    this.onCloseForShutdown();
  }
  close_for_session_invalidation(): void {
    this.onCloseForSessionInvalidation();
  }
}

function ok_result(): ImageAdjustmentResult {
  return { success: true, message: '' };
}

// ───────────────────── 设备选择（AirPlayDeviceSelectionWindow） ─────────────────────

/**
 * 待传给 AirPlay 设备选择窗口的入参。
 * 对应原版：
 *   internal static DeviceViewModel? Show(Window owner, IReadOnlyList<DeviceViewModel> devices)
 *   { var window = new AirPlayDeviceSelectionWindow(owner, devices);
 *     return window.ShowDialog() == true ? window.SelectedDevice : null; }
 *
 * 入参 devices 走 pending_device_selection；返回值走 on_result 回调
 * （鸿蒙侧开窗是异步的，拿不到同步返回值）。
 *
 * on_result 必须「一次性」：无论用户点「确认」「取消」还是右上角 X，原版 ShowDialog()
 * 都会返回（true / false / null），调用方总能拿到结果。窗口里用 resolved 标志 +
 * 关窗钩子保证刚好回调一次，null 表示取消。
 */
export class DeviceSelectionRequest {
  devices: DeviceViewModel[] = [];
  on_result: (selected: DeviceViewModel | null) => void = () => {};

  constructor(devices: DeviceViewModel[], on_result: (selected: DeviceViewModel | null) => void) {
    this.devices = devices;
    this.on_result = on_result;
  }
}

// ───────────────────── 受保护内容提示（ProtectedContentNoticeWindow） ─────────────────────

/**
 * src/App/Services/ProtectedContentStatus.cs:
 *   internal readonly record struct ProtectedContentPresentation(
 *       bool IsProtected, bool AudioActive, uint AudioSampleRate, uint AudioChannels)
 */
export interface ProtectedContentPresentation {
  isProtected: boolean;
  audioActive: boolean;
  audioSampleRate: number;
  audioChannels: number;
}

/**
 * 受保护内容提示窗口对外的入口 —— 对应原版 ProtectedContentNoticeWindow.UpdatePresentation。
 * 原版是主窗口持有窗口对象直接调；这里由窗口自己注册，主窗口反向调用。
 */
/**
 * 受保护内容提示窗口对外的入口 —— 对应原版 ProtectedContentNoticeWindow.UpdatePresentation。
 * 同样是 class（原因见 ImageSettingsHandle：含方法的对象字面量不能赋给 interface）。
 */
export class ProtectedContentHandle {
  private readonly onUpdatePresentation: (presentation: ProtectedContentPresentation) => void;

  constructor(onUpdatePresentation: (presentation: ProtectedContentPresentation) => void) {
    this.onUpdatePresentation = onUpdatePresentation;
  }

  update_presentation(presentation: ProtectedContentPresentation): void {
    this.onUpdatePresentation(presentation);
  }
}

/** 受保护内容提示窗口的入参（原版构造函数第一、二个参数）。 */
export class ProtectedContentRequest {
  deviceUdid: string = '';
  presentation: ProtectedContentPresentation =
    { isProtected: false, audioActive: false, audioSampleRate: 0, audioChannels: 0 };

  constructor(deviceUdid: string, presentation: ProtectedContentPresentation) {
    this.deviceUdid = deviceUdid;
    this.presentation = presentation;
  }
}

// ───────────────────── 注册表本体 ─────────────────────

export class WindowServices {
  // ── 画面调节 ──

  /** 原版 ImageSettingsWindow 的 preview 委托。 */
  private static imagePreview: ImageAdjustmentAction | null = null;
  /** 原版 ImageSettingsWindow 的 save 委托。 */
  private static imageSave: ImageAdjustmentAction | null = null;
  /** 原版 ImageSettingsWindow 的 revert 委托。 */
  private static imageRevert: ImageAdjustmentAction | null = null;

  /** 当前活着的画面调节窗口（没有则为 null）。由该窗口自己注册。 */
  static image_window: ImageSettingsHandle | null = null;

  /**
   * 主窗口启动时注入三个委托。
   * 对应原版 `new ImageSettingsWindow(originalValues, preview, save, revert)` 里那三个实参。
   */
  static register_image_adjustments(preview: ImageAdjustmentAction,
                                    save: ImageAdjustmentAction,
                                    revert: ImageAdjustmentAction): void {
    WindowServices.imagePreview = preview;
    WindowServices.imageSave = save;
    WindowServices.imageRevert = revert;
  }

  /**
   * 原版 ImageSettingsWindow.Apply(action, values)：
   *   var result = action(values);
   *   FeedbackText.Text = result.Success ? string.Empty : result.Message;
   *   return result.Success;
   * 这里只负责「拿到结果」这一半；写 FeedbackText 由窗口自己做。
   * 没有注入实现时按原版「委托一定会被执行」的语义，返回成功且无消息
   * ——开发者预览（ShowDeveloperPreview）在原版里传的就是 `_ => (true, "")`。
   */
  private static apply(action: ImageAdjustmentAction | null,
                       values: ImageAdjustmentValues): ImageAdjustmentResult {
    if (action === null) {
      return ok_result();
    }
    return action(values);
  }

  static apply_image_preview(values: ImageAdjustmentValues): ImageAdjustmentResult {
    return WindowServices.apply(WindowServices.imagePreview, values);
  }

  static apply_image_save(values: ImageAdjustmentValues): ImageAdjustmentResult {
    return WindowServices.apply(WindowServices.imageSave, values);
  }

  static apply_image_revert(values: ImageAdjustmentValues): ImageAdjustmentResult {
    return WindowServices.apply(WindowServices.imageRevert, values);
  }

  /** 供主窗口判断是否已注入（原版靠「窗口对象是否为 null」判断）。 */
  static has_image_adjustments(): boolean {
    return WindowServices.imagePreview !== null;
  }

  // ── 开窗入参 ──

  /**
   * 待传给接下来打开的那个「设备选择类」窗口的入参。
   * 窗口在 aboutToAppear 里取走并置空 —— 对应原版「每个窗口实例自带一份构造参数」，
   * 避免上一次的残留影响下一次。
   */
  static pending_device_selection: DeviceSelectionRequest | null = null;

  /** 待传给下一个受保护内容提示窗口的入参。 */
  static pending_protected_content: ProtectedContentRequest | null = null;

  // ── 受保护内容提示 ──

  /** 当前活着的受保护内容提示窗口（没有则为 null）。 */
  static protected_content_window: ProtectedContentHandle | null = null;

  // ── 通用提示框 ──

  /** 待传给下一个通用提示框的入参。 */
  static pending_prompt: PromptRequest | null = null;

  // ── 独立预览窗口 ──

  /**
   * 待传给下一个独立预览窗口的入参。
   *
   * 与设备选择窗口同理：窗口实例自己带不走构造参数，所以用一次性的注册表传递，
   * 窗口在 aboutToAppear 里取走并置空。
   */
  static pending_standalone_preview: StandalonePreviewRequest | null = null;

  /**
   * 独立预览窗口是否开着。
   *
   * 主窗口要据此决定两件事：① 预览区改显示「已在独立窗口打开」的占位；
   * ② **不要**再去 attach 自己的 surface（否则会把画面从独立窗口抢回来）。
   * 上游对应的状态是 `_secondaryMirrors.IsOpen(device)`。
   */
  static standalone_preview_open: boolean = false;
}

// ───────────────────── 通用提示框（AppPromptWindow） ─────────────────────

/**
 * AppPromptWindow 的入参 + 结果通道。
 * 对应原版三个入口：
 *   internal static bool Confirm(string title, string body)   → showCancel=true，取 on_result 的布尔值
 *   internal static void Inform (string title, string body)   → showCancel=false，结果无人关心
 *   internal static void InformThen(title, body, Func<Task> afterShown)
 *        → showCancel=false，并且窗口上屏之后再跑 afterShown
 *          （原版挂在 ContentRendered 上，注释说「让提示先真正画到屏幕上，
 *            再去执行这次警告要求的 USB/会话清理」）
 */
export class PromptRequest {
  title: string = '';
  body: string = '';
  showCancel: boolean = true;
  /** 对应 ShowDialog() == true。Inform 类调用可以传空实现。 */
  on_result: (confirmed: boolean) => void = () => {};
  /** InformThen 的 afterShown；null 表示没有。 */
  after_shown: (() => void) | null = null;

  constructor(title: string, body: string, showCancel: boolean,
              on_result: (confirmed: boolean) => void,
              after_shown: (() => void) | null) {
    this.title = title;
    this.body = body;
    this.showCancel = showCancel;
    this.on_result = on_result;
    this.after_shown = after_shown;
  }
}

// ───────────────────── 独立预览窗口（StandalonePreviewWindow） ─────────────────────

/**
 * 原版 `src/App/Windows/NativePreviewWindow.cs` 的入参。
 *
 * 上游那个窗口是**裸 Win32 顶层窗口**（HwndSource + WS_POPUP，无边框），
 * 标题是 `$"iPhoneMirror — {device.DisplayName}"`（MultiDevicePreviewManager.cs:152-153）。
 * 鸿蒙这边的等价物是 SubWindowHost 开的子窗口 —— 它本来就是 `decorEnabled: false`
 * （无系统装饰），所以"无边框"这条天然成立，画面直接铺满整窗。
 *
 * 与上游一致的还有一处行为：**打开独立窗口时主窗口的预览让位**（上游会把主预览
 * 宿主 Collapsed 掉，换成「已在独立窗口打开」的占位）。这就是 on_closed 的意义 ——
 * 窗口关掉时要通知主窗口把画面接回去。
 */
export class StandalonePreviewRequest {
  /** 设备显示名，用于窗口标题。 */
  deviceName: string = '';
  /** 关闭时回调主窗口（把预览接回主窗口）。必调一次。 */
  on_closed: () => void = () => {};
  /**
   * 该设备的显示轮廓拟合（机型外形适配）。
   *
   * 为什么由主窗口算好再传进来、而不是窗口自己算：机型要靠 ProductType，
   * 而 ProductType 在主窗口的设备状态里（`Index.selectedModel`）；子窗口取不到。
   * 上游也是同一个分工 —— `MultiDevicePreviewManager.ShowCoreAsync` 解析出
   * profile，再把 `cornerRadius / curveExponent` 传进 `NativePreviewWindow`。
   */
  profile: DeviceCornerProfile = CORNER_RECTANGULAR;

  constructor(deviceName: string, on_closed: () => void, profile: DeviceCornerProfile) {
    this.deviceName = deviceName;
    this.on_closed = on_closed;
    this.profile = profile;
  }
}

// ───────────────────── 独立预览窗口：独立 Ability 通道 ─────────────────────
//
// ★ 2026-09-21：独立窗口从「子窗口」升级为**独立 UIAbility 的主窗口**。
//   动机（详见 entryability/StandalonePreviewAbility.ets 文件头）：
//     ① 子窗生命周期挂在主窗口上 —— 主窗口最小化，子窗跟着不显示，而
//        「独立子窗」要 API 26 的 zLevelAboveParentLoosened，本工程是 API 23；
//     ② 「只能等比例缩放」要 setContentAspectRatio，它**只认主窗、且只认 FLOATING**。
//
//   换过去之后，`StandalonePreviewRequest.on_closed` 这条回调**不再由独立窗口调**
//   —— 跨 Ability 的模块单例共享没有文档保证，所以改成：独立窗口只把
//   `STANDALONE_ALIVE_KEY` 置 false，主窗口在自己的 500ms 轮询里发现它没了，
//   由主窗口自己执行「画面接回」。收尾逻辑留在主窗口，不跨 Ability 调主窗代码。
//   （`StandalonePreviewRequest` 保留，供"万一以后退回子窗实现"时不用重写。）

/** 独立窗口页面路径（Ability 的 loadContent 用它）。 */
export const STANDALONE_PAGE: string = 'pages/windows/StandalonePreviewWindow';

/** 独立窗口 Ability 名（module.json5 的 abilities 里注册）。 */
export const STANDALONE_ABILITY: string = 'StandalonePreviewAbility';

/**
 * 独立窗口是否**真的活着**（由独立窗口页面/Ability 自己维护）。
 *
 * 取代原来的 `window.findWindow('StandalonePreviewWindow')` 判定 —— 独立 Ability
 * 的窗口名不是我们注册过的子窗名，findWindow 找不到它。
 */
export const STANDALONE_ALIVE_KEY: string = 'im.standalone.alive';

/** 主窗口 → 独立窗口：请求关闭（独立窗口用 @StorageLink 响应式接收）。 */
export const STANDALONE_CLOSE_REQUEST_KEY: string = 'im.standalone.closeRequest';

/** 锁宽高比失败时把原因挂在这里，主窗口状态行会显示（失败必须能被看见）。 */
export const STANDALONE_ASPECT_ERROR_KEY: string = 'im.standalone.aspectError';

/**
 * 独立窗口的**详细**异常说明（主窗口的占位区显示）。
 *
 * ★ 为什么要单独开一个键、而不是继续写在栏上：栏只有 40vp 高、宽度有限，
 *   一句「窗口圆角未生效：Unauthorized operation. xxx」会把整条栏占满，
 *   把画面顶部压得看不见（用户 2026-09-21 就是这么反馈的）。改成：
 *   栏上只留 4~6 个字的短徽标，完整原因走这里 → 主窗口占位区有空间慢慢写。
 *   两边都不丢信息，界面也不再被一句话吃掉。
 */
export const STANDALONE_NOTICE_KEY: string = 'im.standalone.notice';

/**
 * 独立窗口的**系统装饰**处理结果（Ability 写，主窗口显示）。
 *
 * 为什么不和上面那条合用一个键：写的人不同（Ability = 系统栏/三键；页面 = 圆角/
 * 挂载），合用一个键就会互相覆盖，谁后写谁赢 —— 那等于悄悄丢掉一条故障信息。
 * 两个键各写各的，主窗口把两条都列出来。
 */
export const STANDALONE_CHROME_NOTICE_KEY: string = 'im.standalone.chromeNotice';

/**
 * 用户是否**显式停用**了反向控制（主窗口设置面板那个「停止蓝牙反向控制」）。
 *
 * ★ 为什么必须有这一条：通道改成"鼠标悬停即自动启动"之后，如果只有自动那一路，
 *   用户点了停止、再把鼠标移回画面，它立刻又自己启动 —— 那个按钮就等于失灵，
 *   用户会认为整个应用不听使唤。所以自动启动前必须先看这个标志。
 * ★ 为什么放 AppStorage 而不是各写一个成员变量：独立预览窗口是另一个 UIAbility，
 *   它在自己那侧也会惰性启动通道（用户完全可能直接把鼠标落在独立窗口上），
 *   必须读到同一个决定，否则会出现"在主窗口停了、到独立窗口又活了"。
 */
export const REVERSE_CONTROL_DISABLED_KEY: string = 'im.reverseControl.disabled';

/**
 * 开发者模式（在关于页连点版本号 7 次开启；开启后再点一下关闭）。
 *
 * ★ 为什么走 AppStorage 而不是各写一个成员变量：开关在**关于子窗口**里点，效果却要
 *   落在**主窗口**的空态诊断区（那批 USB 服务 / DDK 权限 / 环境诊断 / 驱动绑定文字
 *   只给开发者看）。两个窗口跑在同一进程，@StorageLink 才能做到"一处点、另一处立刻变"。
 * ★ 仅本次运行有效（不落盘）：重启回到非开发者模式 —— 与"这是个调试入口"的定位一致，
 *   也免得普通用户误开后，每次启动都被一堆底层诊断刷屏。
 */
export const DEVELOPER_MODE_KEY: string = 'im.developerMode';

/**
 * 半透明窗口（磨砂观感）开关 —— 对齐 Windows 11 原生深色界面的 Acrylic/Mica 观感。
 *
 * ★ 已实机确认生效（读数：窗口透明=是、容器配色探测成功）⇒ 正式特性，不再标「实验」。
 *   磨砂能否模糊到桌面取决于系统合成器，但最坏只是"半透明无磨砂"，不影响任何功能；
 *   观感不合意可一键关闭（关闭 = 回到原纯色背景）。
 * ★ 这两个键**跨启动保留**（`EntryAbility.onCreate` 里由 `AppPreferences` 从
 *   `@ohos.data.preferences` 读回来）—— 用户选了开关/浓度，重启却回到默认值，等于没保存。
 *   （对比 `DEVELOPER_MODE_KEY`：那是调试入口，**有意**不持久化，每次启动都回到关闭。）
 * ★ 试过 `PersistentStorage.persistProp`，**实机仍不保留**：它的落盘时机不在我们手里，
 *   用户直接关掉/杀进程时来不及 ⇒ 换成显式 putSync + flushSync（见 `AppPreferences.ets`）。
 */
export const ACRYLIC_WINDOW_KEY: string = 'im.acrylicWindow';

/**
 * 浓度的**默认值**（'99' ≈ 60%，00=全透、FF=实色）。
 *
 * ★ 为什么不放在 Index.ets：`EntryAbility` 注册持久化时要用它作默认值，而 Index 是页面
 *   文件、被 Ability 引用会把整份 UI 拖进启动路径 ⇒ 放这里做唯一事实来源。
 */
export const ACRYLIC_ALPHA_DEFAULT: string = '99';

/**
 * 半透明窗口的**浓度档位**（根容器底色的 alpha 十六进制，00=全透、FF=实色）。
 *
 * ★ 为什么要有这个键：容器色与内容区背景都全透之后，根容器那层底色的 alpha 是
 *   **唯一**决定浓淡的量。做成运行时可选档位，用户就不必为"再透一点"改代码重建。
 */
export const ACRYLIC_ALPHA_KEY: string = 'im.acrylicAlpha';

/**
 * 半透明窗口两项调用的**结果**（EntryAbility 写入，设置面板读数显示）。
 * 为什么要回传而不是让页面猜：setWindowContainerColor / setWindowShadowEnabled 的失败
 * 路径有四种（201 权限 / 801 设备不支持 / 1300002 窗口状态 / 1300004 未授权），观感上
 * 全是"没变化"，只有把错误码读出来才能区分"权限没声明"与"这设备根本不支持"。
 */
export const WINDOW_ACRYLIC_RESULT_KEY: string = 'im.acrylicResult';
export const WINDOW_SHADOW_RESULT_KEY: string = 'im.shadowResult';

/**
 * 偏好持久化（`AppPreferences.ets`）的**读 / 写结果** —— 设置面板读数行显示。
 *
 * ★ 为什么"保存"这件事也要摊到读数上： Persistence 失败的表现和用户没改过**同形**
 *   （都是"回到默认"），只有把每次读写的结果读出来，才能区分「没打开偏好存储」、
 *   「读了用了旧值」、「写成功但没落盘」——否则只能靠猜。
 */
export const PERSIST_READ_RESULT_KEY: string = 'im.persistReadResult';
export const PERSIST_WRITE_RESULT_KEY: string = 'im.persistWriteResult';

/**
 * 顶部条带高度 ÷ 窗口宽度 —— **单一口径**，Ability 与页面共用。
 *
 * ── 为什么是"按宽度取比例"而不是固定 40vp ────────────────────────────────────
 * 用户要求「栏不许遮住手机画面」。要让条带不压画面，就只能把条带放在画面**之外**，
 * 于是窗口内容区 = 条带 + 画面。而「只能等比例放大缩小」要求窗口内容区比例是个
 * **常数** K = W/H。设条带高 s、源画面比例 R：
 *
 *     画面区 = W × (H − s)，要求 W /(H − s) = R
 *  ⇒  H = W/R + s  ⇒  K = W/H = 1 / (1/R + s/W)
 *
 * s 若取固定值，K 就随 W 变 —— 没有常数解，锁不住。**只有 s = f·W（按宽度取比例）
 * 时 K = 1/(1/R + f) 才是常数**，此时任何尺寸下画面都严格是 W × W/R：
 * 不变形、不被遮挡。这个 f 就是本常量。
 *
 * 副作用是"整个窗口连同条带一起等比例缩放"—— 与用户要的「只能等比例放大缩小」
 * 语义正好一致（条带也是窗口的一部分）。
 */
export const STANDALONE_STRIP_FRACTION: number = 0.08;

/** 条带在给定窗口宽度（vp）下的高度（vp）。 */
export function standalone_strip_height(widthVp: number): number {
  if (Number.isNaN(widthVp) || widthVp <= 0) {
    return 40;
  }
  return Math.round(widthVp * STANDALONE_STRIP_FRACTION);
}

/**
 * 源画面比例 → **窗口内容区**比例（`setContentAspectRatio` 的入参）。
 *
 * 推导见 STANDALONE_STRIP_FRACTION 的注释：K = 1/(1/R + f)。
 * R 非法时按上游兜底 201/437 处理。
 */
export function standalone_content_aspect(sourceAspect: number): number {
  const fallback: number = 201 / 437;
  const r: number = (Number.isNaN(sourceAspect) || sourceAspect <= 0) ? fallback : sourceAspect;
  return 1 / (1 / r + STANDALONE_STRIP_FRACTION);
}

/**
 * 独立窗口的 window 对象（由 Ability 存进来，页面同步取用）。
 *
 * 为什么不能让页面自己拿：页面侧只有异步的 `window.getLastWindow(ctx)`，而
 * 最小化/最大化/设圆角这些调用点都在事件回调里，用同步取用最简单可靠。
 * 存 window 对象进 AppStorage 是官方示例里就有的写法（'SUB_WINDOW'）。
 */
export const STANDALONE_WINDOW_KEY: string = 'im.standalone.window';

// ── want.parameters 的键（跨 Ability 只能带基本类型）──
export const WANT_DEVICE_NAME: string = 'im.standalone.deviceName';
export const WANT_ASPECT_RATIO: string = 'im.standalone.aspectRatio';
export const WANT_CORNER_ID: string = 'im.standalone.cornerId';
export const WANT_CORNER_ROUNDED: string = 'im.standalone.cornerRounded';
export const WANT_CORNER_RADIUS: string = 'im.standalone.cornerRadius';
export const WANT_CORNER_CURVE: string = 'im.standalone.cornerCurve';
export const WANT_CORNER_GDI: string = 'im.standalone.cornerGdi';

// ── Ability 把 want 参数转存进 AppStorage 后，页面读这些键 ──
export const STANDALONE_DEVICE_NAME_KEY: string = 'im.standalone.deviceNameValue';
export const STANDALONE_ASPECT_KEY: string = 'im.standalone.aspectValue';
export const STANDALONE_CORNER_ID_KEY: string = 'im.standalone.cornerIdValue';
export const STANDALONE_CORNER_ROUNDED_KEY: string = 'im.standalone.cornerRoundedValue';
export const STANDALONE_CORNER_RADIUS_KEY: string = 'im.standalone.cornerRadiusValue';
export const STANDALONE_CORNER_CURVE_KEY: string = 'im.standalone.cornerCurveValue';
export const STANDALONE_CORNER_GDI_KEY: string = 'im.standalone.cornerGdiValue';

/** 从 want.parameters 取字符串（取不到或空串则回退）。 */
export function read_want_string(params: Record<string, Object>, key: string,
                                 fallback: string): string {
  const raw: Object | undefined = params[key];
  if (raw === undefined || raw === null) {
    return fallback;
  }
  const text: string = String(raw);
  return text.length > 0 ? text : fallback;
}

/** 从 want.parameters 取数值（取不到或非数则回退）。 */
export function read_want_number(params: Record<string, Object>, key: string,
                                 fallback: number): number {
  const raw: Object | undefined = params[key];
  if (raw === undefined || raw === null) {
    return fallback;
  }
  const value: number = Number(raw);
  return Number.isNaN(value) ? fallback : value;
}

/** 把轮廓拆成 want 带得走的标量（DeviceCornerProfile 的字段全是基本类型）。 */
export function corner_to_want(profile: DeviceCornerProfile): Record<string, Object> {
  const out: Record<string, Object> = {};
  out[WANT_CORNER_ID] = profile.id;
  out[WANT_CORNER_ROUNDED] = profile.isRounded ? 1 : 0;
  out[WANT_CORNER_RADIUS] = profile.radiusRatio;
  out[WANT_CORNER_CURVE] = profile.curveExponent;
  out[WANT_CORNER_GDI] = profile.gdiRadiusRatio;
  return out;
}

/** 从 AppStorage 的 5 个标量还原出轮廓（与 corner_to_want 配对）。 */
export function corner_from_storage(): DeviceCornerProfile {
  let id: string = 'rectangular';
  let rounded: number = 0;
  let radius: number = 0;
  let curve: number = 2;
  let gdi: number = 0;
  try {
    const v1: string | undefined = AppStorage.get<string>(STANDALONE_CORNER_ID_KEY);
    if (v1 !== undefined && v1.length > 0) {
      id = v1;
    }
    const v2: number | undefined = AppStorage.get<number>(STANDALONE_CORNER_ROUNDED_KEY);
    if (v2 !== undefined) {
      rounded = v2;
    }
    const v3: number | undefined = AppStorage.get<number>(STANDALONE_CORNER_RADIUS_KEY);
    if (v3 !== undefined) {
      radius = v3;
    }
    const v4: number | undefined = AppStorage.get<number>(STANDALONE_CORNER_CURVE_KEY);
    if (v4 !== undefined) {
      curve = v4;
    }
    const v5: number | undefined = AppStorage.get<number>(STANDALONE_CORNER_GDI_KEY);
    if (v5 !== undefined) {
      gdi = v5;
    }
  } catch (error) {
    return CORNER_RECTANGULAR;
  }
  return new DeviceCornerProfile(id, rounded !== 0, radius, curve, gdi);
}
