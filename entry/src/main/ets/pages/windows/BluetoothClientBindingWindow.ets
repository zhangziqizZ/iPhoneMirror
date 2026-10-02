// BluetoothClientBindingWindow.ets —— 子窗口 12/20：绑定蓝牙手机（蓝牙反控的客户端选择）
//
// 逐项对照上游（main 1.8.4 与 linux 1.8.1 的这两个文件**逐字节相同**，已 diff 确认）
//   src/App/Windows/BluetoothClientBindingWindow.xaml（149 行）
//   src/App/Windows/BluetoothClientBindingWindow.xaml.cs（117 行）
// 相关服务（状态机与文案来源）
//   src/App/Services/BluetoothClientInfo.cs（22 行）—— 条目的四个展示属性
//   src/App/Services/BluetoothClientRouteTable.cs（165 行）—— IsBound / CanBind 的判定
//   src/App/Services/BluetoothHidMouseService.cs（1605 行）—— 客户端来自 GATT 订阅者表
//
// ── 窗口属性（XAML 根元素 <ui:FluentWindow> 那一行）──────────────────────────
//   Title="{DynamicResource BluetoothClientBindingTitle}"  → 「绑定蓝牙手机」
//   Width="520" Height="448" MinWidth="460" MinHeight="400"
//   WindowStartupLocation="CenterOwner"                    → SubWindowHost.open 里算居中
//   ResizeMode="NoResize"                                  → resizable: false
//   ExtendsContentIntoTitleBar="True"                      → decorEnabled: false + 自绘表头
//   WindowBackdropType="Mica" / WindowCornerPreference="Round"
//                                                          → 由系统窗口负责，界面层无需复现
//   Background="{DynamicResource AppBackgroundBrush}"      → SubWindowShell 默认底色
//
// ── 行定义（Grid.RowDefinitions，7 行）──────────────────────────────────────
//   Row Auto : SubWindowHeader（只有标题，没有 SubWindowSubtitle）
//   Row 16   : 间隔
//   Row Auto : StackPanel —— TargetText(15 SemiBold) + Hint(Muted 11 Wrap, Margin 0,5,0,0)
//   Row 12   : 间隔
//   Row *    : ListBox（BorderThickness 0 / Background Transparent / 禁用横向滚动条）
//   Row 14   : 间隔
//   Row Auto : 按钮条（Grid 六列 = * / Auto / 8 / Auto / 8 / Auto）
//
// ── 条目（ItemContainerStyle 的 ControlTemplate + ItemTemplate 两层 Border）──
//   外层 Border：ControlFillBrush 底 / BorderBrush 1px / 圆角 10 / Padding 0 / Margin 0,0,0,8
//     Trigger IsMouseOver → 底转 ControlHoverBrush
//     Trigger IsSelected  → 底转 ComboItemSelectedBrush、边转 AccentBrush（写在 hover 之后，
//                           所以「既 hover 又选中」以选中态为准）
//     Trigger IsEnabled=False → Opacity 0.5
//   内层 Border：ControlFillBrush 底 / BorderBrush 1px / 圆角 8 / Padding 12,10
//     Grid 两列 = * / Auto
//     列 0 StackPanel：
//       TextBlock DisplayName        FontWeight SemiBold
//       TextBlock ConnectionTimeText AccentHoverBrush / 10 / Margin 0,4,0,0
//       TextBlock BindingText        SuccessBrush / 10 / Margin 0,3,0,0（IsBound 才显示）
//       TextBlock IdentifierText     MutedTextBrush / Consolas / 10 / Margin 0,4,0,0 / 截断
//     列 1 Button「解除绑定」VerticalAlignment Center / Margin 12,0,0,0 / Padding 10,5
//           （IsBound 才显示）
//   ⚠ 还原取舍：两层 Border 的外层 Padding=0，视觉上只见内层的圆角 8 + Padding 12,10，
//     所以这里合成一层（圆角 8 / Padding 12,10 / Margin 0,0,0,8），与 AirPlayDeviceSelectionWindow
//     的处理一致。
//
// ── xaml.cs 的行为（逐条照搬）─────────────────────────────────────────────
//   CanConfirm => SelectedClient?.CanBind == true        → 未选中 / 选中已绑定项时「确认绑定」禁用
//   CanRefresh => !_isRefreshing
//   ReplaceClients(clients, preferredId)：
//       优先选中 CanBind 且 Id == preferredId 的那一项；否则当可绑定项恰好只有 1 个时选中它；
//       否则不选中（null）
//   OnConfirmClick: if (CanConfirm) DialogResult = true;
//   OnCancelClick / 右上角 X: DialogResult = false;
//   OnUnbindClick : _unbind(client.Id) 成功后把该项换成 with { BoundDeviceName = null }，
//                   并清掉对它的选中
//   OnRefreshClick: 记住当前选中 Id → 置 _isRefreshing → await _refresh() → ReplaceClients
//   Show(...) 返回 window.SelectedClient?.Id（DialogResult != true 时返回 null）
//
// ── 文案来源 Strings.zh-CN.xaml（main 版，逐字取用）────────────────────────
//   BluetoothClientBindingTitle           「绑定蓝牙手机」
//   BluetoothClientBindingHint            「首次使用此投屏设备时…之后切换选项卡会自动使用此绑定。」
//   BluetoothClientBindingTargetFormat    「请选择与“{0}”对应的蓝牙手机」
//   BluetoothClientBindingUnbind          「解除绑定」
//   BluetoothClientBindingRefresh         「刷新蓝牙客户端」
//   BluetoothClientBindingConfirm         「确认绑定」
//   Cancel                                「取消」
//   BluetoothClientUnknownName            「未命名蓝牙设备」
//   BluetoothClientAddressFormat          「设备 ID：{0}」
//   BluetoothClientConnectionTimeFormat   「本次连接：{0}」
//   BluetoothClientBoundToFormat          「已绑定到：{0}」
//
// ═══════════════════ 与原版的差异（2026-09-20 重写）═══════════════════════
// ★ 这一节此前写的是「鸿蒙没有 GATT Server / 外设角色」——**那是错的，已作废**。
//   本移植已经用 `ble.createGattServer()` + `startAdvertising()` 做出了真的 BLE HID
//   外设（见 common/BluetoothHidPeripheral.ets），所以列表、刷新、解绑都接上了
//   真实数据。判据是代码事实，不是猜测。
//
// ① 客户端列表的数据来源
//    原版：refresh 回调 = MainViewModel.RefreshBluetoothBindingClientsAsync
//          → BluetoothHidMouseService 里 _clientStates / _clientConnectedAt（GATT 订阅者表）。
//    鸿蒙：`BluetoothHidPeripheral.connectedClients()` —— 记录来自 GATT Server 的
//          `connectionStateChange` 事件（地址 + `connection.getRemoteDeviceName` 查到的名字
//          + 本地连接时刻）。**最多一条**：鸿蒙的 GattServer 同一时刻只维护一个活动连接
//          （原版 Windows 的 GattServiceProvider 支持多个订阅者，这是平台差异）。
//          名称查不到时留空，页面显示「未命名蓝牙设备」而不是拿地址冒充名字。
// ② 「刷新蓝牙客户端」按钮（OnRefreshClick）
//    原版：await _refresh() 重新枚举 GATT 订阅者。
//    鸿蒙：真的重新读一次 `connectedClients()` 并如实报出条数（0 条就说 0 条）。
// ③ 「解除绑定」按钮（OnUnbindClick）
//    原版：_unbind = MainViewModel.UnbindBluetoothControlBinding
//          → BluetoothClientRouteTable.RemoveBinding + 删除持久化绑定。
//    鸿蒙：**清除本列表里的绑定标记**并如实说明「本移植未做持久化，重启后回到原状」。
//          不假装写进了什么持久化存储。
// ④ 「确认绑定」（OnConfirmClick）
//    原版：DialogResult=true 后由 MainViewModel 调 BindTargetClientAsync + 持久化。
//    鸿蒙：只有「选中了哪个客户端」这一 UI 结果是真实的，照原版写回 AppStorage + 回调；
//          不会建立任何 BLE HID 连接（连接由反控开关负责，见 Index 的蓝牙反控设置）。
// ⑤ 对话框返回值
//    原版用 WPF 的 DialogResult；鸿蒙子窗口没有等价机制 → 与 AdvancedSettingsWindow 一样
//    改用 AppStorage 键 + 一次性回调（键名见下 RESULT_KEY_SELECTED_ID）。
// ⑥ ToolTip / AutomationProperties.Name（原版刷新按钮上写了两遍 BluetoothClientBindingRefresh）
//    鸿蒙 ArkUI 没有 ToolTip 属性映射进这套外壳 → 只在 hilog 里记录按钮名，视觉上还原图标按钮。

