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
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
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
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0

        for size in sizes {
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x)
            lineHeight = max(lineHeight, size.height)
        }
        let width = maxWidth == .infinity ? widest : maxWidth
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
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
