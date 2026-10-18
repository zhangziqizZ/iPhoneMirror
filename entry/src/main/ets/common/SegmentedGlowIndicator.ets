import {
  GLOW_ENABLED_KEY,
  GLOW_STRENGTH_KEY,
  GLOW_DEGRADED_KEY,
} from './WindowServices';
import { ACCENT } from './Theme';
import { THEME_SCHEME_KEY } from './theme_manager';

interface IndicatorGlowParams {
  glowRadius: number;
  glowOpacity: number;
  trailRadius: number;
  trailOpacity: number;
  glowColor: string;
}

function indicator_glow_params(strength: number): IndicatorGlowParams {
  const table: IndicatorGlowParams[] = [
    { glowRadius: 4, glowOpacity: 0.10, trailRadius: 6, trailOpacity: 0.05, glowColor: ACCENT + '1A' },
    { glowRadius: 8, glowOpacity: 0.20, trailRadius: 10, trailOpacity: 0.10, glowColor: ACCENT + '33' },
    { glowRadius: 12, glowOpacity: 0.30, trailRadius: 14, trailOpacity: 0.15, glowColor: ACCENT + '4D' },
  ];
  if (strength < 0 || strength > 2 || Number.isNaN(strength)) {
    return table[1];
  }
  return table[strength];
}

@Component
export struct SegmentedGlowIndicator {
  @Prop @Watch('onTabIndexChange') currentIndex: number = 0;
  @Prop tabCount: number = 3;
  @Prop @Watch('onContainerWidthChange') containerWidth: number = 0;

  @StorageLink(GLOW_ENABLED_KEY) glowEnabled: boolean = true;
  @StorageLink(GLOW_STRENGTH_KEY) glowStrength: number = 1;
  @StorageLink(GLOW_DEGRADED_KEY) glowDegraded: boolean = false;
  @StorageLink(THEME_SCHEME_KEY) scheme: string = 'dark';

  @State indicatorOffsetX: number = 0;
  @State trailOffsetX: number = 0;
  @State trailOpacity: number = 0;
  @State indicatorReady: boolean = false;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private indicatorContext: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private trailContext: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  private tabWidth(): number {
    if (this.containerWidth <= 0 || this.tabCount <= 0) {
      return 0;
    }
    return this.containerWidth / this.tabCount;
  }

  onContainerWidthChange(): void {
    if (this.containerWidth > 0 && !this.indicatorReady) {
      this.indicatorOffsetX = this.currentIndex * this.tabWidth();
      this.trailOffsetX = this.indicatorOffsetX;
      this.indicatorReady = true;
    }
  }

  onTabIndexChange(): void {
    if (!this.indicatorReady || this.containerWidth <= 0) {
      return;
    }
    if (this.glowDegraded || !this.glowEnabled) {
      this.indicatorOffsetX = this.currentIndex * this.tabWidth();
      this.trailOffsetX = this.indicatorOffsetX;
      this.trailOpacity = 0;
      return;
    }
    const targetX: number = this.currentIndex * this.tabWidth();
    animateTo({ duration: 250, curve: Curve.EaseInOut }, (): void => {
      this.indicatorOffsetX = targetX;
    });
    animateTo({ duration: 350, curve: Curve.EaseOut }, (): void => {
      this.trailOffsetX = targetX;
    });
    const params: IndicatorGlowParams = indicator_glow_params(this.glowStrength);
    animateTo({ duration: 200, curve: Curve.EaseInOut }, (): void => {
      this.trailOpacity = params.trailOpacity;
    });
    setTimeout((): void => {
      animateTo({ duration: 300, curve: Curve.EaseInOut }, (): void => {
        this.trailOpacity = 0;
      });
    }, 200);
  }

  private drawIndicator(): void {
    const w: number = this.indicatorContext.width;
    const h: number = this.indicatorContext.height;
    if (w <= 0 || h <= 0) return;
    const params: IndicatorGlowParams = indicator_glow_params(this.glowStrength);
    const cx: number = w / 2;
    const cy: number = h / 2;
    const r: number = Math.max(params.glowRadius, Math.min(cx, cy));
    const gradient: CanvasGradient = this.indicatorContext.createRadialGradient(cx, cy, 0, cx, cy, r);
    gradient.addColorStop(0, params.glowColor);
    gradient.addColorStop(1, 'rgba(0,0,0,0)');
    this.indicatorContext.fillStyle = gradient;
    this.indicatorContext.fillRect(0, 0, w, h);
  }

  private drawTrail(): void {
    const w: number = this.trailContext.width;
    const h: number = this.trailContext.height;
    if (w <= 0 || h <= 0) return;
    const params: IndicatorGlowParams = indicator_glow_params(this.glowStrength);
    const cx: number = w / 2;
    const cy: number = h / 2;
    const r: number = Math.max(params.trailRadius, Math.min(cx, cy));
    const gradient: CanvasGradient = this.trailContext.createRadialGradient(cx, cy, 0, cx, cy, r);
    gradient.addColorStop(0, params.glowColor);
    gradient.addColorStop(1, 'rgba(0,0,0,0)');
    this.trailContext.fillStyle = gradient;
    this.trailContext.fillRect(0, 0, w, h);
  }

  build() {
    Stack() {
      if (this.glowEnabled && !this.glowDegraded && this.trailOpacity > 0) {
        Canvas(this.trailContext)
          .width(this.tabWidth())
          .height(40)
          .position({ x: this.trailOffsetX, y: 0 })
          .opacity(this.trailOpacity)
          .onReady((): void => {
            this.drawTrail();
          })
      }

      if (this.glowEnabled && !this.glowDegraded) {
        Canvas(this.indicatorContext)
          .width(this.tabWidth())
          .height(40)
          .position({ x: this.indicatorOffsetX, y: 0 })
          .onReady((): void => {
            this.drawIndicator();
          })
      }
    }
    .width('100%')
    .height(40)
  }
}