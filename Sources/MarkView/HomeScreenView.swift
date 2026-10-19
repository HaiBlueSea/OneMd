import SwiftUI
import UniformTypeIdentifiers
import MarkViewAppCore

/// Empty state when no file is loaded — open via the same panel path as ⌘O.
struct HomeScreenView: View {
    let onFileSelected: (URL) -> Void

    @State private var isFileImporterPresented = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text(Strings.dropPrompt)
                .font(.title2)
                .foregroundStyle(.secondary)

            Button(Strings.openFileButton) { isFileImporterPresented = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: markdownContentTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                for url in urls where MarkdownFile.shouldAcceptOpen(url) {
                    onFileSelected(url)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private let markdownContentTypes: [UTType] = {
    var types: [UTType] = []
    for ext in ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn"] {
        if let t = UTType(filenameExtension: ext) { types.append(t) }
    }
    return types
}()
