import SwiftUI
import LorisListKit

/// The "New List" and "Edit List" pop-ups: a name and one of the list colours.
struct ListEditorSheet: View {
    enum Mode {
        case create
        case edit(ListSummary)
    }

    let mode: Mode
    let colors: [ListColorOption]
    let onSave: (String, String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var colorHex: String
    @State private var isWorking = false
    @State private var errorText: String?
    @FocusState private var nameFocused: Bool

    /// The colour the list had when the sheet opened, which may not be one of the offered ones.
    private let originalHex: String?

    init(mode: Mode, colors: [ListColorOption], onSave: @escaping (String, String) async throws -> Void) {
        self.mode = mode
        self.colors = colors
        self.onSave = onSave
        switch mode {
        case .create:
            _name = State(initialValue: "")
            _colorHex = State(initialValue: HexColor.normalize(colors.first?.hex ?? "") ?? "ff9900")
            originalHex = nil
        case .edit(let list):
            let hex = HexColor.normalize(list.color) ?? list.color
            _name = State(initialValue: list.name)
            _colorHex = State(initialValue: hex)
            originalHex = hex
        }
    }

    private var title: String {
        switch mode {
        case .create: return "New List"
        case .edit(let list): return "Edit List: \(list.name)"
        }
    }

    /// The offered colours, plus the list's current one if it is not among them.
    private var options: [ListColorOption] {
        var all = colors
        if let originalHex, !all.contains(where: { HexColor.normalize($0.hex) == originalHex }) {
            all.append(ListColorOption(id: -100, hex: originalHex, name: "Current colour"))
        }
        return all
    }

    var body: some View {
        SheetScaffold(title: title) {
            if let errorText {
                Banner(.error, errorText)
            }

            TextField("List Name", text: $name)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($nameFocused)
                .onSubmit { nameFocused = false }
                .onChange(of: name) { value in
                    if value.count > ItemInput.maxNameLength {
                        name = String(value.prefix(ItemInput.maxNameLength))
                    }
                }
                .boxedField()

            Text("Colour")
                .font(.subheadline.weight(.medium))
                .foregroundColor(.black)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
                ForEach(options) { option in
                    let hex = HexColor.normalize(option.hex) ?? option.hex
                    Button {
                        colorHex = hex
                    } label: {
                        ColorSwatch(hex: hex, name: option.name, isSelected: hex == colorHex)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Spacer()
                Button {
                    Task { await save() }
                } label: {
                    BusyLabel(title: "Go!", isBusy: isWorking)
                }
                .buttonStyle(.appGradient)
                .disabled(isWorking)
            }
        }
        .onAppear {
            if case .create = mode { nameFocused = true }
        }
    }

    private func save() async {
        guard !isWorking else { return }
        let trimmed = ItemInput.cleanName(name)
        guard !trimmed.isEmpty else {
            errorText = "Give the list a name."
            return
        }
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            try await onSave(trimmed, colorHex)
            dismiss()
        } catch is CancellationError {
            // The sheet went away; nothing to report.
        } catch {
            errorText = error.localizedDescription
        }
    }
}
