# Shep developer reference

The detailed command-line, recording, settings and pipeline reference, moved here from the README. The README has the overview.

## Build and test

Requires macOS 14+, Xcode, and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```sh
scripts/build.sh     # xcodegen generate + xcodebuild build -> build/Build/Products/Debug/Shep.app
scripts/test.sh      # headless ShepCore unit tests
```

Try the docking without finishing onboarding:

```sh
build/Build/Products/Debug/Shep.app/Contents/MacOS/Shep --dock-demo
```

Take a docked screenshot of a clean window (output goes to `$SHEP_EVIDENCE_DIR`, default `~/shep-evidence/`, never the repo):

```sh
scripts/shep-test-window.sh   # opens an empty TextEdit document titled "Shep test"
scripts/docked-shot.sh        # launches Shep --dock-demo --capturable, waits for the tab, captures window + tab, quits Shep
```

### Reading and pressing from the command line

All of these are headless (no overlay, no capture) and need Accessibility for the terminal. `<target>` is a pid or a bundle identifier.

```sh
# What Shep sees: selected window, every window (modal flag), nodes_visited, controls_kept, one line per control, truncated, modal notice.
Shep --ax-read-once <target> [--title "<text>"] [--frame x,y,w,h]

# Fix this screen on a PNG, with the app's own controls merged in (otherwise every box looks "not in the Accessibility list"):
SHEP_AX_PID=<pid> SHEP_WINDOW_FRAME=x,y,w,h SHEP_WINDOW_TITLE="<title>" Shep --fix-screen-once shot.png
scripts/e2e-glimmer.sh --window "<owner>" [--title "<substr>"]     # captures the window and exports the pid for you
```

Who a `--fix-screen-once` image belongs to is decided before any provider is reached. If `SHEP_AX_PID` or `SHEP_WINDOW_OWNER` is set, Shep resolves the bundle identifier itself (from the running process, never from your words) and applies the capture policy to it; an unresolved or stale pid, an empty bundle identifier, an owner that disagrees with the pid, Accessibility denied or a failed window read all refuse (exit 6) and nothing is sent. A frame and a title with neither variable refuse too (that is a captured window that lost its owner; `scripts/e2e-glimmer.sh --window` stops with exit 2 when it cannot resolve the pid, before capturing). A bare PNG with neither variable is accepted only as an **unattested, user-supplied file**: Shep prints a one-line notice, still leaves out the controls it never presses (words like delete or pay), but cannot know which app the pixels came from, so you are responsible for what image you hand it.

```sh

# Propose AXPress on the one enabled control whose label or tooltip contains the text.
Shep --press-demo-once <target> --match "<text>" [--title t] [--frame f]             # prints the approval card, does nothing
Shep --press-demo-once <target> --match "<text>" [--title t] [--frame f] --approve   # presses once
scripts/press-demo.sh <bundle-id> "<exact match>"                                    # read, decline, press, restore, report
```

How the reader chooses: every window of the app is listed (`AXWindows`, plus the focused and main window). The target window, the one a screenshot shows, is the one whose frame is within 4 pt of `SHEP_WINDOW_FRAME` (or `--frame`), then the one titled `SHEP_WINDOW_TITLE` (or `--title`), else the main window, else the focused non-modal window, else the first non-modal one. Caps are the old ones (depth 8, 400 nodes, 2 s, 0.2 s per call) and are shared, with the target walked first so a dialog cannot starve it. Controls from the other windows are kept only where they overlap the target window, tagged with their own window title and subrole. Secure fields are not descended and menu bars are not either.

A control with no title or description is named by its tooltip (`AXHelp`), last, and listed as `source=tooltip`; the approval card says "(named by its tooltip)". Of the 37 nodes in a torrent client's main window, 24 are actionable controls: `controls_kept` counts the actionable subset (`ControlFilter.prepare`), `nodes_visited` counts everything read.

The press demo never bypasses approval. The proposal goes through `ApprovalPolicy` and `ActionRunner` and the token is single use. The app has no auto-approve mode and the card always asks. `--approve` exists only on this command line, is the operator's yes for that one control, and is logged as "approved by explicit --approve flag". A failed press does not fall back to a click. `scripts/press-demo.sh` always restores the original value (an exit trap presses again if the value is left flipped) and writes `$SHEP_EVIDENCE_DIR/press-demo-<time>.txt`.

### The doghouse cycle

Pure, tested logic in ShepCore: `ShepLifecycle` (asleep, waking, traveling, working, returning; events call, wakeFinished, arrived, homeReached, taskStarted, taskDone, dismiss, timeout, windowLost, reduceMotion; it returns effects the app carries out), `TravelPath` and `TravelTarget` (`.tab(windowFrame:)` today, `.control(rect)` as the hook for pointing at a control), `HomeGeometry` (notch, status item or top centre, per screen), `LifecycleFramePolicy` (8 fps asleep, 30 waking, 60 only while travelling, 0 hidden). The app side is `ShepCoordinator` (timers, panels, call inputs), `HomePanel`, `TravelPanel` and `CallInputs.swift`; the page is `tools/shep-dog/src/house.ts`, `house-main.ts` (built to `Resources/shep-dog/house.html`).

