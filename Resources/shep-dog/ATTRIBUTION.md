# Dog art attribution

The dog in `index.html` (and the sleeping head in the doghouse, `house.html`) is the "goop dog" from **bloub** (https://github.com/jeremy-prt/bloub),
branch `dog-goop`, commit `6b59465`, MIT License, Copyright (c) 2026 Jérémy Perret.
The licence text is in `LICENSE-bloub` next to this file.

What is bloub's: the drawing code (`dog.ts`, `outline.ts`, `contrast.ts`, `themes.ts`), the geometry, the 12 palettes
and the two-tone outline logic. Copied into `tools/shep-dog/src/`; `dog.ts` has one small Shep change (the `rig` option, `data-rig` markers so the page can animate ears, eyes, nose and dots); the others are unmodified.

What is Shep's: `main.ts` (the `shep` JS bridge: theme, state, cards, layout, travel), `motion.ts` (the motion engine), `house.ts` and
`house-main.ts` (the doghouse page), and the two page shells `shep-dog.html` and `shep-house.html`, all in `tools/shep-dog/`.

`index.html` is a build output: run `tools/shep-dog/build.sh` to regenerate it.

`house.html` (the doghouse) is Shep's: `tools/shep-dog/src/house.ts` and `house-main.ts` draw the roof, walls, door and "z" and animate the sleeping head, which is bloub's head drawing scaled into the door.

