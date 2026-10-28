import CoreGraphics
import Foundation

// Written for Shep.

/// `--live-debug-dir <dir>` (SHEP_LIVE_DEBUG_DIR): an opt-in dump of what a live run handed to the provider and decided, so the
/// difference between two runs can be diagnosed. The pure parts live here: which directories are refused, the folder name and the
/// text of the files. The app writes the files (Shep/LiveDebugDump.swift).
///
/// A dump holds a screenshot of the target window (`input.png`: the exact image handed to the provider, raw pixels, not text and not
/// sanitised, mode 0600, written only after the gate allowed sending it): it belongs outside the repository and outside version
/// control. The text files are scrubbed of secrets and have capped lines; they can still hold private text.
public enum LiveDebug {
    /// The files written per run, in `<dir>/<yyyyMMdd-HHmmss>/`.
    public static let fileNames = ["input.png", "ax-controls.txt", "trace.txt", "request.txt"]

    // MARK: the directory

    /// An absolute path with `~` expanded and `.`, `..` and repeated slashes resolved; nil for a relative, empty or NUL-holding path.
    public static func normalizedPath(_ path: String, home: String) -> String? {
        var text = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.contains("\u{0}") { return nil }
        if text == "~" { text = home }
        else if text.hasPrefix("~/") { text = home + "/" + String(text.dropFirst(2)) }
        guard text.hasPrefix("/") else { return nil }
        var parts: [String] = []
        for piece in text.split(separator: "/", omittingEmptySubsequences: true) {
            if piece == "." { continue }
            if piece == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(String(piece))
        }
        return "/" + parts.joined(separator: "/")
    }

    /// `path` itself or the nearest ancestor that holds a `.git` (`hasGit` answers for one directory); nil when none does.
    public static func enclosingGitRoot(of path: String, hasGit: (String) -> Bool) -> String? {
        var current = path
        while true {
            if hasGit(current) { return current }
            if current == "/" || current.isEmpty { return nil }
            guard let slash = current.lastIndex(of: "/") else { return nil }
            current = slash == current.startIndex ? "/" : String(current[current.startIndex..<slash])
        }
    }

    /// True when `path` is `root` or lies below it.
    static func isInside(_ path: String, root: String) -> Bool {
        if root == "/" { return true }
        return path == root || path.hasPrefix(root + "/")
    }

    /// Why a dump may not go to `path`, or nil when it may. Refused: a relative path, the root of the disk, anything inside the
    /// checkout of the running app (`appBundlePath` is where the app sits), and anything inside a directory that holds a `.git`.
    /// Symlinks are the caller's business: pass the resolved path.
    public static func refusal(path: String, home: String, appBundlePath: String?, hasGit: (String) -> Bool) -> String? {
        guard let normal = normalizedPath(path, home: home) else {
            return "the path must be absolute (or start with ~/)"
        }
        if normal == "/" { return "that is the root of the disk" }
        if let app = appBundlePath, let appPath = normalizedPath(app, home: home),
           let checkout = enclosingGitRoot(of: appPath, hasGit: hasGit), isInside(normal, root: checkout) {
            return "that is inside the app's own repository checkout (\(checkout)); a dump holds a screenshot, keep it outside the repo"
        }
        if let root = enclosingGitRoot(of: normal, hasGit: hasGit) {
            return "that is inside a git checkout (\(root)); a dump holds a screenshot, keep it out of version control"
        }
        return nil
    }

