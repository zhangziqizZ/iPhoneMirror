// Theme.ets —— 原版深色主题的忠实搬用
//
// 数据源（逐条对应，值一个不改）：
//   src/SharedUI/Themes/DarkTheme.xaml      ← App.xaml 里 <ui:ThemesDictionary Theme="Dark"/>
//   src/App/App.xaml                        ← 默认主题就是 Dark
//
// 命名规则：常量名 = 原版 x:Key 去掉 "Brush" 后缀再全大写，
//          例如原版 CaptureStartBrush 在这里是 CAPTURE_START。
//          想在原版里核对某个颜色，直接把常量名小写成驼峰后加 Brush 即可。
//
// 颜色格式：ArkUI 与 WPF 都用 #AARRGGBB，所以原版的 #E61F1F1F 可以原样搬，
//          不需要做 alpha 重排。

// ───────────────────────── 窗口 / 面板底色 ─────────────────────────

/** App.xaml 窗口 Background（#E61F1F1F，带 90% 不透明度，对应 Mica 底） */
export const APP_BACKGROUND: string = '#E61F1F1F';
/** 同 AppBackground 的实色版本，用于不支持透明的容器 */
export const BACKGROUND: string = '#FF1F1F1F';
/** NavigationView（左侧导航栏）底色 */
export const SIDEBAR: string = '#C41F1F1F';
/** 常规面板（设备面板、设置面板、统计面板的外壳） */
export const PANEL: string = '#B3242424';
/** 层层抬升的次级面板 */
export const PANEL_ALT: string = '#D1292929';
/** 卡片（设置卡片、当前设备卡） */
export const CARD: string = '#A6292929';
export const CARD_HOVER: string = '#C42E2E2E';
/** 工作区卡片：未选中时完全透明，只靠边框分层 */
export const WORKSPACE_CARD: string = '#00FFFFFF';
export const WORKSPACE_CARD_HOVER: string = '#14FFFFFF';
/** 工作区条目选中态与其边框（导航项 / 设备行） */
export const WORKSPACE_ITEM_SELECTED: string = '#28479EF5';
export const WORKSPACE_ITEM_SELECTED_BORDER: string = '#FF69B1F8';
export const DIALOG_SURFACE: string = '#F2242424';

// ───────────────────────── 边框 / 分隔 ─────────────────────────

export const BORDER: string = '#24FFFFFF';
export const BORDER_SOFT: string = '#14FFFFFF';
export const CONTROL_DIVIDER: string = '#26FFFFFF';

// ───────────────────────── 文字 ─────────────────────────

export const TEXT: string = '#FFF5F5F7';
export const MUTED_TEXT: string = '#FFB7B7BC';

// ───────────────────────── 强调色 ─────────────────────────

export const ACCENT: string = '#FF69B1F8';
export const ACCENT_HOVER: string = '#FF8CC6FF';
export const ON_ACCENT: string = '#FF0F1419';
export const FOCUS_STROKE: string = '#FF69B1F8';
/** 主操作按钮（开始投屏的通用蓝色，非捕获按钮） */
export const PRIMARY_ACTION: string = '#FF479EF5';
export const PRIMARY_ACTION_HOVER: string = '#FF62ABF5';
export const PRIMARY_ACTION_PRESSED: string = '#FF2886DE';
export const PRIMARY_ACTION_BORDER: string = '#FF9BCEFF';
export const PRIMARY_ACTION_TEXT: string = '#FF0F1419';

// ───────────────────────── 控件填充 ─────────────────────────

export const CONTROL_FILL: string = '#14FFFFFF';
export const CONTROL_HOVER: string = '#20FFFFFF';
export const CONTROL_PRESSED: string = '#2AFFFFFF';
export const ICON_BUTTON_HOVER: string = '#1FFFFFFF';
export const SELECTION: string = '#24FFFFFF';
export const COMBO_BACKGROUND: string = '#14FFFFFF';
export const COMBO_HOVER: string = '#20FFFFFF';
export const COMBO_OPEN: string = '#2AFFFFFF';
export const COMBO_POPUP: string = '#F2292929';
export const COMBO_ITEM_SELECTED: string = '#28FFFFFF';
export const SCROLL_THUMB: string = '#70FFFFFF';

