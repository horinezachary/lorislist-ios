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
    private let api: APIClient
    private var subscription: AnyCancellable?
    let listID: Int

    init(summary: ListSummary, api: APIClient, sync: SyncEngine, events: AnyPublisher<SyncEvent, Never>) {
        self.api = api
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

    // Renaming, deleting and leaving the list need the server, as they do on the home screen.

    func update(name: String, color: String) async throws {
        _ = try await api.updateList(id: listID, name: name, color: color)
        await sync.sync()
        await reload(fromEvent: false)
    }

    /// Returns true when the list is gone and the screen should close.
    func delete() async -> Bool {
        await perform { try await self.api.deleteList(id: self.listID) }
    }

    /// Returns true when the person no longer has the list and the screen should close.
    func leave() async -> Bool {
        await perform { try await self.api.leaveList(id: self.listID) }
    }

    private func perform(_ request: () async throws -> Void) async -> Bool {
        do {
            try await request()
            errorText = nil
            // Tells the home screen, which follows the sync's events.
            await sync.sync()
            return true
        } catch is CancellationError {
            return false
        } catch {
            // An expired session already sent the person to the sign-in screen.
            if let apiError = error as? APIError, apiError.code == .sessionExpired { return false }
            errorText = error.localizedDescription
            return false
        }
    }
}


// MARK: - View

