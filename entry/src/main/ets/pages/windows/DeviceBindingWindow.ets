// DeviceBindingWindow.ets —— 子窗口：设备绑定器（USB / AirPlay / Bluetooth 身份绑定）
//
// 逐项对照上游 src/App/Windows/DeviceBindingWindow.xaml（27 行，单行压缩排版）
//              src/App/Windows/DeviceBindingWindow.xaml.cs（238 行）
//
// ⚠ 这个窗口**只有 main 1.8.4 有**，linux-port 1.8.1 完全没有（连同
//   DeviceBindingManager / DeviceIdentityResolver / WifiSyncInsertionTracker
//   三个服务一起缺失）。所以本文件补的不只是一个页面，而是这一整套「设备档案」
//   功能缺口在鸿蒙侧的第一版实现。
//
// ── 窗口属性（XAML 根元素 <ui:FluentWindow> 那一行）──────────────────────────
//   Title="{DynamicResource DeviceBindingTitle}"      → 「设备绑定器」
//   Width="1040" Height="720"                         → SubWindowSpec 1040×720
//   MinWidth="900" MinHeight="600"                    → minWidth/minHeight
//   WindowStartupLocation="CenterOwner"               → SubWindowHost.open 里算居中
//   ExtendsContentIntoTitleBar="True"                 → decorEnabled: false + 自绘表头
//   WindowBackdropType="Mica" WindowCornerPreference="Round" → 由系统窗口负责
//   Background="{DynamicResource AppBackgroundBrush}" → shellBackground 用默认 APP_BACKGROUND
//   没有 ResizeMode → WPF 默认 CanResize                 → resizable: true
//   调用点（MainWindow.xaml.cs:1607）是 window.Show()  → modal: false（非模态）
//
// ── 行定义（3 行）───────────────────────────────────────────────────────────
//   Row Auto : SubWindowHeader（MinHeight 44）+ SubWindowTitle + SubWindowSubtitle
//              + SubWindowCloseButton（Dismiss20/18，Click=CloseClick）
//   Row 16   : 间隔                                        → shell 的 gap
//   Row *    : Grid 两列 = 270 / 16 / *                     → content
//
// ── 左栏（列 0，270）────────────────────────────────────────────────────────
//   Border ControlFillBrush 底 / BorderBrush 1px / 圆角 10 / Padding 12
//     Grid 两行 = Auto / *
//       行 0：Grid
//         TextBlock「我的设备档案」FontSize 16 SemiBold Margin 4,2,4,12
//         Button Style=IconButton 靠右靠上（Add20 / 18）
//              ToolTip=DeviceBindingAddProfileToolTip「添加 AirPlay 设备档案」
//       行 1：ListBox（透明底 / 无边框 / ItemsSource=Profiles / 双向选中）
//         条目容器：ControlFillBrush 底 / BorderBrush 1px / 圆角 8 / Padding 12 /
//                   Margin 0,0,0,8；IsMouseOver → ControlHoverBrush；
//                   IsSelected → ComboItemSelectedBrush + AccentBrush 边框
//         条目模板：TextBlock 设备名（SemiBold / 字符省略）
//                   TextBlock 型号（FontSize 11 / Muted / Margin 0,4,0,0 / 字符省略）
//         条目右键菜单（ProfileContextMenu）：重命名档案 / 删除档案
//
// ── 右栏（列 2，*）──────────────────────────────────────────────────────────
//   Border ControlFillBrush 底 / BorderBrush 1px / 圆角 10 / Padding 22
//     ScrollViewer（纵向自动）
//       StackPanel
//         TextBlock ProfileTitle（FontSize 21 SemiBold）
//         TextBlock 为此档案选择并管理三种连接身份。（Muted 11 / Margin 0,5,0,0）
//         Grid Margin 0,16,0,0  行 = Auto / 16 / Auto   列 = * / 16 / *
//           (0,0) 有线 USB 卡    (0,2) AirPlay 卡
//           (2,0) colspan 3  Bluetooth 卡
//           卡片样式 BindingSectionCard：ControlFillBrush 底 / BorderBrush 1px /
//                                       圆角 8 / Padding 14
//           卡内（三种卡结构一致）：
//             TextBlock 标题（BindingSectionTitle：FontSize 14 SemiBold）
//             TextBlock 状态（Margin 0,7,0,0）
//             TextBlock 身份（Consolas / 11 / Muted / Margin 0,3,0,0）
//             TextBlock 说明（Wrap / 11 / Muted / Margin 0,10,0,0）
//             【已绑定】ComboBox ItemsSource=Profiles / SelectedItem=SelectedProfile /
//                      IsEnabled=False（BoundWiredSelector / BoundAirPlaySelector）
//             【未绑定】ComboBox ItemsSource=WiredDevices|AirPlayDevices /
//                      IsEnabled=CanEditWired|CanEditAirPlay / Margin 0,10,0,0
//             按钮行（Margin 0,10,0,0；Bluetooth 卡是 0,12,0,0）：
//               「绑定选择设备」IsEnabled=CanBindWired|CanBindAirPlay，Padding 12,7
//               「解绑」Margin 8,0,0,0，Padding 12,7
//               蓝牙卡是「连接设备」+「解绑」
//
// ── 文案来源 Strings.zh-CN.xaml（逐字取用）────────────────────────────────
//   DeviceBindingTitle/Subtitle/Profiles/AddProfileToolTip
//   DeviceBindingRenameProfile/DeleteProfile/SelectProfile/ProfileDescription
//   DeviceBindingWired/AirPlay/Bluetooth（+ 各自的 Description）
//   DeviceBindingBind/Unbind/Connect
//   DeviceBindingBound/BoundConnected/BoundMirroring/BoundUnavailable/BoundDisconnected
//   DeviceBindingModelUnknown/UnnamedDevice/CreateFailed
//   DeviceBindingRenamePrompt/RenameTitle/DeleteConfirmation/DeleteTitle
//   DeviceBindingConfirmTitle/ConfirmBodyFormat
//   DeviceBindingUsbOrAirPlayRequired/BluetoothStartFailed/BluetoothSaveFailed
//   DeviceBindingIdentityRequired/IdentityAlreadyBound/ProfileNotFound/
//   IdentityBoundElsewhere/IncompatibleModel/CompatibleNeedsConfirmation/
//   UnknownNeedsConfirmation
//
// ── 关联服务（main 版独有，逐条注明搬到哪里 / 为什么搬不动）────────────────────
//   ① src/App/Services/DeviceBindingManager.cs
//      · Profile / WiredDeviceIdentity / AirPlayDeviceIdentity /
//        BluetoothDeviceIdentity / DeviceFingerprint 五个 record
//        → 本文件合成一个 BindingProfile（身份为空串即「未绑定」，等价于原版的 null）。
//      · CreateProfileFromIdentity / Bind / Unbind / FindByIdentity /
//        ValidateCompatibility 的全部判定（身份重复、型号 Incompatible、
//        Compatible/Unknown 需用户确认）→ binding_create / binding_bind / binding_unbind。
//      · 持久化：原版写 %LOCALAPPDATA%\iPhoneMirror\device-binding-profiles.json
//        （tmp + File.Move 原子写）。鸿蒙侧**不新增文件写逻辑**，改存 AppStorage
//        （键 PROFILES_KEY）—— 与本项目 AdvancedSettingsWindow / AboutWindow 的
//        平台替换 9 完全同一套路，注释里也按同样口径写明。
//   ② src/App/Services/DeviceIdentityResolver.cs
//      · ResolveProfile(device)：IsWireless ? AirPlay : Wired，按 Udid 找档案，
//        找不到是 BindingRequired（明确「从不猜测」）。
//        → 本文件 resolve_profile()，用在「当前设备是否已绑定」的判断上，
//          与 IsWiredConnected / IsAirPlayCurrent 同源。
//   ③ src/App/Services/WifiSyncInsertionTracker.cs
//      · Observe()：每次「连续可信的 USB 插入」只发一次配网目标；未授信设备保持
//        候选；拔线重置。这是**无线配网**侧的发射器，本窗口只做它的前置动作
//        「已连接 USB 设备自动建档案」（CreateProfilesForConnectedUsbDevices，
//        本文件 create_profiles_for_wired_devices）。配网目标发射属于网络栈，不搬，
//        仅在此注明，避免被当成遗漏。
//
// ── 平台替换（原版机制在鸿蒙没有对应物，逐条列出）──────────────────────────
//   1. 【数据来源】原版构造参数是 ObservableCollection<DeviceViewModel>（主窗口的
//      实时设备列表 + CollectionChanged 订阅）。鸿蒙子窗口拿不到构造参数，改为
//      开窗入口 open_device_binding(ctx, devices) 注入（模块级 + AppStorage 双写），
//      aboutToAppear 取走。**不调用任何 NAPI**：设备身份列表是调用方给的本地状态，
//      没有注入时列表为空并在界面上明说，绝不伪造设备。
//   2. 【ListBox 右键菜单】原版 ContextMenu + MenuItem（重命名 / 删除）。鸿蒙长按
//      菜单（bindContextMenu）在本工程的其它窗口里没有先例，为免引入未验证的交互，
//      改成「选中后在该条目右侧露出两个图标按钮（重命名 / 删除）」，功能与文案不变。
//   3. 【InputBox】原版重命名走 Microsoft.VisualBasic.Interaction.InputBox。
//      鸿蒙没有输入框弹窗 → 右栏标题处就地展开一个 RoundedTextBox + 「保存 / 取消」。
//   4. 【MessageBox】原版删除前是 MessageBox(YesNo, Warning)。鸿蒙 MessageBox 需要
//      promptAction.showDialog（会盖一层系统弹窗，与原版风格不一致）→ 改成两段式
//      确认：点「删除」变成「确认删除？」，再点一次才真的删。确认文案
//      DeviceBindingDeleteConfirmation 原样显示在下方。
//   5. 【ComboBox】→ ArkUI 的 Select（与开发者工具窗口同一处理）。
//      BoundWiredSelector / BoundAirPlaySelector 两个「已绑定」下拉在原版里是
//      IsEnabled=False 且 ItemsSource=Profiles，语义上只是「展示当前档案名」，
//      这里保留同样的禁用下拉，选项取档案列表。
//   6. 【蓝牙连接】原版 ConnectBluetoothClick（xaml.cs:140-176）是「临时开一次 BLE HID
//      广播 → 等 iPhone 配对 → 保存绑定 → 无论成没成，都把这次广播收掉」。
//      本移植**已完整实现**，三段逐行对应，见 on_connect_bluetooth /
//      finish_bluetooth_configuration：
//        · StartBluetoothPeripheralForConfigurationAsync(target)
//          = BluetoothHidPeripheral.start(ctx)（**异步**：它内部要先做蓝牙权限的
//            运行时申请 —— ACCESS_BLUETOOTH 是 user_grant，只声明不上报就是 201）。
//            注意上游这个方法落到
//            EnableBluetoothControlAsync(target, fromReverseControl: true,
//            configurationOnly: true)，configurationOnly 让
//            `_bluetoothControlInputEnabled` 恒为 false —— 也就是**只广播、不接管输入**；
//            这里同样不碰 ReverseControlInput，语义一致。
//        · BluetoothConnectionWindow.Show(owner, profileName, refresh, unbind)
//          = open_bluetooth_connection(ctx, 档案显示名, 回调)。那个窗口已接真数据
//            （实时读 GATT 连接状态、真枚举客户端），不是空壳。
//        · 尾部 StopBluetoothPeripheralConfigurationAsync() + RefreshBluetoothClientsAsync()
//          = hid.stop() + 重算蓝牙状态行。★ 偏离：上游这两个是**无条件**执行的
//            （会顺手掐掉用户在主窗口开的反控），本移植按「不收自己没开的东西」
//            的纪律只收自己这次开的；确切成因写在 finish_bluetooth_configuration 的注释里。
//      ★ 这里此前写的是「鸿蒙不支持 BLE 外设模式（无 GATT Server、不能广播），
//        于是走原版启动失败分支、不打开等待窗口」——**那是错的，已作废**。
//      蓝牙客户端列表也不再恒空：GATT 连接本身就是真实来源
//      （BluetoothHidPeripheral.connectedClients()）。
//   7. 【添加 AirPlay 档案】原版 AddAirPlayProfileClick 打开
//      AirPlayDeviceSelectionWindow.Show(this, AirPlayDevices)。
//      本工程**确有**这个页面 → 真打开（open_airplay_device_selection），
//      选中后按原版 CreateProfile 建档案。列表为空时明说并直接返回。
//   8. 【Consolas】等宽字体 → 'monospace'（与 StartupErrorWindow 一致）。
//
// ── 不做假成功 ─────────────────────────────────────────────────────────────
//   注入的设备列表为空 → 界面明说「调用方未注入设备列表」；蓝牙连接做不到 → 明说
//   并给出原版失败文案；绑定被拒 → 原样显示 DeviceBindingManager 的拒绝理由。

