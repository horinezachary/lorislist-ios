import SwiftUI
import LorisListKit

/// Sign in, with a way to the register screen. Mirrors the website's login and register pages.
struct AuthFlow: View {
    private enum AuthRoute: Hashable {
        case register
    }

    @State private var path: [AuthRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            LoginView(onRegister: { path.append(.register) })
                .navigationDestination(for: AuthRoute.self) { _ in
                    RegisterView()
                }
        }
    }
}

// MARK: - Sign in

struct LoginView: View {
    @EnvironmentObject private var model: AppModel

    let onRegister: () -> Void

    @State private var username = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorText: String?
    @State private var showReset = false
    @FocusState private var focus: Field?

    private enum Field {
        case username, password
    }

    var body: some View {
        CardColumn {
            if let notice = model.signedOutNotice {
                Banner(.info, notice)
            }
            if case .invitation = model.pendingLink {
                Banner(.info, "Sign in or sign up to answer your invitation.")
            }

            Card {
                CardTitle("Sign In")
                RowDivider()

                VStack(spacing: 14) {
                    if let errorText {
                        Banner(.error, errorText)
                    }

                    IconField(systemImage: "person.fill") {
                        TextField("username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                            .submitLabel(.next)
                            .focused($focus, equals: .username)
                            .onSubmit { focus = .password }
                    }

                    IconField(systemImage: "key.fill") {
                        SecureField("password", text: $password)
                            .textContentType(.password)
                            .submitLabel(.go)
                            .focused($focus, equals: .password)
                            .onSubmit { Task { await signIn() } }
                    }

                    HStack {
                        Spacer()
                        Button {
                            Task { await signIn() }
                        } label: {
                            BusyLabel(title: "Login", isBusy: isWorking)
                        }
                        .buttonStyle(.appDark)
                        .disabled(isWorking)
                    }
                }
                .padding(20)

                RowDivider()

                VStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Text("Don't have an account?")
                            .foregroundColor(.black)
                        Button("Sign Up!") { onRegister() }
                    }
                    Button("Forgot your password?") { showReset = true }
                }
                .font(.subheadline)
                .padding(16)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Lori's List")
        .navigationBarTitleDisplayMode(.inline)
        .brandedNavigationBar()
        .sheet(isPresented: $showReset) {
            ForgotPasswordSheet()
        }
    }

    private func signIn() async {
        guard !isWorking else { return }
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !password.isEmpty else {
            errorText = "Enter your username and password."
            return
        }
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            let user = try await model.api.login(username: name, password: password)
            model.didSignIn(user)
        } catch is CancellationError {
            // The screen went away; nothing to report.
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Register

struct RegisterView: View {
    @EnvironmentObject private var model: AppModel

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var passwordAgain = ""
    @State private var isWorking = false
    @State private var errorText: String?
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case first, last, username, email, password, again
    }

    var body: some View {
        CardColumn {
            Card {
                CardTitle("Register")
                RowDivider()

                VStack(spacing: 14) {
                    if let errorText {
                        Banner(.error, errorText)
                    }

                    IconField(systemImage: "person.fill") {
                        HStack(spacing: 8) {
                            TextField("First Name", text: $firstName)
                                .textContentType(.givenName)
                                .focused($focus, equals: .first)
                                .submitLabel(.next)
                                .onSubmit { focus = .last }
                            TextField("Last Name", text: $lastName)
                                .textContentType(.familyName)
                                .focused($focus, equals: .last)
                                .submitLabel(.next)
                                .onSubmit { focus = .username }
                        }
                    }

                    IconField(systemImage: "person.fill") {
                        TextField("username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                            .focused($focus, equals: .username)
                            .submitLabel(.next)
                            .onSubmit { focus = .email }
                    }

                    IconField(systemImage: "at") {
                        TextField("email", text: $email)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.emailAddress)
                            .focused($focus, equals: .email)
                            .submitLabel(.next)
                            .onSubmit { focus = .password }
                    }

                    IconField(systemImage: "key.fill") {
                        SecureField("password (at least 8 characters)", text: $password)
                            .textContentType(.newPassword)
                            .focused($focus, equals: .password)
                            .submitLabel(.next)
                            .onSubmit { focus = .again }
                    }

                    IconField(systemImage: "key.fill") {
                        SecureField("password again", text: $passwordAgain)
                            .textContentType(.newPassword)
                            .focused($focus, equals: .again)
                            .submitLabel(.go)
                            .onSubmit { Task { await register() } }
                    }

                    HStack {
                        Spacer()
                        Button {
                            Task { await register() }
                        } label: {
                            BusyLabel(title: "Register", isBusy: isWorking)
                        }
                        .buttonStyle(.appDark)
                        .disabled(isWorking)
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Lori's List")
        .navigationBarTitleDisplayMode(.inline)
        .brandedNavigationBar()
    }

    /// Returns what is wrong with the form, or nil when it can be sent.
    private func problem() -> String? {
        let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        if first.isEmpty || last.isEmpty { return "Please enter your first and last name." }
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !Validation.isValidUsername(name) {
            return "Usernames are 1 to 50 letters, numbers or . _ @ + - (no spaces)."
        }
        if !Validation.isValidEmail(email.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return "Please enter a valid email address."
        }
        if password.count < Validation.minPasswordLength {
            return "Passwords must be at least \(Validation.minPasswordLength) characters long."
        }
        if password != passwordAgain { return "The two passwords do not match." }
        return nil
    }

    private func register() async {
        guard !isWorking else { return }
        if let message = problem() {
            errorText = message
            return
        }
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            let user = try await model.api.register(
                firstName: firstName.trimmingCharacters(in: .whitespacesAndNewlines),
                lastName: lastName.trimmingCharacters(in: .whitespacesAndNewlines),
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password)
            model.didSignIn(user)
        } catch is CancellationError {
            // The screen went away; nothing to report.
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Forgot password

struct ForgotPasswordSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var isWorking = false
    @State private var errorText: String?
    @State private var sent = false

    var body: some View {
        SheetScaffold(title: "Reset Password") {
            if sent {
                Banner(.success, "If that email address has an account, a reset link is on its way.")
                Text("The link opens a screen where you can choose a new password. Then sign in with it.")
                    .font(.subheadline)
                    .foregroundColor(.black)
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.appGradient)
                }
            } else {
                Text("Enter your e-mail address and we'll send you a link to reset your password.")
                    .foregroundColor(.black)

                if let errorText {
                    Banner(.error, errorText)
                }

                TextField("email address", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.emailAddress)
                    .submitLabel(.send)
                    .onSubmit { Task { await send() } }
                    .boxedField()

                HStack {
                    Spacer()
                    Button {
                        Task { await send() }
                    } label: {
                        BusyLabel(title: "Send", isBusy: isWorking)
                    }
                    .buttonStyle(.appGradient)
                    .disabled(isWorking)
                }
            }
        }
    }

    private func send() async {
        guard !isWorking else { return }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Validation.isValidEmail(address) else {
            errorText = "Please enter a valid email address."
            return
        }
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            try await model.api.requestPasswordReset(email: address)
            sent = true
        } catch is CancellationError {
            // The sheet went away; nothing to report.
        } catch {
            errorText = error.localizedDescription
        }
    }
}
