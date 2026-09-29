// DeviceViewModel.ets —— 设备视图模型的忠实搬用
//
// 数据源（逐条对应）：
//   src/App/Models/DeviceViewModel.cs      （147 行）
//   src/App/Services/AppleProductNames.cs  （64 行，同文件底部）
//   src/App/Interop/NativeCore.cs          （ConnectionState 枚举）
//
// ── 与原版的对应关系 ───────────────────────────────────────────────────────
//   C# 属性                 → 这里的方法     说明
//   Udid / Name / ...        → 同名字段       纯数据
//   DisplayName              → display_name() 计算属性（原来是 get-only property）
//   ModelDisplay             → model_display()
//   OsDisplay                → os_display()
//   ShortUdid                → short_udid()
//   Ready                    → ready()
//   StatusDisplay            → status_display()
//   UpdateFrom(source)       → update_from(source)
//   NotifyLanguageChanged()  → 不需要（单语言移植，文案是编译期常量）
//
// ── 为什么计算属性改成方法 ─────────────────────────────────────────────────
//   ArkTS 的 class 支持 getter，但计算属性在 ArkUI 里被 @State 引用时，
//   框架对 getter 的依赖收集不如普通方法可控；而且原版这几个属性的值依赖
//   语言切换事件（NotifyLanguageChanged），单语言移植后是纯函数，
//   写成方法语义更清楚。调用处一律写 `device.display_name()`。
//
// ── 唯一一处平台替换 ───────────────────────────────────────────────────────
//   原版 `LocalizationService.Get("Xxx")` 在属性访问时查表；这里按
//   Strings.zh-CN.xaml 的取值直接内联成常量（与本项目其它窗口的做法一致）。
//   每个常量后面都标了原来的资源键，便于核对。

/** src/App/Interop/NativeCore.cs: internal enum ConnectionState : int */
export enum ConnectionState {
  Disconnected = 0,
  UsbPresentNoMux = 1,
  Connected = 2,
  Paired = 3,
  Ready = 4,
  Error = 5,
}

/** src/App/Models/DeviceViewModel.cs 顶部的两个常量。 */
export const WIRELESS_UDID_PREFIX: string = 'airplay://';
export const MEDIA_CAST_UDID: string = 'media-cast://active';

/** src/App/Interop/NativeCore.cs 里的 NativeDeviceInfo（FromNative 的入参）。 */
export interface NativeDeviceInfo {
  udid: string;
  name: string;
  productType: string;
  osVersion: string;
  connectionType: string;
  status: string;
  state: ConnectionState;
}

// ───────────────────── Strings.zh-CN.xaml 的取值（逐键标注） ─────────────────────

/** MediaCastDeviceName */
const S_MEDIA_CAST_DEVICE_NAME: string = '视频应用投屏';
/** MediaCastDeviceModel */
const S_MEDIA_CAST_DEVICE_MODEL: string = 'AirPlay / DLNA 视频';
/** MediaCastDeviceConnection */
const S_MEDIA_CAST_DEVICE_CONNECTION: string = '网络媒体投放';
/** MediaCastDeviceActive */
const S_MEDIA_CAST_DEVICE_ACTIVE: string = '正在投放视频';
/** ModelLoading */
const S_MODEL_LOADING: string = '型号读取中';
/** WirelessLocalNetwork */
const S_WIRELESS_LOCAL_NETWORK: string = '本地网络';
/** WirelessConnected */
const S_WIRELESS_CONNECTED: string = 'AirPlay 已连接';
/** ConnectionDisconnected */
const S_CONNECTION_DISCONNECTED: string = '未连接';
/** ConnectionUsbNoMux */
const S_CONNECTION_USB_NO_MUX: string = 'USB 已连接，等待 Apple 通道';
/** ConnectionConnected */
const S_CONNECTION_CONNECTED: string = '已连接';
/** ConnectionPaired */
const S_CONNECTION_PAIRED: string = '已配对，请解锁设备';
/** ConnectionReady */
const S_CONNECTION_READY: string = '已连接并配对';
/** ConnectionError */
const S_CONNECTION_ERROR: string = '设备连接异常';

/**
 * src/App/Services/AppleProductNames.cs —— KnownProducts 字典。
 * 大小写不敏感（原版 StringComparer.OrdinalIgnoreCase），所以查表时先转小写。
 * 一个都不删、一个都不改。
 */
