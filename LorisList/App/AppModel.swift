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

    @Published private(set) var phase: Phase = .launching
    /// Nil until the server has told us, and while signed out.
    @Published private(set) var user: User?
    @Published private(set) var colors: [ListColorOption] = ColorPalette.fallback
    /// Why the person is back at the sign-in screen, when it was not their own doing.
    @Published var signedOutNotice: String?

    /// A link from an email that is waiting to be shown (see `handle(url:)`).
    @Published var pendingLink: AppLink?
    /// Set when an accepted invitation should take the person straight to that list.
    @Published var listToOpen: ListSummary?

    let api: APIClient
    private let siteHosts: Set<String>

    static let defaultBaseURL = "https://lorislist.horinetech.com/api/v1"

    init(api: APIClient? = nil) {
        self.api = api ?? AppModel.makeClient()
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

        guard await api.isSignedIn else {
            phase = .signedOut
            return
        }

        do {
            user = try await api.me()
            phase = .signedIn
        } catch let error as APIError where error.code == .sessionExpired {
            // sessionExpired() has already moved us to the sign-in screen.
            if phase == .launching { phase = .signedOut }
        } catch {
            // Offline, or the server is down: stay signed in. Screens show their own errors.
            phase = .signedIn
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

    func didSignIn(_ signedInUser: User) {
        user = signedInUser
        signedOutNotice = nil
        phase = .signedIn
        // Sign-in does not include the tips setting; ask for the full profile.
        Task {
            if let full = try? await api.me() { user = full }
        }
    }

    func signOut() async {
        await api.logout()
        finishSignOut()
    }

    /// For after the API has already ended every session, this one included.
    func signedOutEverywhere() {
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
        if let fresh = try? await api.colors(), !fresh.isEmpty {
            colors = fresh
        }
    }
}
