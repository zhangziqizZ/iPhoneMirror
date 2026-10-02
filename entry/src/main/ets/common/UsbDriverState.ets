// SPDX-License-Identifier: GPL-3.0-only
//
// 扩展外设驱动（DriverExtensionAbility）的落盘状态。
//
// 为什么走**文件**而不是 AppStorage：驱动扩展由系统在匹配设备插入时拉起，它和
// 入口 Ability 虽然同属一个应用，但**不保证在同一个 ArkTS VM 里**。AppStorage /
// 进程内静态变量在这种跨 VM 情况下会读到空值 —— 那就又变成一次"看起来查过了、
// 其实什么都没读到"的假诊断。文件落在应用沙箱的 filesDir 下，同一个应用的所有
// Ability / Extension 都能读写，是最省事且不会说谎的通道。
//
// 格式刻意用 `key=value` 逐行文本而不是 JSON：
//   · 不需要 JSON.parse —— ArkTS 严格模式下它返回 any；
//   · 出问题时用 hdc 直接 cat 就能看，不必先找解析器。
// 健康（health）信息只记录**已经发生的事实**：谁在什么时候被拉起、那一刻外部
// 设备管理服务看到几台 USB 设备。不写"应该没问题"这类推断。

import { fileIo } from '@kit.CoreFileKit';
import { t } from './i18n';

/** 状态文件名。读写两侧共用本常量，避免两处手写字符串漂移。 */
export const USB_DRIVER_STATE_FILE: string = 'usb_driver_state.txt';

/** 驱动扩展上报的状态快照。present=false 表示这个文件还不存在。 */
export class UsbDriverState {
  present: boolean = false;
  /** onInit / onConnect / onDisconnect / onRelease */
  stage: string = '';
  atMs: number = 0;
  /** 拉起那一刻，deviceManager.queryDevices(USB) 返回的台数；-1 = 查询失败 */
  deviceCount: number = -1;
  detail: string = '';
}

export function driver_state_path(dir: string): string {
  return `${dir}/${USB_DRIVER_STATE_FILE}`;
}

/** 去掉换行与 `=`，并截断。诊断字符串绝不能把状态文件本身写坏。 */
function sanitize(value: string): string {
  let out: string = '';
  for (let i = 0; i < value.length; i++) {
    const ch: string = value.charAt(i);
    out += (ch === '\n' || ch === '\r' || ch === '=') ? ' ' : ch;
  }
  return out.length > 200 ? out.substring(0, 200) : out;
}

function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

export function format_clock(atMs: number): string {
  if (atMs <= 0) {
    return '时间未知';
  }
  try {
    const when: Date = new Date(atMs);
    return `${pad2(when.getHours())}:${pad2(when.getMinutes())}:${pad2(when.getSeconds())}`;
  } catch (error) {
    return '时间未知';
  }
}

/**
 * 驱动侧调用。
 *
 * 返回 `false` = 这次**没能写进去**，而不是"写成功了但内容为空"。这个返回值必须
 * 传出去：官方对 DriverExtensionAbility 的约束是"仅支持访问 DDK API，不支持访问
 * 其它 ArkTS API"，本模块用的 `fileIo` 属于 CoreFileKit，**有可能在扩展进程里被裁掉**。
 * 那样的话"状态文件不存在"就不能当成"扩展没被拉起"—— 两者是完全不同的结论。
 * 写失败只返回 false，绝不抛：状态上报不能反过来弄坏驱动本身。
 */
export function write_driver_state(dir: string, stage: string, deviceCount: number,
  detail: string): boolean {
  const text: string =
    `stage=${sanitize(stage)}\natMs=${Date.now()}\n` +
    `deviceCount=${deviceCount}\ndetail=${sanitize(detail)}\n`;
  try {
    const handle: fileIo.File = fileIo.openSync(driver_state_path(dir),
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(handle.fd, text);
    } finally {
      fileIo.closeSync(handle);
    }
    return true;
  } catch (error) {
    return false;
  }
}

