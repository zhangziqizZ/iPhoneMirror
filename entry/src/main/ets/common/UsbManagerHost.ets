// SPDX-License-Identifier: GPL-3.0-only
//
// usbManager 备用 USB 通道的 ArkTS 宿主层。
//
// ★ 为什么需要这一层 ★
//
// USB DDK 通道（OhosUsbTransport）有两个绕不开的闸门：
//   1. ACCESS_DDK_USB 要进签名 profile 的 allowed-acls —— profile 由 AGC 签发，
//      本地改不了 ⇒ 装包被拒（9568289）；
//   2. OH_Usb_GetDevices() 按 module.json5 驱动扩展声明的 VID/PID 过滤 ⇒
//      还要驱动扩展 bind 成功才看得到设备。
//
// @ohos.usbManager 这条路两个闸门都没有：
//   · 权限存在**设备级 DB 记录**里（UsbRightManager），由 requestRight() 弹一次
//     系统授权窗换来，授权一次长期有效，**不查签名 ACL**；
//   · getDevices() **不按 VID 过滤**，不需要驱动扩展。
//
// 拿到的东西是一个 fd：usbManager.getFileDescriptor(pipe)，系统 USB 服务
// open("/dev/bus/usb/BBB/DDD", O_RDWR) 后经 IPC 把这份描述符复制进本进程。
// native 侧（OhosUsbMux::connect_fd）用它在标准 usbfs 节点上做 bulk/控制传输，
// 讲完整的 usbmux/lockdownd 协议把「信任此电脑」弹窗逼出来。
//
// ★ 分工 ★
//
//   本文件（ArkTS）：设备枚举 → 授权弹窗 → 连接 → 拿 fd —— 这些 API 只在
//                   ArkTS 层开放，native 拿不到；
//   native 层      ：描述符解析、端点定位、UDID 读取、usbmux 协议、配对。
//
// ★ 明确不调 usbManager.claimInterface() ★
//
// 文档要求 bulkTransfer 前先 claimInterface，但那个 claim 是**服务侧 libusb**
// 的 claim（占用 intf->dev.driver）；而 native 的 fd 路径靠内核 usbfs 的
// per-fd 记账（proc_bulk → claimintf），两条路径一旦混用会互相顶掉。
// 我们的数据传输全部走 native fd，ArkTS 侧只当"开 fd 的门"。

import { usbManager } from '@kit.BasicServicesKit';
import { BusinessError } from '@ohos.base';

const APPLE_VENDOR_ID: number = 0x05AC;

/** 一轮"开通道"的完整结果：成功带 fd，失败带可读原因。 */
export class UsbFdChannel {
  /** true = fd 有效，可交给 native。 */
  ok: boolean = false;
  /** 走到哪一步了：authorized / connected / fd / failed（诊断用）。 */
  stage: string = '';
  /** usbManager.getFileDescriptor 的返回值；ok=false 时无意义。 */
  fd: number = -1;
  /** 设备的 device.name（"busNum-devAddr"，授权记录的键）。 */
  deviceName: string = '';
  /** 方便 UI 点名：产品名 + PID。 */
  label: string = '';
  /** 一句人读的状态（成功或失败原因，可直接进诊断行）。 */
  summary: string = '';
}

// ── 模块级状态 ────────────────────────────────────────────────
//
// requestRight 是异步弹窗，绝不能在心跳里反复触发 —— 不然授权窗一个摞一个。
// channelBusy 保证同时只有一轮尝试在飞；已授权的设备靠 hasRight() 直接放行，
// 不会再弹窗。

let channelBusy: boolean = false;
/** 已开着的 pipe。复用 fd 前提下保留它；断开/重试时先关旧的。 */
let activePipe: usbManager.USBDevicePipe | null = null;
/** 上一次成功拿到的 fd 与它的设备名。设备没变就直接复用，不再走连接流程。 */
let cachedFd: number = -1;
let cachedDeviceName: string = '';

/** 当前缓存的 fd（心跳开通道成功后有效；未开/已重置返回 -1）。
 *  供子窗口（文件管理）复用同一条通道，不必各自再开 pipe。 */
export function current_cached_fd(): number {
  return cachedFd;
}

/** 关闭之前开着的 pipe（新设备插入 / 调用方要求重置时）。 */
export function reset_usb_fd_channel(): void {  if (activePipe !== null) {
    try {
      usbManager.closePipe(activePipe);
    } catch {
      // pipe 已被系统回收（设备拔出）时 close 会抛，忽略即可。
    }
    activePipe = null;
  }
  cachedFd = -1;
  cachedDeviceName = '';
  channelBusy = false;
}

/**
 * 打开 usbManager 备用通道：授权（必要时弹窗）→ 连接 → 拿 fd。
 *
 * 返回的 fd 交给 native（pairViaUsbFd）后，native 侧自己定位 usbmux 接口、
 * 读 UDID、跑配对协议 —— 本函数不解析任何描述符。
 *
 * ★ 调用时机 ★ 由 UI 心跳驱动：检测到系统 USB 服务里出现 Apple 设备、且
 * DDK 通道没有可用设备时调用一次；channelBusy 期间重复调用会被直接拒绝。
 */
