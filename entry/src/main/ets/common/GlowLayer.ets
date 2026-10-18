import {
  GLOW_ENABLED_KEY,
  GLOW_STRENGTH_KEY,
  GLOW_DEGRADED_KEY,
} from './WindowServices';
import {
  glow_strength_params,
  GlowStrengthParams,
  PULSE_DURATION_MS,
  PULSE_MIN_OPACITY,
  PULSE_MAX_OPACITY,
  BLINK_DURATION_MS,
  BLINK_MIN_OPACITY,
  BLINK_MAX_OPACITY,
  FOCUS_TRANSITION_MS,
} from './GlowConfig';

@Component
export struct GlowLayer {
  @Prop glowType: string = 'radial';
  @Prop glowColor: string = '#30FFFFFF';
  @Prop glowDirection: string = 'all';
  @Prop glowAnimation: string = 'none';
  @Prop glowHoverTrigger: boolean = false;

  @StorageLink(GLOW_ENABLED_KEY) glowEnabled: boolean = true;
  @StorageLink(GLOW_STRENGTH_KEY) glowStrength: number = 1;
  @StorageLink(GLOW_DEGRADED_KEY) glowDegraded: boolean = false;

  @State hovered: boolean = false;
  @State animOpacity: number = 0;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private canvasContext: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  aboutToAppear(): void {
    if (this.glowAnimation === 'pulse') {
      this.animOpacity = PULSE_MIN_OPACITY;
    } else if (this.glowAnimation === 'blink') {
      this.animOpacity = BLINK_MIN_OPACITY;
    } else {
      this.animOpacity = 1;
    }
  }

  // 10905210 的硬约束：build 方法体内只能有一条 UI 语句（根节点必须是容器）。
  // 连局部变量声明都不能写在 build 里（会被编译器当成"另一个节点"），
  // 所以强度参数/透明度/可见性全部下沉成私有方法。
  private glowParams(): GlowStrengthParams {
    return glow_strength_params(this.glowStrength);
  }

  private currentOpacity(): number {
    return this.glowHoverTrigger ? this.animOpacity : this.glowParams().opacity;
  }

  private isVisible(): boolean {
    return this.glowEnabled && (!this.glowHoverTrigger || this.hovered);
  }

  build() {
    Stack() {
      if (this.isVisible()) {
        Canvas(this.canvasContext)
          .width('100%')
          .height('100%')
          .onReady(() => {
            this.drawGlow(this.glowParams().radius, this.currentOpacity());
          })
      }
    }
    .width('100%')
    .height('100%')
    // 沉浸式光感层是盖在按钮/卡片之上的覆盖层：必须让点击和悬停穿透到下层，
    // 否则会出现"发光很好看，但按钮点不动、hover 不响应"的假死故障。
    // Transparent = 自身仍参与命中（glowHoverTrigger 的 onHover 还能收到），
    // 同时不阻塞兄弟节点与父节点。
    .hitTestBehavior(HitTestMode.Transparent)
    .onHover((isHover: boolean) => {
      if (!this.glowHoverTrigger) return;
      this.hovered = isHover;
      animateTo({ duration: FOCUS_TRANSITION_MS, curve: Curve.EaseOut }, () => {
        this.animOpacity = isHover ? this.glowParams().opacity : 0;
      });
    })
  }

  private drawGlow(radius: number, opacity: number): void {
    const canvasW = this.canvasContext.width;
    const canvasH = this.canvasContext.height;
    if (canvasW <= 0 || canvasH <= 0) return;

    this.canvasContext.clearRect(0, 0, canvasW, canvasH);

    if (this.glowType === 'radial') {
      const cx = canvasW / 2;
      const cy = canvasH / 2;
      const r = Math.max(radius, Math.min(cx, cy));
      const gradient = this.canvasContext.createRadialGradient(cx, cy, 0, cx, cy, r);
      gradient.addColorStop(0, this.applyAlpha(this.glowColor, opacity));
      gradient.addColorStop(1, this.applyAlpha(this.glowColor, 0));
      this.canvasContext.fillStyle = gradient;
      this.canvasContext.fillRect(0, 0, canvasW, canvasH);
    } else {
      let x0 = 0, y0 = 0, x1 = 0, y1 = 0;
      switch (this.glowDirection) {
        case 'top':
          x0 = canvasW / 2; y0 = 0; x1 = canvasW / 2; y1 = canvasH;
          break;
        case 'bottom':
          x0 = canvasW / 2; y0 = canvasH; x1 = canvasW / 2; y1 = 0;
          break;
        case 'left':
          x0 = 0; y0 = canvasH / 2; x1 = canvasW; y1 = canvasH / 2;
          break;
        case 'right':
          x0 = canvasW; y0 = canvasH / 2; x1 = 0; y1 = canvasH / 2;
          break;
        default:
          x0 = canvasW / 2; y0 = 0; x1 = canvasW / 2; y1 = canvasH;
          break;
      }
      const gradient = this.canvasContext.createLinearGradient(x0, y0, x1, y1);
      gradient.addColorStop(0, this.applyAlpha(this.glowColor, opacity));
      gradient.addColorStop(1, this.applyAlpha(this.glowColor, 0));
      this.canvasContext.fillStyle = gradient;
      this.canvasContext.fillRect(0, 0, canvasW, canvasH);
    }
  }

  /**
   * 按 opacity 重新合成 alpha，返回 **9 位 '#AARRGGBB'**（Canvas 唯一认的格式）。
   *
   * ★ 2026-10-18 修掉一个让辉光整体消失的 bug：调用处一直用 `主题色 + '20'` 这种拼法
   *   （如 ACCENT '#FF69B1F8' + '20' = 11 位 '#FF69B1F820'），而本方法原先只认 9 位，
   *   11 位串被原样 return 给 Canvas.addColorStop ⇒ 颜色解析失败 ⇒ **辉光根本画不出来**
   *   （症状曾被误判成"沉浸光感没了"）。现在两种长度都支持：末两位才是目标 alpha。
   */
  private applyAlpha(color: string, opacity: number): string {
    if (!color.startsWith('#')) {
      return color;
    }
    let alphaHex: string = 'FF';
    let rgbHex: string = '';
    if (color.length === 9) {
      // '#AARRGGBB' —— 常规主题色，alpha 取前两位。
      alphaHex = color.substring(1, 3);
      rgbHex = color.substring(3, 9);
    } else if (color.length === 11) {
      // '#AARRGGBBAA' —— 调用处的 `主题色 + '20'` 拼法，**末两位**才是想要的 alpha。
      alphaHex = color.substring(9, 11);
      rgbHex = color.substring(3, 9);
    } else {
      return color;
    }
    const baseAlpha: number = parseInt(alphaHex, 16) / 255;
    const newAlpha: number = Math.round(baseAlpha * opacity * 255);
    const hexAlpha: string = newAlpha.toString(16).padStart(2, '0');
    return '#' + hexAlpha + rgbHex;
  }
}