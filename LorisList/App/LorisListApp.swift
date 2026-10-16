import SwiftUI

@main
struct LorisListApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task { await model.start() }
                .tint(Theme.link)
                // The design is the website's: white cards on grey. It is not drawn for dark mode.
                .preferredColorScheme(.light)
        }
    }
}