/// One list, drawn with the system's own pieces: the navigation bar takes the list's colour and
/// name and holds its actions, the items run edge to edge, and the "add item" bar sits at the
/// bottom of the screen and rides up with the keyboard.
struct ListDetailView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ListDetailModel

    @State private var newName = ""
    @State private var newCount = ""
    @State private var isAdding = false
    @State private var showShare = false
    @State private var showEditor = false
    @State private var confirmDelete = false
    @State private var confirmLeave = false
    @State private var tipDismissed = false
    @FocusState private var nameFocused: Bool

    init(summary: ListSummary, app: AppModel) {
        _model = StateObject(wrappedValue: ListDetailModel(
            summary: summary, api: app.api, sync: app.sync, events: app.syncEvents.eraseToAnyPublisher()))
    }

    var body: some View {
        let summary = model.list.summary
        let barColor = Color(hex: summary.color)
        let barText = Color.foreground(on: summary.color)

        List {
            if showTip {
                tipBanner
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }

            ForEach(model.list.items) { item in
                ItemRow(
                    item: item,
                    canEdit: model.list.canEdit,
                    onToggle: {
                        tickFeedback()
                        Task { await model.toggle(item) }
                    },
                    onRemove: { Task { await model.remove(item) } })
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if !model.hasLoaded {
                ProgressView()
            } else if model.list.items.isEmpty {
                ContentUnavailableView(
                    model.list.canEdit ? "Nothing on this list yet" : "Nothing on this list",
                    systemImage: "checklist",
                    description: model.list.canEdit ? Text("Add something with the box below.") : nil)
            }
        }
        .refreshable { await model.load() }
        // Messages that matter right now stay in view above the items.
        .safeAreaInset(edge: .top, spacing: 0) {
            topMessages
        }
        // A safe-area inset follows the keyboard, so the add bar rises with it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.list.canEdit {
                addBar(accent: barColor, accentText: barText)
            }
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(list: summary, api: app.api)
        }
        .sheet(isPresented: $showEditor) {
            ListEditorSheet(mode: .edit(summary), colors: app.colors) { name, color in
                try await model.update(name: name, color: color)
            }
        }
        .alert("Delete List", isPresented: $confirmDelete) {
            Button("Yes", role: .destructive) {
                Task { if await model.delete() { dismiss() } }
            }
            Button("No", role: .cancel) {}
        } message: {
            Text("You are about to delete your \"\(summary.name)\" list, are you sure?")
        }
        .alert("Unsubscribe from List", isPresented: $confirmLeave) {
            Button("Yes", role: .destructive) {
                Task { if await model.leave() { dismiss() } }
            }
            Button("No", role: .cancel) {}
        } message: {
            Text("You are about to remove your permissions for \(summary.name). You will have to be re-invited by the owner if you would like access to this list again, are you sure?")
        }
        // Everything above keeps the app's blue; the top bar (below) is drawn in the list's colours.
        .tint(Theme.link)
        .navigationTitle(summary.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(barColor, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(HexColor.prefersDarkText(on: summary.color) ? .light : .dark, for: .navigationBar)
        .toolbar { toolbarContent(summary: summary) }
        .tint(barText)
        // The back button takes its colour from the navigation stack, so tell it to match the bar.
        .onAppear { app.navigationTint = barText }
        .onChange(of: summary.color) { _, _ in app.navigationTint = barText }
        .onDisappear { app.navigationTint = nil }
        .task { await model.load() }
        .onChange(of: model.isGone) { _, gone in
            if gone { dismiss() }
        }
    }

    // MARK: Top bar

    @ToolbarContentBuilder
    private func toolbarContent(summary: ListSummary) -> some ToolbarContent {
        // A shared list says whose it is under its name.
        if summary.role != .owner {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(summary.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(summary.role == .edit
                         ? "Shared by \(summary.owner) · you can edit"
                         : "Shared by \(summary.owner) · view only")
                        .font(.caption2)
                        .lineLimit(1)
                }
                .foregroundStyle(Color.foreground(on: summary.color))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.list.canEdit {
                Button("Clear") {
                    Task { await model.clearCrossedOff() }
                }
                .disabled(model.list.checkedCount == 0)
                .accessibilityHint("Removes the crossed-off items")
            }

            if summary.role == .owner {
                Button {
                    showShare = true
                } label: {
                    Label("Share List", systemImage: "person.badge.plus")
                }
            }

            Menu {
                if summary.role == .owner {
                    Button {
                        showEditor = true
                    } label: {
                        Label("Edit List", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete List", systemImage: "trash")
                    }
                } else {
                    Button(role: .destructive) {
                        confirmLeave = true
                    } label: {
                        Label("Unsubscribe", systemImage: "person.badge.minus")
                    }
                }
            } label: {
                Label("List Options", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: Messages

    private var showTip: Bool {
        (app.user?.tipsEnabled ?? false) && !tipDismissed && model.list.canEdit
    }

    @ViewBuilder
    private var topMessages: some View {
        let sync = app.syncState
        let hasSyncNotice = sync.droppedCount > 0 || !sync.isOnline || sync.pendingCount > 0
        if hasSyncNotice || model.errorText != nil {
            VStack(spacing: 8) {
                SyncBanner()
                if let errorText = model.errorText {
                    Banner(.error, errorText)
                        .onTapGesture { Task { await model.load() } }
                        .accessibilityHint("Tap to try again")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    private var tipBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Welcome to your list! Here you can add things to your list using the text box below.")
            Text("Tap an item to cross it off, or swipe it to remove it.")
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
            .buttonStyle(.borderless)
            .font(.footnote.weight(.semibold))
        }
        .font(.subheadline)
        .foregroundColor(Theme.alertInfoText)
        .tint(Theme.alertInfoText)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.alertInfoBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Add bar

    private func addBar(accent: Color, accentText: Color) -> some View {
        let matches = ItemInput.suggestions(for: newName, from: model.suggestionPool)
        return VStack(spacing: 8) {
            if !matches.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(matches, id: \.self) { name in
                            Button(name) {
                                newName = name
                                nameFocused = true
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            HStack(spacing: 8) {
                TextField("#", text: $newCount)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .accessibilityLabel("Quantity")

                TextField("Add an item", text: $newName)
                    .focused($nameFocused)
                    .submitLabel(.send)
                    .onSubmit { Task { await addItem() } }
                    .onChange(of: newName) { _, value in
                        if value.count > ItemInput.maxNameLength {
                            newName = String(value.prefix(ItemInput.maxNameLength))
                        }
                    }
                    .textFieldStyle(.roundedBorder)

                Button {
                    Task { await addItem() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(accentText)
                        .frame(width: 34, height: 34)
                        .background(accent, in: Circle())
                }
                .buttonStyle(.plain)
                .opacity(canAdd ? 1 : 0.35)
                .disabled(!canAdd)
                .accessibilityLabel("Add item")
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
        .tint(Theme.link)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
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
/// Swiping it, or a long press, removes it.
private struct ItemRow: View {
    let item: ListItem
    let canEdit: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button(action: onToggle) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if canEdit {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
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
            .foregroundColor(item.checked ? .secondary : .primary)
    }

    private var spokenName: String {
        if let count = item.count { return "\(count), \(item.name)" }
        return item.name
    }
}