```sh
build/Build/Products/Debug/Shep.app/Contents/MacOS/Shep --demo-script=cycle --capturable   # waits asleep; SIGUSR1 plays the cycle, SIGUSR2 logs the planned arc
scripts/record-cycle.sh       # (add --backdrop for a clean clip with sound, below) records ONLY the doghouse, the Shep test window, its tab and the arc's corridor; prints asleep CPU
```

`record-cycle.sh` moves the Shep test window directly under the house, asks Shep for the planned arc, records the bounding box and, with ffmpeg, replaces every pixel outside those rectangles with a flat colour (the unmasked file is a temp file and is deleted); without ffmpeg it records the house, the window and the tab separately. Output goes to `$SHEP_EVIDENCE_DIR` (default `~/shep-evidence/`) as `cycle-<time>.mov` with Shep's log beside it.

### Poses

Ears, eyes and head tilt come from one table in ShepCore (`DogPose`): asleep (ears droop flat), waking (one ear twitches, then both pop up), idle, listening (ears lift and perk with a springy overshoot, eyes widen, a small tilt after the ears), thinking (one ear flops down, eyes look up and aside), talking, finish (ears up). `PoseTransition` gives each move its spring and delays; the page animates the JSON it is sent (`shep.setPose`, `house.setPose`). With Reduce Motion the change is static: no springing, no overshoot. `--demo-script=cycle` logs `[shep] demo-state <name> t=<seconds>` at each change.

### The finish beat

When a fix finishes (at least one action done, nothing cancelled) Shep puts its ears up, posts "Done." to VoiceOver, hops once and woofs once, holds the happy pose for a moment, then trots home and sleeps. The woof is synthesized in Shep's own code at runtime (`BarkSynth` in ShepCore: one short soft bark of 200 ms: a sawtooth whose pitch falls from 820 to 380 Hz through two formant band-pass filters (about 1.15 and 1.9 kHz) and a 250 Hz high-pass, a 3 ms attack, a fast exponential decay and a little band-passed noise in the first 35 ms, no tremolo, deterministic); there are no audio assets and no samples. The app renders the samples into an `AVAudioPCMBuffer` and plays it through `AVAudioEngine` and an `AVAudioPlayerNode` (`BarkPlayer`). With VoiceOver running the woof waits until VoiceOver has finished speaking, or 1.5 s at most, so Shep never talks over it. With Reduce Motion there is no hop: the ear pose and the sound only. The timeline is `FinishBeat` (tested).

```sh
build/Build/Products/Debug/Shep.app/Contents/MacOS/Shep --export-bark=/tmp/bark.wav   # writes the woof as a 16-bit mono WAV and exits
```

### A clean cycle clip with sound

```sh
build/Build/Products/Debug/Shep.app/Contents/MacOS/Shep --demo-script=cycle --capturable --demo-backdrop
scripts/record-cycle.sh --backdrop   # records only the backdrop's rectangle and adds the woof; prints the clip path
```

`--demo-backdrop` makes Shep paint a plain soft-coloured window of its own (directly below the Shep test window, above every other app, under the menu bar, ignoring the mouse, visible to recordings) over the doghouse, the travel corridor, the tab and the test window, and log its rectangle. `record-cycle.sh --backdrop` records just that rectangle (`screencapture -v -R`, never the full screen) and uses ffmpeg to add the synthesized woof (`--export-bark`) at the cycle's `finish` step. The output is `$SHEP_EVIDENCE_DIR/cycle-<time>.mov` plus Shep's log. Without `--backdrop` the keep-only mask above is used.

### A live "Fix this screen" clip (`--live-request`)

```sh
scripts/record-fix-demo.sh org.m0k.transmission "turn on the speed limit (turtle)" --seconds 70   # --no-record for a dry run
# what it launches:
build/Build/Products/Debug/Shep.app/Contents/MacOS/Shep --live-request "turn on the speed limit (turtle)" --live-target org.m0k.transmission --live-record out.mov --live-record-seconds 70 --capturable
```

