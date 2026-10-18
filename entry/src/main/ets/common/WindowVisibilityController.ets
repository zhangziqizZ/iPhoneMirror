import common from '@ohos.app.ability.common';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@ohos.base';

const TAG: string = 'WindowVisibilityController';

export class WindowVisibilityController {
  private static instance: WindowVisibilityController | null = null;

  private mainWindow: window.Window | null = null;
  private context: common.UIAbilityContext | null = null;
  private retryCount: number = 0;
  private visible: boolean = true;
  private static readonly MAX_RETRY: number = 3;
  private static readonly RETRY_INTERVAL_MS: number = 500;

  static shared(): WindowVisibilityController {
    if (WindowVisibilityController.instance === null) {
      WindowVisibilityController.instance = new WindowVisibilityController();
    }
    return WindowVisibilityController.instance;
  }

  setContext(context: common.UIAbilityContext): void {
    this.context = context;
  }

  setMainWindow(win: window.Window): void {
    this.mainWindow = win;
  }

  hideToTray(): boolean {
    if (this.mainWindow === null) {
      hilog.warn(0x0000, TAG, 'hideToTray: 主窗口未设置');
      return false;
    }
    // 注意：新版 SDK 的 window.Window 已移除 hide()（2in1 上不可用），
    // 收起窗口统一走 minimize()（与自绘标题栏最小化按钮同一条路径）。
    try {
      this.mainWindow.minimize().then((): void => {
        this.visible = false;
        hilog.info(0x0000, TAG, '主窗口已收起到托盘/任务栏');
      }).catch((error: BusinessError): void => {
        hilog.warn(0x0000, TAG, 'minimize 失败：%{public}s', error.message);
      });
      this.visible = false;
      return true;
    } catch (error) {
      const failure = error as BusinessError;
      hilog.warn(0x0000, TAG, '隐藏主窗口失败：%{public}s', failure.message);
      return false;
    }
  }

  showFromTray(): boolean {
    if (this.mainWindow === null) {
      hilog.warn(0x0000, TAG, 'showFromTray: 主窗口未设置');
      this.startAbilityFallback();
      return false;
    }
    try {
      this.mainWindow.show();
      this.visible = true;
      this.retryCount = 0;
      hilog.info(0x0000, TAG, '主窗口已从托盘恢复显示');
      return true;
    } catch (error) {
      const failure = error as BusinessError;
      hilog.warn(0x0000, TAG, '恢复主窗口失败（第 %{public}d 次）：%{public}s',
        this.retryCount + 1, failure.message);
      this.scheduleRetry();
      return false;
    }
  }

  isVisible(): boolean {
    return this.visible;
  }

  private scheduleRetry(): void {
    if (this.retryCount >= WindowVisibilityController.MAX_RETRY) {
      hilog.warn(0x0000, TAG, '恢复主窗口重试 %{public}d 次仍失败，降级 startAbility 拉起',
        WindowVisibilityController.MAX_RETRY);
      this.startAbilityFallback();
      return;
    }
    this.retryCount++;
    setTimeout((): void => {
      this.showFromTray();
    }, WindowVisibilityController.RETRY_INTERVAL_MS);
  }

  private startAbilityFallback(): void {
    if (this.context === null) {
      hilog.error(0x0000, TAG, 'startAbility 降级失败：context 未设置');
      return;
    }
    try {
      this.context.startAbility({
        bundleName: this.context.abilityInfo.bundleName,
        abilityName: this.context.abilityInfo.name,
      });
      this.visible = true;
      hilog.info(0x0000, TAG, '通过 startAbility 恢复主窗口');
    } catch (error) {
      const failure = error as BusinessError;
      hilog.warn(0x0000, TAG, 'startAbility 降级失败：%{public}s', failure.message);
    }
  }
}