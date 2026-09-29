import { AbilityConstant, UIAbility, Want, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { setSystemDark } from '../common/theme_manager';
import { vp_to_px_ratio } from '../common/SubWindow';
import { BusinessError } from '@ohos.base';
import { open_instance_conflict, InstanceConflictRequest } from '../pages/windows/InstanceConflictWindow';

const TAG: string = 'iPhoneMirror';

/**
 * 主窗口最小尺寸 —— 原版 src/App/MainWindow.xaml 根元素：
 *   Width="1540" Height="900" MinWidth="1280" MinHeight="700" ResizeMode="CanResize"
 * WPF 的这几个数都是 DIP（设备无关单位），鸿蒙里对等的单位是 **vp**。
 *
 * 为什么要设：主界面是「左侧图标条（收起 48 / 展开 208vp）+ 中间预览 + 右侧控制
 * 面板」三栏布局，不设下限时用户能把窗口拖得很小，三栏互相挤扁、控件重叠变形。
 */
const MAIN_WINDOW_MIN_WIDTH_VP: number = 1280;
const MAIN_WINDOW_MIN_HEIGHT_VP: number = 700;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, TAG, '%{public}s', 'EntryAbility.onCreate');
  }

  onDestroy(): void {
    hilog.info(0x0000, TAG, '%{public}s', 'EntryAbility.onDestroy');
  }

  /**
   * 单实例守护 —— 上游用命名互斥体检测「另一份 iPhoneMirror 已在运行」并弹冲突窗。
   * 鸿蒙 UIAbility 默认 singleton：第二次启动不会新建进程，而是复用本实例并触发
   * onNewWant，这正是「另一份已在运行」的等价信号。直接弹实例冲突窗口（与原版一致）。
   */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, TAG, '%{public}s', 'EntryAbility.onNewWant');
    try {
      open_instance_conflict(this.context, new InstanceConflictRequest(
        1, false,
        (continueWithCurrent: boolean): void => {
          // 鸿蒙只有这一份实例：continueWithCurrent=true 维持现状；false 在原版里是
          // 「关掉当前、切到新实例」，这里没有可切换的实例，仅记录用户选择。
          hilog.info(0x0000, TAG, '实例冲突结果：%{public}s',
            continueWithCurrent ? '继续当前实例' : '用户选择切换（无第二实例可切换）');
        }), true);
    } catch (error) {
      const failure = error as BusinessError;
      hilog.warn(0x0000, TAG, 'open_instance_conflict failed: %{public}s', failure.message);
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(0x0000, TAG, '%{public}s', 'EntryAbility.onWindowStageCreate');
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(0x0000, TAG, '%{public}s', 'Succeeded in loading the content.');

      // 上游主窗口是 ui:FluentWindow 且 ExtendsContentIntoTitleBar="True" ——
      // 内容延伸到标题栏，系统只画右上角三键，不画标题栏背景/标题文字。
      //
      // 鸿蒙等价做法 = 沉浸式标题栏：
      //   1) 隐藏窗口装饰栏（本块），应用自绘标题区内容（pages/Index.ets 的 header）；
      //   2) 系统三键（最小化/最大化/关闭）仍由系统画在**右上角**，位置由系统分配，
      //      应用内容需在右侧给它让位（见 Index.ets 的 TITLE_BUTTON_RESERVED_WIDTH）；
      //   3) 三键颜色由系统按**应用的 colorMode** 推导 —— 所以应用切换深浅色时必须
      //      调 ApplicationContext.setColorMode()（见 Index.ets 的 sync_system_color_mode），
      //      否则会出现「应用已是深色、系统三键仍是浅色」而看不见。
      try {
        const mainWindow: window.Window = windowStage.getMainWindowSync();
        mainWindow.setWindowDecorVisible(false);

        // 主窗口最小尺寸（原版 MinWidth="1280" MinHeight="700" DIP）。
        // 窗口 API 收的是 **px**，所以按屏幕密度把 vp 折算过去——与 SubWindowHost.open
        // 共用同一个 vp_to_px_ratio()，避免两处口径漂移；isForcible=true 才能把下限
        // 压到系统默认限制以下。失败只记日志：它只是"防呆"，不该影响启动。
        const ratio: number = vp_to_px_ratio();
        const limits: window.WindowLimits = {
          minWidth: Math.round(MAIN_WINDOW_MIN_WIDTH_VP * ratio),
          minHeight: Math.round(MAIN_WINDOW_MIN_HEIGHT_VP * ratio),
        };
        mainWindow.setWindowLimits(limits, true).then((): void => {
          hilog.info(0x0000, TAG, '主窗口最小尺寸已生效：%{public}s',
            `${limits.minWidth}x${limits.minHeight} px（密度 ${ratio.toFixed(3)}）`);
        }).catch((limitsError: BusinessError): void => {
          hilog.warn(0x0000, TAG, 'setWindowLimits failed: %{public}s', limitsError.message);
        });
      } catch (error) {
        const failure = error as BusinessError;
        hilog.warn(0x0000, TAG, 'setWindowDecorVisible failed: %{public}s', failure.message);
      }

      // 双主题：读取系统当前浅深写入 AppStorage，决定首屏方案。
      // 之后系统主题变化由 onConfigurationUpdate 持续更新（对应原版 ThemeService 监听系统）。
      try {
        const config: Configuration = this.context.config;
        setSystemDark(config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      } catch (error) {
        const failure = error as BusinessError;
        hilog.warn(0x0000, TAG, 'read system colorMode failed: %{public}s', failure.message);
      }
    });
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    hilog.info(0x0000, TAG, '%{public}s', 'EntryAbility.onConfigurationUpdate');
    setSystemDark(newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
  }

  onWindowStageDestroy(): void {
    hilog.info(0x0000, TAG, '%{public}s', 'EntryAbility.onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(0x0000, TAG, '%{public}s', 'EntryAbility.onForeground');
  }

  onBackground(): void {
    hilog.info(0x0000, TAG, '%{public}s', 'EntryAbility.onBackground');
  }
}
