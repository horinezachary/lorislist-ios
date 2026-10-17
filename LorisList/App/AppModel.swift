import Combine
import SwiftUI
import UIKit
import LorisListKit

/// Who is signed in, and the one API client the whole app shares.
@MainActor
final class AppModel: ObservableObject {
    enum Phase {
        case launching
        case signedOut
        case signedIn
    }

    @Published private(set) var phase: Phase = .launching {
        didSet { updateLiveUpdates() }
    }
    /// Nil until the server has told us, and while signed out.
    @Published private(set) var user: User?
    @Published private(set) var colors: [ListColorOption] = ColorPalette.fallback
    /// Why the person is back at the sign-in screen, when it was not their own doing.
    @Published var signedOutNotice: String?

    /// A link from an email that is waiting to be shown (see `handle(url:)`).
    @Published var pendingLink: AppLink?
    /// Set when an accepted invitation should take the person straight to that list.
    @Published var listToOpen: ListSummary?

    /// Whether the phone is talking to the server, and what is waiting to be sent. Drives the banner.
    @Published private(set) var syncState = SyncState()

    let api: APIClient
    /// The copy of the lists kept on the phone, and the queue of changes made offline.
    let sync: SyncEngine
    /// Tells screens that lists or items changed (after a sync, or an edit on this phone).
    let syncEvents = PassthroughSubject<SyncEvent, Never>()
    private let siteHosts: Set<String>

    private var live: LiveUpdates?
    private var isActive = true
    private let connectivity = ConnectivityMonitor()

    static let defaultBaseURL = "https://lorislist.horinetech.com/api/v1"

    init(api: APIClient? = nil, store: SnapshotStore? = nil) {
        let client = api ?? AppModel.makeClient()
        self.api = client
        self.sync = SyncEngine(api: client, store: store ?? FileSnapshotStore.standard())
        let base = URL(string: Bundle.main.object(forInfoDictionaryKey: "LorisListAPIBaseURL") as? String ?? "")
            ?? URL(string: AppModel.defaultBaseURL)!
        siteHosts = AppLink.siteHosts(forAPI: base)
    }

    /// The server address comes from Info.plist (`LorisListAPIBaseURL`), so a debug build can
    /// point at a development server without touching code.
    private static func makeClient() -> APIClient {
        AppModel.wipeKeychainOnFreshInstall()
        let configured = Bundle.main.object(forInfoDictionaryKey: "LorisListAPIBaseURL") as? String
        let url = URL(string: configured ?? "") ?? URL(string: defaultBaseURL)!
        return APIClient(
            baseURL: url,
            deviceName: UIDevice.current.name,
            tokenStore: KeychainTokenStore())
    }

    /// The Keychain survives deleting the app, so a reinstall would otherwise start out
    /// signed in as whoever used the phone before.
    private static func wipeKeychainOnFreshInstall() {
        let key = "hasLaunchedBefore"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        KeychainTokenStore().clear()
        UserDefaults.standard.set(true, forKey: key)
    }

    // MARK: Launch

    func start() async {
        guard phase == .launching else { return }
        await api.setSessionExpiredHandler { [weak self] in
            Task { @MainActor in self?.sessionExpired() }
        }
        await sync.setHandler { [weak self] event in
            Task { @MainActor in self?.receive(event) }
        }
        syncState = await sync.currentState()
        connectivity.onRestored = { [weak self] in
            Task { @MainActor in self?.connectivityRestored() }
        }
        connectivity.start()

        guard await api.isSignedIn else {
            phase = .signedOut
            return
        }

        // With a saved copy there is no need to wait for the network: show it now and check the
        // sign-in in the background. (If the session turned out to be dead, sessionExpired() runs.)
        if let cached = await sync.cachedUser() {
            user = cached
            await sync.attach(username: cached.username)
            phase = .signedIn
            Task { await refreshProfile() }
            return
        }

        do {
            let fresh = try await api.me()
            await sync.attach(username: fresh.username)
            await sync.remember(user: fresh)
            user = fresh
            phase = .signedIn
        } catch let error as APIError where error.code == .sessionExpired {
            // sessionExpired() has already moved us to the sign-in screen.
            if phase == .launching { phase = .signedOut }
        } catch {
            // Offline, or the server is down: stay signed in. Screens show their own errors.
            phase = .signedIn
        }
    }

