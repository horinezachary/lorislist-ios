import SwiftUI
import LorisListKit

/// Says when the phone is offline, what is waiting to be sent, and when something could not be saved.
/// Shows nothing at all when everything is as it should be.
struct SyncBanner: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        let state = app.syncState
        VStack(spacing: 8) {
            if state.droppedCount > 0 {
                Banner(.error, "Some changes couldn't be saved because the list was changed or removed by someone else. Tap to dismiss.")
                    .onTapGesture { Task { await app.sync.acknowledgeDropped() } }
                    .accessibilityHint("Tap to dismiss")
            }
            if !state.isOnline {
                Banner(.info, offlineText(state))
            } else if state.pendingCount > 0 {
                Banner(.info, state.pendingCount == 1 ? "Saving 1 change…" : "Saving \(state.pendingCount) changes…")
            }
        }
    }

    private func offlineText(_ state: SyncState) -> String {
        var text = "You're offline."
        if state.pendingCount > 0 {
            let what = state.pendingCount == 1 ? "1 change" : "\(state.pendingCount) changes"
            text += " \(what) will be saved when you're back online."
        } else if let when = state.lastSynced {
            text += " Showing what was saved \(when.formatted(.relative(presentation: .named)))."
        }
        return text
    }
}
