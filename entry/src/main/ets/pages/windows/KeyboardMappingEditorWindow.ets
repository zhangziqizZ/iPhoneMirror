// KeyboardMappingEditorWindow.ets —— 子窗口：键盘映射编辑器 / 向导
// （对照上游 KeyboardMappingEditorWindow.xaml.cs + KeyboardMappingWizardState.cs）
//
// ── 平台替换（必须逐条列明）──────────────────────────────────────────────────
//   1. 【向导 5 步】上游 Key → Action → Parameters → Position → Confirmation。
//      本移植保留这 5 步与「上一步 / 下一步 / 完成」导航、草稿保留、冲突检测。
//   2. 【按键捕获】上游走全局 WH_KEYBOARD_LL 钩子；鸿蒙侧没有全局键盘钩子可用，
//      改为在可聚焦的捕获区上挂 onKeyEvent：点击捕获区即聚焦并开始录入，松开/按下
//      记录鸿蒙 KeyCode（与布局无关的物理标识，对照上游 ScanCode 语义）。
//   3. 【位置取点】上游在预览框里取点（MappingPreviewSurface）；本移植无该层 ⇒ 位置
//      改用归一化坐标数字输入（0–100%），数据模型保持完整。
//   4. 【执行缺口（诚实标注）】同 KeyboardMappingWindow：动作真实下发（绝对触控）待后端，
//      本窗口只负责把配置写回 AppStorage + 落盘，不假装能操控手机。
//   5. 【丢弃确认】上游在关闭且有修改时弹确认；本移植草稿不落盘、仅在「完成」时写回，
//      故直接关闭即放弃，无需二次确认（更低的崩溃面）。
//   6. 【方向滑动】上游把 Swipe（自定义手势）与 SwipeUp/Down/Left/Right（方向滑动）分开；
//      本移植把 9 个动作都放进动作下拉，方向滑动在 Position 步骤按 distance 推导终点。

import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import { hilog } from '@kit.PerformanceAnalysisKit';
// ★ 不要从 '@ohos.multimodalInput.keyEvent' 导入 KeyEvent / KeyType（本文件曾经导过，编译直接报
//   「no exported member 'KeyType'」+ 回调签名不匹配）：
//   那个 KeyEvent 是**输入服务**的事件类型（action / key / unicodeChar / keys），与组件
//   onKeyEvent 回调给的根本不是同一个类型。组件侧用的是 ArkUI 全局的
//   KeyEvent（type: KeyType / keyCode: number / keyText: string）与全局枚举
//   KeyType（Down / Up），都无需 import。名字一样、成员完全不同，混用必然对不上。
import {
  SubWindowShell, SubWindowHost, SecondaryButton, PrimaryButton,
  SUBWINDOW_ROW_GAP, SubWindowSpec,
} from '../../common/SubWindow';
import {
  ACCENT, DARK, CARD, RADIUS_CARD, WARNING,
} from '../../common/Theme';
import { t } from '../../common/i18n';
import {
  KeyboardMappingSettings, KeyboardMappingEntry, MappingKey, KeymapPoint, MappedTouchAction,
  ALL_MAPPED_ACTIONS,
  keymap_key_display, keymap_action_label_key, keymap_entry_summary,
  keymap_is_swipe, keymap_is_directional, keymap_has_parameters,
  keymap_validate_entry, keymap_validate_key, keymap_same_key,
  keymap_clone_settings, keymap_clone_entry, keymap_end_point,
  new_mapping_id, default_keyboard_mapping_settings,
} from '../../common/KeyboardMapping';
import {
  save_keyboard_mapping, KEYBOARD_MAPPING_KEY, KEYBOARD_EDIT_TARGET_KEY,
} from '../../common/AppPreferences';

const TAG: string = 'im_keymap_edt';
const DOMAIN: number = 0x0100;

const STEP_KEY: number = 0;
const STEP_ACTION: number = 1;
const STEP_PARAMS: number = 2;
const STEP_POSITION: number = 3;
const STEP_CONFIRM: number = 4;

/** 窗口名。 */
export const WINDOW_NAME: string = 'KeyboardMappingEditorWindow';
/** 页面路径。 */
export const PAGE_PATH: string = 'pages/windows/KeyboardMappingEditorWindow';