import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  SubWindowShell, SubWindowHost, SecondaryButton, PrimaryButton,
  hint_text, error_text,
  SUBWINDOW_ROW_GAP, SUBWINDOW_ROW_GAP_NARROW,
  SubWindowSpec,
} from '../../common/SubWindow';
import { FluentSymbol } from '../../common/FluentIcon';
import {
  TEXT, MUTED_TEXT, ACCENT_HOVER, SUCCESS,
  CONTROL_FILL, CONTROL_HOVER, COMBO_ITEM_SELECTED, ACCENT, BORDER,
  BUTTON_CORNER, DISABLED_OPACITY,
} from '../../common/Theme';
import { BluetoothHidPeripheral, BluetoothHidClient } from '../../common/BluetoothHidPeripheral';
import { t } from '../../common/i18n';

const TAG: string = 'im_bluetooth_binding';
const DOMAIN: number = 0x0100;

export const WINDOW_NAME: string = 'BluetoothClientBindingWindow';
export const PAGE_PATH: string = 'pages/windows/BluetoothClientBindingWindow';

/** 原版 Show(owner, targetName, clients, suggestedId, refresh, unbind) 的入参键。 */
export const ARG_KEY_TARGET_NAME: string = 'im.bluetoothClientBinding.targetName';
export const ARG_KEY_SUGGESTED_ID: string = 'im.bluetoothClientBinding.suggestedId';
/** 结果键：确认时写选中的客户端 Id；取消 / 关闭时写空串（对应原版返回 null）。 */
export const RESULT_KEY_SELECTED_ID: string = 'im.bluetoothClientBinding.selectedId';

