// FirstRunSetupWindow.ets —— 子窗口：首启向导（多步设置）
//
// 逐项对照上游 src/App/Windows/FirstRunSetupWindow.xaml（115 行）
//              src/App/Windows/FirstRunSetupWindow.xaml.cs（536 行）
//  上游是一个被 C# 逻辑驱动的 5 步向导：USB 驱动检测/安装 → AirPlay 可用性 →
//  权限 → 组件下载（BusyBar/DownloadProgress）→ 完成。其中「USB 驱动安装」
//  （UAC / DriverInstaller）、「组件下载」（GitHub Release 拉取原生组件）都是
//  Windows 专属能力，鸿蒙版没有对应物。
//
//  ── 平台替换（必须逐条列明，与本项目其他窗口同律）──────────────────────────
//   1. 【USB 驱动安装】上游 DriverInstaller 工程 + UAC 提权。鸿蒙版没有这个链路：
//      USB 投屏依赖的 ACCESS_DDK_USB 必须进 AGC 签名 profile 的 ACL 才能装包，
//      当前版本已临时移出、改为引导用户走 AirPlay（见 README / CHANGELOG 的诚实声明）。
//      所以向导里 USB 那一项标为「需要额外签名权限，以 AirPlay 更稳定」，不假装能装驱动。
//   2. 【组件下载】上游会从 GitHub Release 拉取并解压原生解码组件。鸿蒙版的解码核心
//      （libim_core.so）是随包预编译进来的，没有「首次运行下载组件」这一步 ⇒ 向导里
//      去掉下载进度，改为「权限与提示」一步说明系统能力与已知限制。
//   3. 【步骤】保留上游的「欢迎 → 连接方式 → 连接指引 → 权限与提示 → 完成」五步骨架，
//      内容按鸿蒙实际能力改写；每步的「上一步 / 下一步 / 跳过」语义与原版一致。
//   4. 【已知限制】原版把「录制与推流」当可用项展示；鸿蒙版尚未实现（见 Index 的
//      NOT_IMPLEMENTED_ACTIONS），故在「权限与提示」一步如实写明，不夸功能。
//
//  ── 与首启标记的关系 ────────────────────────────────────────────────────────
//   「看过一次就不再弹」由 AppPreferences 的 first_run_done 标记承担：窗口任意方式
//   关闭（完成 / 跳过 / 右上角 ×）都会经 SubWindowHost 的关窗钩子写标记；
//   EntryAbility.onWindowStageCreate 据此在首次启动自动弹出本窗口。
//   关于页也提供「首启向导」按钮可随时重看（不依赖该标记）。

import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  SubWindowShell, SubWindowHost, SecondaryButton, PrimaryButton,
  SUBWINDOW_ROW_GAP, SubWindowSpec,
} from '../../common/SubWindow';
import {
  ACCENT, DARK, CARD, CARD_HOVER, RADIUS_CARD,
} from '../../common/Theme';
import { FluentSymbol } from '../../common/FluentIcon';
import { save_first_run_done } from '../../common/AppPreferences';
import { t } from '../../common/i18n';

const TAG: string = 'im_firstrun';
const DOMAIN: number = 0x0100;

/** 窗口名 —— 用 XAML 的类名，window.findWindow 也用它。 */
export const WINDOW_NAME: string = 'FirstRunSetupWindow';
/** 页面路径。 */
export const PAGE_PATH: string = 'pages/windows/FirstRunSetupWindow';

/**
 * 五个步骤的标题（用于顶部步骤指示条）。
 * ★ 只存简体原文 key，渲染时再调 t() —— 与本项目其它窗口一致：t() 必须在
 *   语言缓存建立后（EntryAbility.init_language）才调，不能放在模块加载期求值的
 *   常量里（否则会被冻结成导入时刻的语言，切语言不跟着变）。
 */
const STEP_KEYS: string[] = [
  '欢迎使用 iPhone Mirror',
  '选择连接方式',
  '连接指引',
  '权限与提示',
  '完成',
];

/** 连接方式：airplay = 无线（当前主力且最稳），usb = 有线（需签名 ACL）。 */
type ConnectMode = 'airplay' | 'usb';

