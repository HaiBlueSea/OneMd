import Foundation

// MARK: - PHK Debug

/// Lightweight debug logger gated on PHK_DEBUG env var.
enum PHKDebug {
    static let enabled = ProcessInfo.processInfo.environment["PHK_DEBUG"] != nil
    static func log(_ msg: String, file: String = #fileID, line: Int = #line) {
        guard enabled else { return }
        fputs("[PHK] \(msg) (\(file):\(line))\n", stderr)
    }
}

/// Assembles the full HTML document delivered to WKWebView by injecting
/// bundled JS (Prism) into a rendered template.
public struct HTMLPipeline: Sendable {

    public let prismJS: String?

    public init(prismJS: String? = nil) {
        self.prismJS = prismJS
    }

    public static func loadFromBundle() -> HTMLPipeline {
        PHKDebug.log("loadFromBundle() — bundle: \(Bundle.module.bundlePath)")
        func load(_ name: String, ext: String = "js") -> String? {
            if let url = Bundle.module.url(forResource: name, withExtension: ext) {
                let content = try? String(contentsOf: url, encoding: .utf8)
                PHKDebug.log("  \(name).\(ext): \(content.map { "\($0.count) bytes" } ?? "READ FAILED")")
                return content
            }
            if let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources") {
                let content = try? String(contentsOf: url, encoding: .utf8)
                PHKDebug.log("  \(name).\(ext) (Resources/): \(content.map { "\($0.count) bytes" } ?? "READ FAILED")")
                return content
            }
            PHKDebug.log("  \(name).\(ext): NOT FOUND in bundle ⚠️")
            return nil
        }
        let pipeline = HTMLPipeline(prismJS: load("prism-bundle.min"))
        PHKDebug.log("loadFromBundle() done — prism:\(pipeline.prismJS != nil)")
        return pipeline
    }

    // MARK: - Image inlining

    public static func inlineLocalImages(in html: String, baseDirectory: URL) -> String {
        let pattern = "src=\"([^\"]*\\.(png|jpg|jpeg|gif|svg|webp|ico|bmp|tiff?))\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return html
        }
        var result = html
        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        for match in matches.reversed() {
            guard match.numberOfRanges > 1,
                  let srcRange = Range(match.range(at: 1), in: html) else { continue }
            let src = String(html[srcRange])
            guard !src.hasPrefix("http://"), !src.hasPrefix("https://"),
                  !src.hasPrefix("data:"), !src.hasPrefix("file://"),
                  !src.hasPrefix("/") else { continue }
            let directory = baseDirectory.resolvingSymlinksInPath().standardizedFileURL
            let imageURL = directory.appendingPathComponent(src).resolvingSymlinksInPath().standardizedFileURL
            let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
            guard imageURL.path.hasPrefix(prefix) else { continue }
            guard let data = try? Data(contentsOf: imageURL) else { continue }
            let ext = imageURL.pathExtension.lowercased()
            let mime: String
            switch ext {
            case "png":        mime = "image/png"
            case "jpg","jpeg": mime = "image/jpeg"
            case "gif":        mime = "image/gif"
            case "svg":        mime = "image/svg+xml"
            case "webp":       mime = "image/webp"
            case "ico":        mime = "image/x-icon"
            case "bmp":        mime = "image/bmp"
            case "tif","tiff": mime = "image/tiff"
            default:           mime = "image/\(ext)"
            }
            let dataURI = "data:\(mime);base64,\(data.base64EncodedString())"
            if let attrRange = Range(match.range(at: 0), in: result) {
                result.replaceSubrange(attrRange, with: "src=\"\(dataURI)\"")
            }
        }
        return result
    }

    // MARK: - Public assembly

    public static func assembleFullDocument(from markdown: String) -> String {
        let bodyHTML = MarkdownRenderer.renderHTML(from: markdown)
        let accessibleHTML = MarkdownRenderer.postProcessForAccessibility(bodyHTML)
        let template: String?
        if let url = Bundle.module.url(forResource: "template", withExtension: "html") {
            template = try? String(contentsOf: url, encoding: .utf8)
        } else if let url = Bundle.module.url(forResource: "template", withExtension: "html", subdirectory: "Resources") {
            template = try? String(contentsOf: url, encoding: .utf8)
        } else {
            template = nil
        }
        let baseHTML = MarkdownRenderer.wrapInTemplate(accessibleHTML, template: template)
        return HTMLPipeline.loadFromBundle().assemble(baseHTML)
    }

    public func assemble(_ templateHTML: String) -> String {
        injectPrism(templateHTML)
    }

    public func insertBeforeBodyClose(_ script: String, into html: String) -> String {
        guard let range = html.range(of: "</body>", options: .backwards) else {
            return html + script
        }
        return html.replacingCharacters(in: range, with: "\(script)\n</body>")
    }

    public func injectPrism(_ html: String) -> String {
        guard let js = prismJS else { return html }
        let scriptTag = "<script>\(js)\nPrism.manual = false; Prism.highlightAll();</script>"
        return insertBeforeBodyClose(scriptTag, into: html)
    }
}
