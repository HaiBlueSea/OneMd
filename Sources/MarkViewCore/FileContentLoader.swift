import Foundation

public struct LoadedFileText: Sendable, Equatable {
    public let text: String
    public let hasUTF8BOM: Bool
    public let usesCRLF: Bool

    public init(text: String, hasUTF8BOM: Bool, usesCRLF: Bool) {
        self.text = text
        self.hasUTF8BOM = hasUTF8BOM
        self.usesCRLF = usesCRLF
    }
}

public enum FileContentLoader {
    public static func load(from path: String) throws -> LoadedFileText {
        let resolvedPath = (path as NSString).resolvingSymlinksInPath
        do {
            return try decode(Data(contentsOf: URL(fileURLWithPath: resolvedPath)))
        } catch {
            return try decode(Data(contentsOf: URL(fileURLWithPath: path)))
        }
    }

    public static func decode(_ data: Data) throws -> LoadedFileText {
        var payload = data
        var hasBOM = false
        if payload.starts(with: [0xEF, 0xBB, 0xBF]) {
            hasBOM = true
            payload = payload.dropFirst(3)
        }
        guard let raw = String(data: payload, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let usesCRLF = raw.contains("\r\n")
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return LoadedFileText(text: text, hasUTF8BOM: hasBOM, usesCRLF: usesCRLF)
    }

    public static func encode(_ file: LoadedFileText) -> Data {
        let body = file.usesCRLF
            ? file.text.replacingOccurrences(of: "\n", with: "\r\n")
            : file.text
        var data = Data()
        if file.hasUTF8BOM {
            data.append(contentsOf: [0xEF, 0xBB, 0xBF])
        }
        data.append(contentsOf: body.utf8)
        return data
    }

    public static func write(_ file: LoadedFileText, to path: String) throws {
        try encode(file).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public static func read(from path: String) throws -> String {
        try load(from: path).text
    }
}
