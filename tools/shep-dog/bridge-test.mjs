// Checks the shep JS bridge (say / ask / openPill / setLayout) in happy-dom. Usage: BLOUB_DIR=/path/to/bloub node tools/shep-dog/bridge-test.mjs
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
// BLOUB_DIR defaults to bloub-dog next to this repo (../bloub-dog from the repo root). Missing: exits 2.
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const blouB = process.env.BLOUB_DIR || path.resolve(root, '../bloub-dog')
if (!fs.existsSync(blouB)) {
  console.error(`bridge-test: bloub checkout not found at ${blouB}; set BLOUB_DIR to the bloub-dog checkout (with its node_modules).`)
  process.exit(2)
}
const { Window } = await import(pathToFileURL(path.join(blouB, 'node_modules/happy-dom/lib/index.js')).href)
const html = fs.readFileSync(path.join(root, 'Resources/shep-dog/index.html'), 'utf8')
const w = new Window({ url: 'file:///x/index.html', width: 320, height: 182 })
const posts = []
w.webkit = { messageHandlers: { shep: { postMessage: (m) => posts.push(m) } } }
const m = html.match(/<script type="module"[^>]*>([\s\S]*?)<\/script>/)
w.document.write(html.replace(/<script type="module"[\s\S]*?<\/script>/, ''))
w.eval(m[1])
await new Promise((r) => setTimeout(r, 100))
const shep = w.shep
const ok = (c, m) => { if (!c) { console.log('FAIL', m); process.exitCode = 1 } else console.log('ok', m) }
ok(!!shep, 'shep bridge exists')
ok(posts.some((p) => p.ready === true), 'page posts ready once window.shep exists')
shep.setLayout(140, 0, 40, 28, true)
const dog = w.document.getElementById('dog'), card = w.document.getElementById('card')
ok(dog.style.left === '140px' && dog.style.width === '40px', 'dog positioned')
ok(card.style.top === '32px', 'card below dog')
ok(dog.classList.contains('placed'), 'dog shown once placed')
ok(shep.metrics().viewW > 0 && typeof shep.metrics().dogW === 'number', 'metrics reports dog and viewport')
shep.say('hello', 50)
ok(card.classList.contains('on') && w.document.getElementById('text').textContent === 'hello', 'say shows card')
ok(posts.some((p) => p.card === 'shown'), 'shown posted')
await new Promise((r) => setTimeout(r, 120))
ok(!card.classList.contains('on') && posts.some((p) => p.card === 'hidden'), 'say auto-hides and posts hidden')
shep.ask('Click Gear?', [{ id: 'approve', label: 'Approve' }, { id: 'cancel', label: 'Cancel' }])
const btns = w.document.querySelectorAll('#buttons button')
ok(btns.length === 2, 'two buttons')
btns[0].click()
ok(posts.some((p) => p.choice === 'approve'), 'approve posted')
ok(!card.classList.contains('on'), 'card hidden after choice')
shep.openPill()
ok(card.classList.contains('pilling'), 'pill open')
const input = w.document.getElementById('pillInput'); input.value = ' fix this screen '
w.document.getElementById('pill').dispatchEvent(new w.Event('submit', { cancelable: true }))
ok(posts.some((p) => p.submit === 'fix this screen'), 'submit posted trimmed')
shep.openPill()
input.dispatchEvent(new w.KeyboardEvent('keydown', { key: 'Escape' }))
ok(posts.some((p) => p.cancel === true), 'escape cancels')
shep.showTranscript('open the settings')
ok(card.classList.contains('on') && card.classList.contains('pilling') && input.value === 'open the settings' && input.readOnly, 'transcript shows read-only in the pill')
shep.showTranscript('open the settings page')
ok(input.value === 'open the settings page', 'transcript updates')
shep.closeCard()
ok(!card.classList.contains('on') && !input.readOnly, 'closing the card makes the pill editable again')
shep.openPill(); ok(!input.readOnly && input.value === '', 'a fresh pill is empty and editable')
shep.closeCard()
shep.setLayout(140, 154, 40, 28, false)
ok(card.style.top === 'auto' && card.style.bottom !== 'auto', 'card above dog when flipped')
shep.setLayout(140, 2, 40, 28, true, 62)
ok(card.style.top === '62px' && card.style.bottom === 'auto', 'card hangs from the anchor below the title bar')
shep.setLayout(140, 2, 40, 28, true)
ok(card.style.top === '34px', 'no anchor: card hugs the dog')

