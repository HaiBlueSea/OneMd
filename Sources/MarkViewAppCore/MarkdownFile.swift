import Foundation

public enum MarkdownFile {
    private static let allowed = Set(["md", "markdown", "mdown", "mkd", "mkdn", "mdwn"])

    public static func hasMarkdownExtension(_ url: URL) -> Bool {
        allowed.contains(url.pathExtension.lowercased())
    }

    public static func shouldAcceptOpen(_ url: URL, allowMissing: Bool = false) -> Bool {
        guard url.isFileURL, hasMarkdownExtension(url) else { return false }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if exists { return !isDir.boolValue }
        return allowMissing
    }
}
