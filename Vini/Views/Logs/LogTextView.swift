import AppKit
import SwiftUI

/// An `NSTextView`-backed log viewer that supports:
/// - ANSI color rendering via `NSAttributedString`
/// - Full cross-line text selection and copy
/// - Line wrapping (no horizontal scrolling)
/// - Auto-scroll to bottom on new content
/// - Built-in Cmd+F find bar
struct LogTextView: NSViewRepresentable {
    let attributedText: NSAttributedString
    let fontSize: CGFloat
    @Binding var autoScroll: Bool
    @Binding var showFindBar: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = LogNSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false

        // Line wrapping: text container tracks the scroll view width
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]

        // Use the find bar (not the old-style find panel)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        scrollView.documentView = textView

        // Store reference for updates
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView

        // Track user scrolling
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        scrollView.contentView.postsBoundsChangedNotifications = true

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        // Update find bar visibility
        if showFindBar && !context.coordinator.findBarVisible {
            if let logTextView = textView as? LogNSTextView {
                logTextView.showFindInterface()
            }
            context.coordinator.findBarVisible = true
        }
        if !showFindBar && context.coordinator.findBarVisible {
            if let logTextView = textView as? LogNSTextView {
                logTextView.hideFindInterface()
            }
            context.coordinator.findBarVisible = false
        }

        // If autoScroll was just re-enabled (e.g. user pressed "Scroll to bottom"),
        // scroll immediately even if text hasn't changed.
        if autoScroll && !context.coordinator.wasAutoScroll {
            DispatchQueue.main.async {
                self.scrollToBottom(scrollView)
            }
        }
        context.coordinator.wasAutoScroll = autoScroll

        // Only update text if it actually changed (avoid unnecessary relayouts)
        let currentLength = textView.textStorage?.length ?? 0
        let newLength = attributedText.length

        if currentLength != newLength || (currentLength > 0 && textView.textStorage?.isEqual(to: attributedText) == false) {
            let wasAtBottom = context.coordinator.isAtBottom(scrollView)

            textView.textStorage?.setAttributedString(attributedText)

            // Scroll to bottom if auto-scroll is on and we were at the bottom
            if autoScroll && (wasAtBottom || context.coordinator.isFirstUpdate) {
                context.coordinator.isFirstUpdate = false
                DispatchQueue.main.async {
                    self.scrollToBottom(scrollView)
                }
            }
        }
    }

    private func scrollToBottom(_ scrollView: NSScrollView) {
        guard let documentView = scrollView.documentView else { return }
        let maxY = documentView.frame.maxY - scrollView.contentView.bounds.height
        if maxY > 0 {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        var parent: LogTextView
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var findBarVisible = false
        var isFirstUpdate = true
        var wasAutoScroll = true

        init(parent: LogTextView) {
            self.parent = parent
        }

        func isAtBottom(_ scrollView: NSScrollView) -> Bool {
            guard let documentView = scrollView.documentView else { return true }
            let visibleRect = scrollView.contentView.bounds
            let contentHeight = documentView.frame.height
            let threshold: CGFloat = 40
            return visibleRect.maxY >= contentHeight - threshold
        }

        @objc func scrollViewDidScroll(_ notification: Notification) {
            guard let scrollView else { return }
            let atBottom = isAtBottom(scrollView)
            if !atBottom && parent.autoScroll {
                // User scrolled away from bottom — disable auto-scroll
                parent.autoScroll = false
            } else if atBottom && !parent.autoScroll {
                // User scrolled back to bottom — re-enable
                parent.autoScroll = true
            }
        }
    }
}

/// A subclass that supports Cmd+F find bar activation.
final class LogNSTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Cmd+F → show find bar
        if event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.shift),
           !event.modifierFlags.contains(.option),
           event.charactersIgnoringModifiers == "f" {
            showFindInterface()
            return true
        }
        // Esc → hide find bar
        if event.keyCode == 53 { // Escape
            hideFindInterface()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Show the find bar using the standard menu action mechanism.
    func showFindInterface() {
        // NSTextView responds to performFindPanelAction: with a sender whose tag
        // maps to an NSTextFinder.Action. Tag 1 = showFindInterface.
        let menuItem = NSMenuItem()
        menuItem.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
        super.performFindPanelAction(menuItem)
    }

    /// Hide the find bar.
    func hideFindInterface() {
        let menuItem = NSMenuItem()
        menuItem.tag = Int(NSTextFinder.Action.hideFindInterface.rawValue)
        super.performFindPanelAction(menuItem)
    }
}
