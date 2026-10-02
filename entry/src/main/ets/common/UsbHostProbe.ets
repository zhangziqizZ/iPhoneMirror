// SPDX-License-Identifier: GPL-3.0-only
//
// 系统侧 USB 视图 —— 用来判"识别不到 iPhone"到底卡在哪一层。
//
// 为什么值得单独走一条路：鸿蒙上"看不到设备"至少有三个互斥的原因，而它们的处置
// 方式完全不同：
//   A. USB 线/供电/接口问题，或 iPhone 根本没连上   → 系统 USB 服务也看不到
//   B. 系统看到了，但本应用没向扩展外设驱动框架声明 VID ⇒ DDK 枚举为空（见 module.json5）
//   C. 声明了但 ACCESS_DDK_USB 没进签名 ACL ⇒ OH_Usb_Init 直接失败
//      （注意 ACCESS_EXTENSIONAL_DEVICE_DRIVER 是 normal 级、声明即授权，不涉及 ACL）
// 原生的环境诊断（im_get_environment）只能回答 B 与 C；A 与 B/C 的区别，需要一个
// **不经过 USB DDK** 的旁证。
//
// @ohos.usbManager 就是这个旁证：它的 getDevices() 走系统 USB 服务，d.ts 里这几个
// 查询接口**没有 @permission 标记**，因此不受驱动框架与 ACL 影响。于是：
//   系统看得到 05AC 而 DDK 枚举为空  ⇒ 100% 是驱动注册/权限问题（B 或 C）
//   系统也看不到 05AC               ⇒ 问题在更外面（线、供电、iPhone 未连接/未解锁）
//
// 纪律：这里只报"看到了几台、VID/PID 是什么"，不做任何推断。判断留给读它的人。

import { usbManager } from '@kit.BasicServicesKit';
import { BusinessError } from '@ohos.base';
import { t } from './i18n';

const APPLE_VENDOR_ID: number = 0x05AC;
/** 摘要里最多点名几台，避免一串设备名把状态行撑爆。 */
const MAX_NAMED: number = 3;

export class UsbHostScan {
  /** false = 这次查询本身失败了（此时 total/appleCount 无意义）。 */
  ok: boolean = false;
  total: number = 0;
  appleCount: number = 0;
  summary: string = '';
}

export function scan_usb_host(): UsbHostScan {
  const result: UsbHostScan = new UsbHostScan();
  let devices: Array<Readonly<usbManager.USBDevice>> = [];
  try {
    devices = usbManager.getDevices();
  } catch (error) {
    const failure: BusinessError = error as BusinessError;
    // 801 = Capability not supported。2in1 上这套 JS 接口未必开放，
    // 那就如实说"这条路走不通"，不要让调用方误以为"没有设备"。
    result.summary = `系统 USB 服务查询失败（${failure.code}）：${failure.message}`;
    return result;
  }
  result.ok = true;
  result.total = devices.length;

  const names: string[] = [];
  let apple: number = 0;
  for (let i = 0; i < devices.length; i++) {
    const device: Readonly<usbManager.USBDevice> = devices[i];
    if (device.vendorId !== APPLE_VENDOR_ID) {
      continue;
    }
    apple += 1;
    if (names.length < MAX_NAMED) {
      const product: string = device.productName.length > 0
        ? device.productName : device.name;
      names.push(`${product}(0x${device.productId.toString(16).toUpperCase()})`);
    }
  }
  result.appleCount = apple;
  if (apple > 0) {
    const more: string = apple > names.length ? ` 等 ${apple} 台` : '';
    result.summary = `系统 USB 服务可见 ${apple} 台 Apple 设备：${names.join('、')}${more}`;
  } else {
    result.summary =
      `系统 USB 服务可见 ${devices.length} 台 USB 设备，其中没有 Apple（0x05AC）设备`;
  }
  return result;
}
