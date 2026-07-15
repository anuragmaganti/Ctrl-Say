import AppKit
import SwiftUI

/// Registers an AppKit tooltip for exactly the SwiftUI region occupied by this
/// representable. The registration lives on the parent view, so this bridge is
/// hit-test transparent and does not interfere with clicks or swipe gestures.
struct NativeTooltipRegion: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> RegistrationView {
        let view = RegistrationView()
        view.tooltipText = text
        return view
    }

    func updateNSView(_ nsView: RegistrationView, context: Context) {
        nsView.tooltipText = text
        nsView.updateRegistrationIfNeeded()
    }

    final class RegistrationView: NSView, NSViewToolTipOwner {
        var tooltipText = "" {
            didSet {
                guard tooltipText != oldValue else { return }
                invalidateRegistration()
                updateRegistrationIfNeeded()
            }
        }

        private weak var registrationView: NSView?
        private var registrationTag: NSView.ToolTipTag?
        private var registrationRect = NSRect.zero

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewWillMove(toSuperview newSuperview: NSView?) {
            invalidateRegistration()
            super.viewWillMove(toSuperview: newSuperview)
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            updateRegistrationIfNeeded()
        }

        override func layout() {
            super.layout()
            updateRegistrationIfNeeded()
        }

        func updateRegistrationIfNeeded() {
            guard !tooltipText.isEmpty,
                  let superview,
                  bounds.width > 0,
                  bounds.height > 0 else {
                invalidateRegistration()
                return
            }

            let rect = convert(bounds, to: superview)
            guard registrationView !== superview
                    || registrationTag == nil
                    || registrationRect != rect else {
                return
            }

            invalidateRegistration()
            registrationView = superview
            registrationRect = rect
            registrationTag = superview.addToolTip(
                rect,
                owner: self,
                userData: nil
            )
        }

        func view(
            _ view: NSView,
            stringForToolTip tag: NSView.ToolTipTag,
            point: NSPoint,
            userData: UnsafeMutableRawPointer?
        ) -> String {
            tooltipText
        }

        private func invalidateRegistration() {
            if let registrationView, let registrationTag {
                registrationView.removeToolTip(registrationTag)
            }
            registrationView = nil
            registrationTag = nil
            registrationRect = .zero
        }
    }
}
