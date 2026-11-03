import Combine
import SwiftUI
import LorisListKit

// MARK: - Model

@MainActor
final class HomeModel: ObservableObject {
    @Published private(set) var lists: [ListSummary] = []
    /// There is something to show: lists were fetched at some point, here or on an earlier run.
    @Published private(set) var hasLoaded = false
    @Published var errorText: String?

    private let api: APIClient
    private let sync: SyncEngine
    private var subscription: AnyCancellable?

    init(api: APIClient, sync: SyncEngine, events: AnyPublisher<SyncEvent, Never>) {
        self.api = api
        self.sync = sync
        subscription = events.sink { [weak self] event in
            if case .lists = event { Task { await self?.reload() } }
        }
        // The saved copy first, so the screen is never empty on a launch without a connection.
        Task { await reload() }
    }

    var groups: ListGroups { ListGroups(lists) }

    private func reload() async {
        lists = await sync.lists()
        hasLoaded = await sync.hasData()
    }

    /// Sends anything waiting, fetches what changed, and shows the result.
    func load() async {
        await sync.sync()
        await reload()
        errorText = nil
    }

    // Making, renaming, deleting and leaving lists need the server, so they say so when offline.

    func create(name: String, color: String) async throws {
        _ = try await api.createList(name: name, color: color)
        await load()
    }

    func update(_ list: ListSummary, name: String, color: String) async throws {
        _ = try await api.updateList(id: list.id, name: name, color: color)
        await load()
    }

    func delete(_ list: ListSummary) async {
        do {
            try await api.deleteList(id: list.id)
            await load()
        } catch is CancellationError {
            return
        } catch {
            report(error)
        }
    }

    func leave(_ list: ListSummary) async {
        do {
            try await api.leaveList(id: list.id)
            await load()
        } catch is CancellationError {
            return
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        // An expired session already sent the person to the sign-in screen.
        if let apiError = error as? APIError, apiError.code == .sessionExpired { return }
        errorText = error.localizedDescription
    }
}

// MARK: - View

struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model: HomeModel

    @State private var sheet: HomeSheet?
    @State private var listToDelete: ListSummary?
    @State private var listToLeave: ListSummary?

    enum HomeSheet: Identifiable {
        case create
        case edit(ListSummary)
        case share(ListSummary)

        var id: String {
            switch self {
            case .create: return "create"
            case .edit(let list): return "edit-\(list.id)"
            case .share(let list): return "share-\(list.id)"
            }
        }
    }

    init(app: AppModel) {
        _model = StateObject(wrappedValue: HomeModel(
            api: app.api, sync: app.sync, events: app.syncEvents.eraseToAnyPublisher()))
    }

