import CoreGraphics
import ImageIO
import XCTest
@testable import ShepCore

final class RedactTests: XCTestCase {
    func testKeysAndBearerHeadersAreScrubbed() {
        Redact.register("shep-test-secret-0123456789")
        XCTAssertFalse(Redact.scrub("failed with shep-test-secret-0123456789 here").contains("0123456789"))
        XCTAssertFalse(Redact.scrub("Authorization: Bearer abcdefghijklmnop").contains("abcdefghijklmnop"))
        XCTAssertFalse(Redact.scrub("https://x.example/a?token=zzzzzzzzzzzz").contains("zzzzzzzzzzzz"))
        XCTAssertEqual(Redact.scrub("plain words"), "plain words")
    }

    func testRegisteredSecretIsMaskedEverywhereAndShortOnesAreIgnored() {
        Redact.register("  registered-key-98765  ")
        let out = Redact.scrub("a registered-key-98765 b registered-key-98765")
        XCTAssertEqual(out, "a \(Redact.mask) b \(Redact.mask)")
        Redact.register("")
        Redact.register("abc")
        XCTAssertEqual(Redact.scrub("abc and the empty string stay"), "abc and the empty string stay")
    }

    func testKeyShapesAreMasked() {
        for key in ["sk-proj-abcdefghijklmnop1234", "hf_abcdefghijklmnopqrst", "0123456789abcdef0123456789abcdef"] {
            let out = Redact.scrub("error with \(key) in it")
            XCTAssertFalse(out.contains(key), key)
            XCTAssertTrue(out.contains(Redact.mask), key)
        }
        let long = "Zm9vYmFyMTIzNDU2Nzg5MGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6"
        XCTAssertFalse(Redact.scrub("blob \(long) end").contains(long))
    }

    func testOrdinaryTextAndPathsSurvive() {
        let text = "Could not reach 127.0.0.1:8080 for /Users/me/Library/Application Support/Shep/models"
        XCTAssertEqual(Redact.scrub(text), text)
        XCTAssertEqual(Redact.scrub("a-very-long-hyphenated-words-only-no-digits-at-all-here"), "a-very-long-hyphenated-words-only-no-digits-at-all-here")
    }

    func testScrubIsIdempotent() {
        let once = Redact.scrub("Authorization: Bearer abcdefghijklmnop")
        XCTAssertEqual(Redact.scrub(once), once)
    }
}

final class ScreenshotFilesTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_000_000)
    func entry(_ name: String, _ offset: TimeInterval, regular: Bool = true, link: Bool = false) -> ScreenshotEntry {
        ScreenshotEntry(name: name, created: start.addingTimeInterval(offset), isRegularFile: regular, isSymbolicLink: link)
    }

    func testOnlyImagesCreatedAfterTheRequestStartAreTakenAndTheNewestWins() {
        let files = [entry("before.png", -5), entry("a.png", 3), entry("new.PNG", 50), entry("notes.txt", 500), entry("mid.heic", 10)]
        XCTAssertEqual(ScreenshotFiles.newestSince(start, in: files), "new.PNG")
        XCTAssertEqual(ScreenshotFiles.newestSince(start, in: [entry("at-start.png", 0)]), "at-start.png")
    }

    func testAnUnrelatedRecentPersonalImageFromBeforeTheRequestIsNeverPicked() {
        let files = [entry("holiday-photo.jpg", -60), entry("Screenshot old.png", -3600)]
        XCTAssertNil(ScreenshotFiles.newestSince(start, in: files))
    }

    func testSymlinksDirectoriesAndNonImagesAreSkipped() {
        let files = [entry("link.png", 10, link: true), entry("folder.png", 20, regular: false), entry("notes.txt", 30), entry("noext", 40)]
        XCTAssertNil(ScreenshotFiles.newestSince(start, in: files))
        XCTAssertEqual(ScreenshotFiles.newestSince(start, in: files + [entry("real.jpg", 5)]), "real.jpg")
    }

    func testNothingIsPickedFromAnEmptyListing() {
        XCTAssertNil(ScreenshotFiles.newestSince(start, in: []))
    }

    func testAnExplicitChoiceMustBeAReadableImageInTheListing() {
        let files = [entry("old-but-chosen.png", -9999), entry("link.png", 1, link: true), entry("dir.png", 1, regular: false), entry("a.txt", 1)]
        XCTAssertEqual(ScreenshotFiles.chosen("old-but-chosen.png", in: files), "old-but-chosen.png")
        for name in ["link.png", "dir.png", "a.txt", "missing.png"] { XCTAssertNil(ScreenshotFiles.chosen(name, in: files), name) }
    }

    func testAllImageExtensionsCountCaseInsensitively() {
        for n in ["a.png", "a.JPG", "a.jpeg", "a.HEIC", "a.tiff"] { XCTAssertTrue(ScreenshotFiles.isImage(n), n) }
        XCTAssertFalse(ScreenshotFiles.isImage("a.gif"))
    }
}

