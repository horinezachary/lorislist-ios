import SwiftUI
import LorisListKit

// MARK: - Model

@MainActor
final class HomeModel: ObservableObject {
    @Published private(set) var lists: [ListSummary] = []
    @Published private(set) var hasLoaded = false
    @Published var errorText: String?

    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    var groups: ListGroups { ListGroups(lists) }

    func load() async {
        do {
            lists = try await api.lists()
            hasLoaded = true
            errorText = nil
        } catch is CancellationError {
            // Left the screen, or a pull-to-refresh was interrupted. Not an error.
        } catch {
            report(error)
        }
    }

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
            lists.removeAll { $0.id == list.id }
        } catch is CancellationError {
            return
        } catch {
            report(error)
        }
    }

    func leave(_ list: ListSummary) async {
        do {
            try await api.leaveList(id: list.id)
            lists.removeAll { $0.id == list.id }
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
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: HomeModel

    @State private var sheet: HomeSheet?
    @State private var listToDelete: ListSummary?
    @State private var listToLeave: ListSummary?

    enum HomeSheet: Identifiable {
        case create
        case edit(ListSummary)

        var id: String {
            switch self {
            case .create: return "create"
            case .edit(let list): return "edit-\(list.id)"
            }
        }
    }

    init(api: APIClient) {
        _model = StateObject(wrappedValue: HomeModel(api: api))
    }

    var body: some View {
        CardColumn {
            if let errorText = model.errorText {
                Banner(.error, errorText)
            }

            Card {
                CardTitle("My Lists")

                if !model.hasLoaded && model.errorText == nil {
                    RowDivider()
                    ProgressView()
                        .padding(24)
                } else if model.groups.mine.isEmpty && model.hasLoaded {
                    RowDivider()
                    Text("You don't have any lists yet. Tap New List to make your first one.")
                        .font(.subheadline)
                        .foregroundColor(Color(hex: "495057"))
                        .multilineTextAlignment(.center)
                        .padding(20)
                }

                ForEach(model.groups.mine) { list in
                    RowDivider()
                    ListRow(
                        list: list,
                        onEdit: { sheet = .edit(list) },
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.load() }
            }
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
