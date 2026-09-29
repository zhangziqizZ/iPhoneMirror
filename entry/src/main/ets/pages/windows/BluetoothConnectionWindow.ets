// BluetoothConnectionWindow.ets —— 子窗口 13/20：等待 Bluetooth HID 连接（设备档案绑定流程）
//
// 逐项对照上游
//   src/App/Windows/BluetoothConnectionWindow.xaml（9 行，整段压在一行里）
//   src/App/Windows/BluetoothConnectionWindow.xaml.cs（26 行）
// ★ 这个窗口**只有 main（1.8.4）有**，linux（1.8.1）分支里没有，全仓库仅此一处来源。
//
// ── 窗口属性（XAML 根元素 <ui:FluentWindow> 那一行）──────────────────────────
//   Title="{DynamicResource DeviceBindingBluetoothWaitingTitle}"  → 「等待 Bluetooth HID 连接」
//   Width="500" Height="390" MinWidth="440" MinHeight="340"
//   WindowStartupLocation="CenterOwner"   → SubWindowHost.open 里算居中
//   ResizeMode="NoResize"                 → resizable: false
//   ExtendsContentIntoTitleBar="True"     → decorEnabled: false + 自绘表头
//   WindowBackdropType="Mica" / WindowCornerPreference="Round"  → 系统窗口负责
//   Background="{DynamicResource AppBackgroundBrush}"           → shell 默认底色
//
// ── 行定义（Grid.RowDefinitions，5 行）──────────────────────────────────────
//   Row Auto : SubWindowHeader（只有标题，没有 SubWindowSubtitle）
//   Row 16   : 间隔
//   Row *    : StackPanel
//               TextBlock DeviceBindingBluetoothBroadcasting    16 / SemiBold
//               TextBlock DeviceBindingBluetoothWaitingDescription 12 / Muted / Wrap / Margin 0,10,0,0
//               Border ControlFillBrush 底 / BorderBrush 1px / 圆角 8 / Padding 12 / Margin 0,18,0,0
//                 StackPanel Orientation=Horizontal
//                   SymbolIcon Bluetooth20 / 18 / AccentBrush
//                   TextBlock DeviceBindingBluetoothWaitingStatus / Margin 9,0,0,0 / VCenter
//   Row 14   : 间隔
//   Row Auto : StackPanel Orientation=Horizontal，整体靠右（HorizontalAlignment=Right）
//              Button「取消」MinWidth 88
//              Button「下一步」PrimaryButton / MinWidth 100 / Margin 8,0,0,0
//
// ── xaml.cs 的行为（逐条照搬）─────────────────────────────────────────────
//   NextClick：
//       var clients = await _refresh();
//       var selected = BluetoothClientBindingWindow.Show(this, _targetName, clients,
//                                                        null, _refresh, _unbind);
//       if (string.IsNullOrWhiteSpace(selected)) return;   // 没选就**留在当前窗口**
//       Tag = selected; DialogResult = true;
//   CancelClick：DialogResult = false
//   Show(owner, targetName, refresh, unbind) → DialogResult == true ? Tag as string : null
//
// ── 调用方（还原时保持同一条链路）──────────────────────────────────────────
//   src/App/Windows/DeviceBindingWindow.xaml.cs:158（ConnectBluetoothClick）
//     ① _viewModel.StartBluetoothPeripheralForConfigurationAsync(target) 起 BLE 外设广播
//     ② BluetoothConnectionWindow.Show(this, profileName, GetReverseBluetoothClientsAsync,
//                                      UnbindBluetoothControlBinding)
//     ③ 拿到 clientId → _manager.Bind(profileId, DeviceIdentityType.Bluetooth, …)
//     ④ StopBluetoothPeripheralConfigurationAsync() + RefreshBluetoothClientsAsync()
//   ⚠ 这只是「保存设备绑定」，注释里明确写了「此流程只保存设备绑定，不会启动蓝牙反控」。
//
// ── 文案来源 Strings.zh-CN.xaml（main 版）─────────────────────────────────
//   DeviceBindingBluetoothWaitingTitle          「等待 Bluetooth HID 连接」
//   DeviceBindingBluetoothBroadcasting          「电脑正在广播 Bluetooth HID 设备」  ← 见平台替换 ①
//   DeviceBindingBluetoothWaitingDescription    「请在 iPhone/iPad 打开…不会启动蓝牙反控。」
//   DeviceBindingBluetoothWaitingStatus         「等待设备订阅 HID 服务」
//   DeviceBindingCancel                         「取消」
//   DeviceBindingNext                           「下一步」
//
// ═══════════════════ 平台替换（原版机制在鸿蒙没有对应物）═══════════════════
// ① 措辞里的「电脑」
//    原文 DeviceBindingBluetoothBroadcasting = 「电脑正在广播 Bluetooth HID 设备」、
//    DeviceBindingBluetoothWaitingDescription 里的「选择此电脑」。
//    鸿蒙侧是本机设备 → 分别改成「本设备正在广播 Bluetooth HID 设备」/「选择此设备」。
// ② BLE 外设广播（步骤 ① 的 StartBluetoothPeripheralForConfigurationAsync）
//    原版：BluetoothHidMouseService.StartAsync → GattServiceProvider.CreateAsync(HidServiceUuid)
//          + _provider.StartAdvertising(...)（BluetoothHidMouseService.cs:208 / :232），
//          由 iOS 在「设置 → 蓝牙」里发现并订阅 HID 服务。
//    鸿蒙：系统不提供 GATT Server / BLE 广播（对应 Windows 的
//          BluetoothLEAdvertisementPublisher 与 GattServiceProvider 均无对应能力），
//          因此**没有真实广播发生**。状态条按原版显示「等待设备订阅 HID 服务」，
//          但窗口顶部常驻一条说明明确写出这一点（见 notice 槽的说明条），不假装已广播。
// ③ 「下一步」（NextClick 的 _refresh）
//    原版：先 await _refresh() 枚举已订阅的 GATT 客户端，再打开绑定窗口。
//    鸿蒙：枚举不到真实客户端 → 照原版打开蓝牙客户端绑定窗口（纯 UI 流程完整还原），
//          客户端列表由该窗口的本地模拟数据承担，并同样在界面上注明；
//          拿不到选择结果时不关本窗口（与原版 `if (…selected) return;` 一致）。
// ④ 对话框返回值
//    原版用 DialogResult + window.Tag；鸿蒙改用 AppStorage 键（见 RESULT_KEY_CLIENT_ID）。
// ⑤ 右上角 X 与「取消」等价（原版两者都走 CancelClick）。

