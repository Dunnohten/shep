// Checks the doghouse page's pure parts (art, pose, frame policy) and the travel interpolation without a browser.
// Usage: BLOUB_DIR=/path/to/bloub tools/shep-dog/run-tests.sh
import * as H from './src/house.ts'
import * as M from './src/motion.ts'
import { THEMES } from './src/themes.ts'

let failed = 0
const ok = (c: unknown, m: string) => { if (!c) { failed++; console.log('FAIL', m) } else console.log('ok', m) }
const near = (a: number, b: number, e: number) => Math.abs(a - b) <= e

// frame policy (mirrors LifecycleFramePolicyTests)
ok(H.houseFps('asleep', false, true) === 8, 'asleep: 8 fps')
ok(H.houseFps('asleep', false, false) === 0 && H.houseFps('waking', false, false) === 0, 'inactive: nothing scheduled')
ok(H.houseFps('away', false, true) === 0, 'away: nothing scheduled')
ok(H.houseFps('waking', false, true) === 30 && H.houseFps('entering', false, true) === 30, 'waking / entering: 30 fps')
ok(H.houseFps('asleep', true, true) === 0, 'reduce motion asleep: still picture')
ok(H.houseFps('waking', true, true) === 15, 'reduce motion waking: calm rate')

// sleeping pose
{
  const a = H.housePose('asleep', 1, false)   // a quarter of the 4 s breath: fullest
  ok(a.dog.eyeOpen === 0 && a.dog.opacity === 1, 'asleep: eyes shut, dog in the door')
  ok(near(a.dog.sy, 1.035, 1e-9) && near(a.dog.sx, 0.98, 1e-9), 'breathing: taller and narrower on the in-breath (anti-phase)')
  const b = H.housePose('asleep', 3, false)
  ok(b.dog.sy < 1 && b.dog.sx > 1, 'breathing out is the opposite')
  let maxZ = 0, seen = 0
  for (let t = 0; t < 12; t += 0.25) {
    const p = H.housePose('asleep', t, false)
    for (const z of p.zs) { maxZ = Math.max(maxZ, z.opacity); if (z.opacity > 0.05) seen++ }
  }
  ok(maxZ <= 0.9 + 1e-9 && seen > 0, 'a z floats in and out, never fully opaque')
  const z0 = H.zPose(0.1), z1 = H.zPose(0.9)
  ok(z1.y < z0.y && z1.x > z0.x, 'the z rises and drifts right')
  ok(near(H.zPose(1.25).x, H.zPose(0.25).x, 1e-9), 'z phase wraps')
  const r1 = H.housePose('asleep', 0.7, true), r2 = H.housePose('asleep', 9.1, true)
  ok(JSON.stringify(r1) === JSON.stringify(r2), 'reduce motion: the picture does not change with time')
  ok(r1.zs[0].opacity > 0.5 && r1.dog.eyeOpen === 0, 'reduce motion: a still z, eyes shut')
}

// waking and entering
{
  const w0 = H.housePose('waking', 0, false), w1 = H.housePose('waking', 0.3, false), w2 = H.housePose('waking', H.WAKE_SECONDS, false)
  ok(w0.dog.eyeOpen === 0 && w2.dog.eyeOpen === 1, 'waking: the eyes open')
  ok(w1.dog.sy > 1.05 && w1.dog.ty < 0, 'waking: stretches up out of the door mid-way')
  ok(near(w2.dog.sy, 1, 1e-6), 'waking: the stretch settles')
  const rw = H.housePose('waking', 0.3, true)
  ok(rw.dog.opacity < 0.05 && rw.dog.sy === 1, 'reduce motion waking: fades out, no stretch')
  const e0 = H.housePose('entering', 0, false), e1 = H.housePose('entering', H.ENTER_SECONDS, false)
  ok(e0.dog.opacity === 0 && e1.dog.opacity === 1 && e1.dog.eyeOpen === 0, 'entering: appears awake, ends asleep')
  const away = H.housePose('away', 5, false)
  ok(away.dog.opacity === 0 && away.zs.every((z) => z.opacity === 0), 'away: empty house')
}

// art
{
  for (const t of THEMES) {
    const svg = H.houseSvg(t.palette)
    ok(svg.includes(t.palette.body), `${t.id}: the theme colour is used`)
    ok((svg.match(/data-rig="z"/g) ?? []).length === 3 && (svg.match(/data-rig="eye"/g) ?? []).length === 2, `${t.id}: 3 z, 2 eyes`)
    // no tag may repeat an attribute (the HTML parser would silently drop the second)
    const dup = (svg.match(/<[a-zA-Z][^>]*>/g) ?? []).filter((tag) => {
      const names = (tag.match(/\s([a-zA-Z:-]+)=/g) ?? []).map((s) => s.trim())
      return new Set(names).size !== names.length
    })
    ok(dup.length === 0, `${t.id}: no repeated attributes ${dup[0] ?? ''}`)
    ok((svg.match(/<svg/g) ?? []).length === 1 && svg.endsWith('</svg>'), `${t.id}: one svg`)
  }
  ok(H.VIEW.w === 96 && H.VIEW.h === 84 && H.DOOR.cx === 48 && H.DOOR.cy === 60 && H.DOOR.r === 14, 'layout matches ShepCore HomeGeometry')
  ok(H.DOG_SCALE * (2 * 17) <= 2 * H.DOOR.r, 'the head fits the door')
}

// travel interpolation
{
  const frames = [[0, 1, 1, 0, 0], [0.5, 1.5, 0.8, 90, 1], [1, 1, 1, 0, 0]]
  const a = M.travelFrame(frames, 0.25)!
  ok(near(a.along, 1.25, 1e-9) && near(a.across, 0.9, 1e-9) && near(a.angle, 45, 1e-9) && near(a.opacity, 0.5, 1e-9), 'travel: linear between frames')
  ok(M.travelFrame(frames, -1)!.opacity === 0 && M.travelFrame(frames, 5) === null && M.travelFrame([], 0) === null, 'travel: clamps before, ends after')
}

console.log(failed ? `${failed} FAILED` : 'all ok')
process.exit(failed ? 1 : 0)
