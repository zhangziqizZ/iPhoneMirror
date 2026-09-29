import { BluetoothHidPeripheral } from './BluetoothHidPeripheral';
import { BusinessError } from '@ohos.base';

// ─────────────────────────────────────────────────────────────────────────────
//  反向控制：电脑端输入 → iPhone
//
//  本模块负责"翻译"，发送端在 BluetoothHidPeripheral（BLE HID 外设）。
//  三个环节各管一件事，不混在一起：
//
//    ① 坐标换算：预览控件坐标 → 归一化 0..1（照上游 MapPointerToNormalized 的
//       letterbox 规则，落在黑边上直接丢弃）
//    ② 归一化 → HID 相对位移：iOS 的蓝牙鼠标只吃**相对量**，所以要做差分，
//       余数累积起来防止慢速移动被"归零"（上游 685-706 行同款做法）
//    ③ 按键/滚轮/键盘：直接组 HID report
//
//  ── 灵敏度口径怎么来的 ──────────────────────────────────────────────────
//  上游 PointerSensitivity() 返回 0.5 或 1/3，判据是
//  `min(sourceWidth, sourceHeight) >= 1400 ? 0.5 : 1/3`，注释写着
//  "iPhone 截图通常 3x 逻辑像素；新 iPad 常为 2x"。
//  换句话说 1/3 与 1/2 就是"物理像素 → 逻辑点"的换算因子（scale=3 / scale=2）。
//  于是：横划过一个预览区宽度 ⇒ HID 位移 = 源宽/scale × 灵敏度系数
//  —— 也就是 iPhone 上光标走一整屏。这是可验证的直白口径，不是拍的。
//
//  真实效果受 iOS 侧鼠标速度设置影响，所以最终发送值会进诊断，便于真机校准。
// ─────────────────────────────────────────────────────────────────────────────

// 鼠标按键位（与 HID Report Map 的 Button page 一致）
const BTN_LEFT = 0x01;
const BTN_RIGHT = 0x02;
const BTN_MIDDLE = 0x04;

// HID Keyboard/Keypad usage（HID Usage Tables 第 10 节）
const HID_KEY_NONE = 0x00;
const HID_KEY_A = 0x04;
const HID_KEY_1 = 0x1E;
const HID_KEY_0 = 0x27;
const HID_KEY_ENTER = 0x28;
const HID_KEY_ESCAPE = 0x29;
const HID_KEY_BACKSPACE = 0x2A;
const HID_KEY_TAB = 0x2B;
const HID_KEY_SPACE = 0x2C;
const HID_KEY_MINUS = 0x2D;
const HID_KEY_EQUAL = 0x2E;
const HID_KEY_LEFTBRACE = 0x2F;
const HID_KEY_RIGHTBRACE = 0x30;
const HID_KEY_BACKSLASH = 0x31;
const HID_KEY_SEMICOLON = 0x33;
const HID_KEY_APOSTROPHE = 0x34;
const HID_KEY_GRAVE = 0x35;
const HID_KEY_COMMA = 0x36;
const HID_KEY_DOT = 0x37;
const HID_KEY_SLASH = 0x38;
const HID_KEY_CAPSLOCK = 0x39;
const HID_KEY_F1 = 0x3A;
const HID_KEY_INSERT = 0x49;
const HID_KEY_HOME = 0x4A;
const HID_KEY_PAGEUP = 0x4B;
const HID_KEY_DELETE = 0x4C;
const HID_KEY_END = 0x4D;
const HID_KEY_PAGEDOWN = 0x4E;
const HID_KEY_RIGHT = 0x4F;
const HID_KEY_LEFT = 0x50;
const HID_KEY_DOWN = 0x51;
const HID_KEY_UP = 0x52;

// 修饰键位（HID Report Map 键盘 report 的第 0 字节）
const MOD_LCTRL = 0x01;
const MOD_LSHIFT = 0x02;
const MOD_LALT = 0x04;
const MOD_LGUI = 0x08;
const MOD_RCTRL = 0x10;
const MOD_RSHIFT = 0x20;
const MOD_RALT = 0x40;
const MOD_RGUI = 0x80;

// 鸿蒙 KeyCode（@ohos.multimodalInput.keyCode）—— 取值已逐个核对 d.ts
const HK_0 = 2000;
const HK_9 = 2009;
const HK_A = 2017;
const HK_Z = 2042;
const HK_COMMA = 2043;
const HK_PERIOD = 2044;
const HK_ALT_LEFT = 2045;
const HK_ALT_RIGHT = 2046;
const HK_SHIFT_LEFT = 2047;
const HK_SHIFT_RIGHT = 2048;
const HK_TAB = 2049;
const HK_SPACE = 2050;
const HK_ENTER = 2054;
const HK_DEL = 2055;          // 退格
const HK_GRAVE = 2056;
const HK_MINUS = 2057;
const HK_EQUALS = 2058;
const HK_LEFT_BRACKET = 2059;
const HK_RIGHT_BRACKET = 2060;
const HK_BACKSLASH = 2061;
const HK_SEMICOLON = 2062;
const HK_APOSTROPHE = 2063;
const HK_SLASH = 2064;
const HK_PAGE_UP = 2068;
const HK_PAGE_DOWN = 2069;
const HK_ESCAPE = 2070;
const HK_FORWARD_DEL = 2071;
const HK_CTRL_LEFT = 2072;
const HK_CTRL_RIGHT = 2073;
const HK_CAPS_LOCK = 2074;
const HK_META_LEFT = 2076;
const HK_META_RIGHT = 2077;
const HK_MOVE_END = 2082;
const HK_INSERT = 2083;
const HK_F1 = 2090;
const HK_DPAD_UP = 2012;
const HK_DPAD_DOWN = 2013;
const HK_DPAD_LEFT = 2014;
const HK_DPAD_RIGHT = 2015;

// 滚轮：一次轴事件换算成几格滚轮
const WHEEL_STEP_SCALE = 0.2;

// ★ rawDelta 可用性判定的连续次数阈值。
//   `MouseEvent.rawDeltaX/Y` 是**可选**字段（@since 15，OpenHarmony d.ts 原文：
//   "?number"），但"可选"只说明它可能缺席，并不保证"不支持时一定缺席" ——
//   若某些输入设备（触控板、经转接的鼠标）把字段填成恒定 0，那么"字段存在"
//   就会被误判成"原始位移可用"，于是永远走 onRawDelta、永远发不出位移，
//   而诊断里 rawEvents 还在涨 —— 那是最难查的一种"看着在工作"。
//   故这里不认"字段在不在"，只认"它到底有没有变过"：连续 6 次收到 0、
//   同一时刻绝对坐标明明在动 ⇒ 判定本机拿不到原始位移，改走差分。
const RAW_ZERO_STREAK_LIMIT = 6;

