// SPDX-License-Identifier: GPL-3.0-only
//
// AirPlayMdns.ets —— 把原生侧排好队的 AirPlay 服务用 @ohos.net.mdns 广播出去。
//
// 为什么要绕这一圈：
//   协议库在 raop_start()/airplay_start() 之后会**同步**调用
//   dnssd_register_raop()/dnssd_register_airplay()，而鸿蒙的
//   mdns.addLocalService() 是**异步 Promise**，同步 NAPI 调用里没法 await 它。
//   所以原生侧只把"要广播什么"排进队列（im_dnssd_queue.h），由本文件在
//   ArkTS 的事件循环里取走、真正广播、再回报成败。
//
// 诚实原则：
//   * 广播失败一定回报给原生（airplayReportService(id, false, reason)），
//     原生会计进 mdnsFailed 并显示到 AirPlay 状态里；
//   * 取不到 UIAbilityContext 时直接报错，不假装广播成功。

import mdns from '@ohos.net.mdns';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';
import {
  airplayTakeService,
  airplayTakeRemoval,
  airplayReportService,
  AirPlayService,
} from 'libim_core.so';

// ArkTS 严格模式下对象字面量必须标成已声明类型，而 interface 类型的字面量
// 也要走 class（arkts-no-untyped-obj-literals），所以给两个薄壳。
class MdnsAttribute implements mdns.ServiceAttribute {
  key: string = '';
  value: Array<number> = [];
}

class MdnsServiceInfo implements mdns.LocalServiceInfo {
  serviceType: string = '';
  serviceName: string = '';
  port: number = 0;
  serviceAttribute: Array<mdns.ServiceAttribute> = [];
}

// TXT 记录是原生侧编码好的 DNS-SD 字节串：[1 字节长度][key 或 key=value]。
// 这里拆成 mdns 要的 { key, value: 字节数组 } 形式。
function parse_txt(bytes: Uint8Array): Array<MdnsAttribute> {
  const attributes: Array<MdnsAttribute> = [];
  let offset = 0;
  while (offset < bytes.length) {
    const length = bytes[offset];
    offset = offset + 1;
    if (length === 0 || offset + length > bytes.length) {
      break;
    }
    let entry = '';
    for (let i = 0; i < length; i++) {
      entry = entry + String.fromCharCode(bytes[offset + i]);
    }
    offset = offset + length;

    const separator = entry.indexOf('=');
    const attribute = new MdnsAttribute();
    if (separator >= 0) {
      attribute.key = entry.substring(0, separator);
      const text = entry.substring(separator + 1);
      for (let i = 0; i < text.length; i++) {
        attribute.value.push(text.charCodeAt(i));
      }
    } else {
      attribute.key = entry;
    }
    attributes.push(attribute);
  }
  return attributes;
}

class AirPlayMdnsPublisher {
  private context: common.UIAbilityContext | null = null;
  /** 本机是否具备 mDNS 系统能力（SystemCapability.Communication.NetManager.MDNS）。 */
  private capable: boolean = false;
  /** 已广播成功的服务，按原生侧 id 索引，注销时要拿同一份 info 去 remove。 */
  private published: Map<number, MdnsServiceInfo> = new Map();
  lastError: string = '';

  attach(context: common.UIAbilityContext): void {
    this.context = context;
    // mDNS 在鸿蒙是**系统能力**，不是普通 API。2in1/PC 形态上若该能力缺失，
    // mdns 调用会直接抛 801（能力不支持）。这里先探一次，让界面能如实说
    // "本机不支持 mDNS"，而不是停在"正在广播…"让人以为在等 iPhone。
    this.capable = canIUse('SystemCapability.Communication.NetManager.MDNS');
  }

  private describe(error: BusinessError): string {
    return `code=${error.code} ${error.message}`;
  }

  // 每轮轮询调一次：把所有待广播/待注销的服务都处理掉。
  pump(): void {
    let service: AirPlayService | null = airplayTakeService();
    while (service !== null) {
      this.publish(service);
      service = airplayTakeService();
    }

    let id: number = airplayTakeRemoval();
    while (id !== 0) {
      this.remove(id);
      id = airplayTakeRemoval();
    }
  }

  private publish(service: AirPlayService): void {
    const context = this.context;
    if (context === null) {
      airplayReportService(service.id, false, '尚未拿到 UIAbilityContext，无法广播 mDNS');
      return;
    }
    if (!this.capable) {
      airplayReportService(service.id, false,
        `本机系统能力不支持 mDNS（SystemCapability.Communication.NetManager.MDNS 缺失），${service.type} 无法广播`);
      return;
    }

    const info = new MdnsServiceInfo();
    info.serviceType = service.type;
    info.serviceName = service.name;
    info.port = service.port;
    const attributes = parse_txt(service.txt);
    for (let i = 0; i < attributes.length; i++) {
      info.serviceAttribute.push(attributes[i]);
    }

    // addLocalService 参数非法/能力缺失时是**同步抛出**的，光有 .catch 兜不住。
    try {
      mdns.addLocalService(context, info).then((): void => {
        this.published.set(service.id, info);
        this.lastError = '';
        airplayReportService(service.id, true, '');
      }).catch((error: BusinessError): void => {
        const reason = `addLocalService 失败：${this.describe(error)}`;
        this.lastError = `${service.type} ${reason}`;
        airplayReportService(service.id, false, reason);
      });
    } catch (error) {
      const failure = error as BusinessError;
      const reason = `addLocalService 抛异常：${this.describe(failure)}`;
      this.lastError = `${service.type} ${reason}`;
      airplayReportService(service.id, false, reason);
    }
  }

  private remove(id: number): void {
    const info = this.published.get(id);
    if (info === undefined) {
      return; // 没广播成功过，本来就没什么可撤的
    }
    this.published.delete(id);

    const context = this.context;
    if (context === null) {
      return;
    }
    try {
      mdns.removeLocalService(context, info).then((): void => {
        this.lastError = '';
      }).catch((error: BusinessError): void => {
        this.lastError = `removeLocalService 失败：${this.describe(error)}`;
      });
    } catch (error) {
      const failure = error as BusinessError;
      this.lastError = `removeLocalService 抛异常：${this.describe(failure)}`;
    }
  }

  // 停止接收端时清掉本地记录（原生侧会 reset 队列）。
  clear(): void {
    this.published.clear();
    this.lastError = '';
  }
}

const airPlayMdns: AirPlayMdnsPublisher = new AirPlayMdnsPublisher();
export default airPlayMdns;
