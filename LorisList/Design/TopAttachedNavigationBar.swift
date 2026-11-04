import SwiftUI
import UIKit

extension View {
    /// Lets a coloured top bar reach the top edge of the screen when no status bar sits above it.
    ///
    /// On a phone whose status bar runs down the side (the narrow layout of iPhone Duo), the
    /// window has no top safe area, yet the navigation controller still sets its bar a little way
    /// down. With nothing above it the bar counts as `.top` rather than `.topAttached`, so its
    /// background stops short and the page shows through in a strip above it. Marking that strip
    /// as safe area makes the bar top-attached again, and it draws its background up to the edge.
    /// Where a status bar is above the bar (any other iPhone, or an iPad) nothing changes.
    func topAttachedNavigationBar() -> some View {
        background(TopAttachedNavigationBar().frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

private struct TopAttachedNavigationBar: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.install() }

    final class Controller: UIViewController {
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            install()
        }

        /// Puts a watcher in the navigation controller's own view, so the strip is measured again
        /// whenever that view changes size or safe area (folding, unfolding, rotating), not only
        /// when this screen happens to lay out.
        func install() {
            guard let navigation = navigationController else { return }
            if !navigation.view.subviews.contains(where: { $0 is Watcher }) {
                let watcher = Watcher(frame: navigation.view.bounds)
                watcher.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                watcher.isUserInteractionEnabled = false
                watcher.navigation = navigation
                navigation.view.insertSubview(watcher, at: 0)
            }
            Watcher.attachBar(of: navigation)
        }
    }

    final class Watcher: UIView {
        weak var navigation: UINavigationController?

        override func layoutSubviews() {
            super.layoutSubviews()
            scheduleAttach()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            scheduleAttach()
        }

        /// After the current layout pass, so the bar has already moved to its new place.
        private func scheduleAttach() {
            DispatchQueue.main.async { [weak self] in
                guard let navigation = self?.navigation else { return }
                Watcher.attachBar(of: navigation)
            }
        }

        static func attachBar(of navigation: UINavigationController) {
            guard let window = navigation.view.window else { return }
            let bar = navigation.navigationBar
            // The gap between the top of the navigation controller's view and its bar, when no
            // status bar already claims it. Measured without the inset this sets, so it stays put.
            let gap = window.safeAreaInsets.top == 0 && !bar.isHidden
                ? bar.frame.minY - (navigation.view.safeAreaInsets.top - navigation.additionalSafeAreaInsets.top)
                : 0
            let inset = max(0, gap)
            if navigation.additionalSafeAreaInsets.top != inset {
                navigation.additionalSafeAreaInsets.top = inset
            }
        }
    }
}
