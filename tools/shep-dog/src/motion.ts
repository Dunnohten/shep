/*
 * Shep motion (written for Shep, not part of bloub): the state machine, the frame policy and the soft-body physics for
 * the goop dog. Pure: no DOM, no clock; the page passes `now` in milliseconds. The state machine mirrors
 * ShepCore/Sources/DogMotion.swift rule for rule (same names, same durations); tests on both sides keep them in step.
 */

import { Spring } from './spring.ts'
import { PoseDriver, type PoseSpec } from './poses.ts'

export type MotionState = 'idle' | 'docking' | 'listening' | 'thinking' | 'speaking' | 'dragging' | 'hidden'
export type MotionEvent = 'dock' | 'rest' | 'listen' | 'think' | 'speak' | 'dragBegan' | 'dragEnded' | 'hide' | 'show'

export const DOCK_SECONDS = 0.9
export const REDUCED_DOCK_SECONDS = 0.35
export const SNAP_BACK_SECONDS = 0.8
export const IDLE_FPS = 30
export const SPRING_FPS = 60
export const CALM_FPS = 15

export class MotionMachine {
  state: MotionState = 'idle'
  resting: MotionState = 'idle'
  reduceMotion = false
  endsAt: number | null = null
  /** Set when the last transition started a rise out of the tab (not a snap-back), so the engine can fire its spring. */
  riseStarted = false

  get isSpringing(): boolean {
    return !this.reduceMotion && (this.state === 'docking' || this.state === 'dragging')
  }

  private get dockLength(): number {
    return this.reduceMotion ? REDUCED_DOCK_SECONDS : DOCK_SECONDS
  }

  send(event: MotionEvent, now: number): void {
    this.riseStarted = false
    switch (event) {
      case 'hide':
        this.state = 'hidden'
        this.endsAt = null
        break
      case 'show':
        if (this.state === 'hidden') this.beginDocking(now, this.dockLength, true)
        break
      case 'dock':
        if (this.state !== 'hidden') this.beginDocking(now, this.dockLength, true)
        break
      case 'rest':
      case 'listen':
      case 'think':
      case 'speak': {
        const target: MotionState = event === 'listen' ? 'listening' : event === 'think' ? 'thinking' : event === 'speak' ? 'speaking' : 'idle'
        this.resting = target
        if (this.state !== 'hidden' && this.state !== 'docking' && this.state !== 'dragging') {
          this.state = target
          this.endsAt = null
        }
        break
      }
      case 'dragBegan':
        if (this.state !== 'hidden' && this.state !== 'dragging') {
          this.state = 'dragging'
          this.endsAt = null
        }
        break
      case 'dragEnded':
        if (this.state === 'dragging') {
          if (this.reduceMotion) {
            this.state = this.resting
            this.endsAt = null
          } else {
            this.beginDocking(now, SNAP_BACK_SECONDS, false)
          }
        }
        break
    }
  }

  tick(now: number): void {
    if (this.state === 'docking' && this.endsAt !== null && now >= this.endsAt) {
      this.state = this.resting
      this.endsAt = null
    }
  }

  private beginDocking(now: number, seconds: number, rise: boolean): void {
    this.state = 'docking'
    this.endsAt = now + seconds * 1000
    this.riseStarted = rise
  }
}

/** Frames per second the loop should run at; 0 means paused (no frame is scheduled at all). */
export function framesPerSecond(state: MotionState, reduceMotion: boolean, active: boolean): number {
  if (!active || state === 'hidden') return 0
  if (reduceMotion) return state === 'docking' ? IDLE_FPS : CALM_FPS
  return state === 'docking' || state === 'dragging' ? SPRING_FPS : IDLE_FPS
}

