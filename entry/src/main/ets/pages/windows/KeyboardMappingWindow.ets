// KeyboardMappingWindow.ets —— 子窗口：键盘映射管理（对照上游 KeyboardMappingWindow.xaml）
//
// ── 平台替换（必须逐条列明）──────────────────────────────────────────────────
//   1. 【作用】上游是 WPF 独立窗口；本移植做成 SubWindowHost 子窗口（与本站 20 个
//      子窗口同律），挂在主窗口上。
//   2. 【数据】设置走 AppStorage 的 KEYBOARD_MAPPING_KEY（load_keyboard_mapping 在
//      EntryAbility 装载期读回）。本窗口用 @StorageLink 双向绑定：编辑即生成新对象、
//      写回 AppStorage + 落盘（save_keyboard_mapping），编辑器保存后本窗口也会响应式刷新。
//   3. 【执行缺口（诚实标注）】上游把物理键映射成 iPhone 屏幕**触摸动作**，需要绝对触控
//      通道；本移植反控是蓝牙 HID 相对鼠标，没有绝对触控 ⇒ 动作的真实下发暂不能做。
//      本窗口只完成「配置 / 列表 / 增删改 / 持久化」，并在界面明确说明执行待后端，
//      不假装能操控手机（见底部 WARNING 提示）。
//   4. 【取点】上游在预览框里取点（MappingPreviewSurface 那一层），本移植没有该层，
//      位置改用归一化坐标数字输入（见编辑器 Position 步骤）。
//   5. 【删除确认】上游用 AppPrompt 确认框；本移植在行内做「确定删除？」二次确认，
//      不另开对话框窗口，降低耦合与崩溃面。

import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  SubWindowShell, SubWindowHost, SecondaryButton, PrimaryButton,
  SettingsSection, NoticeBanner, SUBWINDOW_ROW_GAP, SubWindowSpec,
} from '../../common/SubWindow';
import {
  ACCENT, DARK, CARD, RADIUS_CARD, WARNING,
} from '../../common/Theme';
import { t } from '../../common/i18n';
import {
  KeyboardMappingSettings, KeyboardMappingEntry, MappedTouchAction,
  keymap_key_display, keymap_action_label_key, keymap_entry_summary,
  keymap_clone_settings, default_keyboard_mapping_settings,
  KEYBOARD_MAPPING_MAX_ENTRIES,
} from '../../common/KeyboardMapping';
import {
  save_keyboard_mapping, KEYBOARD_MAPPING_KEY, KEYBOARD_EDIT_TARGET_KEY,
} from '../../common/AppPreferences';
import { open_keyboard_mapping_editor } from './KeyboardMappingEditorWindow';

const TAG: string = 'im_keymap_mgr';
const DOMAIN: number = 0x0100;

/** 窗口名。 */
export const WINDOW_NAME: string = 'KeyboardMappingWindow';
/** 页面路径。 */
export const PAGE_PATH: string = 'pages/windows/KeyboardMappingWindow';

/** 按原版打开这个子窗口。 */
export function open_keyboard_mapping(ctx: common.Context): void {
  const spec: SubWindowSpec = {
    name: WINDOW_NAME,
    page: PAGE_PATH,
    title: t('键盘映射'),
    width: 580,
    height: 600,
    resizable: true,
    minWidth: 500,
    minHeight: 520,
    modal: false,
  };
  SubWindowHost.open(ctx, spec).catch((error: BusinessError): void => {
    const reason: string = error !== undefined && error !== null && error.message !== undefined
      ? error.message : '未知原因';
    hilog.error(DOMAIN, TAG, '打开键盘映射管理失败: %{public}s', reason);
  });
}

@Entry
@Component
struct KeyboardMappingWindow {
  /** 键盘映射设置（AppStorage 双向绑定，编辑器保存后此处响应式刷新）。 */
  @StorageLink(KEYBOARD_MAPPING_KEY) settings: KeyboardMappingSettings = default_keyboard_mapping_settings();
  /** 行内「确定删除」的待确认条目 id（空 = 无）。 */
  @State pendingDeleteId: string = '';
  /** 错误/状态行。 */
  @State errorText: string = '';

