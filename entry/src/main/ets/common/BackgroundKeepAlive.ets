import { common, Want, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@ohos.base';

// 长时任务（连续任务）保活。
//
// 为什么必须做：投屏时用户一定会把 App 切到后台 —— 去看 iPhone、去别的窗口、
// 或者干脆锁屏等连接。没有长时任务，鸿蒙会冻结整个进程，AirPlay/mDNS 响应器
// 的收发线程随之停摆。
//
// 这个故障极具迷惑性：App 在前台时状态行一切正常（"已广播 · 已应答 N 次"），
// 用户一拿起 iPhone，进程已经哑了。而 mdns_answered 是累计值，回到前台看到的
// 仍是历史数字 —— 于是"看起来在广播，实际早就停了"。
//
// 需要的两处配置（缺一不可，已在 module.json5 中声明）：
//   1. requestPermissions: ohos.permission.KEEP_BACKGROUND_RUNNING
//   2. abilities[].backgroundModes: ["dataTransfer"]
export class BackgroundKeepAlive {
  private static instance: BackgroundKeepAlive = new BackgroundKeepAlive();
  private active: boolean = false;
  private lastError: string = '';

  static shared(): BackgroundKeepAlive {
    return BackgroundKeepAlive.instance;
  }

  isActive(): boolean {
    return this.active;
  }

  // 失败原因。调用方必须把它显示出来 —— 否则"后台没保住"又会变成一个静默故障。
  errorText(): string {
    return this.lastError;
  }

  async start(context: common.UIAbilityContext): Promise<boolean> {
    if (this.active) return true;

    let agent: WantAgent;
    try {
      // 通知点击后回到本 App 主Ability —— 长时任务必须有用户可见的通知入口。
      const want: Want = {
        bundleName: context.abilityInfo.bundleName,
        abilityName: context.abilityInfo.name,
      };
      const info: wantAgent.WantAgentInfo = {
        wants: [want],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
      };
      agent = await wantAgent.getWantAgent(info);
    } catch (error) {
      const err = error as BusinessError;
      this.lastError = `构造后台任务通知失败：${err.code} ${err.message}`;
      this.active = false;
      return false;
    }

    try {
      await backgroundTaskManager.startBackgroundRunning(
        context, backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
      this.active = true;
      this.lastError = '';
      return true;
    } catch (error) {
      const err = error as BusinessError;
      // 9800005 之类是"已申请过"，不算故障；其余要如实报出来。
      this.lastError = `申请后台长时任务失败：${err.code} ${err.message}`;
      this.active = false;
      return false;
    }
  }

  async stop(context: common.UIAbilityContext): Promise<void> {
    if (!this.active) return;
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      this.lastError = '';
    } catch (error) {
      const err = error as BusinessError;
      this.lastError = `释放后台长时任务失败：${err.code} ${err.message}`;
    }
    this.active = false;
  }
}