/** 顶部步骤指示条的一个圆点 + 文字。 */
@Component
struct StepDot {
  @Prop index: number = 0;
  @Prop active: boolean = false;
  @Prop done: boolean = false;

  build(): void {
    Column() {
      Text(`${this.index + 1}`)
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.done || this.active ? DARK.TEXT : DARK.MUTED_TEXT)
        .width(28)
        .height(28)
        .borderRadius(14)
        .textAlign(TextAlign.Center)
        .backgroundColor(this.active ? ACCENT : (this.done ? DARK.CONTROL_FILL : DARK.CARD))
        .border({
          width: 1,
          color: this.active ? ACCENT : (this.done ? ACCENT : DARK.BORDER_SOFT),
        });
      Text(t(STEP_KEYS[this.index] ?? ''))
        .fontSize(11)
        .fontColor(this.active ? DARK.TEXT : DARK.MUTED_TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 6 })
        .constraintSize({ maxWidth: 96 });
    }
    .alignItems(HorizontalAlign.Center);
  }
}

/** 连接方式选择卡（原版 SetupChoiceCard：选中描边变 Accent + ✓ 标记）。 */
@Component
struct ModeChoiceCard {
  @Prop label: string = '';
  @Prop description: string = '';
  @Prop iconName: string = 'PhoneDesktop24';
  @Prop selected: boolean = false;
  on_select: () => void = (): void => {};

  build(): void {
    Row() {
      // 左侧图标底座（与原版 Border 38×38 圆角 10 同形）。
      Row() {
        FluentSymbol({ iconName: this.iconName, iconSize: 22, iconColor: DARK.TEXT });
      }
      .width(38)
      .height(38)
      .borderRadius(10)
      .backgroundColor(DARK.BORDER_SOFT)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .margin({ right: 14 });

      Column() {
        Text(this.label)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(DARK.TEXT)
          .width('100%');
        Text(this.description)
          .fontSize(12)
          .fontColor(DARK.MUTED_TEXT)
          .lineHeight(18)
          .width('100%')
          .margin({ top: 4 });
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start);

      // 选中标记（○ / ✓）。
      Text(this.selected ? '✓' : '○')
        .fontSize(16)
        .fontColor(this.selected ? ACCENT : DARK.MUTED_TEXT)
        .margin({ left: 8 });
    }
    .width('100%')
    .padding(18)
    .borderRadius(14)   // Apple 圆角分级：选择卡 → 14（介于 CARD 12 与 SURFACE 16）
    .backgroundColor(this.selected ? CARD_HOVER : CARD)
    .border({ width: 1.5, color: this.selected ? ACCENT : DARK.BORDER_SOFT })
    .onClick((): void => { this.on_select(); });
  }
}

/** 按原版打开这个子窗口。 */
export function open_first_run(ctx: common.Context): void {
  const spec: SubWindowSpec = {
    name: WINDOW_NAME,
    page: PAGE_PATH,
    title: t('首启向导'),
    width: 880,
    height: 820,
    resizable: true,                // ResizeMode 等价
    minWidth: 600,
    minHeight: 540,
    modal: true,                    // CenterOwner 等价
  };
  // ★ .catch 里不允许再抛异常：拒绝回调里的 undefined 取 .message 会二次抛错、
  //   被运行时当成未捕获异常结束应用（与 open_about 同律）。
  SubWindowHost.open(ctx, spec).catch((error: BusinessError): void => {
    const reason: string = error !== undefined && error !== null && error.message !== undefined
      ? error.message : '未知原因';
    hilog.error(DOMAIN, TAG, '打开首启向导失败: %{public}s', reason);
  });
}

@Entry
@Component
struct FirstRunSetupWindow {
  /** 当前步骤（0..4）。 */
  @State step: number = 0;
  /** 选中的连接方式（默认 AirPlay：当前最稳、无需签名 ACL）。 */
  @State mode: ConnectMode = 'airplay';

