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
        // On devices whose status bar sits at the side (iPhone Duo), the bar's colour stops short
        // of the screen's top edge. A zero-height strip at the top that ignores the safe area
        // paints the space above it in the bar's colour.
        .overlay(alignment: .top) {
            Group {
                if let bar = model.navigationTint?.barColor {
                    Rectangle().fill(bar)
                } else {
                    Rectangle().fill(Theme.navGradient)
                }
            }
            .ignoresSafeArea(edges: .top)
            .frame(height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// iPad: the list of lists stays on the left and the chosen list opens on the right.
///
/// Two stacks side by side rather than a split view: the system's split view floats its sidebar
/// over the open list, leaving a gap at the screen's edge and the list's bar showing beneath it.
/// Side by side, the list chooser runs to the top of the screen.
private struct SplitMainView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selected: ListSummary?
    @State private var detailPath: [Route] = []
    /// The list of lists can be tucked away for more room, on a small iPad or in portrait.
    @SceneStorage("showsListsSidebar") private var showsSidebar = true

    var body: some View {
        HStack(spacing: 0) {
            if showsSidebar {
                sidebar
                    .transition(.move(edge: .leading))
                    .zIndex(1)
            }
            detail
        }
        // Swiping left across the edge between the two tucks the lists away; with them hidden,
        // swiping right from the screen's left edge brings them back.
        .overlay(alignment: .leading) {
            if showsSidebar || detailPath.isEmpty {
                Color.clear
                    .frame(width: 28)
                    .contentShape(Rectangle())
                    .offset(x: showsSidebar ? Self.sidebarWidth - 14 : 0)
                    .ignoresSafeArea()
                    .gesture(
                        DragGesture(minimumDistance: 12)
                            .onEnded { drag in
                                let dx = drag.translation.width
                                guard abs(dx) > abs(drag.translation.height) else { return }
                                if showsSidebar && dx < -40 {
                                    setSidebar(false)
                                } else if !showsSidebar && dx > 40 {
                                    setSidebar(true)
                                }
                            })
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: model.listToOpen) { _, list in
            guard let list else { return }
            selected = list
            detailPath = []
            model.listToOpen = nil
        }
    }

    static let sidebarWidth: CGFloat = 320

    private func setSidebar(_ shown: Bool) {
        withAnimation(.easeInOut(duration: 0.25)) { showsSidebar = shown }
    }

    private var sidebar: some View {
        NavigationStack {
            ListsSidebar(
                app: model,
                selectedID: selected?.id,
                onSelect: { list in
                    selected = list
                    detailPath = []
                },
                onShowAccount: { detailPath = [.account] },
                onHide: { setSidebar(false) })
        }
        .frame(width: Self.sidebarWidth)
        // The edge between the two: a soft shadow in light mode, and in dark mode (where a
        // shadow on black can't be seen) a slightly lighter sidebar with a hairline edge.
        .background(Theme.cardBackground.ignoresSafeArea())
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(width: 1)
                .ignoresSafeArea()
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 6, x: 2, y: 0)
        .zIndex(1)
    }

    private var detail: some View {
        NavigationStack(path: $detailPath) {
            Group {
                if let selected {
                    ListDetailView(summary: selected, app: model, onClose: { self.selected = nil })
                        .id(selected.id)
                } else {
                    ContentUnavailableView(
                        "No List Open",
                        systemImage: "list.bullet",
                        description: Text(showsSidebar ? "Choose a list on the left." : "Tap the sidebar button to choose a list."))
                        .navigationTitle("")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            .toolbar {
                // While the lists show, their own bar holds this button.
                if !showsSidebar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            setSidebar(true)
                        } label: {
                            Label("Show Lists", systemImage: "sidebar.left")
                        }
                    }
                }
            }
            .navigationDestination(for: Route.self) { route in
                destination(for: route, model: model)
            }
        }
        .tint(model.navigationTint?.color ?? Theme.link)
        .frame(maxWidth: .infinity)
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
