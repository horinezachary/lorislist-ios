import SwiftUI
import LorisListKit

/// "My Account": name, email and password, as on the website, plus devices and sign out.
struct AccountView: View {
    enum AccountSheet: String, Identifiable {
        case name, email, password

        var id: String { rawValue }
    }

    @EnvironmentObject private var app: AppModel
    @State private var sheet: AccountSheet?
    @State private var confirmSignOut = false

    var body: some View {
        CardColumn {
            Card {
                CardTitle("My Account - \(app.user?.username ?? "")")
                RowDivider()
                infoRow(title: "Name", value: app.user?.fullName, button: "Update name", sheet: .name)
                RowDivider()
                infoRow(title: "Email", value: app.user?.email, button: "Update email", sheet: .email)
                RowDivider()
                infoRow(title: "Password", value: nil, button: "Change Password", sheet: .password)
            }

            Card {
                NavigationLink(value: Route.devices) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Signed-in devices")
                                .font(.headline)
                            Text("See where you are signed in, and sign a device out.")
                                .font(.subheadline)
                                .foregroundColor(Color(hex: "495057"))
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(Color(hex: "495057"))
                    }
                    .foregroundColor(.black)
                    .padding(20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                RowDivider()

                HStack {
                    Spacer()
                    Button("Sign out") { confirmSignOut = true }
                        .buttonStyle(.appDark)
                }
                .padding(12)
            }

            aboutCard
        }
        .navigationTitle("Lori's List")
        .navigationBarTitleDisplayMode(.inline)
        .brandedNavigationBar()
        .sheet(item: $sheet) { which in
            EditAccountSheet(kind: which, user: app.user)
        }
        .alert("Sign out", isPresented: $confirmSignOut) {
            Button("Sign out", role: .destructive) {
                Task { await app.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will need to sign in again on this device.")
        }
    }

    private func infoRow(title: String, value: String?, button: String, sheet target: AccountSheet) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.black)
                if let value {
                    Text(value)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.black)
                }
            }
            Spacer(minLength: 8)
            Button(button) { sheet = target }
                .buttonStyle(AppButtonStyle(kind: .dark, compact: true))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var aboutCard: some View {
        Card {
            CardTitle("Feedback")
            RowDivider()
            VStack(alignment: .leading, spacing: 10) {
                Text("If you have feature suggestions or would like to report an issue, please send me an email. This information is incredibly valuable and much appreciated!")
                if let url = URL(string: "mailto:feedback@horine.dev") {
                    Link("feedback@horine.dev", destination: url)
                }
                Text("Thanks,\nZachary Horine")
                Text("Version \(versionText)")
                    .font(.caption)
                    .foregroundColor(Color(hex: "495057"))
            }
            .font(.subheadline)
            .foregroundColor(.black)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

// MARK: - Edit sheets

/// The pop-up for changing the name, the email or the password.
struct EditAccountSheet: View {
    let kind: AccountView.AccountSheet

    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var firstName: String
    @State private var lastName: String
    @State private var email: String
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var newPasswordAgain = ""
    @State private var isWorking = false
    @State private var errorText: String?
    @State private var passwordChanged = false

    init(kind: AccountView.AccountSheet, user: User?) {
        self.kind = kind
        _firstName = State(initialValue: user?.firstName ?? "")
        _lastName = State(initialValue: user?.lastName ?? "")
        _email = State(initialValue: user?.email ?? "")
    }

    private var title: String {
        switch kind {
        case .name: return "Update name"
        case .email: return "Update email"
        case .password: return "Change Password"
        }
    }

    var body: some View {
        SheetScaffold(title: title) {
            if passwordChanged {
                Banner(.success, "Your password was changed.")
                Text("Your other devices have been signed out, so they will ask for the new password.")
                    .font(.subheadline)
                    .foregroundColor(.black)
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.appGradient)
                }
            } else {
                if let errorText {
                    Banner(.error, errorText)
                }

                fields

                HStack {
                    Spacer()
                    Button {
                        Task { await submit() }
                    } label: {
                        BusyLabel(title: "Update", isBusy: isWorking)
                    }
                    .buttonStyle(.appGradient)
                    .disabled(isWorking)
                }
            }
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch kind {
        case .name:
            TextField("First Name", text: $firstName)
                .textContentType(.givenName)
                .boxedField()
            TextField("Last Name", text: $lastName)
                .textContentType(.familyName)
                .boxedField()
        case .email:
            TextField("email", text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.emailAddress)
                .boxedField()
        case .password:
            SecureField("current password", text: $currentPassword)
                .textContentType(.password)
                .boxedField()
            SecureField("new password (at least 8 characters)", text: $newPassword)
                .textContentType(.newPassword)
                .boxedField()
            SecureField("new password again", text: $newPasswordAgain)
                .textContentType(.newPassword)
                .boxedField()
        }
    }

    private func submit() async {
        guard !isWorking else { return }
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            switch kind {
            case .name:
                let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
                let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !first.isEmpty, !last.isEmpty else {
                    errorText = "Please enter your first and last name."
                    return
                }
                app.updateUser(try await app.api.updateProfile(firstName: first, lastName: last))
                dismiss()
            case .email:
                let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
                guard Validation.isValidEmail(address) else {
                    errorText = "Please enter a valid email address."
                    return
                }
                app.updateUser(try await app.api.updateProfile(email: address))
                dismiss()
            case .password:
                guard !currentPassword.isEmpty else {
                    errorText = "Enter your current password."
                    return
                }
                guard newPassword.count >= Validation.minPasswordLength else {
                    errorText = "Passwords must be at least \(Validation.minPasswordLength) characters long."
                    return
                }
                guard newPassword == newPasswordAgain else {
                    errorText = "The two new passwords do not match."
                    return
                }
                try await app.api.changePassword(current: currentPassword, new: newPassword)
                currentPassword = ""
                newPassword = ""
                newPasswordAgain = ""
                passwordChanged = true
            }
        } catch is CancellationError {
            // The sheet went away; nothing to report.
        } catch {
            errorText = error.localizedDescription
        }
    }
}