/** 按原版打开编辑器子窗口。 */
export function open_keyboard_mapping_editor(ctx: common.Context): void {
  const spec: SubWindowSpec = {
    name: WINDOW_NAME,
    page: PAGE_PATH,
    title: t('键盘映射'),
    width: 560,
    height: 600,
    resizable: false,
    minWidth: 480,
    minHeight: 520,
    modal: false,
  };
  SubWindowHost.open(ctx, spec).catch((error: BusinessError): void => {
    const reason: string = error !== undefined && error !== null && error.message !== undefined
      ? error.message : '未知原因';
    hilog.error(DOMAIN, TAG, '打开键盘映射编辑器失败: %{public}s', reason);
  });
}

@Entry
@Component
struct KeyboardMappingEditorWindow {
  /** 键盘映射设置（读已有条目 + 完成时写回）。 */
  @StorageLink(KEYBOARD_MAPPING_KEY) settings: KeyboardMappingSettings = default_keyboard_mapping_settings();
  /** 正在编辑的草稿。 */
  @State draft: KeyboardMappingEntry = KeyboardMappingEditorWindow.default_draft();
  /** 当前步骤。 */
  @State stepIndex: number = STEP_KEY;
  /** 是否正在录入按键。 */
  @State capturing: boolean = false;
  /** 是否已选动作。 */
  @State hasAction: boolean = false;
  /** 是否已设位置（进入 Position 步骤时置 true，默认值即合法）。 */
  @State hasPosition: boolean = false;
  /** 是否新增（false = 编辑已有）。 */
  @State isNew: boolean = true;
  /** 被编辑条目的原 id（新增为 ''）。 */
  @State originalId: string = '';
  /** 错误行。 */
  @State errorText: string = '';
  /** 成功行（完成后短暂显示）。 */
  @State successText: string = '';
  /** 是否已提交（完成后禁用编辑）。 */
  @State committed: boolean = false;

  // ── 坐标 / 参数文本镜像（受控输入框需要字符串态）──
  @State xText: string = '50';
  @State yText: string = '50';
  @State endXText: string = '50';
  @State endYText: string = '75';
  @State distanceText: string = '25';
  @State durationText: string = '400';
  @State intervalText: string = '100';

  /** 默认草稿。 */
  private static default_draft(): KeyboardMappingEntry {
    return {
      id: new_mapping_id(),
      key: null,
      action: MappedTouchAction.Tap,
      enabled: true,
      x: 0.5, y: 0.5, endX: 0.5, endY: 0.75, distance: 0.25,
      durationMs: 400, intervalMs: 100, deviceCoordinates: false,
    };
  }

  aboutToAppear(): void {
    // 读编辑目标：'__new__' = 新增；否则按 id 在设置里找已有条目预载。
    let target: string = '__new__';
    try {
      const v: string | undefined = AppStorage.get<string>(KEYBOARD_EDIT_TARGET_KEY);
      if (v !== undefined && v !== null) {
        target = v;
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '读取编辑目标失败: %{public}s', (error as BusinessError).message);
    }
    if (target !== '__new__') {
      const found: KeyboardMappingEntry | undefined = this.settings.mappings.find(
        (m: KeyboardMappingEntry): boolean => m.id === target);
      if (found !== undefined) {
        this.draft = keymap_clone_entry(found);
        this.isNew = false;
        this.originalId = found.id;
        this.hasAction = true;
        this.hasPosition = keymap_validate_entry(this.draft) === null;
      }
    }
    this.sync_text_from_draft();
  }

  /** 把草稿里的数值同步到文本输入框。 */
  private sync_text_from_draft(): void {
    this.xText = this.pct(this.draft.x);
    this.yText = this.pct(this.draft.y);
    this.endXText = this.pct(this.draft.endX);
    this.endYText = this.pct(this.draft.endY);
    this.distanceText = this.pct(this.draft.distance);
    this.durationText = `${this.draft.durationMs}`;
    this.intervalText = `${this.draft.intervalMs}`;
  }

  /** 数值 → 百分比文本（0–100，整数）。 */
  private pct(value: number): string {
    return `${Math.round(value * 100)}`;
  }

  /** 解析百分比文本（0–100）→ 0..1，越界回退默认。 */
  private parse_pct(text: string, fallback: number): number {
    const n: number = Number(text);
    if (!Number.isFinite(n)) {
      return fallback;
    }
    return Math.max(0, Math.min(100, n)) / 100;
  }