import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import window from '@ohos.window';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  SubWindowShell, SubWindowHost, RoundedTextBox, hint_text,
  SubWindowSpec,
} from '../../common/SubWindow';
import {
  TEXT, MUTED_TEXT, BORDER, CONTROL_FILL, CONTROL_HOVER,
  COMBO_ITEM_SELECTED, ACCENT, ERROR,
} from '../../common/Theme';
import { FluentSymbol } from '../../common/FluentIcon';
import { DeviceViewModel } from '../../common/DeviceViewModel';
import { open_airplay_device_selection } from './AirPlayDeviceSelectionWindow';
// 平台替换 6（已实现）：BLE HID 外设（同时也是主窗口「蓝牙反向控制」用的那一个单例）
// 与「等待 HID 连接」子窗口。上游用的是同一个 _bluetoothControl 实例，这里也一样。
import { BluetoothHidPeripheral, BluetoothHidClient } from '../../common/BluetoothHidPeripheral';
import {
  open_bluetooth_connection, WINDOW_NAME as BLUETOOTH_CONNECTION_WINDOW_NAME,
} from './BluetoothConnectionWindow';

const TAG: string = 'im_device_binding';
const DOMAIN: number = 0x0100;

/** 窗口名 —— 用 XAML 的类名，window.findWindow 也用它。 */
export const WINDOW_NAME: string = 'DeviceBindingWindow';
/** 页面路径。 */
export const PAGE_PATH: string = 'pages/windows/DeviceBindingWindow';

/** 原版构造参数的替代通道（平台替换 1）。 */
export const ARG_KEY_DEVICE_COUNT: string = 'im.deviceBinding.deviceCount';
/** 服务 ① 的持久化替代：档案列表（进程内）。 */
export const PROFILES_KEY: string = 'im.deviceBinding.profiles';

// ───────────────────── Strings（逐键标注） ─────────────────────

const S_TITLE: string = '设备绑定器';                          // DeviceBindingTitle
const S_SUBTITLE: string = '以真实设备档案管理 USB、AirPlay 和 Bluetooth 身份绑定。'; // DeviceBindingSubtitle
const S_PROFILES: string = '我的设备档案';                     // DeviceBindingProfiles
const S_ADD_TOOLTIP: string = '添加 AirPlay 设备档案';          // DeviceBindingAddProfileToolTip
const S_RENAME: string = '重命名档案';                         // DeviceBindingRenameProfile
const S_DELETE: string = '删除档案';                           // DeviceBindingDeleteProfile
const S_SELECT_PROFILE: string = '选择设备档案';                // DeviceBindingSelectProfile
const S_PROFILE_DESC: string = '为此档案选择并管理三种连接身份。'; // DeviceBindingProfileDescription
const S_WIRED: string = '有线 USB';                            // DeviceBindingWired
const S_AIRPLAY: string = 'AirPlay';                           // DeviceBindingAirPlay
const S_BLUETOOTH: string = 'Bluetooth';                      // DeviceBindingBluetooth
const S_WIRED_DESC: string =
  '使用数据线连接 iPhone/iPad，解锁设备并在提示时选择“信任”。已连接的 USB 设备会自动建立档案；' +
  '如需为当前档案更换有线身份，可在下方选择后绑定。';            // DeviceBindingWiredDescription
const S_AIRPLAY_DESC: string =
  '请让手机与电脑处于同一局域网，在 iPhone/iPad 打开“控制中心”→“屏幕镜像”，选择 iPhoneMirror。' +
  '镜像建立后会出现在下方列表；选择它并绑定到此档案。';          // DeviceBindingAirPlayDescription
const S_BLUETOOTH_DESC: string =
  '点击“连接设备”后，电脑会临时广播 Bluetooth HID 服务。请在 iPhone/iPad 的“设置”→“蓝牙”中' +
  '选择此电脑完成配对，再点击等待窗口中的“下一步”选择 HID 设备。' +
  '完成后只保存绑定，不会启动反控。';                            // DeviceBindingBluetoothDescription
