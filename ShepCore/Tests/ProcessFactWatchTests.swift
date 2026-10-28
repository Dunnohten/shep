import CoreGraphics
import Darwin
import XCTest
@testable import ShepCore

/// Code review F5: the recording watch carries what is known about the target's process (alive, confirmed terminated, unknown).
/// `pid-gone` is logged, and the recording stopped at once, only on confirmed termination; an empty bundle lookup for a
/// process not known to be gone keeps its six-check tolerance and its `bundle-empty` reason.
final class ProcessFactWatchTests: XCTestCase {
    let target = RecordingTarget(pid: 4242, windowID: 7125, bundleID: "org.m0k.transmission", frame: CGRect(x: 0, y: 0, width: 800, height: 600))

    func obs(onScreen: Bool = true, owner: Int32? = 4242, bundle: String? = "org.m0k.transmission", process: ProcessFact) -> RecordingObservation {
        RecordingObservation(windowOnScreen: onScreen, windowOwnerPID: owner, bundleIDForTargetPID: bundle, frontPID: 1, frontBundleID: "com.apple.finder",
                             frame: target.frame, process: process)
    }

    // MARK: the fact itself

    func testTerminationIsConfirmedOnlyByIsTerminatedOrESRCH() {
        XCTAssertEqual(ProcessFact.classify(runningIsTerminated: false, killResult: 0, killErrno: 0), .alive)
        XCTAssertEqual(ProcessFact.classify(runningIsTerminated: true, killResult: 0, killErrno: 0), .terminated)
        XCTAssertEqual(ProcessFact.classify(runningIsTerminated: nil, killResult: -1, killErrno: ESRCH), .terminated)
        XCTAssertEqual(ProcessFact.classify(runningIsTerminated: nil, killResult: 0, killErrno: 0), .alive, "the process exists")
        XCTAssertEqual(ProcessFact.classify(runningIsTerminated: nil, killResult: -1, killErrno: EPERM), .alive, "exists, not ours to signal")
        XCTAssertEqual(ProcessFact.classify(runningIsTerminated: nil, killResult: -1, killErrno: EINVAL), .unknown)
    }

    func testObservePassesTheFactThrough() {
        let window = RecordingWindowEntry(id: 7125, ownerPID: 4242, bounds: target.frame)
        for fact in ProcessFact.allCases {
            let now = RecordingWatch.observe(target: target, windows: [window], bundleForPID: { _ in nil }, pidsForBundle: { _ in [] },
                                             frontPID: nil, frontBundleID: nil, processFact: { pid in pid == 4242 ? fact : .alive })
            XCTAssertEqual(now.process, fact)
        }
    }

    // MARK: the reason

    func testPidGoneOnlyOnConfirmedTermination() {
        XCTAssertEqual(RecordingWatchLog.reason(target: target, now: obs(onScreen: false, owner: nil, bundle: nil, process: .terminated), moved: false), .pidGone,
                       "a confirmed exit names itself even though the window went with it")
        XCTAssertEqual(RecordingWatchLog.reason(target: target, now: obs(bundle: nil, process: .terminated), moved: false), .pidGone)
        XCTAssertEqual(RecordingWatchLog.reason(target: target, now: obs(bundle: nil, process: .unknown), moved: false), .bundleEmpty)
        XCTAssertEqual(RecordingWatchLog.reason(target: target, now: obs(bundle: nil, process: .alive), moved: false), .bundleEmpty)
        XCTAssertEqual(RecordingWatchLog.reason(target: target, now: obs(onScreen: false, owner: nil, bundle: nil, process: .unknown), moved: false), .windowMissing)
        XCTAssertEqual(RecordingWatchLog.reason(target: target, now: obs(process: .alive), moved: false), .ok)
    }

    func testThePidGoneTokenIsPinned() {
        XCTAssertEqual(WatchReason.pidGone.rawValue, "pid-gone")
        XCTAssertEqual(RecordingWatchLog.line(t: 2, alive: false, reason: .pidGone), "[shep] live: watch t=2.00 alive=no reason=pid-gone")
    }

    // MARK: the verdict

    func testAConfirmedExitStopsAtOnce() {
        var state = RecordingWatchState()
        XCTAssertEqual(state.verdict(target: target, now: obs(bundle: nil, process: .terminated)), .stop(RecordingWatch.processEnded))
        state = RecordingWatchState()
        XCTAssertEqual(state.verdict(target: target, now: obs(onScreen: false, owner: nil, bundle: nil, process: .terminated)), .stop(RecordingWatch.processEnded))
    }

    func testAnEmptyLookupKeepsItsSixCheckTolerance() {
        for fact in [ProcessFact.unknown, .alive] {
            var state = RecordingWatchState()
            for i in 1..<RecordingWatchState.unresolvedLimit {
                XCTAssertEqual(state.verdict(target: target, now: obs(bundle: nil, process: fact)), .keep, "check \(i), \(fact)")
            }
            guard case .stop(let why) = state.verdict(target: target, now: obs(bundle: nil, process: fact)) else { return XCTFail("\(fact)") }
            XCTAssertTrue(why.hasPrefix("could not confirm"), why)
            XCTAssertNotEqual(why, RecordingWatch.processEnded)
        }
        XCTAssertEqual(RecordingWatchState.unresolvedLimit, 6)
    }

    func testTheEndedReasonSaysWhatWasConfirmed() {
        XCTAssertEqual(RecordingWatch.processEnded, "the target app quit (its process ended)")
    }
}