/** UI 侧调用。读不到就返回 present=false，由调用方决定怎么措辞。 */
export function read_driver_state(dir: string): UsbDriverState {
  const state: UsbDriverState = new UsbDriverState();
  let text: string = '';
  try {
    text = fileIo.readTextSync(driver_state_path(dir));
  } catch (error) {
    return state;
  }
  const lines: string[] = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i];
    const at: number = line.indexOf('=');
    if (at <= 0) {
      continue;
    }
    const key: string = line.substring(0, at);
    const value: string = line.substring(at + 1);
    if (key === 'stage') {
      state.stage = value;
      state.present = true;
    } else if (key === 'atMs') {
      const parsed: number = Number.parseInt(value, 10);
      state.atMs = Number.isNaN(parsed) ? 0 : parsed;
    } else if (key === 'deviceCount') {
      const parsed: number = Number.parseInt(value, 10);
      state.deviceCount = Number.isNaN(parsed) ? -1 : parsed;
    } else if (key === 'detail') {
      state.detail = value;
    }
  }
  return state;
}

/**
 * 给界面用的一句话。present=false 时也要说清"没读到"而不是留空。
 *
 * @param bindPhase 当前这次绑定处于哪个阶段（'idle'/'binding'/'bound'/'failed'，
 *                  取值来自 UsbDriverBinder.usb_driver_bind_state()）。
 *
 * 为什么要把它传进来：状态文件里的记录**不是实时的** —— 它只保存"驱动扩展上一次
 * 被拉起的时刻"，而文件会跨进程存活。11:36 的真机截图里因此出现了两句互相矛盾的
 * 文字并排挂着：「驱动扩展已拉起（onConnect @ 10:58:32）」与「绑定失败（22900001）」。
 * 逻辑上这不可能同时为真：失败的绑定不会拉起扩展。那条记录其实来自上一次运行。
 * 把 bindPhase 接进来，就能在两边冲突时主动说明哪一条是旧的，而不是让用户自己猜。
 * 判据是"当前是否已绑定"而不是"是否失败"：idle / binding / failed 三态都说明本次
 * 会话还没有成功的绑定，那条记录一律是旧的。
 */
export function describe_driver_state(state: UsbDriverState, bindPhase: string = ''): string {
  if (!state.present) {
    // 这一条**不能**写成"驱动扩展尚未拉起"。状态文件不存在有两种完全不同的成因，
    // 而本文件只看得见"没有文件"这个结果：
    //   ① 扩展确实没被拉起 —— 驱动可能是懒加载的，要客户端先 bindDevice 才起来；
    //   ② 扩展起来了但写不进去 —— 官方约束「DriverExtensionAbility 中仅支持访问
    //      DDK API，不支持访问其它 ArkTS API」，本模块依赖的 fileIo 可能被裁掉。
    // 把②误报成①，就是一次典型的假诊断。所以只陈述"没收到上报"，并把真正的
    // 取证手段（hilog）指出来。
    // 另外也**不能**说"检查 ACCESS_EXTENSIONAL_DEVICE_DRIVER 的 ACL"：该权限在
    // SDK 的 PermissionDefinitions.json 里是 availableLevel=normal、
    // provisionEnable=false，声明即授权，与签名 profile 的 allowed-acls 无关。
    return '未收到驱动扩展上报：可能它没被拉起（驱动可为懒加载，需客户端先绑定外部设备），'
      + '也可能它起来了但进程内不允许写文件（驱动扩展仅支持 DDK API）。'
      + '扩展自身的日志用 hdc shell "hilog | grep ImDriverExt" 看';
  }
  const devices: string = state.deviceCount >= 0
    ? `外部设备管理服务可见 ${state.deviceCount} 台 USB 设备`
    : '外部设备管理服务查询失败';
  const tail: string = state.detail.length > 0 ? `；${state.detail}` : '';
  // 判据修正：不只是"绑定失败"时这条记录才过期 —— 只要当前**不是已绑定**状态
  // （idle / binding / failed 三态），本次会话就还没有一次成功的绑定，而"扩展被拉起"
  // 只可能由成功的绑定引发（11:57 截图里那条 onConnect @ 11:55:51 就是这么来的）。
  // 所以这三种阶段下它必然是更早一次运行的记录。只有 phase==='bound' 时它才代表此刻。
  const unbound: boolean = bindPhase === 'idle' || bindPhase === 'binding'
    || bindPhase === 'failed';
  const stale: string = unbound
    ? '（这条记录来自更早的一次拉起：本次会话尚未绑定成功，扩展不可能被本次操作拉起，故它不代表此刻状态）'
    : '';
  return `驱动扩展已拉起（${state.stage} @ ${format_clock(state.atMs)}）：`
    + `${devices}${tail}${stale}`;
}
