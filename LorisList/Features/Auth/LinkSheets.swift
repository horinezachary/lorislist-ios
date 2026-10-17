import SwiftUI
import LorisListKit

// MARK: - Password reset

/// Opened from the link in a password-reset email. Checks the link first, then asks for a new
/// password. Works whether or not anyone is signed in.
struct ResetPasswordSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let token: String

    private enum Stage {
        case checking
        case ready
        case badLink(String)
    }

    @State private var stage = Stage.checking
    @State private var password = ""
    @State private var passwordAgain = ""
    @State private var isWorking = false
    @State private var errorText: String?
    @FocusState private var focus: Field?

    private enum Field {
        case password, again
    }

    var body: some View {
        SheetScaffold(title: "New Password") {
            switch stage {
            case .checking:
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 20)
            case .badLink(let message):
                Banner(.error, message)
                Text("Reset links stop working once they have been used or have expired. You can ask for a new one from the sign-in screen.")
                    .font(.subheadline)
                    .foregroundColor(.black)
                HStack {
                    Spacer()
                    Button("OK") { dismiss() }
                        .buttonStyle(.appGradient)
                }
            case .ready:
                form
            }
        }
        .task { await check() }
        .interactiveDismissDisabled(isWorking)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a new password for your account. You will be signed out everywhere and asked to sign in again.")
                .foregroundColor(.black)

            if let errorText {
                Banner(.error, errorText)
            }

            SecureField("new password", text: $password)
                .textContentType(.newPassword)
                .submitLabel(.next)
                .focused($focus, equals: .password)
                .onSubmit { focus = .again }
                .boxedField()

            SecureField("new password again", text: $passwordAgain)
                .textContentType(.newPassword)
                .submitLabel(.go)
                .focused($focus, equals: .again)
                .onSubmit { Task { await save() } }
                .boxedField()

            HStack {
                Spacer()
                Button {
                    Task { await save() }
                } label: {
                    BusyLabel(title: "Change Password", isBusy: isWorking)
                }
                .buttonStyle(.appGradient)
                .disabled(isWorking)
            }
        }
    }

    private func check() async {
        do {
            try await model.api.checkPasswordReset(token: token)
            stage = .ready
            focus = .password
        } catch is CancellationError {
            // The sheet went away.
        } catch let error as APIError where error.code == .notFound {
            stage = .badLink(error.errorDescription ?? "This reset link is not valid any more.")
        } catch {
            // Offline or a server hiccup: let them try anyway; saving reports the real problem.
            stage = .ready
            errorText = error.localizedDescription
        }
    }

    private func save() async {
        guard !isWorking else { return }
        guard password.count >= Validation.minPasswordLength else {
            errorText = "Passwords must be at least \(Validation.minPasswordLength) characters long."
            return
        }
        guard password == passwordAgain else {
            errorText = "The two passwords don't match."
            return
        }
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            try await model.api.completePasswordReset(token: token, newPassword: password)
            model.passwordWasReset()
        } catch is CancellationError {
            // The sheet went away.
        } catch let error as APIError where error.code == .notFound {
            stage = .badLink(error.errorDescription ?? "This reset link is not valid any more.")
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Invitation

/// Opened from the link in an invitation email, once the person is signed in.
struct InvitationSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let key: String

    private enum Stage {
        case loading
        case ready(ShareInvitation)
        case declined
        case problem(String)
    }

    @State private var stage = Stage.loading
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        SheetScaffold(title: "Invitation") {
            switch stage {
            case .loading:
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 20)
            case .ready(let invitation):
                details(invitation)
            case .declined:
                Banner(.success, "Invitation declined.")
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.appGradient)
                }
            case .problem(let message):
                Banner(.error, message)
                HStack {
                    Spacer()
                    Button("OK") { dismiss() }
                        .buttonStyle(.appGradient)
                }
            }
        }
        .task { await load() }
        .interactiveDismissDisabled(isWorking)
    }

    @ViewBuilder
    private func details(_ invitation: ShareInvitation) -> some View {
        let access = invitation.permission == .edit ? "add and change items" : "see items"
        HStack(spacing: 12) {
            ColorSwatch(hex: invitation.list.color, name: invitation.list.name, isSelected: false)
            Text(invitation.list.name)
                .font(.title3.bold())
                .foregroundColor(.black)
        }
        Text("\(invitation.list.owner) invited you to share this list. You will be able to \(access).")
            .foregroundColor(.black)

        if let errorText {
            Banner(.error, errorText)
        }

        HStack(spacing: 12) {
            Spacer()
            Button {
                Task { await answer(accept: false) }
            } label: {
                Text("Decline")
            }
            .buttonStyle(.appOutline)
            .disabled(isWorking)

            Button {
                Task { await answer(accept: true) }
            } label: {
                BusyLabel(title: "Accept", isBusy: isWorking)
            }
            .buttonStyle(.appGradient)
            .disabled(isWorking)
        }
    }

    private func load() async {
        do {
            stage = .ready(try await model.api.invitation(key: key))
        } catch is CancellationError {
            // The sheet went away.
        } catch {
            stage = .problem(error.localizedDescription)
        }
    }

    private func answer(accept: Bool) async {
        guard !isWorking else { return }
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            if let list = try await model.api.respond(toInvitation: key, accept: accept) {
                model.invitationAccepted(list)
            } else {
                stage = .declined
            }
        } catch is CancellationError {
            // The sheet went away.
        } catch {
            errorText = error.localizedDescription
        }
    }
}