final class ImagePreparationTests: XCTestCase {
    func testTargetSizeScalesTheLongestSideAndNeverEnlarges() {
        XCTAssertEqual(ImageIOPreparer.targetSize(for: CGSize(width: 3024, height: 1964), longestSide: 960), CGSize(width: 960, height: 623))
        XCTAssertEqual(ImageIOPreparer.targetSize(for: CGSize(width: 800, height: 600), longestSide: 960), CGSize(width: 800, height: 600))
        XCTAssertEqual(ImageIOPreparer.targetSize(for: CGSize(width: 600, height: 2400), longestSide: 960), CGSize(width: 240, height: 960))
        XCTAssertEqual(ImageIOPreparer.targetSize(for: .zero, longestSide: 960), CGSize(width: 1, height: 1))
    }

    func testPNGBecomesASmallerJPEG() throws {
        let w = 2000, h = 1000
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let image = try XCTUnwrap(ctx.makeImage())
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let prepared = try XCTUnwrap(ImageIOPreparer().prepare(png: out as Data, longestSide: 500, quality: 0.7))
        XCTAssertEqual(prepared.originalSize, CGSize(width: 2000, height: 1000))
        XCTAssertEqual(prepared.size, CGSize(width: 500, height: 250))
        XCTAssertEqual(Array(prepared.jpeg.prefix(2)), [0xFF, 0xD8], "JPEG magic")
        XCTAssertNil(ImageIOPreparer().prepare(png: Data([1, 2, 3]), longestSide: 500, quality: 0.7))
    }
}

/// Rules from the brief, enforced on the source tree: no scripting-bridge automation anywhere, and no other local model.

final class SourceRulesTests: XCTestCase {
    func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func swiftSources(under dirs: [String]) throws -> [(URL, String)] {
        var out: [(URL, String)] = []
        for d in dirs {
            let dir = repoRoot().appendingPathComponent(d)
            guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                out.append((url, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return out
    }

    func testNoAppleScriptAnywhereInTheApp() throws {
        let files = try swiftSources(under: ["Shep", "ShepCore/Sources"])
        try XCTSkipIf(files.isEmpty, "source tree not reachable from the test bundle")
        // Built from pieces so this file does not match its own rule.
        let banned = ["osa" + "script", "NSApple" + "Script", "Apple" + "Script", "OSA" + "Script", "NSUserApple" + "ScriptTask"]
        for (url, text) in files {
            let lower = text.lowercased()
            for b in banned { XCTAssertFalse(lower.contains(b.lowercased()), "\(url.lastPathComponent) mentions \(b)") }
        }
    }

    func testTheAppNeverTalksToAnotherLocalModel() throws {
        let files = try swiftSources(under: ["Shep"])
        try XCTSkipIf(files.isEmpty, "source tree not reachable from the test bundle")
        for (url, text) in files {
            XCTAssertFalse(text.contains("11" + "234"), url.lastPathComponent)
        }
    }

    /// Every tracked or new file under the repo (not build output, not .git) holds no banned token. The tokens are stored only as hashes in
    /// scripts/banned-token-hashes.txt; this test and scripts/check-banned-tokens.py use the same tokenizer.
    func testNoFileInTheTreeHoldsABannedToken() throws {
        let root = repoRoot()
        let hashFile = root.appendingPathComponent("scripts/banned-token-hashes.txt")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: hashFile.path), "source tree not reachable from the test bundle")
        let hashes = BannedTokenScan.hashes(inListing: try String(contentsOf: hashFile, encoding: .utf8))
        XCTAssertFalse(hashes.isEmpty, "the hash list is empty")
        var checked = 0
        for folder in ["Shep", "ShepCore", "scripts", "tools", "docs", "Config", "Resources"] {
            guard let walker = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where ["swift", "sh", "py", "md", "yml", "json", "txt", "html", "ts", "js"].contains(url.pathExtension) {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                checked += 1
                XCTAssertFalse(BannedTokenScan.contains(text, hashes: hashes), url.lastPathComponent)
            }
        }
        for name in ["README.md", "LESSONS.md", "NOTICE", "project.yml"] {
            if let text = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) {
                checked += 1
                XCTAssertFalse(BannedTokenScan.contains(text, hashes: hashes), name)
            }
        }
        try XCTSkipIf(checked == 0, "source tree not reachable from the test bundle")
    }