    /// Asks the server for the full profile. Quietly does nothing when offline.
    private func refreshProfile() async {
        if let fresh = try? await api.me() {
            user = fresh
            await sync.remember(user: fresh)
        }
    }

    // MARK: Staying in sync

    private func receive(_ event: SyncEvent) {
        if case .state(let newState) = event { syncState = newState }
        syncEvents.send(event)
    }

    /// The app came to the front, or went away. Live updates only run while it is in front,
    /// since iOS ends background connections anyway.
    func setActive(_ active: Bool) {
        isActive = active
        updateLiveUpdates()
        if active, phase == .signedIn {
            Task { await sync.sync() }
        }
    }

    private func connectivityRestored() {
        guard phase == .signedIn else { return }
        // Start the stream afresh so it does not sit in a long back-off, and send what is waiting.
        live?.stop()
        live = nil
        updateLiveUpdates()
        Task { await sync.sync() }
    }

    private func updateLiveUpdates() {
        let shouldRun = phase == .signedIn && isActive
        if shouldRun, live == nil {
            let sync = self.sync
            let updates = LiveUpdates(api: api, streamer: URLSessionLineStreamer()) { digest in
                Task { await sync.sync(digest: digest) }
            }
            live = updates
            updates.start()
        } else if !shouldRun, let running = live {
            running.stop()
            live = nil
        }
    }

    // MARK: Links from emails

    /// Called when iOS hands the app a web link (a universal link). Anything that is not an
    /// invitation or a reset link is ignored.
    func handle(url: URL) {
        guard let link = AppLink.parse(url, siteHosts: siteHosts) else { return }
        pendingLink = link
    }

    /// The person finished with the link, or turned it down.
    func finishLink() {
        pendingLink = nil
    }

    /// A new password was set from a reset link. The server ended every session, so go to sign-in.
    func passwordWasReset() {
        user = nil
        pendingLink = nil
        signedOutNotice = "Your password has been changed. Sign in with the new one."
        phase = .signedOut
    }

    /// An invitation was accepted: close the sheet and open the list.
    func invitationAccepted(_ list: ListSummary) {
        pendingLink = nil
        listToOpen = list
    }

    // MARK: Signing in and out

    func didSignIn(_ signedInUser: User) async {
        // A different account than the saved copy belongs to starts the copy over, so this has
        // to finish before any screen reads it.
        await sync.attach(username: signedInUser.username)
        await sync.remember(user: signedInUser)
        user = signedInUser
        signedOutNotice = nil
        phase = .signedIn
        // Sign-in does not include the tips setting; ask for the full profile.
        Task { await refreshProfile() }
        Task { await sync.sync() }
    }

    func signOut() async {
        await api.logout()
        await sync.reset()
        finishSignOut()
    }

    /// For after the API has already ended every session, this one included.
    func signedOutEverywhere() {
        Task { await sync.reset() }
        finishSignOut()
    }

    private func finishSignOut() {
        user = nil
        signedOutNotice = nil
        phase = .signedOut
    }

    private func sessionExpired() {
        user = nil
        signedOutNotice = "Your session has expired. Please sign in again."
        phase = .signedOut
    }

    // MARK: Account

    func updateUser(_ newUser: User) {
        user = newUser
        Task { await sync.remember(user: newUser) }
    }

    /// "Don't show this again" on the welcome tip.
    func hideTips() async {
        if let updated = try? await api.updateProfile(showTips: false) {
            user = updated
        } else if var current = user {
            current.showTips = false
            user = current
        }
    }

    // MARK: Colours

    func loadColors() async {
        let saved = await sync.colors()
        if !saved.isEmpty { colors = saved }
        if let fresh = try? await api.colors(), !fresh.isEmpty {
            colors = fresh
        }
    }
}
