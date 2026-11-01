# Shep

Shep is a small dog that lives in your Mac's menu bar. When you call it, it leaves its home under the menu bar and docks as a tab on the title bar of the window you are working in, the one VoiceOver is on when VoiceOver is running. Ask it for something, such as "turn on the speed limit", and it finds the control, even one the app never named, then shows you exactly what it will do. It acts only after you approve.

It was built for the Meta Global AI Developer Hackathon (Oct 26 to Nov 4, 2026). The model that names controls and picks the target is **Muse Glimmer 30B**, Meta's open-weights model, running on your own Mac.

## Calling Shep

| How | Details |
|---|---|
| Say **"Hey Shep"** | Off by default: Settings > Calling and voice > *Listen for "Hey Shep"*. The microphone is read by on-device speech recognition only; if your Mac cannot recognise your language on-device, Shep does not listen at all. Audio is never written to disk and transcripts are never logged. After the match, say your request; it ends after 1.5 s of silence (6 s if nothing was heard). |
| Hold **Right Option** | Push to talk: hold about a quarter of a second and speak; let go to send. Right Command or Right Control can be chosen instead in Settings. |
| Press **Control-Shift-Command-Space** | Global shortcut, no extra permission. It was chosen because Control-Option is VoiceOver's own modifier and Control-Option-Space is the input-source shortcut. Other presets are in Settings. |
| Menu bar | **Call Shep**, **Fix This Screen**, **Send Shep Home**. With VoiceOver, Shep's home indicator is a button ("Shep's home") that calls Shep. |

Escape or **Send Shep Home** sends it back; it also goes home after about 20 seconds without activity, or after a task. With Reduce Motion on it fades instead of travelling.

**Home.** While it sleeps Shep is a small dark indicator. On a Mac with a notch it is a slim black chin exactly as wide as the notch, hanging just below the menu bar, with a paw on the left and a status mark (asleep, waking, out) on the right; on a Mac without a notch it is a small pill at the top centre. It is click-through and never covers the menu bar. While Shep sleeps nothing is tracked.

**Short feedback.** Shep says "On it." when it starts looking and "Done." when a step is done, then gives one short bark; otherwise "Cancelled." or "Nothing to do." It does not narrate the screen. With VoiceOver running these are high-priority VoiceOver announcements, Shep stays home until your spoken question is over (so nothing talks over you), and it does not say "Shep is here." after a question.

## Where Shep goes: VoiceOver first

Shep does not trust the mouse pointer first, because many of the people it is meant for do not use one. It picks the window in this order:

