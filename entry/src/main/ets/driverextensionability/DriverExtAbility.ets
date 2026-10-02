// SPDX-License-Identifier: GPL-3.0-only
//
// 扩展外设驱动（USB）—— 鸿蒙这条链路上最关键、也最容易被误解的一环。
//
// 它要解决的问题不是"缺 Apple 驱动"，而是两条平台约束：
//
//   1. `OH_Usb_GetDevices` 返回的设备「**已通过驱动配置信息中的 vid 进行筛选过滤**」。
//      那句"驱动配置信息"就是本扩展在 module.json5 里声明的 vid/pid —— 不声明，
//      DDK 枚举恒为空列表，一台设备都看不到。
//
//   2. 驱动扩展是**懒加载**的：OpenHarmony 的 device.cpp 里有 launchOnBind 开关，
//      没有客户端 bindDevice 就不会把扩展拉起来 —— 这一点已被现场证实（onConnect
//      的时间戳正好落在第一次 bind 之后）。
//
// 至于官方文档写的「USB DDK 开放 API 仅允许 DriverExtensionAbility 生命周期内
// 使用」：**在本机 2in1 上不成立**。入口 Ability 里 OH_Usb_Init() 实测返回 0
// （USB_DDK_SUCCESS），从来没有出现过早期注释预告的 27400002。别再据此把 DDK
// 调用点往扩展里搬 —— 那会把一条本来能用的通路强行拆成跨进程的帧搬运。
// 文档措辞与设备实测冲突时，以设备实测为准，并在注释里把两者都写下来。
//
// 所以本文件的职责只有两件：
//   · 让 module.json5 里那套 vid/pid「驱动配置信息」生效（DDK 枚举看得见 iPhone
//     的前提，见第 1 条）—— 这是**唯一真正必须由扩展完成**的事；
//   · 落盘"我被拉起过、那一刻看到几台设备"，供主窗口展示（onConnect 时间戳是
//     判断懒加载的关键证据）。
//
// ★ 本扩展**不碰 USB DDK**，也不 import libim_core.so。曾经在这里加过"DDK 自检"，
// 撤掉了：09:13 那版扩展里 getEnvironment() 因 Core 未 initialize 而返回 -2，
// **从未真正调用 OH_Usb_Init()**；新版补了 initialize() 后它第一次真的调了 DDK，
// 而 09:34 随即出现三条 cppcrash。DDK 的真实状态由**主进程**的「环境诊断」回答
// （那条路径 09:13 已在跑、已证明安全），同一件事不必在风险更高、信息更少的地方
// 再测一遍。详见 record() 的注释。
//
// 反过来的纪律：官方文档明确「在 DriverExtensionAbility 中仅支持访问 DDK API，
// 不支持访问其它 ArkTS API」，未加载的模块调用会失败。因此
//   · 日志一律走内置 `console`，不用 PerformanceAnalysisKit 的 hilog；
//   · 状态落盘（CoreFileKit 的 fileIo）是**尽力而为**，成功与否必须上报 ——
//     "文件不存在"绝不能被当成"扩展没被拉起"。

import { DriverExtensionAbility, deviceManager } from '@kit.DriverDevelopmentKit';
import { Want } from '@kit.AbilityKit';
import { rpc } from '@kit.IPCKit';
import { BusinessError } from '@ohos.base';
import { write_driver_state } from '../common/UsbDriverState';
import { t } from '../common/i18n';
// 刻意**不** import 'libim_core.so'：本扩展不碰 USB DDK（原因见 record() 的注释）。
// 顺带的好处是扩展进程不必加载那 3.6MB 原生库（含 FFmpeg/AirPlay 的静态初始化），
// 只做"被系统按 VID 拉起 + 让驱动配置生效"这一件事。

const TAG: string = 'ImDriverExt';

/**
 * 驱动侧端点。外部设备管理服务绑定本驱动时会拿它当对端对象。
 *
 * 本移植不需要任何 IPC 载荷 —— 有线采集走原生 USB DDK 传输。但 onConnect 必须
 * 返回一个合法对象：返回前会在服务侧失败、驱动被判为不可用，连设备列表都拿不到。
 * 所以这里给一个最小实现，只把收到的指令如实记下来。
 */
class DriverEndpoint extends rpc.RemoteObject {
  constructor(descriptor: string) {
    super(descriptor);
  }

  onRemoteMessageRequest(code: number, data: rpc.MessageSequence,
    reply: rpc.MessageSequence, options: rpc.MessageOption): boolean {
    // 返回 true = 已处理。回 false 会让服务侧把它当成失败并重试，
    // 而现在确实没有任何需要驱动侧执行的指令。
    console.info(`${TAG} 收到驱动侧 IPC 请求 code=${code}`);
    return true;
  }
}

