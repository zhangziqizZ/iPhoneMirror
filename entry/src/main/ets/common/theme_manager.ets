// theme_manager.ets —— 双主题方案的状态协调（对应原版 ThemeService）
//
// 原版 Win 的 ThemeService：默认 AppTheme.System，监听系统浅深变化实时切换
// （读注册表 AppsUseLightTheme / 监听 UserPreferenceChanged），Apply() 时把
// 资源字典整本换成 Light / Dark 版。
//
// 鸿蒙等价实现用三把 AppStorage 钥匙：
//   themePref    number  用户偏好 0=跟随系统 1=深色 2=浅色（来自主窗口 themeIndex）
//   systemDark   boolean 系统当前是否深色（EntryAbility.onConfigurationUpdate 写入）
//   themeScheme  string  最终生效方案 'dark' | 'light'（recompute 算出，组件读它）
//
// 组件侧用 @StorageLink('themeScheme') 建立响应式依赖，颜色统一从
// common/Theme.ets 的 DARK / LIGHT 字典按当前 scheme 取，即可随系统/偏好实时重绘，
// 与原版「所有窗口同步切换」一致。

export const THEME_PREF_KEY: string = 'themePref';
export const THEME_SCHEME_KEY: string = 'themeScheme';
export const SYSTEM_DARK_KEY: string = 'systemDark';

// 综合「用户偏好」与「系统浅深」算出最终生效方案。
export function recomputeThemeScheme(): void {
  const prefRaw: number = AppStorage.get(THEME_PREF_KEY) as number;
  const pref: number = (prefRaw !== undefined && prefRaw !== null) ? prefRaw : 0;
  const systemDarkRaw: boolean = AppStorage.get(SYSTEM_DARK_KEY) as boolean;
  const systemDark: boolean = (systemDarkRaw !== undefined && systemDarkRaw !== null) ? systemDarkRaw : true;
  const scheme: string =
    pref === 1 ? 'dark' : pref === 2 ? 'light' : (systemDark ? 'dark' : 'light');
  AppStorage.setOrCreate(THEME_SCHEME_KEY, scheme);
}

// 系统浅深变化时（EntryAbility.onConfigurationUpdate）调用：
// 记录系统状态并重新计算最终方案。
export function setSystemDark(dark: boolean): void {
  AppStorage.setOrCreate(SYSTEM_DARK_KEY, dark);
  recomputeThemeScheme();
}
