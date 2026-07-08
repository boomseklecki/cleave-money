import SwiftUI

/// A quiet, non-modal inline notice that a background refresh failed and the screen is showing the last
/// cached data. Used in place of an error alert for pull-to-refresh / on-appear fetches, where a modal would
/// be intrusive and the data self-heals on the next successful refresh.
struct StaleNotice: View {
    var body: some View {
        Label("Couldn’t refresh — showing saved data", systemImage: "wifi.exclamationmark")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