1. **VoiceOver focus**, while VoiceOver is running.
2. **Keyboard focus** (the front app's focused window).
3. **The mouse pointer**, only when neither gives a window.

The order is `FocusTargetPolicy` in ShepCore and is unit-tested; the app logs which one decided (`[shep] target: voiceover`, `keyboard` or `mouse`). There is no public API for the VoiceOver cursor, so Shep reads the focused element through Accessibility, which matches the VoiceOver cursor under VoiceOver's default cursor tracking. When VoiceOver is on, macOS often refuses the system-wide "what has focus" query; Shep then asks the front app for its own focused element. If you call Shep while one of Shep's own windows (such as Settings) is in front, it hands focus back to the app you were in first.

## What happens when you ask

1. **Read.** Shep lists the window's own controls through the macOS Accessibility API.
2. **Look.** It takes a screenshot of that one window and runs a local detector (OmniParser v3 `icon_detect`) to find controls the app does not list, such as icon-only buttons or a checkbox named only by its tooltip. Boxes that duplicate a listed control are merged away.
3. **Name and pick.** Muse Glimmer names the controls found on the screenshot and picks the one your request is about (schema-constrained JSON, thinking off, temperature 0).
4. **Check the pick.** The model's pick is evidence, not a decision. `ProposalRanker` scores every control against your words. A pick that covers a whole pane, or that only exists on the screenshot while exactly one listed control clearly matches your request, gives way to that control.
5. **Ask.** The proposal appears on a one-line native card under the tab with **Approve** and **Deny**, for example: *Press the checkbox "Speed Limit"?* Deny is the cancel choice, Escape picks it, and neither is the default. Keyboard focus starts on the card's text, so VoiceOver reads it first; VO-Right reaches Approve and VO-Space presses it.
6. **Act.** Only after Approve. An Accessibility press is tried first. A mouse click happens only after approval, only if the window has not moved and nothing covers the spot, and the pointer is put back afterwards. When a fix finishes, Shep gives one short recorded bark (CC0, credited in `NOTICE`; it can be turned off).

### What Shep refuses
- There is **no auto-approve** anywhere: every action that is not refused asks (`ApprovalPolicy`, tested).
- Controls whose names involve paying, buying, ordering, transferring money, signing in or out, passwords, deleting, erasing, uninstalling, restarting or shutting down are refused, and so are password fields.
- Security and password apps and System Settings are never driven.
- Messaging, mail, call, wallet and password-manager windows are never captured, and neither are terminals, code editors and other apps that run commands.
- Shep hides its own windows from screen sharing and recordings by default (**Hide Shep from Screen Sharing** in the menu).
- There is no scripting-bridge automation in the code; `scripts/check-rules.sh` and a unit test enforce that.

## Models

| Component | Role | Licence | Where it runs |
|---|---|---|---|
| **Muse Glimmer 30B** by Meta ([model card](https://huggingface.co/meta-models/Muse-Glimmer-30B)) | Names screenshot-only controls and picks the target of a request | Apache 2.0 | Your Mac, behind any OpenAI-compatible server. Tested with the 4-bit MLX conversion served by `mlx_vlm.server` (`scripts/glimmer-server.sh`), default `http://127.0.0.1:8080/v1` |
| **OmniParser v3** `icon_detect` by Microsoft | Finds control boxes on the screenshot | MIT (the weights' own licence file applies) | Local Python sidecar, `127.0.0.1:8765` (`scripts/detector-server.py`) |
| macOS Accessibility | The app's own controls, and the presses | — | The app |
| macOS Speech (`SFSpeechRecognizer`) | "Hey Shep" (always on-device) and push to talk (on-device whenever the Mac supports it) | — | The app |

No model weights are in this repository. Optional, untested providers are listed under Limitations.

## Requirements

- macOS 14 or later. The window-bound demo recorder (`--live-record`) needs macOS 15.
- Xcode and [xcodegen](https://github.com/yonaskolb/XcodeGen).
- An M-series Mac (MLX) with enough memory for Glimmer: `scripts/glimmer-server.sh` refuses to start with less than 24 GB free.
- Python 3 for the detector sidecar (PyTorch, torchvision, Pillow, NumPy, huggingface_hub), installed in a venv you create.
- Permissions, each requested from the first-launch setup window: **Accessibility** (find, follow and press the window's controls; also the Right Option and Escape monitors), **Screen Recording** (the window screenshot), **Microphone** and **Speech Recognition** (talking to Shep).

## Setup

```sh
# 1. Build
scripts/build.sh                     # xcodegen + xcodebuild -> build/Build/Products/Debug/Shep.app

# 2. Muse Glimmer: put an MLX build of meta-models/Muse-Glimmer-30B at ~/models/Muse-Glimmer-30B-4bit
#    (or set GLIMMER_MODEL), give it a Python environment with mlx-vlm (the script uses ~/models/venv,
#    or set GLIMMER_VENV), then start it, or point Shep at a server you already run.
python3 -m venv ~/models/venv && ~/models/venv/bin/pip install mlx-vlm
scripts/glimmer-server.sh            # or: SHEP_GLIMMER_URL=http://127.0.0.1:<port>/v1 when launching Shep

# 3. Detector sidecar (see docs/detector.md for the weights)
python3 -m venv ~/.shep-venv
~/.shep-venv/bin/pip install torch torchvision pillow numpy huggingface_hub
~/.shep-venv/bin/python scripts/detector-server.py --omni-weights <path to icon_detect_v3.torchscript>

# 4. Launch, grant the permissions, and call Shep
open build/Build/Products/Debug/Shep.app
```

An unsigned Debug build can lose its Accessibility permission when it is rebuilt; remove Shep and add it again under System Settings > Privacy & Security > Accessibility.

To film Shep, untick **Hide Shep from Screen Sharing**, or launch with `--capturable`. The Transmission demo is scripted:

```sh
scripts/record-fix-demo.sh org.m0k.transmission "turn on the speed limit (turtle)"
```

It records only the target window and Shep's own overlay, writes the clip outside the repo (`SHEP_EVIDENCE_DIR`), and never answers the approval card: a person does.

## Tests

```sh
scripts/test.sh      # check-rules, the shell-script tests, then the ShepCore XCTest suite
build/Build/Products/Debug/Shep.app/Contents/MacOS/Shep --ui-snapshot <dir>   # renders Shep's own views to PNGs and checks them
```

`tools/shep-dog/run-tests.sh` tests the dog page separately and needs a checkout of bloub (see [docs/DEVELOPER.md](docs/DEVELOPER.md)).

## Limitations and not yet

- **SAM 3 has not been run inside Shep.** It is wired in as an optional second detector (`--sam3` on the sidecar plus `SHEP_SAM3=1`, with your own Hugging Face token for the gated weights) and is off by default. SAM 3 is under Meta's SAM License, which is not an open-source licence.
- **The cloud provider has not been run.** A Muse Spark + SAM 3.1 provider through the Meta Model API exists behind `SHEP_PROVIDER=meta`, a `MODEL_API_KEY`, and the menu switch **Allow Screenshots to Meta Cloud**. It is untested and not used in the demo.
- **"Fix This Screen" with no request, on a window where nothing is wrong, offers nothing.** Shep says what it saw rather than guess.
- **A screenshot-only pick on an empty spot can still end in "I can't identify what is under that spot"** when no listed control matches the request words, so there is nothing to fall back to.
- **The rescue for a missed pick is narrow on purpose.** If the model picks nothing, Shep offers a control only when exactly one control clearly matches the request words.
- **VoiceOver focus is read indirectly.** If VoiceOver's cursor is set not to move keyboard focus, Shep follows keyboard focus instead.
- **The "Hey Shep" matcher is English-only** (hey, hay, hei, eh or a, followed by shep or a close spelling) and needs on-device recognition for your language.
- **The OmniParser weights' download location is not recorded** (see [docs/detector.md](docs/detector.md)); read the licence file that ships with whichever copy you use.
- **Tested on one Mac**, with three displays, including displays at negative coordinates. It has not been tested by VoiceOver users yet. Not signed or packaged.
- Roadmap: answering questions about the screen (not only pressing controls), packaging and signing, and testing with VoiceOver users.

## Layout

```
Shep/                 app target (AppKit + SwiftUI): menu, setup, window tracker, overlay, dog web view, capture, voice, actions
ShepCore/             pure logic framework (no AppKit) and its XCTest suite: geometry, policy, approval, providers, ranking, pipeline
Resources/shep-dog/   the built dog and doghouse pages (transparent WKWebView)
tools/shep-dog/       sources and build for the dog pages
scripts/              build, test, check-rules, detector sidecar, Glimmer server, demo recording
docs/                 DEVELOPER.md (command-line, recording and pipeline reference), detector.md
```

More: [docs/DEVELOPER.md](docs/DEVELOPER.md) for every launch flag, the demo recorder and the pipeline details; [docs/detector.md](docs/detector.md) for the sidecar; [LESSONS.md](LESSONS.md) for what the build taught us.

## Third-party

- **bloub** goop dog avatar, MIT, Copyright (c) 2026 Jérémy Perret, https://github.com/jeremy-prt/bloub (branch `dog-goop`, commit 6b59465). See `NOTICE` and `Resources/shep-dog/ATTRIBUTION.md`.
- **OmniParser v3** `icon_detect` (MIT), optional `icon_caption` (MIT, a Florence-2 fine-tune) and **SAM 3 by Meta** (SAM License, optional). The user supplies or downloads the weights; none are in this repository. The OmniParser v2 `icon_detect` weights (AGPL-3.0) are never used.
- **Muse Glimmer** by Meta, Apache 2.0, downloaded by the user.
- **"Single Dog Bark"** by kwahmah_02 (Freesound 277058), CC0 1.0, used as the finish bark. See `NOTICE`.
- Vite (MIT) helper code inlined in the built pages. Build and test tools that are not redistributed: Vite, vite-plugin-singlefile, happy-dom, jiti. See `NOTICE`.

## License

MIT, Copyright (c) 2026 Tyler Dunn. See [LICENSE](LICENSE).