    /// The checker itself, with a harmless token whose hash is in a test-only list: a file holding it is flagged, a file without it is not.
    /// The token is found as a word, inside punctuation, in a different case and as a part of a camel-case compound, but not inside a
    /// longer word; a banned number is found only as a whole digit run.
    func testTheCheckerFlagsAFileHoldingATokenFromItsList() throws {
        let harmless = BannedTokenScan.hashes(inListing: "# test-only list\n11 0184a519a036e2f74423335947ea4a0e009899c6e7d2525f85073f4a26dbbc20\n")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shep-banned-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dirty = dir.appendingPathComponent("dirty.txt")
        let clean = dir.appendingPathComponent("clean.txt")
        try "some text, then gigglesnort-3 and more".write(to: dirty, atomically: true, encoding: .utf8)
        try "nothing to see here, giggle and snort apart".write(to: clean, atomically: true, encoding: .utf8)
        XCTAssertTrue(BannedTokenScan.contains(try String(contentsOf: dirty, encoding: .utf8), hashes: harmless), "a file holding the token is flagged")
        XCTAssertFalse(BannedTokenScan.contains(try String(contentsOf: clean, encoding: .utf8), hashes: harmless), "a file without it is not")
        XCTAssertTrue(BannedTokenScan.contains("(GIGGLESNORT)", hashes: harmless))
        XCTAssertTrue(BannedTokenScan.contains("model GiggleSnort", hashes: harmless))
        XCTAssertFalse(BannedTokenScan.contains("gigglesnorts and xgigglesnort", hashes: harmless), "a longer word is a different word")
        let digits = BannedTokenScan.hashes(inListing: "5 \(BannedTokenScan.sha256Hex("90210"))")
        XCTAssertTrue(BannedTokenScan.contains("port 90210/v1", hashes: digits))
        XCTAssertFalse(BannedTokenScan.contains("port 902101 and 190210", hashes: digits), "a longer digit run is a different number")
    }

    /// The real list holds the banned tokens as hashes only: two lines, nothing else that could be read back as a word.
    func testTheHashListHoldsHexOnly() throws {
        let text = try String(contentsOf: repoRoot().appendingPathComponent("scripts/banned-token-hashes.txt"), encoding: .utf8)
        let entries = text.split(whereSeparator: { $0.isNewline }).filter { !$0.hasPrefix("#") }
        XCTAssertFalse(entries.isEmpty)
        for line in entries {
            let parts = line.split(separator: " ")
            XCTAssertEqual(parts.count, 2, String(line))
            XCTAssertEqual(parts.last?.count, 64)
            XCTAssertTrue(parts.last?.allSatisfy { $0.isHexDigit } ?? false)
        }
    }

    func testTheLabelModelIsAMetaModel() throws {
        XCTAssertEqual(LabelModelConfig.glimmer().baseURL.host, "127.0.0.1")
        XCTAssertTrue(LabelModelConfig.glimmer().model.contains("Glimmer"))
        XCTAssertEqual(LabelModelConfig.spark().baseURL.host, "api.meta.ai")
        XCTAssertTrue(LabelModelConfig.spark().model.hasPrefix("muse-spark"))
    }
}
