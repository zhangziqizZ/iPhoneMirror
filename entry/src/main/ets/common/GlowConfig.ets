import { MUTED_TEXT, WARNING, SUCCESS, ERROR, ACCENT } from './Theme';
import { GLOW_ENABLED_KEY, GLOW_STRENGTH_KEY, GLOW_DEGRADED_KEY } from './WindowServices';

export interface GlowStrengthParams {
  radius: number;
  opacity: number;
  blurRadius: number;
}

export const GLOW_STRENGTH_TABLE: GlowStrengthParams[] = [
  { radius: 8, opacity: 0.15, blurRadius: 4 },
  { radius: 16, opacity: 0.30, blurRadius: 8 },
  { radius: 24, opacity: 0.50, blurRadius: 12 },
];

export function glow_strength_params(strength: number): GlowStrengthParams {
  if (strength < 0 || strength > 2 || Number.isNaN(strength)) {
    return GLOW_STRENGTH_TABLE[1];
  }
  return GLOW_STRENGTH_TABLE[strength];
}

export function status_glow_color(captureState: number, scheme: string): string {
  switch (captureState) {
    case 0:
    case 6:
      return MUTED_TEXT + '30';
    case 1:
      return WARNING + '60';
    case 2:
    case 3:
      return WARNING + '50';
    case 4:
      return SUCCESS + '50';
    case 5:
      return WARNING + '40';
    case 7:
      return ERROR + '60';
    default:
      return MUTED_TEXT + '30';
  }
}

export function status_glow_animation(captureState: number): string {
  switch (captureState) {
    case 1:
      return 'pulse';
    case 7:
      return 'blink';
    default:
      return 'none';
  }
}

export const PULSE_DURATION_MS: number = 2000;
export const PULSE_MIN_OPACITY: number = 0.3;
export const PULSE_MAX_OPACITY: number = 0.6;

export const BLINK_DURATION_MS: number = 1000;
export const BLINK_MIN_OPACITY: number = 0.2;
export const BLINK_MAX_OPACITY: number = 0.7;

export const FOCUS_TRANSITION_MS: number = 200;