import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  SubWindowShell, SubWindowHost, SecondaryButton, PrimaryButton, NoticeBanner,
  SUBWINDOW_ROW_GAP, SUBWINDOW_ROW_GAP_NARROW,
  SubWindowSpec,
} from '../../common/SubWindow';
import { FluentSymbol } from '../../common/FluentIcon';
import {
  TEXT, MUTED_TEXT, ACCENT, ERROR, ERROR_SURFACE, CONTROL_FILL, BORDER,
  WARNING, WARNING_SURFACE,
} from '../../common/Theme';
import {
  BluetoothClientInfo, open_bluetooth_client_binding, clients_from_hid,
} from './BluetoothClientBindingWindow';
import { BluetoothHidPeripheral } from '../../common/BluetoothHidPeripheral';

const TAG: string = 'im_bluetooth_connection';
const DOMAIN: number = 0x0100;

export const WINDOW_NAME: string = 'BluetoothConnectionWindow';
export const PAGE_PATH: string = 'pages/windows/BluetoothConnectionWindow';

/** 原版 Show(owner, targetName, refresh, unbind) 的入参键（targetName = 档案显示名）。 */
export const ARG_KEY_TARGET_NAME: string = 'im.bluetoothConnection.targetName';
/** 结果键：确认后在绑定窗里选中的客户端 Id；取消 / 关闭时为空串。 */
export const RESULT_KEY_CLIENT_ID: string = 'im.bluetoothConnection.clientId';

