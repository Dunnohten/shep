/*
 * Shep's doghouse (written for Shep, not part of bloub): the art and the pose of the sleeping dog. Pure: strings and numbers,
 * no DOM, no clock (the page passes seconds). Same flat goop style as the dog: one vivid colour (the theme's), flat fills,
 * a dark line with a light halo so it reads on any desktop. The dog is the real goop head, scaled down inside the round door.
 * ShepCore/Sources/HomeGeometry.swift knows this layout (panel 96 x 84, door centre (48, 60), radius 14): keep them in step.
 */
import { HEAD, dogGeometry, earShade, f, type Palette } from './dog.ts'
import { OUTLINE } from './outline.ts'

export const VIEW = { w: 96, h: 84 }
export const DOOR = { cx: 48, cy: 60, r: 14 }
export const ROOF = { peakX: 48, peakY: 14, baseY: 40, left: 8, right: 88 }
export const WALL = { x: 16, y: 38, w: 64, h: 42, rx: 6 }
/** Head scale inside the door: the head body (34 x 30 units) must fit inside the door's circle with its ears. */
export const DOG_SCALE = 0.6

export type HouseMode = 'asleep' | 'waking' | 'away' | 'entering'

export const ASLEEP_FPS = 8
export const WAKE_FPS = 30
export const CALM_FPS = 15
export const WAKE_SECONDS = 0.6
export const REDUCED_WAKE_SECONDS = 0.3
export const ENTER_SECONDS = 0.8
export const BREATH_SECONDS = 4
export const Z_SECONDS = 3.2

/** Mirrors LifecycleFramePolicy.houseFramesPerSecond. 0 = no frame is scheduled (a change renders one by itself). */
export function houseFps(mode: HouseMode, reduce: boolean, active: boolean): number {
  if (!active) return 0
  if (mode === 'away') return 0
  if (mode === 'asleep') return reduce ? 0 : ASLEEP_FPS
  return reduce ? CALM_FPS : WAKE_FPS
}

export interface ZPose { x: number; y: number; scale: number; opacity: number }
export interface HousePose {
  /** Dog inside the door: opacity, scale (breathing, stretching), lift in px, eye openness 0 (shut) .. 1. */
  dog: { opacity: number; sx: number; sy: number; ty: number; eyeOpen: number }
  zs: ZPose[]
}

const clamp01 = (v: number) => (Number.isFinite(v) ? Math.min(1, Math.max(0, v)) : 0)
const smooth = (u: number) => { const x = clamp01(u); return x * x * (3 - 2 * x) }

/** Where one "z" is: it rises from beside the roof's peak up and to the right, fading in and out. phase 0..1. */
export function zPose(phase: number): ZPose {
  const p = phase - Math.floor(phase)
  return { x: 60 + 14 * p, y: 34 - 26 * p, scale: 0.55 + 0.45 * p, opacity: 0.9 * Math.sin(Math.PI * p) }
}

/**
 * The pose at `t` seconds. asleep: t is absolute time (breathing and the z's loop). waking / entering: t is seconds since the
 * mode began. away: nothing shows. Reduce Motion: no breathing and no drifting z, a single still z.
 */
export function housePose(mode: HouseMode, t: number, reduce: boolean): HousePose {
  const hidden: ZPose = { x: 60, y: 34, scale: 0.55, opacity: 0 }
  const still = zPose(0.5)
  switch (mode) {
    case 'away':
      return { dog: { opacity: 0, sx: 1, sy: 1, ty: 0, eyeOpen: 0 }, zs: [hidden, hidden, hidden] }
    case 'asleep': {
      if (reduce) return { dog: { opacity: 1, sx: 1, sy: 1, ty: 0, eyeOpen: 0 }, zs: [still, hidden, hidden] }
      const b = Math.sin((2 * Math.PI * t) / BREATH_SECONDS)
      // Breathing squish in anti-phase: taller as it breathes in, a touch narrower.
      return { dog: { opacity: 1, sx: 1 - 0.02 * b, sy: 1 + 0.035 * b, ty: 0, eyeOpen: 0 },
        zs: [zPose(t / Z_SECONDS), zPose(t / Z_SECONDS + 0.5), hidden] }
    }
    case 'waking': {
      const dur = reduce ? REDUCED_WAKE_SECONDS : WAKE_SECONDS
      const u = clamp01(t / dur)
      if (reduce) return { dog: { opacity: 1 - smooth(u), sx: 1, sy: 1, ty: 0, eyeOpen: 1 }, zs: [hidden, hidden, hidden] }
      // Eyes open in the first 40 %, then a stretch up and out of the door (grows, lifts) while the z's fade.
      const open = smooth(u / 0.4)
      const stretch = Math.sin(Math.PI * smooth((u - 0.2) / 0.8))
      const z = { ...still, opacity: still.opacity * (1 - smooth(u / 0.5)) }
      return { dog: { opacity: 1, sx: 1 - 0.06 * stretch, sy: 1 + 0.22 * stretch, ty: -4 * stretch, eyeOpen: open }, zs: [z, hidden, hidden] }
    }
    case 'entering': {
      const dur = reduce ? REDUCED_WAKE_SECONDS : ENTER_SECONDS
      const u = clamp01(t / dur)
      if (reduce) return { dog: { opacity: smooth(u), sx: 1, sy: 1, ty: 0, eyeOpen: 0 }, zs: [still, hidden, hidden] }
      // Appears awake, turns round (a dip), closes its eyes at 55 %, settles; the first z comes back at the end.
      const dip = Math.sin(Math.PI * smooth(u))
      const open = 1 - smooth((u - 0.45) / 0.2)
      const z = { ...still, opacity: still.opacity * smooth((u - 0.7) / 0.3) }
      return { dog: { opacity: smooth(u / 0.25), sx: 1 + 0.05 * dip, sy: 1 - 0.12 * dip, ty: 2 * dip, eyeOpen: open }, zs: [z, hidden, hidden] }
    }
  }
}