/** 原版 BluetoothClientInfo 的六个字段（record，含四个派生展示属性）。 */
export class BluetoothClientInfo {
  id: string = '';
  name: string = '';
  address: string = '';
  /** 原版 DateTimeOffset；这里直接用已经格式化好的「yyyy-MM-dd HH:mm:ss」字符串。 */
  connectedAtText: string = '';
  /** 原版 string? BoundDeviceName，空串 = 未绑定。 */
  boundDeviceName: string = '';

  constructor(id: string, name: string, address: string, connectedAtText: string,
              boundDeviceName: string = '') {
    this.id = id;
    this.name = name;
    this.address = address;
    this.connectedAtText = connectedAtText;
    this.boundDeviceName = boundDeviceName;
  }

  /** 原版 DisplayName：名字为空时用 BluetoothClientUnknownName。 */
  display_name(): string {
    return this.name.length === 0 ? '未命名蓝牙设备' : this.name;
  }

  /** 原版 IdentifierText：地址为空时退回 Id（BluetoothClientAddressFormat）。 */
  identifier_text(): string {
    return this.address.length === 0 ? this.id : `设备 ID：${this.address}`;
  }

  /** 原版 ConnectionTimeText（BluetoothClientConnectionTimeFormat）。 */
  connection_time_text(): string {
    return `本次连接：${this.connectedAtText}`;
  }

  /** 原版 IsBound => !string.IsNullOrWhiteSpace(BoundDeviceName)。 */
  is_bound(): boolean {
    return this.boundDeviceName.trim().length > 0;
  }

  /** 原版 CanBind => !IsBound。 */
  can_bind(): boolean {
    return !this.is_bound();
  }

  /** 原版 BindingText（BluetoothClientBoundToFormat）；未绑定时是空串。 */
  binding_text(): string {
    return this.is_bound() ? `已绑定到：${this.boundDeviceName}` : '';
  }
}

/**
 * 原版 Show(...) 的一次性通道。
 * 客户端列表是对象数组（不是 AppStorage 能安全承载的基本类型），所以与
 * AirPlayDeviceSelectionWindow 用 WindowServices 一样，走一个静态挂点；
 * 其余标量入参与结果仍走 AppStorage，便于调用方与日志核对。
 */
export class BluetoothClientBindingRequest {
  targetName: string = '';
  suggestedId: string = '';
  clients: BluetoothClientInfo[] = [];
  on_result: (selectedId: string | null) => void = (): void => {};

