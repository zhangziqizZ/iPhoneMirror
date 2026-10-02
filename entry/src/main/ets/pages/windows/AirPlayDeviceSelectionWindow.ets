// AirPlayDeviceSelectionWindow.ets —— 子窗口 3/20：选择 AirPlay 设备
//
// 逐项对照上游 src/App/Windows/AirPlayDeviceSelectionWindow.xaml（11 行）
//              src/App/Windows/AirPlayDeviceSelectionWindow.xaml.cs（22 行）
//
// ── 窗口属性（XAML 根元素 <ui:FluentWindow>）────────────────────────────────
//   Title="{DynamicResource DeviceBindingAirPlaySelectTitle}"  → 「选择 AirPlay 设备」
//   Width="460" Height="410" MinWidth="400" MinHeight="340"
//   WindowStartupLocation="CenterOwner"  → SubWindowHost.open 里算居中
//   ResizeMode="NoResize"                → resizable: false
//   ExtendsContentIntoTitleBar="True"    → decorEnabled: false + 自绘表头
//   Background="{DynamicResource AppBackgroundBrush}" → shell 默认底色
//
// ── 行定义（Grid.RowDefinitions，7 行）──────────────────────────────────────
//   Row Auto : SubWindowHeader（只有标题，没有 SubWindowSubtitle）
//   Row 16   : 间隔
//   Row Auto : StackPanel —— 标题 15 SemiBold + 说明 Muted 11 Wrap（Margin 0,5,0,0）
//   Row 12   : 间隔
//   Row *    : ListBox（BorderThickness 0 / Background Transparent）
//   Row 14   : 间隔
//   Row Auto : 靠右的按钮条（取消 MinWidth 88 / 创建档案 Primary MinWidth 108，间距 8）
//
// ── ListBox 条目样式（原版写在 ItemContainerStyle 的 ControlTemplate 里）────
//   Border x:Name="Root"  ControlFillBrush 底 / BorderBrush 1px 边 / 圆角 8 / Padding 12
//   ItemContainerStyle: Padding 0 / Margin 0,0,0,8 / HorizontalContentAlignment Stretch
//   Trigger IsMouseOver=True  → Root.Background = ControlHoverBrush
//   Trigger IsSelected=True   → Root.Background = ComboItemSelectedBrush
//                               Root.BorderBrush = AccentBrush
//   注意两个 Trigger 的先后：IsSelected 在后面，所以「既 hover 又选中」时以选中态为准。
//
// ── 条目内容（ItemTemplate）───────────────────────────────────────────────
//   TextBlock DisplayName     FontWeight SemiBold
//   TextBlock ModelDisplay    FontSize 11 / MutedTextBrush / Margin 0,4,0,0
//
// ── xaml.cs 的行为 ────────────────────────────────────────────────────────
//   CanConfirm => SelectedDevice is not null      → 没选中时「创建档案」是禁用的
//   ConfirmClick: if (CanConfirm) DialogResult = true;
//   CancelClick : DialogResult = false;          （右上角关闭按钮也走这个）
//   Show(owner, devices) → ShowDialog() == true ? SelectedDevice : null
//
// ── 平台替换 ──────────────────────────────────────────────────────────────
//   原版构造函数收 devices，ShowDialog() 同步返回结果。鸿蒙开窗只能给页面路径，
//   所以走 WindowServices.pending_device_selection 这个一次性通道
//   （入参 + 结果回调），语义等价：确认给设备、取消/关闭给 null。
//   为了「关窗必定回调一次」，这里注册了关窗钩子（右上角 X 也走它）。

import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  SubWindowShell, SubWindowHost, SecondaryButton, PrimaryButton,
  SUBWINDOW_ROW_GAP, SUBWINDOW_ROW_GAP_NARROW,
  SubWindowSpec,
} from '../../common/SubWindow';
import {
  TEXT, MUTED_TEXT, CONTROL_FILL, CONTROL_HOVER, COMBO_ITEM_SELECTED, ACCENT, BORDER,
} from '../../common/Theme';
import { DeviceViewModel } from '../../common/DeviceViewModel';
import { WindowServices, DeviceSelectionRequest } from '../../common/WindowServices';
import { t } from '../../common/i18n';

const TAG: string = 'im_airplay_select';
const DOMAIN: number = 0x0100;

export const WINDOW_NAME: string = 'AirPlayDeviceSelectionWindow';
export const PAGE_PATH: string = 'pages/windows/AirPlayDeviceSelectionWindow';

/**
 * 原版 internal static DeviceViewModel? Show(Window owner, IReadOnlyList<DeviceViewModel> devices)。
 * 同步返回改成了回调：on_result(选中设备) 或 on_result(null)。
 */
export function open_airplay_device_selection(ctx: common.Context,
                                              devices: DeviceViewModel[],
                                              on_result: (selected: DeviceViewModel | null) => void): void {
  WindowServices.pending_device_selection = new DeviceSelectionRequest(devices, on_result);

  const spec: SubWindowSpec = {
    name: WINDOW_NAME,
    page: PAGE_PATH,
    title: '选择 AirPlay 设备',      // Strings: DeviceBindingAirPlaySelectTitle
    width: 460,
    height: 410,
    resizable: false,                // ResizeMode="NoResize"
    minWidth: 400,                   // XAML 里的 MinWidth（NoResize 时不生效，留着备查）
    minHeight: 340,
    modal: true,                     // ShowDialog()
  };
  SubWindowHost.open(ctx, spec).catch((error: BusinessError): void => {
    hilog.error(DOMAIN, TAG, '打开失败: %{public}s', error.message);
  });
}

