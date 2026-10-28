import { PALETTES, SIGNATURE, type Palette } from './dog.ts'

/*
 * Les douze palettes, toutes selectionnables comme theme : par `?palette=` (identifiant
 * ou nom, casse ignoree) ou par cette liste exportee. La mandarine reste le defaut.
 */

export interface Theme {
  id: string
  name: string
  palette: Palette
}

export const themeId = (name: string) =>
  name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')

export const THEMES: Theme[] = PALETTES.map((p) => ({ id: themeId(p.name), name: p.name, palette: p }))

export const DEFAULT_THEME: Theme = THEMES.find((t) => t.palette === SIGNATURE)!

// inconnu, vide ou absent : le defaut, jamais d'erreur
export function findTheme(q: string | null | undefined): Theme {
  const k = themeId(q ?? '')
  return THEMES.find((t) => t.id === k) ?? DEFAULT_THEME
}