  constructor(targetName: string, suggestedId: string, clients: BluetoothClientInfo[],
              on_result: (selectedId: string | null) => void) {
    this.targetName = targetName;
    this.suggestedId = suggestedId;
    this.clients = clients;
    this.on_result = on_result;
  }
}

export class BluetoothClientBindingChannel {
  static pending: BluetoothClientBindingRequest | null = null;
}

/**
 * 本地模拟数据（仅在调用方没有传 clients 时使用）。
 * 数据来源说明：原版对应 BluetoothHidMouseService 的 _clientStates / _clientConnectedAt
 * （GATT 订阅者表，见 BluetoothHidMouseService.cs:84 / :88），鸿蒙无 GATT Server 能力，
 * 这三行只是为了还原「列表 + 连接时间 + 已绑定徽标」三种视觉状态。
 */
/**
 * 演示数据 —— **只在本机没有真实蓝牙客户端、且调用方也没传列表时**用来还原
 * 「条目 + 连接时间 + 已绑定徽标」三种视觉状态（例如 DevEco 预览、UI 走查）。
 *
 * ★ 曾经这里写的是「鸿蒙不支持 BLE HID 外设模式」并把它当成**唯一**数据源 ——
 *   那是错的：本移植已经用 ble.createGattServer() 做出了真的外设，真实列表来自
 *   `BluetoothHidPeripheral.connectedClients()`。这份演示数据现在只在
 *   `clients_from_hid()` 返回空**且**调用方没传列表时兜底，并且会在窗口里
 *   明确标注「以下为演示数据，不是真实连接」。
 */
export const SAMPLE_CLIENTS: BluetoothClientInfo[] = [
  new BluetoothClientInfo('gatt-client-8f21', 'iPhone', 'A4:83:E7:21:9C:0D',
    '2026-09-13 22:31:07'),
  new BluetoothClientInfo('gatt-client-3c07', 'iPad Pro', '7C:2A:31:5E:88:19',
    '2026-09-13 22:29:44'),
  new BluetoothClientInfo('gatt-client-b195', 'iPhone', 'D0:81:7A:4F:2B:36',
    '2026-09-13 21:58:12', '客厅 iPhoneMirror'),
];

/**
 * 真实客户端列表 —— 从 BLE HID 外设当前的 GATT 连接来。
 *
 * 与原版 `_clientStates` 的对应关系：
 *   · Id        → 用蓝牙地址当 Id（鸿蒙不给"客户端句柄"这种东西）
 *   · DisplayName → `connection.getRemoteDeviceName()` 查到的名字；查不到留空，
 *                   `display_name()` 会退回 BluetoothClientUnknownName「未命名蓝牙设备」
 *   · Address   → GATT connectionStateChange 给的 deviceId
 *   · ConnectedAtText → 本地连接时刻
 *   · BoundDeviceName → 本移植未持久化绑定，一律空串（不编造）
 */
export function clients_from_hid(): BluetoothClientInfo[] {
  let result: BluetoothClientInfo[] = [];
  try {
    const hid = BluetoothHidPeripheral.shared();
    const clients: BluetoothHidClient[] = hid.connectedClients();
    for (let i: number = 0; i < clients.length; i++) {
      result.push(new BluetoothClientInfo(clients[i].address, clients[i].name,
        clients[i].address, clients[i].connectedAtText));
    }
  } catch (error) {
    const err = error as BusinessError;
    hilog.warn(DOMAIN, TAG, '读取 BLE HID 客户端失败: %{public}s', err.message);
    result = [];
  }
  return result;
}

/** 原版 BluetoothClientBindingTargetFormat 的 {0}。 */
const S_TARGET_FORMAT = (): string => t('请选择与“{0}”对应的蓝牙手机');
/** Strings: BluetoothClientBindingHint */
const S_HINT = (): string => t('首次使用此投屏设备时，请确认列表中的蓝牙客户端就是当前设备。之后切换选项卡会自动使用此绑定。');
/** Strings: BluetoothClientBindingUnbind */
const S_UNBIND = (): string => t('解除绑定');
/** Strings: BluetoothClientBindingRefresh（也是刷新按钮的 ToolTip / AutomationProperties.Name） */
const S_REFRESH = (): string => t('刷新蓝牙客户端');
/** Strings: BluetoothClientBindingConfirm */
const S_CONFIRM = (): string => t('确认绑定');
/** Strings: Cancel */
const S_CANCEL = (): string => t('取消');
/** Strings: BluetoothClientBindingTitle */
const S_TITLE = (): string => t('绑定蓝牙手机');
/** 平台替换 ①：列表为演示数据（真实客户端为空时）时才显示的常驻说明。 */
const S_MOCK_NOTE: string =
  '以上为演示数据：当前没有蓝牙客户端连着本机（真实列表来自 BLE HID 外设的 GATT 连接）。';