| Flag | Meaning |
|---|---|
| `--live-request "<text>"` (or `=<text>`, `SHEP_LIVE_REQUEST`) | After launch Shep is called like the shortcut does, waits until it is working at the front window (25 s limit), then submits the text once by the same path as the ask field. Only the request is submitted: the approval card is answered by a person, and no flag or script approves anything. The frontmost app stays the target; if that is Shep itself it logs `live: no target app in front` and does nothing. Normal launch only (not with `--dock-demo` or `--demo-script`). |
| `--demo-backdrop` (together with `--live-request`) | A plain backdrop window directly below the target app's front window, covering the window plus 120 pt at the sides and bottom, 70 pt on top, and the overlay panel (tab, speech bubble, approval card); clamped to the screen below the menu bar. Logs `[shep] live: record-rect x,y,w,h` (global top-left points). The request is submitted 3 s later, so a recorder has started. |
| `--live-record <out.mov>` (or `=<path>`, `SHEP_LIVE_RECORD`) | Used with `--live-request`; without it the flag is ignored and Shep logs `live: ignored: --live-record needs --live-request`. Shep records the target window itself once it is working there (ScreenCaptureKit, macOS 15 or later). The movie holds the target app's front window (by window id) and Shep's own overlay windows (dog tab and panel, speech and approval cards), cropped to the window plus the same margins as the backdrop, at 2x and 30 fps; every other window, even one that moves over the area, is not drawn, and what is not drawn is the plain lavender background. It stops 3 s after `live: finished` or after the seconds below, then logs `live: recording written: <path>`. It refuses to overwrite an existing file. **The output's parent folder must be private to you**, or Shep refuses with `live: record refused: the output folder is not private to you (<check>)` (the check names only the failing component, never a path): the folder is resolved with `realpath` first, and the resolved path is what is judged and what the recorder is given. It must be a real directory owned by your effective uid with no group- or other-write bit (`mode & 022 == 0`; a sticky bit on the folder itself does not help), and every ancestor up to `/` must be owned by you or root and either not group/other-writable or sticky (`/tmp`, `/private/var/folders/...`). **ACLs count too**: on macOS an ACL can let another user add files, add subdirectories, delete children, delete or change the security of a folder while its mode still reads 0700/0755, so the output folder, every ancestor and the fresh working directory are also read for ACLs. An `allow` entry carrying any of those rights (add_file, add_subdirectory, delete_child, delete, write data, append, write security, change owner) for anyone but you (another user, any group, an unresolvable principal), or an ACL that cannot be read, refuses with `<component>: an ACL lets another user change it`. `deny` entries and read-only `allow` entries pass, so the home folder's `group:everyone deny delete` does not refuse. `scripts/record-fix-demo.sh` applies the same rule with `ls -led` (a no-op where `ls` prints no ACL). The default evidence folder passes; `/tmp/out.mov` does not (`/tmp` itself is writable by others). ScreenCaptureKit opens the clip by path, not by descriptor, so Shep holds the working directory by descriptor and re-checks before the start, after the first clip appears, every 0.25 s, before the stop and before publishing that the path still leads to the held directory and that `clip.mov` is the file first seen (same device and inode, a regular file, one name, owned by you); a mismatch stops the stream and discards (`recording discarded: the private folder was swapped`), and a clip replaced by another file is preserved, not removed (`the clip was replaced by another file; left in <workdir>`). This narrows the race, it cannot make the write atomic with the descriptor; the parent check is what excludes other users. A process running as the same user is out of scope (it can do anything you can), and a sticky parent does not stop a same-user rename. |
| `--live-record-seconds N` (`SHEP_LIVE_RECORD_SECONDS`) | The longest recording: 10 to 600, default 70. |
| `--live-debug-dir <dir>` (or `=<dir>`, `SHEP_LIVE_DEBUG_DIR`) | Used with `--live-request`; without it the flag is ignored and Shep logs `live: ignored: --live-debug-dir needs --live-request`. Every live run then writes `<dir>/<yyyyMMdd-HHmmss>/` (mode 0700, files 0600) with `input.png` (the exact PNG handed to the provider), `ax-controls.txt` (the prepared Accessibility list: role, label, label source, frame), `trace.txt` (the namer's pick, the ranked list with scores, the picker's marks, explanation or error) and `request.txt`, then logs `live: debug dump written: <path>`. Named fields' values are omitted; static text, titles, descriptions and help can contain private text (a static text's label can derive from its value), which is why the dump is scrubbed and opt-in. All three text files pass through `Redact.scrub` (secrets and key-shaped strings masked; this is not personal-data removal) and every line is capped at 400 characters. **Nothing is written before the send decision**: the dump starts only after the pipeline's gate (`FixScreenPipeline.gate`: the required app, the never-capture policy, cloud consent for an off-device provider) allows sending; a refused input creates no directory. `input.png` is the exact image handed to the provider: a raw screenshot of the target window, not text and not sanitised, mode 0600, kept outside the repo, and written only when the gate has allowed sending it. Without the flag nothing is written. A directory inside the app's repository checkout, inside any directory that holds a `.git`, relative, the root of the disk or unwritable is refused (`live: debug dir refused: <why>`) and the run goes on without a dump. |
| `--live-target <bundle-id>` (or `=<id>`, `SHEP_LIVE_TARGET`) | Used with `--live-request`; binds the request to that app (`[A-Za-z0-9._-]`, 1 to 255 characters). **An explicit binding that cannot be used refuses the run** (a missing, empty, too long or malformed value, in the flag or in `SHEP_LIVE_TARGET`, a trailing space included): Shep logs `live: reason: target: --live-target is not a bundle id` (or `needs a value`, `is too long`, and the same for `SHEP_LIVE_TARGET`), `outcome: refused`, `finished`, says one short line, and does not call itself to the window, read, capture, record or build a provider. If either of the two is unusable the run is refused even when the other is valid; when both are valid the flag wins. With neither supplied the front app is the target, as before. Without `--live-request` the flag is ignored with a `live: ignored:` line. Shep activates the app (`NSRunningApplication.activate`, no scripting bridge), re-checks every 0.25 s for up to 5 s, and looks once more at the instant of submission and again right before the Accessibility read. If the app is not running, is on the never-look list, or is still not in front, the run ends with `live: reason: target: front app is <bundle> not <wanted>` (bundle ids only, never window titles), `outcome: refused`, `finished`, Shep says one short line, and nothing is read, captured or sent to a provider. Without the flag the front app is read, as before, and `live: target: front app is <bundle>` says which. |
| `--capturable` | Keeps Shep's own panels visible to screen recording. |