// ───────────────────────── 语义色 ─────────────────────────

export const SUCCESS: string = '#FF6CCB8F';
export const WARNING: string = '#FFFFC55C';
export const ERROR: string = '#FFFF6961';
export const DANGER: string = '#FFC9363E';
export const DANGER_HOVER: string = '#FFD13D45';
export const DANGER_BORDER: string = '#FFFFAAA5';
export const DANGER_BUTTON_TEXT: string = '#FFFFFFFF';

/** 状态徽标：已生效 / 待处理 / 失败（原版状态行与设备状态用） */
export const STATUS_APPLIED: string = '#FF6CCB8F';
export const STATUS_PENDING: string = '#FFFFC55C';
export const STATUS_FAILED: string = '#FFFF6961';

/** 提示条底色（半透明语义色） */
export const WARNING_SURFACE: string = '#22FFC55C';
export const ERROR_SURFACE: string = '#22FF6961';
export const SUCCESS_SURFACE: string = '#226CCB8F';

export const OVERLAY: string = '#D91F1F22';
export const MEDIA_OVERLAY: string = '#E6222226';

// ───────────────────────── 预览区专用 ─────────────────────────

/** 预览画布底色（PreviewPanel 的 Background） */
export const PREVIEW_CHROME: string = '#EE0B0B0C';
/** 预览空态里的圆形底（92 / 96 / 76 / 84px 圆都用它） */
export const PREVIEW_PANEL_ALT: string = '#FF111113';
/** 预览空态圆的边框 */
export const PREVIEW_BORDER: string = '#FF3C3C40';
export const PREVIEW_TEXT: string = '#FFF5F5F7';
export const PREVIEW_MUTED_TEXT: string = '#FFB8B8BD';

// ───────────────────────── 捕获按钮（HeaderPanel 的开始/停止投屏） ─────────────────────────

/** 未投屏：「开始投屏」 */
export const CAPTURE_START: string = '#FF0A67D0';
export const CAPTURE_START_HOVER: string = '#FF0A5FAF';
export const CAPTURE_START_BORDER: string = '#FF78BAFF';
/** 投屏中：「停止投屏」 */
export const CAPTURE_STOP: string = '#FFC9363E';
export const CAPTURE_STOP_HOVER: string = '#FFB92F38';
export const CAPTURE_STOP_BORDER: string = '#FFFF979C';
export const CAPTURE_ACTION_TEXT: string = '#FFFFFFFF';

// ───────────────────────── 尺寸口径（同样取自原版 XAML） ─────────────────────────

/**
 * NavigationView.CompactPaneLength（收起态宽度）。
 *
 * 原版 48（MainWindow.xaml:773）。这里曾写成 56，注释理由是「鸿蒙 PC 高 DPI 下
 * 图标显小」—— 那个「显小」其实是 FluentIcon 渲染器的 bug（墨迹只有应有尺寸的
 * 约一半，见 FluentIcon.ets 的取证注释）。渲染器修好后图标按原版口径出图，
 * 加宽就没有理由了，回归声明的 48。
 */
export const NAV_RAIL_COMPACT: number = 48;
/** NavigationView.OpenPaneLength（展开态宽度） */
export const NAV_RAIL_OPEN: number = 208;
/** LeftPanelHost Width —— 设备面板宽度 */
export const DEVICE_PANEL_WIDTH: number = 300;
/** MainContentGrid 的 LeftGapColumn Width */
export const COLUMN_GAP: number = 18;
/** CaptureActionButton：Width 132 / Height 40 / CornerRadius 12 / Padding 16,8 */
export const CAPTURE_ACTION_WIDTH: number = 132;
export const CAPTURE_ACTION_HEIGHT: number = 40;
export const CAPTURE_ACTION_RADIUS: number = 12;
/** 图标与文字的间距：卡片内 ToolButton 用 9，预览快捷条用 6 */
export const ICON_TEXT_GAP_CARD: number = 9;
export const ICON_TEXT_GAP_QUICK: number = 6;