const KNOWN_PRODUCTS: Map<string, string> = new Map<string, string>([
  ['iphone8,1', 'iPhone 6s'],
  ['iphone8,2', 'iPhone 6s Plus'],
  ['iphone8,4', 'iPhone SE (1st generation)'],
  ['iphone9,1', 'iPhone 7'],
  ['iphone9,3', 'iPhone 7'],
  ['iphone9,2', 'iPhone 7 Plus'],
  ['iphone9,4', 'iPhone 7 Plus'],
  ['iphone10,1', 'iPhone 8'],
  ['iphone10,4', 'iPhone 8'],
  ['iphone10,2', 'iPhone 8 Plus'],
  ['iphone10,5', 'iPhone 8 Plus'],
  ['iphone10,3', 'iPhone X'],
  ['iphone10,6', 'iPhone X'],
  ['iphone11,2', 'iPhone XS'],
  ['iphone11,4', 'iPhone XS Max'],
  ['iphone11,6', 'iPhone XS Max'],
  ['iphone11,8', 'iPhone XR'],
  ['iphone12,1', 'iPhone 11'],
  ['iphone12,3', 'iPhone 11 Pro'],
  ['iphone12,5', 'iPhone 11 Pro Max'],
  ['iphone12,8', 'iPhone SE (2nd generation)'],
  ['iphone13,1', 'iPhone 12 mini'],
  ['iphone13,2', 'iPhone 12'],
  ['iphone13,3', 'iPhone 12 Pro'],
  ['iphone13,4', 'iPhone 12 Pro Max'],
  ['iphone14,2', 'iPhone 13 Pro'],
  ['iphone14,3', 'iPhone 13 Pro Max'],
  ['iphone14,4', 'iPhone 13 mini'],
  ['iphone14,5', 'iPhone 13'],
  ['iphone14,6', 'iPhone SE (3rd generation)'],
  ['iphone14,7', 'iPhone 14'],
  ['iphone14,8', 'iPhone 14 Plus'],
  ['iphone15,2', 'iPhone 14 Pro'],
  ['iphone15,3', 'iPhone 14 Pro Max'],
  ['iphone15,4', 'iPhone 15'],
  ['iphone15,5', 'iPhone 15 Plus'],
  ['iphone16,1', 'iPhone 15 Pro'],
  ['iphone16,2', 'iPhone 15 Pro Max'],
  ['iphone17,1', 'iPhone 16 Pro'],
  ['iphone17,2', 'iPhone 16 Pro Max'],
  ['iphone17,3', 'iPhone 16'],
  ['iphone17,4', 'iPhone 16 Plus'],
  ['iphone17,5', 'iPhone 16e'],
  ['iphone18,1', 'iPhone 17 Pro'],
  ['iphone18,2', 'iPhone 17 Pro Max'],
  ['iphone18,3', 'iPhone 17'],
  ['iphone18,4', 'iPhone Air'],
]);

/** AppleProductNames.Resolve(productType)：查不到就原样返回。 */
export function resolve_apple_product_name(productType: string): string {
  if (productType === undefined || productType === null || productType.trim().length === 0) {
    return '';
  }
  const found: string | undefined = KNOWN_PRODUCTS.get(productType.toLowerCase());
  return found !== undefined ? found : productType;
}

function is_blank(value: string): boolean {
  return value === undefined || value === null || value.trim().length === 0;
}

export class DeviceViewModel {
  readonly udid: string;
  name: string;
  productType: string;
  osVersion: string;
  connectionType: string;
  status: string;
  state: ConnectionState;

  constructor(udid: string, name: string, productType: string, osVersion: string,
              connectionType: string, status: string, state: ConnectionState) {
    this.udid = udid;
    this.name = name;
    this.productType = productType;
    this.osVersion = osVersion;
    this.connectionType = connectionType;
    this.status = status;
    this.state = state;
  }

  // ── 计算属性 ──

  /** DeviceViewModel.DisplayName */
  display_name(): string {
    if (this.is_media_cast()) {
      return S_MEDIA_CAST_DEVICE_NAME;
    }
    return is_blank(this.name) ? 'iPhone' : this.name;
  }

  /** DeviceViewModel.ModelDisplay */
  model_display(): string {
    if (this.is_media_cast()) {
      return S_MEDIA_CAST_DEVICE_MODEL;
    }
    if (is_blank(this.productType)) {
      return this.is_wireless() ? 'AirPlay' : S_MODEL_LOADING;
    }
    return resolve_apple_product_name(this.productType);
  }

  /** DeviceViewModel.OsDisplay */
  os_display(): string {
    if (this.is_media_cast()) {
      return S_MEDIA_CAST_DEVICE_CONNECTION;
    }
    if (is_blank(this.osVersion)) {
      return this.is_wireless() ? S_WIRELESS_LOCAL_NETWORK : 'iOS -';
    }
    if (this.is_wireless()) {
      return `iOS ${this.osVersion} · ${S_WIRELESS_LOCAL_NETWORK}`;
    }
    return `iOS ${this.osVersion}`;
  }

  /** DeviceViewModel.ShortUdid */
  short_udid(): string {
    if (this.is_media_cast()) {
      return 'AirPlay / DLNA';
    }
    if (this.is_wireless()) {
      return 'AirPlay';
    }
    if (this.udid.length <= 18) {
      return this.udid;
    }
    return `${this.udid.substring(0, 8)}...${this.udid.substring(this.udid.length - 6)}`;
  }

