import SwiftUI

@main
struct LorisListApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task { await model.start() }
                // Links in Lori's List emails open here when the site vouches for the app.
                .onOpenURL { model.handle(url: $0) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { model.handle(url: url) }
                }
                .tint(Theme.link)
                // The design is the website's: white cards on grey. It is not drawn for dark mode.
                .preferredColorScheme(.light)
        }
    }
}