const S_BIND: string = '绑定选择设备';                          // DeviceBindingBind
const S_UNBIND: string = '解绑';                               // DeviceBindingUnbind
const S_CONNECT: string = '连接设备';                           // DeviceBindingConnect
const S_BOUND_NONE: string = '未绑定';                          // DeviceBindingBound
const S_BOUND_CONNECTED: string = '已绑定 · 已连接';             // DeviceBindingBoundConnected
const S_BOUND_MIRRORING: string = '已绑定 · 当前镜像';           // DeviceBindingBoundMirroring
const S_BOUND_UNAVAILABLE: string = '已绑定 · 当前不可用';       // DeviceBindingBoundUnavailable
const S_BOUND_DISCONNECTED: string = '已绑定 · 已断开';          // DeviceBindingBoundDisconnected
const S_MODEL_UNKNOWN: string = '型号信息待获取';                // DeviceBindingModelUnknown
const S_UNNAMED: string = '未命名设备';                         // DeviceBindingUnnamedDevice
const S_CREATE_FAILED: string = '无法创建设备档案。';            // DeviceBindingCreateFailed
const S_RENAME_PROMPT: string = '输入设备档案名称';              // DeviceBindingRenamePrompt
const S_DELETE_CONFIRMATION: string =
  '删除该设备档案将解除所有已绑定的 USB、AirPlay 和 Bluetooth 身份。是否继续？'; // DeviceBindingDeleteConfirmation
const S_DELETE_CONFIRM: string = '确认删除？';
const S_CANCEL: string = '取消';                                // DeviceBindingCancel
const S_SAVE: string = '应用';                                  // Apply
const S_USB_OR_AIRPLAY_REQUIRED: string = '请先为该档案绑定 USB 或 AirPlay 设备。'; // DeviceBindingUsbOrAirPlayRequired
const S_BLUETOOTH_START_FAILED: string = '无法启动 Bluetooth HID 连接。请确认电脑蓝牙已开启。'; // DeviceBindingBluetoothStartFailed

/** DeviceBindingManager 的拒绝理由（Strings 原文）。 */
const S_ERR_IDENTITY_REQUIRED: string = '设备身份不能为空。';              // DeviceBindingIdentityRequired
const S_ERR_ALREADY_BOUND: string = '该设备身份已经绑定到设备档案。';       // DeviceBindingIdentityAlreadyBound
const S_ERR_BOUND_ELSEWHERE: string = '该设备身份已绑定到另一台设备档案。';  // DeviceBindingIdentityBoundElsewhere
const S_ERR_PROFILE_NOT_FOUND: string = '设备档案不存在。';                // DeviceBindingProfileNotFound
const S_ERR_INCOMPATIBLE: string = '检测到的设备型号不一致，无法绑定。';    // DeviceBindingIncompatibleModel
const S_ERR_NEEDS_CONFIRM: string = '设备型号一致，需要用户确认。';         // DeviceBindingCompatibleNeedsConfirmation
const S_ERR_UNKNOWN_CONFIRM: string = '无法自动验证设备型号，需要用户确认。'; // DeviceBindingUnknownNeedsConfirmation

/**
 * 保存蓝牙绑定失败时的兜底文案。
 *
 * ★ 这里原来放的是 `S_REASON_BLUETOOTH`（「鸿蒙不支持 BLE 外设模式…」）——**已作废**，
 *   那是错的：BLE HID 外设本移植已经做出来了（common/BluetoothHidPeripheral.ets）。
 *   现在蓝牙连接的失败原因是**真的启动失败**，而且原因由 `hid.errorText()` 原样给出
 *   （最常见的是 801 设备不支持 BLE 外设角色），不需要再编一段"平台不支持"的解释。
 */
const S_BLUETOOTH_SAVE_FAILED: string = '无法保存 Bluetooth 设备绑定。'; // DeviceBindingBluetoothSaveFailed
/** 下拉框在空列表时的占位项（原版此时 ComboBox 是空的）。 */
const S_NO_OPTION: string = '（没有可选项）';

/** 平台替换 1：没有注入设备列表时的说明。 */
const S_REASON_NO_DEVICES: string =
  '调用方未注入设备列表（原版是主窗口的实时 ObservableCollection<DeviceViewModel>）。' +
  '本窗口不调用任何 NAPI 自行发现设备，因此此处为空。';

// ───────────────────── 服务 ①：档案模型与判定 ─────────────────────

/**
 * DeviceBindingManager 的 DeviceBindingProfile + 三个 Identity record。
 * 身份字段为空串 = 原版的 null（未绑定）。
 */
export class BindingProfile {
  id: string = '';
  displayName: string = '';
  /** DeviceFingerprint.ProductType —— 兼容性比对只用这一个字段（与原版一致）。 */
  productType: string = '';
  wiredUdid: string = '';
  wiredName: string = '';
  airPlayId: string = '';
  airPlayName: string = '';
  bluetoothId: string = '';
  bluetoothName: string = '';

  constructor(id: string, displayName: string, productType: string) {
    this.id = id;
    this.displayName = displayName;
    this.productType = productType;
  }
}

/** 原版 BindIdentityResult / CreateProfileResult 的合并（都只要 success + error）。 */
export class BindingResult {
  success: boolean = false;
  error: string = '';

  constructor(success: boolean, error: string) {
    this.success = success;
    this.error = error;
  }
}

/** 原版 DeviceIdentityType。 */
export enum DeviceIdentityType {
  Wired = 0,
  AirPlay = 1,
  Bluetooth = 2,
}

function same_id(left: string, right: string): boolean {
  return left.length > 0 && right.length > 0 && left.toLowerCase() === right.toLowerCase();
}

function stable_id_of(profile: BindingProfile, type: DeviceIdentityType): string {
  if (type === DeviceIdentityType.Wired) {
    return profile.wiredUdid;
  }
  return type === DeviceIdentityType.AirPlay ? profile.airPlayId : profile.bluetoothId;
}

/** DeviceBindingManager.Matches */
function matches(profile: BindingProfile, type: DeviceIdentityType, id: string): boolean {
  return same_id(stable_id_of(profile, type), id);
}

/** DeviceBindingManager.ValidateCompatibilityUnsafe —— 只比 ProductType。 */
function compatibility_of(profile: BindingProfile, candidateType: string): number {
  // 0 = Confirmed（同一个身份），1 = Compatible，2 = Incompatible，3 = Unknown
  if (profile.productType.length === 0 || candidateType.length === 0) {
    return 3;
  }
  return same_id(profile.productType, candidateType) ? 1 : 2;
}

/** DeviceBindingManager.CreateProfileFromIdentity 的等价实现（不含磁盘持久化）。 */
function binding_create(profiles: BindingProfile[], displayName: string,
                        type: DeviceIdentityType, stableId: string,
                        productType: string): BindingResult {
  if (stableId.length === 0) {
    return new BindingResult(false, S_ERR_IDENTITY_REQUIRED);
  }
  for (let index: number = 0; index < profiles.length; ++index) {
    if (matches(profiles[index], type, stableId)) {
      return new BindingResult(false, S_ERR_ALREADY_BOUND);
    }
  }
  const profile: BindingProfile = new BindingProfile(
    'p' + Date.now().toString() + profiles.length.toString(),
    displayName.trim(), productType);
  if (type === DeviceIdentityType.Wired) {
    profile.wiredUdid = stableId;
    profile.wiredName = displayName;
  } else if (type === DeviceIdentityType.AirPlay) {
    profile.airPlayId = stableId;
    profile.airPlayName = displayName;
  } else {
    profile.bluetoothId = stableId;
    profile.bluetoothName = displayName;
  }
  profiles.push(profile);
  return new BindingResult(true, '');
}

/**
 * DeviceBindingManager.Bind —— 原版在 Compatible / Unknown 且未确认时**拒绝**，
 * 让用户确认后再调一次（userConfirmed: true）。本窗口没有二次确认弹窗（平台替换 4），
 * 所以确认动作由「再点一次绑定」承担：第一次给出需要确认的理由并要求再点一次。
 */
