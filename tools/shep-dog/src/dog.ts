/*
 * Chien "goop" : un avatar minuscule et plat, une seule couleur vive, perche sur le bord
 * d'une fenetre. Dessine a la main, en coordonnees de tete (origine au centre de la tete,
 * une unite ~ un pixel a la taille "normale" de 40 px de large).
 *
 * Tout sort en chaines SVG, sans DOM : le meme code sert a la page `goop-dog.html`, aux
 * captures et aux tests.
 */

import { TITLE_LIGHT } from './contrast.ts'
import { OUTLINE, bubbleScheme, outlineScheme } from './outline.ts'

export interface Palette {
  name: string
  body: string
  eye: string
  ink: string
}

// couleur signature : mandarine, une seule couleur et rien d'autre
export const SIGNATURE: Palette = {
  name: 'Tangerine',
  body: '#FF7A1A',
  eye: '#FFFFFF',
  ink: '#1A1A22'
}

export const ALTERNATES: Palette[] = [
  { name: 'Cobalt', body: '#3D6BFF', eye: '#FFFFFF', ink: '#14142B' },
  { name: 'Bubblegum', body: '#FF4F9A', eye: '#FFFFFF', ink: '#2A1020' },
  { name: 'Grape', body: '#8B5CF6', eye: '#FFFFFF', ink: '#1C1233' }
]

// les quatre d'origine, celles de la planche
export const CORE: Palette[] = [SIGNATURE, ...ALTERNATES]

/*
 * Huit de plus. Sur les corps trop clairs pour des yeux blancs (lime, creme, tournesol),
 * les yeux prennent l'encre ; sur le charbon c'est l'encre qui passe au blanc (nez, texte).
 */
export const EXTENDED: Palette[] = [
  { name: 'Beagle Tan', body: '#D99A4E', eye: '#FFFFFF', ink: '#2A1A0C' },
  { name: 'Coral', body: '#FF5A4E', eye: '#FFFFFF', ink: '#2A1010' },
  { name: 'Teal', body: '#0E9AA7', eye: '#FFFFFF', ink: '#0B2226' },
  { name: 'Lime', body: '#8BD617', eye: '#1F2A0A', ink: '#1F2A0A' },
  { name: 'Sky', body: '#38B6FF', eye: '#FFFFFF', ink: '#0E2233' },
  { name: 'Cream', body: '#FFF1D6', eye: '#2A2218', ink: '#2A2218' },
  { name: 'Charcoal', body: '#46464E', eye: '#FFFFFF', ink: '#FFFFFF' },
  { name: 'Sunflower', body: '#FFC81A', eye: '#2A2008', ink: '#2A2008' }
]

export const PALETTES: Palette[] = [...CORE, ...EXTENDED]

// demi-largeur et demi-hauteur de la tete, rayon des coins
export const HEAD = { hw: 17, hh: 15, r: 12.5 }

export function clampGaze(g: number): number {
  if (!Number.isFinite(g)) return 0
  return Math.max(-1, Math.min(1, g))
}

/*
 * Oreille tombante, cote droit (s = 1), en coordonnees de tete : un rabat attache sur le
 * coin du crane qui pend le long de la joue jusque sous le bas des yeux, bout arrondi.
 * Dessinee derriere la tete, son bord interieur est enfoui dedans : seul le rabat qui
 * depasse se voit, et il ne peut jamais mordre sur un oeil.
 */
export const EAR = {
  top: -15.8,
  tip: 9.7,
  outer: 22.6,
  // commandes et points de la courbe, a symetriser pour le cote gauche
  path: [
    ['M', 9, -13.5],
    ['C', 12.5, -17, 18.5, -16.4, 20.6, -12.2],
    ['C', 22.8, -7.5, 22.9, 2, 22.2, 6.8],
    ['C', 21.6, 10.4, 17, 10.6, 16, 7.4],
    ['C', 14.6, 3, 13.4, -6, 12, -9],
    ['C', 11, -11.5, 10, -12.8, 9, -13.5]
  ] as [string, ...number[]][]
}

export function earPath(side: number, dx = 0): string {
  return (
    EAR.path
      .map(([cmd, ...n]) => cmd + n.map((v, i) => (i % 2 === 0 ? f(side * v + dx) : f(v))).join(' '))
      .join(' ') + ' Z'
  )
}

// l'oreille d'une couleur un peu plus sombre que le corps, sinon elle se fond dans la tete
export function earShade(hex: string, k = 0.74): string {
  const n = parseInt(hex.slice(1), 16)
  return (
    '#' +
    [16, 8, 0]
      .map((sh) => Math.round(((n >> sh) & 255) * k).toString(16).padStart(2, '0'))
      .join('')
      .toUpperCase()
  )
}

/*
 * Ce que le regard deplace : les yeux glissent le plus (~0.18 de la largeur de tete), le
 * nez un peu moins (~0.15), les oreilles repartent un rien dans l'autre sens (parallaxe),
 * assez pour que la tete "tourne" meme en petit.
 */