// ───────────────────────── 第二轮补齐：控件态与滚动条 ─────────────────────────
//
// 同样是 DarkTheme.xaml 里逐条搬过来的（值一个不改），原先只搬了主窗口用到的，
// 这一批是子窗口（ModernControls.xaml / App.xaml 的共享样式）需要的。

/** TextSelectionBrush —— RoundedTextBox 的 SelectionBrush */
export const TEXT_SELECTION: string = '#805CAFFB';
/** ComboBorderHoverBrush —— RoundedTextBox / 普通按钮 hover 时的边框 */
export const COMBO_BORDER_HOVER: string = '#52FFFFFF';
export const COMBO_ITEM_HOVER: string = '#20FFFFFF';
export const COMBO_ITEM_SELECTED_HOVER: string = '#38FFFFFF';
/** IconButtonPressedBrush */
export const ICON_BUTTON_PRESSED: string = '#33FFFFFF';
/** MutedTextBrush 的别名（原版两个键同值，有地方引 MutedBrush） */
export const MUTED: string = '#FFB7B7BC';

export const PRIMARY_ACTION_HOVER_BORDER: string = '#FFC4E1FF';
export const PRIMARY_ACTION_PRESSED_BORDER: string = '#FF79BDF8';
export const PRIMARY_ACTION_FOCUS: string = '#FF0F1419';
export const PRIMARY_ACTION_DISABLED: string = '#FF3A3A3D';
export const PRIMARY_ACTION_DISABLED_TEXT: string = '#FFB8B8BD';

export const DANGER_PRESSED: string = '#FFA82830';
export const DANGER_HOVER_BORDER: string = '#FFFFCBC8';
export const DANGER_PRESSED_BORDER: string = '#FFFF8E87';
/** ShortcutClearIconBrush —— 快捷键窗口里清除按钮的图标色 */
export const SHORTCUT_CLEAR_ICON: string = '#FFFFFFFF';

export const SCROLL_TRACK: string = '#00FFFFFF';
export const SCROLL_TRACK_HOVER: string = '#24FFFFFF';
export const SCROLL_THUMB_HOVER: string = '#94FFFFFF';
export const SCROLL_THUMB_PRESSED: string = '#A6FFFFFF';

// ───────────────────────── 共享控件的尺寸口径（ModernControls.xaml / App.xaml） ─────────────────────────

/** App.xaml 隐式 Button 样式：CornerRadius 11 / Padding 18,10 / MinHeight 42 / FontSize 14 */
export const BUTTON_CORNER: number = 11;
export const BUTTON_PADDING_H: number = 18;
export const BUTTON_PADDING_V: number = 10;
export const BUTTON_MIN_HEIGHT: number = 42;
export const BUTTON_FONT_SIZE: number = 14;
/** 按下时的缩放（Button 模板 RenderTransform ScaleTransform 0.96） */
export const BUTTON_PRESSED_SCALE: number = 0.96;
/** 禁用态不透明度 */
export const DISABLED_OPACITY: number = 0.34;

/** PrimaryButton：CornerRadius 12（Padding 继承隐式 Button 的 18,10） */
export const PRIMARY_BUTTON_CORNER: number = 12;

/** SettingsSection：CornerRadius 16 / Padding 18 / 1px BorderBrush / 底色 CardBrush */
export const SETTINGS_SECTION_CORNER: number = 16;
export const SETTINGS_SECTION_PADDING: number = 18;

/** RoundedTextBox：CornerRadius 10 / Padding 10,5 / MinHeight 40 / FontSize 12 */
export const TEXTBOX_CORNER: number = 10;
export const TEXTBOX_PADDING_H: number = 10;
export const TEXTBOX_PADDING_V: number = 5;
export const TEXTBOX_MIN_HEIGHT: number = 40;
export const TEXTBOX_FONT_SIZE: number = 12;
/** IsReadOnly 时的不透明度 */
export const TEXTBOX_READONLY_OPACITY: number = 0.7;

