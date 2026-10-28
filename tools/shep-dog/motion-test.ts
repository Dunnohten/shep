// Checks the dog's motion engine (state machine, frame policy, blinks, springs, Reduce Motion) without a browser.
// Usage: BLOUB_DIR=/path/to/bloub tools/shep-dog/run-tests.sh   (jiti from bloub's node_modules runs the TypeScript)
import * as M from './src/motion.ts'
import * as P from './src/poses.ts'

// What PoseBridge.json (ShepCore/Sources/DogPose.swift) sends for these poses; the Swift tests pin the same numbers.
const pose = (name: string, ears: [number, number][], extra: any, tr: any) => ({ name, ears: ears.map(([angle, lift]) => ({ angle, lift })), eyeScale: 1, eyeX: 0, eyeY: 0, tilt: 0, tiltDelay: 0, ...extra, transition: { stiffness: 150, damping: 12, earDelay: [0, 0], springs: true, ...tr } })
const LISTENING = pose('listening', [[52, 4], [52, 4]], { eyeScale: 1.12, tilt: 7, tiltDelay: 0.35 }, { stiffness: 190, damping: 9.5, earDelay: [0, 0.05] })
const THINKING = pose('thinking', [[-8, -2], [20, 1.5]], { eyeX: 0.6, eyeY: -0.85, tilt: -4, tiltDelay: 0.2 }, { stiffness: 120, damping: 11, earDelay: [0, 0.12] })
const ASLEEP = pose('asleep', [[-12, -2], [-12, -2]], { eyeScale: 0.95, eyeY: 0.3 }, { stiffness: 90, damping: 14, earDelay: [0, 0.08] })
const WAKING = pose('waking', [[22, 2.5], [22, 2.5]], { eyeScale: 1.1 }, { stiffness: 200, damping: 9, twitch: { ear: 0, kick: 24, seconds: 0.18, popDelay: 0.24 } })
const STATIC = (p: any) => ({ ...p, tiltDelay: 0, transition: { stiffness: 0, damping: 0, earDelay: [0, 0], springs: false } })

let failed = 0
const ok = (c: unknown, m: string) => { if (!c) { failed++; console.log('FAIL', m) } else console.log('ok', m) }
const near = (a: number, b: number, e: number) => Math.abs(a - b) <= e

// state machine (mirrors DogMotionMachineTests)
{
  const m = new M.MotionMachine()
  ok(m.state === 'idle', 'starts idle')
  m.send('listen', 0); ok(m.state === 'listening', 'listen')
  m.send('think', 1); ok(m.state === 'thinking', 'think')
  m.send('speak', 2); ok(m.state === 'speaking', 'speak')
  m.send('rest', 3); ok(m.state === 'idle', 'rest')
  m.send('think', 0); m.send('dock', 10000)
  ok(m.state === 'docking' && near(m.endsAt, 10900, 0.1), 'dock lasts 0.9 s')
  m.tick(10500); ok(m.state === 'docking', 'still docking at 0.5 s')
  m.tick(11000); ok(m.state === 'thinking', 'docking ends at the resting state')
  m.send('dock', 0); m.send('listen', 200); ok(m.state === 'docking', 'listen deferred while docking')
  m.tick(1000); ok(m.state === 'listening', 'deferred state applies')
  m.send('dragBegan', 0); m.send('think', 1); ok(m.state === 'dragging', 'dragging preempts')
  m.send('dragEnded', 2000); ok(m.state === 'docking' && near(m.endsAt, 2800, 0.1), 'snap-back is a 0.8 s docking')
  m.tick(3000); ok(m.state === 'thinking', 'then the resting state')
  const h = new M.MotionMachine()
  h.send('hide', 0); h.send('listen', 1); h.send('dock', 1); h.send('dragBegan', 1)
  ok(h.state === 'hidden', 'hidden ignores everything but show')
  h.send('show', 2000); ok(h.state === 'docking', 'show rises again')
  h.tick(3000); ok(h.state === 'listening', 'request made while hidden is remembered')
  const r = new M.MotionMachine(); r.reduceMotion = true
  r.send('dock', 0); ok(near(r.endsAt, 350, 0.1) && !r.isSpringing, 'reduce motion: 0.35 s fade, no spring')
  r.tick(400); r.send('dragBegan', 500); r.send('dragEnded', 600); ok(r.state === 'idle', 'reduce motion: drag ends at rest')
}

