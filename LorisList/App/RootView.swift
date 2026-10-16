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
        switch model.phase {
        case .launching:
            LaunchView()
        case .signedOut:
            AuthFlow()
        case .signedIn:
            MainView()
        }
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
            HomeView(api: model.api)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .list(let summary):
                        ListDetailView(summary: summary, api: model.api)
                    case .account:
                        AccountView()
                    case .devices:
                        DevicesView(api: model.api)
                    }
                }
        }
    }
}