// ───────────────────────── 第三轮补齐：子窗口还原到第 3 个时新引到的键 ─────────────────────────

/** WindowBackgroundBrush —— 实色窗口底（ProtectedContentNoticeWindow 用，非 Mica 透明底） */
export const WINDOW_BACKGROUND: string = '#FF1F1F1F';

/** SliderTrackBrush / Thumb —— ImageSettingsWindow 的四个滑杆 */
export const SLIDER_TRACK: string = '#3DFFFFFF';
export const SLIDER_THUMB_FILL: string = '#FFF5F5F7';
export const SLIDER_THUMB_HOVER: string = '#FFFFFFFF';
export const SLIDER_THUMB_BORDER: string = '#FF479EF5';

/** MediaOverlayTextBrush —— 媒体浮层上的文字（MediaOutputSettings / 投屏浮层） */
export const MEDIA_OVERLAY_TEXT: string = '#FFF7F7F8';

/**
 * App.xaml 的隐式 Slider 样式（第 444–520 行）：
 *   Slider Height 20 / Track Height 16 / Orientation Horizontal
 *   DecreaseRepeatButton（滑钮左侧）= AccentBrush / Height 4 / CornerRadius 2
 *   IncreaseRepeatButton（滑钮右侧）= SliderTrackBrush / Height 4 / CornerRadius 2
 *   Thumb = Ellipse 16×16 / Fill SliderThumbFillBrush / Stroke SliderThumbBorderBrush / StrokeThickness 3
 *   IsMouseOver → Thumb Fill 转 SliderThumbHoverBrush、Stroke 转 AccentHoverBrush
 *   IsDragging → Thumb Fill 转 AccentBrush
 *   IsEnabled=False → Opacity 0.4
 */
export const SLIDER_TRACK_THICKNESS: number = 4;
export const SLIDER_THUMB_SIZE: number = 16;
export const SLIDER_THUMB_STROKE: number = 3;
export const SLIDER_DISABLED_OPACITY: number = 0.4;

// ───────────────────────── 第四轮补齐：WPF-UI 库级配色（ToolTip） ─────────────────────────
//
// 导航项 hover 时弹出的名称气泡（原版 ToolTip）用的三个色键**不在工程主题文件里**，
// 而在上游引用的 WPF-UI 4.3.0 库里：库的 ToolTip.xaml 定义 DefaultToolTipStyle，
// 键值定义在库的 Resources/Theme/Dark.xaml、Light.xaml。原版每个 ui:NavigationViewItem
// 都设了 ToolTip="{DynamicResource NavXxxDescription}"，所以走的就是这三个键。

/** 库 Dark.xaml: ToolTipBackground = AcrylicBackgroundFillColorDefault（原值 #2C2C2C） */
export const TOOLTIP_BACKGROUND: string = '#FF2C2C2C';
/** 库 Dark.xaml: ToolTipBorderBrush = SurfaceStrokeColorFlyout（原值 #33000000） */
export const TOOLTIP_BORDER: string = '#33000000';
/** 库 Dark.xaml: ToolTipForeground = TextFillColorPrimary（原值 #FFFFFF） */
export const TOOLTIP_FOREGROUND: string = '#FFFFFFFF';


// ───────────────────────── 双主题字典（对应原版 Light/DarkTheme.xaml 同构） ─────────────────────────
//
// 原版 ThemeService 在 Apply() 时整本切换 Light / Dark 资源字典；这里用 DARK / LIGHT 两个
// 同构字典等价实现。所有界面颜色改从 this.scheme 派生的 DARK/LIGHT 取（见 ThemedComponent /
// 主窗口的 get T()），即可随系统浅深 + 用户偏好实时重绘。
// 浅色值逐条取自 src/SharedUI/Themes/LightTheme.xaml，深色值直接引用上方逐条搬来的常量。