  /** DeviceViewModel.AutomationId */
  automation_id(): string {
    return this.is_media_cast() ? 'MediaCastDeviceCard' : 'DeviceCard';
  }

  /** DeviceViewModel.Ready */
  ready(): boolean {
    return this.state === ConnectionState.Ready;
  }

  /** DeviceViewModel.IsWireless */
  is_wireless(): boolean {
    return DeviceViewModel.is_wireless_udid(this.udid);
  }

  /** DeviceViewModel.IsMediaCast */
  is_media_cast(): boolean {
    return DeviceViewModel.is_media_cast_udid(this.udid);
  }

  /** DeviceViewModel.StatusDisplay */
  status_display(): string {
    if (this.is_media_cast()) {
      return S_MEDIA_CAST_DEVICE_ACTIVE;
    }
    if (this.is_wireless()) {
      return S_WIRELESS_CONNECTED;
    }
    switch (this.state) {
      case ConnectionState.Disconnected:
        return S_CONNECTION_DISCONNECTED;
      case ConnectionState.UsbPresentNoMux:
        return S_CONNECTION_USB_NO_MUX;
      case ConnectionState.Connected:
        return S_CONNECTION_CONNECTED;
      case ConnectionState.Paired:
        return S_CONNECTION_PAIRED;
      case ConnectionState.Ready:
        return S_CONNECTION_READY;
      default:
        return S_CONNECTION_ERROR;
    }
  }

  // ── 变更 ──

  /**
   * DeviceViewModel.UpdateFrom(source)。
   * 原版用 Set<T> 逐字段比较，返回「是否有变化」；这里保持同样的返回值语义。
   * Udid 不同则抛错（原版抛 ArgumentException）。
   */
  update_from(source: DeviceViewModel): boolean {
    if (!DeviceViewModel.udid_equals(this.udid, source.udid)) {
      throw new Error('Cannot update a device item from a different UDID.');
    }
    let changed: boolean = false;
    if (this.name !== source.name) {
      this.name = source.name;
      changed = true;
    }
    if (this.productType !== source.productType) {
      this.productType = source.productType;
      changed = true;
    }
    if (this.osVersion !== source.osVersion) {
      this.osVersion = source.osVersion;
      changed = true;
    }
    if (this.connectionType !== source.connectionType) {
      this.connectionType = source.connectionType;
      changed = true;
    }
    if (this.status !== source.status) {
      this.status = source.status;
      changed = true;
    }
    if (this.state !== source.state) {
      this.state = source.state;
      changed = true;
    }
    return changed;
  }

  /** DeviceViewModel.AsUsbPresentNoMux() */
  as_usb_present_no_mux(): DeviceViewModel {
    return new DeviceViewModel(this.udid, this.name, this.productType, this.osVersion,
      this.connectionType, this.status, ConnectionState.UsbPresentNoMux);
  }

  // ── 静态工具 ──

  /** DeviceViewModel.UdidEquals */
  static udid_equals(left: string, right: string): boolean {
    if (left === undefined || left === null || right === undefined || right === null) {
      return left === right;
    }
    return left.toLowerCase() === right.toLowerCase();
  }

  /** DeviceViewModel.IsWirelessUdid */
  static is_wireless_udid(udid: string): boolean {
    if (udid === undefined || udid === null) {
      return false;
    }
    return udid.toLowerCase().startsWith(WIRELESS_UDID_PREFIX);
  }

  /** DeviceViewModel.GetUsbUdid */
  static get_usb_udid(udid: string): string | null {
    if (is_blank(udid)) {
      return null;
    }
    return DeviceViewModel.is_wireless_udid(udid)
      ? udid.substring(WIRELESS_UDID_PREFIX.length)
      : udid;
  }

  /** DeviceViewModel.IsMediaCastUdid */
  static is_media_cast_udid(udid: string): boolean {
    if (udid === undefined || udid === null) {
      return false;
    }
    return udid.toLowerCase() === MEDIA_CAST_UDID;
  }

  /** DeviceViewModel.CreateMediaCast() */
  static create_media_cast(): DeviceViewModel {
    return new DeviceViewModel(MEDIA_CAST_UDID, S_MEDIA_CAST_DEVICE_NAME, '', '',
      'AirPlay / DLNA', '', ConnectionState.Ready);
  }

  /** DeviceViewModel.FromNative(info) */
  static from_native(info: NativeDeviceInfo): DeviceViewModel {
    return new DeviceViewModel(
      info.udid !== undefined && info.udid !== null ? info.udid : '',
      info.name !== undefined && info.name !== null ? info.name : 'iPhone',
      info.productType !== undefined && info.productType !== null ? info.productType : '',
      info.osVersion !== undefined && info.osVersion !== null ? info.osVersion : '',
      info.connectionType !== undefined && info.connectionType !== null ? info.connectionType : 'USB',
      info.status !== undefined && info.status !== null ? info.status : '',
      info.state);
  }
}
