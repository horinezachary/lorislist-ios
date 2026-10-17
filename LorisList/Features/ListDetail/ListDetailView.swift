import Combine
import SwiftUI
import LorisListKit

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Model

@MainActor
final class ListDetailModel: ObservableObject {
    @Published private(set) var list: ListDetail
    /// Item names used before, for the quick-pick chips under the "add item" box.
    @Published private(set) var suggestionPool: [String] = []
    @Published private(set) var hasLoaded = false
    /// The list was deleted or is no longer shared with this person.
    @Published private(set) var isGone = false
    @Published var errorText: String?

    private let sync: SyncEngine
    private var subscription: AnyCancellable?
    let listID: Int

    init(summary: ListSummary, sync: SyncEngine, events: AnyPublisher<SyncEvent, Never>) {
        self.sync = sync
        self.listID = summary.id
        // Draw the header in the right colour straight away; the items follow.
        self.list = ListDetail(summary: summary, canEdit: summary.role != .view, items: [])
        subscription = events.sink { [weak self] event in
            switch event {
            case .list(let id) where id == summary.id:
                Task { await self?.reload(fromEvent: true) }
            case .lists:
                Task { await self?.reload(fromEvent: true) }
            default:
                break
            }
        }
        Task { await reload(fromEvent: false) }
    }

    /// Reads the saved copy, which already has any waiting changes applied.
    ///
    /// A list that is not saved is only called gone when a sync says so (`fromEvent`): opening a
    /// list that was only just shared with the person finds nothing saved yet, and is not gone.
    private func reload(fromEvent: Bool) async {
        if let saved = await sync.list(id: listID) {
            list = saved
            hasLoaded = true
            isGone = false
        } else if fromEvent, await sync.hasData() {
            let stillThere = await sync.lists().contains { $0.id == listID }
            if !stillThere { isGone = true }
        }
    }

    func load() async {
        await sync.sync()
        await reload(fromEvent: true)
        errorText = nil
        if list.canEdit {
            suggestionPool = await sync.refreshSuggestions()
        }
    }

    /// Crosses an item off, or puts it back. Shows at once; sent now, or when the connection returns.
    func toggle(_ item: ListItem) async {
        guard list.canEdit, let current = list.items.first(where: { $0.id == item.id }) else { return }
        if let updated = await sync.setChecked(listID: listID, itemID: item.id, checked: !current.checked) {
            list = updated
        }
    }

    /// Returns true when the item was added.
    func add(name: String, count: Int?) async -> Bool {
        guard list.canEdit else { return false }
        guard let updated = await sync.addItem(listID: listID, name: name, count: count) else { return false }
        list = updated
        errorText = nil
        if !suggestionPool.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            suggestionPool.append(name)
        }
        return true
    }

    func remove(_ item: ListItem) async {
        guard list.canEdit else { return }
        if let updated = await sync.removeItem(listID: listID, itemID: item.id) {
            list = updated
        }
    }

    /// The "Clear" button: removes everything that is crossed off.
    func clearCrossedOff() async {
        guard list.canEdit, list.checkedCount > 0 else { return }
        if let updated = await sync.clearChecked(listID: listID) {
            list = updated
        }
    }
}

// MARK: - View

