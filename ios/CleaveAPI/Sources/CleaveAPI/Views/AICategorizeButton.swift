import SwiftUI

/// A compact, icon-only on-device-AI categorize control for a card or section corner: the
/// `apple.intelligence` glyph, swapped to a spinner while a pass is running. Callers gate visibility
/// (`if aiAvailable`) and may add extra `.disabled(...)` (e.g. no named items yet).
struct AICategorizeButton: View {
    let running: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if running {
                ProgressView()
            } else {
                Image(systemName: "apple.intelligence").font(.title3)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .disabled(running)
        .accessibilityLabel("Categorize with Apple Intelligence")
    }
}