interface NormalizedPoint {
  nx: number;
  ny: number;
}

// 诊断快照 —— 反控"点了没反应"时唯一的定位出口
export interface ReverseControlDiag {
  enabled: number;        // 1 = 反控已启用
  takeover: number;       // 1 = 当前正被接管（鼠标在画面上）
  takeovers: number;      // 累计接管次数
  hoverCount: number;     // 当前有多少个来源正悬停在画面上
  rawEvents: number;      // 走 rawDelta 通道的移动事件数
  rawDx: number;          // 最近一次 rawDelta 横向原始计数
  rawDy: number;
  rawFallbacks: number;   // rawDelta 不可用、退回绝对坐标差分的次数
  rawUsable: number;      // 0 = 已判定本机拿不到原始位移（改走绝对坐标差分）
  rawZeroStreak: number;  // 连续多少次"原始计数为 0 而绝对坐标在动"
  absMoveEvents: number;  // 绝对坐标确实在变的移动事件数（探针的对照量）
  sizeMissingDrops: number; // 因缺画面尺寸 / 源尺寸而无法换算、只能丢弃的移动数
  dedupDrops: number;     // 同一次事件被两条承接路径各收一次而丢弃的重复数
  rawNote: string;        // rawDelta 判定结果的一句话（进状态行）
  surfaceW: number;       // 预览控件宽（vp）
  surfaceH: number;
  sourceW: number;        // 源帧宽（px）
  sourceH: number;
  scale: number;          // 逻辑像素倍率（2 或 3）
  sensitivity: number;    // 灵敏度百分比
  moveEvents: number;     // 收到的指针移动事件数
  inImageEvents: number;  // 落在画面内的移动事件数
  blackBarDrops: number;  // 落在黑边被丢弃的事件数
  sentX: number;          // 最近一次送出的 HID 横向位移
  sentY: number;
  wheelSteps: number;     // 累计滚轮格数
  buttonMask: number;     // 当前按下的鼠标按键位
  keyDown: number;        // 累计按键按下次数
  keyUp: number;
  unmappedKeys: number;   // 无法映射到 HID usage 的键次数
  lastKeyCode: number;    // 最近一次按键的鸿蒙 KeyCode
  kbdFocus: number;       // 1 = 最近一次 requestFocus 成功（0 ⇒ 键盘会静默哑掉）
  lastError: string;
}

export class ReverseControlInput {
  private static instance: ReverseControlInput = new ReverseControlInput();

  // ★ 这里**没有** enabled 字段，是刻意的。
  //   「通道开没开」一律从外设单例回读（见 isEnabled）：外设是被主窗口与独立
  //   窗口两条惰性启动路径共用的单例，若在本地存一个"谁打开过它"的布尔量，
  //   那么由独立窗口启动通道时，主窗口这一侧读到的就是 false，接管判据随之
  //   失效 —— 现象是"蓝牙在广播、iPhone 也连上了，鼠标放上去就是没反应"，
  //   而且查的时候两边读数都"看起来正常"。状态在谁身上就问谁，是这条链路上
  //   唯一不会错的口径。
  private surfaceW: number = 0;
  private surfaceH: number = 0;
  private sourceW: number = 0;
  private sourceH: number = 0;
  private sensitivity: number = 100;

  // 差分状态（归一化）
  private lastNx: number = 0;
  private lastNy: number = 0;
  private hasLast: boolean = false;
  // 余数累积：慢速移动时单次位移不足 1，直接截断会永远发不出去
  private remainderX: number = 0;
  private remainderY: number = 0;

  private buttonMask: number = 0;
  // 当前键盘按下的 usage 列表（HID 键盘 report 一次最多报 6 个）
  private pressedUsages: number[] = [];
  private modifiers: number = 0;

  private moveEvents: number = 0;
  private inImageEvents: number = 0;
  private blackBarDrops: number = 0;
  private sentX: number = 0;
  private sentY: number = 0;
  private wheelSteps: number = 0;
  private keyDown: number = 0;
  private keyUp: number = 0;
  private unmappedKeys: number = 0;
  private lastKeyCode: number = 0;
  private lastError: string = '';

  // ── 接管状态 ──────────────────────────────────────────────────────────────
  // 「启用」(enabled) 与「接管」(takingOver) 是两件事，不能合成一个布尔量：
  //   · enabled  = 通道层就绪（BLE HID 外设已启动 + iPhone 已连上），可以发事件
  //   · takingOver = 指针此刻落在画面上，事件**应该**转发给 iPhone
  // 分成两个量之后，「悬停进画面」才可能在通道就绪的前提下自动生效 ——
  // 这正是"无感"的全部含义：用户不需要去找开关，也不需要先点一下画面。
  private takingOver: boolean = false;
  private takeovers: number = 0;
  // 当前正悬停在画面上的来源（'main' / 'standalone'）。用集合而不是布尔量：
  // 两个窗口交替发 hover 时到达顺序不定，见 setHoverSource 的说明。
  private hoverSources: string[] = [];
  // 各来源的画面区尺寸（vp）。见 setSurfaceSize 的说明。
  private surfaceSizes: Map<string, number[]> = new Map<string, number[]>();
  // 各来源此刻是否**有可操控的画面**（画面在不在、挂没挂上）。
  //
  // ★ 必须与 hover 分开记：hover 只在指针进出时更新一次，而"画面有没有"是随时会
  //   变的（刚点了开始投屏、画面被挪到另一个窗口）。合成一个量就会出现
  //   「鼠标一直停在画面上没动，画面来了却不接管」—— 因为那一次 hover 早就过去了。
  //   分开之后判据每轮重算，画面一到位就能直接接管，不需要用户先移开再移回来。
  private pictureReady: Map<string, boolean> = new Map<string, boolean>();

  // rawDelta 通道的计数。rawDelta 是**鼠标硬件的原始计数**（HID 里的 mickey），
  // 与屏幕像素不是同一把尺子 —— 所以单独记账，便于真机校准灵敏度。
  private rawEvents: number = 0;
  private rawDx: number = 0;
  private rawDy: number = 0;
  private rawFallbacks: number = 0;

  // rawDelta 可用性探针（见 RAW_ZERO_STREAK_LIMIT 的说明）
  private rawUsable: boolean = true;
  private rawZeroStreak: number = 0;
  private rawNote: string = '';
  // 绝对坐标的上一帧值 —— 只用来当"鼠标到底动没动"的对照量
  private hasAbs: boolean = false;
  private lastAbsX: number = 0;
  private lastAbsY: number = 0;
  private absMoveEvents: number = 0;
  private sizeMissingDrops: number = 0;

  // 同一次事件被两条承接路径各收一次的去重账（见 handle_mouse 的说明）
  private dedupDrops: number = 0;
  private lastMouseStamp: string = '';
  private lastAxisStamp: string = '';