  /** 解析整数并夹到 [min,max]。 */
  private parse_int(text: string, min: number, max: number, fallback: number): number {
    const n: number = Math.trunc(Number(text));
    if (!Number.isFinite(n)) {
      return fallback;
    }
    return Math.max(min, Math.min(max, n));
  }

  // ── 步骤元信息 ──
  private step_titles(): string[] {
    return [
      t('WizardStepKey'), t('WizardStepAction'), t('WizardStepParameters'),
      t('WizardStepPosition'), t('WizardStepConfirmation'),
    ];
  }

  private current_title(): string {
    switch (this.stepIndex) {
      case STEP_KEY: return t('WizardTitleKey');
      case STEP_ACTION: return t('WizardTitleAction');
      case STEP_PARAMS: return t('WizardTitleParameters');
      case STEP_POSITION: return t('WizardTitlePosition');
      default: return t('WizardTitleConfirmation');
    }
  }

  private current_hint(): string {
    switch (this.stepIndex) {
      case STEP_KEY: return t('WizardHintKey');
      case STEP_ACTION: return t('WizardHintAction');
      case STEP_PARAMS: return t('WizardHintParameters');
      case STEP_POSITION: return t('WizardHintPosition');
      default: return t('WizardHintConfirmation');
    }
  }

  /** 当前步骤的错误（null = 通过）。 */
  private error_for_step(step: number): string | null {
    switch (step) {
      case STEP_KEY:
        if (this.draft.key === null) {
          return this.capturing ? null : 'MappingCaptureHint';
        }
        if (keymap_validate_key(this.draft.key) !== null) {
          return 'MappingUnsupportedKey';
        }
        if (this.duplicate_conflict()) {
          return 'WizardDuplicate';
        }
        return null;
      case STEP_ACTION:
        return this.hasAction ? null : 'WizardChooseAction';
      case STEP_PARAMS:
        if (this.draft.action === MappedTouchAction.LongPress && this.draft.durationMs < 50) {
          return 'MappingInvalidDuration';
        }
        if (keymap_is_swipe(this.draft.action) && (this.draft.durationMs < 50 || this.draft.durationMs > 10000)) {
          return 'MappingInvalidDuration';
        }
        if (this.draft.action === MappedTouchAction.DoubleTap &&
          (this.draft.intervalMs < 40 || this.draft.intervalMs > 1000)) {
          return 'MappingInvalidInterval';
        }
        return null;
      case STEP_POSITION:
        if (!this.hasPosition) {
          return 'MappingPickRequired';
        }
        return keymap_validate_entry(this.draft);
      default:
        // 确认页：汇总所有步骤
        for (let s = STEP_KEY; s <= STEP_POSITION; s++) {
          const e: string | null = this.error_for_step(s);
          if (e !== null) {
            return e;
          }
        }
        return null;
    }
  }

  /** 当前步骤能否前进。 */
  private can_next(): boolean {
    return this.error_for_step(this.stepIndex) === null;
  }

  /** 是否与已有（且非自身）条目物理键冲突。 */
  private duplicate_conflict(): boolean {
    if (this.draft.key === null) {
      return false;
    }
    return this.settings.mappings.some((m: KeyboardMappingEntry): boolean =>
      m.id !== this.originalId && keymap_same_key(m.key, this.draft.key));
  }

  // ── 导航 ──
  private go_to_step(target: number): void {
    if (this.committed) {
      return;
    }
    // 离开 Key 步骤时停止录入
    if (this.stepIndex === STEP_KEY && target !== STEP_KEY) {
      this.capturing = false;
    }
    this.stepIndex = target;
    this.errorText = '';
    if (target === STEP_POSITION && !this.hasPosition) {
      this.hasPosition = true;   // 默认坐标合法，进入即视为已设
    }
    if (target === STEP_KEY) {
      // 进入按键步骤：若还没录到键，自动开始录入（点击捕获区也会触发）
      if (this.draft.key === null) {
        this.start_capture();
      }
    }
  }

  private next(): void {
    if (this.stepIndex === STEP_CONFIRM) {
      this.finish();
      return;
    }
    if (!this.can_next()) {
      return;
    }
    this.go_to_step(this.stepIndex + 1);
  }