  /** 总开关。 */
  private set_enabled(checked: boolean): void {
    const next: KeyboardMappingSettings = keymap_clone_settings(this.settings);
    next.enabled = checked;
    this.commit(next);
  }

  /** 阻止原键开关。 */
  private set_suppress(checked: boolean): void {
    const next: KeyboardMappingSettings = keymap_clone_settings(this.settings);
    next.suppressOriginalKey = checked;
    this.commit(next);
  }

  /** 单条启用/停用。 */
  private set_entry_enabled(id: string, checked: boolean): void {
    const next: KeyboardMappingSettings = keymap_clone_settings(this.settings);
    next.mappings = next.mappings.map((m: KeyboardMappingEntry): KeyboardMappingEntry =>
      m.id === id ? { ...m, enabled: checked } : m);
    this.commit(next);
  }

  /** 删除一条（已二次确认）。 */
  private remove_entry(id: string): void {
    const next: KeyboardMappingSettings = keymap_clone_settings(this.settings);
    next.mappings = next.mappings.filter((m: KeyboardMappingEntry): boolean => m.id !== id);
    this.pendingDeleteId = '';
    this.commit(next);
  }

  /** 打开编辑器：新增。 */
  private add_entry(): void {
    if (this.settings.mappings.length >= KEYBOARD_MAPPING_MAX_ENTRIES) {
      this.errorText = '映射数量已达上限';
      return;
    }
    AppStorage.setOrCreate(KEYBOARD_EDIT_TARGET_KEY, '__new__');
    open_keyboard_mapping_editor(this.ctx_for_editor());
  }

  /** 打开编辑器：编辑已有。 */
  private edit_entry(entry: KeyboardMappingEntry): void {
    AppStorage.setOrCreate(KEYBOARD_EDIT_TARGET_KEY, entry.id);
    open_keyboard_mapping_editor(this.ctx_for_editor());
  }

  /** 取当前 ability context（开编辑器用，取自 AppStorage 的 im.appContext）。 */
  private ctx_for_editor(): common.Context {
    return AppStorage.get<common.Context>('im.appContext') as common.Context;
  }

  /** 写回 AppStorage + 落盘（@StorageLink 赋值即同步 AppStorage，编辑器侧会刷新）。 */
  private commit(next: KeyboardMappingSettings): void {
    this.settings = next;            // 触发 @StorageLink → AppStorage
    const ok: boolean = save_keyboard_mapping(next);
    this.errorText = ok ? '' : '保存失败，但本次改动已生效于本次运行';
  }

  // ── 顶部两个总开关 ──
  @Builder
  toggles() {
    Column() {
      SettingsSection({ padH: 16, padV: 14 }) {
        Row() {
          Column() {
            Text(t('启用键盘映射'))
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(DARK.TEXT);
            Text(t('映射已开启') + ' / ' + t('映射已关闭'))
              .fontSize(11)
              .fontColor(DARK.MUTED_TEXT)
              .margin({ top: 4 });
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start);
          Toggle({ type: ToggleType.Switch, isOn: this.settings.enabled })
            .onChange((checked: boolean): void => { this.set_enabled(checked); });
        }
        .width('100%');
      }
      .width('100%')
      .margin({ bottom: 12 });

      SettingsSection({ padH: 16, padV: 14 }) {
        Row() {
          Column() {
            Text(t('阻止已映射按键的原始行为'))
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(DARK.TEXT);
            Text(t('默认不阻止；没有可用映射目标时也不拦截。'))
              .fontSize(11)
              .fontColor(DARK.MUTED_TEXT)
              .margin({ top: 4 });
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start);
          Toggle({ type: ToggleType.Switch, isOn: this.settings.suppressOriginalKey })
            .onChange((checked: boolean): void => { this.set_suppress(checked); });
        }
        .width('100%');
      }
      .width('100%')
      .margin({ bottom: 12 });
    }
    .width('100%');
  }