  // 键盘焦点：键盘事件**只发给有焦点的节点**，所以"接管了但键盘是哑的"这件事
  // 必须是可见的 —— 否则它和"通道没通"在现象上一模一样（鼠标能动、敲键盘没反应）。
  // 记录的是**最近一次 requestFocus 的返回值**（哪个窗口要的就算哪个的：同一时刻
  // 只可能有一个窗口在接管，指针在谁身上谁要焦点）。
  private keyboardFocus: boolean = false;

  static shared(): ReverseControlInput {
    return ReverseControlInput.instance;
  }

  /** 「反控已启用」= 外设正在广播。**每轮从单例回读真值**，不在本地缓存。 */
  isEnabled(): boolean {
    return BluetoothHidPeripheral.shared().isAdvertising();
  }

  /**
   * 上报"这一刻键盘有焦点吗"。
   *
   * 为什么必须有这一项：`requestFocus()` **返回 `void`**（没有成功/失败可读），
   * 且它按组件的**可寻址标识**（`.id()`）去找目标 —— 老写法 `.key()` 在新版 SDK 上
   * 已不再承担这个作用，于是调用会静默落空、键盘哑掉，现象与"通道没通"完全一样。
   * 所以焦点的真值交给组件自己的 `onFocus` / `onBlur` 回报，并进账本显示出来。
   * （记的是"最近一次事件"：同一时刻只可能有一个窗口在接管，指针在谁身上谁报。）
   */
  noteKeyboardFocus(ok: boolean): void {
    this.keyboardFocus = ok;
  }

  keyboardFocusOk(): boolean {
    return this.keyboardFocus;
  }

  /**
   * 通道层的开/关通知。
   *
   * 打开时什么都不必记（判据是回读外设）；关闭时要把悬停来源清空并退出接管 ——
   * 否则"通道没了却还在接管"会让本地光标一直藏着不回来，那是用户连电脑都用
   * 不下去的状态。
   */
  setEnabled(on: boolean): void {
    if (on) {
      return;
    }
    this.hoverSources = [];
    this.sync_takeover();
  }

  /**
   * 每轮轮询调一次，重算接管态。
   *
   * 通道状态随时可能被别处改掉：iPhone 自己断开、设备绑定器窗口停掉外设、
   * 某个窗口退出。不每轮重算的话，接管态会停在一个过期值上 ——
   * 要么该释放时还吸着鼠标，要么该接管时没反应。
   */
  refreshChannel(): void {
    this.sync_takeover();
    // 每拍（500ms）顺带推一次"配对探测"的节拍 —— 它内部按
    // BOND_PROBE_INTERVAL_TICKS 限流，真正去问系统大约每 10s 一次。
    // 放在这里是因为主窗口与独立窗口都会调 refreshChannel()。
    try {
      BluetoothHidPeripheral.shared().bond_probe_tick();
    } catch (error) {
      // 定时器回调里抛异常会结束整个应用；而探测失败本身不影响任何功能，
      // 所以这里刻意吞掉（真值会在下一次探测里被重新写入）。
    }
  }

  /**
   * 一整段可复制的诊断文本（设置面板「复制诊断」按钮用）。
   *
   * 分成"输入侧 + HID 侧"两段：这两侧本来就是两条独立的故障面 —— 输入侧回答
   * "事件到没到、位移算不算得出"，HID 侧回答"主机有没有来读、有没有订阅"。
   * 一段话复制过来，比在两条短句里找读数可靠得多（2026-09-22 的教训：
   * 让用户读六个数字，结果一个都没收到）。
   */
  diagnosisText(): string {
    const hid = BluetoothHidPeripheral.shared();
    const lines: string[] = [];
    lines.push('[iPhoneMirror 反控诊断 · 输入侧]');
    lines.push(`启用${this.isEnabled() ? 1 : 0} 接管${this.takingOver ? 1 : 0} 悬停来源=${this.hoverSources.length > 0 ? this.hoverSources.join(',') : '(无)'} 累计接管${this.takeovers}`);
    lines.push(`窗口=${this.surfaceW}×${this.surfaceH} 画面=${this.sourceW}×${this.sourceH} 灵敏度=${this.sensitivity}%`);
    lines.push(`事件: 移动${this.moveEvents} 画面内${this.inImageEvents} 黑边丢弃${this.blackBarDrops} 原始位移${this.rawEvents} 降级${this.rawFallbacks} 去重${this.dedupDrops} 缺尺寸${this.sizeMissingDrops}`);
    lines.push(`原始位移可用${this.rawUsable ? 1 : 0} 最近发送=(${this.sentX},${this.sentY}) 按键掩码=${this.buttonMask} 滚轮格=${this.wheelSteps}`);
    lines.push(`键盘: 按下${this.keyDown} 抬起${this.keyUp} 未映射${this.unmappedKeys} 最近键码=${this.lastKeyCode} 有焦点=${this.keyboardFocus ? 1 : 0}`);
    lines.push(`原始位移判定: ${this.rawNote.length > 0 ? this.rawNote : '(探针未触发)'}`);
    if (this.lastError.length > 0) {
      lines.push(`输入侧错误: ${this.lastError}`);
    }
    lines.push('');
    lines.push(hid.diagnosisText());
    return lines.join('\n');
  }

  /**
   * 登记某个来源（主窗口 / 独立预览窗口）的悬停状态，并据此重算接管。
   *
   * ★ 为什么不是简单的 `setTakeover(bool)`：现在有两个窗口都能发起操控，
   *   而鼠标从主窗口移到独立窗口时，两边的 hover 事件到达顺序是不定的 ——
   *   若"进入"先到、"离开"后到，单一布尔量就被那句过期的"离开"覆盖掉，
   *   接管状态与事实完全相反（鼠标明明在独立窗口上，却处于已释放）。
   *   按来源分别登记、由"还有没有来源在悬停"统一裁定，顺序就不再有影响。
   *   来源离开时忘记注销也是同理：窗口被直接销毁的话会永远残留，
   *   所以两个窗口都在 aboutToDisappear 里显式注销自己。
   *
   * 返回**是否真的接管**（而非"有没有收到请求"）：调用方拿它决定本地光标
   * 藏不藏。通道没就绪时返回 false，指针照常当普通指针用，不产生副作用 ——
   * 这是"无感"的另一半：不可用时不许装成可用。
   */
  setHoverSource(source: string, isHover: boolean): boolean {
    const known: number = this.hoverSources.indexOf(source);
    if (isHover) {
      if (known < 0) {
        this.hoverSources.push(source);
      }
    } else if (known >= 0) {
      this.hoverSources.splice(known, 1);
    }
    return this.sync_takeover();
  }

