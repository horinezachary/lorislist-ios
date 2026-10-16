import SwiftUI
import LorisListKit

/// "Share List": invite someone by email to edit or only view a list. Only the owner sees this.
/// The server sends the invitation email; its link opens the website.
struct ShareSheet: View {
    let list: ListSummary
    let api: APIClient

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var permission: SharePermission = .edit
    @State private var isWorking = false
    @State private var errorText: String?
    @State private var sentTo: String?

    var body: some View {
        SheetScaffold(title: "Share List") {
            if let sentTo {
                Banner(.success, "Invitation sent to \(sentTo).")
                Text("They will get an email with a link to accept it.")
                    .foregroundColor(.black)
                HStack {
                    Button("Invite someone else") {
                        email = ""
                        self.sentTo = nil
                    }
                    .buttonStyle(.appOutline)
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.appGradient)
                }
            } else {
                Text("Enter the email address you would like to share \"\(list.name)\" with and select their permission level.")
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

                Text("Permission Level")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.black)

                Picker("Permission Level", selection: $permission) {
                    ForEach(SharePermission.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                Text(permission == .edit
                     ? "They can add, cross off and remove items."
                     : "They can see the list but not change it.")
                    .font(.footnote)
                    .foregroundColor(Color(hex: "495057"))

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
            try await api.invite(listID: list.id, email: address, permission: permission)
            sentTo = address
        } catch is CancellationError {
            // The sheet went away; nothing to report.
        } catch {
            errorText = error.localizedDescription
        }
    }
}
