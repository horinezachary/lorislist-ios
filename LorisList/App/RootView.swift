import SwiftUI
import LorisListKit

/// Where the app can navigate to from the home screen.
enum Route: Hashable {
    case list(ListSummary)
    case account
    case devices
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        content
            .sheet(item: linkToShow) { link in
                switch link {
                case .passwordReset(let token):
                    ResetPasswordSheet(token: token)
                case .invitation(let key):
                    InvitationSheet(key: key)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .launching:
            LaunchView()
        case .signedOut:
            AuthFlow()
        case .signedIn:
            MainView()
        }
    }

    /// A reset link can be used from any state. An invitation needs a sign-in first, so while
    /// signed out it waits (the sign-in screen says so) and appears once the person is in.
    private var linkToShow: Binding<AppLink?> {
        Binding(
            get: {
                guard let link = model.pendingLink else { return nil }
                switch (link, model.phase) {
                case (_, .launching): return nil
                case (.invitation, .signedOut): return nil
                default: return link
                }
            },
            set: { newValue in
                if newValue == nil { model.finishLink() }
            })
    }
}

/// Shown for a moment while the app checks whether the saved sign-in still works.
struct LaunchView: View {
    var body: some View {
        ZStack {
            Theme.navGradient.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Lori's List")
                    .font(.largeTitle.bold())
                    .foregroundColor(.white)
                ProgressView().tint(.white)
            }
        }
    }
}

/// Everything after sign-in: a stack of screens on iPhone, and the lists beside the open list on iPad.
struct MainView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .regular {
            SplitMainView()
        } else {
            StackMainView()
        }
    }
}

/// iPhone: the home screen, with a list sliding in over it.
private struct StackMainView: View {
    @EnvironmentObject private var model: AppModel
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(app: model)
                .onChange(of: model.listToOpen) { _, list in
                    guard let list else { return }
                    path = [.list(list)]
                    model.listToOpen = nil
                }
                .navigationDestination(for: Route.self) { route in
                    destination(for: route, model: model)
                }
        }
        // The back button follows the stack's tint, so it matches whichever bar is showing.
        .tint(model.navigationTint?.color ?? Theme.link)
    }
}

/// iPad: the list of lists stays on the left and the chosen list opens on the right.
private struct SplitMainView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selected: ListSummary?
    @State private var detailPath: [Route] = []
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            ListsSidebar(
                app: model,
                selectedID: selected?.id,
                onSelect: { list in
                    selected = list
                    detailPath = []
                },
                onShowAccount: { detailPath = [.account] })
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
        } detail: {
            NavigationStack(path: $detailPath) {
                Group {
                    if let selected {
                        ListDetailView(summary: selected, app: model, onClose: { self.selected = nil })
                            .id(selected.id)
                    } else {
                        ContentUnavailableView(
                            "No List Open",
                            systemImage: "list.bullet",
                            description: Text("Choose a list on the left."))
                            .navigationTitle("")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                }
                .navigationDestination(for: Route.self) { route in
                    destination(for: route, model: model)
                }
            }
            .tint(model.navigationTint?.color ?? Theme.link)
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: model.listToOpen) { _, list in
            guard let list else { return }
            selected = list
            detailPath = []
            model.listToOpen = nil
        }
    }
}

@MainActor @ViewBuilder
private func destination(for route: Route, model: AppModel) -> some View {
    switch route {
    case .list(let summary):
        ListDetailView(summary: summary, app: model)
    case .account:
        AccountView()
    case .devices:
        DevicesView(api: model.api)
    }
}
