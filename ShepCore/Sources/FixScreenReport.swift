import Foundation

/// Plain-text report for `--fix-screen-once` and scripts/e2e-glimmer.sh.
public enum FixScreenReport {
    public static func render(_ r: FixScreenResult, seconds: Double) -> String {
        var lines: [String] = []
        lines.append("provider: \(r.provider)")
        switch r.status {
        case .ok: lines.append("status: ok")
        case .notAllowed(let why): lines.append("status: not allowed (\(why))")
        case .failed(let why): lines.append("status: failed (\(why))")
        }
        lines.append("summary: \(r.summary)")
        lines.append("controls: \(r.controls.count) (\(r.foundCount) found on screen)")
        for c in r.controls {
            let f = c.frame.map { " at (\(ControlFilter.int($0.minX)),\(ControlFilter.int($0.minY)) \(ControlFilter.int($0.width))x\(ControlFilter.int($0.height)))" } ?? ""
            lines.append("  \(c.line)\(f)")
        }
        lines.append("proposals: \(r.proposals.count)")
        for p in r.proposals {
            let need: String
            switch p.requirement {
            case .refused(let why): need = "refused: \(why)"
            case .required(let why): need = why.isEmpty ? "needs approval" : "needs approval: \(why)"
            }
            lines.append("  \(p.action.summary) [\(need)]")
        }
        if r.proposals.isEmpty, !r.explanation.isEmpty { lines.append("none: \(r.explanation)") }
        for n in r.notes { lines.append("note: \(n)") }
        lines.append(String(format: "time: %.2f s", seconds))
        return lines.joined(separator: "\n")
    }
}