  /** 按「有任一来源正悬停在画面上 且 通道就绪」重算接管态。 */
  private sync_takeover(): boolean {
    // 通道就绪的判据**回读外设**（不是本地记的布尔量）：两颗条件缺一不可 ——
    // 正在广播（外设活着）且 iPhone 已连上（有接收方）。
    const hid = BluetoothHidPeripheral.shared();
    // 「指针落在画面上」= 有任一来源**既在悬停、又有可操控的画面**。
    // 后一半每轮才更新一次，所以画面刚到位时不需要用户先移开再移回来
    // （见 pictureReady 的说明）。
    let pointerOnPicture: boolean = false;
    for (let i = 0; i < this.hoverSources.length; i++) {
      if (this.pictureReady.get(this.hoverSources[i]) === true) {
        pointerOnPicture = true;
        break;
      }
    }
    const want: boolean = pointerOnPicture
      && hid.isAdvertising()
      && hid.isConnected();
    if (want === this.takingOver) {
      return this.takingOver;
    }
    if (want) {
      this.takingOver = true;
      this.takeovers++;
      // 换算基准切到"此刻在悬停的这个窗口"的画面区尺寸 —— 两个窗口的
      // 画面区大小不同，沿用上一个窗口的会让划动距离算偏。
      this.apply_active_surface_size();
      // 接管瞬间把差分基准清掉：上一次离开时残留的基准点，会把"刚进来"
      // 算成一次跨度极大的移动，iPhone 光标会突然蹦一下。
      this.hasLast = false;
      this.remainderX = 0;
      this.remainderY = 0;
      return true;
    }
    this.takingOver = false;
    // 释放时必须把按下的键与键帽都放掉，否则 iPhone 侧会留着"一直按住的
    // 鼠标键"—— 用户以为松手了，手机上还在拖。
    this.reset();
    return false;
  }

  isTakingOver(): boolean {
    return this.takingOver;
  }

  // ── 事件入口（主窗口与独立窗口共用） ──────────────────────────────────────
  //
  // 两个窗口要做的是完全同一件事：把 ArkUI 的鼠标/轴/键盘事件翻译成 HID 动作。
  // 翻译只写一份 —— 各写一份的结果必然是某天只改了一处，于是出现"主窗口好使、
  // 独立窗口不好使"这种最难查的不一致。

  /**
   * `Area.width/height` 是 `Length`（`string | number | Resource`）→ vp 数值。
   *
   * ★ 不能直接 `Number(area.width)`：`Length` 允许带单位的字符串（"402.00vp"），
   *   那样 `Number()` 得到 NaN，被调用方的 `Number.isNaN` 守卫挡掉之后，
   *   画面区尺寸就永远停在 0 —— 而它正是灵敏度换算的基准，也是差分路径
   *   **能否工作**的前置条件。静默为 0 的后果是"接管了却一步都送不出去"。
   */
  static length_to_vp(value: Length): number {
    if (typeof value === 'number') {
      return Number.isNaN(value) ? 0 : value;
    }
    if (typeof value === 'string') {
      const parsed: number = parseFloat(value);
      return Number.isNaN(parsed) ? 0 : parsed;
    }
    return 0;
  }

  /** ArkUI 的 MouseButton → 本工程/HID 的按键序号（0=左 1=右 2=中）。 */
  static button_index(button: MouseButton): number {
    if (button === MouseButton.Right) {
      return 1;
    }
    if (button === MouseButton.Middle) {
      return 2;
    }
    return 0;
  }

  /**
   * 鼠标：移动优先走 rawDelta，按下/抬起更新按键位。
   *
   * 移动那条不再用绝对坐标自己算差分：差分只在"本地光标看得见、且始终落在
   * 画面内"时才成立，而接管期间本地光标是藏起来的、还会滑出窗口 —— 一旦滑出
   * 就是事件断流，iPhone 光标卡住。rawDeltaX/Y 是鼠标硬件的原始相对位移，
   * 不经过屏幕坐标，没有这个问题。两个字段可选：设备不支持时由 onPointerEvent
   * 统一退回老路。
   */
  handle_mouse(event: MouseEvent): void {
    try {
      // ★ 去重：同一次物理事件可能被**两条承接路径**各收一次 —— 画面区那层透明
      //   承接层（负责 hover 与尺寸）与画面区**容器**（兜底，见两个窗口 build()
      //   里的说明）。重复转发会让 iPhone 侧位移与滚轮全部翻倍。
      //   指纹只取**与承接节点无关**的字段：时间戳 + 动作 + 按键 + 窗口坐标 +
      //   原始位移。绝不能放 `x/y` —— 那是"相对当前组件左上角"的坐标，同一次
      //   事件派给承接层与它的父容器时数值不同，指纹就对不上、去重会失效。
      //   也不能只按时间戳去重：高回报率鼠标在同一毫秒内可以产生多次真实移动，
      //   那些必须都放过去（补上窗口坐标与原始位移后，它们彼此仍能区分开）。
      const stamp: string = `${event.timestamp}|${event.action}|${event.button}|`
        + `${event.windowX}|${event.windowY}|${event.rawDeltaX}|${event.rawDeltaY}`;
      if (stamp === this.lastMouseStamp) {
        this.dedupDrops++;
        return;
      }
      this.lastMouseStamp = stamp;
      if (event.action === MouseAction.Move) {
        this.onPointerEvent(event.rawDeltaX, event.rawDeltaY, event.x, event.y);
      } else if (event.action === MouseAction.Press) {
        this.onPointerButton(ReverseControlInput.button_index(event.button), true);
      } else if (event.action === MouseAction.Release) {
        this.onPointerButton(ReverseControlInput.button_index(event.button), false);
      }
    } catch (error) {
      this.lastError = `处理鼠标事件异常：${(error as BusinessError).message}`;
    }
  }

  /** 滚轮：ArkUI 把滚轮归到轴事件（onAxisEvent），不是 onMouse。 */
  handle_axis(event: AxisEvent): void {
    try {
      // 滚轮不是幂等操作（重复一次就多滚一格），必须去重，理由同 handle_mouse。
      const value: number = event.getVerticalAxisValue();
      const stamp: string = `${event.timestamp}|${event.action}|${value}`;
      if (stamp === this.lastAxisStamp) {
        this.dedupDrops++;
        return;
      }
      this.lastAxisStamp = stamp;
      if (event.action === AxisAction.CANCEL) {
        return;
      }
      if (value !== 0) {
        this.onWheel(value);
      }
    } catch (error) {
      this.lastError = `处理滚轮事件异常：${(error as BusinessError).message}`;
    }
  }

  /** 键盘：鸿蒙 KeyCode → HID usage 的映射在本类的 usage_for 里。 */
  handle_key(event: KeyEvent): void {
    try {
      this.onKey(event.keyCode, event.type === KeyType.Down);
    } catch (error) {
      this.lastError = `处理键盘事件异常：${(error as BusinessError).message}`;
    }
  }

