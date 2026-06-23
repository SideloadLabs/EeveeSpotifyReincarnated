import SwiftUI

/// Wraps child views onto multiple rows when they don't fit the available
/// width — needed so karaoke lines wrap naturally at the screen edge like
/// real running text, rather than being clipped or forced onto one line.
///
/// SwiftUI's Layout protocol (the clean way to do this) is iOS 16+. This
/// project's only existing @available check gates at iOS 15, so on iOS 15
/// devices we fall back to a simple non-wrapping HStack instead of crashing
/// — lines will run off-screen on iOS 15 rather than wrapping, which is a
/// known limitation rather than a silent bug, until/unless iOS 15 support
/// for this specific view is worth a more involved manual-wrapping fallback.
struct KaraokeFlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 16.0, *) {
            KaraokeFlowLayoutImpl(spacing: spacing) {
                content()
            }
        } else {
            HStack(spacing: spacing) {
                content()
            }
        }
    }
}

@available(iOS 16.0, *)
private struct KaraokeFlowLayoutImpl: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
