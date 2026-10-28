import { HEAD_BOX, clampGaze, dogGeometry, dogHead, type Palette } from './dog.ts'
import { Engine, eventForName, framesPerSecond, travelFrame, type MotionEvent, type Pose } from './motion.ts'
import { parsePose } from './poses.ts'
import { THEMES, findTheme, type Theme } from './themes.ts'

/*
 * Shep renderer entry (not part of bloub). Transparent single-file page driven from Swift:
 *   shep.setTheme('Cobalt')   one of the 12 themes (id or name), default Tangerine
 *   shep.setState('thinking') idle | look-left | look-right | thinking | listening | talking | speaking | sleeping | docking | dragging | hidden
 *   shep.send('dock')         machine event: dock | rest | listen | think | speak | dragBegan | dragEnded | hide | show
 *   shep.setActive(false)     pause the animation loop (panel hidden / occluded / screen asleep); true resumes it
 *   shep.setPose(json)        ears, eyes and head tilt: the pose table lives in ShepCore (DogPose); Swift sends one pose with its transition
 *                             (see poses.ts). Springs overshoot like goop; with Reduce Motion the change is static.
 *   shep.setReduceMotion(true) calm fallback: no wobble or springs, opacity fades and blinks only
 *   shep.setPointer(x, y)     eye tracking, -1..1 relative to the dog (Swift pushes it; the panel is click-through)
 *   shep.drag(dx, dy) / shep.dragEnd()   stretchy drag in px from rest, then snap-back
 *   shep.hop(px, ms)          a little hop (finish beat); nothing under Reduce Motion
 *   shep.pulse() / shep.blink()   click squash / blink now
 *   shep.say('hello', 3000)   speech card next to the dog (the panel is tall enough for it)
 *   shep.ask('Click Gear?', [{id:'approve',label:'Approve'},{id:'cancel',label:'Cancel'}], 'Shep wants to press Gear in TextEdit')
 *                             approval card: role=dialog, aria-modal, aria-label = the title; focus moves to Cancel (else the first button);
 *                             Escape closes it and posts {cancel:true}; a click posts {choice:id}
 *   shep.openPill()           card with a text field; posts {submit:text} on Enter, {cancel:true} on Escape
 *   shep.showTranscript(text) the pill, read-only, showing what push-to-talk has heard so far (no focus); closeCard() hides it
 *   shep.closeCard()          hide the card
 * The card is silent for assistive technology (no live region): Swift announces replies once through NSAccessibility.
 * A hidden card is `inert` and aria-hidden. The DOM dog button posts {activate:true} on Enter or Space.
 *   shep.setLayout(x,y,w,h,below,anchor?)   where the dog is inside the panel (px, top-left origin) and which side the card is on;
 *                             anchor = y of the card's near edge (below: its top, above: its bottom); default hugs the dog
 *   shep.setGaze(-1..1)       manual gaze, overrides the state's gaze until the next setState
 *   shep.setBar('#ECECF0')    colour of the surface behind the dog (picks the outline); null = no outline
 *   shep.travel(frames, seconds)   goo-stretch travel: frames = [[t, along, across, angleDeg, opacity], ...] (ShepCore TravelPath samples);
 *                             the page rotates/scales the dog along its velocity and fades it, at 60 fps, while the panel moves it
 *                             across the screen. shep.endTravel() cancels. The doghouse hand-off cross-fades through `opacity`.
 * URL params at load: ?theme=&state=&bar=&gaze=
 */

type State = 'idle' | 'look-left' | 'look-right' | 'thinking' | 'listening' | 'talking' | 'speaking' | 'sleeping' | 'docking' | 'dragging' | 'hidden'
const STATES: State[] = ['idle', 'look-left', 'look-right', 'thinking', 'listening', 'talking', 'speaking', 'sleeping', 'docking', 'dragging', 'hidden']