/** Old and new names accepted by shep.setState, mapped to machine events (plus the look-left / sleeping extras). */
export function eventForName(name: string): MotionEvent | null {
  switch (name) {
    case 'idle': case 'look-left': case 'look-right': case 'sleeping': case 'rest': return 'rest'
    case 'listening': return 'listen'
    case 'thinking': return 'think'
    case 'talking': case 'speaking': return 'speak'
    case 'docking': return 'dock'
    case 'dragging': return 'dragBegan'
    case 'hidden': return 'hide'
    case 'visible': return 'show'
    default: return null
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// physics

export { Spring } from './spring.ts'

/** Random blinks every 2-6 s, one in four a double blink. `rng` is injectable for tests. */
export class Blinker {
  private nextAt: number
  private phases: number[] = []   // start times (ms) of the blinks in the current group
  static readonly LENGTH = 150    // ms per blink
  static readonly DOUBLE_GAP = 220

  constructor(now: number, private rng: () => number = Math.random) {
    this.nextAt = now + this.interval()
  }

  private interval(): number {
    return 2000 + this.rng() * 4000
  }

  /** 0 (open) ... 1 (closed) at time `now` (ms). Call with non-decreasing times. */
  at(now: number): number {
    if (this.phases.length === 0 && now >= this.nextAt) {
      this.phases = [now]
      if (this.rng() < 0.25) this.phases.push(now + Blinker.DOUBLE_GAP)
      this.nextAt = now + (this.phases.length > 1 ? Blinker.DOUBLE_GAP + Blinker.LENGTH : Blinker.LENGTH) + this.interval()
    }
    let v = 0
    for (const s of this.phases) {
      const p = (now - s) / Blinker.LENGTH
      if (p >= 0 && p <= 1) v = Math.max(v, Math.sin(p * Math.PI))
    }
    if (this.phases.length > 0 && now > this.phases[this.phases.length - 1] + Blinker.LENGTH) this.phases = []
    return v
  }

  /** Forces a blink now (the demo script). */
  blinkNow(now: number): void {
    this.phases = [now]
  }
}

export function rubberBand(v: number, limit: number): number {
  return limit * Math.tanh(v / limit)
}

export interface Pose {
  /** CSS transform parts for #dog (origin at its base). */
  sx: number
  sy: number
  lean: number     // degrees
  skew: number     // degrees (drag stretch)
  tx: number
  ty: number
  opacity: number
  /** Ear swing in degrees about each ear's attach point, [left, right]. Positive = clockwise on screen. */
  ears: [number, number]
  /** Ear lift in head units (positive = up), from the pose. */
  earLift: [number, number]
  gazeX: number    // -1..1
  gazeY: number    // -1 (up) ... 1
  eyeScale: number // 1 = normal
  blink: number    // 0..1
  dots: [number, number, number]   // opacity of the thinking dots
}

export const REST_POSE: Pose = {
  sx: 1, sy: 1, lean: 0, skew: 0, tx: 0, ty: 0, opacity: 1, ears: [0, 0], earLift: [0, 0], gazeX: 0, gazeY: 0, eyeScale: 1, blink: 0, dots: [0, 0, 0]
}

const TAU = Math.PI * 2
const clamp = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, v))
export const DRAG_LIMIT = 22   // px the head can be pulled

export class Engine {
  readonly machine = new MotionMachine()
  private blinker: Blinker
  private last: number | null = null
  private t0: number
  private rise = new Spring(1, 230, 15)      // 0 = hidden in the tab, 1 = risen; overshoots above 1
  private riseT = 1                          // reduce-motion fade progress (0..1)
  private drag = { x: new Spring(0, 420, 30), y: new Spring(0, 420, 30) }
  private dragTarget = { x: 0, y: 0 }
  private squash = new Spring(0, 300, 14)
  private leanSpring = new Spring(0, 90, 9)
  private earL = new Spring(0, 150, 7)
  private earR = new Spring(0, 150, 7)
  private prevLean = 0
  private nextTwitch = 0
  private pointer = { x: 0, y: 0 }
  private gaze = { x: new Spring(0, 140, 18), y: new Spring(0, 140, 18) }
  private manualGaze: number | null = null
  sleepy = false
  private hopStart = 0
  private hopPx = 0
  private hopMs = 0
  /** Ears, eyes and head tilt: Swift sends a pose (ShepCore DogPose) and this animates toward it. */
  readonly poses = new PoseDriver()
  /** Last pose, for tests and the page. */
  pose: Pose = { ...REST_POSE, ears: [0, 0], earLift: [0, 0], dots: [0, 0, 0] }

  constructor(now = 0, private rng: () => number = Math.random) {
    this.t0 = now
    this.blinker = new Blinker(now, rng)
    this.nextTwitch = now + 1500
  }

  get reduceMotion(): boolean { return this.machine.reduceMotion }

  setReduceMotion(on: boolean, now: number): void {
    this.machine.reduceMotion = on
    if (on) { this.drag.x.x = this.drag.y.x = 0; this.drag.x.v = this.drag.y.v = 0; this.poses.freeze() }
    this.machine.tick(now)
  }

  send(event: MotionEvent, now: number): void {
    this.machine.send(event, now)
    if (this.machine.riseStarted) {
      if (this.machine.reduceMotion) this.riseT = 0
      else { this.rise.x = 0; this.rise.v = 0 }
    }
  }

  /** A pose from Swift. Reduce Motion (the engine's own flag) makes the change static whatever the transition says. */
  setPose(spec: PoseSpec, now: number): void {
    this.poses.set(spec, now, this.machine.reduceMotion)
  }

  setPointer(x: number, y: number): void {
    this.pointer = { x: clamp(Number(x) || 0, -1, 1), y: clamp(Number(y) || 0, -1, 1) }
  }