// frame policy (mirrors FramePolicyTests)
{
  const f = M.framesPerSecond
  ok(f('idle', false, true) === 30 && f('thinking', false, true) === 30, '30 fps idle')
  ok(f('docking', false, true) === 60 && f('dragging', false, true) === 60, '60 fps while a spring runs')
  const states = ['idle', 'docking', 'listening', 'thinking', 'speaking', 'dragging', 'hidden']
  ok(states.every((s) => f(s, false, false) === 0 && f(s, true, false) === 0), 'paused when inactive')
  ok(f('hidden', false, true) === 0, 'paused when hidden')
  ok(f('idle', true, true) === 15 && f('dragging', true, true) === 15 && f('docking', true, true) < 60, 'reduce motion is calm')
}

// names
ok(M.eventForName('talking') === 'speak' && M.eventForName('look-left') === 'rest' && M.eventForName('nope') === null, 'state names map to events')

// blinks: 2-6 s apart, some doubles
{
  let seed = 7
  const rng = () => { seed = (seed * 16807) % 2147483647; return seed / 2147483647 }
  const b = new M.Blinker(0, rng)
  const starts = []
  let prev = 0, doubles = 0
  for (let t = 0; t < 600000; t += 16) {
    const v = b.at(t)
    if (v > 0.02 && prev <= 0.02) starts.push(t)
    prev = v
  }
  const groups = []
  for (const s of starts) { if (groups.length && s - groups[groups.length - 1].last < 400) { groups[groups.length - 1].last = s; doubles++ } else groups.push({ first: s, last: s }) }
  const gaps = groups.slice(1).map((g, i) => g.first - groups[i].last)
  ok(groups.length > 80, `blinks happen (${groups.length} in 10 min)`)
  ok(Math.min(...gaps) >= 1900 && Math.max(...gaps) <= 6500, `gaps between 2 and 6 s (min ${Math.min(...gaps)}, max ${Math.max(...gaps)})`)
  ok(doubles > 0 && doubles < groups.length / 2, `some double blinks (${doubles})`)
}

