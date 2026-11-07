// 注意：WantAgent 类型是 @kit.AbilityKit 的顶层导出，不是 wantAgent.WantAgent；
// wantAgent 命名空间里也没有 ActionType / getWantAgentSync（那是别的 API 版本）。
// 本文件按 BackgroundKeepAlive.ets 里已验证可编译的写法来构造通知点击行为。
import common from '@ohos.app.ability.common';
import { Want, wantAgent, WantAgent } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@ohos.base';
import { TRAY_AVAILABLE_KEY, MINIMIZE_TO_TRAY_KEY } from './WindowServices';
import { WindowVisibilityController } from './WindowVisibilityController';

const TAG: string = 'TrayManager';
const NOTIFICATION_ID: number = 1001;

export class TrayManager {
  private static instance: TrayManager | null = null;

  private context: common.UIAbilityContext | null = null;
  private windowStage: window.WindowStage | null = null;
  private trayAvailable: boolean = false;
  private windowVisible: boolean = true;
  private lastCaptureState: number = 0;

  static shared(): TrayManager {
    if (TrayManager.instance === null) {
      TrayManager.instance = new TrayManager();
    }
    return TrayManager.instance;
  }

  initialize(context: common.UIAbilityContext, windowStage: window.WindowStage): boolean {
    this.context = context;
    this.windowStage = windowStage;
    try {
      const mainWindow: window.Window = windowStage.getMainWindowSync();
      WindowVisibilityController.shared().setContext(context);
      WindowVisibilityController.shared().setMainWindow(mainWindow);
      this.publishTrayNotification(0).catch((error: BusinessError): void => {
        hilog.warn(0x0000, TAG, '托盘通知发布失败：%{public}s', error.message);
      });
      this.trayAvailable = true;
      AppStorage.setOrCreate(TRAY_AVAILABLE_KEY, true);
      hilog.info(0x0000, TAG, '托盘初始化成功（通知替代方案）');
      return true;
    } catch (error) {
      const failure = error as BusinessError;
      this.trayAvailable = false;
      AppStorage.setOrCreate(TRAY_AVAILABLE_KEY, false);
      hilog.warn(0x0000, TAG, '托盘初始化失败：%{public}s', failure.message);
      return false;
    }
  }

  updateIconState(captureState: number): void {
    if (!this.trayAvailable) return;
    if (captureState === this.lastCaptureState) return;
    this.lastCaptureState = captureState;
    this.publishTrayNotification(captureState).catch((error: BusinessError): void => {
      hilog.warn(0x0000, TAG, '托盘状态更新失败：%{public}s', error.message);
    });
  }

  private tooltipText(captureState: number): string {
    switch (captureState) {
      case 0:
      case 6:
        return 'iPhoneMirror — 等待设备';
      case 1:
        return 'iPhoneMirror — 正在启用';
      case 2:
      case 3:
        return 'iPhoneMirror — 等待设备';
      case 4:
        return 'iPhoneMirror — 正在投屏';
      case 5:
        return 'iPhoneMirror — 正在停止';
      case 7:
        return 'iPhoneMirror — 投屏异常';
      default:
        return 'iPhoneMirror';
    }
  }

  /**
   * 发布「托盘位」常驻通知。
   *
   * 点击通知 → 回到主 Ability：靠 wantAgent（START_ABILITY）挂到 NotificationRequest.wantAgent。
   * 当前 SDK 的 notificationManager 没有 NotificationFlags 枚举，所以不再设置
   * notificationFlags；常驻效果由投屏期间持续刷新该通知来近似。
   */
  private async publishTrayNotification(captureState: number): Promise<void> {
    if (this.context === null) return;

    const title: string = 'iPhoneMirror';
    const text: string = this.tooltipText(captureState);

    let agent: WantAgent;
    try {
      const want: Want = {
        bundleName: this.context.abilityInfo.bundleName,
        abilityName: this.context.abilityInfo.name,
      };
      const info: wantAgent.WantAgentInfo = {
        wants: [want],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
      };
      agent = await wantAgent.getWantAgent(info);
    } catch (error) {
      const failure = error as BusinessError;
      hilog.warn(0x0000, TAG, '构造托盘通知 WantAgent 失败：%{public}s', failure.message);
      return;
    }

    const request: notificationManager.NotificationRequest = {
      id: NOTIFICATION_ID,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: text,
        },
      },
      wantAgent: agent,
    };

    try {
      await notificationManager.publish(request);
    } catch (error) {
      const failure = error as BusinessError;
      hilog.warn(0x0000, TAG, '发布托盘通知失败：%{public}s', failure.message);
    }
  }

  toggleWindowVisibility(): void {
    if (this.windowVisible) {
      this.hideMainWindow();
    } else {
      this.showMainWindow();
    }
  }

  hideMainWindow(): boolean {
    const hidden: boolean = WindowVisibilityController.shared().hideToTray();
    if (hidden) {
      this.windowVisible = false;
      hilog.info(0x0000, TAG, '主窗口已隐藏');
    }
    return hidden;
  }

  showMainWindow(): boolean {
    const shown: boolean = WindowVisibilityController.shared().showFromTray();
    if (shown) {
      this.windowVisible = true;
      hilog.info(0x0000, TAG, '主窗口已恢复显示');
    }
    return shown;
  }

  isWindowVisible(): boolean {
    return WindowVisibilityController.shared().isVisible();
  }

  remove(): void {
    if (!this.trayAvailable) return;
    try {
      notificationManager.cancel(NOTIFICATION_ID);
      this.trayAvailable = false;
      AppStorage.setOrCreate(TRAY_AVAILABLE_KEY, false);
      hilog.info(0x0000, TAG, '托盘通知已移除');
    } catch (error) {
      const failure = error as BusinessError;
      hilog.warn(0x0000, TAG, '移除托盘通知失败：%{public}s', failure.message);
    }
  }

  isAvailable(): boolean {
    return this.trayAvailable;
  }
}