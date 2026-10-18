// MaterialSelect.ets —— 下拉选择器（官方 Select 组件 + 沉浸光感，薄封装）
//
// ★★★ 2026-10-18 第三次重构，前两次分别错在哪（都记下来，别再走回头路）★★★
//
//   ① 第一版：用官方 Select。当时凭印象写下「Select 的弹出菜单是选择器样式，
//      不呈现沉浸光感的液态玻璃菜单」，于是改成自建 bindPopup。
//      **这个判断是错的** —— 官方《组件适配沉浸光感》明写：
//        「下拉按钮支持通过 systemMaterial 属性设置沉浸光感效果；
//          **下拉菜单通过独立的 menuSystemMaterial 接口设置沉浸光感效果**。」
//      也就是说 Select 本来就有沉浸光感菜单，只是入口是**另一个**接口。
//
//   ② 第二版：自建 bindPopup。踩了两个坑，症状分别是「大白块」和「有项无字」：
//      · 主窗口背景是**全透明**的（EntryAbility: setWindowBackgroundColor('#00000000')）。
//        不显式给 popupColor 时，气泡默认走「透明 + COMPONENT_ULTRA_THICK 模糊」，
//        而模糊要采样背后的画面 —— 透明窗 surface 内没有可采内容，合成器兜底成
//        一块**不透明白面** ⇒ 用户截图里的大白块。
//      · 菜单项 Text 用了 `.layoutWeight(1)`，而外层 Column 只有
//        `constraintSize({minWidth,maxWidth})`、**没有定宽** ⇒
//        「100% 宽的子元素 + layoutWeight」形成循环测量，文本宽度被算成 0
//        ⇒ 四个项都在（选中项的灰底、hover 的系统灰块都看得到），却一个字都不显示。
//
//   ③ 现在回到官方 Select，两个材质入口分别给（官方默认档）：
//        · 下拉按钮：systemMaterial → ULTRA_THIN（官方：默认即此档，且默认带
//          interactive 交互形变与 lightEffect 光感交互反馈）
//        · 下拉菜单：menuSystemMaterial → THICK（官方：菜单位置/背景难以提前确定，
//          THICK 能降低背景对菜单项的干扰）
//
// ★ 「沉浸光感的强度能不能在 App 里调？」—— **不能，用户说得对，已核对官方文档**：
//   强度（强 / 均衡 / 弱）是**系统设置**（设置 > 桌面和个性化 > 沉浸光感），
//   App 侧只能做三件事：应用级开关（module.json5 的
//   `ohos.arkui.UIMaterial.state` = default/enable/disable）、组件级开关
//   （systemMaterial / menuSystemMaterial，传 uiMaterial.Material.empty 关闭）、
//   以及用 uiMaterial.getMaterialInfo() 读当前状态。**没有**调节强度的接口。
//
// ★ 副作用（官方明示，属预期行为而非 bug）：下拉按钮的沉浸光感启用了
//   lightEffect 时，「默认的按压态和悬浮态视觉反馈不再展示，由材质的光感交互
//   反馈效果替代」—— 所以这个下拉按钮上**不会**再出现 HoverEffect.Highlight 的
//   灰色小方块；普通按钮（应用 / 更多设置 / 刷新设备…）仍然保留灰色小方块。
// ★ 2026-10-18 补记第四个坑（用户截图：「每次重新打开应用，渲染分辨率上限 /
//   本地渲染帧率上限 / 解码器三个下拉都是空的，点开菜单选一项后才显示」）：
//   官方文档对 selected 的措辞是 "Sets the index of the **initially** selected
//   option" —— 它只在建立选中态那一刻起作用；按钮文本走的是**另一个**属性
//   value："Sets the text content of drop-down button. By default, it will be
//   replaced by the content of the selected option, **if any**"。
//   "initially" + "if any" 两句加起来就是症状的来源：Select 建立时若选中态
//   与 options 的绑定没如期生效（本工程 options 经 @Prop 同步、且选择器位于
//   首次打开才创建的面板里），按钮文本就停在空，而且此后 selected 索引没变过
//   （一直是 0/1），框架认为属性无变化、不再刷新 ⇒ 空文本一直挂着，直到用户
//   手动点开菜单选一项（那条路径会走官方明示的"选择后按钮文本自动更新"）。
//   ⇒ 修复：**显式**把 value 设成选中项的文本，不再依赖"自动替换"的隐式路径。
//     同时把索引夹到合法区间（调用方若传 -1/越界，selected 会按官方语义回落
//     到"无选中"，按钮又会空）。
import { uiMaterial } from '@kit.ArkUI';
import { ThemeColors, DARK, LIGHT, RADIUS_CONTROL } from './Theme';
import { THEME_SCHEME_KEY } from './theme_manager';