let theme: Theme = findTheme(null)
let bar: string | null = '#ECECF0'
let sayTimer: number | undefined
let built = ''
let active = true
let running = false
let frames = 0
let lastRender = 0
let timer: number | undefined
let raf: number | undefined
let wasPlaced = false
const engine = new Engine(performance.now())
let travel: { frames: number[][]; start: number; seconds: number } | null = null

const dogEl = document.getElementById('dog') as HTMLElement
const cardEl = document.getElementById('card') as HTMLElement
const textEl = document.getElementById('text') as HTMLElement
const buttonsEl = document.getElementById('buttons') as HTMLElement
const pillEl = document.getElementById('pill') as HTMLFormElement
const pillInput = document.getElementById('pillInput') as HTMLInputElement
const ASK_ATTRS = ['role', 'aria-modal', 'aria-label']
const GAP = 4
let askActive = false
let layout: { x: number; y: number; w: number; h: number; below: boolean; anchor: number | null } = { x: 0, y: 0, w: 0, h: 0, below: true, anchor: null }

function post(msg: unknown) {
  const h = (window as any).webkit?.messageHandlers?.shep
  if (h) h.postMessage(msg)
}

function placeDog() {
  if (layout.w <= 0) return
  dogEl.style.left = layout.x + 'px'
  dogEl.style.top = layout.y + 'px'
  dogEl.style.width = layout.w + 'px'
  dogEl.style.height = layout.h + 'px'
  if (!wasPlaced) { wasPlaced = true; engine.send('dock', performance.now()) }   // first placement: the head rises out of the tab
  dogEl.classList.add('placed')
  if (layout.below) {
    cardEl.style.top = (layout.anchor ?? layout.y + layout.h + GAP) + 'px'
    cardEl.style.bottom = 'auto'
  } else {
    cardEl.style.top = 'auto'
    cardEl.style.bottom = window.innerHeight - (layout.anchor ?? layout.y - GAP) + 'px'
  }
}

/** Visible cards are reachable; hidden ones are inert and aria-hidden so neither Tab nor a screen reader finds them. */
function setReachable(on: boolean) {
  if (on) { cardEl.removeAttribute('inert'); cardEl.removeAttribute('aria-hidden') }
  else { cardEl.setAttribute('inert', ''); cardEl.setAttribute('aria-hidden', 'true') }
}

function setAskMode(title: string | null) {
  askActive = title !== null
  if (title === null) { for (const a of ASK_ATTRS) cardEl.removeAttribute(a); textEl.removeAttribute('tabindex'); return }
  cardEl.setAttribute('role', 'dialog')
  cardEl.setAttribute('aria-modal', 'true')
  cardEl.setAttribute('aria-label', title)
  textEl.setAttribute('tabindex', '0')   // long text scrolls: a keyboard user must be able to reach it
}

function showCard() {
  placeDog()
  setReachable(true)
  cardEl.classList.add('on')
  post({ card: 'shown' })
}

function hideCard() {
  window.clearTimeout(sayTimer)
  pillInput.readOnly = false
  cardEl.classList.remove('on', 'pilling')
  pillEl.hidden = true
  setAskMode(null)
  setReachable(false)
  buttonsEl.textContent = ''
  textEl.textContent = ''
  pillInput.blur()
  const focused = document.activeElement as HTMLElement | null
  if (focused && focused !== document.body && cardEl.contains(focused)) focused.blur()
  post({ card: 'hidden' })
}


interface Rig {
  ears: { el: SVGGElement; side: number }[]
  eyes: SVGRectElement[]
  nose: SVGCircleElement | null
  dots: SVGCircleElement[]
}
let rig: Rig = { ears: [], eyes: [], nose: null, dots: [] }

