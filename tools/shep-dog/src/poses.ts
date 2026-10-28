/*
 * Shep poses (written for Shep, not part of bloub). The page has no pose table of its own: Swift owns it
 * (ShepCore/Sources/DogPose.swift) and sends one pose as JSON through `shep.setPose(json)` / `house.setPose(json)`.
 * This module parses it (nothing from the bridge is trusted) and animates toward it:
 *   - a damped spring per value (ear angle and lift, eye scale, eye offset, head tilt), so the ears overshoot like goop;
 *   - a delay per ear, and a delay before the head tilt ("ears first, then a small tilt");
 *   - the wake twitch: one ear flicks first, and only after `popDelay` do both ears pop up;
 *   - Reduce Motion: every value jumps to the pose, with no spring, no delay and no overshoot.
 * Pure: no DOM, no clock; the caller passes `now` in milliseconds. Angles are degrees, positive = outward and up for both
 * ears (the page mirrors the right one when it draws).
 */
import { Spring } from './motion.ts'

export interface EarTarget { angle: number; lift: number }
export interface TwitchSpec { ear: 0 | 1; kick: number; seconds: number; popDelay: number }
export interface PoseSpec {
  name: string
  ears: [EarTarget, EarTarget]
  eyeScale: number
  eyeX: number
  eyeY: number
  tilt: number
  tiltDelay: number
  transition: { stiffness: number; damping: number; earDelay: [number, number]; springs: boolean; twitch: TwitchSpec | null }
}

export interface PoseValues {
  /** Ear swing in degrees for [left, right], in the page's sign convention (left +, right mirrored) already applied. */
  earAngle: [number, number]
  /** Ear lift in head units, positive = up. */
  earLift: [number, number]
  eyeScale: number
  eyeX: number
  eyeY: number
  tilt: number
}

/** Below this the flap swings behind the head and the ear vanishes (same value as DogPose.minVisibleEarAngle in Swift). */
export const MIN_EAR_ANGLE = -20

const clamp = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, v))
const num = (v: unknown, fallback: number, lo: number, hi: number) => {
  const n = typeof v === 'number' ? v : Number(v)
  return Number.isFinite(n) ? clamp(n, lo, hi) : fallback
}

/** Validates what Swift sent (a JSON string or an object). Returns null when it is not a pose at all. */
export function parsePose(input: unknown): PoseSpec | null {
  let o: any = input
  if (typeof input === 'string') {
    try { o = JSON.parse(input) } catch { return null }
  }
  if (!o || typeof o !== 'object' || !Array.isArray(o.ears) || o.ears.length !== 2) return null
  const ear = (e: any): EarTarget => ({ angle: num(e?.angle, 0, MIN_EAR_ANGLE, 90), lift: num(e?.lift, 0, -10, 10) })
  const t = o.transition && typeof o.transition === 'object' ? o.transition : {}
  const delays = Array.isArray(t.earDelay) ? t.earDelay : [0, 0]
  const tw = t.twitch && typeof t.twitch === 'object'
    ? { ear: (Number(t.twitch.ear) === 1 ? 1 : 0) as 0 | 1, kick: num(t.twitch.kick, 20, 0, 60), seconds: num(t.twitch.seconds, 0.18, 0.05, 1), popDelay: num(t.twitch.popDelay, 0.24, 0.05, 2) }
    : null
  return {
    name: typeof o.name === 'string' ? o.name.slice(0, 20) : '',
    ears: [ear(o.ears[0]), ear(o.ears[1])],
    eyeScale: num(o.eyeScale, 1, 0.5, 1.5),
    eyeX: num(o.eyeX, 0, -1, 1),
    eyeY: num(o.eyeY, 0, -1, 1),
    tilt: num(o.tilt, 0, -20, 20),
    tiltDelay: num(o.tiltDelay, 0, 0, 2),
    transition: {
      stiffness: num(t.stiffness, 150, 20, 600),
      damping: num(t.damping, 12, 1, 80),
      earDelay: [num(delays[0], 0, 0, 2), num(delays[1], 0, 0, 2)],
      springs: t.springs !== false,
      twitch: tw
    }
  }
}

interface Pending { at: number; run: () => void }

export class PoseDriver {
  private earAngle = [new Spring(0, 150, 12), new Spring(0, 150, 12)]
  private earLift = [new Spring(0, 150, 12), new Spring(0, 150, 12)]
  private eyeScaleS = new Spring(1, 150, 12)
  private eyeXS = new Spring(0, 150, 12)
  private eyeYS = new Spring(0, 150, 12)
  private tiltS = new Spring(0, 150, 12)
  private target = { angle: [0, 0], lift: [0, 0], eyeScale: 1, eyeX: 0, eyeY: 0, tilt: 0 }
  private pending: Pending[] = []
  private last: number | null = null
  private snap = false
  /** The pose last asked for (name only), for the debug line and tests. */
  name = 'idle'

