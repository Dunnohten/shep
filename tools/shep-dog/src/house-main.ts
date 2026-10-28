import { ASLEEP_FPS, DOG_BASE, DOOR, ENTER_SECONDS, REDUCED_WAKE_SECONDS, WAKE_SECONDS, houseFps, housePose, houseSvg, type HouseMode } from './house.ts'
import { dogGeometry } from './dog.ts'
import { findTheme, type Theme } from './themes.ts'
import { PoseDriver, parsePose } from './poses.ts'
import { clampGaze } from './dog.ts'

/*
 * Shep doghouse page (not part of bloub). Transparent single-file page driven from Swift, one loop at a low rate:
 *   house.setTheme('Cobalt')           one of the 12 themes (id or name)
 *   house.setMode('asleep')            asleep | waking | away | entering (see house.ts); each mode renders at once
 *   house.setActive(false)             pause: no frame is scheduled while the panel is hidden, covered or the screen sleeps
 *   house.setPose(json)                ears, eyes and head tilt of the sleeping / waking dog (pose table: ShepCore DogPose; see poses.ts)
 *   house.setReduceMotion(true)        no breathing, no drifting z: a still picture; waking and entering cross-fade
 * Sleeping runs at 8 fps (breathing is slow); waking / entering at 30; away and paused at 0. URL params: ?theme=&mode=&reduce=1
 */

let theme: Theme = findTheme(null)
let mode: HouseMode = 'asleep'
let modeStart = performance.now()
let active = true
let reduce = false
let built = ''
let timer: number | undefined
let frames = 0
const WAKE_FPS_FOR_POSE = 30
const poses = new PoseDriver()
let ears: { el: SVGGElement; side: number }[] = []

const root = document.getElementById('house') as HTMLElement
let dogEl: SVGGElement | null = null
let eyes: SVGRectElement[] = []
let zs: SVGGElement[] = []
const r2 = (n: number) => (Math.round(n * 100) / 100).toString()

function post(msg: unknown) {
  const h = (window as any).webkit?.messageHandlers?.house
  if (h) h.postMessage(msg)
}

function build() {
  const key = theme.id
  if (key === built) return
  built = key
  root.innerHTML = houseSvg(theme.palette)
  dogEl = root.querySelector('[data-rig="dog"]')
  eyes = Array.from(root.querySelectorAll('[data-rig="eye"]')) as SVGRectElement[]
  zs = Array.from(root.querySelectorAll('[data-rig="z"]')) as SVGGElement[]
  ears = Array.from(root.querySelectorAll('[data-rig="ear"]')).map((el) => ({ el: el as SVGGElement, side: Number(el.getAttribute('data-side')) }))
}

function render(now: number) {
  build()
  frames++
  const t = mode === 'asleep' ? now / 1000 : (now - modeStart) / 1000
  const p = housePose(mode, t, reduce)
  const pv = poses.step(now)
  if (dogEl) {
    dogEl.setAttribute('opacity', r2(p.dog.opacity))
    dogEl.setAttribute('transform', 'translate(' + DOOR.cx + ' ' + r2(DOG_BASE + p.dog.ty) + ') rotate(' + r2(pv.tilt) + ') scale(' + r2(p.dog.sx) + ' ' + r2(p.dog.sy) + ') translate(' + -DOOR.cx + ' ' + -DOG_BASE + ')')
  }
  // Ears: swing about their attach points and lift, from the pose.
  for (const e of ears) {
    const i = e.side < 0 ? 0 : 1
    e.el.setAttribute('transform', 'rotate(' + r2(pv.earAngle[i]) + ' ' + e.side * 11 + ' -12) translate(0 ' + r2(-pv.earLift[i]) + ')')
  }
  // Eyes: shut is a thin line (like the dog's blink), open is the full eye; the pose widens them and moves where they look.
  const geo = dogGeometry(clampGaze(pv.eyeX))
  const open = Math.max(0.08, p.dog.eyeOpen)
  eyes.forEach((el, i) => {
    const g = geo.eyes[i]
    if (!g) return
    const w = g.w * pv.eyeScale, h = g.h * pv.eyeScale * open
    const cx = g.x + g.w / 2, cy = g.y + g.h / 2 + pv.eyeY * 2.4
    el.setAttribute('x', r2(cx - w / 2)); el.setAttribute('width', r2(w))
    el.setAttribute('y', r2(cy - h / 2))
    el.setAttribute('height', r2(h))
  })
  zs.forEach((el, i) => {
    const z = p.zs[i]
    if (!z) return
    el.setAttribute('opacity', r2(z.opacity))
    el.setAttribute('transform', `translate(${r2(z.x)} ${r2(z.y)}) scale(${r2(z.scale)})`)
  })
}

function fps(): number {
  const base = houseFps(mode, reduce, active)
  // A pose spring in flight needs smooth frames even while the house otherwise sleeps at 8 fps.
  if (base > 0 && base < WAKE_FPS_FOR_POSE && poses.busy) return WAKE_FPS_FOR_POSE
  return base
}

function loop() {
  timer = undefined
  render(performance.now())
  const f = fps()
  if (f > 0) timer = window.setTimeout(loop, Math.round(1000 / f))
}

function stop() {
  if (timer !== undefined) window.clearTimeout(timer)
  timer = undefined
}

/** Renders one frame now (so a change shows even at 0 fps) and restarts the loop at the mode's rate. */
function kick() {
  stop()
  if (!active) return
  loop()
}

const house = {
  version: 1,
  setTheme(name: string) { theme = findTheme(name); built = ''; kick() },
  setMode(m: string) {
    if (m !== 'asleep' && m !== 'waking' && m !== 'away' && m !== 'entering') return
    mode = m
    modeStart = performance.now()
    kick()
  },
  setActive(on: boolean) {
    active = !!on
    if (active) kick(); else stop()
  },
  /** A pose from Swift as JSON (or an object). Reduce Motion makes the change static. */
  setPose(json: unknown) {
    const spec = parsePose(json)
    if (!spec) return
    poses.set(spec, performance.now(), reduce)
    kick()
  },
  setReduceMotion(on: boolean) { reduce = !!on; if (reduce) poses.freeze(); kick() },
  debug() { return { mode, fps: fps(), active, reduce, frames, running: timer !== undefined, pose: poses.name } },
  /** Test hook: the ear and eye values the next frame would draw. */
  _pose() { return poses.values() },
  /** Test hook: render at `ms` (performance.now() clock) ignoring the loop. */
  _render(ms: number) { render(ms) },
  _constants() { return { asleep: ASLEEP_FPS, wake: WAKE_SECONDS, reducedWake: REDUCED_WAKE_SECONDS, enter: ENTER_SECONDS } },
}
;(window as any).house = house

const q = new URLSearchParams(location.search)
if (q.has('theme')) house.setTheme(q.get('theme') as string)
if (q.get('reduce') === '1') house.setReduceMotion(true)
if (q.has('mode')) house.setMode(q.get('mode') as string)
build()
kick()
window.addEventListener('error', (e) => post({ error: String(e.message) + ' @' + String(e.lineno) }))
post({ ready: true })