  setGaze(g: number | null): void {
    this.manualGaze = g === null ? null : clamp(g, -1, 1)
  }

  /** Pull the head toward (dx, dy) px from rest (rubber-banded). Starts the drag if it has not started. */
  dragTo(dx: number, dy: number, now: number): void {
    if (this.machine.state !== 'dragging') this.send('dragBegan', now)
    if (this.machine.reduceMotion) return
    this.dragTarget = { x: rubberBand(dx, DRAG_LIMIT), y: rubberBand(dy, DRAG_LIMIT) }
  }

  dragEnd(now: number): void {
    this.dragTarget = { x: 0, y: 0 }
    this.send('dragEnded', now)
  }

  /** A little hop (the finish beat): a parabola of `px` over `ms`. Reduce Motion: no hop at all. */
  hop(now: number, px: number, ms: number): void {
    if (this.machine.reduceMotion) return
    const h = Number(px), d = Number(ms)
    if (!(h > 0) || !(d > 0)) return
    this.hopStart = now; this.hopPx = Math.min(h, 40); this.hopMs = Math.min(d, 2000)
  }

  /** A click: a quick squash that bounces back. */
  pulse(): void {
    this.squash.kick(this.machine.reduceMotion ? 0 : -9)
  }

  blinkNow(now: number): void {
    this.blinker.blinkNow(now)
  }

