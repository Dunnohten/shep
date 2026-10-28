import AppKit
import ShepCore
import Vision

// Written for Shep.

/// Finds the screenshot taken after a request began (or one the person chose) and reads the text in it. Not wired to a feature yet.
enum ScreenshotExtractor {
    enum ExtractError: LocalizedError {
        case none(String)
        case folderUnreadable(String)
        case unreadable
        case noText

        var errorDescription: String? {
            switch self {
            case .none(let folder): return "I found no new screenshot in \(folder)."
            case .folderUnreadable(let folder): return "I could not read the folder \(folder)."
            case .unreadable: return "I could not open that screenshot."
            case .noText: return "I found no text in that screenshot."
            }
        }
    }

    /// Where macOS saves screenshots: the `com.apple.screencapture` "location" default, else the Desktop.
    static var screenshotFolder: URL {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        guard let raw = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !raw.isEmpty else {
            return desktop
        }
        let path = (raw as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return desktop }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The screenshot taken after `requestStart` (newest if several). An older image in the folder, a link, or anything that
    /// is not a regular image file is never taken; for those the person has to choose the file (`screenshot(named:)`).
    static func newestScreenshot(since requestStart: Date) throws -> URL {
        let folder = screenshotFolder
        let entries = try listing(of: folder)
        guard let name = ScreenshotFiles.newestSince(requestStart, in: entries) else { throw ExtractError.none(folder.path) }
        return folder.appendingPathComponent(name)
    }

    /// A file the person picked by name in the screenshot folder. Same checks as above, but any age.
    static func screenshot(named name: String) throws -> URL {
        let folder = screenshotFolder
        let entries = try listing(of: folder)
        guard let chosen = ScreenshotFiles.chosen(name, in: entries) else { throw ExtractError.none(folder.path) }
        return folder.appendingPathComponent(chosen)
    }

    /// The folder's entries with their creation date and kind. An unreadable folder is its own error, not "no screenshot".
    private static func listing(of folder: URL) throws -> [ScreenshotEntry] {
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        } catch {
            throw ExtractError.folderUnreadable(folder.path)
        }
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return ScreenshotEntry(name: url.lastPathComponent, created: values?.creationDate ?? Date.distantPast,
                                   isRegularFile: values?.isRegularFile ?? false, isSymbolicLink: values?.isSymbolicLink ?? true)
        }
    }

    /// Reads the text on the image. Local only (Vision); the text is returned to the caller, never forwarded anywhere.
    /// The continuation is resumed exactly once, after the request has run.
    static func recognizeText(_ url: URL) async throws -> String {
        guard let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ExtractError.unreadable }
        let lines: [String] = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                do {
                    try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
                    let observations = request.results ?? []
                    continuation.resume(returning: observations.compactMap { $0.topCandidates(1).first?.string })
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw ExtractError.noText }
        return text
    }
}
