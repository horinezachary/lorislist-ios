import SwiftUI
import LorisListKit

/// Says when the phone is offline, what is waiting to be sent, and when something could not be saved.
/// Shows nothing at all when everything is as it should be.
///
/// Most changes are saved within a moment, so "Saving…" only appears once a change has waited
/// `savingDelay` without being saved. Once a notice is up it stays at least `minimumShowTime`, so
/// it never flashes on and off as items are tapped.
struct SyncBanner: View {
    @EnvironmentObject private var app: AppModel

    /// How long changes may wait to be saved before the banner says so.
    static let savingDelay: Duration = .seconds(15)
    /// The shortest time a notice stays on screen.
    static let minimumShowTime: TimeInterval = 3

    private enum Notice: Equatable {
        case offline, saving
    }

    @State private var shown: Notice?
    @State private var shownAt = Date.distantPast

    var body: some View {
        let state = app.syncState
        VStack(spacing: 8) {
            if state.droppedCount > 0 {
                Banner(.error, "Some changes couldn't be saved because the list was changed or removed by someone else. Tap to dismiss.")
                    .onTapGesture { Task { await app.sync.acknowledgeDropped() } }
                    .accessibilityHint("Tap to dismiss")
            }
            switch shown {
            case .offline:
                Banner(.info, offlineText(state))
            case .saving:
                Banner(.info, savingText(state))
            case nil:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: shown)
        .task(id: wanted(state)) { await settle(on: wanted(state)) }
    }

    /// What the sync state calls for right now, before any delay.
    private func wanted(_ state: SyncState) -> Notice? {
        if !state.isOnline { return .offline }
        if state.pendingCount > 0 { return .saving }
        return nil
    }

    /// Moves what is shown toward `target`, waiting where the timing rules say to. A newer target
    /// cancels this one, so only the latest state ever lands.
    private func settle(on target: Notice?) async {
        guard target != shown else { return }
        switch target {
        case nil:
            let remaining = Self.minimumShowTime - Date().timeIntervalSince(shownAt)
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
            }
            shown = nil
        case .saving where shown == nil:
            try? await Task.sleep(for: Self.savingDelay)
            guard !Task.isCancelled else { return }
            show(.saving)
        default:
            show(target)
        }
    }

    private func show(_ notice: Notice?) {
        shown = notice
        shownAt = Date()
    }

    private func savingText(_ state: SyncState) -> String {
        switch state.pendingCount {
        case 0: return "All changes saved."
        case 1: return "Saving 1 change…"
        default: return "Saving \(state.pendingCount) changes…"
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