function binding_bind(profiles: BindingProfile[], profileId: string,
                      type: DeviceIdentityType, stableId: string,
                      deviceName: string, productType: string,
                      userConfirmed: boolean): BindingResult {
  if (stableId.length === 0) {
    return new BindingResult(false, S_ERR_IDENTITY_REQUIRED);
  }
  let target: BindingProfile | null = null;
  for (let index: number = 0; index < profiles.length; ++index) {
    if (profiles[index].id === profileId) {
      target = profiles[index];
      break;
    }
  }
  if (target === null) {
    return new BindingResult(false, S_ERR_PROFILE_NOT_FOUND);
  }
  for (let index: number = 0; index < profiles.length; ++index) {
    const other: BindingProfile = profiles[index];
    if (other.id !== profileId && matches(other, type, stableId)) {
      return new BindingResult(false, S_ERR_BOUND_ELSEWHERE);
    }
  }
  const profile: BindingProfile = target;
  if (matches(profile, type, stableId)) {
    return new BindingResult(true, '');
  }
  const compatibility: number = compatibility_of(profile, productType);
  if (compatibility === 2) {
    return new BindingResult(false, S_ERR_INCOMPATIBLE);
  }
  if (!userConfirmed) {
    return new BindingResult(false,
      compatibility === 1 ? S_ERR_NEEDS_CONFIRM : S_ERR_UNKNOWN_CONFIRM);
  }
  if (type === DeviceIdentityType.Wired) {
    profile.wiredUdid = stableId;
    profile.wiredName = deviceName;
  } else if (type === DeviceIdentityType.AirPlay) {
    profile.airPlayId = stableId;
    profile.airPlayName = deviceName;
  } else {
    profile.bluetoothId = stableId;
    profile.bluetoothName = deviceName;
  }
  if (profile.productType.length === 0) {
    profile.productType = productType;
  }
  return new BindingResult(true, '');
}

/** DeviceBindingManager.Unbind。 */
function binding_unbind(profiles: BindingProfile[], profileId: string,
                        type: DeviceIdentityType): boolean {
  for (let index: number = 0; index < profiles.length; ++index) {
    if (profiles[index].id !== profileId) {
      continue;
    }
    if (type === DeviceIdentityType.Wired) {
      profiles[index].wiredUdid = '';
      profiles[index].wiredName = '';
    } else if (type === DeviceIdentityType.AirPlay) {
      profiles[index].airPlayId = '';
      profiles[index].airPlayName = '';
    } else {
      profiles[index].bluetoothId = '';
      profiles[index].bluetoothName = '';
    }
    return true;
  }
  return false;
}

/** 服务 ②：DeviceIdentityResolver.ResolveProfile —— 「映射到真实档案，从不猜测」。 */
function resolve_profile(profiles: BindingProfile[], device: DeviceViewModel): BindingProfile | null {
  const type: DeviceIdentityType = device.is_wireless()
    ? DeviceIdentityType.AirPlay : DeviceIdentityType.Wired;
  for (let index: number = 0; index < profiles.length; ++index) {
    if (matches(profiles[index], type, device.udid)) {
      return profiles[index];
    }
  }
  return null;
}

// ───────────────────── 开窗入口（平台替换 1） ─────────────────────

/** 原版 internal DeviceBindingWindow(Window owner, ObservableCollection<DeviceViewModel>, MainViewModel)。 */
let pending_devices: DeviceViewModel[] = [];
let host_ctx: common.Context | null = null;

function ui_context(): common.Context {
  const ctx: common.Context = host_ctx !== null ? host_ctx : getContext() as common.Context;
  return ctx;
}

export function open_device_binding(ctx: common.Context, devices: DeviceViewModel[]): void {
  host_ctx = ctx;
  pending_devices = devices;
  AppStorage.setOrCreate<number>(ARG_KEY_DEVICE_COUNT, devices.length);

  const spec: SubWindowSpec = {
    name: WINDOW_NAME,
    page: PAGE_PATH,
    title: S_TITLE,
    width: 1040,                      // Width="1040"
    height: 720,                      // Height="720"
    resizable: true,                  // 没写 ResizeMode → WPF 默认 CanResize
    minWidth: 900,                    // MinWidth="900"
    minHeight: 600,                   // MinHeight="600"
    modal: false,                     // MainWindow.xaml.cs:1610 是 window.Show()
  };
  SubWindowHost.open(ctx, spec).catch((error: BusinessError): void => {
    hilog.error(DOMAIN, TAG, '打开失败: %{public}s', error.message);
  });
}

// ───────────────────── 局部控件 ─────────────────────

/** BindingSectionCard：ControlFillBrush 底 / BorderBrush 1px / 圆角 8 / Padding 14。 */
@Component
struct BindingCard {
  @Builder
  empty_slot() {}

  @BuilderParam content: () => void = this.empty_slot;

  build() {
    Column() {
      this.content();
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(14)
    .borderRadius(8)
    .backgroundColor(CONTROL_FILL)
    .border({ width: 1, color: BORDER });
  }
}

/**
 * 卡片里的按钮 —— 原版写 Padding="12,7"（不是隐式 Button 的 18,10），
 * 没有 MinWidth。带 actionEnabled（不能叫 enabled：与 CommonMethod 冲突，TS2416）。
 */
@Component
struct BindingButton {
  @Prop label: string = '';
  @Prop actionEnabled: boolean = true;
  on_action: () => void = () => {};

  build() {
    Text(this.label)
      .fontSize(12)
      .fontColor(TEXT)
      .textAlign(TextAlign.Center)
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .borderRadius(8)
      .backgroundColor(CONTROL_FILL)
      .border({ width: 1, color: BORDER })
      .opacity(this.actionEnabled ? 1 : 0.34)
      .onClick((): void => {
        if (this.actionEnabled) {
          this.on_action();
        }
      });
  }
}

@Entry
@Component
struct DeviceBindingWindow {
  @State profiles: BindingProfile[] = [];
  @State devices: DeviceViewModel[] = [];
  @State selectedIndex: number = -1;
  @State hoverIndex: number = -1;
  @State statusText: string = '';
  /** 平台替换 3：就地重命名。 */
  @State renaming: boolean = false;
  @State renameText: string = '';
  /** 平台替换 4：两段式删除确认。 */
  @State confirmingDelete: boolean = false;
  /** 原版第一次 Bind 被拒（需用户确认）后，再点一次即视为确认。 */
  @State pendingConfirmWired: boolean = false;
  @State pendingConfirmAirPlay: boolean = false;
  @State wiredChoice: number = -1;
  @State airPlayChoice: number = -1;
  /** 蓝牙卡的状态行（原版 BluetoothStatus 属性）。GATT 连接是活的，所以要轮询。 */
  @State bluetoothStatusText: string = S_BOUND_NONE;
  /** 蓝牙状态轮询句柄；-1 = 没在跑。 */
  private bluetoothTimer: number = -1;
  /**
   * 「本次配网广播」是否由本窗口开着（还没收）。
   *
   * 存在的理由：原版 ConnectBluetoothClick 的 finally 是**无条件**
   * StopBluetoothPeripheralConfigurationAsync()，连用户自己在主窗口开的广播也会被一起收掉。
   * 本移植按本项目既有的「不收自己没开的东西」纪律（同独立预览窗口停会话那条），
   * 只收自己这次开的；同时它还是「流程有没有被中途掐断」的标记 —— 见
   * finish_bluetooth_configuration 开头的守卫。
   */
  private bluetoothFlowActive: boolean = false;

  aboutToAppear(): void {
    this.devices = pending_devices;
    const stored: BindingProfile[] = AppStorage.get<BindingProfile[]>(PROFILES_KEY) ?? [];
    this.profiles = stored;
    // 原版构造函数里 CreateProfilesForConnectedUsbDevices()（服务 ③ 的前置动作）。
    this.create_profiles_for_wired_devices();
    this.synchronize_selection();
    // 原版构造函数末尾的 `_ = RefreshBluetoothClientsAsync()`（xaml.cs:89）。
    // 上游是一次性异步拉取；鸿蒙这边 GATT 连接会在窗口开着的时候建立 / 断开，
    // 一次性快照会停在「已断开」而看起来像坏了 → 改成 1 秒轮询同一个真值来源。
    this.refresh_bluetooth_status();
    this.bluetoothTimer = setInterval((): void => { this.refresh_bluetooth_status(); }, 1000);
  }

  aboutToDisappear(): void {
    AppStorage.setOrCreate<BindingProfile[]>(PROFILES_KEY, this.profiles);
    if (this.bluetoothTimer !== -1) {
      clearInterval(this.bluetoothTimer);
      this.bluetoothTimer = -1;
    }
    // 收尾纪律（与独立预览窗口一致）：**只**收掉本窗口自己开的那次配网广播，
    // 绝不能顺手停掉用户在主窗口开的「蓝牙反向控制」——那是别的动作发起的状态。
    // 配网广播在本窗口里一定走 finish_bluetooth_configuration 的尾部被停掉，
    // 这里只是防止窗口被系统直接销毁时那条路径没跑到。
    if (this.bluetoothFlowActive) {
      BluetoothHidPeripheral.shared().stop();
      this.bluetoothFlowActive = false;
    }
  }

