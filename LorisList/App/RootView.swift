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

/// Everything after sign-in.
struct MainView: View {
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
                    switch route {
                    case .list(let summary):
                        ListDetailView(summary: summary, app: model)
                    case .account:
                        AccountView()
                    case .devices:
                        DevicesView(api: model.api)
                    }
                }
        }
    }
}