  // ── 执行缺口提示（诚实标注）──
  @Builder
  execution_note() {
    NoticeBanner({
      noticeText: t('执行说明：本版本反控为蓝牙相对鼠标，尚不能把按键映射成 iPhone 绝对触控；配置已可用，执行待绝对触控后端。'),
      noticeTextColor: WARNING,
      surfaceColor: '#332B00',
      bannerBorderColor: WARNING,
      padH: 14,
      padV: 11,
    })
    .width('100%')
    .margin({ bottom: 12 });
  }

  // ── 单条映射行 ──
  @Builder
  mapping_row(entry: KeyboardMappingEntry) {
    SettingsSection({ padH: 14, padV: 12 }) {
      Row() {
        Column() {
          Text(entry.key !== null ? keymap_key_display(entry.key.code) : t('WizardKeyStart'))
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(ACCENT);
          Text(t(keymap_action_label_key(entry.action)) + ' · ' + keymap_entry_summary(entry))
            .fontSize(11)
            .fontColor(DARK.MUTED_TEXT)
            .margin({ top: 4 });
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);

        if (this.pendingDeleteId !== entry.id) {
          Toggle({ type: ToggleType.Switch, isOn: entry.enabled })
            .onChange((checked: boolean): void => { this.set_entry_enabled(entry.id, checked); });
          SecondaryButton({
            label: t('编辑'),
            minButtonWidth: 64,
            on_action: (): void => { this.edit_entry(entry); },
          })
          .margin({ left: 8 });
          SecondaryButton({
            label: t('删除'),
            minButtonWidth: 64,
            on_action: (): void => { this.pendingDeleteId = entry.id; },
          })
          .margin({ left: 8 });
        } else {
          Text(t('确定删除该映射？'))
            .fontSize(12)
            .fontColor(WARNING)
            .margin({ right: 8 });
          SecondaryButton({
            label: t('删除'),
            minButtonWidth: 64,
            on_action: (): void => { this.remove_entry(entry.id); },
          })
          .margin({ left: 8 });
          SecondaryButton({
            label: t('取消'),
            minButtonWidth: 64,
            on_action: (): void => { this.pendingDeleteId = ''; },
          })
          .margin({ left: 8 });
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);
    }
    .width('100%')
    .margin({ bottom: 10 });
  }

  // ── 列表（空态 / 多行）──
  @Builder
  list_area() {
    Column() {
      if (this.settings.mappings.length === 0) {
        Column() {
          Text(t('暂无映射。点击「添加映射」开始。'))
            .fontSize(13)
            .fontColor(DARK.MUTED_TEXT);
        }
        .width('100%')
        .padding({ top: 24, bottom: 24 })
        .alignItems(HorizontalAlign.Center);
      } else {
        ForEach(this.settings.mappings, (entry: KeyboardMappingEntry): void => {
          this.mapping_row(entry);
        }, (entry: KeyboardMappingEntry): string => entry.id);
      }
    }
    .width('100%');
  }

  @Builder
  content() {
    Column() {
      Row() {
        Text(t('添加映射'))
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(DARK.TEXT);
        Blank();
        PrimaryButton({
          label: t('添加映射'),
          minButtonWidth: 96,
          on_action: (): void => { this.add_entry(); },
        });
      }
      .width('100%')
      .margin({ bottom: 12 });

      this.toggles();
      this.execution_note();
      this.list_area();
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  actions() {
    Row() {
      if (this.errorText.length > 0) {
        Text(this.errorText)
          .fontSize(11)
          .fontColor(WARNING)
          .layoutWeight(1);
      } else {
        Blank()
          .layoutWeight(1);
      }
      PrimaryButton({
        label: t('关闭'),
        minButtonWidth: 96,
        on_action: (): void => { SubWindowHost.close(WINDOW_NAME); },
      });
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Center);
  }

  build() {
    Column() {
      SubWindowShell({
        windowName: WINDOW_NAME,
        title: t('键盘映射'),
        subtitle: t('把电脑按键映射成 iPhone 屏幕上的触摸动作（点按/长按/滑动等）。'),
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
