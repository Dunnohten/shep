import Foundation

// Written for Shep.

/// The coordinator's sequence after the provider returns, as one function so a test can run it with a provider it suspends. The gate is
/// read ONCE, right after the await, before anything else happens: a result that arrives after the target left is dropped as a whole
/// (not kept for the closing lines, not written to the debug dump, not offered). Only then are the answer kept, the trace dumped and the
/// result offered, in that order. Code review of 6d026eb/d8213e1: the old order kept the answer and wrote the trace first.
public enum LiveResultFlow {
    @MainActor
    public static func afterProvider<R>(gate: LiveRunGate, produce: () async -> R, keep: (R) -> Void, dump: (R) -> Void,
                                        offer: (R) async -> Void) async {
        let result = await produce()
        let decision = gate.decideResult()
        if !decision.forward { return }
        keep(result)
        if decision.writeDump { dump(result) }
        if !decision.offer { return }
        await offer(result)
    }
}