export interface ThemeColors {
  ACCENT: string;
  ACCENT_HOVER: string;
  APP_BACKGROUND: string;
  BACKGROUND: string;
  BORDER: string;
  BORDER_SOFT: string;
  CAPTURE_ACTION_TEXT: string;
  CAPTURE_START: string;
  CAPTURE_START_BORDER: string;
  CAPTURE_START_HOVER: string;
  CAPTURE_STOP: string;
  CAPTURE_STOP_BORDER: string;
  CAPTURE_STOP_HOVER: string;
  CARD: string;
  CARD_HOVER: string;
  COMBO_BACKGROUND: string;
  COMBO_BORDER_HOVER: string;
  COMBO_HOVER: string;
  COMBO_ITEM_HOVER: string;
  COMBO_ITEM_SELECTED: string;
  COMBO_ITEM_SELECTED_HOVER: string;
  COMBO_OPEN: string;
  COMBO_POPUP: string;
  CONTROL_DIVIDER: string;
  CONTROL_FILL: string;
  CONTROL_HOVER: string;
  CONTROL_PRESSED: string;
  DANGER: string;
  DANGER_BORDER: string;
  DANGER_BUTTON_TEXT: string;
  DANGER_HOVER: string;
  DANGER_HOVER_BORDER: string;
  DANGER_PRESSED: string;
  DANGER_PRESSED_BORDER: string;
  DIALOG_SURFACE: string;
  ERROR: string;
  ERROR_SURFACE: string;
  FOCUS_STROKE: string;
  ICON_BUTTON_HOVER: string;
  ICON_BUTTON_PRESSED: string;
  MEDIA_OVERLAY: string;
  MEDIA_OVERLAY_TEXT: string;
  MUTED: string;
  MUTED_TEXT: string;
  ON_ACCENT: string;
  OVERLAY: string;
  PANEL: string;
  PANEL_ALT: string;
  PREVIEW_BORDER: string;
  PREVIEW_CHROME: string;
  PREVIEW_MUTED_TEXT: string;
  PREVIEW_PANEL_ALT: string;
  PREVIEW_TEXT: string;
  PRIMARY_ACTION: string;
  PRIMARY_ACTION_BORDER: string;
  PRIMARY_ACTION_DISABLED: string;
  PRIMARY_ACTION_DISABLED_TEXT: string;
  PRIMARY_ACTION_FOCUS: string;
  PRIMARY_ACTION_HOVER: string;
  PRIMARY_ACTION_HOVER_BORDER: string;
  PRIMARY_ACTION_PRESSED: string;
  PRIMARY_ACTION_PRESSED_BORDER: string;
  PRIMARY_ACTION_TEXT: string;
  SCROLL_THUMB: string;
  SCROLL_THUMB_HOVER: string;
  SCROLL_THUMB_PRESSED: string;
  SCROLL_TRACK: string;
  SCROLL_TRACK_HOVER: string;
  SELECTION: string;
  SHORTCUT_CLEAR_ICON: string;
  SIDEBAR: string;
  SLIDER_THUMB_BORDER: string;
  SLIDER_THUMB_FILL: string;
  SLIDER_THUMB_HOVER: string;
  SLIDER_TRACK: string;
  STATUS_APPLIED: string;
  STATUS_FAILED: string;
  STATUS_PENDING: string;
  SUCCESS: string;
  SUCCESS_SURFACE: string;
  TEXT: string;
  TEXT_SELECTION: string;
  TOOLTIP_BACKGROUND: string;
  TOOLTIP_BORDER: string;
  TOOLTIP_FOREGROUND: string;
  WARNING: string;
  WARNING_SURFACE: string;
  WINDOW_BACKGROUND: string;
  WORKSPACE_CARD: string;
  WORKSPACE_CARD_HOVER: string;
  WORKSPACE_ITEM_SELECTED: string;
  WORKSPACE_ITEM_SELECTED_BORDER: string;
}