/** 刷新成功但有结果时的格式（原版 BluetoothClientBindingRefresh 的语义）。 */
const S_REFRESH_OK_FORMAT = (): string => t('已刷新：{0} 个蓝牙客户端');
/** 刷新成功但一个都没有。 */
const S_REFRESH_EMPTY: string =
  '已刷新：当前没有蓝牙客户端连接。请先在设置面板开启蓝牙反向控制，再在 iPhone 的「蓝牙」里连接本机。';
/** 解除绑定的真实结果说明（本移植没有持久化绑定）。 */
const S_UNBIND_OK_FORMAT = (): string => t('已清除「{0}」的绑定标记（本移植未做持久化，重启后回到原状）');
const S_UNBIND_NONE = (): string => t('该条目当前没有绑定标记可清除。');

/** 条目里那颗「解除绑定」按钮（原版 Padding="10,5"、跟随隐式 Button 的圆角 11）。 */
@Component
struct UnbindButton {
  @State hovered: boolean = false;
  on_action: () => void = (): void => {};

  build() {
    Text(S_UNBIND())
      .fontSize(12)
      .fontWeight(FontWeight.Bold)
      .fontColor(TEXT)
      .textAlign(TextAlign.Center)
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .borderRadius(BUTTON_CORNER)
      .backgroundColor(this.hovered ? CONTROL_HOVER : CONTROL_FILL)
      .border({ width: 1, color: BORDER })
      .margin({ left: 12 })
      .alignSelf(ItemAlign.Center)
      .onHover((isHover: boolean): void => { this.hovered = isHover; })
      .onClick((): void => { this.on_action(); });
  }
}

/** 原版 Style=IconButton 的刷新按钮（SymbolIcon ArrowClockwise20 / FontSize 18）。 */
@Component
struct RefreshIconButton {
  @Prop actionEnabled: boolean = true;
  @State hovered: boolean = false;
  on_action: () => void = (): void => {};

  build() {
    Row() {
      FluentSymbol({
        iconName: 'ArrowClockwise20',
        iconSize: 18,
        iconColor: TEXT,
      });
    }
    .width(40)
    .height(40)
    .borderRadius(BUTTON_CORNER)
    .backgroundColor(this.hovered ? CONTROL_HOVER : CONTROL_FILL)
    .border({ width: 1, color: BORDER })
    .justifyContent(FlexAlign.Center)
    .opacity(this.actionEnabled ? 1 : DISABLED_OPACITY)
    .onHover((isHover: boolean): void => { this.hovered = isHover; })
    .onClick((): void => {
      if (this.actionEnabled) {
        this.on_action();
      }
    });
  }
}

/** 原版 internal static string? Show(Window owner, string targetName, …)。 */
export function open_bluetooth_client_binding(ctx: common.Context,
                                              targetName: string,
                                              clients: BluetoothClientInfo[],
                                              suggestedId: string,
                                              on_result: (selectedId: string | null) => void): void {
  BluetoothClientBindingChannel.pending =
    new BluetoothClientBindingRequest(targetName, suggestedId, clients, on_result);
  AppStorage.setOrCreate<string>(ARG_KEY_TARGET_NAME, targetName);
  AppStorage.setOrCreate<string>(ARG_KEY_SUGGESTED_ID, suggestedId);
  AppStorage.setOrCreate<string>(RESULT_KEY_SELECTED_ID, '');

  const spec: SubWindowSpec = {
    name: WINDOW_NAME,
    page: PAGE_PATH,
    title: S_TITLE(),
    width: 520,                       // Width="520"
    height: 448,                      // Height="448"
    resizable: false,                 // ResizeMode="NoResize"
    minWidth: 460,                    // MinWidth="460"（NoResize 时不生效，留着备查）
    minHeight: 400,                   // MinHeight="400"
    modal: true,                      // ShowDialog()
  };
  SubWindowHost.open(ctx, spec).catch((error: BusinessError): void => {
    hilog.error(DOMAIN, TAG, '打开失败: %{public}s', error.message);
  });
}

