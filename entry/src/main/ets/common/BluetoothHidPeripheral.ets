import { ble, constant, connection } from '@kit.ConnectivityKit';
import { abilityAccessCtrl, bundleManager, PermissionRequestResult, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import deviceInfo from '@ohos.deviceInfo';

// ─────────────────────────────────────────────────────────────────────────────
//  Bluetooth HID 反控外设（HOGP over BLE）
//
//  上游 Windows 版用 WinRT 的 GattServiceProvider 把本机蓝牙暴露成一个标准的
//  BLE HID 鼠标/键盘（src/App/Services/BluetoothHidMouseService.cs，1605 行）。
//  iPhone 端在「设置 → 辅助触控 → 指针设备」里把它当蓝牙鼠标认下来，于是电脑
//  的鼠标与键盘就能操作 iPhone。
//
//  鸿蒙没有 WinRT，等价物是 @ohos.bluetooth.ble 的 GattServer + 广播：
//      requestPermissionsFromUser(ACCESS_BLUETOOTH)   ← ★ 必须先做，见下
//      → ble.createGattServer() → addService(HID 服务) → ble.startAdvertising()
//      → iPhone 连接 → iOS 订阅 Report 特征 → 我们 notifyCharacteristicChanged()
//
//  ★ 那条权限申请**不是可选项**：`GattServer.addService()` 的 @permission 是
//    ohos.permission.ACCESS_BLUETOOTH，而它的 grantMode 是 **user_grant** ——
//    module.json5 里声明只给了"申请资格"，不调 requestPermissionsFromUser 就永远
//    没有授权，addService 会直接回 `201 BusinessError 201: Permission denied`。
//    （2026-09-20 踩过：界面上原样显示的就是这句 201。）
//
//  ── 三个必须记住的协议事实 ───────────────────────────────────────────────
//
//  1. **报告数据带不带 Report ID，取决于布局模式**（见下面的「HID 布局模式」）：
//     · SINGLE（默认，单 Report 特征）：载荷**首字节是 report id** ——
//         鼠标 [0x02, buttons, x_lo, x_hi, y_lo, y_hi, wheel]（7 字节）
//         键盘 [0x01, modifiers, reserved, usage×6]（9 字节）
//     · MULTI（5 个 Report 特征，抄上游）：载荷**不带** id，就是纯 report 内容 ——
//         鼠标 6 字节、键盘 8 字节。这一路与上游逐字节一致
//         （BluetoothHidMouseService.cs:300-303 / :553-556）。
//
//  2. **★ 鸿蒙发通知只能按 UUID 定位特征，没有别的抓手**。`NotifyCharacteristic`
//     只有 serviceUuid / characteristicUuid / characteristicValue / confirm
//     （离线 SDK 的 @ohos.bluetooth.ble.d.ts 里就这四个字段），**没有描述符、
//     没有特征句柄**。而 HOGP 的标准布局恰恰是"每个 report id 一个 Report 特征、
//     共用 UUID 0x2A4D"。⇒ 五个同 UUID 的特征摆在那里，通知落到哪一个由协议栈
//     决定，调用方**无法指定**。这是 2026-09-22 定位到的结构性成因：报文被送到
//     8 字节的键盘特征（或只读的 feature 特征）上，iOS 按那个特征的 report id 去
//     解析 6 字节的鼠标位移，只能整帧丢弃 —— 现象正是"指针藏了、iPhone 一动不动"。
//
//  3. **iOS 只吃相对位移**（蓝牙鼠标）—— 所以鼠标路径送的是 dx/dy 而不是绝对
//     坐标；绝对方位由 Index.ets 侧算好后差分成位移再送进来。
//
//  ── 能力边界（照抄上游，不要含糊） ────────────────────────────────────────
//  蓝牙这条通道**只能做单指指针 + 键盘 + 少量媒体/导航键**，不能注入多指触控，
//  也不能玩需要真触摸的游戏；且必须先由用户在 iPhone 上打开「辅助触控」。
//  上游 README 与 USER_GUIDE 都是这么写的。
// ─────────────────────────────────────────────────────────────────────────────

const HID_SERVICE_UUID = '00001812-0000-1000-8000-00805F9B34FB';
const UUID_HID_INFORMATION = '00002A4A-0000-1000-8000-00805F9B34FB';
const UUID_REPORT_MAP = '00002A4B-0000-1000-8000-00805F9B34FB';
const UUID_HID_CONTROL_POINT = '00002A4C-0000-1000-8000-00805F9B34FB';
const UUID_REPORT = '00002A4D-0000-1000-8000-00805F9B34FB';
const UUID_PROTOCOL_MODE = '00002A4E-0000-1000-8000-00805F9B34FB';
const UUID_REPORT_REFERENCE = '00002908-0000-1000-8000-00805F9B34FB';
// CCCD：主机写完它才算"订阅了这个特征"。iOS 只有在订阅之后才可能收到 Report。
const UUID_CCCD = '00002902-0000-1000-8000-00805F9B34FB';

// Report ID（与上游 BluetoothHidMouseService.cs 的 Report Map 声明一一对应）
export const REPORT_ID_KEYBOARD = 1;
export const REPORT_ID_MOUSE = 2;
export const REPORT_ID_WHEEL_RESOLUTION = 3;
export const REPORT_ID_CONSUMER = 4;
export const REPORT_ID_NAVIGATION = 5;

// Report Reference 描述符的 report type
const REPORT_TYPE_INPUT = 1;
const REPORT_TYPE_FEATURE = 3;

// ── HID 布局模式（★ 2026-09-22 新增，用来绕开上面第 2 条那个接口缺口）─────────
//
//   SINGLE（1）：只建**一个** Report 特征，Report Reference 的 Report ID = 0
//     （HID Service 规范 2.5.3.2 只要求"同一 Report 类型存在多个实例时 Report ID
//      必须非零"；只有一个实例时允许为 0），所有 report 共用它，**载荷首字节带
//      report id**。同 UUID 的 Report 特征只有一个 ⇒ 投递没有歧义。
//     这正是 Android 手机当蓝牙键鼠外设时用的那套布局，iOS / Windows 都认。
//   MULTI（0）：照抄上游 Windows 的 5 特征布局（Report ID 1/2/3/4/5，载荷不带 id）。
//     Windows 能工作是因为它的栈按**特征对象**投递；鸿蒙这条走不通（见上），
//     保留它只作对照 —— 切换一次就能证明"到底是布局问题还是别的问题"。
export const HID_LAYOUT_MULTI = 0;
export const HID_LAYOUT_SINGLE = 1;
// 默认走 SINGLE：MULTI 在鸿蒙上已被确认为结构性不可用（投递落点不可控）。
const DEFAULT_HID_LAYOUT = HID_LAYOUT_SINGLE;

// 注册完应当有的特征数：HID Information + Report Map + Control Point +
// Protocol Mode + Report×N。N 由布局决定（SINGLE = 1 ⇒ 共 5；MULTI = 5 ⇒ 共 9）。
// 用它判"少注册了"—— 少一个就意味着某个 report 发不出去。
const EXPECTED_CHARS_SINGLE = 5;
const EXPECTED_CHARS_MULTI = 9;

// 2901008 = "Gatt service is not found"，@ohos.bluetooth.ble 的 GattServer.getService
// 在服务不存在时抛这个码。
//
// ★ 2026-09-21 修正：它**不足以单独定论**。理由有两条 ——
//   ① `getService(uuid)` 的 UUID 匹配口径由栈决定，而我们用长格式注册，栈可能把它
//      规范化成短格式/小写 ⇒ 精确匹配假阴性，看起来和"没注册"一模一样；
//   ② `addService()` 是**跨进程**调用，返回时机不等于"服务已可查询" ⇒ 紧接着回读
//      会踩竞态。
//   所以它只作为文字记录（写进 error 供界面显示），最终结论必须由
//   `getService` + `getServices` 两条路交叉印证后得出，并带沉降重试。
const ERR_GATT_SERVICE_NOT_FOUND = 2901008;

// 注册后回读的"沉降"参数（2026-09-21 加；配合上面的 ②）。
//   5 次 × 120ms ≈ 最长 480ms。一旦读到就立刻返回 ⇒ **成功路径零额外等待**，
//   只有"探针能用但读不到服务"这种可疑情形才付出等待。
const READBACK_SETTLE_ATTEMPTS = 5;
const READBACK_SETTLE_DELAY_MS = 120;

// 配对真值的探测节奏：UI 每 500ms 轮询一次，而 `connection.getPairedDevices()`
// 是跨进程调用 ⇒ 每 20 拍（≈10s）探一次就够，不必每拍都问。
const BOND_PROBE_INTERVAL_TICKS = 20;

// HID Information：bcdHID=0x0111、bCountryCode=0x00、Flags=0x03（RemoteWake + NormallyConnectable）
// 见上游 BluetoothHidMouseService.cs:30
const HID_INFORMATION: number[] = [0x11, 0x01, 0x00, 0x03];
// Protocol Mode：1 = Report Protocol（0 = Boot Protocol）
// 见上游 BluetoothHidMouseService.cs:31
const PROTOCOL_MODE_REPORT = 1;
const PROTOCOL_MODE_BOOT = 0;

/**
 * BLE 外设（GattServer + startAdvertising）唯一需要的权限。
 *
 * ★ 级别与**授权方式**必须分开看（SDK 的 PermissionDefinitions.json 是唯一权威）：
 *     availableLevel : normal     → 普通应用可申请，不需要签名 profile 的 ACL
 *     grantMode      : user_grant → **必须在运行时弹窗征得用户同意**
 *   只读到 availableLevel 就断定"声明即授权"，正是本模块此前 addService 报
 *   `201 BusinessError 201: Permission denied` 的原因：module.json5 里写了，
 *   但从来没有调用过 requestPermissionsFromUser。
 */
const BLUETOOTH_PERMISSION: Permissions = 'ohos.permission.ACCESS_BLUETOOTH';

// ── HID Report Map（175 字节） ───────────────────────────────────────────────
// 逐字节抄自上游 src/App/Services/BluetoothHidMouseService.cs:39-67，未做任何改动。
// 结构（按 HID 规范解析，用于核对，改任何一个字节前请重新核一遍）：
//   Report 1 键盘     : 8 个修饰键位 + 1 字节保留 + 6 字节 usage 数组 → 载荷 8 字节
//   Report 2 鼠标     : 5 个按键位 + 3 位填充 + X/Y 各 16 位相对 + 滚轮 8 位 → 载荷 6 字节
//   Report 3 滚轮分辨率: Feature，8 位（嵌套在鼠标的 Physical collection 内，故有两层 C0）
//   Report 4 Consumer : 16 位 usage（媒体键）
//   Report 5 Navigation: 13 个 1 位 usage + 3 位填充 → 2 字节
const HID_REPORT_MAP: number[] = [
  0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x85, 0x01, 0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25,
  0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x75, 0x08, 0x95, 0x01, 0x81, 0x01, 0x75, 0x08, 0x95, 0x06,
  0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00, 0xC0,
  0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x85, 0x02, 0x09, 0x01, 0xA1, 0x00, 0x05, 0x09, 0x19, 0x01, 0x29,
  0x05, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x05, 0x81, 0x02, 0x75, 0x03, 0x95, 0x01, 0x81, 0x01,
  0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x16, 0x01, 0x80, 0x26, 0xFF, 0x7F, 0x75, 0x10, 0x95, 0x02, 0x81,
  0x06, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06, 0x85, 0x03, 0x09, 0x48,
  0x15, 0x00, 0x25, 0x0A, 0x75, 0x08, 0x95, 0x01, 0xB1, 0x02, 0xC0, 0xC0,
  0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x04, 0x15, 0x00, 0x26, 0xFF, 0x03, 0x75, 0x10, 0x95, 0x01,
  0x0A, 0x9D, 0x02, 0x81, 0x02, 0xC0,
  0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x05, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x0D, 0x0A,
  0x24, 0x02, 0x09, 0x40, 0x0A, 0x23, 0x02, 0x0A, 0xAE, 0x01, 0x0A, 0x21, 0x02, 0x81, 0x02, 0x95, 0x03,
  0x75, 0x01, 0x81, 0x03, 0xC0
];

// 上游的超时口径：鼠标 80ms（宁丢勿延迟），键盘 2s
// 见 BluetoothHidMouseService.cs:32-36
const MOUSE_NOTIFY_TIMEOUT_MS = 80;
const KEYBOARD_NOTIFY_TIMEOUT_MS = 2000;
// 看门狗：一次通知迟迟不回来就复位在途标志，否则鼠标会被永久卡死
const NOTIFY_WATCHDOG_MS = 500;

// 鼠标按键位（HID Button page，1..5）
export const MOUSE_BUTTON_LEFT = 0x01;
export const MOUSE_BUTTON_RIGHT = 0x02;
export const MOUSE_BUTTON_MIDDLE = 0x04;

// 键盘修饰键位（HID Keyboard/Keypad page 0xE0..0xE7）
export const MOD_LEFT_CTRL = 0x01;
export const MOD_LEFT_SHIFT = 0x02;
export const MOD_LEFT_ALT = 0x04;
export const MOD_LEFT_GUI = 0x08;
export const MOD_RIGHT_CTRL = 0x10;
export const MOD_RIGHT_SHIFT = 0x20;
export const MOD_RIGHT_ALT = 0x40;
export const MOD_RIGHT_GUI = 0x80;

// Consumer usage（媒体/系统键）—— 值取自 HID Usage Tables (Consumer page)
export const CONSUMER_HOME = 0x0223;
export const CONSUMER_BACK = 0x0224;
export const CONSUMER_SEARCH = 0x0221;
export const CONSUMER_PLAY_PAUSE = 0x00CD;
export const CONSUMER_NEXT_TRACK = 0x00B5;
export const CONSUMER_PREV_TRACK = 0x00B4;
export const CONSUMER_VOLUME_INC = 0x00E9;
export const CONSUMER_VOLUME_DEC = 0x00EA;
export const CONSUMER_MUTE = 0x00E2;
export const CONSUMER_POWER = 0x0030;

// Navigation report 的位（Report Map 里 13 个 1 位字段按顺序排列）
export const NAV_BACK = 0x0001;
export const NAV_MENU = 0x0002;
export const NAV_HOME = 0x0004;
export const NAV_HOME_ALT = 0x0008;
export const NAV_SEARCH = 0x0010;

// ── 诊断快照（UI 必须显示）：反控"没反应"时唯一能定位的出口 ───────────────────
export interface BluetoothHidDiag {
  available: number;          // 1 = 本 SDK 提供了 ble API（编译期有，运行期也可能 801）
  started: number;            // 1 = 服务已注册 + 广播已开
  advertising: number;        // 1 = 广播中
  serviceChars: number;       // addService 后回读到的特征数（SINGLE 应为 5、MULTI 应为 9）
  // ── 布局模式（★ 2026-09-22 加）─────────────────────────────────────────────
  // 为什么要把布局也做成可读、可切换：鸿蒙发通知只能给 `(serviceUuid,
  // characteristicUuid)`，而 HOGP 的标准布局是 5 个共用 0x2A4D 的 Report 特征 ⇒
  // 通知落到哪一个不可控。「单特征 + 载荷带 report id」是唯一能让投递确定的布局。
  // 保留这两个模式并把它显示出来，是为了让"到底是布局问题还是别的问题"
  // 能靠**一次切换**直接判定，而不是继续猜。
  layout: number;             // 1 = 单 Report 特征（载荷带 id）；0 = 5 个 Report 特征
  layoutSwitches: number;     // 布局被切换过的次数（只增不减）
  // ── 回读可靠性（★ 2026-09-21 加：一次误判的教训）────────────────────────
  // `GattServer.getService()` / `getServices()` 是 **@since 22** 的 API。设备上若
  // 不存在它们，调用会抛异常 —— 此时"查不到特征"**不是**"服务没注册"。
  // 旧代码把两者混成一句「特征数为 0（GATT 服务未被接受）」，还顺手把回读的
  // 异常信息覆盖掉，等于用一个坏掉的探针去判定功能不可用。
  // 现在：readbackAvailable=0 只表示"校验不了"，功能照常启动并给出警告。
  readbackAvailable: number;  // 1 = 回读成功（结论可信）；0 = 回读不可用（结论不可信）
  readbackError: string;      // 回读不可用时的确切原因（含错误码）
  readbackServiceUuid: string; // 栈返回的服务 UUID 原样文本（判大小写规范化）
  readbackCharUuids: string;  // 回读到的特征 UUID 短名清单，例 "2A4A,2A4B,2A4D×5"
  readbackAttempts: number;   // 回读试了几次（>1 = 首次踩到竞态，沉降后才对上）
  expectedChars: number;      // 应当注册到的特征数（按当前布局：SINGLE 5 / MULTI 9）
  apiVersion: number;         // deviceInfo.sdkApiVersion，用于解释"@since N 的 API 在旧版本上不存在"
  lastWarning: string;        // 启动成功但有隐患时的说明（空 = 无隐患）
  clientId: string;           // 当前客户端蓝牙地址（空 = 无）
  clientName: string;         // 当前客户端名称（取不到则为空 —— 不编造）
  clientConnectedAtText: string; // 本次连接时刻（原版 BluetoothClientConnectionTimeFormat）
  connected: number;          // 1 = 有客户端订阅着 Report
  connectCount: number;       // 累计连上次数
  disconnectCount: number;    // 累计断开次数
  protocolMode: number;       // iOS 下发的协议模式（1 = Report）
  mouseReports: number;       // 已发出的鼠标报表数
  keyboardReports: number;
  consumerReports: number;
  navReports: number;
  mouseDropped: number;       // 未连接时被丢弃的输入事件
  notifyFailures: number;     // notifyCharacteristicChanged 失败次数
  notifyTimeouts: number;     // 看门狗触发的超时复位次数
  lastError: string;          // 最近一次启动/注册失败原因
  lastNotifyError: string;    // 最近一次发送失败原因
  // ── 权限诊断（201 的唯一出处）──────────────────────────────────────────────
  // ACCESS_BLUETOOTH 是 **user_grant**：module.json5 里声明只是"申请资格"，
  // 不调 requestPermissionsFromUser 就永远拿不到，API 会直接回 201。
  // 这两项是"到底有没有授权"的累计账本 —— 只看 lastError 会分不清
  // 「从没申请过」「用户点了拒绝」「申请了但系统没给」。
  permGranted: number;        // 1 = 运行时已授权
  permRequestCount: number;   // 累计发起运行时申请的次数
  permDeniedCount: number;    // 累计被拒次数

  // ── ★★ 主机侧交互账本（2026-09-24 加：这一轮真正的根因）────────────────────
  // 华为《通用属性协议开发指导》原文：「**收到读取特征值请求时，需要调用
  // sendResponse 进行回复对应特征值的数据内容**」；OpenHarmony 框架层文档同样
  // 写明「Read request：needRsp 恒 true —— **Must call sendResponse()**」，
  // 且**描述符请求永远需要应答**。
  //
  // 也就是说：GATT 服务端**必须**自己应答每一个读/写请求。本实现此前只监听了
  // connectionStateChange 与 characteristicWrite、且写回调里也不应答 ⇒ iOS
  // 读 HID Information / 读 Report Map / 读 Report Reference / 写 CCCD 订阅
  // **全部无声超时**。Report Map 拿不到 ⇒ iOS 建不出 HID 设备 ⇒
  // 「iPhone 上永远不出现系统指针」且**没有任何错误提示**。
  //
  // 这一组字段就是"主机到底来过没有、做到了哪一步"的账本：
  //   读 0 ⇒ 主机压根没枚举（问题在广播/连接/配对，不在服务内容）
  //   读了 Report Map 但 subscribed 恒 0 ⇒ 主机读到了却不订阅（看配对/加密）
  //   subscribed=1 才轮到"报表投递到哪个特征"那类问题
  hostReads: number;          // 累计收到的主机读请求次数（特征 + 描述符）
  hostReadTally: string;      // 读请求按 UUID 的计数，例 "2A4A×1,2A4B×2"
  hostWrites: number;         // 累计收到的主机写请求次数（含 CCCD 订阅写）
  hostWriteTally: string;     // 写请求按 UUID 的计数，例 "2A4E×1,2902×1"
  subscribed: number;         // 1 = 主机写过 CCCD 且置了 notify 位（真正的"订阅上了"）
  cccdWrites: number;         // 累计收到的 CCCD(0x2902) 写次数（订阅/退订都算）
  responsesSent: number;      // 累计成功回出去的应答数
  respondFailures: number;    // 应答失败的次数（>0 ⇒ 必须看 lastError，别以为是主机没来）
  lastHostEvent: string;      // 最近一次主机动作的一句话，例 "读2A4B" / "订阅1"
  pairedCount: number;        // 系统已配对设备数；-1 = 读不到（权限/API 不可用）
  pairedHit: number;          // 1 = 当前客户端地址出现在已配对列表里（= 已绑定）
  pairNote: string;           // 配对探测的结论/失败原因（含"地址会随机化"这条前提）
  pairAttempts: number;       // 主动发起配对的次数
  readbackDescUuids: string;  // 回读到的 Report 特征描述符短名，例 "2902,2908"（判 CCCD 是否自动加）
}

/**
 * 一次 GATT 回读的结果。
 *
 * ★ 为什么要把"回读可用性"和"特征数"分开：`getService()`/`getServices()` 是
 *   **@since 22** 的新 API，设备上不存在时调用会抛异常。老实现把这个异常吞掉并
 *   报成"特征数为 0（GATT 服务未被接受）"，于是**用一个坏掉的探针**否掉了整个
 *   功能。available=0 的语义只能是"校验不了"，绝不能是"没注册"。
 */
interface GattReadback {
  /** 1 = 回读成功（count 可信）；0 = 回读不可用（count 无意义）。 */
  available: number;
  /** 回读到的特征数；available=0 时恒为 0，无意义。 */
  count: number;
  /** 栈返回的服务 UUID 原文（若与请求的大小写不同，说明栈做了规范化）。 */
  serviceUuid: string;
  /** 回读到的特征 UUID 短名清单，例 "2A4A,2A4B,2A4D,2A4D,..."。 */
  charUuids: string;
  /**
   * 回读到的 Report 特征描述符短名清单，例 "2902,2908"。
   *
   * ★ 为什么单独要这一项：`0x2902`（CCCD）是主机**订阅**用的描述符。鸿蒙的 GATT
   * 栈应当为带 notify 的特征自动补上它；若实际没有，主机就永远订阅不上、
   * 我们也永远收不到"订阅"这一步 —— 而现象与"主机没来"完全一样。所以必须能看见。
   */
  descUuids: string;
  /** available=0 时的确切原因（含错误码），供 UI 显示。 */
  error: string;
  /** 得到这份结果探测了几次。>1 = 首次回读踩到竞态、靠沉降才对上。 */
  attempts: number;
}

interface MouseReport {
  buttons: number;
  dx: number;
  dy: number;
  wheel: number;
}

/**
 * 已连接的 HID 客户端（原版 BluetoothHidMouseService 的 _clientStates 一条记录）。
 *
 * 为什么单独导出一个接口（而不是直接复用页面里的 BluetoothClientInfo）：
 * common/ 不该反向依赖 pages/。页面自己把它映射成 BluetoothClientInfo。
 */
export interface BluetoothHidClient {
  /** 蓝牙地址（BLE 连接事件给的 deviceId）。 */
  address: string;
  /** 对端名称；取不到时为空串（不编造）。 */
  name: string;
  /** 本次连接的本地时刻。 */
  connectedAtText: string;
}

/** 两位数补零。 */
function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

/**
 * 本机 SDK API 等级。诊断用：`GattServer.getService()` / `getServices()` 是
 * **@since 22** 的接口，在更低的设备上调用会抛异常 —— 有了这个数字才能解释
 * "为什么回读不可用"而不是猜。取不到返回 0（不编造）。
 */
function read_sdk_api_version(): number {
  try {
    return deviceInfo.sdkApiVersion;
  } catch (error) {
    return 0;
  }
}

/**
 * 等待 ms 毫秒。只给"回读沉降"用（见 READBACK_SETTLE_*）。
 *
 * 为什么自己写一个而不是复用：项目里此前没有任何 Promise 化的等待（setTimeout 都是
 * 命令式的），而这次必须在 async 流程里"暂停一下再重试"，所以需要它。
 */
function delay_ms(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout((): void => {
      resolve();
    }, ms);
  });
}

