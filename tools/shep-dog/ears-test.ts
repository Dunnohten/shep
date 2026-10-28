// Both ears must show on every pose. Reads the pose table straight from ShepCore/Sources/DogPose.swift, rotates the ear
// outline the way main.ts apply() does (rotate(angle, side*11, -12) after translate(0, -lift); the right ear gets -angle),
// and checks that each flap sticks out of the head rectangle by at least MIN_EXPOSED head units.
// Usage: BLOUB_DIR=/path/to/bloub tools/shep-dog/run-tests.sh
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { EAR, HEAD } from './src/dog.ts'
import * as P from './src/poses.ts'

const here = dirname(fileURLToPath(import.meta.url))
const src = readFileSync(join(here, '../../ShepCore/Sources/DogPose.swift'), 'utf8')
const MIN_EXPOSED = 2.5
const PIVOT = { x: 11, y: -12 }

let failed = 0
const ok = (c: unknown, m: string) => { if (!c) { failed++; console.log('FAIL', m) } else console.log('ok', m) }

// case .name: ... return DogPose(name: name, leftEar: EarPose(angle: A, lift: L), rightEar: EarPose(angle: A, lift: L)
const re = /case \.(\w+):\s*(?:\/\/[^\n]*\n\s*)*return DogPose\(name: name, leftEar: EarPose\(angle: (-?[\d.]+), lift: (-?[\d.]+)\), rightEar: EarPose\(angle: (-?[\d.]+), lift: (-?[\d.]+)\)/g
const table: Record<string, [P.EarTarget, P.EarTarget]> = {}
for (const m of src.matchAll(re)) table[m[1]] = [{ angle: +m[2], lift: +m[3] }, { angle: +m[4], lift: +m[5] }]
ok(Object.keys(table).length === 7, `read 7 poses from DogPose.swift (${Object.keys(table).join(',')})`)

// Points along the ear outline (cubic Béziers from EAR.path, right-hand side).
function outline(): { x: number; y: number }[] {
  const pts: { x: number; y: number }[] = []
  let cur = { x: 0, y: 0 }
  for (const [cmd, ...n] of EAR.path) {
    if (cmd === 'M') { cur = { x: n[0], y: n[1] }; pts.push(cur) } else if (cmd === 'C') {
      const [x1, y1, x2, y2, x3, y3] = n
      for (let i = 1; i <= 20; i++) {
        const t = i / 20, u = 1 - t
        pts.push({
          x: u * u * u * cur.x + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3,
          y: u * u * u * cur.y + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y3
        })
      }
      cur = { x: x3, y: y3 }
    }
  }
  return pts
}

// How far (head units) the ear reaches out past the head's side edge, after the page's transform.
// side -1 = left ear (ears[0], angle as is), side +1 = right ear (ears[1], angle mirrored).
function exposed(side: -1 | 1, angle: number, lift: number): number {
  const a = ((side < 0 ? angle : -angle) * Math.PI) / 180
  const px = side * PIVOT.x, py = PIVOT.y
  let reach = -Infinity
  for (const p of outline()) {
    const x = side * p.x, y = p.y - lift                       // translate(0, -lift) first ...
    const dx = x - px, dy = y - py                              // ... then rotate(a) about the pivot (SVG: clockwise on screen)
    const rx = px + dx * Math.cos(a) - dy * Math.sin(a)
    reach = Math.max(reach, Math.abs(rx) - HEAD.hw)
  }
  return reach
}

for (const [name, ears] of Object.entries(table)) {
  const l = exposed(-1, ears[0].angle, ears[0].lift), r = exposed(1, ears[1].angle, ears[1].lift)
  ok(l >= MIN_EXPOSED && r >= MIN_EXPOSED, `${name}: both ears show outside the head (left ${l.toFixed(1)}, right ${r.toFixed(1)}, need ${MIN_EXPOSED})`)
}

const clamped = P.parsePose({ name: 'x', ears: [{ angle: -90, lift: 0 }, { angle: -90, lift: 0 }] })!
ok(clamped.ears[0].angle === -20 && clamped.ears[1].angle === -20, `parsePose clamps -90 to -20 (${clamped.ears.map((e) => e.angle)})`)
const up = P.parsePose({ name: 'x', ears: [{ angle: 90, lift: 0 }, { angle: 55, lift: 0 }] })!
ok(up.ears[0].angle === 90 && up.ears[1].angle === 55, 'parsePose still allows large upward angles')

if (failed) { console.log(`${failed} FAILED`); process.exit(1) }