@Entry
@Component
struct BluetoothClientBindingWindow {
  @State clients: BluetoothClientInfo[] = [];
  /** 原版 SelectedClient（BluetoothClientInfo?），-1 = null。 */
  @State selectedIndex: number = -1;
  /** 当前鼠标悬停的条目（原版 IsMouseOver 触发器）。-1 = 没有。 */
  @State hoverIndex: number = -1;
  /** 原版 _isRefreshing。 */
  @State isRefreshing: boolean = false;
  @State targetText: string = '';
  /** 动作失败时的确切原因（红字）；为空表示不显示。 */
  @State unavailableText: string = '';
  /** 刷新 / 解绑的真实结果（灰字）；为空表示不显示。与失败分开，别把成功写成红的。 */
  @State feedbackText: string = '';
  /** 列表是否为演示数据（真实客户端为空时的兜底）；为 true 时界面必须标注出来。 */
  @State showMockNote: boolean = false;

  private suggestedId: string = '';
  private request: BluetoothClientBindingRequest | null = null;
  /** 结果只允许送一次（对应 ShowDialog 只返回一次）。 */
  private resolved: boolean = false;

  aboutToAppear(): void {
    const pending: BluetoothClientBindingRequest | null = BluetoothClientBindingChannel.pending;
    BluetoothClientBindingChannel.pending = null;
    if (pending !== null) {
      this.request = pending;
      this.suggestedId = pending.suggestedId;
      this.apply_clients(pending.clients, pending.suggestedId);
      this.targetText = S_TARGET_FORMAT().replace('{0}', pending.targetName);
    } else {
      // 直接冷启动这个页面时（DevEco 预览 / 手工拉起），退回 AppStorage 里的标量入参。
      const name: string = AppStorage.get<string>(ARG_KEY_TARGET_NAME) ?? '';
      this.suggestedId = AppStorage.get<string>(ARG_KEY_SUGGESTED_ID) ?? '';
      this.apply_clients([], this.suggestedId);
      this.targetText = S_TARGET_FORMAT().replace('{0}', name);
    }
    // 右上角 X 关窗时也走取消（原版 ShowDialog 此时返回 null）。
    SubWindowHost.register_close_hook(WINDOW_NAME, (): boolean => {
      this.finish(null);
      return true;
    });
    hilog.info(DOMAIN, TAG, '待选蓝牙客户端 %{public}d 个', this.clients.length);
  }

  aboutToDisappear(): void {
    SubWindowHost.unregister_close_hook(WINDOW_NAME);
  }

  /**
   * 决定列表内容（三个来源，按可信度排序）：
   *   ① 调用方显式传入的列表（最高优先 —— 主窗口知道得比本窗口多）；
   *   ② `clients_from_hid()` 的真实 GATT 连接；
   *   ③ 都没有时退回演示数据，并**必须**把这一点显示出来（showMockNote）。
   */
  private apply_clients(from_caller: BluetoothClientInfo[], preferredId: string): void {
    if (from_caller.length > 0) {
      this.showMockNote = false;
      this.replace_clients(from_caller, preferredId);
      return;
    }
    const real: BluetoothClientInfo[] = clients_from_hid();
    if (real.length > 0) {
      this.showMockNote = false;
      this.replace_clients(real, preferredId);
      return;
    }
    this.showMockNote = true;
    this.replace_clients(SAMPLE_CLIENTS, preferredId);
  }

  /** 原版 ReplaceClients(clients, preferredId) —— 连「只有一个可绑定项就选中它」的规则一起搬。 */
  private replace_clients(clients: BluetoothClientInfo[], preferredId: string): void {
    this.clients = clients;
    let preferred: number = -1;
    let bindableCount: number = 0;
    let firstBindable: number = -1;
    for (let i: number = 0; i < clients.length; i++) {
      const client: BluetoothClientInfo = clients[i];
      if (!client.can_bind()) {
        continue;
      }
      if (firstBindable < 0) {
        firstBindable = i;
      }
      bindableCount += 1;
      if (preferredId.length > 0 && client.id === preferredId) {
        preferred = i;
      }
    }
    this.selectedIndex = preferred >= 0 ? preferred : (bindableCount === 1 ? firstBindable : -1);
    this.hoverIndex = -1;
  }

