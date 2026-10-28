/*
 * Contraste WCAG 2.x : luminance relative sRGB et rapport (L1 + 0.05) / (L2 + 0.05).
 * Sert a juger chaque couleur du chien contre les deux barres de titre, claire et sombre.
 * Les chiffres sortent du calcul tels quels : rien n'est arrondi vers le haut.
 */

export const TITLE_LIGHT = '#ECECEC'
export const TITLE_DARK = '#2B2B2B'
// seuil des elements graphiques (WCAG 1.4.11)
export const MIN_RATIO = 3
// seuil du texte courant (WCAG 1.4.3, AA)
export const MIN_TEXT_RATIO = 4.5

export function parseHex(hex: string): [number, number, number] {
  const m = /^#?([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(hex.trim())
  if (!m) throw new Error(`hex invalide : ${hex}`)
  const h = m[1]!.length === 3 ? [...m[1]!].map((c) => c + c).join('') : m[1]!
  return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16)) as [number, number, number]
}

export function toHex(rgb: number[]): string {
  return '#' + rgb.map((v) => Math.round(Math.max(0, Math.min(255, v))).toString(16).padStart(2, '0')).join('').toUpperCase()
}

// composante sRGB 0..255 vers lineaire, seuil 0.04045 (sRGB) ; WCAG 2.x ecrit 0.03928, sans effet sur 8 bits
const linear = (c: number) => {
  const s = c / 255
  return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4
}

export function luminance(hex: string): number {
  const [r, g, b] = parseHex(hex).map(linear) as [number, number, number]
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

export function contrastRatio(a: string, b: string): number {
  const la = luminance(a)
  const lb = luminance(b)
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
}

/*
 * Bande de luminance qui tient 3:1 contre les deux barres a la fois : au-dessus du
 * plancher impose par la barre sombre, sous le plafond impose par la claire. Etroite.
 */
export function passBand(light = TITLE_LIGHT, dark = TITLE_DARK, min = MIN_RATIO) {
  return { lo: min * (luminance(dark) + 0.05) - 0.05, hi: (luminance(light) + 0.05) / min - 0.05 }
}

export interface ContrastCheck {
  hex: string
  luminance: number
  light: number
  dark: number
  pass: boolean
}

export function checkContrast(hex: string, light = TITLE_LIGHT, dark = TITLE_DARK, min = MIN_RATIO): ContrastCheck {
  const l = contrastRatio(hex, light)
  const d = contrastRatio(hex, dark)
  return { hex: hex.toUpperCase(), luminance: luminance(hex), light: l, dark: d, pass: l >= min && d >= min }
}