// springs and the pose
{
  const e = new M.Engine(0, () => 0.3)
  let maxSy = 0, minSy = 9, maxLean = 0
  for (let t = 0; t < 12000; t += 33) { const p = e.step(t); maxSy = Math.max(maxSy, p.sy); minSy = Math.min(minSy, p.sy); maxLean = Math.max(maxLean, Math.abs(p.lean)) }
  ok(maxSy - minSy > 0.03, `idle squish is continuous (sy ${minSy.toFixed(3)}..${maxSy.toFixed(3)})`)
  ok(maxLean > 0.8 && maxLean < 4, `slight lean (max ${maxLean.toFixed(2)} deg)`)
  // anti-phase: wide when short
  const samples = []
  for (let t = 12000; t < 15000; t += 33) samples.push(e.step(t))
  const hi = samples.reduce((a, b) => (b.sy > a.sy ? b : a)), lo = samples.reduce((a, b) => (b.sy < a.sy ? b : a))
  ok(hi.sx < lo.sx, 'scale x and y are in anti-phase')

  const d = new M.Engine(0, () => 0.3)
  for (let t = 0; t <= 100; t += 16) d.step(t)
  d.send('dock', 100)
  let over = 0, op0 = d.step(108).opacity
  for (let t = 110; t < 1200; t += 16) over = Math.max(over, d.step(t).ty * -1)
  ok(op0 < 0.5, 'docking starts nearly hidden in the tab')
  ok(over > 0.3, `rise overshoots above its rest (${over.toFixed(2)} px)`)
  const settled = d.step(2000)
  ok(settled.opacity === 1 && near(settled.sx, 1, 0.05) && d.machine.state === 'idle', 'rise settles and the dog is idle again')

  const l = new M.Engine(0, () => 0.3); l.step(0)
  l.send('listen', 10); l.setPose(P.parsePose(LISTENING)!, 10)
  let p; for (let t = 10; t < 1500; t += 16) p = l.step(t)
  ok(p.ears[0] > 35 && p.ears[1] < -35, `listening perks the ears (${p.ears.map((v) => v.toFixed(0))})`)
  ok(p.lean > 3, `listening tilts the head (${p.lean.toFixed(1)} deg)`)
  ok(p.eyeScale > 1.05 && p.eyeScale < 1.2, `listening widens the eyes slightly (${p.eyeScale.toFixed(2)})`)
  ok(p.earLift[0] > 2 && p.earLift[1] > 2, 'listening lifts both ears')
  const th = new M.Engine(0, () => 0.3); th.step(0); th.send('think', 10); th.setPose(P.parsePose(THINKING)!, 10)
  let q; for (let t = 10; t < 2000; t += 16) q = th.step(t)
  ok(q.gazeY < -0.5 && q.dots.some((v) => v > 0.3), 'thinking looks up and shows the dots')
  ok(q.ears[0] < -3 && q.ears[0] >= -20 && q.ears[1] < -12, `thinking: one ear tucked (still visible), the other cocked up (${q.ears.map((v) => v.toFixed(0))})`)
  ok(q.gazeX > 0.1, `thinking: the eyes look to the side too (${q.gazeX.toFixed(2)})`)

  // drag: rubber band, then snap back with overshoot
  const g = new M.Engine(0, () => 0.3); g.step(0)
  for (let t = 0; t < 600; t += 16) { g.dragTo(200, -200, t); g.step(t) }
  const pulled = g.step(616)
  ok(g.machine.state === 'dragging' && Math.abs(pulled.tx) <= M.DRAG_LIMIT && pulled.sy > 1.05, `drag stretches, rubber-banded (sy ${pulled.sy.toFixed(2)}, tx ${pulled.tx.toFixed(1)})`)
  g.dragEnd(640)
  ok(g.machine.state === 'docking', 'release starts the snap-back')
  let swing = 0
  for (let t = 640; t < 1600; t += 16) swing = Math.max(swing, g.step(t).ty)
  ok(swing > 0.5, `snap-back overshoots past rest (${swing.toFixed(2)} px)`)
  const done = g.step(3000)
  ok(near(done.tx, 0, 0.3) && near(done.skew, 0, 0.5) && g.machine.state === 'idle', 'snap-back settles at rest')

  // reduce motion: no wobble, no springs
  const c = new M.Engine(0, () => 0.3); c.setReduceMotion(true, 0)
  let wob = 0
  for (let t = 0; t < 8000; t += 66) { const z = c.step(t); wob = Math.max(wob, Math.abs(z.sx - 1), Math.abs(z.sy - 1), Math.abs(z.lean), Math.abs(z.ty)) }
  ok(wob === 0, 'reduce motion: no wobble')
  for (let t = 8000; t <= 8100; t += 16) c.step(t)
  c.send('dock', 8100)
  const f0 = c.step(8116).opacity
  let f1 = f0
  for (let t = 8132; t <= 8250; t += 16) f1 = c.step(t).opacity
  let f2 = f1
  for (let t = 8266; t <= 8600; t += 16) f2 = c.step(t).opacity
  ok(f0 < f1 && f1 < f2 && f2 === 1, `reduce motion: dock is a fade (${f0.toFixed(2)} ${f1.toFixed(2)} ${f2.toFixed(2)})`)
  c.dragTo(100, 100, 9000); const dz = c.step(9016)
  ok(dz.tx === 0 && dz.sy === 1, 'reduce motion: no drag stretch')
}
// poses: overshoot, order, Reduce Motion
{
  const drive = (e: M.Engine, from: number, to: number, f: (t: number, p: M.Pose) => void) => { for (let t = from; t <= to; t += 16) f(t, e.step(t)) }

  // springy goop overshoot without Reduce Motion
  const e = new M.Engine(0, () => 0.3); e.step(0)
  e.setPose(P.parsePose(LISTENING)!, 16)
  let maxEar = 0
  drive(e, 16, 2500, (_t, p) => { maxEar = Math.max(maxEar, p.ears[0]) })
  const settled = e.step(2516)
  ok(maxEar > 52 * 1.1, `ears overshoot their target (peak ${maxEar.toFixed(1)} vs 52)`)
  ok(near(settled.ears[0], 52, 2.5) && near(settled.ears[1], -52, 2.5), 'and settle on it')

  // the tilt comes after the ears
  const o = new M.Engine(0, () => 0.3); o.step(0)
  o.setPose(P.parsePose(LISTENING)!, 16)
  let early: M.Pose | undefined
  drive(o, 16, 216, (_t, p) => { early = p })
  ok(early!.ears[0] > 20 && Math.abs(early!.lean) < 1.5, `at 0.2 s the ears are moving and the head has not tilted (${early!.ears[0].toFixed(0)} / ${early!.lean.toFixed(2)})`)

  // none with Reduce Motion: static, exactly the target at the first frame, never beyond it
  const r = new M.Engine(0, () => 0.3); r.setReduceMotion(true, 0); r.step(0)
  r.setPose(P.parsePose(LISTENING)!, 16)
  const first = r.step(32)
  let rMax = 0
  drive(r, 32, 2500, (_t, p) => { rMax = Math.max(rMax, p.ears[0]) })
  ok(first.ears[0] === 52 && first.ears[1] === -52 && first.lean === 7 && first.eyeScale === 1.12, 'reduce motion: the pose is applied at once')
  ok(rMax === 52, 'reduce motion: no overshoot')
  r.setPose(P.parsePose(WAKING)!, 3000)
  const rw = r.step(3016)
  ok(rw.ears[0] === 22 && rw.ears[1] === -22, 'reduce motion: wake pops both ears at once, no twitch')

  // a static transition from Swift snaps even when the page itself is not in Reduce Motion
  const sn = new M.Engine(0, () => 0.3); sn.step(0)
  sn.setPose(P.parsePose(STATIC(LISTENING))!, 16)
  ok(near(sn.step(32).ears[0], 52, 1.5), 'springs:false snaps')

  // Reduce Motion switched on mid-transition finishes at once
  const mid = new M.Engine(0, () => 0.3); mid.step(0)
  mid.setPose(P.parsePose(LISTENING)!, 16); mid.step(60)
  mid.setReduceMotion(true, 70)
  const done = mid.step(86)
  ok(done.ears[0] === 52 && done.lean === 7, 'reduce motion on mid-flight lands on the pose')

  // asleep ears droop flat
  const a = new M.Engine(0, () => 0.3); a.step(0)
  a.setPose(P.parsePose(ASLEEP)!, 16)
  let pa: M.Pose = a.pose
  drive(a, 16, 3000, (_t, p) => { pa = p })
  ok(near(pa.ears[0], -12, 3) && near(pa.ears[1], 12, 3), `asleep: ears hang low but stay visible (${pa.ears.map((v) => v.toFixed(0))})`)

  // wake: one ear twitches first, then both pop
  const w = new M.Engine(0, () => 0.3); w.step(0)
  w.setPose(P.parsePose(ASLEEP)!, 16)
  drive(w, 16, 3000, () => {})
  const base = w.pose.ears.slice() as number[]
  const t0 = 3100
  w.setPose(P.parsePose(WAKING)!, t0)
  let tTwitch = -1, tRight = -1, tLeftPop = -1, peak = [-99, 99]
  let leftMax = -99
  drive(w, t0, t0 + 2500, (t, p) => {
    if (tTwitch < 0 && Math.abs(p.ears[0] - base[0]) > 5) tTwitch = t - t0
    if (tRight < 0 && Math.abs(p.ears[1] - base[1]) > 5) tRight = t - t0
    leftMax = Math.max(leftMax, p.ears[0]); peak = [Math.max(peak[0], p.ears[0]), Math.min(peak[1], p.ears[1])]
    if (tLeftPop < 0 && p.ears[0] > 15 && t - t0 > 200) tLeftPop = t - t0
  })
  ok(tTwitch >= 0 && tTwitch < 120, `wake: the twitching ear moves first (after ${tTwitch} ms)`)
  ok(tRight >= 230 && tRight > tTwitch + 100, `wake: the other ear waits for the pop (moves at ${tRight} ms, twitch at ${tTwitch})`)
  ok(tLeftPop >= 0 && tLeftPop >= 230, `wake: the twitching ear pops up with the other, after the pop delay (${tLeftPop} ms)`)
  const wEnd = w.step(t0 + 2516)
  ok(near(wEnd.ears[0], 22, 2.5) && near(wEnd.ears[1], -22, 2.5), 'wake: both ears end up popped')
  ok(peak[0] > 22 * 1.1, `wake: the pop overshoots (${peak[0].toFixed(1)})`)
}

