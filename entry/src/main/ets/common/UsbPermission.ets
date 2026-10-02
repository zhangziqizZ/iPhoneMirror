// SPDX-License-Identifier: GPL-3.0-only
//
// 只回答一个问题：ohos.permission.ACCESS_DDK_USB 到底有没有被授予。
//
// 为什么值得单独一条诊断：`OH_Usb_Init()` 失败时，SDK 的 usb_ddk_api.h 里只列了
// 两个可能的码 ——
//   201      USB_DDK_NO_PERM           → 权限检查失败
//   27400002 USB_DDK_INVALID_OPERATION  → 连不上 DDK 服务
// 这两个码指向完全不同的处置，而"权限是不是真给了"在 HAP 里看不出来：权限写在
// module.json5，能不能生效却取决于**签名 profile 的 allowed-acls**，那份 profile
// 由 AGC 签发、不在本机构建产物里。
//
// 与其推断，不如问系统的账本：abilityAccessCtrl 的令牌状态就是权限是否生效的权威
// 答案。它只读本地令牌、不走 IPC，放在 2 秒的刷新节拍里也不会成为负担。
//
// 纪律：查不到就如实说"查不到"（ok=false），不要把未知当成"没授予"。

import { abilityAccessCtrl, bundleManager, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@ohos.base';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { t } from './i18n';

const DOMAIN: number = 0x0000;
const TAG: string = 'ImUsbPerm';

/** 有线采集唯一需要的 USB DDK 权限。改这里等于改诊断口径，别只改字符串。 */
const DDK_USB_PERMISSION: Permissions = 'ohos.permission.ACCESS_DDK_USB';

/** ACCESS_DDK_USB 的授予结果快照。 */
export class DdkPermissionGrant {
  /** false = 这次查询本身没成功，此时 granted 无意义，不要当成"未授予"。 */
  ok: boolean = false;
  granted: boolean = false;
  /** 给界面用的一句话，任何分支都非空。 */
  summary: string = '';
}

/**
 * 查 ACCESS_DDK_USB 的授予状态。
 *
 * 用同步接口：异步版本会让"界面已经画完、结果还没回来"变成一个窗口期，
 * 而这一步恰恰是用来排除歧义的，不能自己再引入一段不确定。
 */
export function check_ddk_usb_permission(): DdkPermissionGrant {
  const result: DdkPermissionGrant = new DdkPermissionGrant();

  let tokenId: number = -1;
  try {
    const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
    tokenId = info.appInfo.accessTokenId;
  } catch (error) {
    const failure: BusinessError = error as BusinessError;
    result.summary = `取不到自身 accessTokenId（${failure.code}）：${failure.message}`;
    hilog.warn(DOMAIN, TAG, 'getBundleInfoForSelfSync 失败 code=%{public}d', failure.code);
    return result;
  }

  try {
    const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const status: abilityAccessCtrl.GrantStatus =
      manager.checkAccessTokenSync(tokenId, DDK_USB_PERMISSION);
    result.ok = true;
    result.granted = status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    result.summary = result.granted
      ? 'ohos.permission.ACCESS_DDK_USB 已授予，DDK 初始化若仍失败就不是权限问题'
      : 'ohos.permission.ACCESS_DDK_USB 未授予：它必须在签名 profile 的 '
        + 'allowed-acls 里放行才生效（改 module.json5 不够）';
  } catch (error) {
    const failure: BusinessError = error as BusinessError;
    result.summary = `权限状态查询失败（${failure.code}）：${failure.message}`;
    hilog.warn(DOMAIN, TAG, 'checkAccessTokenSync 失败 code=%{public}d', failure.code);
  }
  return result;
}