**A debug dump holds a screenshot of the target window.** Keep it outside the repo and out of version control; the evidence rules above apply (`SHEP_EVIDENCE_DIR`, default `~/shep-evidence`, is a good place). Never attach one to an issue or a commit, and delete it when you are done.

When a live run ends in anything but done, declined or cancelled, the log says why before the outcome line: `[shep] live: ranked: #<mark> <role> "<label>" score=<n>; ...` (the top five candidates, when a request was made) and `[shep] live: reason: <stage>: <cause>` (one line, at most 240 characters, secrets masked), for example `read: could not read the window's controls (no snapshot)`, `capture: no window`, `provider: <error>`, `picker: model chose no control: "<the model's sentence>"`, `picker: failed (<error>); ranking decided`, `ranking: no candidate matched the request words`, `namer: pick did not match any listed control` or `policy: refused (<why>)`.

Log lines, each starting `[shep] live:`: `waiting for Shep to arrive`, `request submitted: <text>`, `approval card shown: <card text>`, `approval answered: approve|cancel` (what the person chose), `outcome: done|declined|cancelled|refused|failed|nothing-to-offer|needs-fresh-approval|busy`, `finished`, and `record-rect` / `backdrop failed: <why>`, and for the recording `recording started`, `record refused: <why>`, `recording discarded: <why>`, `recording written: <path>`, `record note: <text>` (the target window moved; not a stop).

`scripts/record-fix-demo.sh <bundle-id> "<request>" [--seconds N] [--no-record]` refuses apps on the never-capture list, brings the target to the front (`open -b`), prints its window frame, runs `caffeinate -dimsu` for the job only (its own pid), launches Shep with `--live-request ... --live-record <mov> --live-record-seconds N --capturable`, waits for `live: recording written` (or the timeout plus 15 s), and writes `fix-demo-<time>.mov` to the evidence directory (`SHEP_EVIDENCE_DIR`, default `~/shep-evidence`, never the repo) with the log beside it; the clip path is printed last. The evidence folder must be private to you: the script creates it with mode 0700 when it is missing, never changes the mode of an existing one, and (with `stat`, before anything is reserved or launched) refuses with exit 2 and `the output folder is not private to you (<check>)` when it is not owned by you, is group- or other-writable, or has an ancestor that is neither owned by you or root nor free of group/other write (a sticky ancestor such as `/tmp` is fine); the sticky bit is read with `stat -c %a` or, on macOS, `stat -f '%Mp%Lp'`, and a mode that does not report it is treated as not sticky). A person answers the card while it records; the script never does. `--no-record` launches without `--live-record` and logs only. The script no longer records anything itself. The output is `fix-demo-<yyyymmdd-HHMMSS>-<pid>-<4 hex>.mov` with the `.log` of the same stem; both names are reserved before launch (the log exclusively, under `noclobber`) and the script exits 6 if either path already exists. **The script never removes a file**; on a failure it says "no clip" and leaves every path alone. **The clip path is the final path.** Shep (`RecordingSlot`, ShepCore) refuses when anything at all is there (a file, a directory, a symlink, a dangling symlink: `live: record refused: the output path is taken`). Otherwise it records into a private working directory next to it, `.shep-rec-<pid>-<16 hex>` (mode 0700, created exclusively, held open by identity), writes only `<workdir>/clip.mov`, and publishes the finished movie to the final path with `link()`, which fails rather than overwrite anything that appeared meanwhile (then the clip stays in the working directory and the log says where). It then removes only its own clip name and its own working directory, after checking the directory is still the one it made (`unlinkat` on the held descriptor, no symlink is ever followed), and never unlinks the final path. A leftover `.shep-rec-*` directory after a crash is **not** removed automatically; you may remove it yourself once you have looked at it. Claims are exclusive within one process; between two processes the race is decided at the `link()`. The never-capture list is one shell function, `capture_denied` in `scripts/capture-policy-lib.sh`, shared with `scripts/e2e-glimmer.sh`; a ShepCore test checks it against `ControlPolicy.mayCapture`.