  /**
   * 登记某个来源的画面区尺寸（vp）。
   *
   * ★ 为什么要按来源分开记：surfaceW 是灵敏度的换算基准
   *   （gain = 源逻辑宽 / surfaceW）。主窗口与独立窗口的画面区大小通常不同，
   *   共用一个字段就会出现"在独立窗口里划得很正常、回主窗口就偏了"——
   *   因为写入顺序取决于哪个窗口最后改过尺寸，与用户此刻在哪个窗口无关。
   *   接管发生时再按当前悬停来源切换（见 apply_active_surface_size）。
   */
  setSurfaceSize(source: string, width: number, height: number): void {
    this.surfaceSizes.set(source, [width, height]);
    if (this.hoverSources.indexOf(source) >= 0) {
      this.apply_active_surface_size();
    }
  }

  /** 把换算基准切到"当前正在悬停的那个来源"的画面区尺寸。 */
  private apply_active_surface_size(): void {
    // 倒着找：后登记的悬停来源优先（鼠标刚移动到的那个更可能是用户当下在看的目标）。
    for (let i = this.hoverSources.length - 1; i >= 0; i--) {
      const source: string = this.hoverSources[i];
      if (this.pictureReady.get(source) !== true) {
        continue;
      }
      const size: number[] | undefined = this.surfaceSizes.get(source);
      if (size !== undefined && size[0] > 0 && size[1] > 0) {
        this.surfaceW = size[0];
        this.surfaceH = size[1];
      }
      return;
    }
  }

  /**
   * 登记某个来源此刻有没有可操控的画面（每轮调用）。
   *
   * 只登记，不返回接管态 —— 由随后的 refreshChannel() 统一重算，调用点不必操心
   * 时序。"有没有画面"与"指针在不在上面"是两件事，前者随时会变，见 pictureReady。
   */
  setPictureAvailable(source: string, ready: boolean): void {
    this.pictureReady.set(source, ready);
  }

  setSourceSize(width: number, height: number): void {
    this.sourceW = width;
    this.sourceH = height;
  }

  setSensitivity(percent: number): void {
    this.sensitivity = percent;
  }

  // 反控关闭 / 断开时复位：必须把按下的键与键帽都放掉，
  // 否则 iPhone 侧会留着"按住的鼠标键"和"一直按着某个键"。
  reset(): void {
    this.hasLast = false;
    this.remainderX = 0;
    this.remainderY = 0;
    this.buttonMask = 0;
    this.pressedUsages = [];
    this.modifiers = 0;
    BluetoothHidPeripheral.shared().releaseAll();
  }

  statusText(): string {
    if (!this.isEnabled()) {
      return '反控未启用';
    }
    if (this.sourceW === 0 || this.sourceH === 0) {
      return '反控已启用（等待画面尺寸）';
    }
    const scale = this.logicalScale();
    // 「是否正在接管」必须出现在状态里：这一项就是用户判断"鼠标放上去到底
    // 生效没有"的唯一凭据，藏起来就只能靠猜。
    const hold: string = this.takingOver ? '操控中' : '待机(鼠标移入画面即操控)';
    return `反控已启用 · ${hold} · 源 ${this.sourceW}×${this.sourceH} · 倍率 ${scale}x` +
      ` · 已送 ${this.moveEvents} 次移动`;
  }

  errorText(): string {
    return this.lastError;
  }

  /**
   * 一行可读的真实状态（独立窗口的条带上显示）。
   *
   * 为什么必须给独立窗口一个读数：那边没有主窗口的 500ms 轮询与状态行，
   * 而"指针藏了、却操控不了"这件事必须能**就地看着数字**判断卡在哪一段：
   *
   *   · `未启用`        → 通道没起来（蓝牙权限/广播）
   *   · `待机`          → 悬停没收成接管（没画面 / iPhone 没连上）
   *   · `接管中 … 无事件` → 接管判据通过了，但一个移动事件都没送到 —— 事件层的问题
   *   · `接管中 移N 原0`  → 事件到了，但原始位移恒为 0（本应自动改差分）
   *   · `接管中 移N 送X,Y`（X/Y 在变）→ **我们这一侧一切正常**，问题在手机那侧
   *     （最常见：iPhone 未开「辅助触控」⇒ iOS 根本不认外接鼠标的报告）
   */
  readoutText(): string {
    const hid = BluetoothHidPeripheral.shared();
    // ★ 无论处于什么状态都给一段可读的字 —— 绝不返回空串。
    //   独立窗口的条带是**唯一**能就地看见反控真值的地方（主窗口那条详细状态行
    //   在独立窗口里根本看不到），返回空串等于把唯一的观测口关掉：
    //   "什么都没显示"与"通道没起来"在用户眼里完全一样（2026-09-22 现场）。
    //   前两段是**外设真值**（布局 / 广播 / 连接）—— 用户凭这三个字就能回答
    //   "到底有没有连上"，不需要猜。
    // ★ 外设真值里**必须**带上"主机读了几次、订阅了没有"（2026-09-24 加）：
    //   `广1连1` 只说明链路通了，不说明 iOS 认了这个 HID 设备。真正分水岭是
    //   `读N`（主机来枚举了）与 `订S`（主机订阅了 Report 特征）：
    //     `广1连1 读0`   ⇒ 主机连上了却什么都没读：问题在配对/加密/广播内容
    //     `读3 订0`      ⇒ 主机读到了 Report Map 却不订阅：问题在描述符/加密
    //     `订1` 之后      ⇒ 才轮到"报表投递到哪一段"这类问题
    const hidDiag = hid.diag();
    const alive: string = `${hid.isAdvertising() ? '广1' : '广0'}${hid.isConnected() ? '连1' : '连0'}`
      + ` 读${hidDiag.hostReads} 订${hidDiag.subscribed}`;
    if (!this.isEnabled() && this.takeovers === 0) {
      // 这条路**从来没被用过**（没接管过、也没在广播）⇒ 返回空串，不占条带位置。
      // 一旦用过，哪怕后来被停掉也要继续显示 —— "未启用"本身就是用户要知道的事实。
      return '';
    }
    if (!this.isEnabled()) {
      return `未启用 ${hid.layoutText()} ${alive}`;
    }
    if (!this.takingOver) {
      // 广播中但没接管：广1连0 ⇒ iPhone 还没连上（去手机上配对）；
      // 广1连1 却待机 ⇒ 指针不在画面上，或这个窗口没有可操控的画面。
      return `待机 ${hid.layoutText()} ${alive}`;
    }
    // 四段账各自独立，缺哪一段就指向哪一段的问题：
    //   移 = 承接层收到的移动事件数（0 ⇒ 事件层断了）
    //   原 = 走原始位移通道的事件数（且 rawUsable 为 false 时会标"改差分"）
    //   送 = 最近一次真正发给外设的相对位移（在变 ⇒ 我们这侧全正常）
    //   鼠 = notify 成功的鼠标报表数（在涨而手机不动 ⇒ 问题在接收侧/协议）
    let text: string = `接管 移${this.moveEvents} 原${this.rawEvents}`
      + ` 送${this.sentX},${this.sentY} 鼠${hid.diag().mouseReports}`;
    if (!this.rawUsable) {
      text += ' 改差分';
    }
    if (this.moveEvents === 0) {
      text += ' 无事件';
    } else if (this.inImageEvents === 0 && this.sizeMissingDrops > 0) {
      text += ` 缺尺寸${this.sizeMissingDrops}`;
    }
    if (this.dedupDrops > 0) {
      text += ` 去重${this.dedupDrops}`;
    }
    if (!this.keyboardFocus) {
      // 键盘与鼠标是两条路：鼠标能动而这里显示"无焦点"⇒ 键盘会静默哑掉。
      text += ' 无焦点';
    }
    return text;
  }

