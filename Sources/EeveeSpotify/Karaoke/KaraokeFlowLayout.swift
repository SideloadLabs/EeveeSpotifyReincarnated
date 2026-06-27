import SwiftUI

/// Wraps child views onto multiple rows when they don't fit the available
/// width — needed so karaoke lines wrap naturally at the screen edge like
/// real running text, rather than being clipped or forced onto one line —
/// and centers each wrapped row horizontally, matching Spotify's own
/// centered lyrics view (and Spicetify's) rather than ragged left-aligned
/// text.
///
/// SwiftUI's Layout protocol (the clean way to do this) is iOS 16+. This
/// project's only existing @available check gates at iOS 15, so on iOS 15
/// devices we fall back to a simple non-wrapping, centered HStack instead
/// of crashing — lines will run off-screen on iOS 15 rather than wrapping,
/// which is a known limitation rather than a silent bug, until/unless iOS
/// 15 support for this specific view is worth a more involved
/// manual-wrapping fallback.
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
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

@available(iOS 16.0, *)
private struct KaraokeFlowLayoutImpl: Layout {
    let spacing: CGFloat

    /// One wrapped row: which subview indices it contains, their
    /// individually-measured sizes, and the row's total content width
    /// (sum of subview widths + interior spacing). Computing this width
    /// up front — rather than just placing subviews left-to-right as
    /// they're measured — is what lets placeSubviews center each row
    /// within the available width instead of starting it flush at the
    /// leading edge.
    private struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                rows.append(current)
                current = Row()
                x = 0
            }
            current.indices.append(index)
            current.sizes.append(size)
            current.width = x + size.width
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(subviews: subviews, maxWidth: maxWidth)
        let totalHeight = rows.reduce(CGFloat(0)) { $0 + $1.height }
            + CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY

        for row in rows {
            // Center this row's total content width within the available
            // width — this, plus the matching VStack(alignment: .center)
            // change in KaraokeScrollingLines, is what makes lyrics read
            // centered like Spotify's own lyrics view instead of
            // left-aligned.
            var x = bounds.minX + (bounds.width - row.width) / 2

            for (offset, index) in row.indices.enumerated() {
                let size = row.sizes[offset]
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }
}
