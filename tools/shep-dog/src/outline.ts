import { MIN_RATIO, MIN_TEXT_RATIO, contrastRatio } from './contrast.ts'

/*
 * Contour du chien (tete, oreilles) : 2 px au total, en deux bandes de 1 px.
 *
 *   - la bande EXTERIEURE touche la barre : son ton est choisi par la luminance de la
 *     barre (encre sombre sur barre claire, blanc sur barre sombre). C'est la frontiere
 *     que juge WCAG 1.4.11, elle passe donc toujours, et largement.
 *   - la bande INTERIEURE touche la couleur de la piece : elle reprend le ton exterieur
 *     si toutes les pieces tiennent 3:1 contre lui (le contour se lit alors comme un seul
 *     trait de 2 px), sinon elle prend le ton oppose.
 *
 * Pourquoi pas un seul trait sombre : sur la barre sombre il ne contraste pas. Pourquoi
 * pas un trait choisi par barre et c'est tout : aucune couleur unique ne tient 3:1 a la
 * fois contre la barre sombre et contre un corps clair comme la mandarine (il faudrait
 * L <= 0.08 et L >= 0.17). D'ou le second ton, pose seulement quand il sert.
 *
 * Les deux tons contrastent entre eux (~18:1), donc chaque paire adjacente est mesuree :
 * barre | exterieur | interieur | piece.
 */

export const OUTLINE = {
  dark: '#141418',
  light: '#FFFFFF',
  // largeurs en px d'ecran (trait non mis a l'echelle)
  outer: 1,
  inner: 1
}

export type Tone = 'dark' | 'light'

const other = (t: Tone): Tone => (t === 'dark' ? 'light' : 'dark')

// le ton qui contraste le plus avec la barre
export function outerTone(bar: string): Tone {
  return contrastRatio(OUTLINE.dark, bar) >= contrastRatio(OUTLINE.light, bar) ? 'dark' : 'light'
}

/*
 * Ton interieur de chaque piece : le ton exterieur s'il convient a toutes, sinon l'oppose
 * s'il convient a toutes, sinon piece par piece le meilleur des deux.
 */
export function innerTones(fills: string[], outer: Tone, min = MIN_RATIO): Tone[] {
  const fits = (t: Tone) => fills.every((c) => contrastRatio(c, OUTLINE[t]) >= min)
  if (fits(outer)) return fills.map(() => outer)
  if (fits(other(outer))) return fills.map(() => other(outer))
  return fills.map((c) => (contrastRatio(c, OUTLINE[outer]) >= contrastRatio(c, OUTLINE[other(outer)]) ? outer : other(outer)))
}

export interface Pair {
  label: string
  a: string
  b: string
  ratio: number
  pass: boolean
}

export interface OutlineScheme {
  bar: string
  outer: string
  head: string
  ear: string
  twoTone: boolean
  // chaque frontiere reellement adjacente, mesuree
  pairs: Pair[]
  pass: boolean
}

const pair = (label: string, a: string, b: string, min: number): Pair => {
  const ratio = contrastRatio(a, b)
  return { label, a: a.toUpperCase(), b: b.toUpperCase(), ratio, pass: ratio >= min }
}

export function outlineScheme(body: string, ear: string, bar: string, min = MIN_RATIO): OutlineScheme {
  const o = outerTone(bar)
  const [h, e] = innerTones([body, ear], o, min) as [Tone, Tone]
  const outer = OUTLINE[o]
  const head = OUTLINE[h]
  const earInner = OUTLINE[e]
  const pairs = [
    pair('outline | bar', outer, bar, min),
    pair('head | outline', body, head, min),
    pair('ear | outline', ear, earInner, min)
  ]
  // la bande interieure ne touche la barre nulle part, mais elle touche l'exterieure
  for (const t of new Set([h, e])) if (t !== o) pairs.push(pair('inner | outer', OUTLINE[t], outer, min))
  return { bar: bar.toUpperCase(), outer, head, ear: earInner, twoTone: h !== o || e !== o, pairs, pass: pairs.every((p) => p.pass) }
}

/*
 * Contour de la bulle et de sa tige : la meme regle a deux bandes, avec une seule couleur
 * de remplissage (le corps). La tige traverse plusieurs surfaces (bosse de la barre, filet
 * sous la barre, contenu de la fenetre) : le ton exterieur est celui qui garde le meilleur
 * pire contraste contre toutes, et chaque surface touchee est mesuree.
 *
 * Le texte de la bulle prend l'encre de la palette si elle tient 4.5:1 contre le corps,
 * sinon le noir ou le blanc, le plus contraste des deux (l'un des deux depasse toujours
 * 4.58:1, quel que soit le fond).
 */
export interface Surface {
  name: string
  hex: string
}

export interface BubbleScheme {
  body: string
  outer: string
  inner: string
  text: string
  twoTone: boolean
  pairs: Pair[]
  pass: boolean
}

export const TEXT_FALLBACK = { dark: '#000000', light: '#FFFFFF' }

export function bubbleText(body: string, ink: string, min = MIN_TEXT_RATIO): string {
  if (contrastRatio(body, ink) >= min) return ink.toUpperCase()
  const { dark, light } = TEXT_FALLBACK
  return contrastRatio(body, dark) >= contrastRatio(body, light) ? dark : light
}

export function bubbleOuterTone(surfaces: string[]): Tone {
  const worst = (t: Tone) => Math.min(...surfaces.map((c) => contrastRatio(OUTLINE[t], c)))
  return worst('dark') >= worst('light') ? 'dark' : 'light'
}

export function bubbleScheme(body: string, surfaces: (string | Surface)[], ink = OUTLINE.dark, min = MIN_RATIO): BubbleScheme {
  const surf = surfaces.map((x) => (typeof x === 'string' ? { name: x.toUpperCase(), hex: x } : x))
  const o = bubbleOuterTone(surf.map((x) => x.hex))
  const [i] = innerTones([body], o, min) as [Tone]
  const outer = OUTLINE[o]
  const inner = OUTLINE[i]
  const text = bubbleText(body, ink)
  const pairs = [
    ...surf.map((x) => pair(`outline | ${x.name}`, outer, x.hex, min)),
    pair('fill | inner', body, inner, min),
    pair('stem | inner', body, inner, min)
  ]
  if (i !== o) pairs.push(pair('inner | outer', inner, outer, min))
  pairs.push(pair('text | fill', text, body, MIN_TEXT_RATIO))
  return { body: body.toUpperCase(), outer, inner, text, twoTone: i !== o, pairs, pass: pairs.every((x) => x.pass) }
}