export default class DriverExtAbility extends DriverExtensionAbility {
  /**
   * 把当时的事实落盘 + 打到 hilog。
   *
   * queryDevices 需要 ACCESS_EXTENSIONAL_DEVICE_DRIVER（normal 级、声明即授权）；
   * 拿不到时会抛 201 —— 这一条本身就是有价值的诊断结论，所以单独记下来。
   *
   * ★ 这里**刻意不碰 USB DDK**（不调 `getEnvironment()` / 不 import `libim_core.so`）。
   *
   * 曾经在这里跑过"DDK 自检"，理由是"这是唯一能回答 DDK 能不能在扩展里用的地方"。
   * 撤掉是因为它带来了两个实打实的代价，而收益是零：
   *   · 2026-09-19 09:34 的三条 cppcrash 有两种可能源，这是其中之一：09:13 那版
   *     扩展里 `getEnvironment()` 因为 Core 没 initialize 而返回 -2，**从未真正走到
   *     `OH_Usb_Init()`**；新版补了 initialize()，于是扩展进程第一次真的调了 DDK。
   *   · 要调它就得 import `libim_core.so`（3.6MB，静态初始化里还带着 FFmpeg/AirPlay），
   *     让一个只该"证明自己被拉起"的扩展进程背上全部原生代码。
   * 而 DDK 的真实状态**主进程的「环境诊断」那一行已经给出**（09:13 已在跑，且证明
   * 是安全的）。同一件事不该在风险更高、信息更少的地方再测一遍。
   */
  private record(stage: string, detail: string): void {
    let count: number = -1;
    const notes: string[] = [];
    if (detail.length > 0) {
      notes.push(detail);
    }

    try {
      const devices: Array<deviceManager.Device> =
        deviceManager.queryDevices(deviceManager.BusType.USB);
      count = devices.length;
      const names: string[] = [];
      for (let i = 0; i < devices.length && i < 4; i++) {
        names.push(devices[i].description);
      }
      if (names.length > 0) {
        notes.push(names.join(', '));
      }
    } catch (error) {
      const failure: BusinessError = error as BusinessError;
      notes.push(`queryDevices 失败 ${failure.code}（201 = ACCESS_EXTENSIONAL_DEVICE_DRIVER `
        + '未授权；该权限 normal 级、声明即授权，出现 201 说明模块未声明或扩展被降级运行）');
      console.warn(`${TAG} queryDevices 失败 code=${failure.code}`);
    }

    const note: string = notes.join('；');
    const stored: boolean = write_driver_state(this.context.filesDir, stage, count, note);
    // 落盘失败必须说出来。"文件不存在"与"扩展没被拉起"是两件事，
    // 界面只读文件的话会把前者误读成后者。
    console.info(`${TAG} ${stage}：可见 ${count} 台 USB 设备；落盘=${stored}；${note}`);
  }

  onInit(want: Want): void {
    // 先记一次：哪怕紧接着的查询与自检都失败，也已经留下"扩展被拉起过"的证据，
    // 这能把"系统没按 VID/PID 匹配到我们"和"匹配到了但 DDK 用不了"区分开。
    this.record('onInit', '');
  }

  onConnect(want: Want): rpc.RemoteObject {
    // ★ 2026-09-19 12:09：这里加逐步骤日志，是为了让 hilog 能**定位 onConnect 死在
    //   哪一步**。背景：客户端 bindDevice 每次都失败（22900001），而本扩展确实被拉起
    //   过（状态文件有 onConnect 时间戳）。两者能同时成立，只有两种可能：
    //     ① onConnect 走完了、服务侧在之后才失败；
    //     ② onConnect **没走完**（卡住或抛在 updateDriverState / 构造端点）⇒ 服务拿不到
    //        对端对象 ⇒ 判定绑定失败。
    //   onConnect 里原本一行日志都没有（只有 record() 那一条），二者无法区分。
    //   下面每条日志都带唯一措辞，hilog 里缺哪一条就说明卡在哪一步。
    console.info(`${TAG} onConnect 进入`);
    this.record('onConnect', '');
    console.info(`${TAG} onConnect 落盘完成`);
    // 官方接口：通知外部设备管理服务"驱动已就绪，可以绑定"。放在 return 之前调，
    // 确保服务侧拿到端点时状态已经是对的。
    try {
      this.context.updateDriverState();
      console.info(`${TAG} onConnect updateDriverState 已返回`);
    } catch (error) {
      const failure: BusinessError = error as BusinessError;
      console.warn(`${TAG} onConnect updateDriverState 抛出 code=${failure.code}`);
    }
    const endpoint: DriverEndpoint = new DriverEndpoint('iPhoneMirrorUsbDriver');
    console.info(`${TAG} onConnect 即将返回驱动端点`);
    return endpoint;
  }

  onDisconnect(want: Want): void {
    this.record('onDisconnect', '');
  }

  onRelease(): void {
    const stored: boolean = write_driver_state(this.context.filesDir, 'onRelease', -1, '');
    console.info(`${TAG} onRelease；落盘=${stored}`);
  }

  onDump(params: Array<string>): Array<string> {
    return ['iPhoneMirror USB driver extension: Apple VID 0x05AC'];
  }
}