  /** Advance to `now` (ms) and compute the pose. */
  step(now: number): Pose {
    const dt = this.last === null ? 1 / 30 : clamp((now - this.last) / 1000, 0, 0.1)
    this.last = now
    this.machine.tick(now)
    const m = this.machine
    const t = (now - this.t0) / 1000
    const calm = m.reduceMotion
    const st = m.state
    const p: Pose = { ...REST_POSE, ears: [0, 0], earLift: [0, 0], dots: [0, 0, 0] }
    p.blink = this.blinker.at(now)
    const pv = this.poses.step(now)

    // gaze: the pointer, plus the pose's eye offset (thinking looks up and aside, with a slow drift); manual gaze overrides
    let gx = this.pointer.x + pv.eyeX, gy = this.pointer.y * 0.6 + pv.eyeY
    if (st === 'thinking') gx += Math.sin(t * TAU / 3.6) * 0.25
    if (this.manualGaze !== null) { gx = this.manualGaze; gy = 0 }
    if (this.sleepy) { gx = 0; gy = 0.3; p.blink = Math.max(p.blink, 0.85) }
    if (calm) {
      // Reduce Motion: the eyes jump to where they look; no spring.
      this.gaze.x.x = gx; this.gaze.y.x = gy; this.gaze.x.v = this.gaze.y.v = 0
    } else {
      this.gaze.x.step(dt, gx); this.gaze.y.step(dt, gy)
    }
    p.gazeX = clamp(this.gaze.x.x, -1, 1)
    p.gazeY = clamp(this.gaze.y.x, -1, 1)
    p.eyeScale = pv.eyeScale

    if (calm) {
      // Reduce Motion: no wobble, no springs. Opacity fades and blinks only.
      this.riseT = Math.min(1, this.riseT + dt / REDUCED_DOCK_SECONDS)
      let o = this.riseT
      if (st === 'listening') o *= 0.9 + 0.1 * Math.sin(t * TAU / 3)
      if (st === 'thinking') { p.dots = [0.5 + 0.5 * Math.sin(t * TAU / 3), 0.5 + 0.5 * Math.sin(t * TAU / 3 - 1), 0.5 + 0.5 * Math.sin(t * TAU / 3 - 2)] }
      if (st === 'hidden') o = 0
      p.opacity = this.sleepy ? Math.min(o, 0.65) : o
      p.ears = [pv.earAngle[0], pv.earAngle[1]]   // static pose: no lag, no twitch
      p.earLift = [pv.earLift[0], pv.earLift[1]]
      p.lean = pv.tilt
      this.pose = p
      return p
    }

    // dock rise: the head grows out of the tab with an overshoot
    this.rise.step(dt, 1)
    const r = this.rise.x
    const riseSpeed = Math.abs(this.rise.v)

    // body: breathing in anti-phase (wide when short), a slower wobble, a slight lean
    const speed = this.sleepy ? 1.7 : 1
    let breath = Math.sin(t * TAU / (2.8 * speed))
    const wob = Math.sin(t * TAU / 4.1 + 1)
    let amp = 1
    let sx = 1 + (0.022 * breath + 0.008 * wob) * amp
    let sy = 1 - (0.028 * breath + 0.006 * wob) * amp
    let leanT = 1.6 * Math.sin(t * TAU / 5.3)
    let ty = 0.5 * Math.sin(t * TAU / (2.8 * speed) + 1.2)

    if (st === 'listening') {
      const pulse = Math.sin(t * TAU / 1.2)
      sx *= 1 + 0.025 * pulse; sy *= 1 + 0.03 * pulse
      leanT = 0.8 * Math.sin(t * TAU / 2.4)   // the tilt itself comes from the pose
    } else if (st === 'thinking') {
      ty = 1.3 * Math.sin(t * TAU / 2.4)          // slow bob
      leanT = 1.2 * Math.sin(t * TAU / 3.6)
      if (now >= this.nextTwitch) {                // small ear twitch every 1.5-3.5 s
        ;(this.rng() < 0.5 ? this.earL : this.earR).kick((this.rng() < 0.5 ? -1 : 1) * 320)
        this.nextTwitch = now + 1500 + this.rng() * 2000
      }
      for (let i = 0; i < 3; i++) p.dots[i] = clamp(0.2 + 0.9 * Math.max(0, Math.sin(t * TAU / 1.2 - i * 0.9)), 0, 1)
    } else if (st === 'speaking') {
      const beat = Math.sin(t * TAU / 0.5)
      ty = -Math.abs(beat) * 1.5
      sx *= 1 + 0.02 * beat; sy *= 1 - 0.025 * beat
    }

    this.leanSpring.step(dt, leanT)
    const lean = this.leanSpring.x + pv.tilt
    // The ears lag the body's own sway; the pose tilt has its own timing and must not fling them.
    const leanVel = dt > 0 ? (this.leanSpring.x - this.prevLean) / dt : 0
    this.prevLean = this.leanSpring.x

    // ears lag behind the head: they swing against its rotation, and spring back
    const lag = clamp(-0.3 * leanVel, -22, 22)
    const hop = clamp((this.rise.v) * -0.08, -14, 14)   // ears flap as the head rises
    this.earL.step(dt, lag + hop)
    this.earR.step(dt, lag - hop)

    // drag stretch (anchored at the base): toward the pointer, then a springy snap back
    const dragging = st === 'dragging'
    for (const s of [this.drag.x, this.drag.y]) { s.k = dragging ? 420 : 240; s.c = dragging ? 30 : 9 }
    this.drag.x.step(dt, this.dragTarget.x)
    this.drag.y.step(dt, this.dragTarget.y)
    const dxp = this.drag.x.x, dyp = this.drag.y.x
    sy *= 1 - (dyp / DRAG_LIMIT) * 0.45      // pulled up (dy < 0) = taller, pulled down = flatter
    sx *= 1 + (dyp / DRAG_LIMIT) * 0.22
    this.squash.step(dt, 0)
    sy *= 1 + this.squash.x * 0.03
    sx *= 1 - this.squash.x * 0.02

    // arrival: squash a little as the rise spring moves fast
    sy *= 1 + riseSpeed * 0.0005
    sx *= 1 - riseSpeed * 0.00025
    const grow = 0.55 + 0.45 * r
    p.sx = sx * grow
    p.sy = sy * grow
    p.lean = lean
    p.skew = -dxp * 0.9
    p.tx = dxp * 0.5
    p.ty = ty + (1 - r) * 10 + dyp * 0.5
    if (this.hopMs > 0) {
      const u = (now - this.hopStart) / this.hopMs
      if (u >= 1) this.hopMs = 0
      else if (u > 0) p.ty -= this.hopPx * 4 * u * (1 - u)
    }
    p.opacity = st === 'hidden' ? 0 : clamp(r * 2.5, 0, 1) * (this.sleepy ? 0.65 : 1)
    p.ears = [pv.earAngle[0] + this.earL.x, pv.earAngle[1] + this.earR.x]
    p.earLift = [pv.earLift[0], pv.earLift[1]]
    this.pose = p
    return p
  }
}

/** The travel's deformation at `now`: linear between the two frames around it; null once the travel is over. */
export function travelFrame(frames: number[][], t: number): { along: number; across: number; angle: number; opacity: number } | null {
  if (frames.length === 0) return null
  if (t <= frames[0][0]) return { along: frames[0][1], across: frames[0][2], angle: frames[0][3], opacity: frames[0][4] }
  for (let i = 1; i < frames.length; i++) {
    const a = frames[i - 1], b = frames[i]
    if (t <= b[0]) {
      const k = b[0] > a[0] ? (t - a[0]) / (b[0] - a[0]) : 1
      const lerp = (x: number, y: number) => x + (y - x) * k
      return { along: lerp(a[1], b[1]), across: lerp(a[2], b[2]), angle: lerp(a[3], b[3]), opacity: lerp(a[4], b[4]) }
    }
  }
  return null
}
