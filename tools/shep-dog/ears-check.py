#!/usr/bin/env python3
"""Pixel check: both ears show in every pose. Optional (needs python3, playwright, PIL, numpy and /usr/bin/google-chrome).

Usage: tools/shep-dog/ears-check.py <out-dir> [index.html [DogPose.swift]]
(defaults: Resources/shep-dog/index.html and ShepCore/Sources/DogPose.swift)

Loads the dog page in headless Chrome on a dark background, applies each pose from ShepCore/Sources/DogPose.swift through
shep.setPose(json), screenshots it (PNGs go to <out-dir>, never into the repo) and counts pixels of the ear colour
to the left of the head's left edge and to the right of its right edge. A side with fewer than MIN_PIXELS fails.
Pixels are counted at device scale 10 (one head unit = about 10 px square), so 1 head unit^2 is about 100 px.
"""
import os, re, sys, json
import numpy as np
from PIL import Image
from playwright.sync_api import sync_playwright

MIN_PIXELS = 1000   # measured at scale 10: fixed table, weakest side is asleep/thinking-left (about 1940-2370); old table, hidden ears gave 0
here = os.path.dirname(os.path.abspath(__file__))
repo = os.path.abspath(os.path.join(here, '..', '..'))
if len(sys.argv) < 2:
    sys.exit(__doc__)
out = os.path.abspath(sys.argv[1]); os.makedirs(out, exist_ok=True)
page_path = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else os.path.join(repo, 'Resources/shep-dog/index.html')
src = open(os.path.abspath(sys.argv[3]) if len(sys.argv) > 3 else os.path.join(repo, 'ShepCore/Sources/DogPose.swift')).read()

poses = {}
for m in re.finditer(r'case \.(\w+):\s*(?://[^\n]*\n\s*)*return DogPose\(name: name, leftEar: EarPose\(angle: (-?[\d.]+), lift: (-?[\d.]+)\), rightEar: EarPose\(angle: (-?[\d.]+), lift: (-?[\d.]+)\)(.*?)\)\n', src, re.S):
    n, extra = m.group(1), m.group(6)
    def g(k, d=0.0):
        mm = re.search(k + r': (-?[\d.]+)', extra)
        return float(mm.group(1)) if mm else d
    poses[n] = dict(name=n, ears=[dict(angle=float(m.group(2)), lift=float(m.group(3))), dict(angle=float(m.group(4)), lift=float(m.group(5)))],
                    eyeScale=g('eyeScale', 1), eyeX=g('eyeX'), eyeY=g('eyeY'), tilt=g('headTilt'), tiltDelay=0,
                    transition=dict(stiffness=150, damping=12, earDelay=[0, 0], springs=False))
if len(poses) != 7:
    sys.exit('read %d poses from DogPose.swift, expected 7' % len(poses))

fail = 0
with sync_playwright() as p:
    b = p.chromium.launch(executable_path='/usr/bin/google-chrome', args=['--no-sandbox'])
    pg = b.new_page(viewport={'width': 320, 'height': 224}, device_scale_factor=10)
    for n, pose in poses.items():
        pg.goto('file://' + page_path + '?reduce=1&state=idle')
        pg.add_style_tag(content='html,body{background:#2a2b2e !important} #dog{left:20px !important;top:14px !important}')
        pg.evaluate("document.getElementById('dog').classList.add('placed')")
        pg.wait_for_timeout(300)
        pg.evaluate('(j) => window.shep.setPose(j)', json.dumps(pose))
        pg.wait_for_timeout(400)
        info = pg.evaluate("""() => {
            const earPath = document.querySelector('[data-rig="ear"] path[fill]:not([fill="none"])');
            const heads = Array.from(document.querySelectorAll('rect[rx="12.5"]')).filter((r) => r.getAttribute('fill') && r.getAttribute('fill') !== 'none');
            const hr = heads[heads.length - 1].getBoundingClientRect();
            const c = document.createElement('canvas').getContext('2d'); c.fillStyle = earPath.getAttribute('fill');
            return { ear: c.fillStyle, left: hr.left, right: hr.right, top: hr.top, bottom: hr.bottom };
        }""")
        clip = {'x': 0, 'y': 0, 'width': 80, 'height': 56}
        png = os.path.join(out, 'ears-%s.png' % n)
        pg.screenshot(path=png, clip=clip)
        im = np.asarray(Image.open(png).convert('RGB')).astype(int)
        h = info['ear'].lstrip('#'); rgb = np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)])
        match = (np.abs(im - rgb).max(axis=2) <= 3)
        scale = 10
        lx, rx = int(info['left'] * scale), int(info['right'] * scale)
        left, right = int(match[:, :lx].sum()), int(match[:, rx:].sum())
        ok = left >= MIN_PIXELS and right >= MIN_PIXELS
        fail += 0 if ok else 1
        print('%-9s left %6d  right %6d  (min %d, ear %s)  %s' % (n, left, right, MIN_PIXELS, info['ear'], 'ok' if ok else 'FAIL'))
    b.close()
sys.exit(1 if fail else 0)