    var body: some View {
        CardColumn {
            SyncBanner()
            if let errorText = model.errorText {
                Banner(.error, errorText)
            }

            Card {
                CardTitle("My Lists")

                if !model.hasLoaded && model.errorText == nil {
                    RowDivider()
                    if app.syncState.isOnline {
                        ProgressView()
                            .padding(24)
                    } else {
                        Text("Can't reach Lori's List. Your lists will appear here once you're connected.")
                            .font(.subheadline)
                            .foregroundColor(Theme.mutedText)
                            .multilineTextAlignment(.center)
                            .padding(20)
                    }
                } else if model.groups.mine.isEmpty && model.hasLoaded {
                    RowDivider()
                    Text("You don't have any lists yet. Tap New List to make your first one.")
                        .font(.subheadline)
                        .foregroundColor(Theme.mutedText)
                        .multilineTextAlignment(.center)
                        .padding(20)
                }

                ForEach(model.groups.mine) { list in
                    RowDivider()
                    ListRow(
                        list: list,
                        onEdit: { sheet = .edit(list) },
                        onShare: { sheet = .share(list) },
                        onDelete: { listToDelete = list },
                        onLeave: nil)
                }

                RowDivider()
                HStack {
                    Spacer()
                    Button("New List") { sheet = .create }
                        .buttonStyle(.appDark)
                }
                .padding(12)
            }

            if !model.groups.shared.isEmpty {
                Card {
                    CardTitle("Shared Lists")
                    ForEach(model.groups.shared) { list in
                        RowDivider()
                        ListRow(
                            list: list,
                            onEdit: nil,
                            onShare: nil,
                            onDelete: nil,
                            onLeave: { listToLeave = list })
                    }
                }
            }
        }
        .refreshable { await model.load() }
        .navigationTitle("Lori's List")
        .navigationBarTitleDisplayMode(.inline)
        .brandedNavigationBar()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink(value: Route.account) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title3)
                }
                .accessibilityLabel("My Account")
            }
        }
        .task {
            await model.load()
            await app.loadColors()
        }
        .sheet(item: $sheet) { current in
            switch current {
            case .create:
                ListEditorSheet(mode: .create, colors: app.colors) { name, color in
                    try await model.create(name: name, color: color)
                }
            case .edit(let list):
                ListEditorSheet(mode: .edit(list), colors: app.colors) { name, color in
                    try await model.update(list, name: name, color: color)
                }
            case .share(let list):
                ShareSheet(list: list, api: app.api)
            }
        }
        .alert(
            "Delete List",
            isPresented: Binding(get: { listToDelete != nil }, set: { if !$0 { listToDelete = nil } }),
            presenting: listToDelete
        ) { list in
            Button("Yes", role: .destructive) {
                Task { await model.delete(list) }
            }
            Button("No", role: .cancel) {}
        } message: { list in
            Text("You are about to delete your \"\(list.name)\" list, are you sure?")
        }
        .alert(
            "Unsubscribe from List",
            isPresented: Binding(get: { listToLeave != nil }, set: { if !$0 { listToLeave = nil } }),
            presenting: listToLeave
        ) { list in
            Button("Yes", role: .destructive) {
                Task { await model.leave(list) }
            }
            Button("No", role: .cancel) {}
        } message: { list in
            Text("You are about to remove your permissions for \(list.name). You will have to be re-invited by the owner if you would like access to this list again, are you sure?")
        }
    }
}

// MARK: - Row

/// One list, drawn in its own colour with its name in white (or dark, on light colours).
private struct ListRow: View {
    let list: ListSummary
    let onEdit: (() -> Void)?
    let onShare: (() -> Void)?
    let onDelete: (() -> Void)?
    let onLeave: (() -> Void)?