The verdict is read from a **structured status file**, not from the human log (which prints the request text and could be forged by it): the script gives Shep `--live-status <file>` (in its private temp directory; Shep creates it exclusively with `O_CREAT|O_EXCL|O_NOFOLLOW`, mode 0600, and refuses if anything is there) and a per-run nonce from `/dev/urandom` in `SHEP_LIVE_NONCE` (also accepted as `--live-nonce`; 16 to 64 characters of `[0-9a-f]`, never printed). Shep appends `<nonce> <event> [<token>]` lines from a closed set (`target-ok`, `target-left`, `request-submitted`, `card-shown`, `answered-approve|answered-cancel`, `outcome-<name>`, `reason-<stage>`, `recording-written`, `recording-discarded [refused]`, `discard-failed`, `discard-unknown`, `recording-already-published`, `finished`); no request or card text ever goes in. The classifier counts only lines that start with `<nonce> ` exactly. An unusable `--live-status` / `--live-nonce` value (or only one of the two) refuses the live run like `--live-target` does; the human log also flattens control characters and newlines in the request. Exit codes of `record-fix-demo.sh`, the same classification in both modes (`scripts/record-fix-lib.sh`), unchanged: **0** the run reached the approval card (and, when recording, the clip was written); **2** usage or preflight (bad arguments or bundle id, never-capture app, app not built, evidence dir in the repo); **3** the target could not be brought up (not frontmost, no window) or left the front during the run (`target-left`, before or after the approval card); **4** no approval card was reached (`outcome: failed` or `nothing-to-offer`, finished or timed out without a card; a dry run that ends here did not reach a card); **5** refused (`reason: target:`, `outcome: refused`, no target app in front, Shep did not arrive, backdrop failed); **6** recording problem (record refused or discarded, `discard-failed`, `discard-unknown`, nothing written in time) or the output name already taken; **7** Shep exited before `live: finished`. Before this change not-frontmost was 7 and a dead Shep was 4.