export async function open_usb_fd_channel(): Promise<UsbFdChannel> {
  const result: UsbFdChannel = new UsbFdChannel();

  if (channelBusy) {
    result.summary = '上一轮 usbManager 通道尝试还在进行，跳过';
    return result;
  }
  channelBusy = true;

  try {
    // ① 枚举。非系统应用也能拿到全部设备（不按 VID 过滤），serial 字段
    //    会被系统清空 —— 所以 UDID 由 native 侧控制传输去读，这里不指望它。
    let devices: Array<Readonly<usbManager.USBDevice>> = [];
    try {
      devices = usbManager.getDevices();
    } catch (error) {
      const failure: BusinessError = error as BusinessError;
      result.stage = 'failed';
      // 801 = Capability not supported：2in1 上这套 JS 接口可能整体不开放。
      if (failure.code === 801) {
        result.summary =
          'usbManager 能力未开放（801）：本机不支持这条备用通道';
      } else {
        result.summary = `usbManager.getDevices 失败（${failure.code}）：
          ${failure.message}`;
      }
      return result;
    }

    const apple: Readonly<usbManager.USBDevice>[] = devices.filter(
      (device: Readonly<usbManager.USBDevice>) =>
        device.vendorId === APPLE_VENDOR_ID);
    if (apple.length === 0) {
      result.stage = 'failed';
      result.summary =
        `系统 USB 服务可见 ${devices.length} 台设备，其中没有 Apple（0x05AC）`;
      return result;
    }

    // ② 授权。设备级 DB 记录，授权一次长期有效；已授权时 requestRight
    //    不弹窗、直接 resolve。
    const device: Readonly<usbManager.USBDevice> = apple[0];
    result.deviceName = device.name;
    result.label = device.productName.length > 0
      ? `${device.productName}(0x${device.productId.toString(16).toUpperCase()})`
      : device.name;

    if (cachedFd >= 0 && cachedDeviceName === device.name) {
      // 设备没换：fd 仍然有效（同一次 open 的描述符），直接复用。
      result.ok = true;
      result.stage = 'fd';
      result.fd = cachedFd;
      result.summary = `复用已开通道：${result.label}`;
      return result;
    }

    let granted: boolean = false;
    try {
      granted = usbManager.hasRight(device.name);
      if (!granted) {
        granted = await usbManager.requestRight(device.name);
      }
    } catch (error) {
      const failure: BusinessError = error as BusinessError;
      result.stage = 'failed';
      result.summary = `usbManager 授权失败（${failure.code}）：${failure.message}`;
      return result;
    }
    result.stage = 'authorized';
    if (!granted) {
      result.summary = `用户拒绝了 ${result.label} 的 USB 访问授权`;
      return result;
    }

    // ③ 连接。得到 pipe 才能拿 fd。
    let pipe: usbManager.USBDevicePipe;
    try {
      pipe = usbManager.connectDevice(device);
    } catch (error) {
      const failure: BusinessError = error as BusinessError;
      result.stage = 'failed';
      // 14400001 = Access right denied（授权记录失效）；88080488 = 无设备
      // 访问权限。这两个出现时把缓存清掉，下轮重新走授权。
      if (failure.code === 14400001 || failure.code === 88080488) {
        reset_usb_fd_channel();
        result.summary =
          `connectDevice 权限失效（${failure.code}），已重置通道，下轮重新授权`;
      } else {
        result.summary =
          `usbManager.connectDevice 失败（${failure.code}）：${failure.message}`;
      }
      return result;
    }
    result.stage = 'connected';

    // ④ 拿 fd。系统服务 open usbfs 节点后把描述符复制进本进程；
    //    之后 native 的 bulk/控制传输全走它。
    let fd: number = -1;
    try {
      fd = usbManager.getFileDescriptor(pipe);
    } catch (error) {
      const failure: BusinessError = error as BusinessError;
      result.stage = 'failed';
      result.summary =
        `usbManager.getFileDescriptor 失败（${failure.code}）：${failure.message}`;
      return result;
    }
    if (fd < 0) {
      result.stage = 'failed';
      result.summary = 'getFileDescriptor 返回了无效的 fd';
      return result;
    }

    // ⑤ 记录并返回。
    if (activePipe !== null && activePipe !== pipe) {
      try {
        usbManager.closePipe(activePipe);
      } catch {
        // 旧 pipe 可能已被系统回收，忽略。
      }
    }
    activePipe = pipe;
    cachedFd = fd;
    cachedDeviceName = device.name;

    result.ok = true;
    result.stage = 'fd';
    result.fd = fd;
    result.summary = `usbManager 通道已打开：${result.label}（fd=${fd}）`;
    return result;
  } finally {
    channelBusy = false;
  }
}