/**
 * 时间戳 → 'YYYY-MM-DD HH:mm:ss'。
 *
 * 不复用页面的格式化函数：common/ 不下依赖 pages/，且这里只服务诊断与客户端列表。
 */
function format_local_time(ms: number): string {
  if (ms <= 0) {
    return '';
  }
  const d: Date = new Date(ms);
  const date: string = `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
  const time: string = `${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`;
  return `${date} ${time}`;
}

interface KeyboardReport {
  modifiers: number;
  usages: number[];
}

// 把字节数组转成 GATT 需要的 ArrayBuffer
function to_buffer(bytes: number[]): ArrayBuffer {
  const buffer = new ArrayBuffer(bytes.length);
  const view = new Uint8Array(buffer);
  for (let i = 0; i < bytes.length; i++) {
    view[i] = bytes[i] & 0xFF;
  }
  return buffer;
}

// Report Reference 描述符的值 = [reportId, reportType]
function report_reference(report_id: number, report_type: number): ArrayBuffer {
  return to_buffer([report_id, report_type]);
}

// UUID 比对一律忽略大小写：栈回给我们的文本格式（大小写、是否带 0x）没有保证，
// 用 `===` 直接比是**假阴性**的常见来源。
function same_uuid(a: string, b: string): boolean {
  if (a === undefined || a === null || b === undefined || b === null) {
    return false;
  }
  return a.toUpperCase() === b.toUpperCase();
}

// 诊断里只写 UUID 的第 5–8 位（2A4A / 2902 …）。整条 UUID 太长，读数会挤爆。
function short_uuid(uuid: string): string {
  if (uuid === undefined || uuid === null || uuid.length < 8) {
    return '?';
  }
  return uuid.substring(4, 8).toUpperCase();
}

export class BluetoothHidPeripheral {
  private static instance: BluetoothHidPeripheral = new BluetoothHidPeripheral();

  private server: ble.GattServer | null = null;
  private started: boolean = false;
  private advertising: boolean = false;
  // 正在进行的 start()。见 start() 里的并发守卫说明。
  private startingPromise: Promise<boolean> | null = null;

  private clientId: string = '';
  private clientName: string = '';
  private clientConnectedAtMs: number = 0;
  private connected: boolean = false;
  private protocolMode: number = PROTOCOL_MODE_REPORT;

  // 合并队列：鼠标移动是高频事件，蓝牙带不动逐条发 —— 只保留"最新一帧"，
  // 位移累加。这与上游"宁丢勿延迟"的取向一致，也是不把 RTP/UI 线程拖垮的关键。
  private pendingMouse: MouseReport | null = null;
  private mouseInFlight: boolean = false;
  private mouseFlightStart: number = 0;
  private pendingKeyboard: KeyboardReport | null = null;
  private keyboardInFlight: boolean = false;
  private keyboardInFlightStart: number = 0;

  // 诊断计数（只增不减 —— 只显示"最近一次结果"会持续吃掉关键证据）
  private serviceChars: number = 0;
  // HID 布局模式（见 HID_LAYOUT_* 与「HID 布局模式」注释块）。
  private layout: number = DEFAULT_HID_LAYOUT;
  private layoutSwitches: number = 0;
  // 最近一次 start() 用的上下文。切换布局要把整个 GATT 服务重建（不能热改），
  // 所以得留着它才能就地重启外设。
  private lastContext: common.Context | null = null;
  // 回读可靠性（见 BluetoothHidDiag 的 readback* 说明）：available=0 只表示
  // "校验不了"，不代表"没注册"。
  private readbackAvailable: number = 0;
  private readbackError: string = '';
  private readbackServiceUuid: string = '';
  private readbackCharUuids: string = '';
  // 本次回读试了几次（>1 = 首次回读是竞态，沉降后才读到）。只增不减。
  private readbackAttempts: number = 0;
  private lastWarning: string = '';
  private connectCount: number = 0;
  private disconnectCount: number = 0;
  private mouseReports: number = 0;
  private keyboardReports: number = 0;
  private consumerReports: number = 0;
  private navReports: number = 0;
  private mouseDropped: number = 0;
  private notifyFailures: number = 0;
  private notifyTimeouts: number = 0;
  private lastError: string = '';
  private lastNotifyError: string = '';

  // 权限账本（只增不减）。见 BluetoothHidDiag 里 perm* 的说明。
  private permGranted: boolean = false;
  private permRequestCount: number = 0;
  private permDeniedCount: number = 0;

  // ── 主机侧交互账本（见 BluetoothHidDiag 的 host* 说明）────────────────────
  private hostReads: number = 0;
  private hostWrites: number = 0;
  private subscribed: number = 0;
  private cccdValue: number = 0;
  private cccdWrites: number = 0;
  private responsesSent: number = 0;
  private respondFailures: number = 0;
  private lastHostEvent: string = '';
  private readTally: Map<string, number> = new Map<string, number>();
  private writeTally: Map<string, number> = new Map<string, number>();
  // Report 特征当前的"可读值"。主机可能来读它（HOGP 允许），必须给得出东西，
  // 否则那次读就是超时 —— 而超时在主机侧只会表现为"这个设备不好用"。
  private reportValue: ArrayBuffer = new ArrayBuffer(0);
  // 配对探测（见 BluetoothHidDiag 的 paired* 说明）。pairedCount = -1 表示读不到。
  private pairedCount: number = -1;
  private pairedHit: number = 0;
  private pairNote: string = '';
  private pairAttempts: number = 0;
  private bondProbeTick: number = 0;
  private readbackDescUuids: string = '';

  private onConnectionChange = (state: ble.BLEConnectionChangeState): void => {
    // 这个回调由系统线程投递，里面抛异常会变成未捕获异常 → 整个应用被结束。
    try {
      const connectedState: number = constant.ProfileConnectionState.STATE_CONNECTED;
      const disconnectedState: number = constant.ProfileConnectionState.STATE_DISCONNECTED;
      if (state.state === connectedState) {
        this.clientId = state.deviceId;
        this.connected = true;
        this.connectCount++;
        this.clientConnectedAtMs = Date.now();
        // 名称要向系统查一次。取不到就留空 —— 页面显示时会退回"未知设备"，
        // 而不是拿地址冒充名称。
        this.clientName = '';
        try {
          const name: string = connection.getRemoteDeviceName(state.deviceId);
          if (name !== undefined && name !== null) {
            this.clientName = name;
          }
        } catch (error) {
          // 未配对/系统不允许时这里会抛，属正常情况，只记不报错。
          this.clientName = '';
        }
      } else if (state.state === disconnectedState) {
        this.connected = false;
        this.disconnectCount++;
        // 订阅是"本次连接"的属性：断开即失效。**必须复位**，否则界面上会一直
        // 显示"已订阅"，而我们其实早就收不到任何东西了（历史次数由 cccdWrites 留证）。
        this.subscribed = 0;
        this.cccdValue = 0;
        if (state.deviceId === this.clientId) {
          this.clientId = '';
          this.clientName = '';
          this.clientConnectedAtMs = 0;
        }
      }
    } catch (error) {
      const err = error as BusinessError;
      this.lastError = `连接状态回调异常：${err.message}`;
    }
  };

  private onCharacteristicWrite = (request: ble.CharacteristicWriteRequest): void => {
    try {
      this.hostWrites++;
      this.tally(this.writeTally, request.characteristicUuid);
      this.lastHostEvent = `写${short_uuid(request.characteristicUuid)}`;
      // iOS 会在订阅前把 Protocol Mode 写成 1（Report Protocol）。
      // 它写的是 Boot Protocol 时我们无法按 report id 组包，必须如实记下来。
      if (same_uuid(request.characteristicUuid, UUID_PROTOCOL_MODE)) {
        const view = new Uint8Array(request.value);
        if (view.length > 0) {
          this.protocolMode = view[0];
        }
      }
      // ★ 带响应的写必须应答（needRsp 由请求给出；对端若是 Write Request 而我们
      //   不回，对端会一直等到超时 —— 与"没写成功"在现象上无法区分）。
      if (request.needRsp) {
        this.respond(request.deviceId, request.transId, request.offset, new ArrayBuffer(0));
      }
    } catch (error) {
      const err = error as BusinessError;
      this.lastError = `特征写入回调异常：${err.message}`;
    }
  };

  // ── ★★ 主机侧请求的应答（2026-09-24：这一轮真正的根因）──────────────────────
  //
  // 官方规定（华为《通用属性协议开发指导》）：**收到读取特征值请求时，需要调用
  // sendResponse 进行回复**；OpenHarmony 框架层的表述更直白：「Read request —
  // needRsp 恒 true — Must call sendResponse()」，且**描述符请求永远需要应答**。
  //
  // 本实现此前只监听了 connectionStateChange / characteristicWrite，读请求一个都
  // 没应答 ⇒ iOS 读 HID Information(2A4A)、Report Map(2A4B)、Report Reference(2908)
  // 与写 CCCD(2902) 全部无声超时 ⇒ **Report Map 拿不到，iOS 建不出 HID 设备** ⇒
  // iPhone 上永远不出现系统指针，且没有任何错误提示。这是"看着全对、就是不动"
  // 的另一种形态：对端在等我们回话，而我们连"听到了"都没记。
  //
  // 三个处理器都做同一件事：① 记账（主机来过没有、来了读什么）② 按 UUID 取值
  // ③ 用请求自带的 deviceId/transId/offset 应答。任何一步抛异常都只记不抛 ——
  // 这些回调由系统线程投递，抛出去会结束整个应用。

  /** 累计某个 UUID 的出现次数（诊断用；ArkTS 下 Map 比对象字面量安全）。 */
  private tally(bucket: Map<string, number>, uuid: string): void {
    const key: string = short_uuid(uuid);
    const previous: number | undefined = bucket.get(key);
    bucket.set(key, previous === undefined ? 1 : previous + 1);
  }

  /** Map → "2A4A×1,2A4B×2"（按写入顺序）。 */
  private tallyText(bucket: Map<string, number>): string {
    const parts: string[] = [];
    bucket.forEach((count: number, key: string): void => {
      parts.push(`${key}×${count}`);
    });
    return parts.join(',');
  }

  /** 把一个值应答回去。失败只记账 —— 应答失败与应用崩掉，前者才是可诊断的。 */
  private respond(deviceId: string, transId: number, offset: number,
    value: ArrayBuffer): void {
    const server = this.server;
    if (server === null) {
      return;
    }
    try {
      const response: ble.ServerResponse = {
        deviceId: deviceId,
        transId: transId,
        status: 0,                  // 0 = 成功
        offset: offset,
        value: value
      };
      server.sendResponse(response);
      this.responsesSent++;
    } catch (error) {
      const err = error as BusinessError;
      this.respondFailures++;
      this.lastError = `应答主机请求失败：${err.code} ${err.message}`;
    }
  }

  /** 按特征 UUID 取"该回什么值"。取不到就回空 —— 但绝不因此不答。 */
  private characteristic_value(uuid: string): ArrayBuffer {
    if (same_uuid(uuid, UUID_HID_INFORMATION)) {
      return to_buffer(HID_INFORMATION);
    }
    if (same_uuid(uuid, UUID_REPORT_MAP)) {
      return to_buffer(HID_REPORT_MAP);
    }
    if (same_uuid(uuid, UUID_PROTOCOL_MODE)) {
      return to_buffer([this.protocolMode]);
    }
    if (same_uuid(uuid, UUID_HID_CONTROL_POINT)) {
      return to_buffer([0x00]);
    }
    if (same_uuid(uuid, UUID_REPORT)) {
      return this.reportValue;
    }
    return new ArrayBuffer(0);
  }

  /**
   * 按描述符 UUID 取"该回什么值"。
   *
   * ⚠️ 已知局限（MULTI 布局）：`DescriptorReadRequest` 只给 descriptorUuid 与
   * characteristicUuid，**不给"第几个 Report 特征实例"** ⇒ 5 个实例的
   * Report Reference(2908) 读到的是同一个值。这也是 MULTI 布局在鸿蒙上走不通的
   * 另一条独立理由（SINGLE 只有一个实例，不存在这个问题）。
   */
  private descriptor_value(uuid: string): ArrayBuffer {
    if (same_uuid(uuid, UUID_REPORT_REFERENCE)) {
      const id: number = this.layout === HID_LAYOUT_SINGLE ? 0 : REPORT_ID_KEYBOARD;
      return report_reference(id, REPORT_TYPE_INPUT);
    }
    if (same_uuid(uuid, UUID_CCCD)) {
      return to_buffer([this.cccdValue, 0x00]);
    }
    return new ArrayBuffer(0);
  }

  private onCharacteristicRead = (request: ble.CharacteristicReadRequest): void => {
    try {
      this.hostReads++;
      this.tally(this.readTally, request.characteristicUuid);
      this.lastHostEvent = `读${short_uuid(request.characteristicUuid)}`;
      this.respond(request.deviceId, request.transId, request.offset,
        this.characteristic_value(request.characteristicUuid));
    } catch (error) {
      const err = error as BusinessError;
      this.lastError = `特征读取回调异常：${err.message}`;
    }
  };

  private onDescriptorRead = (request: ble.DescriptorReadRequest): void => {
    try {
      this.hostReads++;
      this.tally(this.readTally, request.descriptorUuid);
      this.lastHostEvent = `读描述符${short_uuid(request.descriptorUuid)}`;
      this.respond(request.deviceId, request.transId, request.offset,
        this.descriptor_value(request.descriptorUuid));
    } catch (error) {
      const err = error as BusinessError;
      this.lastError = `描述符读取回调异常：${err.message}`;
    }
  };

  /**
   * 描述符写 = **主机在订阅/退订**（CCCD 0x2902）。
   *
   * 这是"主机认不认这个设备"的转折点：写了 CCCD 才代表它真的准备收 Report。
   * 所以除了应答，还要把值本身留下来（subscribed）—— 只增不减地记，
   * 否则"订阅过又退了"会被"最近一次结果"吃掉。
   */
  private onDescriptorWrite = (request: ble.DescriptorWriteRequest): void => {
    try {
      this.hostWrites++;
      this.tally(this.writeTally, request.descriptorUuid);
      if (same_uuid(request.descriptorUuid, UUID_CCCD)) {
        this.cccdWrites++;
        const view = new Uint8Array(request.value);
        this.cccdValue = view.length > 0 ? view[0] : 0;
        if ((this.cccdValue & 0x01) !== 0) {
          this.subscribed = 1;
        }
        this.lastHostEvent = `订阅${this.cccdValue}`;
      } else {
        this.lastHostEvent = `写描述符${short_uuid(request.descriptorUuid)}`;
      }
      if (request.needRsp) {
        this.respond(request.deviceId, request.transId, request.offset, new ArrayBuffer(0));
      }
    } catch (error) {
      const err = error as BusinessError;
      this.lastError = `描述符写入回调异常：${err.message}`;
    }
  };

  static shared(): BluetoothHidPeripheral {
    return BluetoothHidPeripheral.instance;
  }

  isAdvertising(): boolean {
    return this.advertising;
  }

  isConnected(): boolean {
    return this.connected;
  }

  /** 当前 HID 布局模式（HID_LAYOUT_SINGLE / HID_LAYOUT_MULTI）。 */
  layoutMode(): number {
    return this.layout;
  }

  /** 布局的中文短名，可直接进状态行与诊断读数。 */
  layoutText(): string {
    return this.layout === HID_LAYOUT_SINGLE ? '单特征' : '多特征';
  }

  /** 当前布局下应当注册到的特征数（SINGLE = 5 / MULTI = 9）。 */
  private expected_characteristic_count(): number {
    return this.layout === HID_LAYOUT_SINGLE ? EXPECTED_CHARS_SINGLE : EXPECTED_CHARS_MULTI;
  }

  /**
   * 切换 HID 布局并就地重启外设。
   *
   * 为什么必须重启：Report 特征的**个数**与各特征的 Report Reference 描述符都在
   * `build_service()` 里，而 GATT 服务一旦 `addService()` 就不能改（要重来一遍）。
   * 代价是 iPhone 会断开、需重新连一次 —— 这是切换布局的固有代价，所以只在
   * 用户明确点"切换布局"时才调用。
   *
   * @returns true = 已按新布局重新开始广播。
   */
  async setLayoutMode(mode: number): Promise<boolean> {
    if (mode !== HID_LAYOUT_SINGLE && mode !== HID_LAYOUT_MULTI) {
      return false;
    }
    if (mode === this.layout) {
      return true;
    }
    const ctx: common.Context | null = this.lastContext;
    this.layout = mode;
    this.layoutSwitches++;
    this.stop();
    if (ctx === null) {
      // 从没成功启动过 ⇒ 没有上下文可重启。服务已停，如实返回失败，由调用方
      // 去走"重新开启"那条路（那里能拿到上下文）。
      this.lastError = '已切到新布局，但没有可用的应用上下文：请在设置里重新开启蓝牙反控';
      return false;
    }
    return await this.start(ctx);
  }

  // 给 UI 用的一句话状态。刻意把"没连上"和"广播没开"分开报 —— 两者处置完全不同。
  //
  // ★ 三个取值一律带「（实验）」：本版本的反控仍在实现阶段（iPhone 侧可能始终
  //   不出现指针）。这条串会出现在设置卡片的状态行里，写「已广播」而不带成熟度，
  //   用户就会把"GATT 服务起来了"读成"功能可用"。成熟度声明与真值同源，见
  //   SUPPORT.md § 一之补 / Index.ets 的 reverse_label()。
  statusText(): string {
    if (!this.started) {
      return '蓝牙反控（实验）未启用';
    }
    if (!this.advertising) {
      return '蓝牙反控（实验）：广播未开启';
    }
    // 主机侧账本：`读0` 与 `读N 订0` 是两种完全不同的故障，必须能在状态里直接区分 ——
    // 前者是主机没来枚举（广播/连接/配对），后者是主机来了但不订阅（内容/加密）。
    const ledger: string = `主机 读${this.hostReads} 写${this.hostWrites}`
      + ` 订${this.subscribed} 应答失败${this.respondFailures}`;
    if (this.connected) {
      const who: string = this.clientName.length > 0
        ? `${this.clientName}（${this.clientId}）`
        : this.clientId;
      return `蓝牙反控（实验）已连接（${who}） · ${ledger}`;
    }
    return `蓝牙反控（实验）已广播，等待 iPhone 连接 · ${ledger}`;
  }

  /**
   * 当前已连接的客户端（原版 BluetoothHidMouseService 的 _clientStates）。
   *
   * 为什么最多只有一条：本移植用的是一个 GATT Server + 一个 HID 服务，
   * 鸿蒙的 GattServer 在同一时刻只维护一个活动连接（原版 Windows 的
   * GattServiceProvider 支持多个订阅者，这是平台差异，不假装一致）。
   */
  connectedClients(): BluetoothHidClient[] {
    if (!this.connected || this.clientId.length === 0) {
      return [];
    }
    return [{
      address: this.clientId,
      name: this.clientName,
      connectedAtText: format_local_time(this.clientConnectedAtMs),
    }];
  }

  errorText(): string {
    return this.lastError;
  }

  /** 启动成功但有隐患时的说明（空 = 无隐患）。与 errorText() 分开：一个是失败原因，
   *  一个是"跑起来了但校验不了/注册不全"，两者的处置方式完全不同。 */
  warningText(): string {
    return this.lastWarning;
  }

  /**
   * 一整段可复制的诊断文本（设置面板「复制诊断」按钮用）。
   *
   * 为什么要有它：条带/状态行能显示的字数有限，而"反控没反应"的现场往往需要
   * 十几项数字一起看才能定性。让用户能**一次复制**发过来，比让他在几条短句里
   * 找读数可靠得多 —— 这也是上一轮"没有读数反馈"的直接教训。
   *
   * 写作纪律：每项都带**真值**（没有就写"无"），不写"正常/异常"这类需要二次解释的词。
   */
  diagnosisText(): string {
    const d: BluetoothHidDiag = this.diag();
    const lines: string[] = [];
    lines.push('[iPhoneMirror 反控诊断 · HID 侧]');
    lines.push(`广播${d.advertising} 连接${d.connected} 设备=${d.clientName.length > 0 ? d.clientName : '(无名称)'} ${d.clientId.length > 0 ? d.clientId : '(无地址)'}`);
    lines.push(`累计: 连${d.connectCount} 断${d.disconnectCount} 本次连接于 ${d.clientConnectedAtText.length > 0 ? d.clientConnectedAtText : '(无)'}`);
    lines.push(`布局: ${this.layoutText()} 切过${d.layoutSwitches}次 特征${d.serviceChars}/${d.expectedChars} 清单=${d.readbackCharUuids.length > 0 ? d.readbackCharUuids : '(无)'} 描述符=${d.readbackDescUuids.length > 0 ? d.readbackDescUuids : '(无)'}`);
    lines.push(`主机: 读${d.hostReads}(${d.hostReadTally.length > 0 ? d.hostReadTally : '-'}) 写${d.hostWrites}(${d.hostWriteTally.length > 0 ? d.hostWriteTally : '-'}) 订阅${d.subscribed} CCCD写${d.cccdWrites}`);
    lines.push(`应答: 成功${d.responsesSent} 失败${d.respondFailures}`);
    lines.push(`最近主机动作: ${d.lastHostEvent.length > 0 ? d.lastHostEvent : '(还没有)'}`);
    lines.push(`配对: 已配对${d.pairedCount}台 命中${d.pairedHit} 主动发起${d.pairAttempts}次 · ${d.pairNote.length > 0 ? d.pairNote : '(未探测)'}`);
    lines.push(`协议: mode=${d.protocolMode} 报表: 鼠${d.mouseReports} 键${d.keyboardReports} 多${d.consumerReports} 导${d.navReports} 丢${d.mouseDropped}`);
    lines.push(`发送: 失败${d.notifyFailures} 超时${d.notifyTimeouts} · ${d.lastNotifyError.length > 0 ? d.lastNotifyError : '(无)'}`);
    lines.push(`回读: 可用${d.readbackAvailable} 试${d.readbackAttempts}次 服务=${d.readbackServiceUuid.length > 0 ? d.readbackServiceUuid : '(无)'} 错误=${d.readbackError.length > 0 ? d.readbackError : '(无)'}`);
    lines.push(`权限: 授权${d.permGranted} 申请${d.permRequestCount} 拒${d.permDeniedCount} · SDK API ${d.apiVersion}`);
    if (d.lastWarning.length > 0) {
      lines.push(`警告: ${d.lastWarning}`);
    }
    if (d.lastError.length > 0) {
      lines.push(`错误: ${d.lastError}`);
    }
    return lines.join('\n');
  }

  // ── 配对（绑定）真值 ──────────────────────────────────────────────────────
  //
  // 为什么必须能读出来：iOS 对 HID 设备**要求加密链路**（上游 Windows 版是靠
  // `ReadProtectionLevel = EncryptionRequired` 逼 iOS 走配对；见
  // BluetoothHidMouseService.cs:721-725）。鸿蒙的 `GattProperties` 只有
  // read/write/notify/indicate 这些开关，**没有"要求加密"这一项**（离线 SDK 原文），
  // 所以我们这一侧无法声明"必须先配对"。剩下的路只有两条：
  //   ① 用户在 iPhone 的「辅助触控 → 设备 → 蓝牙设备」里配对（上游用户手册的做法）；
  //   ② 我们用 `connection.pairDevice()` 主动向已连接的 iPhone 发起配对。
  // 两条路的成败都需要一个可读的真值来判定 —— 那就是这里。

  /**
   * 读一次"当前客户端到底绑定了没有"。
   *
   * ⚠️ 前提必须写清楚：iOS 用**可解析随机地址**，同一次连接里地址固定，但换一次
   * 连接就可能变 ⇒ `pairedHit=0` **不能**断定"没绑定"，只能说明"这一条地址不在
   * 已配对列表里"。因此 pairedCount（系统已配对总数）与 pairedHit（命中）都要看。
   */
  refresh_bond(): void {
    try {
      const paired: string[] = connection.getPairedDevices();
      this.pairedCount = paired === undefined || paired === null ? -1 : paired.length;
      const wanted: string = this.clientId.toUpperCase();
      let hit: number = 0;
      if (wanted.length > 0 && paired !== undefined && paired !== null) {
        for (let i = 0; i < paired.length; i++) {
          if (paired[i] !== undefined && paired[i] !== null
            && paired[i].toUpperCase() === wanted) {
            hit = 1;
            break;
          }
        }
      }
      // 命中只增不减：地址会随机化，某一次没命中不代表从没命中过。
      if (hit === 1) {
        this.pairedHit = 1;
      }
      this.pairNote = `已配对 ${this.pairedCount} 台设备，当前客户端命中 ${this.pairedHit}`;
    } catch (error) {
      const err = error as BusinessError;
      this.pairedCount = -1;
      this.pairNote = `配对查询不可用：${err.code} ${err.message}`;
    }
  }

  /** UI 轮询里按节拍调用的配对探测（见 BOND_PROBE_INTERVAL_TICKS）。 */
  bond_probe_tick(): void {
    this.bondProbeTick++;
    if (this.bondProbeTick % BOND_PROBE_INTERVAL_TICKS !== 0) {
      return;
    }
    this.refresh_bond();
  }

  /**
   * 主动向已连接的 iPhone 发起配对（用户点按钮时的显式动作）。
   *
   * 为什么做成"手动"：配过对会在对方手机上弹授权框，自动重试会变成骚扰。这里只
   * 尝试一次，并把结果如实回报。
   */
  async pair_client(): Promise<string> {
    if (this.clientId.length === 0) {
      return '没有已连接的 iPhone，无法发起配对';
    }
    this.pairAttempts++;
    try {
      await connection.pairDevice(this.clientId);
      this.refresh_bond();
      return this.pairedHit === 1
        ? '配对成功（已出现在系统已配对列表）'
        : '已发起配对，请留意 iPhone 上的配对提示';
    } catch (error) {
      const err = error as BusinessError;
      this.pairNote = `主动配对失败：${err.code} ${err.message}`;
      return this.pairNote;
    }
  }

  diag(): BluetoothHidDiag {
    const result: BluetoothHidDiag = {
      available: 1,
      started: this.started ? 1 : 0,
      advertising: this.advertising ? 1 : 0,
      serviceChars: this.serviceChars,
      layout: this.layout,
      layoutSwitches: this.layoutSwitches,
      readbackAvailable: this.readbackAvailable,
      readbackError: this.readbackError,
      readbackServiceUuid: this.readbackServiceUuid,
      readbackCharUuids: this.readbackCharUuids,
      readbackAttempts: this.readbackAttempts,
      expectedChars: this.expected_characteristic_count(),
      apiVersion: read_sdk_api_version(),
      lastWarning: this.lastWarning,
      clientId: this.clientId,
      clientName: this.clientName,
      clientConnectedAtText: format_local_time(this.clientConnectedAtMs),
      connected: this.connected ? 1 : 0,
      connectCount: this.connectCount,
      disconnectCount: this.disconnectCount,
      protocolMode: this.protocolMode,
      mouseReports: this.mouseReports,
      keyboardReports: this.keyboardReports,
      consumerReports: this.consumerReports,
      navReports: this.navReports,
      mouseDropped: this.mouseDropped,
      notifyFailures: this.notifyFailures,
      notifyTimeouts: this.notifyTimeouts,
      lastError: this.lastError,
      lastNotifyError: this.lastNotifyError,
      permGranted: this.permGranted || this.check_access() === true ? 1 : 0,
      permRequestCount: this.permRequestCount,
      permDeniedCount: this.permDeniedCount,
      hostReads: this.hostReads,
      hostReadTally: this.tallyText(this.readTally),
      hostWrites: this.hostWrites,
      hostWriteTally: this.tallyText(this.writeTally),
      subscribed: this.subscribed,
      cccdWrites: this.cccdWrites,
      responsesSent: this.responsesSent,
      respondFailures: this.respondFailures,
      lastHostEvent: this.lastHostEvent,
      pairedCount: this.pairedCount,
      pairedHit: this.pairedHit,
      pairNote: this.pairNote,
      pairAttempts: this.pairAttempts,
      readbackDescUuids: this.readbackDescUuids
    };
    return result;
  }

  // ── 权限 ──────────────────────────────────────────────────────────────────

  /**
   * 运行时申请 ACCESS_BLUETOOTH。
   *
   * ★ 这一条缺失就是此前界面上那句
   *   「注册 BLE HID 服务失败：201 BusinessError 201: Permission denied.」
   *   的确切原因 —— `GattServer.addService()` 的 @permission 正是
   *   ohos.permission.ACCESS_BLUETOOTH，而它是 **user_grant**：
   *   module.json5 里声明只给了"申请资格"，不调这个接口永远拿不到授权。
   *
   * 已授权时先查令牌直接放行（不再弹窗）；未授权才弹系统授权框。
   * 全程 try/catch —— 它由按钮点击驱动，异常抛出去会变成未捕获异常结束整个应用。
   */
  async ensure_access(ctx: common.Context): Promise<boolean> {
    if (this.check_access() === true) {
      this.permGranted = true;
      return true;
    }
    try {
      const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      this.permRequestCount++;
      // 注意类型来源：PermissionRequestResult 是 @ohos.abilityAccessCtrl 的**顶层**
      // 导出（SDK 里 `export type PermissionRequestResult = _PermissionRequestResult`），
      // 不在 abilityAccessCtrl 命名空间里 —— 写成 abilityAccessCtrl.PermissionRequestResult
      // 会直接编译报 2694。
      const result: PermissionRequestResult =
        await manager.requestPermissionsFromUser(ctx, [BLUETOOTH_PERMISSION]);
      const results: number[] = result.authResults;
      this.permGranted = results !== undefined && results !== null
        && results.length > 0 && results[0] === 0;
      if (this.permGranted) {
        return true;
      }
      this.permDeniedCount++;
      this.lastError = `未授予蓝牙权限（${BLUETOOTH_PERMISSION}）：`
        + `requestPermissionsFromUser 返回 ${JSON.stringify(results)}。`
        + '请在「设置 → 应用 → iPhoneMirror → 权限」里允许「蓝牙」后重试。';
      return false;
    } catch (error) {
      const err = error as BusinessError;
      this.lastError = `申请蓝牙权限失败：${err.code} ${err.message}`;
      return false;
    }
  }

  /**
   * 只读查询：令牌里 ACCESS_BLUETOOTH 是否已授予。
   *
   * 口径与 common/UsbPermission.ets 完全一致（bundleManager 取自身 tokenId →
   * checkAccessTokenSync），好处是"已授权但 API 仍报 201"这类情形能一眼区分开。
   * 查不到返回 null（未知），**不把未知当成未授权**。
   */
  private check_access(): boolean | null {
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const status: abilityAccessCtrl.GrantStatus =
        manager.checkAccessTokenSync(info.appInfo.accessTokenId, BLUETOOTH_PERMISSION);
      return status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (error) {
      return null;
    }
  }

  // ── 启停 ──────────────────────────────────────────────────────────────────

  /**
   * 确保权限 → 注册 HID 服务 → 开广播。返回 false 时 errorText() 里有确切原因。
   *
   * ★ async 有两个原因：① 权限（requestPermissionsFromUser 必然异步，要弹系统授权
   *   框）；② 注册后的回读要做**沉降重试**（addService 是跨进程调用，见
   *   probe_registered_service_settled）。
   */
  async start(ctx: common.Context): Promise<boolean> {
    // 记上下文：切换布局要重建 GATT 服务，届时需要它才能就地重启（见 setLayoutMode）。
    this.lastContext = ctx;
    if (this.started) {
      return true;
    }
    // ★ 并发守卫：this.started 要到 register_and_advertise() 跑完才置 true，
    //   而那中间隔着"弹权限框"和"沉降重试"两段很长的等待（数×120ms）。主窗口
    //   与独立窗口都会做惰性启动，两边同时触发时就会双双穿过上面那道判断，
    //   于是 createGattServer/addService 各来一遍 —— 后一个 server 覆盖前一个，
    //   前一个广播悬着没人管，现象是"广播着但永远连不上"。
    //   并发的第二次调用直接复用第一次那个 Promise，不重复注册。
    if (this.startingPromise !== null) {
      return this.startingPromise;
    }
    this.startingPromise = this.start_internal(ctx);
    try {
      return await this.startingPromise;
    } finally {
      this.startingPromise = null;
    }
  }

  /** start() 的主体（拆出来是为了让并发守卫只包一层 Promise）。 */
  private async start_internal(ctx: common.Context): Promise<boolean> {
    const granted: boolean = await this.ensure_access(ctx);
    if (!granted) {
      return false;                       // lastError 已由 ensure_access 写好
    }
    return await this.register_and_advertise();
  }

  /** 注册 HID 服务 + 开广播（start() 的主体）。 */
  private async register_and_advertise(): Promise<boolean> {
    this.lastError = '';
    this.lastWarning = '';
    this.readbackAvailable = 0;
    this.readbackError = '';
    this.readbackServiceUuid = '';
    this.readbackCharUuids = '';
    this.readbackAttempts = 0;
    try {
      const server = ble.createGattServer();
      server.on('connectionStateChange', this.onConnectionChange);
      server.on('characteristicWrite', this.onCharacteristicWrite);
      // ★ 读请求与描述符请求必须应答（官方规定，见各处理器的说明）。少注册一个，
      //   对应的那类请求就变成"对端等到超时"，而我们在界面上看不到任何异常。
      server.on('characteristicRead', this.onCharacteristicRead);
      server.on('descriptorRead', this.onDescriptorRead);
      server.on('descriptorWrite', this.onDescriptorWrite);
      server.addService(this.build_service());
      this.server = server;
      const readback: GattReadback = await this.probe_registered_service_settled(server);
      this.readbackAvailable = readback.available;
      this.readbackError = readback.error;
      this.readbackServiceUuid = readback.serviceUuid;
      this.readbackCharUuids = readback.charUuids;
      this.readbackDescUuids = readback.descUuids;
      this.readbackAttempts = readback.attempts;
      this.serviceChars = readback.available !== 0 ? readback.count : 0;
      // ★ 只有"回读成功 + 两条路交叉印证后仍说服务不在"才算真证据。回读不可用时
      //   绝不能据此下结论 —— 那正是把整个功能误判为不可用的原因（见 GattReadback）。
      //   文案里带上证据（试了几次 / SDK 等级 / 探针原话），否则用户和我们都没法
      //   区分"服务真没注册"与"我们找错了口径"。
      if (readback.available !== 0 && readback.count === 0) {
        this.lastError = `HID 服务注册后回读不到该服务（已沉降重试 ${readback.attempts}`
          + `×${READBACK_SETTLE_DELAY_MS}ms，SDK ${read_sdk_api_version()}）`
          + `—— GATT 服务未被接受`
          + (readback.error.length > 0 ? `；探针记录：${readback.error}` : '');
        this.cleanup();
        return false;
      }
      if (readback.available === 0) {
        this.lastWarning = `已启动，但无法回读 GATT 服务以校验特征数`
          + `（SDK ${read_sdk_api_version()}：${readback.error}）`
          + `；若 iPhone 连上后无反应，请把这条发给开发者`;
      } else if (readback.count < this.expected_characteristic_count()) {
        // 少注册了特征：HOGP 需要每个 report 一个 Report 特征（MULTI 布局要 5 个），
        // 少一个就意味着某个 report 发不出去。不拦启动，但必须报出来。
        this.lastWarning = `只注册到 ${readback.count}/${this.expected_characteristic_count()} 个特征`
          + ` · 实到 ${readback.charUuids}`;
      } else if (readback.attempts > 1) {
        // 读到 9/9 但第一次是空 —— 这是一条有价值的现场事实：证明 addService 返回
        // 之后确实存在"服务还查不到"的窗口。留着它，以后遇到类似误判能直接对上。
        this.lastWarning = `首次回读为空，沉降到第 ${readback.attempts} 次才读到`
          + ` ${readback.count} 个特征（GATT 注册是异步落地）`;
      }
    } catch (error) {
      const err = error as BusinessError;
      // 801 = Capability not supported：该设备/该 SDK 不具备 BLE 外设能力。
      // 这是本功能最主要的不确定性，必须原样报给用户，不能含糊成"启动失败"。
      this.lastError = `注册 BLE HID 服务失败：${err.code} ${err.message}` +
        (err.code === 801 ? '（当前设备不支持 BLE 外设角色）' : '');
      this.cleanup();
      return false;
    }

    try {
      const setting: ble.AdvertiseSetting = { interval: 160, txPower: 0, connectable: true };
      // 广播里必须带 HID 服务 UUID，iPhone 的蓝牙扫描才会把它当输入设备看待。
      const advData: ble.AdvertiseData = {
        serviceUuids: [HID_SERVICE_UUID],
        manufactureData: [],
        serviceData: [],
        includeDeviceName: true
      } as ble.AdvertiseData;
      ble.startAdvertising(setting, advData);
      this.advertising = true;
    } catch (error) {
      const err = error as BusinessError;
      this.lastError = `开启蓝牙广播失败：${err.code} ${err.message}` +
        (err.code === 2902054 ? '（广播数据超长）' : '');
      this.advertising = false;
      this.cleanup();
      return false;
    }

    this.started = true;
    return true;
  }

  stop(): void {
    if (this.advertising) {
      try {
        ble.stopAdvertising();
      } catch (error) {
        const err = error as BusinessError;
        this.lastError = `停止蓝牙广播失败：${err.code} ${err.message}`;
      }
      this.advertising = false;
    }
    this.cleanup();
    this.started = false;
    this.connected = false;
    this.subscribed = 0;
    this.cccdValue = 0;
    this.lastWarning = '';
    this.clientId = '';
    this.clientName = '';
    this.clientConnectedAtMs = 0;
    this.pendingMouse = null;
    this.pendingKeyboard = null;
    this.mouseInFlight = false;
    this.keyboardInFlight = false;
  }

  private cleanup(): void {
    if (this.server !== null) {
      try {
        this.server.off('connectionStateChange');
        this.server.off('characteristicWrite');
        this.server.off('characteristicRead');
        this.server.off('descriptorRead');
        this.server.off('descriptorWrite');
        this.server.close();
      } catch (error) {
        const err = error as BusinessError;
        this.lastError = `关闭 GATT 服务失败：${err.code} ${err.message}`;
      }
      this.server = null;
    }
    this.serviceChars = 0;
  }

  // 注册后回读一次实际服务内容：鸿蒙的 GATT 栈若不允许同一服务下存在多个
  // 相同 UUID 的 Report 特征，这里拿到的数量就会明显偏少 —— 那是 HOGP 走不通的
  // 直接证据，必须能看见，而不是等到"iPhone 连上却不动"再猜。
  //
  // ★ 2026-09-21 重写：原来只有 getService() 一条路，且调用异常被 catch 成
  //   "0 个特征"，随后又被调用方的文案覆盖 ⇒ 界面上出现「特征数为 0（GATT 服务
  //   未被接受）」，而真相是**这个回读 API 在本机不可用**（getService/getServices
  //   是 @since 22 的新接口）。现在的规则（2026-09-21 第二次修正后）：
  //     · **两条路交叉印证**才允许下结论：`getService(uuid)` 精确查 + `getServices()`
  //       全量列出后按 UUID 忽略大小写比对。两条路都通、都看不到 HID 服务，才算
  //       "没注册"。★ 只凭 `getService` 的 2901008 就早退是错的 —— UUID 匹配口径
  //       由栈决定，假阴性长得和"没注册"一模一样（见 ERR_GATT_SERVICE_NOT_FOUND）。
  //     · 两条路都不通 / 调用不存在 = 探针坏了 → available=0，绝不当作"没注册"
  //     · attempts 记下试了几次（沉降重试的次数由调用方写回）。
  private probe_registered_service(server: ble.GattServer): GattReadback {
    const result: GattReadback = {
      available: 0,
      count: 0,
      serviceUuid: '',
      charUuids: '',
      descUuids: '',
      error: '',
      attempts: 1
    };

    // ── 第 1 手：按 UUID 精确查。只记录结果，**绝不早退**。 ────────────────
    let service: ble.GattService | null = null;
    let getServiceNote: string = '';
    try {
      service = server.getService(HID_SERVICE_UUID);
    } catch (error) {
      const err = error as BusinessError;
      getServiceNote = `getService(${HID_SERVICE_UUID}) → ${err.code} ${err.message}`;
    }

    // ── 第 2 手：全量列出 + 忽略大小写比对 ────────────────────────────────
    let enumerable: boolean = service !== null && service !== undefined;
    let enumerationError: string = '';
    if (!enumerable) {
      try {
        const all: ble.GattService[] = server.getServices();
        enumerable = true;
        const wanted: string = HID_SERVICE_UUID.toUpperCase();
        for (let i = 0; i < all.length; i++) {
          const candidate: ble.GattService = all[i];
          if (candidate.serviceUuid !== undefined && candidate.serviceUuid !== null
            && candidate.serviceUuid.toUpperCase() === wanted) {
            service = candidate;
            break;
          }
        }
      } catch (error) {
        const err = error as BusinessError;
        enumerationError = `getServices() → ${err.code} ${err.message}`;
      }
    }

    // ── 结论分级：只有"至少一条路能调通"才允许给出"服务不在"的结论 ────────
    if (service === null || service === undefined) {
      if (enumerable) {
        result.available = 1;                  // 探针可用
        result.count = 0;                      // 且确实看不到 HID 服务
        result.error = getServiceNote;         // 原样留证，不吞掉
        return result;
      }
      const previous: string = getServiceNote.length > 0 ? `${getServiceNote}；` : '';
      result.error = `${previous}${enumerationError}`;   // available 保持 0：探针坏了
      return result;
    }

    // 走到这里 service 必定非空（上面每条拿不到服务的路径都已 return 并定好结论）。
    // 仍显式判一次：ArkTS 的窄化不跨 try/catch，不判会在严格模式下报错。
    if (service === null || service === undefined) {
      return result;
    }
    const chars: ble.BLECharacteristic[] =
      service.characteristics !== undefined && service.characteristics !== null
        ? service.characteristics
        : [];
    const shortNames: string[] = [];
    for (let i = 0; i < chars.length; i++) {
      const uuid: string = chars[i].characteristicUuid;
      shortNames.push(uuid !== undefined && uuid !== null && uuid.length >= 8
        ? uuid.substring(4, 8)
        : '?');
    }
    // Report 特征身上的描述符短名（正常应含 2902 = CCCD，主机订阅要用它）。
    const descNames: string[] = [];
    for (let i = 0; i < chars.length; i++) {
      if (!same_uuid(chars[i].characteristicUuid, UUID_REPORT)) {
        continue;
      }
      const descriptors: ble.BLEDescriptor[] =
        chars[i].descriptors !== undefined && chars[i].descriptors !== null
          ? chars[i].descriptors
          : [];
      for (let d = 0; d < descriptors.length; d++) {
        descNames.push(short_uuid(descriptors[d].descriptorUuid));
      }
    }
    result.descUuids = descNames.join(',');
    result.available = 1;
    result.count = chars.length;
    result.serviceUuid = service.serviceUuid !== undefined && service.serviceUuid !== null
      ? service.serviceUuid
      : '';
    result.charUuids = shortNames.join(',');
    result.error = '';
    return result;
  }

  /**
   * 带沉降重试的回读（见 READBACK_SETTLE_* 常量）。
   *
   * 为什么要重试：`addService()` 是**跨进程**调用，服务在蓝牙服务进程里真正可查询
   * 与它返回之间没有同步保证。紧接着回读很容易拿到 2901008，若据此判定「服务未被
   * 接受」，就是**拿一次竞态当结论** —— 2026-09-21 用户截图里那句话的候选成因之一。
   *
   * 三级短路（顺序即优先级）：
   *   · 探针本身不可用（available=0）→ **立即返回**。重试不会让坏探针变好，
   *     白白让用户多等半秒；
   *   · 读到了（count>0）→ 立即返回。**成功路径零额外等待**；
   *   · 只有"探针可用但服务不在"才继续等 —— 这才是竞态该有的样子。
   */
  private async probe_registered_service_settled(
    server: ble.GattServer): Promise<GattReadback> {
    let last: GattReadback = this.probe_registered_service(server);
    for (let attempt = 2; attempt <= READBACK_SETTLE_ATTEMPTS; attempt++) {
      if (last.available === 0 || last.count > 0) {
        return last;
      }
      await delay_ms(READBACK_SETTLE_DELAY_MS);
      last = this.probe_registered_service(server);
      last.attempts = attempt;
    }
    return last;
  }

  // ── HID 服务定义 ──────────────────────────────────────────────────────────
  private build_service(): ble.GattService {
    const characteristics: ble.BLECharacteristic[] = [];

    // 1) HID Information：只读
    characteristics.push({
      serviceUuid: HID_SERVICE_UUID,
      characteristicUuid: UUID_HID_INFORMATION,
      characteristicValue: to_buffer(HID_INFORMATION),
      descriptors: [],
      properties: { read: true } as ble.GattProperties
    } as ble.BLECharacteristic);

    // 2) Report Map：只读。iOS 靠它知道每个 report 的字节布局，
    //    内容必须与后面 report 的实际打包方式严格一致。
    //
    //    ★ 2026-09-24：去掉此前挂在这里的 Report Reference(2908) 描述符。
    //    Report Reference 是**Report 特征专属**的（用来说明"这个特征承载哪个
    //    report id"），挂在 Report Map 上不合规范 —— 上游只给 Report 特征创建它
    //    （BluetoothHidMouseService.cs:736-748），这里照上游对齐，少一个多余差异。
    characteristics.push({
      serviceUuid: HID_SERVICE_UUID,
      characteristicUuid: UUID_REPORT_MAP,
      characteristicValue: to_buffer(HID_REPORT_MAP),
      descriptors: [],
      properties: { read: true } as ble.GattProperties
    } as ble.BLECharacteristic);

    // 3) HID Control Point：iOS 写 Suspend / Exit Suspend。
    //
    //    ★ 2026-09-24：属性放宽成 "写 + 免应答写" 两种都收。HOGP 规定它是
    //    Write Without Response，但主机实现不保证（上游 Windows 声明的是 Write，
    //    见 BluetoothHidMouseService.cs:676-679）。只声明其中一种时，另一种写法的
    //    ATT 请求会被栈直接拒掉 —— 而主机侧看到的只是"这个设备不好用"，
    //    我们这侧连回调都不会有。多声明一个开关没有副作用。
    characteristics.push({
      serviceUuid: HID_SERVICE_UUID,
      characteristicUuid: UUID_HID_CONTROL_POINT,
      characteristicValue: to_buffer([0x00]),
      descriptors: [],
      properties: { write: true, writeNoResponse: true } as ble.GattProperties
    } as ble.BLECharacteristic);

    // 4) Protocol Mode：可读可写（iOS 会写 1 = Report Protocol）。
    //    同上：两种写法都收（上游对它有 ReadRequested + WriteRequested 两个回调）。
    characteristics.push({
      serviceUuid: HID_SERVICE_UUID,
      characteristicUuid: UUID_PROTOCOL_MODE,
      characteristicValue: to_buffer([PROTOCOL_MODE_REPORT]),
      descriptors: [],
      properties: { read: true, write: true, writeNoResponse: true } as ble.GattProperties
    } as ble.BLECharacteristic);

    // 5) Report：**个数由布局决定**（见文件头的「HID 布局模式」）。
    if (this.layout === HID_LAYOUT_SINGLE) {
      // SINGLE（默认）：只建一个 Report 特征，Report Reference 的 Report ID = 0
      // —— 规范（HID Service 2.5.3.2）只在"同一 Report 类型存在多个实例"时才要求
      // Report ID 非零，只有一个实例时允许为 0。所有 report 共用这一个特征，
      // 靠**载荷首字节的 report id** 区分（真正的 report/Notify 协议模式）。
      // 关键收益：0x2A4D 只有一个实例 ⇒ `notifyCharacteristicChanged()` 按 UUID
      // 定位时没有第二个候选，投递落点确定。
      characteristics.push({
        serviceUuid: HID_SERVICE_UUID,
        characteristicUuid: UUID_REPORT,
        // 初始值取最长的那个 report（键盘 8 字节），全零。
        characteristicValue: to_buffer(this.empty_payload(REPORT_ID_KEYBOARD)),
        descriptors: [{
          serviceUuid: HID_SERVICE_UUID,
          characteristicUuid: UUID_REPORT,
          descriptorUuid: UUID_REPORT_REFERENCE,
          descriptorValue: report_reference(0, REPORT_TYPE_INPUT)
        } as ble.BLEDescriptor],
        properties: { read: true, notify: true } as ble.GattProperties
      } as ble.BLECharacteristic);
    } else {
      // MULTI：照抄上游 Windows 的 5 特征布局，Report ID 1/2/3/4/5 靠 Report
      // Reference 区分，载荷**不带** id。Windows 能工作是因为它的栈按特征对象
      // 投递；鸿蒙这条走不通（同 UUID 无法指定落点），保留它只作对照。
      const reports: number[] = [
        REPORT_ID_KEYBOARD, REPORT_ID_MOUSE, REPORT_ID_WHEEL_RESOLUTION,
        REPORT_ID_CONSUMER, REPORT_ID_NAVIGATION
      ];
      for (let i = 0; i < reports.length; i++) {
        const id = reports[i];
        const isFeature = id === REPORT_ID_WHEEL_RESOLUTION;
        const initial: number[] = isFeature ? [0x00] : this.empty_payload(id);
        characteristics.push({
          serviceUuid: HID_SERVICE_UUID,
          characteristicUuid: UUID_REPORT,
          characteristicValue: to_buffer(initial),
          descriptors: [{
            serviceUuid: HID_SERVICE_UUID,
            characteristicUuid: UUID_REPORT,
            descriptorUuid: UUID_REPORT_REFERENCE,
            descriptorValue: report_reference(id, isFeature ? REPORT_TYPE_FEATURE : REPORT_TYPE_INPUT)
          } as ble.BLEDescriptor],
          properties: isFeature
            ? { read: true } as ble.GattProperties
            : { read: true, notify: true } as ble.GattProperties
        } as ble.BLECharacteristic);
      }
    }

    const service: ble.GattService = {
      serviceUuid: HID_SERVICE_UUID,
      isPrimary: true,
      characteristics: characteristics
    };
    return service;
  }

  // 各 report 的初始（全零）载荷长度 —— 必须与 Report Map 声明的尺寸一致
  private empty_payload(report_id: number): number[] {
    if (report_id === REPORT_ID_KEYBOARD) {
      return [0, 0, 0, 0, 0, 0, 0, 0];
    }
    if (report_id === REPORT_ID_MOUSE) {
      return [0, 0, 0, 0, 0, 0];
    }
    if (report_id === REPORT_ID_CONSUMER) {
      return [0, 0];
    }
    return [0, 0];
  }

  private payload_size(report_id: number): number {
    if (report_id === REPORT_ID_KEYBOARD) {
      return 8;
    }
    if (report_id === REPORT_ID_MOUSE) {
      return 6;
    }
    return 2;
  }

  // ── 发送 ──────────────────────────────────────────────────────────────────

  // 发送一个 report。返回 false 表示"没送出去"，但**不阻塞调用方**：
  // 输入事件在 UI 线程上，await 一个蓝牙写会卡住界面。
  private notify(report_id: number, payload: number[]): void {
    const server = this.server;
    if (server === null || !this.connected || this.clientId === '') {
      this.mouseDropped++;
      return;
    }
    const expected = this.payload_size(report_id);
    if (payload.length !== expected) {
      // 长度不对就是组包 bug，绝不能"照发"——iOS 会按 Report Map 解析出乱码。
      this.lastNotifyError = `report ${report_id} 载荷长度 ${payload.length} ≠ ${expected}`;
      this.notifyFailures++;
      return;
    }
    // 线格式：SINGLE 布局要在最前面补一个 report id 字节（详见文件头「HID 布局模式」）。
    // 补在**长度校验之后** —— 校验的是"纯 report 内容"的长度，两件事不要混。
    const wire: number[] = [];
    if (this.layout === HID_LAYOUT_SINGLE) {
      wire.push(report_id & 0xFF);
    }
    for (let i = 0; i < payload.length; i++) {
      wire.push(payload[i]);
    }
    const characteristic: ble.NotifyCharacteristic = {
      serviceUuid: HID_SERVICE_UUID,
      characteristicUuid: UUID_REPORT,
      characteristicValue: to_buffer(wire),
      // 通知不需要对端确认：HID report 是"发了就完"，等 ACK 会把输入延迟堆起来。
      confirm: false
    };
    // Report 特征是可读的（HOGP 允许主机来读"当前值"）⇒ 把最近一次线格式留一份，
    // 让 onCharacteristicRead 答得出东西。留的是**线格式**（SINGLE 已含 id 字节），
    // 因为主机读的就是特征值本身。
    this.reportValue = characteristic.characteristicValue;
    try {
      const pending = server.notifyCharacteristicChanged(this.clientId, characteristic);
      pending.then((): void => {
        if (report_id === REPORT_ID_MOUSE) {
          this.mouseReports++;
        } else if (report_id === REPORT_ID_KEYBOARD) {
          this.keyboardReports++;
        } else if (report_id === REPORT_ID_CONSUMER) {
          this.consumerReports++;
        } else if (report_id === REPORT_ID_NAVIGATION) {
          this.navReports++;
        }
      }).catch((error: BusinessError): void => {
        this.notifyFailures++;
        this.lastNotifyError = `report ${report_id} 发送失败：${error.code} ${error.message}`;
      });
    } catch (error) {
      const err = error as BusinessError;
      this.notifyFailures++;
      this.lastNotifyError = `report ${report_id} 发送异常：${err.code} ${err.message}`;
    }
  }

  // 鼠标。dx/dy 是**相对位移**（iOS 蓝牙鼠标只看相对量），wheel 为滚动格数。
  sendMouse(buttons: number, dx: number, dy: number, wheel: number): void {
    if (!this.started) {
      return;
    }
    if (this.connected && this.clientId !== '') {
      const now = Date.now();
      // 看门狗：上一次通知卡住超过 500ms 就复位在途标志，否则鼠标僵死
      if (this.mouseInFlight && now - this.mouseFlightStart > NOTIFY_WATCHDOG_MS) {
        this.notifyTimeouts++;
        this.mouseInFlight = false;
      }
      if (this.pendingMouse === null) {
        this.pendingMouse = { buttons: buttons, dx: dx, dy: dy, wheel: wheel };
      } else {
        const merged: MouseReport = this.pendingMouse;
        merged.buttons = buttons;
        merged.dx += dx;
        merged.dy += dy;
        merged.wheel += wheel;
        this.pendingMouse = merged;
      }
      if (!this.mouseInFlight) {
        this.flush_mouse();
      }
      return;
    }
    this.mouseDropped++;
  }

  private flush_mouse(): void {
    const report = this.pendingMouse;
    if (report === null) {
      return;
    }
    this.pendingMouse = null;
    this.mouseInFlight = true;
    this.mouseFlightStart = Date.now();
    // 16 位有符号小端
    const x = report.dx < -32768 ? -32768 : (report.dx > 32767 ? 32767 : report.dx);
    const y = report.dy < -32768 ? -32768 : (report.dy > 32767 ? 32767 : report.dy);
    const wheel = report.wheel < -127 ? -127 : (report.wheel > 127 ? 127 : report.wheel);
    const payload: number[] = [
      report.buttons & 0xFF,
      x & 0xFF, (x >> 8) & 0xFF,
      y & 0xFF, (y >> 8) & 0xFF,
      wheel & 0xFF
    ];
    this.notify(REPORT_ID_MOUSE, payload);
    // 通知是异步的，这里立刻放行后续合并 —— 真正的节流靠"只留最新一帧"，
    // 而不是靠等待。等待会把输入延迟堆起来，那正是上游要避免的。
    this.mouseInFlight = false;
  }

  // 键盘。usages 最多 6 个（Report Map 里就是 6 个 usage 数组元素）。
  sendKeyboard(modifiers: number, usages: number[]): void {
    if (!this.started || !this.connected || this.clientId === '') {
      return;
    }
    const now = Date.now();
    if (this.keyboardInFlight && now - this.keyboardInFlightStart > NOTIFY_WATCHDOG_MS) {
      this.notifyTimeouts++;
      this.keyboardInFlight = false;
    }
    this.pendingKeyboard = { modifiers: modifiers, usages: usages };
    if (!this.keyboardInFlight) {
      this.flush_keyboard();
    }
  }

  private flush_keyboard(): void {
    const report = this.pendingKeyboard;
    if (report === null) {
      return;
    }
    this.pendingKeyboard = null;
    this.keyboardInFlight = true;
    this.keyboardInFlightStart = Date.now();
    const payload: number[] = [report.modifiers & 0xFF, 0x00, 0, 0, 0, 0, 0, 0];
    let index = 2;
    for (let i = 0; i < report.usages.length && i < 6; i++) {
      payload[index] = report.usages[i] & 0xFF;
      index++;
    }
    this.notify(REPORT_ID_KEYBOARD, payload);
    this.keyboardInFlight = false;
  }

  // 释放所有按键（断开/关闭反控时必须发，否则 iPhone 上会留着按住的键）
  releaseAll(): void {
    if (!this.started || !this.connected || this.clientId === '') {
      return;
    }
    this.notify(REPORT_ID_MOUSE, [0, 0, 0, 0, 0, 0]);
    this.notify(REPORT_ID_KEYBOARD, [0, 0, 0, 0, 0, 0, 0, 0]);
  }

  // Consumer（媒体/系统键）：16 位 usage 小端，松开时送 0
  sendConsumer(usage: number): void {
    if (!this.started) {
      return;
    }
    this.notify(REPORT_ID_CONSUMER, [usage & 0xFF, (usage >> 8) & 0xFF]);
  }

  // Navigation（返回/主屏/搜索）：0x10 位掩码，见 NAV_* 常量
  sendNavigation(mask: number): void {
    if (!this.started) {
      return;
    }
    this.notify(REPORT_ID_NAVIGATION, [mask & 0xFF, (mask >> 8) & 0xFF]);
  }

  // 鼠标通知超时口径（上游 80ms / 键盘 2s）—— 供调用方做节流参考，
  // 数值来源：BluetoothHidMouseService.cs:32-36
  static mouseTimeoutMs(): number {
    return MOUSE_NOTIFY_TIMEOUT_MS;
  }

  static keyboardTimeoutMs(): number {
    return KEYBOARD_NOTIFY_TIMEOUT_MS;
  }
}