**A live run stays bound to its target for its whole life** (from `live: target: front app is <bundle>` until `live: finished`; only with `--live-target`). Shep watches the front app (the activation notification plus a 0.25 s poll as backup). If the person moves to another app, even while the approval card waits, the run ends: the card closes and counts as Cancel (nothing waiting for approval is done; a click already under way is still checked by the click guard), a model answer still on its way is dropped, a recording is stopped and discarded, and the log says `live: reason: target: front app is <bundle> not <wanted>`, `outcome: refused`, `finished`, with the status event `target-left` (exit **3**, not 0, even if the card had been shown). The discard is awaited: Shep writes its outcome first (`recording-discarded` only when the clip and its working directory were really removed; `discard-failed` when something could not be removed; `discard-unknown` when it could not confirm the discard within its bounds, namely a recording start still running after 30 s, an end still under way after 25 s, or a stream whose stop did not return within 10 s, in which case a clip or a `.shep-rec-*` directory may remain; `recording-already-published` when the clip had reached its output path before the target left, in which case it stays), and only then `target-left` and `finished`. Shep never says `recording-discarded` or "never started" while a start is in flight: a start that was launched is awaited, and the recorder says never-started only when no start was ever launched. A discard requested while a keep is finalising wins: once the target has left, the clip is never published after that point. `record-fix-demo.sh` does not stop at an outcome: it keeps waiting for `target-left` or `finished` (at most `SHEP_LEFT_DISCARD_WAIT` seconds after the outcome), so an outcome written just before `target-left` still ends in exit **3**, not 6. After `target-left` it waits (same bound; not with `--no-record`) for the outcome and prints one `discard-outcome: discarded|failed|unknown|already-published|shep-exited` line with a sentence; the exit code stays **3** in every case, so read the word: `failed`, `unknown`, `already-published` and `shep-exited` mean a clip or a `.shep-rec-*` directory may remain (`unknown` is Shep's `discard-unknown`, or this script's wait running out; it replaces the earlier word `timeout`). The script does not stop Shep before the outcome is final: on any exit, an interrupt included, with a recording in doubt it waits up to `SHEP_DRAIN_WAIT` seconds (default 60, longer than Shep's own bounds) and, if nothing arrives, stops Shep anyway and prints `discard-outcome: unknown`. The departure is read from the app the activation notification names (not from a later look at the front app), so a leave-and-return that was queued while the main thread was busy still ends the run; the card is also checked against the live front app before it is shown and again after Approve. Shep itself in front (its card taking focus) is not leaving. What already happened is not undone: a screenshot already sent to the provider stays sent. While bound, Shep does not dock to another app, does not read its window through Accessibility (no frame, title or title-bar items), and does not capture it for the tab colour; the overlay is hidden over it. Every tint decision is logged with the bundle id only: `[shep] tint: sampled <bundle>` or `[shep] tint: skipped <bundle or (none)> (not-docked | no-permission | never-capture | live-bound-other-app)`.

`scripts/e2e-glimmer.sh --window` makes ONE `shep-winfo --record <owner> [<title>]` call (id, owner pid, that pid's bundle, frame and title from one window-list snapshot; exit 4 when the match is ambiguous, the pid has no bundle or nothing matches, and there is no untitled fallback), applies `capture_denied` to that record's bundle before `screencapture` runs and before the helper health checks, and then runs, in this order: `shep-winfo --verify <id> <pid> <bundle> <x> <y> <w> <h> <title>` (a fresh snapshot must show that exact window id, owner, bundle, title and integer frame; the title is one argument and may be empty) -> reserve a unique PNG path (`e2e-window-<stamp>-<pid>-<4 hex>.png`, created under `noclobber`; anything already at that name, a dangling link included, refuses and is never touched) -> `screencapture -l <that id>` -> the same full verify again -> only then the app runs. `SHEP_AX_PID` is the record's pid and `SHEP_WINDOW_FRAME` is the verified frame of the record. A denied, unresolved, ambiguous or changed window exits 2 and leaves no PNG; a window that changed between the capture and the second verify exits **8**, the app never runs, and the run removes only the PNG it made itself (after checking that it is a regular file, not a symlink, with the inode recorded right after the capture; if that check fails it removes nothing and says so). **This is not an atomic capture:** no capture API binds the selected object, so the second verify narrows window churn (moved, resized, re-titled or replaced under the same id) and cannot prove that the pixels are of the window that was checked.

**Script tests:** `bash scripts/test-scripts.sh` (plain bash, runs on Linux and on the Mac; fake Shep, `shep-winfo`, `screencapture`, `open`, `caffeinate` and `curl`; canned logs for every exit code; byte-for-byte checks that an existing file survives; the name reservation; the policy list; the order of the policy call and `screencapture` in `e2e-glimmer.sh`; a moved, resized, re-titled or reused window before and after the capture; a foreign PNG at a colliding name; the evidence-folder rule). `scripts/test.sh` runs it before `xcodebuild`. It deletes nothing, its temp directory included.

**How the recording is bound and checked.** The capture policy decides first: `RecordingPolicy.allowed(bundleID:)` is `ControlPolicy.mayCapture`, the function `ScreenCapture.captureWindow` and the tab tint use. A never-capture app, an unknown bundle id, no Screen Recording permission or no target window logs `live: record refused: <why>` and nothing is recorded (the fix still runs). While recording, `RecordingWatch` is polled every 0.25 s: if the target window closes or is minimised, changes owner, the process id now belongs to another app, or the target is no longer allowed, the stream stops and the partial file is deleted (`live: recording discarded: <why>`). Switching to another app is not a stop, because the movie never contains it; moving the target is logged, not a stop. **Permission:** Screen Recording must be allowed for the terminal that launches Shep (Shep inherits it).

### Animation

The head is never still. The page (`tools/shep-dog/src/motion.ts`, `main.ts`) runs one loop: a soft-body idle (scale x and y in anti-phase, a slight lean, ears that lag the head and spring back), random blinks every 2 to 6 seconds with the odd double blink, a rise out of the tab with an overshoot when Shep docks, a slide (not a jump) when the window moves a little, a listening pose (ears perk, head tilts, gentle pulse), a thinking pose (eyes up and sideways, slow bob, animated dots, ear twitches), eyes that follow the pointer, and a stretchy pull on the tab that snaps back. The loop runs at 30 fps, 60 only while a spring runs, and is paused while the panel is hidden or covered or the display sleeps. With Reduce Motion on, only blinks and opacity fades remain (15 fps). The state machine, frame policy and activity rule are pure ShepCore code (`DogMotion.swift`, tested) mirrored by the page.

```sh
scripts/record-demo.sh        # records window + tab (screencapture -v -R) through the --demo-script sequence, prints idle CPU
tools/shep-dog/run-tests.sh   # motion engine and bridge tests (node, no browser)
```

### Fix this screen

Click the dog to type a request (or use the menu item **Fix This Screen** to run it with no request). Shep reads the controls of the front window, takes a screenshot of that window, and asks the vision provider which controls are missing from the app's own list. Each proposal shows in the dog's card with **Approve** / **Cancel**. Nothing is done before you approve:

- an Accessibility press (AXPress / AXConfirm / AXPick) is tried first, text goes in with AXValue only with explicit text;
- a synthetic mouse click happens only after an explicit approval, only when the window has not moved and nothing covers the spot, and it puts the pointer back;
- controls Shep only found on the screenshot, any click, and any click that follows a failed Accessibility press always ask (`ApprovalPolicy`, tested);
- money, sign-in, password and delete controls are refused, and messaging, mail, wallet, terminal and password-manager windows are never captured.

There is no scripting-bridge automation anywhere (`scripts/check-rules.sh`, run by `scripts/test.sh`, and a unit test enforce it).

### Settings

**Settings…** in the menu (Command-comma while the menu is open) opens a small window; every change is saved at once and applied without a restart (`SettingsModel` in ShepCore holds the keys, defaults and validation; the window is SwiftUI):

| Setting | Default | Notes |
|---|---|---|
| Colour | Tangerine | all 12 themes; the doghouse in the window previews the choice |
| Hold to talk | Right Option | Right Option, Right Command or Right Control |
| Call Shep shortcut | Control-Shift-Command-Space | presets only for now; the original Control-Option-Space is listed with its conflicts |
| Speak replies | on | off is the mute toggle; VoiceOver running silences it anyway |
| Glimmer address | `http://127.0.0.1:8080/v1` | local addresses only; **Test** asks `/v1/models`; `SHEP_GLIMMER_URL` at launch still wins |
| Meta (cloud) | read-only | "Available" only when `MODEL_API_KEY` is set; the key is never shown |
| SAM 3 | off | "SAM 3 by Meta, under the SAM License; weights download with your own Hugging Face token." |
| Hide from screen recordings | on | same as the menu item |
| Bark when done | on | one short synthesized woof when a fix finishes |
| Bark volume | 0.6 | slider 0 to 1 |
| Open at login | off | `SMAppService.mainApp` (macOS 13+) |

A note in the window explains that Reduce Motion follows System Settings. Keys: `shep.theme`, `shep.pushToTalkKey`, `shep.callShortcut`, `shep.speakReplies`, `shep.glimmerURL`, `shep.sam3`, `shep.hideFromCapture`, `shep.barkWhenDone`, `shep.barkVolume`, `shep.wakeWord`.

### Voice

Hold **Right Option** (about a quarter of a second; a tap or an Option-character is ignored) and talk. Shep starts listening at once, even if it is still asleep in the doghouse, wakes and crosses the screen while you speak, and shows what it has heard so far in its pill (read-only). When you let go, the final text becomes the request for **Fix This Screen**, and the dog thinks while the pipeline runs. Another key pressed while you hold throws the recording away. Replies are spoken with the system voice (`AVSpeechSynthesizer`); pressing the key again cuts Shep off, so does sending Shep home, **Speak Replies** in the menu mutes it, and with VoiceOver running replies are announced by VoiceOver only. The rules are `VoiceSession` in ShepCore (press, partial, release, final, cancel, timeout, failure, permission denied or not asked yet; tested); recognition is `SFSpeechRecognizer` with `requiresOnDeviceRecognition` when `supportsOnDeviceRecognition`, fed by an `AVAudioEngine` input tap. If Microphone or Speech Recognition is off, Shep says so and opens Setup.

### Calling Shep by voice ("Hey Shep")

Settings > Calling and voice > **Listen for "Hey Shep"** (key `shep.wakeWord`, **off by default**). Turning it on asks for Speech Recognition and Microphone then, and only then; if either is refused the toggle goes back off and Settings says why.

- **What listens.** An `AVAudioEngine` input tap feeds an `SFSpeechRecognizer` request with `requiresOnDeviceRecognition = true`, always. If the recogniser does not support on-device recognition for your language, Shep does not listen and logs `[shep] wake: unavailable (on-device recognition not supported)`; it never falls back to a server. No network, no other model, no extra dependency. Audio is never written to disk.
- **When it listens.** Only when `WakeWordPolicy.shouldListen` says so: the toggle is on, both permissions are granted, on-device recognition works, the talk key is not held, no voice session, spoken reply or fix is going on and Shep is not out of its doghouse, and the Mac is awake. So it listens while Shep sleeps in the doghouse and stops while you talk to Shep or Shep talks.
- **You can see it.** While the microphone is open for the wake word, the menu bar icon is a microphone ("Listening for Hey Shep") instead of the paw, and macOS shows its own orange microphone dot. Both follow the listener's single microphone state.
- **What counts.** `WakeWordMatcher`: case, punctuation and spacing do not matter; a greeting (hey, hay, hei, eh, a) directly followed by a name (shep, shepp, sheppe, shap), as whole words, anywhere in the transcript. "Hey, Shep!", "hay shep" and "a shep" match; "hey chef", "shepherd's pie", "hey sheep", "shep" alone and "hi shep" do not. A transcript that keeps growing reports one match (`WakeWordDetector`, reset for each recognition task).
- **What happens next.** The microphone closes, then the same call path as the talk key runs (`VoiceController.press` and the coordinator call). There is no key to let go of, so the request ends 1.5 s after you stop talking (6 s if nothing was heard). Whatever was said in the same breath as "Hey Shep" is not part of the request: say it after Shep starts listening.
- **Staying up.** The recognition task is replaced every 50 s (the recogniser stops at about a minute) and when it ends; errors retry after 1, 2, 5, 10 then 30 s; the listener stops when the Mac sleeps and restarts on wake, and rebuilds after an audio configuration change.
- **What is logged.** Only `[shep] wake: matched`, `not matched` (a recognition task ended without a match), `listening started`, `listening stopped`, `unavailable (...)` and `error (microphone|engine|recognizer|authorization)`. Never the transcript, never audio.

### Labels and proposals

Every control found on the screenshot gets one role from a fixed list (button, link, tab, checkbox, text field, menu item, icon, static text, image, other), which Glimmer must pick from (JSON schema enum). A box that overlaps a control the app itself lists (IoU 0.3 or more, or sitting inside a comparable-size one) takes that control's Accessibility role and is not listed again. For the rest, guards correct the model: a wide, short box it calls text, a paragraph or a label is static text, and "text field" is accepted only for a field-shaped box with a name that is not a paragraph. Static text, images and "other" are never proposed.

Proposals are ranked, then picked, then capped at three. `ProposalRanker` scores each control from the request (words plus a small synonym table: close/quit/exit, save/store, send/submit, search/find, settings/preferences, back/previous, next/forward, add/new/plus, delete/remove/trash, and more), a role prior, a boost for controls the app lists, and size and position sanity. Window chrome (close, minimize, zoom) and quit controls are never offered unless the request is about them. The best 12 go to Glimmer with mark numbers drawn on the screenshot; it answers with up to three mark numbers (with no request: the single most helpful next step). If the model is down the ranking decides: with a request only controls whose words match, without one the controls found on the screenshot. When nothing fits, there are no proposals and Shep says why. A named target from the naming step still wins. Each proposal still waits for **Approve**.

### Providers

`VisionProvider` is a protocol in ShepCore with these implementations:

| Provider | What | When |
|---|---|---|
| `DetectorVisionProvider` | **Local control finder.** A detector sidecar finds boxes (OmniParser v3, optionally SAM 3), they are merged with the Accessibility tree (IoU de-dup), and Muse Glimmer only *names* what is left and picks the target of a request. Nothing leaves the Mac | default |
| `MetaProvider` | Muse Spark + SAM 3.1 through `MetaClient` (cloud) | `SHEP_PROVIDER=meta` **and** `MODEL_API_KEY` set; also needs the menu switch *Allow Screenshots to Meta Cloud* |
| `FakeProvider` | canned answer for tests | tests only |

Inside the local provider, `DetectorProvider` (sidecar over HTTP, `FakeDetector` for tests) and `ControlNaming` (`GlimmerNamer`, `FakeNamer`) are separate protocols; the merge is pure code in `ControlMerger`. Setup, weights and licences: [docs/detector.md](detector.md).

Glimmer is any OpenAI-compatible server on this Mac. Requests send the screenshot at about 960 px as JPEG, with `reasoning_strength: "none"`, `max_tokens` 1500, temperature 0 and a JSON-schema `response_format` (the strict prompt alone if the server rejects it); one retry on invalid JSON. Boxes on Glimmer's 0 to 1000 scale are converted with `x / 1000 * originalWidth`. Config comes from the environment:

| Variable | Default | |
|---|---|---|
| `SHEP_GLIMMER_URL` | `http://127.0.0.1:8080/v1` | point it at an already-running Glimmer (e.g. llama-server) instead of loading a second copy |
| `SHEP_GLIMMER_MODEL` | `~/models/Muse-Glimmer-30B-4bit` | must equal the mlx_vlm server's `--model`; ignored by llama-server |
| `SHEP_DETECTOR_URL` | `http://127.0.0.1:8765` | the detector sidecar |
| `SHEP_SAM3` | off | `1` opts in to SAM 3 (also needs `--sam3` on the sidecar and your own Hugging Face token) |
| `SHEP_PROVIDER` | `glimmer` | `meta` or `fake` |

```sh
scripts/detector-server.py --omni-weights <icon_detect_v3.torchscript>   # from your own venv, see docs/detector.md
scripts/glimmer-server.sh                    # starts mlx_vlm (refuses under 24 GB free, or if one is already running)
scripts/e2e-glimmer.sh path/to/window.png    # runs the pipeline once on a PNG, prints result and timing
```

The same one-shot is available as `Shep --fix-screen-once <png>`.

Model weights are never in this repository: the user supplies them (`--omni-weights`) or downloads them at runtime (`--omni-repo`, a Hugging Face token for SAM 3). SAM 3 is by Meta under the SAM License, which is not an open-source licence; it is off by default.

Rebuild the dog page (needs Node and a checkout of bloub with `node_modules`): `BLOUB_DIR=/path/to/bloub tools/shep-dog/build.sh`.

The dog page tests (`tools/shep-dog/run-tests.sh`) read `BLOUB_DIR`: set it to your own checkout of [bloub](https://github.com/jeremy-prt/bloub) (branch `dog-goop`), a **sibling checkout outside this repo, not tracked by it**, used as a read-only reference. The scripts' built-in fallback path is one from the original build machine and will not exist on yours. They use `$BLOUB_DIR/node_modules/.bin/jiti`, else the newest `jiti` in its pnpm store (`node_modules/.pnpm/jiti@*/node_modules/jiti/lib/jiti-cli.mjs`, run with node), else print the restore command and exit 2: `cd $BLOUB_DIR && npm_config_manage_package_manager_versions=false npx --yes pnpm@10 install --frozen-lockfile --ignore-scripts` (pnpm 10 with node 20; pnpm 11 needs a newer node).

## Renderer decision

The dog is bloub's "goop dog" embedded in a transparent `WKWebView` from a single prebuilt HTML file, rather than ported to SwiftUI. That keeps pixel parity with the source and costs one JS bridge (`tools/shep-dog/src/main.ts`: theme, state, cards, layout, motion, travel; the motion engine is `motion.ts`, the doghouse is `house.ts` and `house-main.ts`).