    var body: some View {
        let foreground = Color.foreground(on: list.color)

        HStack(spacing: 0) {
            NavigationLink(value: Route.list(list)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(list.name)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                    if list.role != .owner {
                        Text(subtitle)
                            .font(.caption)
                            .opacity(0.9)
                    }
                }
                .foregroundColor(foreground)
                .padding(.leading, 20)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                if let onEdit {
                    Button(action: onEdit) {
                        Label("Edit", systemImage: "pencil")
                    }
                }
                if let onShare {
                    Button(action: onShare) {
                        Label("Share", systemImage: "person.badge.plus")
                    }
                }
                if let onDelete {
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                }
                if let onLeave {
                    Button(role: .destructive, action: onLeave) {
                        Label("Unsubscribe", systemImage: "person.badge.minus")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundColor(foreground)
                    .frame(width: 52, height: 56)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Options for \(list.name)")
        }
        .background(Color(hex: list.color))
    }

    private var subtitle: String {
        let what = list.role == .edit ? "you can edit" : "view only"
        return "Shared by \(list.owner) · \(what)"
    }
}

// MARK: - iPad sidebar

/// The lists on iPad, in a system list down the left. The open list's row is filled with its colour.
struct ListsSidebar: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model: HomeModel

    let selectedID: Int?
    let onSelect: (ListSummary) -> Void
    let onShowAccount: () -> Void
    /// Tucks the list of lists away. Its button sits on this side while the lists show, and moves
    /// to the open list's bar while they are hidden, as in the Files app.
    let onHide: () -> Void

    @State private var sheet: HomeView.HomeSheet?
    @State private var listToDelete: ListSummary?
    @State private var listToLeave: ListSummary?

    init(app: AppModel, selectedID: Int?, onSelect: @escaping (ListSummary) -> Void,
         onShowAccount: @escaping () -> Void, onHide: @escaping () -> Void) {
        self.onHide = onHide
        _model = StateObject(wrappedValue: HomeModel(
            api: app.api, sync: app.sync, events: app.syncEvents.eraseToAnyPublisher()))
        self.selectedID = selectedID
        self.onSelect = onSelect
        self.onShowAccount = onShowAccount
    }

    var body: some View {
        List {
            Section("My Lists") {
                if !model.hasLoaded && model.errorText == nil {
                    if app.syncState.isOnline {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Can't reach Lori's List. Your lists will appear here once you're connected.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else if model.groups.mine.isEmpty && model.hasLoaded {
                    Text("You don't have any lists yet. Tap + to make your first one.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.groups.mine) { list in
                    row(list)
                }
            }

            if !model.groups.shared.isEmpty {
                Section("Shared Lists") {
                    ForEach(model.groups.shared) { list in
                        row(list)
                    }
                }
            }
        }
        .listStyle(.plain)
        // Matches the column behind it: white, or a dark grey a step above the open list's black.
        .scrollContentBackground(.hidden)
        .background(Theme.cardBackground)
        // The rows keep the app's blue; the white below is for the buttons on the blue bar.
        .tint(Theme.link)
        .refreshable { await model.load() }
        // Messages sit in a bar above the lists and push them down while they show.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                SyncBanner(asBar: true)
                if let errorText = model.errorText {
                    Banner(.error, errorText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
            }
        }
        .navigationTitle("Lori's List")
        // Inline, so the bar is the same height as the open list's beside it.
        .navigationBarTitleDisplayMode(.inline)
        .brandedNavigationBar()
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    sheet = .create
                } label: {
                    Label("New List", systemImage: "plus")
                }
                Button(action: onShowAccount) {
                    Label("My Account", systemImage: "person.crop.circle.fill")
                }
                Button(action: onHide) {
                    Label("Hide Lists", systemImage: "sidebar.left")
                }
            }
        }
        .tint(.white)
        .task {
            await model.load()
            await app.loadColors()
        }
        .sheet(item: $sheet) { current in
            switch current {
            case .create:
                ListEditorSheet(mode: .create, colors: app.colors) { name, color in
                    try await model.create(name: name, color: color)
                }
            case .edit(let list):
                ListEditorSheet(mode: .edit(list), colors: app.colors) { name, color in
                    try await model.update(list, name: name, color: color)
                }
            case .share(let list):
                ShareSheet(list: list, api: app.api)
            }
        }
        .alert(
            "Delete List",
            isPresented: Binding(get: { listToDelete != nil }, set: { if !$0 { listToDelete = nil } }),
            presenting: listToDelete
        ) { list in
            Button("Yes", role: .destructive) {
                Task { await model.delete(list) }
            }
            Button("No", role: .cancel) {}
        } message: { list in
            Text("You are about to delete your \"\(list.name)\" list, are you sure?")
        }
        .alert(
            "Unsubscribe from List",
            isPresented: Binding(get: { listToLeave != nil }, set: { if !$0 { listToLeave = nil } }),
            presenting: listToLeave
        ) { list in
            Button("Yes", role: .destructive) {
                Task { await model.leave(list) }
            }
            Button("No", role: .cancel) {}
        } message: { list in
            Text("You are about to remove your permissions for \(list.name). You will have to be re-invited by the owner if you would like access to this list again, are you sure?")
        }
    }

    private func row(_ list: ListSummary) -> some View {
        let isSelected = list.id == selectedID
        let foreground = Color.foreground(on: list.color)

        return Button {
            onSelect(list)
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color(hex: list.color))
                    .overlay(Circle().stroke(foreground.opacity(isSelected ? 0.6 : 0), lineWidth: 1.5))
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(list.name)
                        .font(.body.weight(isSelected ? .semibold : .regular))
                        .lineLimit(2)
                    if list.role != .owner {
                        Text(list.role == .edit
                             ? "Shared by \(list.owner) · you can edit"
                             : "Shared by \(list.owner) · view only")
                            .font(.caption)
                            .opacity(0.8)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? foreground : Color.primary)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color(hex: list.color) : Color.clear)
        .listRowSeparator(isSelected ? .hidden : .automatic)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .swipeActions(edge: .trailing) {
            actions(for: list)
        }
        .contextMenu {
            actions(for: list)
        }
    }

    @ViewBuilder
    private func actions(for list: ListSummary) -> some View {
        if list.role == .owner {
            Button(role: .destructive) {
                listToDelete = list
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                sheet = .edit(list)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button {
                sheet = .share(list)
            } label: {
                Label("Share", systemImage: "person.badge.plus")
            }
        } else {
            Button(role: .destructive) {
                listToLeave = list
            } label: {
                Label("Unsubscribe", systemImage: "person.badge.minus")
            }
        }
    }
}
