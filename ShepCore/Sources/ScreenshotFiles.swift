import Foundation

// Written for Shep.

/// One directory entry, as the extractor reads it. Plain values, so the choice is testable.
public struct ScreenshotEntry: Equatable, Sendable {
    public var name: String
    public var created: Date
    public var isRegularFile: Bool
    public var isSymbolicLink: Bool

    public init(name: String, created: Date, isRegularFile: Bool = true, isSymbolicLink: Bool = false) {
        self.name = name; self.created = created; self.isRegularFile = isRegularFile; self.isSymbolicLink = isSymbolicLink
    }
}

/// Pure helpers for picking a screenshot out of a folder listing.
/// A picture already sitting in the folder (a photo, an old screenshot) is never read by guessing: only a file created after
/// the request began is taken automatically, and anything else needs the person to choose that exact file.
public enum ScreenshotFiles {
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff"]

    public static func isImage(_ name: String) -> Bool {
        imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// A file Shep may read as a screenshot: an image extension, a regular file, not a link to somewhere else.
    public static func isReadable(_ entry: ScreenshotEntry) -> Bool {
        isImage(entry.name) && entry.isRegularFile && !entry.isSymbolicLink
    }

    /// The newest readable image created at or after `requestStart`, or nil when there is none. Older images, links,
    /// folders named like images and other files are never returned.
    public static func newestSince(_ requestStart: Date, in entries: [ScreenshotEntry]) -> String? {
        entries.filter { isReadable($0) && $0.created >= requestStart }.max { $0.created < $1.created }?.name
    }

    /// An image the person picked by name: accepted only if it is in the listing and is readable, whatever its age.
    public static func chosen(_ name: String, in entries: [ScreenshotEntry]) -> String? {
        entries.first { $0.name == name && isReadable($0) }?.name
    }
}