    /// `yyyyMMdd-HHmmss` in `timeZone`.
    public static func runDirectoryName(date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    // MARK: the files

    /// The longest line in any dump text file.
    public static let lineLimit = 400
    /// The longest single field (label, role, source) in `ax-controls.txt`.
    static let fieldLimit = 120

    /// Secrets and key-shaped strings masked, whitespace runs (newlines too) folded into single spaces, cut at `limit` characters
    /// with an ellipsis. One line out, whatever came in.
    static func scrubbedLine(_ text: String, limit: Int) -> String {
        let folded = Redact.scrub(text).split(whereSeparator: { ch in ch.isWhitespace || ch.isNewline }).joined(separator: " ")
        return folded.count > limit ? String(folded.prefix(limit)) + "\u{2026}" : folded
    }

    /// `text` scrubbed, with every line cut at `lineLimit`. Line breaks are kept.
    static func scrubbedText(_ text: String) -> String {
        let lines = Redact.scrub(text).components(separatedBy: "\n").map { line -> String in
            line.count > lineLimit ? String(line.prefix(lineLimit)) + "\u{2026}" : line
        }
        return lines.joined(separator: "\n")
    }

    /// The prepared Accessibility controls: role, label, where the label came from, frame. Every string is scrubbed and capped.
    /// A named field's value is left out, but a static text's label can derive from its value, and titles, descriptions and help
    /// can hold private text: this file is opt-in raw evidence, scrubbed for secrets only, not for personal text.
    public static func axControlsText(_ controls: [Control]) -> String {
        if controls.isEmpty { return "no Accessibility controls were handed to the provider\n" }
        var lines: [String] = []
        for c in controls {
            let role = scrubbedLine(c.role, limit: fieldLimit)
            let label = scrubbedLine(c.label, limit: fieldLimit)
            let source = scrubbedLine(c.labelSource.rawValue, limit: fieldLimit)
            let line = "#\(c.index) \(role) \"\(label)\" source=\(source) frame=\(AXReadReport.frameText(c.frame))"
            lines.append(scrubbedLine(line, limit: lineLimit))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// What the pipeline recorded: the namer's pick, the counts, the ranked list with scores, the picker's marks, explanation or
    /// error, then the status and notes. Secrets are masked.
    /// `focus` is how the target window was chosen (source, sampled VoiceOver flag, fall-through reasons); omitted when unknown.
    public static func traceText(_ result: FixScreenResult, focus: FocusTargetSample? = nil) -> String {
        let t = result.trace
        var lines: [String] = []
        lines.append("request: " + (t.hadRequest ? "yes" : "no"))
        if let focus { lines.append(focus.traceLine) }
        if let space = t.space { lines.append(spaceLine(space)) }
        if let box = t.namerTargetBox {
            lines.append("namer: pick box=\(AXReadReport.frameText(box)) matched=\(AXReadReport.yesNo(t.namerMatched)) "
                         + "ambiguous=\(AXReadReport.yesNo(t.namerAmbiguous)) refused=\(AXReadReport.yesNo(t.namerRefused))")
            lines.append(namerPickLine(box, trace: t))
            lines.append(namerMatchLine(t))
        } else {
            lines.append("namer: no pick")
        }
        lines += detectorLines(t.detector)
        lines.append("counts: ax=\(t.axCount) found=\(t.foundCount) ranked=\(t.rankedCount) chosen=\(t.chosenCount) dropped-by-policy=\(t.droppedByPolicy)")
        if t.ranked.isEmpty {
            lines.append("ranked: none")
        } else {
            lines.append("ranked (best first, top \(t.ranked.count) of \(t.rankedCount)):")
            for c in t.ranked {
                lines.append("  #\(c.mark) \(c.role) \"\(c.label)\" score=\(String(format: "%.2f", c.matchScore)) source=\(c.fromVision ? "found" : "ax")")
            }
        }
        if t.pickerUsed {
            lines.append("picker: marks=\(t.pickerMarks) explanation=\"\(t.pickerExplanation)\"")
        } else if let error = t.pickerError {
            lines.append("picker: error=\"\(error)\"")
        } else {
            lines.append("picker: not used")
        }
        if let offer = t.strongMatchOffer { lines.append("offer: \(offer)") }
        switch result.status {
        case .ok: lines.append("status: ok")
        case .notAllowed(let why): lines.append("status: not allowed (\(why))")
        case .failed(let why): lines.append("status: failed (\(why))")
        }
        lines.append("proposals: \(result.proposals.count)")
        for n in result.notes { lines.append("note: \(n)") }
        if result.proposals.isEmpty, !result.explanation.isEmpty { lines.append("none: \(result.explanation)") }
        return scrubbedText(lines.joined(separator: "\n")) + "\n"
    }

    static func sizeText(_ s: CGSize) -> String { "\(ControlFilter.int(s.width))x\(ControlFilter.int(s.height))" }
    static func scaleText(_ v: Double) -> String { String(format: "%.2f", v.isFinite ? v : 0) }

    /// `space: image=1041x922 px window=-337,-1020,1041,922 pt scale=1.00x1.00 measured (fallback 2.00 unused) sent=960x850 px`
    static func spaceLine(_ s: TraceSpace) -> String {
        let how = s.measured ? "measured (fallback \(scaleText(s.fallbackScale)) unused)" : "fallback"
        var line = "space: image=\(sizeText(s.imageSize)) px window=\(AXReadReport.frameText(s.windowFrame)) pt "
            + "scale=\(scaleText(s.scaleX))x\(scaleText(s.scaleY)) \(how)"
        if let sent = s.sentSize { line += " sent=\(sizeText(sent)) px" }
        return line
    }

    /// The pick in pixels, window points and screen points, and where it came from.
    static func namerPickLine(_ box: CGRect, trace t: FixScreenTrace) -> String {
        var line = "namer: pick px=\(AXReadReport.frameText(box))"
        if let s = t.space, s.scaleX > 0, s.scaleY > 0 {
            let w = CGRect(x: box.minX / CGFloat(s.scaleX), y: box.minY / CGFloat(s.scaleY),
                           width: box.width / CGFloat(s.scaleX), height: box.height / CGFloat(s.scaleY))
            let screen = w.offsetBy(dx: s.windowFrame.minX, dy: s.windowFrame.minY)
            line += " window-pt=\(AXReadReport.frameText(w)) screen-pt=\(AXReadReport.frameText(screen))"
        }
        let from: String
        switch t.detector.namerSource {
        case .candidate(let id)?: from = "candidate #\(id)"
        case .modelBoxOnCandidate(let id)?: from = "model-box on candidate #\(id)"
        case .modelBox?: from = "model-box"
        case nil: from = "provider"
        }
        return line + " from=" + from
    }

    /// `namer: matched ax #16 AXCheckBox "..." used=yes`, `namer: matched screenshot-only AXButton "..." used=no` or `namer: matched none`.
    static func namerMatchLine(_ t: FixScreenTrace) -> String {
        let used = " used=" + AXReadReport.yesNo(t.namerMatched)
        switch t.namerMatch {
        case .ax(let index, let role, let label)?:
            return "namer: matched ax #\(index) \(scrubbedLine(role, limit: fieldLimit)) \"\(scrubbedLine(label, limit: fieldLimit))\"" + used
        case .screenshotOnly(let role, let label)?:
            return "namer: matched screenshot-only \(scrubbedLine(role, limit: fieldLimit)) \"\(scrubbedLine(label, limit: fieldLimit))\"" + used
        case nil:
            return "namer: matched none"
        }
    }

    /// `detector: n box(es)` and one line per box (none when no detector ran). No caption: it is read off the screen.
    static func detectorLines(_ d: AnalysisDebug) -> [String] {
        guard d.detectorCount > 0 else { return [] }
        var lines = ["detector: \(d.detectorCount) box(es)"]
        for (i, b) in d.detectorBoxes.enumerated() {
            let ax = b.axAmbiguous ? "ambiguous" : (b.axIndex.map { "#\($0)" } ?? "-")
            var line = "  d\(i + 1) px=\(AXReadReport.frameText(b.pixelBox)) window-pt=\(AXReadReport.frameText(b.windowBox)) "
                + "kind=\(scrubbedLine(b.kind.isEmpty ? "-" : b.kind, limit: TraceDetectorBox.kindLimit)) score=\(scaleText(b.score)) "
                + "ax=\(ax) candidate=\(b.candidate.map { "#\($0)" } ?? "-")"
            if !b.label.isEmpty { line += " label=\"\(scrubbedLine(b.label, limit: TraceRankedControl.labelLimit))\"" }
            line += " offered=" + AXReadReport.yesNo(b.offered)
            lines.append(line)   // every field is already one scrubbed line; traceText caps the length
        }
        if d.detectorCount > d.detectorBoxes.count { lines.append("  (\(d.detectorCount - d.detectorBoxes.count) more not shown)") }
        return lines
    }

    /// The request the run was given.
    public static func requestText(_ request: String?) -> String {
        let t = (request ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return scrubbedText(t.isEmpty ? "(no request)" : t) + "\n"
    }

    // MARK: when the dump may start

    /// Writes this run's three input files, but only when the pipeline's gate has allowed sending (`gate` is nil). Called before
    /// anything is created: `begin` (which makes the run's directory) is not called at all when the gate refuses, so a run that is
    /// never sent leaves nothing on disk. `input.png` is the exact image handed to the provider (raw pixels, not text, not
    /// sanitised); the text files are scrubbed. Returns the open dump so the caller can add `trace.txt`, or nil.
    public static func dumpInputs(gate: FixScreenResult.Status?, begin: () -> LiveDebugSink?, png: Data, axControls: [Control],
                                  request: String?) -> LiveDebugSink? {
        guard gate == nil else { return nil }
        guard let sink = begin() else { return nil }
        sink.write("input.png", png)
        sink.write("ax-controls.txt", text: axControlsText(axControls))
        sink.write("request.txt", text: requestText(request))
        return sink
    }
}

/// Where a debug dump goes (Shep/LiveDebugDump.swift writes files; tests spy).
public protocol LiveDebugSink: AnyObject {
    func write(_ name: String, _ data: Data)
    func write(_ name: String, text: String)
    func announce()
}