// approval card: focus, dialog semantics, Escape, long text, hidden/inert, dog button
{
  const textEl = w.document.getElementById('text'), buttonsEl = w.document.getElementById('buttons')
  ok(card.hasAttribute('inert') && card.getAttribute('aria-hidden') === 'true', 'a hidden card is inert and aria-hidden')
  ok(w.document.getElementById('pill').hidden === true, 'a hidden pill has the hidden attribute')
  shep.ask('Press the button "Save"?\nYou asked Shep to check every action.', [{ id: 'approve', label: 'Approve' }, { id: 'cancel', label: 'Cancel' }], 'Shep wants to press Save in TextEdit')
  ok(card.getAttribute('role') === 'dialog' && card.getAttribute('aria-modal') === 'true', 'approval card is a modal dialog')
  ok(card.getAttribute('aria-label') === 'Shep wants to press Save in TextEdit', 'dialog is named after the action')
  ok(!card.hasAttribute('inert') && !card.hasAttribute('aria-hidden'), 'a visible card is reachable')
  const act = w.document.activeElement
  ok(act && act.tagName === 'BUTTON' && act.textContent === 'Cancel', 'Cancel is focused when the card shows (active: ' + (act && act.tagName) + ')')
  ok(card.getAttribute('aria-live') === null && card.getAttribute('role') !== 'status', 'no live region: Swift announces once')
  const before = posts.length
  w.document.dispatchEvent(new w.KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
  ok(posts.slice(before).some((p) => p.cancel === true), 'Escape on an approval card posts cancel')
  ok(!card.classList.contains('on') && card.hasAttribute('inert') && !card.hasAttribute('role'), 'Escape closes the card and clears the dialog role')
  // a card without Cancel focuses the first button
  shep.ask('Pick one', [{ id: 'a', label: 'First' }, { id: 'b', label: 'Second' }])
  ok(w.document.activeElement.textContent === 'First' && card.getAttribute('aria-label') === 'Pick one', 'no Cancel: first button focused, label falls back to the text')
  shep.closeCard()
  // Escape with no approval card showing does nothing
  const n = posts.length
  w.document.dispatchEvent(new w.KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
  ok(posts.length === n, 'Escape with no approval card posts nothing')
  // long text: the buttons stay in the card, the text area scrolls
  const long = 'This is a very long explanation of what Shep is about to do. '.repeat(40)
  shep.ask(long, [{ id: 'approve', label: 'Approve' }, { id: 'cancel', label: 'Cancel' }], 'Shep wants to press Save in TextEdit')
  ok(buttonsEl.querySelectorAll('button').length === 2 && buttonsEl.parentElement === card, 'long text: both buttons are in the card')
  ok(textEl.textContent.length > 2000 && textEl.nextElementSibling === buttonsEl, 'long text: the text area comes first and the buttons follow it')
  const css = Array.from(w.document.querySelectorAll('style')).map((e) => e.textContent).join('\n').replace(/\s+/g, ' ')
  const rule = (sel) => { const m = css.match(new RegExp(sel.replace(/[#.]/g, '\\$&') + ' ?\\{([^}]*)\\}')); return m ? m[1] : '' }
  ok(/max-height: ?150px/.test(rule('#card')) && /display: ?flex/.test(rule('#card')) && /flex-direction: ?column/.test(rule('#card')), 'card: 150 px high flex column')
  ok(/overflow-y: ?auto/.test(rule('#text')) && /min-height: ?0/.test(rule('#text')) && /flex: ?1 1 auto/.test(rule('#text')), 'text area scrolls (overflow-y:auto, min-height:0, flex 1 1 auto)')
  ok(/flex: ?none/.test(rule('#buttons')), 'buttons never shrink')
  shep.closeCard()
  // the DOM dog button
  const nd = posts.length
  dog.dispatchEvent(new w.KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
  dog.dispatchEvent(new w.KeyboardEvent('keydown', { key: ' ', bubbles: true }))
  ok(posts.slice(nd).filter((p) => p.activate === true).length === 2, 'Enter and Space activate the dog button')
  ok(dog.getAttribute('role') === 'button' && dog.getAttribute('tabindex') === '0', 'the dog is a focusable button')
  dog.dispatchEvent(new w.KeyboardEvent('keydown', { key: 'a', bubbles: true }))
  ok(posts.slice(nd).filter((p) => p.activate === true).length === 2, 'other keys do not activate it')
  shep.openPill(); ok(w.document.getElementById('pill').hidden === false && !card.hasAttribute('inert'), 'an open pill is reachable')
  shep.closeCard()
}

// one error listener and one ready post, however many frames run
{
  const lw = new Window({ url: 'file:///x/index.html', width: 320, height: 182 })
  const lposts = []
  lw.webkit = { messageHandlers: { shep: { postMessage: (m) => lposts.push(m) } } }
  let errorListeners = 0
  const orig = lw.addEventListener.bind(lw)
  lw.addEventListener = (type, ...rest) => { if (type === 'error') errorListeners++; return orig(type, ...rest) }
  lw.document.write(html.replace(/<script type="module"[\s\S]*?<\/script>/, ''))
  lw.eval(m[1])
  lw.shep.setLayout(140, 0, 40, 28, true)
  for (let i = 1; i <= 120; i++) lw.shep._step(performance.now() + i * 33)
  await new Promise((r) => setTimeout(r, 120))
  ok(errorListeners === 1, '120 frames -> 1 error listener (got ' + errorListeners + ')')
  ok(lposts.filter((p) => p.ready === true).length === 1, '120 frames -> 1 ready post (got ' + lposts.filter((p) => p.ready === true).length + ')')
  lw.shep.setActive(false)
}

// motion bridge
const dbg = () => shep.debug()
ok(dbg().state === 'docking' && dbg().fps === 60, 'first placement starts the rise at 60 fps')
shep._step(performance.now() + 3000)
shep.setState('thinking'); ok(dbg().state === 'thinking' && dbg().fps === 30, 'thinking runs at 30 fps')
shep.setState('talking'); ok(dbg().state === 'speaking', 'old name talking maps to speaking')
shep.setState('listening'); ok(dbg().state === 'listening', 'listening')
shep.setState('idle')
shep.setActive(false)
ok(dbg().active === false && dbg().fps === 0 && dbg().running === false, 'setActive(false) pauses the loop')
const framesBefore = dbg().frames
await new Promise((r) => setTimeout(r, 150))
ok(dbg().frames === framesBefore, 'no frames while paused')
shep.setActive(true)
await new Promise((r) => setTimeout(r, 150))
ok(dbg().running && dbg().frames > framesBefore, 'setActive(true) resumes it')
shep.setReduceMotion(true)
ok(dbg().reduce && dbg().fps === 15 && w.document.body.classList.contains('calm'), 'reduce motion: 15 fps, calm class')
shep.setReduceMotion(false)
shep.send('hide'); await new Promise((r) => setTimeout(r, 100))
ok(dbg().state === 'hidden' && dbg().fps === 0 && dbg().running === false, 'hidden stops the loop')
shep.send('show'); ok(dbg().state === 'docking', 'show rises again')
shep._step(performance.now() + 5000)
shep.setState('listening'); shep._step(performance.now() + 7000)
const earTf = Array.from(w.document.querySelectorAll('[data-rig="ear"]')).map((e) => e.getAttribute('transform'))
ok(earTf.length === 4 && earTf.every((t) => /^rotate\(/.test(t)), 'ears are rigged (outer and inner band, both sides)')
ok(w.document.querySelectorAll('[data-rig="eye"]').length === 2 && w.document.querySelectorAll('[data-rig="dot"]').length === 3, 'eyes and thinking dots are rigged')
shep.drag(40, -40); ok(dbg().state === 'dragging' && dbg().fps === 60, 'drag runs at 60 fps')
shep.dragEnd(); ok(dbg().state === 'docking', 'drag end snaps back')
shep.setActive(true)
shep.setState('idle'); shep._step(performance.now() + 20000)
shep.setPose(JSON.stringify({ name: 'listening', ears: [{ angle: 52, lift: 4 }, { angle: 52, lift: 4 }], eyeScale: 1.12, eyeX: 0, eyeY: 0, tilt: 7, tiltDelay: 0, transition: { stiffness: 190, damping: 9.5, earDelay: [0, 0], springs: false } }))
shep._step(performance.now() + 20100)
ok(shep.debug().poseName === 'listening', 'setPose is accepted by the dog page')
ok(/rotate\(5\d(\.\d+)? -11 -12\) translate\(0 -4\)/.test(w.document.querySelectorAll('[data-rig="ear"]')[0].getAttribute('transform')), 'left ear: rotation and lift applied: ' + w.document.querySelectorAll('[data-rig="ear"]')[0].getAttribute('transform'))
shep.setPose('{bad'); ok(shep.debug().poseName === 'listening', 'a bad pose is ignored')
shep.setPose(JSON.stringify({ name: 'idle', ears: [{ angle: 0, lift: 0 }, { angle: 0, lift: 0 }], transition: { springs: false } })); shep._step(performance.now() + 20200)

// travel: stretched along the velocity at 60 fps, then back to the normal pose
const frames = [[0, 1, 1, 0, 0], [0.05, 1.4, 0.85, 30, 1], [0.1, 1.5, 0.82, 30, 1]]
shep.travel(frames, 0.1)
ok(dbg().fps === 60, 'travel runs at 60 fps')
shep._step(performance.now() + 50)
const sc = /scale\(([\d.]+), ([\d.]+)\)/.exec(dog.style.transform)
ok(sc && Number(sc[1]) > 1.2 && Number(sc[2]) < 0.95 && /rotate\(30deg\)/.test(dog.style.transform), 'travel stretches along the velocity: ' + dog.style.transform)
shep._step(performance.now() + 5000)
ok(!/rotate\(30deg\)/.test(dog.style.transform) && dbg().fps !== 60, 'travel ends: normal pose, rate drops')
shep.travel([[0, 1, 1, 0, 1]], 1)   // fewer than two frames: ignored
ok(dbg().fps !== 60, 'a one-frame travel is ignored')
shep.setActive(false)

// the doghouse page
{
  const hhtml = fs.readFileSync(path.join(root, 'Resources/shep-dog/house.html'), 'utf8')
  const hw = new Window({ url: 'file:///x/house.html', width: 96, height: 84 })
  const hposts = []
  hw.webkit = { messageHandlers: { house: { postMessage: (m) => hposts.push(m) } } }
  const hm = hhtml.match(/<script type="module"[^>]*>([\s\S]*?)<\/script>/)
  hw.document.write(hhtml.replace(/<script type="module"[\s\S]*?<\/script>/, ''))
  hw.eval(hm[1])
  await new Promise((r) => setTimeout(r, 150))
  const house = hw.house
  ok(!!house && hposts.some((p) => p.ready === true), 'house bridge exists and posts ready')
  ok(hw.document.querySelectorAll('[data-rig="z"]').length === 3, 'house: z glyphs are in the art')
  ok(house.debug().mode === 'asleep' && house.debug().fps === 8 && house.debug().running, 'house sleeps at 8 fps')
  const f0 = house.debug().frames
  await new Promise((r) => setTimeout(r, 400))
  const f1 = house.debug().frames
  ok(f1 - f0 >= 1 && f1 - f0 <= 6, 'house frame rate is low (' + (f1 - f0) + ' frames in 0.4 s)')
  house.setMode('waking'); ok(house.debug().fps === 30, 'house: waking at 30 fps')
  house.setMode('away'); ok(house.debug().fps === 0 && !house.debug().running, 'house: empty house schedules nothing')
  house.setMode('bogus'); ok(house.debug().mode === 'away', 'house: unknown mode ignored')
  house.setMode('entering'); house.setMode('asleep')
  house.setActive(false); const fp = house.debug().frames; await new Promise((r) => setTimeout(r, 300))
  ok(house.debug().frames === fp && !house.debug().running, 'house: paused means no frames')
  house.setActive(true); house.setReduceMotion(true)
  ok(house.debug().fps === 0 && house.debug().frames > fp, 'house: reduce motion renders one still frame and stops')
  house.setReduceMotion(false); house.setTheme('Cobalt')
  ok(hw.document.body.innerHTML.includes('#3D6BFF'), 'house: theme colour applied')
  // poses on the house page: ears droop asleep, wake twitches one ear first
  const asleep = { name: 'asleep', ears: [{ angle: -12, lift: -2 }, { angle: -12, lift: -2 }], eyeScale: 0.95, eyeX: 0, eyeY: 0.3, tilt: 0, tiltDelay: 0, transition: { stiffness: 90, damping: 14, earDelay: [0, 0.08], springs: false } }
  house.setPose(JSON.stringify(asleep)); house._render(performance.now())
  const hears = Array.from(hw.document.querySelectorAll('[data-rig="ear"]'))
  ok(hears.length === 2 && hears.every((e) => /^rotate\(/.test(e.getAttribute('transform'))), 'house: ears are rigged and posed')
  ok(house._pose().earAngle[0] === -12 && house._pose().earAngle[1] === 12 && house.debug().pose === 'asleep', 'house: asleep pose droops both ears (mirrored)')
  house.setPose('junk'); ok(house.debug().pose === 'asleep', 'house: a bad pose is ignored')
  house.setReduceMotion(true)
  house.setPose(JSON.stringify({ ...asleep, name: 'waking', ears: [{ angle: 22, lift: 2.5 }, { angle: 22, lift: 2.5 }], transition: { ...asleep.transition, springs: true, twitch: { ear: 0, kick: 24, seconds: 0.18, popDelay: 0.24 } } }))
  ok(house._pose().earAngle[0] === 22 && house._pose().earAngle[1] === -22, 'house: reduce motion pops the ears at once')
  house.setReduceMotion(false)
  house.setActive(false)
}
process.exit(process.exitCode || 0)