  private persist(): void {
    AppStorage.setOrCreate<BindingProfile[]>(PROFILES_KEY, this.profiles);
    this.profiles = this.profiles.slice();
  }

  // ── 设备列表（原版 WiredDevices / AirPlayDevices 两个 get-only 属性） ──

  private wired_devices(): DeviceViewModel[] {
    const result: DeviceViewModel[] = [];
    for (let index: number = 0; index < this.devices.length; ++index) {
      const device: DeviceViewModel = this.devices[index];
      if (!device.is_wireless() && !device.is_media_cast()) {
        result.push(device);
      }
    }
    return result;
  }

  private airplay_devices(): DeviceViewModel[] {
    const result: DeviceViewModel[] = [];
    for (let index: number = 0; index < this.devices.length; ++index) {
      const device: DeviceViewModel = this.devices[index];
      if (device.is_wireless() && !device.is_media_cast()) {
        result.push(device);
      }
    }
    return result;
  }

  private selected_profile(): BindingProfile | null {
    if (this.selectedIndex < 0 || this.selectedIndex >= this.profiles.length) {
      return null;
    }
    return this.profiles[this.selectedIndex];
  }

  /** 服务 ③ 的前置动作：已连接的 USB 设备自动建档案（原版构造函数里就做）。 */
  private create_profiles_for_wired_devices(): void {
    const wired: DeviceViewModel[] = this.wired_devices();
    let created: number = 0;
    for (let index: number = 0; index < wired.length; ++index) {
      const device: DeviceViewModel = wired[index];
      if (resolve_profile(this.profiles, device) === null) {
        const result: BindingResult = binding_create(this.profiles, device.display_name(),
          DeviceIdentityType.Wired, device.udid, device.productType);
        if (result.success) {
          created = created + 1;
        }
      }
    }
    if (created > 0) {
      this.persist();
      this.statusText = '已为 ' + created.toString() + ' 台已连接的有线设备建立档案。';
    }
  }

  /** 原版 SynchronizeSelectedDevices：档案切换后把两个下拉定位到对应设备。 */
  private synchronize_selection(): void {
    const profile: BindingProfile | null = this.selected_profile();
    this.wiredChoice = -1;
    this.airPlayChoice = -1;
    this.pendingConfirmWired = false;
    this.pendingConfirmAirPlay = false;
    this.renaming = false;
    this.confirmingDelete = false;
    if (profile === null) {
      return;
    }
    const wired: DeviceViewModel[] = this.wired_devices();
    for (let index: number = 0; index < wired.length; ++index) {
      if (same_id(wired[index].udid, profile.wiredUdid)) {
        this.wiredChoice = index;
        break;
      }
    }
    const airPlay: DeviceViewModel[] = this.airplay_devices();
    for (let index: number = 0; index < airPlay.length; ++index) {
      if (same_id(airPlay[index].udid, profile.airPlayId)) {
        this.airPlayChoice = index;
        break;
      }
    }
  }

  // ── 状态文本（xaml.cs 的那一组 get-only 属性） ──

  private profile_title(): string {
    const profile: BindingProfile | null = this.selected_profile();
    if (profile === null) {
      return S_SELECT_PROFILE;
    }
    return profile.displayName.length > 0 ? profile.displayName : S_UNNAMED;
  }

  /** ProfileListItem.ModelName：指纹产品名 → 产品类型 → 「型号信息待获取」。 */
  private model_name(profile: BindingProfile): string {
    if (profile.productType.length > 0) {
      return profile.productType;
    }
    return S_MODEL_UNKNOWN;
  }

  private profile_name(profile: BindingProfile): string {
    return profile.displayName.length > 0 ? profile.displayName : S_UNNAMED;
  }

  private wired_status(): string {
    const profile: BindingProfile | null = this.selected_profile();
    if (profile === null || profile.wiredUdid.length === 0) {
      return S_BOUND_NONE;
    }
    return this.is_wired_connected(profile) ? S_BOUND_CONNECTED : S_BOUND_UNAVAILABLE;
  }

  private airplay_status(): string {
    const profile: BindingProfile | null = this.selected_profile();
    if (profile === null || profile.airPlayId.length === 0) {
      return S_BOUND_NONE;
    }
    return this.is_airplay_current(profile) ? S_BOUND_MIRRORING : S_BOUND_UNAVAILABLE;
  }

  /**
   * 原版 BluetoothStatus（DeviceBindingWindow.xaml.cs:64）：
   *   Profile?.BluetoothIdentity is null                          → 「未绑定」
   *   BluetoothClients 里存在 Id == 绑定 StableId 的客户端（忽略大小写） → 「已绑定 · 已连接」
   *   其余                                                        → 「已绑定 · 已断开」
   *
   * 上游的 BluetoothClients 由 `GetReverseBluetoothClientsAsync()` 填（GATT 订阅者）。
   * 本移植读的是同一层的真值：BluetoothHidPeripheral.connectedClients() 就是当前 GATT
   * 连接。★ 这里此前恒返回「已绑定 · 已断开」，依据是"客户端列表恒空"——**那个前提已作废**
   * （BLE HID 外设已实现，列表有真数据）。
   *
   * 写成"算出来存进 @State"而不是一个 getter：GATT 连接会在窗口开着的时候建立/断开，
   * 靠用户点击触发重算会长时间停在过期值上（看起来就像坏了）。
   */
  private refresh_bluetooth_status(): void {
    let text: string = S_BOUND_NONE;
    try {
      const profile: BindingProfile | null = this.selected_profile();
      if (profile !== null && profile.bluetoothId.length > 0) {
        text = S_BOUND_DISCONNECTED;
        const clients: BluetoothHidClient[] = BluetoothHidPeripheral.shared().connectedClients();
        for (let index: number = 0; index < clients.length; ++index) {
          if (same_id(clients[index].address, profile.bluetoothId)) {
            text = S_BOUND_CONNECTED;
            break;
          }
        }
      }
    } catch (error) {
      // 定时器回调里抛异常 = 未捕获异常 = 整个应用被结束（本项目踩过）。
      const err = error as BusinessError;
      text = `蓝牙状态读取异常：${err.message}`;
    }
    this.bluetoothStatusText = text;
  }

  private is_wired_connected(profile: BindingProfile): boolean {
    const wired: DeviceViewModel[] = this.wired_devices();
    for (let index: number = 0; index < wired.length; ++index) {
      if (same_id(wired[index].udid, profile.wiredUdid)) {
        return true;
      }
    }
    return false;
  }

  private is_airplay_current(profile: BindingProfile): boolean {
    const airPlay: DeviceViewModel[] = this.airplay_devices();
    for (let index: number = 0; index < airPlay.length; ++index) {
      if (same_id(airPlay[index].udid, profile.airPlayId)) {
        return true;
      }
    }
    return false;
  }

  private has_wired_binding(): boolean {
    const profile: BindingProfile | null = this.selected_profile();
    return profile !== null && profile.wiredUdid.length > 0;
  }

  private has_airplay_binding(): boolean {
    const profile: BindingProfile | null = this.selected_profile();
    return profile !== null && profile.airPlayId.length > 0;
  }

  // ── 平台替换 5：WPF ComboBox → ArkUI 的 Select ──

  /** BoundWiredSelector / BoundAirPlaySelector 的选项：档案名列表。 */
  private profile_options(): SelectOption[] {
    const options: SelectOption[] = [];
    for (let index: number = 0; index < this.profiles.length; ++index) {
      options.push({ value: this.profile_name(this.profiles[index]) });
    }
    if (options.length === 0) {
      options.push({ value: S_NO_OPTION });
    }
    return options;
  }

  /** UnboundWiredSelector / UnboundAirPlaySelector 的选项：设备名列表。 */
  private device_options(devices: DeviceViewModel[]): SelectOption[] {
    const options: SelectOption[] = [];
    for (let index: number = 0; index < devices.length; ++index) {
      options.push({ value: devices[index].display_name() });
    }
    if (options.length === 0) {
      options.push({ value: S_NO_OPTION });
    }
    return options;
  }

  /** Select 的当前显示值（下标越界 / 空列表时回退到第一项）。 */
  private device_label(devices: DeviceViewModel[], index: number): string {
    if (devices.length === 0) {
      return S_NO_OPTION;
    }
    const safe: number = index >= 0 && index < devices.length ? index : 0;
    return devices[safe].display_name();
  }