  /**
   * ★ 生命周期抛出的异常没人接管会被当成未捕获异常结束应用 —— 整块 try 包住。
   */
  aboutToAppear(): void {
    try {
      // 任意方式关闭本窗口（完成 / 跳过 / 右上角 ×）都写首启标记，
      // 保证「看过一次就不再自动弹」。
      SubWindowHost.register_close_hook(WINDOW_NAME, (): boolean => {
        try {
          this.mark_done();
        } catch (error) {
          hilog.warn(DOMAIN, TAG, '写首启标记失败: %{public}s',
            (error as BusinessError).message);
        }
        return true;   // 钩子返回 true = 允许关闭
      });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '注册关窗钩子失败: %{public}s',
        (error as BusinessError).message);
    }
  }

  aboutToDisappear(): void {
    try {
      SubWindowHost.unregister_close_hook(WINDOW_NAME);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '注销关窗钩子失败: %{public}s',
        (error as BusinessError).message);
    }
  }

  /** 标记首启向导已看过并落盘。 */
  private mark_done(): void {
    try {
      save_first_run_done();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'save_first_run_done 失败: %{public}s',
        (error as BusinessError).message);
    }
  }

  /** 完成 / 跳过 / 开始使用：标记已看 + 关闭窗口。 */
  private finish(): void {
    this.mark_done();
    SubWindowHost.close(WINDOW_NAME);
  }

  private go_next(): void {
    if (this.step < STEP_KEYS.length - 1) {
      this.step += 1;
    } else {
      this.finish();
    }
  }

  private go_prev(): void {
    if (this.step > 0) {
      this.step -= 1;
    }
  }

  // ── 顶部步骤指示条 ──
  @Builder
  step_indicator() {
    Row() {
      ForEach(STEP_KEYS, (title: string, idx: number): void => {
        Row() {
          StepDot({ index: idx, active: idx === this.step, done: idx < this.step });
          // 步骤之间的连接线（最后一步后不画）。
          if (idx < STEP_KEYS.length - 1) {
            Column()
              .height(2)
              .layoutWeight(1)
              .margin({ left: 8, right: 8, top: -14 })
              .backgroundColor(idx < this.step ? ACCENT : DARK.BORDER_SOFT);
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center);
      }, (title: string, idx: number): string => `${idx}`);
    }
    .width('100%')
    .alignItems(VerticalAlign.Start);
  }

  // ── Step 0：欢迎 ──
  @Builder
  step_welcome() {
    Column() {
      Row() {
        FluentSymbol({ iconName: 'PhoneDesktop24', iconSize: 34, iconColor: DARK.TEXT });
      }
      .width(64)
      .height(64)
      .borderRadius(16)
      .backgroundColor(DARK.PANEL_ALT)
      .border({ width: 1, color: DARK.BORDER })
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 16 });

      Text(t('欢迎使用 iPhone Mirror'))
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
        .fontColor(DARK.TEXT)
        .width('100%')
        .textAlign(TextAlign.Center);
      Text(t('本向导帮你完成第一次投屏所需的基本设置。'))
        .fontSize(13)
        .fontColor(DARK.MUTED_TEXT)
        .lineHeight(20)
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 12 });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center);
  }

  // ── Step 1：选择连接方式 ──
  @Builder
  step_mode() {
    Column() {
      Text(t('选择连接方式'))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(DARK.TEXT)
        .width('100%')
        .margin({ bottom: 16 });
      ModeChoiceCard({
        label: t('AirPlay 无线投屏'),
        description: t('通过本机与 iPhone 的屏幕镜像连接，无需数据线。'),
        iconName: 'PhoneDesktop24',
        selected: this.mode === 'airplay',
        on_select: (): void => { this.mode = 'airplay'; },
      })
      .margin({ bottom: 12 });
      ModeChoiceCard({
        label: t('USB 有线投屏'),
        description: t('需要额外签名权限，当前以 AirPlay 更稳定。'),
        iconName: 'PhoneDesktop24',
        selected: this.mode === 'usb',
        on_select: (): void => { this.mode = 'usb'; },
      });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  // ── Step 2：连接指引（按 mode 动态）──
  @Builder
  step_guide() {
    Column() {
      Text(t('连接指引'))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(DARK.TEXT)
        .width('100%')
        .margin({ bottom: 16 });
      // 一张说明卡（原版 SetupToolCard 形态）。
      Column() {
        Text(this.mode === 'airplay' ? t('AirPlay 无线投屏') : t('USB 有线投屏'))
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(DARK.TEXT)
          .width('100%')
          .margin({ bottom: 10 });
        Text(this.mode === 'airplay'
          ? t('在 iPhone 上，从右上角向下滑动打开控制中心，点「屏幕镜像」，选择本机名称。')
          : t('USB 模式当前需要额外权限，建议先用 AirPlay 完成首次投屏。'))
          .fontSize(13)
          .fontColor(DARK.MUTED_TEXT)
          .lineHeight(20)
          .width('100%');
      }
      .width('100%')
      .padding(18)
      .borderRadius(RADIUS_CARD)
      .backgroundColor(CARD)
      .border({ width: 1, color: DARK.BORDER });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  // ── Step 3：权限与提示 ──
  @Builder
  step_permissions() {
    Column() {
      Text(t('权限与提示'))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(DARK.TEXT)
        .width('100%')
        .margin({ bottom: 16 });
      Column() {
        Text(t('本应用需要本地网络与屏幕镜像系统能力；无需麦克风或相机权限。'))
          .fontSize(13)
          .fontColor(DARK.MUTED_TEXT)
          .lineHeight(20)
          .width('100%')
          .margin({ bottom: 10 });
        Text(t('已知限制：录制与推流尚未实现。'))
          .fontSize(13)
          .fontColor(DARK.MUTED_TEXT)
          .lineHeight(20)
          .width('100%');
      }
      .width('100%')
      .padding(18)
      .borderRadius(RADIUS_CARD)
      .backgroundColor(CARD)
      .border({ width: 1, color: DARK.BORDER });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  // ── Step 4：完成 ──
  @Builder
  step_done() {
    Column() {
      Row() {
        FluentSymbol({ iconName: 'PhoneDesktop24', iconSize: 34, iconColor: ACCENT });
      }
      .width(64)
      .height(64)
      .borderRadius(16)
      .backgroundColor(DARK.PANEL_ALT)
      .border({ width: 1, color: DARK.BORDER })
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 16 });

      Text(t('完成'))
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
        .fontColor(DARK.TEXT)
        .width('100%')
        .textAlign(TextAlign.Center);
      Text(t('本向导帮你完成第一次投屏所需的基本设置。'))
        .fontSize(13)
        .fontColor(DARK.MUTED_TEXT)
        .lineHeight(20)
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 12 });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center);
  }

  /** 内容区：步骤指示条 + 当前步主体（可滚动）。 */
  @Builder
  content() {
    Column() {
      this.step_indicator()
        .margin({ bottom: 20 });

      Scroll() {
        Column() {
          if (this.step === 0) {
            this.step_welcome();
          } else if (this.step === 1) {
            this.step_mode();
          } else if (this.step === 2) {
            this.step_guide();
          } else if (this.step === 3) {
            this.step_permissions();
          } else {
            this.step_done();
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%');
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .align(Alignment.Top);
    }
    .width('100%')
    .height('100%');
  }

  /** 底部按钮条：上一步（左） / 跳过 + 下一步（右）。 */
  @Builder
  actions() {
    Row() {
      // 左：上一步（首步禁用）。
      SecondaryButton({
        label: t('上一步'),
        minButtonWidth: 96,
        actionEnabled: this.step > 0,
        on_action: (): void => { this.go_prev(); },
      });

      // 右：跳过（最后一步不显示）+ 下一步 / 开始使用。
      Row() {
        if (this.step < STEP_KEYS.length - 1) {
          SecondaryButton({
            label: t('跳过'),
            minButtonWidth: 96,
            on_action: (): void => { this.finish(); },
          })
            .margin({ right: 8 });
        }
        PrimaryButton({
          label: this.step === STEP_KEYS.length - 1 ? t('开始使用') : t('下一步'),
          minButtonWidth: 112,
          on_action: (): void => { this.go_next(); },
        });
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Center);
  }

  build() {
    Column() {
      SubWindowShell({
        windowName: WINDOW_NAME,
        title: t('首启向导'),
        gap: SUBWINDOW_ROW_GAP,
        hasNotice: false,
        hasFooter: false,
        hasActions: true,
        content: (): void => { this.content(); },
        actions: (): void => { this.actions(); },
      });
    }
  }
}