function build() {
  const key = `${theme.id}|${bar}`
  if (key === built) return
  built = key
  const p: Palette = theme.palette
  const b = HEAD_BOX
  dogEl.innerHTML =
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${b.x} ${b.y} ${b.w} ${b.h}" preserveAspectRatio="xMidYMid meet">` +
    dogHead({ gaze: 0, palette: p, bar, rig: true }) +
    `</svg>`
  const q = (sel: string) => Array.from(dogEl.querySelectorAll(sel))
  rig = {
    ears: q('[data-rig="ear"]').map((el) => ({ el: el as SVGGElement, side: Number(el.getAttribute('data-side')) })),
    eyes: q('[data-rig="eye"]') as SVGRectElement[],
    nose: dogEl.querySelector('[data-rig="nose"]') as SVGCircleElement | null,
    dots: q('[data-rig="dot"]') as SVGCircleElement[]
  }
  cardEl.style.background = p.body
  cardEl.style.color = p.ink
}

const r2 = (n: number) => (Math.round(n * 100) / 100).toString()

function endTravel() {
  travel = null
  dogEl.style.transformOrigin = ''
}

function apply(p: Pose, now = performance.now()) {
  build()
  const tv = travel ? travelFrame(travel.frames, (now - travel.start) / 1000) : null
  if (travel && (!tv || (now - travel.start) / 1000 >= travel.seconds)) endTravel()
  if (tv && travel) {
    // Stretched along the velocity, squashed across it: rotate into the direction, scale, rotate back so the head stays upright.
    dogEl.style.transformOrigin = '50% 50%'
    dogEl.style.transform = `rotate(${r2(tv.angle)}deg) scale(${r2(tv.along)}, ${r2(tv.across)}) rotate(${r2(-tv.angle)}deg)`
    dogEl.style.opacity = r2(tv.opacity)
  } else {
    dogEl.style.transform = `translate(${r2(p.tx)}px, ${r2(p.ty)}px) rotate(${r2(p.lean)}deg) skewX(${r2(p.skew)}deg) scale(${r2(p.sx)}, ${r2(p.sy)})`
    dogEl.style.opacity = r2(p.opacity)
  }
  for (const e of rig.ears) {
    const a = e.side < 0 ? p.ears[0] : p.ears[1]
    const lift = e.side < 0 ? p.earLift[0] : p.earLift[1]
    e.el.setAttribute('transform', `rotate(${r2(a)} ${e.side * 11} -12) translate(0 ${r2(-lift)})`)
  }
  const geo = dogGeometry(clampGaze(p.gazeX))
  const open = Math.max(0.08, 1 - 0.92 * p.blink)
  rig.eyes.forEach((el, i) => {
    const g = geo.eyes[i]
    if (!g) return
    const w = g.w * p.eyeScale, h = g.h * p.eyeScale * open
    const cx = g.x + g.w / 2, cy = g.y + g.h / 2 + p.gazeY * 2.4
    el.setAttribute('x', r2(cx - w / 2)); el.setAttribute('y', r2(cy - h / 2))
    el.setAttribute('width', r2(w)); el.setAttribute('height', r2(h)); el.setAttribute('rx', r2(Math.min(w, h) / 2))
  })
  if (rig.nose) { rig.nose.setAttribute('cx', r2(geo.nose.cx)); rig.nose.setAttribute('cy', r2(geo.nose.cy + p.gazeY * 1.2)) }
  rig.dots.forEach((d, i) => d.setAttribute('opacity', r2(p.dots[i] ?? 0)))
}

function currentFps(): number {
  if (travel && active) return engine.reduceMotion ? 15 : 60   // a travel in flight: 60 fps, only for its ~1 s
  return framesPerSecond(engine.machine.state, engine.reduceMotion, active)
}

function tick(now: number) {
  raf = undefined
  lastRender = now
  frames++
  apply(engine.step(now), now)
  schedule()
}

// One loop: 30 fps idle, 60 only while a spring runs (rise, drag, snap-back), 15 in Reduce Motion, none when paused.
function schedule() {
  const fps = currentFps()
  if (fps === 0) { running = false; return }
  running = true
  if (fps >= 60) { raf = requestAnimationFrame(tick); return }
  const wait = Math.max(0, 1000 / fps - (performance.now() - lastRender) - 4)
  timer = window.setTimeout(() => { timer = undefined; raf = requestAnimationFrame(tick) }, wait)
}

