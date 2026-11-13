import AppKit
import SwiftUI

extension View {
    /// `height` tall and out to the edges of its row in a grouped `Form`. `listRowInsets` doesn't do that there, and with
    /// negative padding the row works out another height (seen on macOS 27), so it gets something to go by and this goes over
    /// that.
    func fillingFormRow(height: CGFloat) -> some View {
        Color.clear
            .frame(height: height - formRowInset * 2)
            .overlay {
                frame(height: height)
                    .padding(.horizontal, -formRowInset)
            }
    }
}

/// How far a grouped `Form` keeps what's in a row from the row's edges.
let formRowInset: CGFloat = 10

extension NSScrollView {
    /// A view that scrolls `table`, showing what's behind it.
    static func holding(_ table: NSTableView, in scrollView: NSScrollView = ContainedScrollView()) -> NSScrollView {
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        return scrollView
    }
}

/// A list in the page that keeps the wheel once it's got to an end, instead of passing it on to the page, which would move
/// with a list that only scrolls a little before anyone meant it to. A list that all fits has nothing to scroll, so there the
/// page does get it.
final class ContainedScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let room = (documentView?.frame.height ?? 0) - contentView.bounds.height
        let offset = contentView.bounds.minY
        let delta = event.scrollingDeltaY
        if room > 0, delta > 0 && offset <= 0 || delta < 0 && offset >= room {
            return
        }
        super.scrollWheel(with: event)
    }
}

/// A list in the page that scrolls to its end and then goes straight on with the page, in the same movement of the fingers.
final class PageChainingScrollView: NSScrollView {
    /// The fingers' movement has gone on to the page, where it stays until they start another. Turning back wouldn't go back to
    /// the list, as the page has moved it from under the pointer.
    private var isWithPage = false

    private var page: NSResponder? { enclosingScrollView ?? nextResponder }

    private var room: CGFloat {
        (documentView?.frame.height ?? 0) - contentView.bounds.height
    }

    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began || event.phase == .mayBegin {
            isWithPage = false
        }
        guard !isWithPage else {
            page?.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY
        let offset = contentView.bounds.minY
        // Half a point short still counts, as the list stops on whole pixels.
        let isAtEnd = room <= 0 || delta > 0 && offset <= 0.5 || delta < 0 && offset >= room - 0.5
        guard isAtEnd, delta != 0 else {
            super.scrollWheel(with: event)
            return
        }
        // Only a trackpad's movement has phases. A mouse wheel's clicks are each on their own.
        if !event.phase.isEmpty || !event.momentumPhase.isEmpty {
            isWithPage = true
        }
        page?.scrollWheel(with: event)
    }
}