/**
 * 原版 Show(owner, …) 的一次性通道：存档结果回调，以及「下一步」再次开窗时要用的
 * UIAbility 上下文（鸿蒙子窗口页面里拿不到调用方的 ctx，只能在这里暂存）。
 */
export class BluetoothConnectionChannel {
  static pending_result: ((clientId: string | null) => void) | null = null;
  static context: common.Context | null = null;
}

/** Strings: DeviceBindingBluetoothWaitingTitle */
const S_TITLE: string = '等待 Bluetooth HID 连接';
/** Strings: DeviceBindingBluetoothBroadcasting（平台替换 ①：「电脑」→「本设备」） */
const S_BROADCASTING: string = '本设备正在广播 Bluetooth HID 设备';
/** Strings: DeviceBindingBluetoothWaitingDescription（平台替换 ①：「此电脑」→「此设备」） */
const S_DESCRIPTION: string =
  '请在 iPhone/iPad 打开“设置”→“蓝牙”，在设备列表中选择此设备并完成配对。配对成功后返回这里，' +
  '点击“下一步”选择刚刚连接的 HID 设备。此流程只保存设备绑定，不会启动蓝牙反控。';
/** Strings: DeviceBindingBluetoothWaitingStatus */
const S_STATUS: string = '等待设备订阅 HID 服务';
/** Strings: DeviceBindingCancel */
const S_CANCEL: string = '取消';
/** Strings: DeviceBindingNext */
const S_NEXT: string = '下一步';
/**
 * 未在广播时的引导。
 *
 * ★ 这行此前写的是「鸿蒙不支持 BLE HID 外设模式：无 GATT Server，也不能 BLE 广播」
 *   ——**那是错的，已作废**。本移植已经用 `ble.createGattServer()` +
 *   `ble.startAdvertising()` 做出了真的 BLE HID 外设
 *   （见 common/BluetoothHidPeripheral.ets），iPhone 能搜到、能配对、能订阅 Report。
 *   所以这里不再是"能力缺失"，而是"还没开启"：给的必须是下一步该做什么。
 */
const S_NEED_ADVERTISE: string =
  '当前没有在广播 HID 设备。请先在主窗口设置面板的「蓝牙反向控制」里开启它，再回到这里配对。';

/**
 * 原版 internal static string? Show(Window owner, string targetName,
 *                                    Func<…> refresh, Func<string, bool> unbind)。
 * 同步返回改成回调：确认时给选中的客户端 Id，取消 / 关闭给 null。
 */
export function open_bluetooth_connection(ctx: common.Context,
                                          targetName: string,
                                          on_result: (clientId: string | null) => void): void {
  BluetoothConnectionChannel.pending_result = on_result;
  BluetoothConnectionChannel.context = ctx;
  AppStorage.setOrCreate<string>(ARG_KEY_TARGET_NAME, targetName);
  AppStorage.setOrCreate<string>(RESULT_KEY_CLIENT_ID, '');

  const spec: SubWindowSpec = {
    name: WINDOW_NAME,
    page: PAGE_PATH,
    title: S_TITLE,
    width: 500,                       // Width="500"
    height: 390,                      // Height="390"
    resizable: false,                 // ResizeMode="NoResize"
    minWidth: 440,                    // MinWidth="440"（NoResize 时不生效，留着备查）
    minHeight: 340,                   // MinHeight="340"
    modal: true,                      // ShowDialog()
  };
  SubWindowHost.open(ctx, spec).catch((error: BusinessError): void => {
    hilog.error(DOMAIN, TAG, '打开失败: %{public}s', error.message);
  });
}