function stop() {
  if (timer !== undefined) window.clearTimeout(timer)
  if (raf !== undefined) cancelAnimationFrame(raf)
  timer = raf = undefined
  running = false
}

/** Starts the loop if it is stopped and may run (one frame renders any pending change). */
function kick() {
  if (running || raf !== undefined || timer !== undefined) return
  if (!active) return
  raf = requestAnimationFrame(tick)
  running = true
}

/** A spring may just have begun: leave the 30 fps wait and run the next frame now. */
function speedUp() {
  if (timer !== undefined && currentFps() >= 60) stop()
  kick()
}

function sendEvent(e: MotionEvent) {
  engine.send(e, performance.now())
  speedUp()
}

const shep = {
  version: 1,
  themes: () => THEMES.map((t) => ({ id: t.id, name: t.name, body: t.palette.body })),
  states: () => STATES.slice(),
  setTheme(name: string) { theme = findTheme(name); built = ''; kick() },
  setState(name: string) {
    if (!STATES.includes(name as State)) return
    const e = eventForName(name)
    engine.sleepy = name === 'sleeping'
    engine.setGaze(name === 'look-left' ? -1 : name === 'look-right' ? 1 : null)
    if (e) sendEvent(e)
  },
  send(event: string) { sendEvent(event as MotionEvent) },
  setActive(on: boolean) {
    active = !!on
    if (active) kick(); else stop()
  },
  /** A pose from Swift as JSON (or an object): ears, eyes, head tilt and how to move there. Bad input is ignored. */
  setPose(json: unknown) {
    const spec = parsePose(json)
    if (!spec) return
    engine.setPose(spec, performance.now())
    speedUp()
  },
  setReduceMotion(on: boolean) {
    engine.setReduceMotion(!!on, performance.now())
    document.body.classList.toggle('calm', !!on)
    speedUp()
  },
  setPointer(x: number, y: number) { engine.setPointer(x, y); kick() },
  drag(dx: number, dy: number) { engine.dragTo(Number(dx) || 0, Number(dy) || 0, performance.now()); speedUp() },
  dragEnd() { engine.dragEnd(performance.now()); speedUp() },
  pulse() { engine.pulse(); kick() },
  /** A little hop: `px` up and back down over `ms` (the finish beat). Ignored under Reduce Motion. */
  hop(px: number, ms: number) { engine.hop(performance.now(), Number(px), Number(ms)); speedUp() },
  blink() { engine.blinkNow(performance.now()); kick() },
  /** Loop and machine state, for the dock-time log and tests. */
  debug() {
    return { state: engine.machine.state, fps: currentFps(), active, running, reduce: engine.reduceMotion, frames, poseName: engine.poses.name,
      pose: { sx: +engine.pose.sx.toFixed(3), sy: +engine.pose.sy.toFixed(3), ty: +engine.pose.ty.toFixed(2), opacity: +engine.pose.opacity.toFixed(2) } }
  },
  /** Test hook: advance the engine to `ms` (performance.now() clock) and render, ignoring the frame cap. */
  _step(ms: number) { apply(engine.step(ms), ms); return engine.pose },
  travel(frames: number[][], seconds: number) {
    if (!Array.isArray(frames) || frames.length < 2 || !(Number(seconds) > 0)) return
    travel = { frames, start: performance.now(), seconds: Number(seconds) }
    speedUp()
  },
  endTravel() { endTravel(); kick() },

  /** What the page really did, for the dock-time log: the dog's box and the viewport. */
  metrics() {
    // The layout box, not getBoundingClientRect: the animated transform (lean, scale, rise) must not read as a misplaced dog.
    return { dogX: dogEl.offsetLeft, dogY: dogEl.offsetTop, dogW: dogEl.offsetWidth, dogH: dogEl.offsetHeight,
      viewW: window.innerWidth, viewH: window.innerHeight, placed: dogEl.classList.contains('placed') }
  },
  setGaze(g: number) { engine.setGaze(clampGaze(Number(g))) },
  setBar(hex: string | null) { bar = hex && /^#[0-9a-fA-F]{6}$/.test(hex) ? hex : null; built = ''; kick() },
  setLayout(x: number, y: number, w: number, h: number, below: boolean, anchor?: number) {
    const a = anchor === undefined || anchor === null || !Number.isFinite(Number(anchor)) ? null : Number(anchor)
    layout = { x: Number(x), y: Number(y), w: Number(w), h: Number(h), below: !!below, anchor: a }
    placeDog()
    kick()
  },
  say(text: string, ms = 3000) {
    window.clearTimeout(sayTimer)
    cardEl.classList.remove('pilling')
    pillEl.hidden = true
    setAskMode(null)
    buttonsEl.textContent = ''
    textEl.textContent = text
    showCard()
    sayTimer = window.setTimeout(hideCard, ms)
    post({ say: text })
  },
  ask(text: string, choices: { id: string; label: string }[], title?: string) {
    window.clearTimeout(sayTimer)
    cardEl.classList.remove('pilling')
    pillEl.hidden = true
    textEl.textContent = text
    buttonsEl.textContent = ''
    let first: HTMLButtonElement | null = null
    let cancel: HTMLButtonElement | null = null
    for (const c of choices) {
      const b = document.createElement('button')
      b.type = 'button'
      b.textContent = c.label
      b.setAttribute('aria-label', c.label)
      b.addEventListener('click', () => { post({ choice: c.id }); hideCard() })
      buttonsEl.appendChild(b)
      if (!first) first = b
      if (c.id === 'cancel' && !cancel) cancel = b
    }
    setAskMode((title && title.trim()) || text.split('\n')[0] || 'Shep needs your approval')
    showCard()
    ;(cancel ?? first)?.focus()   // Cancel first: a stray Enter or Space never approves
  },
  showTranscript(text: string) {
    window.clearTimeout(sayTimer)
    buttonsEl.textContent = ''
    textEl.textContent = ''
    pillInput.readOnly = true
    pillInput.value = String(text ?? '')
    setAskMode(null)
    pillEl.hidden = false
    cardEl.classList.add('pilling')
    showCard()
  },
  openPill() {
    window.clearTimeout(sayTimer)
    buttonsEl.textContent = ''
    textEl.textContent = ''
    pillInput.readOnly = false
    pillInput.value = ''
    setAskMode(null)
    pillEl.hidden = false
    cardEl.classList.add('pilling')
    showCard()
    pillInput.focus()
  },
  closeCard() { hideCard() },
}
;(window as any).shep = shep

pillEl.addEventListener('submit', (e) => {
  e.preventDefault()
  const t = pillInput.value.trim()
  hideCard()
  if (t) post({ submit: t })
  else post({ cancel: true })
})
pillInput.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') { e.preventDefault(); hideCard(); post({ cancel: true }) }
})

// Escape closes an approval card (the pill handles its own Escape above); Swift also has a fallback for when the page is not first responder.
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && askActive) { e.preventDefault(); hideCard(); post({ cancel: true }) }
})
// The DOM dog is a button: Enter and Space activate it like a click on the tab.
dogEl.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' || e.key === ' ' || e.key === 'Spacebar') { e.preventDefault(); post({ activate: true }) }
})

const q = new URLSearchParams(location.search)
if (q.has('theme')) shep.setTheme(q.get('theme') as string)
if (q.has('bar')) shep.setBar(q.get('bar') === 'none' ? null : '#' + (q.get('bar') as string).replace('#', ''))
if (q.has('state')) shep.setState(q.get('state') as string)
if (q.has('gaze')) shep.setGaze(Number(q.get('gaze')))
if (q.get('reduce') === '1') shep.setReduceMotion(true)
build()
kick()
window.addEventListener('error', (e) => post({ error: String(e.message) + ' @' + String(e.lineno) }))
post({ ready: true })