  diag(): ReverseControlDiag {
    const result: ReverseControlDiag = {
      enabled: this.isEnabled() ? 1 : 0,
      takeover: this.takingOver ? 1 : 0,
      takeovers: this.takeovers,
      hoverCount: this.hoverSources.length,
      rawEvents: this.rawEvents,
      rawDx: this.rawDx,
      rawDy: this.rawDy,
      rawFallbacks: this.rawFallbacks,
      rawUsable: this.rawUsable ? 1 : 0,
      rawZeroStreak: this.rawZeroStreak,
      absMoveEvents: this.absMoveEvents,
      sizeMissingDrops: this.sizeMissingDrops,
      dedupDrops: this.dedupDrops,
      rawNote: this.rawNote,
      surfaceW: this.surfaceW,
      surfaceH: this.surfaceH,
      sourceW: this.sourceW,
      sourceH: this.sourceH,
      scale: this.logicalScale(),
      sensitivity: this.sensitivity,
      moveEvents: this.moveEvents,
      inImageEvents: this.inImageEvents,
      blackBarDrops: this.blackBarDrops,
      sentX: this.sentX,
      sentY: this.sentY,
      wheelSteps: this.wheelSteps,
      buttonMask: this.buttonMask,
      keyDown: this.keyDown,
      keyUp: this.keyUp,
      unmappedKeys: this.unmappedKeys,
      lastKeyCode: this.lastKeyCode,
      kbdFocus: this.keyboardFocus ? 1 : 0,
      lastError: this.lastError
    };
    return result;
  }

  // 逻辑像素倍率：上游判据 min(源宽,源高) >= 1400 → 2x，否则 3x
  private logicalScale(): number {
    if (this.sourceW === 0 || this.sourceH === 0) {
      return 3;
    }
    const shorter = this.sourceW < this.sourceH ? this.sourceW : this.sourceH;
    return shorter >= 1400 ? 2 : 3;
  }

  // ── ① 坐标换算（letterbox） ──────────────────────────────────────────────
  // 与上游 MainWindow.xaml.cs:623-647 的 MapPointerToNormalized 同一套算法：
  // 先按"源宽高比"在预览区里算出真正的画面矩形，落在矩形外（黑边）返回 null。
  private normalize(x: number, y: number): NormalizedPoint | null {
    if (this.surfaceW <= 0 || this.surfaceH <= 0 || this.sourceW <= 0 || this.sourceH <= 0) {
      return null;
    }
    const sourceAspect = this.sourceW / this.sourceH;
    const surfaceAspect = this.surfaceW / this.surfaceH;
    let imageX = 0;
    let imageY = 0;
    let imageWidth = this.surfaceW;
    let imageHeight = this.surfaceH;
    if (surfaceAspect > sourceAspect) {
      // 左右黑边
      imageWidth = this.surfaceH * sourceAspect;
      imageX = (this.surfaceW - imageWidth) / 2;
    } else if (surfaceAspect < sourceAspect) {
      // 上下黑边
      imageHeight = this.surfaceW / sourceAspect;
      imageY = (this.surfaceH - imageHeight) / 2;
    }
    if (x < imageX || x >= imageX + imageWidth || y < imageY || y >= imageY + imageHeight) {
      return null;
    }
    let nx = (x - imageX) / imageWidth;
    let ny = (y - imageY) / imageHeight;
    nx = nx < 0 ? 0 : (nx > 1 ? 1 : nx);
    ny = ny < 0 ? 0 : (ny > 1 ? 1 : ny);
    return { nx: nx, ny: ny };
  }

  /**
   * 指针移动的统一入口：优先 rawDelta，取不到（或判定不可用）才退回绝对坐标差分。
   *
   * 把"这台设备到底有没有可用的原始位移"这个判断收在这里，只写一次 ——
   * 主窗口与独立窗口两个调用点都不必各自去记这条规矩。降级次数单独记账，
   * 这样诊断里能一眼看出"是不是整条链路都在走那条有缺陷的老路"。
   */
  onPointerEvent(rawDx: number | undefined, rawDy: number | undefined,
    x: number, y: number): void {
    // 绝对坐标有没有在动 —— 这是"原始计数为 0"的唯一对照量：
    // 鼠标真的没动和"设备不报原始计数"在 rawDelta 上长得一模一样。
    const absMoved: boolean = !this.hasAbs
      || Math.abs(x - this.lastAbsX) > 0.5 || Math.abs(y - this.lastAbsY) > 0.5;
    this.hasAbs = true;
    this.lastAbsX = x;
    this.lastAbsY = y;
    if (absMoved) {
      this.absMoveEvents++;
    }

    // ★★ 两个 `!== undefined` 必须**直接写在这个 if 里**。
    //    ArkTS 编译器**不做**「通过布尔变量别名收窄类型」的推断（tsc 会）——
    //    写成 `const present = rawDx !== undefined && ...; if (present) { this.onRawDelta(rawDx, rawDy) }`
    //    在 DevEco 真构建里报：
    //      10605999 Argument of type 'number | undefined' is not assignable to
    //      parameter of type 'number'.  At ...ReverseControlInput.ets:710:23
    //    本例就是 2026-09-22 真机构建翻车的那一处。本工程的类型自检脚本走 tsc，
    //    **会放过**这种写法 ⇒「自检 0 错误」不等于「能编过」。改完请另跑
    //    `python3 tools/check_alias_narrowing.py .`（专门补这个盲区）。
    if (rawDx !== undefined && rawDy !== undefined && this.rawUsable) {
      // 三态里的第三态：字段在、值恒 0。只统计"raw 为 0 而绝对坐标在动"的次数，
      // 攒够 RAW_ZERO_STREAK_LIMIT 次就判定本机不提供原始位移，改走差分。
      if (rawDx === 0 && rawDy === 0) {
        if (absMoved) {
          this.rawZeroStreak++;
        }
        if (this.rawZeroStreak >= RAW_ZERO_STREAK_LIMIT) {
          this.rawUsable = false;
          this.rawNote = `原始位移连续 ${this.rawZeroStreak} 次为 0（同时绝对坐标在动）`
            + `⇒ 判定本机不提供 rawDelta，已改用绝对坐标差分`;
        }
      } else {
        this.rawZeroStreak = 0;
      }
      this.onRawDelta(rawDx, rawDy);
      return;
    }
    if (this.takingOver) {
      this.rawFallbacks++;
    }
    this.onPointerMove(x, y);
  }

