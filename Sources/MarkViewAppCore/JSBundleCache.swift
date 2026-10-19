import Foundation

/// Process-wide, load-once cache for Prism injected into the preview page.
public struct JSBundleCache: Sendable {

    public let prism: String?

    public let failures: [LoadFailure]

    public enum LoadFailure: Equatable, Sendable {
        case resourceNotFound(label: String)
        case readFailed(label: String, message: String)
    }

    public enum LoadError: Error, Sendable {
        case resourceNotFound
        case readFailed(message: String)
    }

    public typealias Loader = @Sendable (_ resourceName: String) -> Result<String, LoadError>

    public static let shared = JSBundleCache(loader: JSBundleCache.resourceBundleLoader)

    public init(loader: Loader) {
        var failures: [LoadFailure] = []
        func load(_ name: String, label: String) -> String? {
            switch loader(name) {
            case .success(let js):
                return js
            case .failure(.resourceNotFound):
                failures.append(.resourceNotFound(label: label))
                return nil
            case .failure(.readFailed(let message)):
                failures.append(.readFailed(label: label, message: message))
                return nil
            }
        }
        self.prism = load("prism-bundle.min", label: "Prism.js")
        self.failures = failures
    }

    public static let resourceBundleLoader: Loader = { name in
        guard let url = ResourceBundle.url(forResource: name, withExtension: "js", subdirectory: "Resources") else {
            return .failure(.resourceNotFound)
        }
        do {
            return .success(try String(contentsOf: url, encoding: .utf8))
        } catch {
            return .failure(.readFailed(message: error.localizedDescription))
        }
    }
}
