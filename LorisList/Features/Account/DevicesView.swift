import SwiftUI
import LorisListKit

@MainActor
final class DevicesModel: ObservableObject {
    @Published private(set) var sessions: [DeviceSession] = []
    @Published private(set) var hasLoaded = false
    @Published var errorText: String?

    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    func load() async {
        do {
            sessions = try await api.sessions()
            hasLoaded = true
            errorText = nil
        } catch is CancellationError {
            // Left the screen. Not an error.
        } catch {
            report(error)
        }
    }

    func signOut(_ session: DeviceSession) async {
        do {
            try await api.revokeSession(id: session.id)
            sessions.removeAll { $0.id == session.id }
        } catch is CancellationError {
            return
        } catch {
            report(error)
        }
    }

    /// Returns true when every device, this one included, was signed out.
    func signOutEverywhere() async -> Bool {
        do {
            try await api.logoutEverywhere()
            return true
        } catch is CancellationError {
            return false
        } catch {
            report(error)
            return false
        }
    }

    private func report(_ error: Error) {
        if let apiError = error as? APIError, apiError.code == .sessionExpired { return }
        errorText = error.localizedDescription
    }
}

/// Every device that is signed in to the account, with a way to sign one out.
/// (The website has no equivalent; this comes from the API's session list.)
struct DevicesView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model: DevicesModel
    @State private var confirmAll = false

    init(api: APIClient) {
        _model = StateObject(wrappedValue: DevicesModel(api: api))
    }

    var body: some View {
        CardColumn {
            if let errorText = model.errorText {
                Banner(.error, errorText)
            }

            Card {
                CardTitle("Signed-in devices")

                if !model.hasLoaded && model.errorText == nil {
                    RowDivider()
                    ProgressView().padding(24)
                }

                ForEach(model.sessions) { session in
                    RowDivider()
                    row(session)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Signing a device out means whoever has it must sign in again. If you lose a phone, sign out of all devices and change your password.")
                        .font(.subheadline)
                        .foregroundColor(.black)
                    HStack {
                        Spacer()
                        Button("Sign out of all devices") { confirmAll = true }
                            .buttonStyle(.appDanger)
                    }
                }
                .padding(20)
            }
        }
        .refreshable { await model.load() }
        .navigationTitle("Lori's List")
        .navigationBarTitleDisplayMode(.inline)
        .brandedNavigationBar()
        .task { await model.load() }
        .alert("Sign out of all devices", isPresented: $confirmAll) {
            Button("Sign out everywhere", role: .destructive) {
                Task {
                    if await model.signOutEverywhere() {
                        app.signedOutEverywhere()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This signs out every device, including this one.")
        }
    }

    private func row(_ session: DeviceSession) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(session.deviceName.isEmpty ? "Unknown device" : session.deviceName)
                        .font(.headline)
                        .foregroundColor(.black)
                    if session.current {
                        Text("This device")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Theme.alertSuccessText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Theme.alertSuccessBackground)
                            .clipShape(Capsule())
                    }
                }
                if let used = session.lastUsedAt {
                    Text("Last used \(Self.relative(used))")
                        .font(.caption)
                        .foregroundColor(Color(hex: "495057"))
                }
            }
            Spacer(minLength: 8)
            if !session.current {
                Button("Sign out") {
                    Task { await model.signOut(session) }
                }
                .buttonStyle(AppButtonStyle(kind: .danger, compact: true))
                .accessibilityLabel("Sign out \(session.deviceName)")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
