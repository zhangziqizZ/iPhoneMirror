import { GLOW_DEGRADED_KEY, GLOW_ENABLED_KEY } from './WindowServices';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'iPhoneMirror';

export class GlowDegradationMonitor {
  private static instance: GlowDegradationMonitor | null = null;

  private consecutiveSlowFrames: number = 0;
  private consecutiveFastFrames: number = 0;
  private monitoring: boolean = false;
  private wasDegraded: boolean = false;
  private static readonly SLOW_FRAME_THRESHOLD_MS: number = 33;
  private static readonly SLOW_FRAME_STREAK_LIMIT: number = 10;
  private static readonly FAST_FRAME_STREAK_LIMIT: number = 10;

  static shared(): GlowDegradationMonitor {
    if (GlowDegradationMonitor.instance === null) {
      GlowDegradationMonitor.instance = new GlowDegradationMonitor();
    }
    return GlowDegradationMonitor.instance;
  }

  start(): void {
    this.monitoring = true;
    this.consecutiveSlowFrames = 0;
    this.consecutiveFastFrames = 0;
  }

  stop(): void {
    this.monitoring = false;
    this.consecutiveSlowFrames = 0;
    this.consecutiveFastFrames = 0;
    this.wasDegraded = false;
    AppStorage.setOrCreate(GLOW_DEGRADED_KEY, false);
  }

  checkFrameTime(frameDurationMs: number): void {
    if (!this.monitoring) return;

    if (frameDurationMs > GlowDegradationMonitor.SLOW_FRAME_THRESHOLD_MS) {
      this.consecutiveSlowFrames++;
      this.consecutiveFastFrames = 0;
      if (this.consecutiveSlowFrames >= GlowDegradationMonitor.SLOW_FRAME_STREAK_LIMIT) {
        AppStorage.setOrCreate(GLOW_DEGRADED_KEY, true);
        if (!this.wasDegraded) {
          this.wasDegraded = true;
          hilog.warn(0x0000, TAG, '光感已降级：GPU 负载过高，关闭辉光动画');
        }
      }
    } else {
      this.consecutiveFastFrames++;
      this.consecutiveSlowFrames = 0;
      if (this.consecutiveFastFrames >= GlowDegradationMonitor.FAST_FRAME_STREAK_LIMIT) {
        AppStorage.setOrCreate(GLOW_DEGRADED_KEY, false);
        if (this.wasDegraded) {
          this.wasDegraded = false;
          hilog.info(0x0000, TAG, '光感恢复正常');
        }
      }
    }
  }

  isDegraded(): boolean {
    return AppStorage.get<boolean>(GLOW_DEGRADED_KEY) ?? false;
  }
}