@Entry
@Component
struct BluetoothConnectionWindow {
  /** 原版 _targetName（调用方传的是档案显示名 Profile.DisplayName）。 */
  @State targetName: string = '';
  /** 「下一步」是否已经把绑定窗口拉起过（原版是同步 ShowDialog，这里只能挂结果回调）。 */
  private bindingPending: boolean = false;
  private resolved: boolean = false;
  /** 本窗口自己的结果回调（Show 的返回值通道）。 */
  private on_result: ((clientId: string | null) => void) | null = null;
  /** 实时状态条文本（每 500ms 刷新一次）。 */
  @State liveStatus: string = '';
  /** 需要用户先去做点什么时才显示的提示条（空 = 不显示）。 */
  @State noticeText: string = '';
  /** 轮询句柄；-1 表示没在跑。 */
  private statusTimer: number = -1;

  /**
   * 读一次 BLE HID 外设的真实状态。
   *
   * 为什么要在子窗口里也刷一次：这个窗口的整个流程就是「等 iPhone 配对」，
   * 上游靠 Windows 的 GATT 订阅者事件推动界面；鸿蒙这边没有"事件推给子窗口"的
   * 通道（WindowServices 只有开关窗用），所以用一个 500ms 的轮询把它变成活的 ——
   * 否则用户站在"等待设备订阅 HID 服务"这一行前面，永远不知道配对到底成没成。
   */
  private refresh_status(): void {
    try {
      const hid = BluetoothHidPeripheral.shared();
      this.liveStatus = hid.statusText();
      if (!hid.isAdvertising()) {
        this.noticeText = S_NEED_ADVERTISE;
      } else if (hid.errorText().length > 0) {
        // 广播开着但有错（例如某次 notify 失败）—— 如实上报，不吞掉。
        this.noticeText = `蓝牙反控报告：${hid.errorText()}`;
      } else {
        this.noticeText = '';
      }
    } catch (error) {
      // 定时器回调里抛异常 = 未捕获异常 = 整个应用被结束（本项目踩过）。
      const err = error as BusinessError;
      this.liveStatus = `蓝牙状态读取异常：${err.message}`;
      this.noticeText = '';
    }
  }

  aboutToAppear(): void {
    this.targetName = AppStorage.get<string>(ARG_KEY_TARGET_NAME) ?? '';
    this.on_result = BluetoothConnectionChannel.pending_result;
    BluetoothConnectionChannel.pending_result = null;
    // 右上角 X 关窗 = 取消（原版 CancelClick）。
    SubWindowHost.register_close_hook(WINDOW_NAME, (): boolean => {
      this.finish(null);
      return true;
    });
    this.refresh_status();
    this.statusTimer = setInterval((): void => { this.refresh_status(); }, 500);
    hilog.info(DOMAIN, TAG, '等待 Bluetooth HID 连接，目标档案=%{public}s', this.targetName);
  }

  aboutToDisappear(): void {
    SubWindowHost.unregister_close_hook(WINDOW_NAME);
    if (this.statusTimer !== -1) {
      clearInterval(this.statusTimer);
      this.statusTimer = -1;
    }
  }

  /** 原版 Show(...) 的返回值通道；重复调用只生效一次。 */
  private finish(clientId: string | null): void {
    if (this.resolved) {
      return;
    }
    this.resolved = true;
    AppStorage.setOrCreate<string>(RESULT_KEY_CLIENT_ID, clientId === null ? '' : clientId);
    if (this.on_result !== null) {
      this.on_result(clientId);
    }
    hilog.info(DOMAIN, TAG, '连接结果=%{public}s', clientId === null ? 'null' : clientId);
  }