@Component
export struct MaterialSelect {
  @Prop options: SelectOption[] = [];
  @Prop selectedIndex: number = 0;
  // API 23 起 V1 装饰器不能修饰 Function 类型，回调走普通成员（调用方照常传）。
  onSelect: (index: number) => void = (_: number): void => {};

  @StorageLink(THEME_SCHEME_KEY) scheme: string = 'dark';

  /**
   * 下拉按钮的沉浸式系统材质（官方默认档 ULTRA_THIN）。
   * interactive = 交互形变；lightEffect = 光感交互反馈（开启后按钮自身的
   * 按压/悬浮视觉反馈被材质替代，见文件头说明）。
   */
  private buttonMaterial: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
    interactive: true,
    lightEffect: { color: Color.White },
  });

  /**
   * 下拉菜单的沉浸式系统材质（官方对 Menu 的推荐档 THICK）。
   * 与 buttonMaterial 相互独立、可分别开启或关闭；要单独关某一处应传
   * `uiMaterial.Material.empty`，**不能**传 undefined（undefined 的语义是
   * "恢复组件默认行为"，反而可能把材质又放回来）。
   */
  private menuMaterial: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THICK,
  });

  private palette(): ThemeColors {
    const p: ThemeColors | undefined = this.scheme === 'dark' ? DARK : LIGHT;
    return p ?? DARK;
  }

  /**
   * 选中索引夹到合法区间。
   *
   * ★ 为什么下沉成方法而不是写在 build 里：ArkTS 10905210 硬约束——
   *   build 方法体内只能有一条 UI 语句，**连 const 局部变量声明都不允许**
   *   （编译器会把它当成"另一个节点"，同 GlowLayer.ets:46 记录的那个坑）。
   *   第一版修复就是把两个 const 写在 build 里，直接 10905210 编译失败。
   */
  private safeIndex(): number {
    if (this.options.length <= 0) {
      return 0;
    }
    return Math.max(0, Math.min(this.selectedIndex, this.options.length - 1));
  }

  /**
   * 按钮文本 = 选中项的 value。
   * 调用方若传 -1/越界索引，selected 会按官方语义（"invalid value → -1 →
   * no selection"）变成无选中，按钮文本又空了 ⇒ 统一走 safeIndex() 取值。
   * 返回类型就是 ResourceStr（SelectOption.value 的类型，.value() 属性原样
   * 收这个类型）⇒ 不做任何 String() 转换，避免 ArkTS 严格模式下的类型风险。
   */
  private selectedText(): ResourceStr {
    if (this.options.length <= 0) {
      return '';
    }
    return this.options[this.safeIndex()].value;
  }

  build() {
    // 官方 Select：自带宽度/高度/边框/箭头/下拉菜单/键盘交互，样式逐条对齐
    // 原版 WPF ComboBox（Height 40 / CornerRadius 10 / Padding 12,0）。
    // 按钮文本显式取选中项内容（value 属性的默认行为是"有选中项时被选项文本
    // 替换"，但本工程实测首次建立时不生效，见文件头第四个坑的说明）。
    // 用户选择后官方会把按钮文本自动更新为选项文本，父组件 @State 同步后
    // selectedText() 重算出的值与之相同，两条路径不冲突。
    Select(this.options)
      .selected(this.safeIndex())
      .value(this.selectedText())
      .height(40)
      .borderRadius(RADIUS_CONTROL)   // Apple 圆角分级：40 高下拉触发器 → 10（RADIUS_CONTROL）
      .backgroundColor(this.palette().COMBO_BACKGROUND)
      .border({ width: 1, color: this.palette().BORDER_SOFT })
      // 按钮文本（字号 14 与整体控件档一致）
      .font({ size: 14, weight: FontWeight.Regular })
      .fontColor(this.palette().TEXT)
      // 菜单项：未选中走正文色、选中走强调色（原版 ComboBox 的选中态）
      .optionFontColor(this.palette().TEXT)
      .optionBgColor(Color.Transparent)
      .selectedOptionFontColor(this.palette().ACCENT)
      .selectedOptionBgColor(this.palette().COMBO_ITEM_SELECTED)
      // 沉浸光感：按钮与菜单两个独立入口（见文件头 ③）
      .systemMaterial(this.buttonMaterial)
      .menuSystemMaterial(this.menuMaterial)
      .onSelect((index: number, value?: string): void => {
        this.onSelect(index);
      })
  }
}