  /** 原版 CanConfirm => SelectedClient?.CanBind == true。 */
  private can_confirm(): boolean {
    return this.selectedIndex >= 0 && this.selectedIndex < this.clients.length
      && this.clients[this.selectedIndex].can_bind();
  }

  private is_selected(index: number): boolean {
    return this.selectedIndex === index;
  }

  private is_hovered(index: number): boolean {
    return this.hoverIndex === index;
  }

  /** 原版 Show(...) 的返回值通道；重复调用只生效一次。 */
  private finish(selectedId: string | null): void {
    if (this.resolved) {
      return;
    }
    this.resolved = true;
    AppStorage.setOrCreate<string>(RESULT_KEY_SELECTED_ID, selectedId === null ? '' : selectedId);
    const request: BluetoothClientBindingRequest | null = this.request;
    if (request !== null) {
      request.on_result(selectedId);
    }
    hilog.info(DOMAIN, TAG, '绑定结果=%{public}s', selectedId === null ? 'null' : selectedId);
  }

  /** 原版 OnConfirmClick。 */
  private on_confirm(): void {
    if (!this.can_confirm()) {
      return;
    }
    const selected: BluetoothClientInfo = this.clients[this.selectedIndex];
    this.finish(selected.id);
    SubWindowHost.close(WINDOW_NAME);
  }

  /** 原版 OnCancelClick。 */
  private on_cancel(): void {
    this.finish(null);
    SubWindowHost.close(WINDOW_NAME);
  }

  /** 原版 OnUnbindClick —— 见「与原版的差异 ③」。 */
  private on_unbind(index: number): void {
    if (index < 0 || index >= this.clients.length) {
      return;
    }
    const client: BluetoothClientInfo = this.clients[index];
    this.unavailableText = '';
    if (!client.is_bound()) {
      this.feedbackText = S_UNBIND_NONE();
      return;
    }
    // ★ 必须换成**新数组 + 新对象**：@State 只在引用变化时重新渲染，
    //   原地改 client.boundDeviceName 界面不会有任何反应。
    const updated: BluetoothClientInfo[] = [];
    for (let i: number = 0; i < this.clients.length; i++) {
      const item: BluetoothClientInfo = this.clients[i];
      updated.push(i === index
        ? new BluetoothClientInfo(item.id, item.name, item.address,
          item.connectedAtText, '')
        : item);
    }
    this.clients = updated;
    this.feedbackText = S_UNBIND_OK_FORMAT().replace('{0}', client.display_name());
    hilog.info(DOMAIN, TAG, '清除绑定标记: %{public}s', client.id);
  }

  /**
   * 原版 OnRefreshClick —— 见「与原版的差异 ②」。
   *
   * 现在是真的刷新：重新读一次 BLE HID 外设的当前客户端并如实报条数。
   * 一个都没有就明说 0 个，并给出下一步该做什么（而不是留一份演示数据骗自己）。
   */
  private on_refresh(): void {
    if (this.isRefreshing) {
      return;
    }
    this.isRefreshing = true;
    this.unavailableText = '';
    const real: BluetoothClientInfo[] = clients_from_hid();
    this.showMockNote = false;
    this.replace_clients(real, this.suggestedId);
    this.feedbackText = real.length > 0
      ? S_REFRESH_OK_FORMAT().replace('{0}', `${real.length}`)
      : S_REFRESH_EMPTY;
    hilog.info(DOMAIN, TAG, '刷新蓝牙客户端：%{public}d 个', real.length);
    this.isRefreshing = false;
  }

  /** Row Auto：TargetText(15 SemiBold) + Hint(Muted 11 Wrap)。 */
  @Builder
  notice() {
    Column() {
      Text(this.targetText)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT)
        .width('100%');
      Text(S_HINT())
        .fontSize(11)
        .fontColor(MUTED_TEXT)
        .width('100%')
        .margin({ top: 5 });
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%');
  }

