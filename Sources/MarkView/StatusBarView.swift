import SwiftUI
import MarkViewAppCore

/// Bottom status bar: dirty indicator and optional file path.
struct StatusBarView: View {
    let filePath: String?
    let isDirty: Bool
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let palette = settings.palette
        HStack(spacing: 16) {
            if isDirty {
                Circle()
                    .fill(.orange)
                    .frame(width: 8, height: 8)
                    .help(Strings.unsavedChanges)
                    .accessibilityLabel(Strings.unsavedA11yLabel)
            }

            Spacer()

            if let path = filePath {
                Text(path)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(palette.muted)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(palette.subtle)
    }
}