export function dogGeometry(gaze = 0) {
  const g = clampGaze(gaze)
  const eyeW = 4.6
  const eyeH = 10
  const eyeGap = 5.6
  const eyeY = -2.5
  const look = g * 6
  return {
    gaze: g,
    eyes: [-1, 1].map((s) => ({
      x: s * eyeGap + look - eyeW / 2,
      y: eyeY - eyeH / 2,
      w: eyeW,
      h: eyeH
    })),
    nose: { cx: g * 5, cy: 6.4, r: 2.2 },
    // bornes de chaque oreille (x interieur et exterieur, haut, bout) et son trace
    ears: [-1, 1].map((s) => {
      const dx = -g * 1.2
      return {
        side: s,
        dx,
        outer: s * EAR.outer + dx,
        top: EAR.top,
        tip: EAR.tip,
        d: earPath(s, dx)
      }
    }),
    eyeBottom: eyeY + eyeH / 2
  }
}

export interface HeadOptions {
  gaze?: number
  palette?: Palette
  x?: number
  y?: number
  scale?: number
  // couleur de la surface derriere le chien (la barre) ; elle choisit le contour. null : sans contour
  bar?: string | null
  /*
   * SVG peint entre la bande exterieure du contour et les pieces, en coordonnees de la
   * scene (hors de l'echelle de la tete) : la tige de la bulle. Elle passe ainsi par-dessus
   * la bande exterieure de la tete et sous sa bande interieure, et sort de la tete sans
   * qu'un trait la coupe.
   */
  behind?: string
  // Shep: mark the ears, eyes, nose and thinking dots with data-rig attributes so the page can move them without re-rendering
  rig?: boolean
}

export const f = (n: number) => +n.toFixed(2)

/*
 * La tete seule, en <g>, centree sur (x, y). Ordre de peinture, du fond vers le dessus :
 *   1. la bande exterieure du contour, sous toutes les pieces (oreilles et tete) ;
 *   2. `behind` (la tige de la bulle), hors echelle ;
 *   3. les oreilles, leur bande interieure peinte sous le remplissage (paint-order) ;
 *   4. la tete, sa bande interieure par-dessus l'attache des oreilles.
 * Les traits sont en px d'ecran (non mis a l'echelle) : 2 px quelle que soit la taille.
 */
export function dogHead(o: HeadOptions = {}): string {
  const p = o.palette ?? SIGNATURE
  const s = o.scale ?? 1
  const geo = dogGeometry(o.gaze ?? 0)
  const { hw, hh, r } = HEAD
  const ear = earShade(p.body)
  const ol = o.bar === null ? null : outlineScheme(p.body, ear, o.bar ?? TITLE_LIGHT)
  const ns = 'vector-effect="non-scaling-stroke" stroke-linejoin="round"'
  const ring = (c: string) => (ol ? ` stroke="${c}" stroke-width="${OUTLINE.inner * 2}" paint-order="stroke" ${ns}` : '')
  const outer = ol ? ` fill="none" stroke="${ol.outer}" stroke-width="${(OUTLINE.inner + OUTLINE.outer) * 2}" ${ns}` : ''
  // vector-effect ne s'herite pas : chaque forme porte ses propres attributs de trait
  const headRect = (attrs: string) => `<rect x="${-hw}" y="${-hh}" width="${hw * 2}" height="${hh * 2}" rx="${r}"${attrs}/>`
  const rig = !!o.rig
  const ears = (attrs: string) =>
    geo.ears.map((e) => (rig ? `<g data-rig="ear" data-side="${e.side}"><path d="${e.d}"${attrs}/></g>` : `<path d="${e.d}"${attrs}/>`)).join('')
  const eyes = geo.eyes
    .map((e, i) => `<rect${rig ? ` data-rig="eye" data-i="${i}"` : ''} x="${f(e.x)}" y="${f(e.y)}" width="${e.w}" height="${e.h}" rx="${e.w / 2}"/>`)
    .join('')
  // thinking dots (rig only): body colour with the outer outline tone, above the right ear, drawn last, hidden until used
  const dotRing = ol ? ` stroke="${ol.outer}" stroke-width="1" vector-effect="non-scaling-stroke"` : ''
  const dots = rig
    ? `<g data-rig="dots">` + [0, 1, 2].map((i) => `<circle data-rig="dot" data-i="${i}" cx="${8 + i * 5.2}" cy="-23" r="1.7" fill="${p.body}"${dotRing} opacity="0"/>`).join('') + `</g>`
    : ''
  const at = `transform="translate(${f(o.x ?? 0)} ${f(o.y ?? 0)}) scale(${s})"`
  return (
    `<g class="goop-dog">` +
    (ol ? `<g ${at}>${ears(outer)}${headRect(outer)}</g>` : '') +
    (o.behind ?? '') +
    `<g ${at}>` +
    ears(` fill="${ear}"${ring(ol?.ear ?? '')}`) +
    headRect(` fill="${p.body}"${ring(ol?.head ?? '')}`) +
    `<g fill="${p.eye}">${eyes}</g>` +
    `<circle${rig ? ' data-rig="nose"' : ''} cx="${f(geo.nose.cx)}" cy="${geo.nose.cy}" r="${geo.nose.r}" fill="${p.ink}"/>` +
    `</g>${dots ? `<g ${at}>${dots}</g>` : ''}</g>`
  )
}