// 深色：引用上方逐条搬来的深色常量（值一个不改），保证未迁移文件用的具名 const 与此一致。
export const DARK: ThemeColors = {
  ACCENT: ACCENT,
  ACCENT_HOVER: ACCENT_HOVER,
  APP_BACKGROUND: APP_BACKGROUND,
  BACKGROUND: BACKGROUND,
  BORDER: BORDER,
  BORDER_SOFT: BORDER_SOFT,
  CAPTURE_ACTION_TEXT: CAPTURE_ACTION_TEXT,
  CAPTURE_START: CAPTURE_START,
  CAPTURE_START_BORDER: CAPTURE_START_BORDER,
  CAPTURE_START_HOVER: CAPTURE_START_HOVER,
  CAPTURE_STOP: CAPTURE_STOP,
  CAPTURE_STOP_BORDER: CAPTURE_STOP_BORDER,
  CAPTURE_STOP_HOVER: CAPTURE_STOP_HOVER,
  CARD: CARD,
  CARD_HOVER: CARD_HOVER,
  COMBO_BACKGROUND: COMBO_BACKGROUND,
  COMBO_BORDER_HOVER: COMBO_BORDER_HOVER,
  COMBO_HOVER: COMBO_HOVER,
  COMBO_ITEM_HOVER: COMBO_ITEM_HOVER,
  COMBO_ITEM_SELECTED: COMBO_ITEM_SELECTED,
  COMBO_ITEM_SELECTED_HOVER: COMBO_ITEM_SELECTED_HOVER,
  COMBO_OPEN: COMBO_OPEN,
  COMBO_POPUP: COMBO_POPUP,
  CONTROL_DIVIDER: CONTROL_DIVIDER,
  CONTROL_FILL: CONTROL_FILL,
  CONTROL_HOVER: CONTROL_HOVER,
  CONTROL_PRESSED: CONTROL_PRESSED,
  DANGER: DANGER,
  DANGER_BORDER: DANGER_BORDER,
  DANGER_BUTTON_TEXT: DANGER_BUTTON_TEXT,
  DANGER_HOVER: DANGER_HOVER,
  DANGER_HOVER_BORDER: DANGER_HOVER_BORDER,
  DANGER_PRESSED: DANGER_PRESSED,
  DANGER_PRESSED_BORDER: DANGER_PRESSED_BORDER,
  DIALOG_SURFACE: DIALOG_SURFACE,
  ERROR: ERROR,
  ERROR_SURFACE: ERROR_SURFACE,
  FOCUS_STROKE: FOCUS_STROKE,
  ICON_BUTTON_HOVER: ICON_BUTTON_HOVER,
  ICON_BUTTON_PRESSED: ICON_BUTTON_PRESSED,
  MEDIA_OVERLAY: MEDIA_OVERLAY,
  MEDIA_OVERLAY_TEXT: MEDIA_OVERLAY_TEXT,
  MUTED: MUTED,
  MUTED_TEXT: MUTED_TEXT,
  ON_ACCENT: ON_ACCENT,
  OVERLAY: OVERLAY,
  PANEL: PANEL,
  PANEL_ALT: PANEL_ALT,
  PREVIEW_BORDER: PREVIEW_BORDER,
  PREVIEW_CHROME: PREVIEW_CHROME,
  PREVIEW_MUTED_TEXT: PREVIEW_MUTED_TEXT,
  PREVIEW_PANEL_ALT: PREVIEW_PANEL_ALT,
  PREVIEW_TEXT: PREVIEW_TEXT,
  PRIMARY_ACTION: PRIMARY_ACTION,
  PRIMARY_ACTION_BORDER: PRIMARY_ACTION_BORDER,
  PRIMARY_ACTION_DISABLED: PRIMARY_ACTION_DISABLED,
  PRIMARY_ACTION_DISABLED_TEXT: PRIMARY_ACTION_DISABLED_TEXT,
  PRIMARY_ACTION_FOCUS: PRIMARY_ACTION_FOCUS,
  PRIMARY_ACTION_HOVER: PRIMARY_ACTION_HOVER,
  PRIMARY_ACTION_HOVER_BORDER: PRIMARY_ACTION_HOVER_BORDER,
  PRIMARY_ACTION_PRESSED: PRIMARY_ACTION_PRESSED,
  PRIMARY_ACTION_PRESSED_BORDER: PRIMARY_ACTION_PRESSED_BORDER,
  PRIMARY_ACTION_TEXT: PRIMARY_ACTION_TEXT,
  SCROLL_THUMB: SCROLL_THUMB,
  SCROLL_THUMB_HOVER: SCROLL_THUMB_HOVER,
  SCROLL_THUMB_PRESSED: SCROLL_THUMB_PRESSED,
  SCROLL_TRACK: SCROLL_TRACK,
  SCROLL_TRACK_HOVER: SCROLL_TRACK_HOVER,
  SELECTION: SELECTION,
  SHORTCUT_CLEAR_ICON: SHORTCUT_CLEAR_ICON,
  SIDEBAR: SIDEBAR,
  SLIDER_THUMB_BORDER: SLIDER_THUMB_BORDER,
  SLIDER_THUMB_FILL: SLIDER_THUMB_FILL,
  SLIDER_THUMB_HOVER: SLIDER_THUMB_HOVER,
  SLIDER_TRACK: SLIDER_TRACK,
  STATUS_APPLIED: STATUS_APPLIED,
  STATUS_FAILED: STATUS_FAILED,
  STATUS_PENDING: STATUS_PENDING,
  SUCCESS: SUCCESS,
  SUCCESS_SURFACE: SUCCESS_SURFACE,
  TEXT: TEXT,
  TEXT_SELECTION: TEXT_SELECTION,
  TOOLTIP_BACKGROUND: TOOLTIP_BACKGROUND,
  TOOLTIP_BORDER: TOOLTIP_BORDER,
  TOOLTIP_FOREGROUND: TOOLTIP_FOREGROUND,
  WARNING: WARNING,
  WARNING_SURFACE: WARNING_SURFACE,
  WINDOW_BACKGROUND: WINDOW_BACKGROUND,
  WORKSPACE_CARD: WORKSPACE_CARD,
  WORKSPACE_CARD_HOVER: WORKSPACE_CARD_HOVER,
  WORKSPACE_ITEM_SELECTED: WORKSPACE_ITEM_SELECTED,
  WORKSPACE_ITEM_SELECTED_BORDER: WORKSPACE_ITEM_SELECTED_BORDER,
};