// the finish hop
{
  const h = new M.Engine(0, () => 0.3); h.step(0)
  const rest = h.step(100).ty
  h.hop(200, 9, 420)
  let peak = 0, after = 0
  for (let t = 216; t <= 700; t += 16) { const ty = h.step(t).ty; peak = Math.max(peak, rest - ty); if (t > 640) after = ty }
  ok(peak > 7 && peak < 10.5, `the hop lifts the dog about 9 px (${peak.toFixed(1)})`)
  ok(Math.abs(after - rest) < 1.5, 'and sets it down again')
  const c = new M.Engine(0, () => 0.3); c.setReduceMotion(true, 0); c.step(0)
  c.hop(100, 9, 420)
  let cp = 0
  for (let t = 116; t <= 600; t += 16) cp = Math.max(cp, Math.abs(c.step(t).ty))
  ok(cp === 0, 'reduce motion: no hop')
  const bad = new M.Engine(0, () => 0.3); bad.step(0); bad.hop(10, NaN, 100); bad.hop(10, 5, -1)
  ok(Math.abs(bad.step(60).ty) < 1, 'a hop with junk numbers is ignored')
}

// parsing: nothing from the bridge is trusted
{
  ok(P.parsePose('not json') === null && P.parsePose(null) === null && P.parsePose({ ears: [] }) === null, 'junk is not a pose')
  const wild = P.parsePose({ ears: [{ angle: 900, lift: -50 }, { angle: 'x' }], eyeScale: 9, tilt: 99, transition: { stiffness: -5, damping: 1e9, earDelay: [99, 'q'], springs: 'yes', twitch: { ear: 7, kick: 500, seconds: 0, popDelay: 0 } } })!
  ok(wild.ears[0].angle === 90 && wild.ears[0].lift === -10 && wild.ears[1].angle === 0, 'angles and lifts are clamped')
  ok(wild.eyeScale === 1.5 && wild.tilt === 20, 'eye scale and tilt are clamped')
  ok(wild.transition.stiffness === 20 && wild.transition.damping === 80 && wild.transition.earDelay[0] === 2 && wild.transition.earDelay[1] === 0, 'spring and delays are clamped')
  ok(wild.transition.twitch!.ear === 0 && wild.transition.twitch!.kick === 60 && wild.transition.twitch!.popDelay >= 0.05, 'twitch is clamped')
  ok(P.parsePose(JSON.stringify(LISTENING))!.ears[0].angle === 52, 'a JSON string parses')
}

console.log(failed ? `${failed} FAILED` : 'all ok')
process.exit(failed ? 1 : 0)