  /** Applies `spec` at `now`. With `reduce` (or `springs: false`) the values jump there at once. */
  set(spec: PoseSpec, now: number, reduce: boolean): void {
    this.name = spec.name
    this.pending = []
    const tr = spec.transition
    const instant = reduce || !tr.springs
    this.snap = instant
    const springs = [...this.earAngle, ...this.earLift, this.eyeScaleS, this.eyeXS, this.eyeYS, this.tiltS]
    for (const s of springs) { s.k = tr.stiffness; s.c = tr.damping }
    const ang = [spec.ears[0].angle, -spec.ears[1].angle]   // the right ear is the mirror image
    const lift = [spec.ears[0].lift, spec.ears[1].lift]
    const apply = (side: 0 | 1) => {
      this.target.angle[side] = ang[side]
      this.target.lift[side] = lift[side]
    }
    this.target.eyeScale = spec.eyeScale
    this.target.eyeX = spec.eyeX
    this.target.eyeY = spec.eyeY
    if (instant) {
      apply(0); apply(1)
      this.target.tilt = spec.tilt
      this.jump()
      return
    }
    const later = (delayS: number, run: () => void) => {
      if (delayS <= 0) run(); else this.pending.push({ at: now + delayS * 1000, run })
    }
    const tw = tr.twitch
    if (tw) {
      // The twitching ear flicks up from where it hangs now; both ears hold their old targets until the pop.
      const side = tw.ear
      const base = this.target.angle[side]
      this.target.angle[side] = this.earAngle[side].x + (side === 0 ? tw.kick : -tw.kick)
      this.pending.push({ at: now + tw.seconds * 1000, run: () => { this.target.angle[side] = base } })
      later(tw.popDelay, () => { apply(0); apply(1) })
      later(tw.popDelay + spec.tiltDelay, () => { this.target.tilt = spec.tilt })
    } else {
      later(tr.earDelay[0], () => apply(0))
      later(tr.earDelay[1], () => apply(1))
      later(spec.tiltDelay, () => { this.target.tilt = spec.tilt })
    }
    this.pending.sort((a, b) => a.at - b.at)
  }

  /** Reduce Motion switched on mid-flight: finish at once. */
  freeze(): void {
    for (const p of this.pending) p.run()
    this.pending = []
    this.snap = true
    this.jump()
  }

  private jump(): void {
    for (let i = 0; i < 2; i++) {
      this.earAngle[i].x = this.target.angle[i]; this.earAngle[i].v = 0
      this.earLift[i].x = this.target.lift[i]; this.earLift[i].v = 0
    }
    this.eyeScaleS.x = this.target.eyeScale; this.eyeScaleS.v = 0
    this.eyeXS.x = this.target.eyeX; this.eyeXS.v = 0
    this.eyeYS.x = this.target.eyeY; this.eyeYS.v = 0
    this.tiltS.x = this.target.tilt; this.tiltS.v = 0
  }

  /** Advances to `now` (ms) and returns the values. */
  step(now: number): PoseValues {
    const dt = this.last === null ? 0 : clamp((now - this.last) / 1000, 0, 0.1)
    this.last = now
    while (this.pending.length > 0 && this.pending[0].at <= now) this.pending.shift()!.run()
    if (this.snap) this.jump()
    else {
      for (let i = 0; i < 2; i++) { this.earAngle[i].step(dt, this.target.angle[i]); this.earLift[i].step(dt, this.target.lift[i]) }
      this.eyeScaleS.step(dt, this.target.eyeScale)
      this.eyeXS.step(dt, this.target.eyeX)
      this.eyeYS.step(dt, this.target.eyeY)
      this.tiltS.step(dt, this.target.tilt)
    }
    return this.values()
  }

  values(): PoseValues {
    return {
      earAngle: [this.earAngle[0].x, this.earAngle[1].x],
      earLift: [this.earLift[0].x, this.earLift[1].x],
      eyeScale: this.eyeScaleS.x, eyeX: this.eyeXS.x, eyeY: this.eyeYS.x, tilt: this.tiltS.x
    }
  }

  /** True while a delayed step is waiting or a spring is still moving (the page keeps its frame rate up). */
  get busy(): boolean {
    if (this.snap) return this.pending.length > 0
    if (this.pending.length > 0) return true
    const moving = (s: Spring, target: number) => Math.abs(s.x - target) > 0.05 || Math.abs(s.v) > 0.2
    return this.earAngle.some((s, i) => moving(s, this.target.angle[i])) || this.earLift.some((s, i) => moving(s, this.target.lift[i])) ||
      moving(this.eyeScaleS, this.target.eyeScale) || moving(this.tiltS, this.target.tilt) ||
      moving(this.eyeXS, this.target.eyeX) || moving(this.eyeYS, this.target.eyeY)
  }
}