@Entry
@Component
struct AirPlayDeviceSelectionWindow {
  @State devices: DeviceViewModel[] = [];
  /** 原版 SelectedDevice：没选中是 null，这里用下标表示（-1 = 未选中）。 */
  @State selectedIndex: number = -1;
  /** 当前鼠标悬停的条目（原版 IsMouseOver 触发器）。-1 表示没有。 */
  @State hoverIndex: number = -1;

  private request: DeviceSelectionRequest | null = null;
  /** 结果回调只允许发一次（对应 ShowDialog 只返回一次）。 */
  private resolved: boolean = false;

  aboutToAppear(): void {
    // 取走入参并置空 —— 对应原版「每个窗口实例自带一份构造参数」。
    const pending: DeviceSelectionRequest | null = WindowServices.pending_device_selection;
    WindowServices.pending_device_selection = null;
    if (pending !== null) {
      this.request = pending;
      this.devices = pending.devices;
    }
    // 右上角 X 关窗时也要把结果送出去（原版 ShowDialog 在此时返回 null）。
    SubWindowHost.register_close_hook(WINDOW_NAME, (): boolean => {
      this.finish(null);
      return true;
    });
    hilog.info(DOMAIN, TAG, '待选设备 %{public}d 台', this.devices.length);
  }

  aboutToDisappear(): void {
    SubWindowHost.unregister_close_hook(WINDOW_NAME);
  }

  /** 原版 CanConfirm => SelectedDevice is not null。 */
  private can_confirm(): boolean {
    return this.selectedIndex >= 0 && this.selectedIndex < this.devices.length;
  }

  /** 把结果回调出去；重复调用只生效一次。 */
  private finish(selected: DeviceViewModel | null): void {
    if (this.resolved) {
      return;
    }
    this.resolved = true;
    const request: DeviceSelectionRequest | null = this.request;
    if (request !== null) {
      request.on_result(selected);
    }
  }

  /** 原版 ConfirmClick。 */
  private on_confirm(): void {
    if (!this.can_confirm()) {
      return;
    }
    const selected: DeviceViewModel = this.devices[this.selectedIndex];
    this.finish(selected);
    SubWindowHost.close(WINDOW_NAME);
  }

  /** 原版 CancelClick。 */
  private on_cancel(): void {
    this.finish(null);
    SubWindowHost.close(WINDOW_NAME);
  }

  /** Row Auto：标题 15 SemiBold + 说明 Muted 11 Wrap。 */
  @Builder
  notice() {
    Column() {
      Text('添加 AirPlay 设备档案')            // Strings: DeviceBindingAirPlayAddTitle
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT)
        .width('100%');
      Text('选择当前正在镜像的 AirPlay 设备以创建档案。')  // DeviceBindingAirPlaySelectDescription
        .fontSize(11)
        .fontColor(MUTED_TEXT)
        .width('100%')
        .margin({ top: 5 });
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%');
  }

  /** ListBox 的一个条目。 */
  @Builder
  device_row(index: number) {
    Column() {
      Text(this.devices[index].display_name())
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT)
        .width('100%');
      Text(this.devices[index].model_display())
        .fontSize(11)
        .fontColor(MUTED_TEXT)
        .width('100%')
        .margin({ top: 4 });
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(12)
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

  private is_selected(index: number): boolean {
    return this.selectedIndex === index;
  }

  private is_hovered(index: number): boolean {
    return this.hoverIndex === index;
  }

  /** Row * ：ListBox 本体。 */
  @Builder
  body() {
    Scroll() {
      Column() {
        ForEach(this.devices, (item: DeviceViewModel, index: number): void => {
          this.device_row(index);
        }, (item: DeviceViewModel, index: number): string => `${index}:${item.udid}`);
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start);
    }
    .width('100%')
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring);
  }

  /** Row Auto：靠右的按钮条（取消 MinWidth 88 / 创建档案 Primary MinWidth 108）。 */
  @Builder
  actions() {
    SecondaryButton({
      label: '取消',                     // Strings: DeviceBindingCancel
      minButtonWidth: 88,
      on_action: (): void => { this.on_cancel(); },
    });
    Row() {
      PrimaryButton({
        label: '创建档案',                // Strings: DeviceBindingCreateProfile
        minButtonWidth: 108,
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
      title: '选择 AirPlay 设备',
      subtitle: '',                   // 原版这个窗口的表头没有 SubWindowSubtitle
      gap: SUBWINDOW_ROW_GAP,         // 行 1 = 16
      hasNotice: true,                // 行 2 = 标题+说明
      noticeGap: 12,                  // 行 3 = 12
      hasFooter: false,
      hasActions: true,
      actionGap: SUBWINDOW_ROW_GAP_NARROW,   // 行 5 = 14
      actionsSplit: false,
      notice: (): void => { this.notice(); },
      content: (): void => { this.body(); },
      actions: (): void => { this.actions(); },
    });
    }
  }
}