  // ── 动作 ──

  private on_select_profile(index: number): void {
    this.selectedIndex = index;
    this.synchronize_selection();
  }

  /** 平台替换 7：真打开 AirPlay 设备选择窗口。 */
  private on_add_airplay_profile(): void {
    const airPlay: DeviceViewModel[] = this.airplay_devices();
    if (airPlay.length === 0) {
      this.statusText = '当前没有可创建的 AirPlay 设备：' + S_REASON_NO_DEVICES;
      return;
    }
    open_airplay_device_selection(ui_context(), airPlay,
      (selected: DeviceViewModel | null): void => {
        if (selected === null) {
          return;
        }
        const result: BindingResult = binding_create(this.profiles, selected.display_name(),
          DeviceIdentityType.AirPlay, selected.udid, selected.productType);
        if (!result.success) {
          this.statusText = result.error.length > 0 ? result.error : S_CREATE_FAILED;
          return;
        }
        this.persist();
        this.selectedIndex = this.profiles.length - 1;
        this.synchronize_selection();
        this.statusText = '已创建设备档案：' + selected.display_name();
      });
  }

  private on_bind_wired(): void {
    const profile: BindingProfile | null = this.selected_profile();
    if (profile === null || this.wiredChoice < 0) {
      return;
    }
    const device: DeviceViewModel = this.wired_devices()[this.wiredChoice];
    const result: BindingResult = binding_bind(this.profiles, profile.id,
      DeviceIdentityType.Wired, device.udid, device.display_name(), device.productType,
      this.pendingConfirmWired);
    if (!result.success) {
      // 需要用户确认的两种情况 → 记下「已提示」，再点一次即确认（平台替换 4）。
      this.pendingConfirmWired = result.error === S_ERR_NEEDS_CONFIRM
        || result.error === S_ERR_UNKNOWN_CONFIRM;
      this.statusText = result.error;
      return;
    }
    this.pendingConfirmWired = false;
    this.persist();
    this.synchronize_selection();
    this.statusText = '已绑定有线身份：' + device.display_name();
  }

  private on_bind_airplay(): void {
    const profile: BindingProfile | null = this.selected_profile();
    if (profile === null || this.airPlayChoice < 0) {
      return;
    }
    const device: DeviceViewModel = this.airplay_devices()[this.airPlayChoice];
    const result: BindingResult = binding_bind(this.profiles, profile.id,
      DeviceIdentityType.AirPlay, device.udid, device.display_name(), device.productType,
      this.pendingConfirmAirPlay);
    if (!result.success) {
      this.pendingConfirmAirPlay = result.error === S_ERR_NEEDS_CONFIRM
        || result.error === S_ERR_UNKNOWN_CONFIRM;
      this.statusText = result.error;
      return;
    }
    this.pendingConfirmAirPlay = false;
    this.persist();
    this.synchronize_selection();
    this.statusText = '已绑定 AirPlay 身份：' + device.display_name();
  }

  private on_unbind(type: DeviceIdentityType): void {
    const profile: BindingProfile | null = this.selected_profile();
    if (profile === null) {
      return;
    }
    if (binding_unbind(this.profiles, profile.id, type)) {
      this.persist();
      this.synchronize_selection();
      this.statusText = '已解绑。';
    }
  }

  /**
   * 平台替换 6（已实现）：原版 ConnectBluetoothClick 的前半段
   * （DeviceBindingWindow.xaml.cs:140-161）。
   *
   * 逐行对应：
   *   · `if (Profile is null) return;`            → 本移植给一句提示（原版静默返回，
   *     但这个按钮点了什么都不发生更像坏了；文案就是 DeviceBindingSelectProfile）。
   *   · `target = WiredIdentity?.Udid ?? AirPlayIdentity?.StableId` → 见下。
   *   · `string.IsNullOrWhiteSpace(target)` → MessageBox
   *     DeviceBindingUsbOrAirPlayRequired。
   *   · `StartBluetoothPeripheralForConfigurationAsync(target)` → `hid.start(ctx)`。
   *     它返回 Promise：内部先做蓝牙权限的运行时申请（ACCESS_BLUETOOTH 是
   *     user_grant，只声明不申请就是 201 Permission denied），拿到授权才注册 GATT。
   *     上游那个方法最终是 `EnableBluetoothControlAsync(target, fromReverseControl: true,
   *     configurationOnly: true)`，**只广播、不启用输入注入**，所以这里也绝不碰
   *     ReverseControlInput —— 配网阶段 iPhone 上不应该有光标在动。
   *     返回 false → MessageBox DeviceBindingBluetoothStartFailed；本移植额外把
   *     `hid.errorText()` 原样挂上（801 = 设备不具备 BLE 外设角色，重试必然失败，
   *     不说原因等于让用户白试）。
   *   · `BluetoothConnectionWindow.Show(this, profileName, refresh, unbind)` →
   *     `open_bluetooth_connection(ctx, profile.displayName, 回调)`（同步 ShowDialog
   *     在鸿蒙没对应物，改成回调；见该文件里的平台替换 ③）。
   */
  /**
   * 「等待 Bluetooth HID 连接」窗口是否还开着。
   *
   * 为什么必须查一次真窗口而不是只信一个布尔量：`SubWindowHost.open` 失败时只记日志、
   * 不发任何回调，`bluetoothFlowActive` 会永远停在 true。原版有模态对话框天然兜住这件事，
   * 鸿蒙没有 —— 只能问窗口管理器。
   * （`window.findWindow` 找不到窗口时**抛异常**，不是返回 null，见 Index.ets 的同款处理。）
   */
  private bluetooth_waiting_window_alive(): boolean {
    try {
      return window.findWindow(BLUETOOTH_CONNECTION_WINDOW_NAME) !== null;
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, '查找 Bluetooth 等待窗口失败: %{public}s', err.message);
      return false;
    }
  }

  private on_connect_bluetooth(): void {
    const profile: BindingProfile | null = this.selected_profile();
    if (profile === null) {
      this.statusText = S_SELECT_PROFILE;
      return;
    }
    // 原版：Profile.WiredIdentity?.Udid ?? Profile.AirPlayIdentity?.StableId
    const target: string = profile.wiredUdid.length > 0 ? profile.wiredUdid : profile.airPlayId;
    if (target.length === 0) {
      this.statusText = S_USB_OR_AIRPLAY_REQUIRED;
      return;
    }
    if (this.bluetoothFlowActive && this.bluetooth_waiting_window_alive()) {
      // 上一次配网还没收尾（等待窗口还开着）。原版是模态对话框，不可能重入。
      this.statusText = '上一次蓝牙配网还在进行中，请先完成或关闭「等待 Bluetooth HID 连接」窗口。';
      return;
    }
    if (this.bluetoothFlowActive) {
      // 等待窗口已经不在了 → 上一次的结果回调永远不会来（开窗失败时就是这样，
      // SubWindowHost.open 的 catch 只记日志）。不在这里兜底的话，那一次留下的广播
      // 会一直挂着、这个按钮也永远点不动 —— 正是本项目禁止的"哑住"。
      BluetoothHidPeripheral.shared().stop();
      this.bluetoothFlowActive = false;
      this.refresh_bluetooth_status();
    }
    const hid: BluetoothHidPeripheral = BluetoothHidPeripheral.shared();
    const ctx: common.Context = ui_context();
    // ★ 必须走 start(ctx) 这条异步路：ACCESS_BLUETOOTH 是 **user_grant**，
    //   start() 内部会先调 requestPermissionsFromUser 弹系统授权框，拿到授权才去
    //   createGattServer/addService。此前调的是同步版 start()，权限从未申请过，
    //   addService 立刻回 201 Permission denied（与主窗口反控按钮同一个根因）。
    hid.start(ctx).then((started: boolean): void => {
      // Promise 回调里一行都不能裸奔（抛异常 = 未捕获异常 = 整个应用被结束）。
      this.after_bluetooth_start(profile, target, started);
    }).catch((error: BusinessError): void => {
      this.bluetoothFlowActive = false;
      this.statusText = S_BLUETOOTH_START_FAILED + ' ' + error.message;
    });
  }