  // ── ②-b 指针移动（首选路径）：直接用硬件原始相对位移 ─────────────────────
  //
  // 为什么这条路才是对的：iOS 的蓝牙鼠标只接受**相对量**，它那侧光标的位置是
  // 这些相对量自己累加出来的，与本地光标在屏幕上的绝对位置毫无关系。此前用
  // "本地绝对坐标做差分再发"，等于拿一个只有本地才知道的坐标系去驱动另一台
  // 设备：本地光标一旦被窗口边缘挡住（差分变 0）或跑出窗口（事件断流），
  // iPhone 光标就跟着卡住；来回跨一次窗口，两侧位置就再也对不上。
  //
  // MouseEvent.rawDeltaX/Y（@since 15）给的是鼠标硬件的原始计数，不经过屏幕
  // 坐标，因此不受窗口边界与光标钳位影响 —— 与上游 Windows 版用 Raw Input
  // （RIDEV_NOLEGACY）取相对位移是同一条思路，也是"鼠标放上去就能操控"里
  // 那个"能"字的物理基础。
  onRawDelta(dx: number, dy: number): void {
    if (!this.takingOver) {
      return;
    }
    this.moveEvents++;
    this.rawEvents++;
    this.rawDx = dx;
    this.rawDy = dy;
    const gain = this.rawGain();
    this.emit_relative(dx * gain, dy * gain);
  }

  /**
   * 原始计数 → iPhone 逻辑点的换算系数。
   *
   * 口径（可验证、可校准，不是拍的）：**鼠标在画面上横划过一个画面宽度 ⇒
   * iPhone 侧光标走满一整屏**，即 gain = 源逻辑宽 / 预览区宽。
   * 这样"画面被缩放到多小"被自动抵消 —— 窗口拉大拉小，手感一致。
   * 剩下"硬件计数 vs 屏幕像素"的差异（不同鼠标 DPI 不同）由灵敏度百分比兜底，
   * 那个值上游也是留给用户调的（PointerSensitivity）。
   */
  private rawGain(): number {
    if (this.surfaceW <= 0 || this.sourceW <= 0) {
      return this.sensitivity / 100;
    }
    const logicalWidth = this.sourceW / this.logicalScale();
    return (logicalWidth / this.surfaceW) * (this.sensitivity / 100);
  }

  /**
   * 把一段相对位移发给 iPhone。
   *
   * HID 鼠标 report 里的 dx/dy 是**8 位有符号**，一份最多 ±127。高速划动时
   * 原始计数轻易超出这个范围，所以这里拆成多份发而**不是截断** —— 截断的手感
   * 就是"甩一下鼠标，iPhone 光标只挪了一点点"。小数部分进余数累积，否则慢速
   * 微调会被反复归零、永远发不出去（上游 685-706 行同款做法）。
   */
  private emit_relative(dx: number, dy: number): void {
    const accX = dx + this.remainderX;
    const accY = dy + this.remainderY;
    let intX = accX > 0 ? Math.floor(accX) : Math.ceil(accX);
    let intY = accY > 0 ? Math.floor(accY) : Math.ceil(accY);
    this.remainderX = accX - intX;
    this.remainderY = accY - intY;
    if (intX === 0 && intY === 0) {
      return;
    }
    // 单次事件最多拆 8 份（8×127 ≈ 1000 计数），足够覆盖最猛的一甩；
    // 仍未发完的余额留到下次继续，宁可有半帧延迟，也不丢位移。
    let emitted = 0;
    while ((intX !== 0 || intY !== 0) && emitted < 8) {
      const stepX = intX > 127 ? 127 : (intX < -127 ? -127 : intX);
      const stepY = intY > 127 ? 127 : (intY < -127 ? -127 : intY);
      intX -= stepX;
      intY -= stepY;
      emitted++;
      this.sentX = stepX;
      this.sentY = stepY;
      BluetoothHidPeripheral.shared().sendMouse(this.buttonMask, stepX, stepY, 0);
    }
    this.remainderX += intX;
    this.remainderY += intY;
  }

  // ── ②-a 指针移动（降级路径）：本地绝对坐标差分 ──────────────────────────
  // 只在 rawDelta 取不到时启用（该字段可选，设备/系统不支持时为 undefined）。
  // 保留是因为"降级总比完全没有好"，但它的固有缺陷见 onRawDelta 的注释：
  // 边缘卡住、跨窗口错位、黑边附近跳变。
  onPointerMove(x: number, y: number): void {
    if (!this.takingOver) {
      return;
    }
    this.moveEvents++;
    // 缺尺寸与落在黑边是两件事，必须分开记：前者是"我们的换算基准没就绪"（可修），
    // 后者是"指针确实在画面外"（正常）。混成一个计数就会把"基准缺失导致一步都
    // 送不出去"看成"用户老在画面外点"。
    if (this.surfaceW <= 0 || this.surfaceH <= 0 || this.sourceW <= 0 || this.sourceH <= 0) {
      this.sizeMissingDrops++;
      this.hasLast = false;
      return;
    }
    const point = this.normalize(x, y);
    if (point === null) {
      this.blackBarDrops++;
      // 离开画面时忘掉基准点，避免再进来时产生一整屏的跳变
      this.hasLast = false;
      return;
    }
    this.inImageEvents++;
    if (!this.hasLast) {
      this.lastNx = point.nx;
      this.lastNy = point.ny;
      this.hasLast = true;
      return;
    }

    const scale = this.logicalScale();
    // 归一化位移 × 逻辑宽度 × 灵敏度系数 = HID 相对位移
    const logicalWidth = this.sourceW / scale;
    const logicalHeight = this.sourceH / scale;
    const gain = this.sensitivity / 100;
    const dx = (point.nx - this.lastNx) * logicalWidth * gain;
    const dy = (point.ny - this.lastNy) * logicalHeight * gain;
    this.lastNx = point.nx;
    this.lastNy = point.ny;
    this.emit_relative(dx, dy);
  }