  private previous(): void {
    if (this.stepIndex > STEP_KEY) {
      this.go_to_step(this.stepIndex - 1);
    }
  }

  // ── 按键捕获 ──
  private start_capture(): void {
    if (this.committed) {
      return;
    }
    this.capturing = true;
    this.errorText = '';
  }

  private stop_capture(): void {
    this.capturing = false;
  }

  /** onKeyEvent 回调（绑定在捕获区上）。 */
  private on_capture_key(event: KeyEvent): void {
    if (this.committed || !this.capturing) {
      return;
    }
    if (event.type !== KeyType.Down) {
      return;   // 只在按下时录入
    }
    const code: number = event.keyCode;
    // ★ 组件 KeyEvent 的可读名是 keyText（string），不是 key（那是输入服务 KeyEvent 的成员，
    //   且类型是 Key 而非 string）。名字拿错 ⇒ 永远走兜底显示。
    const label: string = event.keyText.length > 0 ? event.keyText : keymap_key_display(code);
    // ★ ArkTS 不支持对象展开（arkts-no-spread）：一律「克隆 + 改字段」。
    const captured: KeyboardMappingEntry = keymap_clone_entry(this.draft);
    captured.key = { code: code, label: label };
    this.draft = captured;
    this.capturing = false;
    this.errorText = '';
  }

  // ── 动作选择 ──
  private select_action(action: MappedTouchAction): void {
    const next: KeyboardMappingEntry = keymap_clone_entry(this.draft);
    next.action = action;
    this.draft = next;
    this.hasAction = true;
    this.hasPosition = false;   // 动作变了 ⇒ 位置重设（避免旧坐标错配）
    this.errorText = '';
  }

  /**
   * 改草稿的物理键。
   *
   * ★ 收成方法而不是在 @Builder 里就地展开：ArkTS 既不支持对象展开
   *   （arkts-no-spread），也不允许在 build/@Builder 里写局部 const。
   */
  private set_draft_key(key: MappingKey | null): void {
    const next: KeyboardMappingEntry = keymap_clone_entry(this.draft);
    next.key = key;
    this.draft = next;
  }

  /**
   * 方向滑动推导出的终点读数。
   *
   * ★ 收成方法的两个原因：① @Builder 内不允许局部 const（10905209）；
   *   ② ArkTS 不允许对象字面量类型，返回类型必须走 KeymapPoint。
   */
  private end_point_text(): string {
    const end: KeymapPoint = keymap_end_point(this.draft);
    return `→ (${Math.round(end.x * 100)}%, ${Math.round(end.y * 100)}%)`;
  }

  // ── 完成 ──
  private build_entry(): KeyboardMappingEntry {
    const entry: KeyboardMappingEntry = keymap_clone_entry(this.draft);
    if (this.draft.action === MappedTouchAction.LongPress || keymap_is_swipe(this.draft.action)) {
      entry.durationMs = this.parse_int(this.durationText, 50, 10000, this.draft.durationMs);
    }
    if (this.draft.action === MappedTouchAction.DoubleTap) {
      entry.intervalMs = this.parse_int(this.intervalText, 40, 1000, this.draft.intervalMs);
    }
    entry.x = this.parse_pct(this.xText, this.draft.x);
    entry.y = this.parse_pct(this.yText, this.draft.y);
    if (keymap_is_directional(this.draft.action)) {
      entry.distance = this.parse_pct(this.distanceText, this.draft.distance);
    }
    if (this.draft.action === MappedTouchAction.Swipe) {
      entry.endX = this.parse_pct(this.endXText, this.draft.endX);
      entry.endY = this.parse_pct(this.endYText, this.draft.endY);
    }
    return entry;
  }