  /** start(ctx) 的异步收尾：广播起来后才打开等待窗口（原同步分支原样搬过来）。 */
  private after_bluetooth_start(profile: BindingProfile, target: string,
                                started: boolean): void {
    try {
      const hid: BluetoothHidPeripheral = BluetoothHidPeripheral.shared();
      if (!started) {
        this.statusText = S_BLUETOOTH_START_FAILED + ' ' + hid.errorText();
        return;
      }
      this.bluetoothFlowActive = true;
      // 启动成功但有隐患（最常见：回读 GATT 特征的 API 在本机版本上不存在，
      // 于是"特征数"校验不了）必须一并说出来 —— 否则配对失败时无从判断。
      const hidWarning: string = hid.warningText();
      this.statusText = (hidWarning.length > 0 ? `已广播，但需注意：${hidWarning}；` : '')
        + '正在广播 Bluetooth HID 设备，请在 iPhone/iPad 的「设置 → 蓝牙」中' +
        '选择本设备完成配对…';
      const ctx: common.Context = ui_context();
      // 目标身份的用途说明（忠实记录上游差异）：上游把 target 传进
      // StartBluetoothPeripheralForConfigurationAsync，用于把这次广播**只**服务
      // 该档案对应的设备。本移植的 BLE HID 外设是一个整体（广播里只有 HID 服务 UUID，
      // 不带设备级目标），所以 target 在这里只作为"该档案确实有有线/AirPlay 身份"的
      // 前置校验，不参与广播内容 —— 这是平台差异，不假装一致。
      hilog.info(DOMAIN, TAG, '开始蓝牙配网：档案=%{public}s 目标身份=%{public}s',
        profile.displayName, target);
      open_bluetooth_connection(ctx, profile.displayName,
        (clientId: string | null): void => {
          this.finish_bluetooth_configuration(profile.id, clientId);
        });
    } catch (error) {
      const failure = error as BusinessError;
      this.bluetoothFlowActive = false;
      this.statusText = S_BLUETOOTH_START_FAILED + ' ' + failure.message;
    }
  }

  /**
   * 原版 ConnectBluetoothClick 的后半段 + finally
   * （DeviceBindingWindow.xaml.cs:160-175）。
   *
   * 由等待窗口的结果回调驱动：选中客户端 → clientId；点「取消」或直接关窗 → null
   * （那个窗口的 close hook 会把 null 喂进来）。两条路都会走到这里，与上游一致。
   */
  private finish_bluetooth_configuration(profileId: string, clientId: string | null): void {
    if (!this.bluetoothFlowActive) {
      // 配网广播已经被别的路径收掉了（本窗口自己被销毁时的兜底）。
      // 这时再保存绑定就是在用户已经离开的界面上偷偷改数据 —— 不保存。
      return;
    }
    this.bluetoothFlowActive = false;

    let message: string = '';
    if (clientId !== null && clientId.length > 0) {
      // 原版：_manager.Bind(profileId, DeviceIdentityType.Bluetooth, clientId,
      //                     clientId, null, userConfirmed: true)
      // —— 注意 deviceName 传的也是 clientId（那时还不知道设备名），指纹传 null，
      //    并且**强制 userConfirmed: true**（配网流程本身就是人工确认过的）。
      const result: BindingResult = binding_bind(this.profiles, profileId,
        DeviceIdentityType.Bluetooth, clientId, clientId, '', true);
      if (result.success) {
        this.persist();
        this.synchronize_selection();
        message = '已绑定 Bluetooth 身份：' + clientId;
      } else {
        // 原版弹 DeviceBindingBluetoothSaveFailed；能拿到 DeviceBindingManager 的
        // 具体拒绝理由时优先显示理由（本文件「不吞原因」的一贯做法）。
        message = result.error.length > 0 ? result.error : S_BLUETOOTH_SAVE_FAILED;
      }
    } else {
      message = '未选择 Bluetooth 设备，未保存绑定。';
    }

    // finally：原版 StopBluetoothPeripheralConfigurationAsync()
    // （= DisableBluetoothControlAsync，无条件 StopAsync）。
    // 见 bluetoothFlowActive 的注释：本移植只收自己这次开的。
    BluetoothHidPeripheral.shared().stop();
    // 原版紧接着 RefreshBluetoothClientsAsync()：重新枚举订阅者 → 刚停掉广播，
    // 列表必然为空 → 状态行回落成「已绑定 · 已断开」。这里用同一份真值重算。
    this.refresh_bluetooth_status();
    this.statusText = message + '（本次配网广播已停止）';
  }

  /** 平台替换 3：就地重命名（原版是 InputBox）。 */
  private on_start_rename(): void {
    const profile: BindingProfile | null = this.selected_profile();
    if (profile === null) {
      return;
    }
    this.renameText = profile.displayName;
    this.renaming = true;
    this.confirmingDelete = false;
  }

  private on_save_rename(): void {
    const profile: BindingProfile | null = this.selected_profile();
    if (profile === null) {
      return;
    }
    if (this.renameText.trim().length === 0) {
      this.statusText = S_RENAME_PROMPT;
      return;
    }
    profile.displayName = this.renameText.trim();
    this.renaming = false;
    this.persist();
    this.statusText = '档案已重命名。';
  }

  /** 平台替换 4：两段式删除确认。 */
  private on_delete_clicked(): void {
    if (!this.confirmingDelete) {
      this.confirmingDelete = true;
      this.renaming = false;
      this.statusText = S_DELETE_CONFIRMATION;
      return;
    }
    const profile: BindingProfile | null = this.selected_profile();
    if (profile === null) {
      return;
    }
    const next: BindingProfile[] = [];
    for (let index: number = 0; index < this.profiles.length; ++index) {
      if (this.profiles[index].id !== profile.id) {
        next.push(this.profiles[index]);
      }
    }
    this.profiles = next;
    this.selectedIndex = -1;
    this.confirmingDelete = false;
    this.persist();
    this.synchronize_selection();
    this.statusText = '设备档案已删除。';
  }

  // ── 构建 ──