  /** 原版 NextClick —— 见平台替换 ③。 */
  private on_next(): void {
    if (this.bindingPending) {
      return;
    }
    this.bindingPending = true;
    // 原版：var clients = await _refresh();（重新枚举 GATT 订阅者）
    // 鸿蒙：同样是真的去读一次当前 GATT 连接（原版 _clientStates 的对等物）。
    // 一个都没有时传空数组，由绑定窗口自己退回演示数据并**标注出来**。
    const clients: BluetoothClientInfo[] = clients_from_hid();
    const ctx: common.Context | null = BluetoothConnectionChannel.context;
    if (ctx === null) {
      hilog.error(DOMAIN, TAG, '缺少 UIAbility 上下文，无法打开绑定窗口');
      this.bindingPending = false;
      return;
    }
    // 原版第二个参数是 suggestedId = null。
    open_bluetooth_client_binding(ctx, this.targetName,
      clients, '', (selectedId: string | null): void => {
        this.bindingPending = false;
        // 原版：if (string.IsNullOrWhiteSpace(selected)) return; —— 没选就留在本窗口。
        if (selectedId === null || selectedId.length === 0) {
          hilog.info(DOMAIN, TAG, '绑定窗口未选中客户端，留在本窗口');
          return;
        }
        this.finish(selectedId);
        SubWindowHost.close(WINDOW_NAME);
      });
  }

  /** 原版 CancelClick。 */
  private on_cancel(): void {
    this.finish(null);
    SubWindowHost.close(WINDOW_NAME);
  }

  /**
   * 表头下面的一条动态提示（新增的一行，原版没有）。
   *
   * 内容是**实时**的（每条 refresh_status 更新）：没在广播 → 引导去开户；
   * 广播有报错 → 原样报出；一切正常 → 整行不显示。
   */
  @Builder
  notice() {
    NoticeBanner({
      noticeText: this.noticeText,
      noticeTextColor: WARNING,
      surfaceColor: WARNING_SURFACE,
      bannerBorderColor: WARNING,
      noticeFontSize: 11,
    });
  }

  /** Row * ：标题 + 说明 + 状态条。 */
  @Builder
  body() {
    Column() {
      Text(S_BROADCASTING)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT)
        .width('100%');
      Text(S_DESCRIPTION)
        .fontSize(12)
        .fontColor(MUTED_TEXT)
        .width('100%')
        .margin({ top: 10 });

      // Border：ControlFillBrush 底 / 1px BorderBrush 边 / 圆角 8 / Padding 12 / Margin 0,18,0,0
      Row() {
        FluentSymbol({
          iconName: 'Bluetooth20',
          iconSize: 18,
          iconColor: ACCENT,
        });
        Text(this.liveStatus.length > 0 ? this.liveStatus : S_STATUS)
          .fontSize(12)
          .fontColor(TEXT)
          .margin({ left: 9 });
      }
      .width('100%')
      .padding(12)
      .borderRadius(8)
      .backgroundColor(CONTROL_FILL)
      .border({ width: 1, color: BORDER })
      .alignItems(VerticalAlign.Center)
      .margin({ top: 18 });
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%');
  }

  /** Row Auto：整体靠右（原版 HorizontalAlignment="Right"），两颗按钮间距 8。 */
  @Builder
  actions() {
    SecondaryButton({
      label: S_CANCEL,
      minButtonWidth: 88,
      on_action: (): void => { this.on_cancel(); },
    });

    Row() {
      PrimaryButton({
        label: S_NEXT,
        minButtonWidth: 100,
        on_action: (): void => { this.on_next(); },
      });
    }
    .margin({ left: 8 });
  }

  build() {
    Column() {
      SubWindowShell({
      windowName: WINDOW_NAME,
      title: S_TITLE,
      subtitle: '',                    // 原版这个窗口的表头没有 SubWindowSubtitle
      gap: SUBWINDOW_ROW_GAP,          // 行 1 = 16
      hasNotice: this.noticeText.length > 0,  // 只在真有话要说时才占那一行（内容实时）
      noticeGap: 12,
      hasFooter: false,
      hasActions: true,
      actionGap: SUBWINDOW_ROW_GAP_NARROW,  // 行 3 = 14
      actionsSplit: false,             // 整排靠右
      notice: (): void => { this.notice(); },
      content: (): void => { this.body(); },
      actions: (): void => { this.actions(); },
    });
    }
  }
}
