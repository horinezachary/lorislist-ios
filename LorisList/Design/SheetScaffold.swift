import SwiftUI

/// The frame shared by the app's pop-up forms (the website's Bootstrap modals): a blue title
/// bar with Cancel, and a white body that scrolls when the keyboard is up.
struct SheetScaffold<Content: View>: View {
    let title: String
    private let content: Content

    @Environment(\.dismiss) private var dismiss

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.white.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .brandedNavigationBar()
        }
        .presentationDetents([.medium, .large])
    }
}