  /** 左栏条目（原版 ListBoxItem 模板 + 两个触发器）。 */
  @Builder
  profile_row(index: number) {
    Row() {
      Column() {
        Text(this.profile_name(this.profiles[index]))
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
        Text(this.model_name(this.profiles[index]))
          .fontSize(11)
          .fontColor(MUTED_TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 4 });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);

      // 平台替换 2：右键菜单的两个菜单项 → 选中后露出的两个图标按钮。
      if (this.selectedIndex === index) {
        FluentSymbol({
          iconName: 'ImageEdit20',
          iconSize: 16,
          iconColor: MUTED_TEXT,
        })
          .margin({ left: 6 })
          .onClick((): void => { this.on_start_rename(); });
        FluentSymbol({
          iconName: 'Delete20',
          iconSize: 16,
          iconColor: this.confirmingDelete ? ERROR : MUTED_TEXT,
        })
          .margin({ left: 6 })
          .onClick((): void => { this.on_delete_clicked(); });
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(8)
    .backgroundColor(this.selectedIndex === index ? COMBO_ITEM_SELECTED
      : (this.hoverIndex === index ? CONTROL_HOVER : CONTROL_FILL))
    .border({ width: 1, color: this.selectedIndex === index ? ACCENT : BORDER })
    .alignItems(VerticalAlign.Center)
    .margin({ bottom: 8 })
    .onHover((isHover: boolean): void => { this.hoverIndex = isHover ? index : -1; })
    .onClick((): void => { this.on_select_profile(index); });
  }

  @Builder
  left_panel() {
    Column() {
      Row() {
        Text(S_PROFILES)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT)
          .margin({ left: 4, right: 4, top: 2, bottom: 12 });
        Row() {
          FluentSymbol({
            iconName: 'Add20',
            iconSize: 18,
            iconColor: TEXT,
          });
        }
        .width(32)
        .height(32)
        .borderRadius(8)
        .justifyContent(FlexAlign.Center)
        .onClick((): void => { this.on_add_airplay_profile(); });
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(VerticalAlign.Top);

      if (this.profiles.length > 0) {
        Scroll() {
          Column() {
            ForEach(this.profiles, (profile: BindingProfile, index: number): void => {
              this.profile_row(index);
            }, (profile: BindingProfile): string => profile.id);
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start);
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .align(Alignment.Top);

        // 平台替换 2：原版是右键菜单，这里改成选中后露出图标，补一句说明。
        Column() {
          hint_text('选中档案后，右侧两个图标分别是「' + S_RENAME + '」与「' + S_DELETE + '」。');
        }
        .width('100%')
        .margin({ top: 8 });
      } else {
        Column() {
          hint_text('还没有设备档案。连接 iPhone/iPad 后会自动建立，'
            + '也可以点右上角「' + S_ADD_TOOLTIP + '」。');
        }
        .width('100%')
        .layoutWeight(1);
      }
    }
    .width(270)
    .height('100%')
    .padding(12)
    .borderRadius(10)
    .backgroundColor(CONTROL_FILL)
    .border({ width: 1, color: BORDER })
    .alignItems(HorizontalAlign.Start);
  }

  /** 原版 ProfileTitle（21 SemiBold）；重命名时就地换成输入框。 */
  @Builder
  title_area() {
    if (this.renaming) {
      Column() {
        RoundedTextBox({
          label: S_RENAME_PROMPT,
          text: this.renameText,
          on_text_change: (value: string): void => { this.renameText = value; },
        });
        Row() {
          BindingButton({
            label: S_SAVE,
            on_action: (): void => { this.on_save_rename(); },
          });
          BindingButton({
            label: S_CANCEL,
            on_action: (): void => { this.renaming = false; },
          })
            .margin({ left: 8 });
        }
        .width('100%')
        .margin({ top: 8 });
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%');
    } else {
      Text(this.profile_title())
        .fontSize(21)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT)
        .width('100%');
    }
  }

  /** 三张卡共用的「身份」行（Consolas 11 / Muted / Margin 0,3,0,0）。 */
  @Builder
  identity_line(text: string) {
    Text(text)
      .fontSize(11)
      .fontColor(MUTED_TEXT)
      .fontFamily('monospace')
      .width('100%')
      .margin({ top: 3 });
  }

  @Builder
  wired_card() {
    Column() {
      Text(S_WIRED)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT);
      Text(this.wired_status())
        .fontSize(12)
        .fontColor(TEXT)
        .width('100%')
        .margin({ top: 7 });
      this.identity_line(this.has_wired_binding()
        ? (this.selected_profile() as BindingProfile).wiredUdid : '');
      Text(S_WIRED_DESC)
        .fontSize(11)
        .fontColor(MUTED_TEXT)
        .width('100%')
        .margin({ top: 10 });

      if (this.has_wired_binding()) {
        // BoundWiredSelector：ItemsSource=Profiles / SelectedItem=SelectedProfile / 禁用
        Select(this.profile_options())
          .selected(this.selectedIndex)
          .value(this.profile_title())
          .enabled(false)
          .fontColor(TEXT)
          .optionFontColor(TEXT)
          .selectedOptionFontColor(TEXT)
          .width('100%')
          .margin({ top: 10 });
      } else {
        // UnboundWiredSelector：ItemsSource=WiredDevices / IsEnabled=CanEditWired
        Select(this.device_options(this.wired_devices()))
          .selected(this.wiredChoice < 0 ? 0 : this.wiredChoice)
          .value(this.device_label(this.wired_devices(),
            this.wiredChoice < 0 ? 0 : this.wiredChoice))
          .enabled(this.selected_profile() !== null)
          .fontColor(TEXT)
          .optionFontColor(TEXT)
          .selectedOptionFontColor(TEXT)
          .width('100%')
          .margin({ top: 10 })
          .onSelect((index: number): void => { this.wiredChoice = index; });
      }

      Row() {
        BindingButton({
          label: S_BIND,
          actionEnabled: this.selected_profile() !== null && !this.has_wired_binding()
            && this.wiredChoice >= 0,
          on_action: (): void => { this.on_bind_wired(); },
        });
        BindingButton({
          label: S_UNBIND,
          actionEnabled: this.has_wired_binding(),
          on_action: (): void => { this.on_unbind(DeviceIdentityType.Wired); },
        })
          .margin({ left: 8 });
      }
      .width('100%')
      .margin({ top: 10 });
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%');
  }

  @Builder
  airplay_card() {
    Column() {
      Text(S_AIRPLAY)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT);
      Text(this.airplay_status())
        .fontSize(12)
        .fontColor(TEXT)
        .width('100%')
        .margin({ top: 7 });
      this.identity_line(this.has_airplay_binding()
        ? (this.selected_profile() as BindingProfile).airPlayId : '');
      Text(S_AIRPLAY_DESC)
        .fontSize(11)
        .fontColor(MUTED_TEXT)
        .width('100%')
        .margin({ top: 10 });

      if (this.has_airplay_binding()) {
        Select(this.profile_options())
          .selected(this.selectedIndex)
          .value(this.profile_title())
          .enabled(false)
          .fontColor(TEXT)
          .optionFontColor(TEXT)
          .selectedOptionFontColor(TEXT)
          .width('100%')
          .margin({ top: 10 });
      } else {
        Select(this.device_options(this.airplay_devices()))
          .selected(this.airPlayChoice < 0 ? 0 : this.airPlayChoice)
          .value(this.device_label(this.airplay_devices(),
            this.airPlayChoice < 0 ? 0 : this.airPlayChoice))
          .enabled(this.selected_profile() !== null)
          .fontColor(TEXT)
          .optionFontColor(TEXT)
          .selectedOptionFontColor(TEXT)
          .width('100%')
          .margin({ top: 10 })
          .onSelect((index: number): void => { this.airPlayChoice = index; });
      }

      Row() {
        BindingButton({
          label: S_BIND,
          actionEnabled: this.selected_profile() !== null && !this.has_airplay_binding()
            && this.airPlayChoice >= 0,
          on_action: (): void => { this.on_bind_airplay(); },
        });
        BindingButton({
          label: S_UNBIND,
          actionEnabled: this.has_airplay_binding(),
          on_action: (): void => { this.on_unbind(DeviceIdentityType.AirPlay); },
        })
          .margin({ left: 8 });
      }
      .width('100%')
      .margin({ top: 10 });
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%');
  }

  @Builder
  bluetooth_card() {
    Column() {
      Text(S_BLUETOOTH)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT);
      Text(this.bluetoothStatusText)
        .fontSize(12)
        .fontColor(TEXT)
        .width('100%')
        .margin({ top: 7 });
      this.identity_line(this.selected_profile() !== null
        ? (this.selected_profile() as BindingProfile).bluetoothId : '');
      Text(S_BLUETOOTH_DESC)
        .fontSize(11)
        .fontColor(MUTED_TEXT)
        .width('100%')
        .margin({ top: 10 });

      Row() {
        BindingButton({
          label: S_CONNECT,
          actionEnabled: this.selected_profile() !== null,
          on_action: (): void => { this.on_connect_bluetooth(); },
        });
        BindingButton({
          label: S_UNBIND,
          actionEnabled: this.selected_profile() !== null
            && (this.selected_profile() as BindingProfile).bluetoothId.length > 0,
          on_action: (): void => { this.on_unbind(DeviceIdentityType.Bluetooth); },
        })
          .margin({ left: 8 });
      }
      .width('100%')
      .margin({ top: 12 });
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%');
  }

  @Builder
  right_panel() {
    Scroll() {
      Column() {
        this.title_area();
        Text(S_PROFILE_DESC)
          .fontSize(11)
          .fontColor(MUTED_TEXT)
          .width('100%')
          .margin({ top: 5 });

        Row() {
          BindingCard({ content: (): void => { this.wired_card(); } }).layoutWeight(1);
          Column().width(16);
          BindingCard({ content: (): void => { this.airplay_card(); } }).layoutWeight(1);
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .margin({ top: 16 });

        Column().height(16);

        BindingCard({ content: (): void => { this.bluetooth_card(); } });

        if (this.statusText.length > 0) {
          Column() {
            hint_text(this.statusText);
          }
          .width('100%')
          .margin({ top: 12 });
        }

        if (this.devices.length === 0) {
          Column() {
            hint_text(S_REASON_NO_DEVICES);
          }
          .width('100%')
          .margin({ top: 12 });
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start);
    }
    .layoutWeight(1)
    .height('100%')
    .padding(22)
    .borderRadius(10)
    .backgroundColor(CONTROL_FILL)
    .border({ width: 1, color: BORDER })
    .scrollBar(BarState.Auto)
    .align(Alignment.Top);
  }

  @Builder
  body() {
    Row() {
      this.left_panel();
      Column().width(16);
      this.right_panel();
    }
    .width('100%')
    .height('100%');
  }

  build() {
    Column() {
      SubWindowShell({
      windowName: WINDOW_NAME,
      title: S_TITLE,
      subtitle: S_SUBTITLE,
      gap: 16,                       // 行 1 = 16
      hasNotice: false,
      hasFooter: false,
      hasActions: false,             // 原版没有按钮条，只有右上角关闭
      content: (): void => { this.body(); },
    });
    }
  }
}
