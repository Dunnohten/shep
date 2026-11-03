import XCTest
@testable import ShepCore

/// The in-repo test window (tools/fixscreen-fixture) and the synthetic tree the unit tests use describe the same controls.
final class LabelFixtureSourceTests: XCTestCase {
    func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("tools/fixscreen-fixture/FixtureApp.swift")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture source not reachable from the test bundle") }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func identifiers(in text: String) -> Set<String> {
        var out = Set<String>()
        let pattern = try! NSRegularExpression(pattern: "\"(btnPlay|u[0-9]+|l[0-9]+)\"")
        for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let r = Range(m.range(at: 1), in: text) { out.insert(String(text[r])) }
        }
        return out
    }

    func treeIdentifiers() -> Set<String> {
        var out = Set<String>()
        func walk(_ n: LabelTestNode) {
            if !n.identifier.isEmpty { out.insert(n.identifier) }
            n.kids.forEach(walk)
        }
        walk(LabelFixture.tree())
        return out.filter { !$0.hasPrefix("s") }
    }

    func testTheWindowHasAtLeastTenOfEachKind() throws {
        let s = try source()
        XCTAssertGreaterThanOrEqual(s.components(separatedBy: "// unlabeled:").count - 1, 10)
        XCTAssertGreaterThanOrEqual(s.components(separatedBy: "// labeled:").count - 1, 10)
        XCTAssertTrue(s.contains("Shep Label Fixture"))
    }

    func testTheWindowAndTheSyntheticTreeUseTheSameIdentifiers() throws {
        XCTAssertEqual(identifiers(in: try source()), treeIdentifiers())
    }

    func testTheFixtureNamesNoPersonalDataAndOpensNoNetwork() throws {
        let s = try source().lowercased()
        for banned in ["http://", "https://", "urlsession", "@gmail", "/users/"] { XCTAssertFalse(s.contains(banned), banned) }
    }
}