/** Bottom of the dog's head inside the door (y in the art): the dog stretches and breathes from here. */
export const DOG_BASE = DOOR.cy + 3 + HEAD.hh * DOG_SCALE

/** The doghouse SVG for a palette. Eyes, dog and z's carry data-rig attributes so the page only changes attributes per frame. */
export function houseSvg(p: Palette): string {
  const haloAttrs = (w: number) => `stroke="${OUTLINE.light}" stroke-width="${w}" stroke-linejoin="round" stroke-linecap="round" fill="none"`
  const halo = haloAttrs(4.5)
  const line = (fill: string) => `fill="${fill}" stroke="${OUTLINE.dark}" stroke-width="2" stroke-linejoin="round" paint-order="stroke"`
  const roof = `M${ROOF.left} ${ROOF.baseY} L${ROOF.peakX} ${ROOF.peakY} L${ROOF.right} ${ROOF.baseY} Z`
  const wall = `<rect x="${WALL.x}" y="${WALL.y}" width="${WALL.w}" height="${WALL.h}" rx="${WALL.rx}"`
  const door = `<circle cx="${DOOR.cx}" cy="${DOOR.cy}" r="${DOOR.r}"`
  const shade = earShade(p.body, 0.6)
  const geo = dogGeometry(0)
  const eyes = geo.eyes.map((e, i) => `<rect data-rig="eye" data-i="${i}" x="${f(e.x)}" y="${f(e.y)}" width="${e.w}" height="${e.h}" rx="${e.w / 2}"/>`).join('')
  // data-rig="ear": the page swings and lifts each ear from the pose (poses.ts); side -1 is the left ear
  const ears = geo.ears.map((e) => `<g data-rig="ear" data-side="${e.side}"><path d="${e.d}" fill="${earShade(p.body)}"/></g>`).join('')
  const head = HEAD
  // z: a small Z stroked in the dark line colour with a halo, drawn at the origin and moved by the page.
  const z = (i: number) => `<g data-rig="z" data-i="${i}" opacity="0"><path d="M0 0 H7 L0 8 H7" ${haloAttrs(4)}/><path d="M0 0 H7 L0 8 H7" fill="none" stroke="${p.ink}" stroke-width="1.8" stroke-linejoin="round" stroke-linecap="round"/></g>`
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${VIEW.w} ${VIEW.h}" width="${VIEW.w}" height="${VIEW.h}" preserveAspectRatio="xMidYMid meet">` +
    `<defs><clipPath id="doorClip"><circle cx="${DOOR.cx}" cy="${DOOR.cy}" r="${DOOR.r}"/></clipPath></defs>` +
    // halo under everything, then walls, door, the dog in the door, the roof on top
    `<g>${wall} ${halo}/><path d="${roof}" ${halo}/></g>` +
    `${wall} ${line('#FFF1D6')}/>` +
    `${door} fill="${shade}" stroke="${OUTLINE.dark}" stroke-width="2"/>` +
    `<g clip-path="url(#doorClip)"><g data-rig="dog">` +
    `<g transform="translate(${DOOR.cx} ${DOOR.cy + 3}) scale(${DOG_SCALE})">` +
    ears +
    `<rect x="${-head.hw}" y="${-head.hh}" width="${head.hw * 2}" height="${head.hh * 2}" rx="${head.r}" fill="${p.body}"/>` +
    `<g fill="${p.eye === '#FFFFFF' ? p.ink : p.eye}">${eyes}</g>` +
    `<circle data-rig="nose" cx="0" cy="${geo.nose.cy}" r="${geo.nose.r}" fill="${p.ink}"/>` +
    `</g></g></g>` +
    `<path d="${roof}" ${line(p.body)}/>` +
    z(0) + z(1) + z(2) +
    `</svg>`
  )
}
