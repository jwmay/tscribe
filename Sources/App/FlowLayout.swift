import SwiftUI

/// A simple left-to-right wrapping layout (like flowing text) for word chips.
///
/// Uses the `Layout` cache: measuring a `Text` is real text-layout work, and
/// SwiftUI probes `sizeThatFits` / `placeSubviews` many times per layout pass
/// (min/ideal/max negotiation, alignment queries, every frame of a scroll
/// animation). Chip sizes don't depend on the proposal, so measure each chip
/// once when the subviews change and answer every probe with arithmetic —
/// re-measuring thousands of chips per pass caused main-thread hangs.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 6

    struct Cache {
        var sizes: [CGSize]
        /// The last real width this layout was given. Nil-width probes (which
        /// lazy stacks use to ESTIMATE unbuilt rows) are answered with this,
        /// so estimated heights match actual heights. Answering nil with
        /// "one infinite line" made every estimate wildly short, and the
        /// scroll view's offset adjustments + lazy re-phasing fed each other
        /// into a main-thread livelock (transactions never drained).
        var lastConcreteWidth: CGFloat?
    }

    /// Fallback wrap width before any real layout pass has happened
    /// (≈ the transcript pane's content width).
    private static let nominalWidth: CGFloat = 640

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) }, lastConcreteWidth: nil)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    }

    /// The cached sizes, re-measured defensively if the count ever disagrees.
    private func sizes(_ cache: inout Cache, _ subviews: Subviews) -> [CGSize] {
        if cache.sizes.count != subviews.count {
            cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        }
        return cache.sizes
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let sizes = sizes(&cache, subviews)
        let maxWidth: CGFloat
        if let w = proposal.width, w.isFinite, w > 0 {
            maxWidth = w
            cache.lastConcreteWidth = w
        } else {
            maxWidth = cache.lastConcreteWidth ?? Self.nominalWidth
        }
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0

        for size in sizes {
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        if bounds.width.isFinite, bounds.width > 0 { cache.lastConcreteWidth = bounds.width }
        let sizes = sizes(&cache, subviews)
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0

        for (view, size) in zip(subviews, sizes) {
            if x + size.width > bounds.width, x > 0 {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                       proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