struct ListDetailView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ListDetailModel

    @State private var newName = ""
    @State private var newCount = ""
    @State private var isAdding = false
    @State private var showShare = false
    @State private var tipDismissed = false
    @FocusState private var nameFocused: Bool

    init(summary: ListSummary, app: AppModel) {
        _model = StateObject(wrappedValue: ListDetailModel(
            summary: summary, sync: app.sync, events: app.syncEvents.eraseToAnyPublisher()))
    }

    var body: some View {
        let summary = model.list.summary
        let background = Color(hex: summary.color)
        let foreground = Color.foreground(on: summary.color)

        CardColumn(spacing: 12) {
            SyncBanner()
            if showTip {
                tipBanner
            }
            if let errorText = model.errorText {
                Banner(.error, errorText)
                    .onTapGesture { Task { await model.load() } }
                    .accessibilityHint("Tap to try again")
            }

            Card {
                header(summary: summary, background: background, foreground: foreground)

                ForEach(model.list.items) { item in
                    RowDivider()
                    ItemRow(
                        item: item,
                        canEdit: model.list.canEdit,
                        onToggle: {
                            tickFeedback()
                            Task { await model.toggle(item) }
                        },
                        onRemove: { Task { await model.remove(item) } })
                }

                if model.hasLoaded && model.list.items.isEmpty {
                    RowDivider()
                    Text(model.list.canEdit ? "Nothing on this list yet." : "Nothing on this list.")
                        .font(.subheadline)
                        .foregroundColor(Color(hex: "495057"))
                        .padding(20)
                        .frame(maxWidth: .infinity)
                } else if !model.hasLoaded {
                    RowDivider()
                    ProgressView().padding(24)
                }

                if model.list.canEdit {
                    addRow(background: background)
                }
            }
        }
        .refreshable { await model.load() }
        .navigationTitle("Lori's List")
        .navigationBarTitleDisplayMode(.inline)
        .brandedNavigationBar()
        .task { await model.load() }
        .onChange(of: model.isGone) { gone in
            if gone { dismiss() }
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(list: summary, api: app.api)
        }
    }

    // MARK: Pieces

    private var showTip: Bool {
        (app.user?.tipsEnabled ?? false) && !tipDismissed && model.list.canEdit
    }

    private var tipBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Welcome to your list! Here you can add things to your list using the text box below.")
            Text("Tap an item to cross it off.")
            Text("When you are done, tap Clear to remove the crossed-off items from your list.")
            Divider()
            HStack {
                Button("Don't show this again") {
                    Task { await app.hideTips() }
                }
                Spacer()
                Button("Close") {
                    withAnimation { tipDismissed = true }
                }
            }
            .font(.footnote.weight(.semibold))
        }
        .font(.subheadline)
        .foregroundColor(Theme.alertInfoText)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.alertInfoBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }

    private func header(summary: ListSummary, background: Color, foreground: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text(summary.name)
                    .font(.title2.bold())
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)

                if summary.role == .owner {
                    Button {
                        showShare = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                    .buttonStyle(AppButtonStyle(kind: .outline, compact: true, outlineColor: foreground))
                    .accessibilityLabel("Share list")
                }

                Button("Clear") {
                    Task { await model.clearCrossedOff() }
                }
                .buttonStyle(AppButtonStyle(kind: .outline, compact: true, outlineColor: foreground))
                .disabled(!model.list.canEdit || model.list.checkedCount == 0)
                .accessibilityHint("Removes the crossed-off items")
            }

            if summary.role != .owner {
                Text(summary.role == .edit
                     ? "Shared by \(summary.owner) · you can edit"
                     : "Shared by \(summary.owner) · view only")
                    .font(.caption)
            }
        }
        .foregroundColor(foreground)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    private func addRow(background: Color) -> some View {
        let matches = ItemInput.suggestions(for: newName, from: model.suggestionPool)
        return VStack(spacing: 10) {
            if !matches.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(matches, id: \.self) { name in
                            Button {
                                newName = name
                                nameFocused = true
                            } label: {
                                Text(name)
                                    .font(.subheadline)
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.white)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("#", text: $newCount)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .boxedField()
                    .frame(width: 64)
                    .accessibilityLabel("Quantity")

                TextField("Item", text: $newName)
                    .focused($nameFocused)
                    .submitLabel(.send)
                    .onSubmit { Task { await addItem() } }
                    .onChange(of: newName) { value in
                        if value.count > ItemInput.maxNameLength {
                            newName = String(value.prefix(ItemInput.maxNameLength))
                        }
                    }
                    .boxedField()

                Button {
                    Task { await addItem() }
                } label: {
                    Image(systemName: "arrow.right")
                        .font(.body.weight(.semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 42)
                        .background(Theme.dark)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                }
                .buttonStyle(.plain)
                .opacity(canAdd ? 1 : 0.4)
                .disabled(!canAdd)
                .accessibilityLabel("Add item")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(background)
    }

    private var canAdd: Bool {
        !isAdding && !ItemInput.cleanName(newName).isEmpty
    }

    private func addItem() async {
        let name = ItemInput.cleanName(newName)
        guard !name.isEmpty, !isAdding else { return }
        isAdding = true
        defer { isAdding = false }
        let added = await model.add(name: name, count: ItemInput.parseCount(newCount))
        if added {
            newName = ""
            newCount = ""
            nameFocused = true
        }
    }

    private func tickFeedback() {
        #if canImport(UIKit)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }
}

// MARK: - Item row

/// "2 - Milk". Tapping crosses it off: grey and struck through, as on the website.
private struct ItemRow: View {
    let item: ListItem
    let canEdit: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 0) {
                label
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if canEdit {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
        .accessibilityLabel(spokenName)
        .accessibilityValue(item.checked ? "Crossed off" : "")
        .accessibilityHint(canEdit ? "Double tap to cross off or put back" : "")
        .accessibilityAddTraits(item.checked ? .isSelected : [])
    }

    private var label: Text {
        let prefix = item.count.map { "\($0) - " } ?? ""
        return Text(prefix + item.name)
            .strikethrough(item.checked)
            .foregroundColor(item.checked ? .gray : .black)
    }

    private var spokenName: String {
        if let count = item.count { return "\(count), \(item.name)" }
        return item.name
    }
}