  /** ListBox 的一个条目（ItemContainerStyle + ItemTemplate 合成一层，见文件头注释）。 */
  @Builder
  client_row(index: number) {
    Row() {
      Column() {
        Text(this.clients[index].display_name())
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT)
          .width('100%');
        Text(this.clients[index].connection_time_text())
          .fontSize(10)
          .fontColor(ACCENT_HOVER)
          .width('100%')
          .margin({ top: 4 });
        if (this.clients[index].is_bound()) {
          Text(this.clients[index].binding_text())
            .fontSize(10)
            .fontColor(SUCCESS)
            .width('100%')
            .margin({ top: 3 });
        }
        Text(this.clients[index].identifier_text())
          .fontSize(10)
          .fontColor(MUTED_TEXT)
          .width('100%')
          .margin({ top: 4 })
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .maxLines(1);
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);

      if (this.clients[index].is_bound()) {
        UnbindButton({
          on_action: (): void => { this.on_unbind(index); },
        });
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .borderRadius(8)
    .backgroundColor(this.is_selected(index) ? COMBO_ITEM_SELECTED
      : (this.is_hovered(index) ? CONTROL_HOVER : CONTROL_FILL))
    .border({ width: 1, color: this.is_selected(index) ? ACCENT : BORDER })
    .margin({ bottom: 8 })
    .onHover((isHover: boolean): void => {
      if (isHover) {
        this.hoverIndex = index;
      } else if (this.hoverIndex === index) {
        this.hoverIndex = -1;
      }
    })
    .onClick((): void => { this.selectedIndex = index; });
  }

  /** Row * ：ListBox 本体（ScrollViewer.HorizontalScrollBarVisibility="Disabled"）。 */
  @Builder
  body() {
    Scroll() {
      Column() {
        ForEach(this.clients, (item: BluetoothClientInfo, index: number): void => {
          this.client_row(index);
        }, (item: BluetoothClientInfo, index: number): string => `${index}:${item.id}`);
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start);
    }
    .width('100%')
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring);
  }

  /**
   * 脚注：动作失败原因（红）+ 动作真实结果（灰）+ 演示数据说明（灰）。
   *
   * ⚠ 原版没有这一块（它在 Row * 与 Row Auto 之间新增了一行 Auto），是「不静默假装成功」
   *   的必需出口，故新增并在此注明。演示数据说明只在真的用了演示数据时才出现 ——
   *   常驻一句"列表为模拟数据"在已经有真实列表时会变成谎言。
   */
  @Builder
  footer() {
    Column() {
      if (this.unavailableText.length > 0) {
        error_text(this.unavailableText);
      }
      if (this.feedbackText.length > 0) {
        hint_text(this.feedbackText);
      }
      if (this.showMockNote) {
        hint_text(S_MOCK_NOTE);
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%');
  }

  /** Row Auto：六列 = * / 刷新 / 8 / 取消 / 8 / 确认绑定（整体靠右，列间距 8）。 */
  @Builder
  actions() {
    RefreshIconButton({
      actionEnabled: !this.isRefreshing,
      on_action: (): void => { this.on_refresh(); },
    });

    Row() {
      SecondaryButton({
        label: S_CANCEL(),
        minButtonWidth: 88,
        on_action: (): void => { this.on_cancel(); },
      });
    }
    .margin({ left: 8 });

    Row() {
      PrimaryButton({
        label: S_CONFIRM(),
        minButtonWidth: 132,
        actionEnabled: this.can_confirm(),
        on_action: (): void => { this.on_confirm(); },
      });
    }
    .margin({ left: 8 });
  }

  build() {
    Column() {
      SubWindowShell({
      windowName: WINDOW_NAME,
      title: S_TITLE(),
      subtitle: '',                    // 原版这个窗口的表头没有 SubWindowSubtitle
      gap: SUBWINDOW_ROW_GAP,          // 行 1 = 16
      hasNotice: true,                 // 行 2 = TargetText + Hint
      noticeGap: 12,                   // 行 3 = 12
      hasFooter: true,                 // 新增：不可用原因 + 模拟数据说明（见 footer 注释）
      footerGap: 10,
      hasActions: true,
      actionGap: SUBWINDOW_ROW_GAP_NARROW,  // 行 5 = 14
      actionsSplit: false,             // 整排靠右
      notice: (): void => { this.notice(); },
      content: (): void => { this.body(); },
      footer: (): void => { this.footer(); },
      actions: (): void => { this.actions(); },
    });
    }
  }
}