// boite englobante du chien (oreilles et contour compris, regard extreme inclus), en unites de tete
export const HEAD_BOX = { x: -27, y: -19, w: 54, h: 38 }

export function goopDogSvg(o: HeadOptions & { size?: number } = {}): string {
  const size = o.size ?? 52
  const b = HEAD_BOX
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${f((size * b.h) / b.w)}" ` +
    `viewBox="${b.x} ${b.y} ${b.w} ${b.h}" role="img" aria-label="dog">` +
    dogHead({ ...o, x: 0, y: 0, scale: 1 }) +
    `</svg>`
  )
}

/*
 * La bosse qui pousse du bord de la fenetre : le bord passe a plat, monte en S doux,
 * file a plat en haut, redescend en S. Tangentes horizontales a chaque raccord, donc pas
 * d'angle nulle part. `y` est le bord haut du cadre, la bosse monte au-dessus.
 *
 * Le segment suppose la plume deja posee au pied gauche (`bumpFoot`), pour s'inserer
 * dans le contour d'une fenetre.
 */
export interface Bump {
  cx: number
  y: number
  halfTop: number
  height: number
  shoulder: number
}

export const bumpFoot = (b: Bump) => ({ l: b.cx - b.halfTop - b.shoulder, r: b.cx + b.halfTop + b.shoulder })

export function bumpSegment(b: Bump): string {
  const { l: l0, r: r0 } = bumpFoot(b)
  const l1 = b.cx - b.halfTop
  const r1 = b.cx + b.halfTop
  const top = b.y - b.height
  const k = b.shoulder * 0.55
  return [
    `C${f(l0 + k)} ${f(b.y)} ${f(l1 - k)} ${f(top)} ${f(l1)} ${f(top)}`,
    `L${f(r1)} ${f(top)}`,
    `C${f(r1 + k)} ${f(top)} ${f(r0 - k)} ${f(b.y)} ${f(r0)} ${f(b.y)}`
  ].join(' ')
}

// la bosse seule, fermee sur le bord
export function bumpPath(b: Bump): string {
  return `M${f(bumpFoot(b).l)} ${f(b.y)} ${bumpSegment(b)} Z`
}

/*
 * Tige + bulle : la tige descend du bas de la tete et s'evase dans la bulle (deux conges
 * concaves), la bulle est une pilule de la meme couleur. Contour de 2 px a deux tons comme
 * le chien, choisi par `bubbleScheme` selon les surfaces que touchent la tige et la bulle.
 * Les deux formes n'en font qu'une : toutes les bandes exterieures, puis toutes les
 * interieures, puis les remplissages, si bien que la jonction tige | bulle n'a pas de trait.
 * Traits en px d'ecran, sans non-scaling-stroke : la bulle n'est jamais mise a l'echelle.
 */
export function stemAndBubble(o: {
  stemX: number
  stemTop: number
  bubbleX: number
  bubbleY: number
  bubbleW: number
  bubbleH: number
  palette?: Palette
  // surfaces reellement touchees par le contour ; [] : sans contour
  surfaces?: string[]
}): string {
  const p = o.palette ?? SIGNATURE
  const w = 3.2
  const fl = 5
  const x0 = o.stemX - w / 2
  const x1 = o.stemX + w / 2
  const yb = o.bubbleY + 0.5
  const stem = [
    `M${f(x0)} ${f(o.stemTop)}`,
    `L${f(x0)} ${f(yb - fl)}`,
    `Q${f(x0)} ${f(yb)} ${f(x0 - fl)} ${f(yb)}`,
    `L${f(x1 + fl)} ${f(yb)}`,
    `Q${f(x1)} ${f(yb)} ${f(x1)} ${f(yb - fl)}`,
    `L${f(x1)} ${f(o.stemTop)}`,
    'Z'
  ].join(' ')
  const shapes = (attrs: string) =>
    `<path d="${stem}"${attrs}/>` +
    `<rect x="${f(o.bubbleX)}" y="${f(o.bubbleY)}" width="${f(o.bubbleW)}" height="${f(o.bubbleH)}" rx="${f(o.bubbleH / 2)}"${attrs}/>`
  const surfaces = o.surfaces ?? []
  if (!surfaces.length) return shapes(` fill="${p.body}"`)
  const ol = bubbleScheme(p.body, surfaces)
  const band = (c: string, wd: number) => shapes(` fill="none" stroke="${c}" stroke-width="${wd}" stroke-linejoin="round"`)
  return (
    `<g class="goop-bubble">` +
    band(ol.outer, (OUTLINE.inner + OUTLINE.outer) * 2) +
    band(ol.inner, OUTLINE.inner * 2) +
    shapes(` fill="${p.body}"`) +
    `</g>`
  )
}

export function escapeXml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' })[c] as string)
}