// 浅色：原版 LightTheme.xaml 的逐条值。
export const LIGHT: ThemeColors = {
  ACCENT: '#FF0F6CBD',
  ACCENT_HOVER: '#FF115EA3',
  APP_BACKGROUND: '#BFF3F3F5',
  BACKGROUND: '#FFF3F3F5',
  BORDER: '#1F000000',
  BORDER_SOFT: '#12000000',
  CAPTURE_ACTION_TEXT: '#FFFFFFFF',
  CAPTURE_START: '#FF0A67D0',
  CAPTURE_START_BORDER: '#FF063F80',
  CAPTURE_START_HOVER: '#FF0A5FAF',
  CAPTURE_STOP: '#FFC9363E',
  CAPTURE_STOP_BORDER: '#FF761F24',
  CAPTURE_STOP_HOVER: '#FFB92F38',
  CARD: '#F5FFFFFF',
  CARD_HOVER: '#FFFFFFFF',
  COMBO_BACKGROUND: '#FFFFFFFF',
  COMBO_BORDER_HOVER: '#52000000',
  COMBO_HOVER: '#FFF2F2F4',
  COMBO_ITEM_HOVER: '#FFF2F2F4',
  COMBO_ITEM_SELECTED: '#16000000',
  COMBO_ITEM_SELECTED_HOVER: '#22000000',
  COMBO_OPEN: '#FFE9E9EC',
  COMBO_POPUP: '#FFFFFFFF',
  CONTROL_DIVIDER: '#1F000000',
  CONTROL_FILL: '#BFFFFFFF',
  CONTROL_HOVER: '#FFF0F0F2',
  CONTROL_PRESSED: '#FFE5E5E8',
  DANGER: '#FFD70015',
  DANGER_BORDER: '#FF7F000C',
  DANGER_BUTTON_TEXT: '#FFFFFFFF',
  DANGER_HOVER: '#FFB60012',
  DANGER_HOVER_BORDER: '#FF620009',
  DANGER_PRESSED: '#FF8F000E',
  DANGER_PRESSED_BORDER: '#FF480007',
  DIALOG_SURFACE: '#FAFFFFFF',
  ERROR: '#FFD70015',
  ERROR_SURFACE: '#12D70015',
  FOCUS_STROKE: '#FF0F6CBD',
  ICON_BUTTON_HOVER: '#14000000',
  ICON_BUTTON_PRESSED: '#24000000',
  MEDIA_OVERLAY: '#E62B2B2E',
  MEDIA_OVERLAY_TEXT: '#FFFFFFFF',
  MUTED: '#FF5F5F65',
  MUTED_TEXT: '#FF5F5F65',
  ON_ACCENT: '#FFFFFFFF',
  OVERLAY: '#BFFFFFFF',
  PANEL: '#D9FFFFFF',
  PANEL_ALT: '#FFFFFFFF',
  PREVIEW_BORDER: '#33000000',
  PREVIEW_CHROME: '#FFF1F1F3',
  PREVIEW_MUTED_TEXT: '#FF6E6E73',
  PREVIEW_PANEL_ALT: '#FFFFFFFF',
  PREVIEW_TEXT: '#FF1D1D1F',
  PRIMARY_ACTION: '#FF0F6CBD',
  PRIMARY_ACTION_BORDER: '#FF073B66',
  PRIMARY_ACTION_DISABLED: '#FFE5E5E8',
  PRIMARY_ACTION_DISABLED_TEXT: '#FF59595D',
  PRIMARY_ACTION_FOCUS: '#FFFFFFFF',
  PRIMARY_ACTION_HOVER: '#FF115EA3',
  PRIMARY_ACTION_HOVER_BORDER: '#FF052D4F',
  PRIMARY_ACTION_PRESSED: '#FF0C3B5E',
  PRIMARY_ACTION_PRESSED_BORDER: '#FF031D32',
  PRIMARY_ACTION_TEXT: '#FFFFFFFF',
  SCROLL_THUMB: '#66000000',
  SCROLL_THUMB_HOVER: '#85000000',
  SCROLL_THUMB_PRESSED: '#A6000000',
  SCROLL_TRACK: '#00000000',
  SCROLL_TRACK_HOVER: '#1A000000',
  SELECTION: '#18000000',
  SHORTCUT_CLEAR_ICON: '#FFD70015',
  SIDEBAR: '#EBF2F2F4',
  SLIDER_THUMB_BORDER: '#FF0F6CBD',
  SLIDER_THUMB_FILL: '#FFFFFFFF',
  SLIDER_THUMB_HOVER: '#FFF7F7F9',
  SLIDER_TRACK: '#29000000',
  STATUS_APPLIED: '#FF107C41',
  STATUS_FAILED: '#FFD70015',
  STATUS_PENDING: '#FF9A4B00',
  SUCCESS: '#FF107C41',
  SUCCESS_SURFACE: '#14107C41',
  TEXT: '#FF1D1D1F',
  TEXT_SELECTION: '#665CAFFB',
  // 库 Light.xaml: ToolTipBackground / BorderBrush / Foreground（原值 #F9F9F9 / #0F000000 / #E4000000）
  TOOLTIP_BACKGROUND: '#FFF9F9F9',
  TOOLTIP_BORDER: '#0F000000',
  TOOLTIP_FOREGROUND: '#E4000000',
  WARNING: '#FF9A4B00',
  WARNING_SURFACE: '#149A4B00',
  WINDOW_BACKGROUND: '#FFF3F3F5',
  WORKSPACE_CARD: '#00FFFFFF',
  WORKSPACE_CARD_HOVER: '#0D000000',
  WORKSPACE_ITEM_SELECTED: '#1F0F6CBD',
  WORKSPACE_ITEM_SELECTED_BORDER: '#FF0F6CBD',
};