  // ── 鼠标按键 ──────────────────────────────────────────────────────────────
  // button: 0=左 1=右 2=中（ArkUI MouseButton 枚举顺序）
  // 判据是 takingOver 而不是 enabled：接管才转发。否则用户在电脑上正常点击
  // （窗口其它部位）也会在 iPhone 上点一下 —— 那是会误操作的状态。
  onPointerButton(button: number, down: boolean): void {
    if (!this.takingOver) {
      return;
    }
    let bit = BTN_LEFT;
    if (button === 1) {
      bit = BTN_RIGHT;
    } else if (button === 2) {
      bit = BTN_MIDDLE;
    }
    if (down) {
      this.buttonMask = this.buttonMask | bit;
    } else {
      this.buttonMask = this.buttonMask & (~bit);
    }
    BluetoothHidPeripheral.shared().sendMouse(this.buttonMask, 0, 0, 0);
  }

  // ── 滚轮 ──────────────────────────────────────────────────────────────────
  // 上游鼠标 report 的滚轮字段是 8 位有符号，1 单位 ≈ 一行。
  onWheel(axisValue: number): void {
    if (!this.takingOver) {
      return;
    }
    const steps = Math.round(axisValue * WHEEL_STEP_SCALE);
    if (steps === 0) {
      return;
    }
    const clamped = steps > 127 ? 127 : (steps < -127 ? -127 : steps);
    this.wheelSteps += clamped;
    BluetoothHidPeripheral.shared().sendMouse(this.buttonMask, 0, 0, clamped);
  }

  // ── 键盘 ──────────────────────────────────────────────────────────────────
  onKey(keyCode: number, down: boolean): void {
    if (!this.takingOver) {
      return;
    }
    this.lastKeyCode = keyCode;
    const modifierBit = this.modifier_bit(keyCode);
    if (modifierBit !== 0) {
      if (down) {
        this.modifiers = this.modifiers | modifierBit;
      } else {
        this.modifiers = this.modifiers & (~modifierBit);
      }
      this.count_key(down);
      this.flush_keyboard();
      return;
    }
    const usage = this.usage_for(keyCode);
    if (usage === HID_KEY_NONE) {
      if (down) {
        this.unmappedKeys++;
      }
      return;
    }
    if (down) {
      if (!this.pressedUsages.includes(usage)) {
        if (this.pressedUsages.length >= 6) {
          // Report Map 里只有 6 个 usage 槽位，第 7 个键只能丢掉并记下来
          this.unmappedKeys++;
          return;
        }
        this.pressedUsages.push(usage);
      }
    } else {
      this.pressedUsages = this.pressedUsages.filter((item: number): boolean => item !== usage);
    }
    this.count_key(down);
    this.flush_keyboard();
  }

  private count_key(down: boolean): void {
    if (down) {
      this.keyDown++;
    } else {
      this.keyUp++;
    }
  }

  private flush_keyboard(): void {
    BluetoothHidPeripheral.shared().sendKeyboard(this.modifiers, this.pressedUsages);
  }

  private modifier_bit(keyCode: number): number {
    if (keyCode === HK_CTRL_LEFT) {
      return MOD_LCTRL;
    }
    if (keyCode === HK_SHIFT_LEFT) {
      return MOD_LSHIFT;
    }
    if (keyCode === HK_ALT_LEFT) {
      return MOD_LALT;
    }
    if (keyCode === HK_META_LEFT) {
      return MOD_LGUI;
    }
    if (keyCode === HK_CTRL_RIGHT) {
      return MOD_RCTRL;
    }
    if (keyCode === HK_SHIFT_RIGHT) {
      return MOD_RSHIFT;
    }
    if (keyCode === HK_ALT_RIGHT) {
      return MOD_RALT;
    }
    if (keyCode === HK_META_RIGHT) {
      return MOD_RGUI;
    }
    return 0;
  }

  // 鸿蒙 KeyCode → HID Keyboard/Keypad usage
  private usage_for(keyCode: number): number {
    if (keyCode >= HK_A && keyCode <= HK_Z) {
      return HID_KEY_A + (keyCode - HK_A);
    }
    if (keyCode >= HK_0 && keyCode <= HK_9) {
      // 数字键在 HID 里是 1..9 在前、0 在最后，顺序与鸿蒙的 0..9 不同
      if (keyCode === HK_0) {
        return HID_KEY_0;
      }
      return HID_KEY_1 + (keyCode - HK_0 - 1);
    }
    if (keyCode >= HK_F1 && keyCode <= HK_F1 + 11) {
      return HID_KEY_F1 + (keyCode - HK_F1);
    }
    if (keyCode === HK_ENTER) {
      return HID_KEY_ENTER;
    }
    if (keyCode === HK_ESCAPE) {
      return HID_KEY_ESCAPE;
    }
    if (keyCode === HK_DEL) {
      return HID_KEY_BACKSPACE;
    }
    if (keyCode === HK_TAB) {
      return HID_KEY_TAB;
    }
    if (keyCode === HK_SPACE) {
      return HID_KEY_SPACE;
    }
    if (keyCode === HK_MINUS) {
      return HID_KEY_MINUS;
    }
    if (keyCode === HK_EQUALS) {
      return HID_KEY_EQUAL;
    }
    if (keyCode === HK_LEFT_BRACKET) {
      return HID_KEY_LEFTBRACE;
    }
    if (keyCode === HK_RIGHT_BRACKET) {
      return HID_KEY_RIGHTBRACE;
    }
    if (keyCode === HK_BACKSLASH) {
      return HID_KEY_BACKSLASH;
    }
    if (keyCode === HK_SEMICOLON) {
      return HID_KEY_SEMICOLON;
    }
    if (keyCode === HK_APOSTROPHE) {
      return HID_KEY_APOSTROPHE;
    }
    if (keyCode === HK_GRAVE) {
      return HID_KEY_GRAVE;
    }
    if (keyCode === HK_COMMA) {
      return HID_KEY_COMMA;
    }
    if (keyCode === HK_PERIOD) {
      return HID_KEY_DOT;
    }
    if (keyCode === HK_SLASH) {
      return HID_KEY_SLASH;
    }
    if (keyCode === HK_CAPS_LOCK) {
      return HID_KEY_CAPSLOCK;
    }
    if (keyCode === HK_INSERT) {
      return HID_KEY_INSERT;
    }
    if (keyCode === HK_PAGE_UP) {
      return HID_KEY_PAGEUP;
    }
    if (keyCode === HK_FORWARD_DEL) {
      return HID_KEY_DELETE;
    }
    if (keyCode === HK_MOVE_END) {
      return HID_KEY_END;
    }
    if (keyCode === HK_PAGE_DOWN) {
      return HID_KEY_PAGEDOWN;
    }
    if (keyCode === HK_DPAD_RIGHT) {
      return HID_KEY_RIGHT;
    }
    if (keyCode === HK_DPAD_LEFT) {
      return HID_KEY_LEFT;
    }
    if (keyCode === HK_DPAD_DOWN) {
      return HID_KEY_DOWN;
    }
    if (keyCode === HK_DPAD_UP) {
      return HID_KEY_UP;
    }
    return HID_KEY_NONE;
  }
}