  private finish(): void {
    const entry: KeyboardMappingEntry = this.build_entry();
    const err: string | null = keymap_validate_entry(entry);
    if (err !== null) {
      this.errorText = t(err);
      return;
    }
    if (this.settings.mappings.some((m: KeyboardMappingEntry): boolean =>
      m.id !== this.originalId && keymap_same_key(m.key, entry.key))) {
      this.errorText = t('WizardDuplicate');
      return;
    }
    const next: KeyboardMappingSettings = keymap_clone_settings(this.settings);
    if (this.isNew) {
      next.mappings.push(entry);
    } else {
      next.mappings = next.mappings.map((m: KeyboardMappingEntry): KeyboardMappingEntry =>
        m.id === this.originalId ? entry : m);
    }
    this.settings = next;   // @StorageLink → AppStorage（管理器会响应式刷新）
    save_keyboard_mapping(next);
    this.committed = true;
    this.successText = t('保存成功');
    // 短暂展示成功，再关窗（对照上游 _completionTimer）
    try {
      setTimeout((): void => {
        SubWindowHost.close(WINDOW_NAME);
      }, 800);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '完成定时器异常: %{public}s', (error as BusinessError).message);
    }
  }

  /**
   * 当前要展示的错误文案：优先 finish() 的校验错误，否则展示当前步骤的实时校验错误
   * （让「下一步」被禁用时用户知道原因，对照上游的逐步校验提示）。
   */
  private current_error_text(): string {
    if (this.errorText.length > 0) {
      return this.errorText;
    }
    if (!this.can_next()) {
      const e: string | null = this.error_for_step(this.stepIndex);
      if (e !== null) {
        return t(e);
      }
    }
    return '';
  }

  // ── 步骤指示条 ──
  @Builder
  stepper() {
    Row() {
      ForEach(this.step_titles(), (title: string, index: number): void => {
        Column() {
          Text(index === this.stepIndex ? '●' : (index < this.stepIndex ? '✓' : '○'))
            .fontSize(16)
            .fontColor(index === this.stepIndex ? ACCENT : DARK.MUTED_TEXT);
          Text(`${index + 1}. ${title}`)
            .fontSize(11)
            .fontColor(index === this.stepIndex ? ACCENT : DARK.MUTED_TEXT)
            .margin({ top: 2 });
        }
        .alignItems(HorizontalAlign.Center);
        if (index < this.step_titles().length - 1) {
          Line()
            .width(24)
            .height(1)
            .backgroundColor(DARK.BORDER)
            .margin({ top: 8 });
        }
      }, (title: string, index: number): string => `${index}`);
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .margin({ bottom: 12 });
  }

  // ── 步骤内容：按键 ──
  @Builder
  step_key() {
    Column() {
      Text(this.current_title())
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(DARK.TEXT);
      Text(this.current_hint())
        .fontSize(11)
        .fontColor(DARK.MUTED_TEXT)
        .width('100%')
        .lineHeight(16)
        .margin({ top: 6, bottom: 14 });

      // 捕获区：可聚焦、可点击；点击即聚焦并开始录入
      Column() {
        if (this.draft.key !== null) {
          Text(keymap_key_display(this.draft.key.code))
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor(ACCENT);
          Text(t('WizardKeySelected') + '：' + this.draft.key.label)
            .fontSize(12)
            .fontColor(DARK.MUTED_TEXT)
            .margin({ top: 6 });
        } else if (this.capturing) {
          Text(t('WizardKeyWaiting'))
            .fontSize(18)
            .fontColor(ACCENT);
        } else {
          Text(t('WizardKeyStart'))
            .fontSize(16)
            .fontColor(DARK.MUTED_TEXT);
        }
      }
      .width('100%')
      .height(120)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(CARD)
      .border({ width: 1, color: this.capturing ? ACCENT : DARK.BORDER })
      .borderRadius(RADIUS_CARD)
      .focusable(true)
      .onClick((): void => { this.start_capture(); })
      .onKeyEvent((event: KeyEvent): void => { this.on_capture_key(event); })
      .margin({ bottom: 12 });

      if (this.draft.key !== null) {
        SecondaryButton({
          label: t('重新录入'),
          minButtonWidth: 96,
          on_action: (): void => {
            this.set_draft_key(null);
            this.start_capture();
          },
        });
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  // ── 步骤内容：动作 ──
  @Builder
  step_action() {
    Column() {
      Text(this.current_title())
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(DARK.TEXT);
      Text(this.current_hint())
        .fontSize(11)
        .fontColor(DARK.MUTED_TEXT)
        .width('100%')
        .lineHeight(16)
        .margin({ top: 6, bottom: 14 });

      // ★ Select 的选项只能从**构造函数**传（Array<SelectOption>）—— SelectAttribute 上
      //   没有 .options()；当前选中项用 .selected(下标) + .value(显示文本) 表达。
      Select(this.action_options())
        .value(this.action_label())
        .selected(this.action_index())
        .onSelect((index: number, value: Object): void => {
          // 选项与 ALL_MAPPED_ACTIONS 同序 ⇒ 直接按下标取动作，避免 Object→枚举的强转。
          if (index >= 0 && index < ALL_MAPPED_ACTIONS.length) {
            this.select_action(ALL_MAPPED_ACTIONS[index]);
          }
        })
        .width('100%')
        .margin({ bottom: 12 });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  private action_index(): number {
    const idx: number = ALL_MAPPED_ACTIONS.indexOf(this.draft.action);
    return idx < 0 ? 0 : idx;
  }

  private action_label(): string {
    return t(keymap_action_label_key(this.draft.action));
  }

  private action_options(): Array<SelectOption> {
    // ★ SelectOption 只有 value / icon / symbolIcon —— **没有 label 字段**，
    //   显示文本就是 value。选中了哪个动作靠 onSelect 的下标（与 ALL_MAPPED_ACTIONS 同序），
    //   不靠 value 反查，所以 value 用不用作标识都无所谓。
    return ALL_MAPPED_ACTIONS.map((action: MappedTouchAction): SelectOption => ({
      value: t(keymap_action_label_key(action)),
    }));
  }

  // ── 步骤内容：参数 ──
  @Builder
  step_params() {
    Column() {
      Text(this.current_title())
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(DARK.TEXT);
      Text(this.current_hint())
        .fontSize(11)
        .fontColor(DARK.MUTED_TEXT)
        .width('100%')
        .lineHeight(16)
        .margin({ top: 6, bottom: 14 });

      if (keymap_has_parameters(this.draft.action)) {
        if (this.draft.action === MappedTouchAction.LongPress || keymap_is_swipe(this.draft.action)) {
          Text(t('时长 (毫秒)'))
            .fontSize(12)
            .fontColor(DARK.TEXT)
            .margin({ bottom: 6 });
          TextInput({ text: this.durationText, placeholder: '50–10000' })
            .type(InputType.Number)
            .width('100%')
            .onChange((v: string): void => { this.durationText = v; });
        }
        if (this.draft.action === MappedTouchAction.DoubleTap) {
          Text(t('间隔 (毫秒)'))
            .fontSize(12)
            .fontColor(DARK.TEXT)
            .margin({ bottom: 6 });
          TextInput({ text: this.intervalText, placeholder: '40–1000' })
            .type(InputType.Number)
            .width('100%')
            .onChange((v: string): void => { this.intervalText = v; });
        }
      } else {
        Text(t('此动作无需参数。'))
          .fontSize(12)
          .fontColor(DARK.MUTED_TEXT);
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  // ── 步骤内容：位置 ──
  @Builder
  step_position() {
    Column() {
      Text(this.current_title())
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(DARK.TEXT);
      Text(this.current_hint())
        .fontSize(11)
        .fontColor(DARK.MUTED_TEXT)
        .width('100%')
        .lineHeight(16)
        .margin({ top: 6, bottom: 8 });
      Text(t('MappingPositionManual'))
        .fontSize(11)
        .fontColor(WARNING)
        .width('100%')
        .lineHeight(16)
        .margin({ bottom: 14 });

      // 位置 X / Y（0–100%，受控输入）
      Column() {
        Text(t('位置 X (%)'))
          .fontSize(12)
          .fontColor(DARK.TEXT)
          .margin({ bottom: 6 });
        TextInput({ text: this.xText, placeholder: '0–100' })
          .type(InputType.Number)
          .width('100%')
          .onChange((v: string): void => { this.xText = v; });
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ bottom: 12 });

      Column() {
        Text(t('位置 Y (%)'))
          .fontSize(12)
          .fontColor(DARK.TEXT)
          .margin({ bottom: 6 });
        TextInput({ text: this.yText, placeholder: '0–100' })
          .type(InputType.Number)
          .width('100%')
          .onChange((v: string): void => { this.yText = v; });
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ bottom: 12 });

      if (keymap_is_directional(this.draft.action)) {
        Column() {
          Text(t('滑动距离 (%)'))
            .fontSize(12)
            .fontColor(DARK.TEXT)
            .margin({ bottom: 6 });
          TextInput({ text: this.distanceText, placeholder: '0–100' })
            .type(InputType.Number)
            .width('100%')
            .onChange((v: string): void => { this.distanceText = v; });
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .margin({ bottom: 12 });
        // ★ 不能在这里写局部 const：@Builder 内只允许 UI 组件语法
        //   （10905209），且 ArkTS 也不认对象字面量类型。读数收成方法。
        Text(this.end_point_text())
          .fontSize(11)
          .fontColor(DARK.MUTED_TEXT)
          .margin({ top: 4 });
      }
      if (this.draft.action === MappedTouchAction.Swipe) {
        Column() {
          Text(t('终点 X (%)'))
            .fontSize(12)
            .fontColor(DARK.TEXT)
            .margin({ bottom: 6 });
          TextInput({ text: this.endXText, placeholder: '0–100' })
            .type(InputType.Number)
            .width('100%')
            .onChange((v: string): void => { this.endXText = v; });
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .margin({ bottom: 12 });
        Column() {
          Text(t('终点 Y (%)'))
            .fontSize(12)
            .fontColor(DARK.TEXT)
            .margin({ bottom: 6 });
          TextInput({ text: this.endYText, placeholder: '0–100' })
            .type(InputType.Number)
            .width('100%')
            .onChange((v: string): void => { this.endYText = v; });
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .margin({ bottom: 12 });
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  // ── 步骤内容：确认 ──
  @Builder
  step_confirm() {
    Column() {
      Text(this.current_title())
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(DARK.TEXT);
      Text(this.current_hint())
        .fontSize(11)
        .fontColor(DARK.MUTED_TEXT)
        .width('100%')
        .lineHeight(16)
        .margin({ top: 6, bottom: 14 });

      Column() {
        Text(this.draft.key !== null ? keymap_key_display(this.draft.key.code) : t('WizardKeyStart'))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(ACCENT);
        Text('→ ' + t(keymap_action_label_key(this.draft.action)))
          .fontSize(14)
          .fontColor(DARK.TEXT)
          .margin({ top: 6 });
        Text(keymap_entry_summary(this.draft))
          .fontSize(11)
          .fontColor(DARK.MUTED_TEXT)
          .margin({ top: 4 });
      }
      .width('100%')
      .padding(16)
      .backgroundColor(CARD)
      .border({ width: 1, color: DARK.BORDER })
      .borderRadius(RADIUS_CARD);
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  step_content() {
    if (this.stepIndex === STEP_KEY) {
      this.step_key();
    } else if (this.stepIndex === STEP_ACTION) {
      this.step_action();
    } else if (this.stepIndex === STEP_PARAMS) {
      this.step_params();
    } else if (this.stepIndex === STEP_POSITION) {
      this.step_position();
    } else {
      this.step_confirm();
    }
  }

  @Builder
  content() {
    Column() {
      this.stepper();
      Text(this.successText)
        .fontSize(12)
        .fontColor(ACCENT)
        .height(this.successText.length > 0 ? undefined : 0)
        .margin({ bottom: this.successText.length > 0 ? 8 : 0 });
      // 错误行：finish 校验失败 / 当前步骤未通过（「下一步」被禁用时的原因）
      if (this.current_error_text().length > 0) {
        Text(this.current_error_text())
          .fontSize(11)
          .fontColor(WARNING)
          .width('100%')
          .lineHeight(15)
          .margin({ bottom: 8 });
      }
      this.step_content();
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  actions() {
    Row() {
      SecondaryButton({
        label: t('取消'),
        minButtonWidth: 88,
        on_action: (): void => { SubWindowHost.close(WINDOW_NAME); },
      });
      Blank()
        .layoutWeight(1);
      if (this.stepIndex > STEP_KEY && !this.committed) {
        SecondaryButton({
          label: t('WizardPrevious'),
          minButtonWidth: 88,
          on_action: (): void => { this.previous(); },
        })
        .margin({ right: 8 });
      }
      PrimaryButton({
        label: this.stepIndex === STEP_CONFIRM ? t('WizardFinish') : t('WizardNext'),
        minButtonWidth: 96,
        actionEnabled: this.committed ? false : this.can_next(),
        on_action: (): void => { this.next(); },
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
        subtitle: this.current_title() + ' · ' + this.current_hint(),
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
