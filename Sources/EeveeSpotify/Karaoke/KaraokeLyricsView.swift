import SwiftUI

/// Karaoke lyrics view. Uses a SwiftUI TimelineView (the supported,
/// declarative equivalent of a manual CADisplayLink/Timer loop inside
/// SwiftUI) to re-evaluate playback position ~30 times per second,
/// determines which line is "active" right now, and renders all lines
/// with KaraokeLineView — auto-scrolling so the active line stays
/// vertically centered, matching Spicetify's lyrics panel behavior.
///
/// Lyrics text itself is horizontally centered (VStack(alignment: .center)
/// below, plus the matching per-row centering inside KaraokeFlowLayout) —
/// matching Spotify's own lyrics view and Spicetify's, rather than ragged
/// left-aligned text. The screen width is read explicitly via
/// GeometryReader and threaded all the way down to KaraokeLineView as a
/// concrete `availableWidth`, rather than relying on `.frame(maxWidth:
/// .infinity)` to implicitly pass a usable width to the custom
/// Layout-conforming KaraokeFlowLayoutImpl. That implicit approach is
/// what an earlier version of this file used, and it doesn't actually
/// work for a custom Layout: `.frame(maxWidth: .infinity)` expands the
/// *outer* container to fill available space, but during the sizing
/// query it can still propose a nil/unspecified width to the *child* —
/// and KaraokeFlowLayoutImpl's sizeThatFits falls back to `proposal.width
/// ?? .infinity` when that happens, meaning no wrapping decision gets
/// made at all: the whole line renders as one long unwrapped row at its
/// natural width, which then gets positioned (not centered the way a
/// plain Text would be) within the expanded frame — reading as left-
/// aligned/overflowing rather than centered. Giving KaraokeLineView a
/// concrete, non-nil width to apply via `.frame(width:)` (a fixed
/// constraint, not a flexible one) removes that ambiguity entirely.
@available(iOS 15.0, *)
struct KaraokeLyricsView: View {
    let lyrics: KaraokeLyricsDto
    /// Called when the user dismisses the view (e.g. tapping the close
    /// button).
    var onDismiss: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                KaraokeBackgroundView()
                content(screenWidth: geo.size.width)
                closeButton
            }
        }
        .preferredColorScheme(.dark)
    }

    @available(iOS 15.0, *)
    private func content(screenWidth: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
            // Reading the tracker here, inside the TimelineView's per-tick
            // closure, is what actually drives the animation — TimelineView
            // re-invokes this closure on its schedule, and since this read
            // is a plain computed value (not @State), there's no separate
            // "fire a side effect to update state" step needed; the new
            // value flows straight into the child views' bodies each tick.
            let currentMs = KaraokePlaybackTracker.shared.currentPositionMs()
            let activeIndex = activeLineIndex(at: currentMs)

            KaraokeScrollingLines(
                lyrics: lyrics,
                currentMs: currentMs,
                activeLineIndex: activeIndex,
                screenWidth: screenWidth
            )
        }
    }

    private func activeLineIndex(at currentMs: Int) -> Int? {
        guard !lyrics.lines.isEmpty else { return nil }
        for (index, line) in lyrics.lines.enumerated().reversed() {
            if currentMs >= line.startMs {
                return index
            }
        }
        return nil
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "chevron.down")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .padding(14)
                .background(Circle().fill(Color.white.opacity(0.12)))
        }
        .padding(.top, 50)
        .padding(.trailing, 20)
    }
}

/// Separated into its own view so SwiftUI can diff/update just the
/// scrolling content each tick without re-creating the ScrollViewReader's
/// identity, which would otherwise reset scroll position every frame.
@available(iOS 15.0, *)
private struct KaraokeScrollingLines: View {
    let lyrics: KaraokeLyricsDto
    let currentMs: Int
    let activeLineIndex: Int?
    let screenWidth: CGFloat

    private let horizontalPadding: CGFloat = 24

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .center, spacing: 28) {
                    Spacer().frame(height: 80)

                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        KaraokeLineView(
                            line: line,
                            currentMs: currentMs,
                            isActiveLine: index == activeLineIndex,
                            availableWidth: max(0, screenWidth - horizontalPadding * 2)
                        )
                        .id(index)
                        .padding(.horizontal, horizontalPadding)
                    }

                    KaraokeCreditsFooterView(lyrics: lyrics)

                    Spacer().frame(height: 200)
                }
                .frame(maxWidth: .infinity)
            }
            .onAppear {
                // Without this, opening the view mid-song shows the very
                // top of the lyrics (the ScrollView's default starting
                // position) rather than the line that's actually playing
                // right now — .onChange below only fires on a *change*,
                // not for the initial value, so the very first active line
                // needs its own explicit, unanimated jump to center here.
                guard let activeLineIndex = activeLineIndex, activeLineIndex < lyrics.lines.count else { return }
                proxy.scrollTo(activeLineIndex, anchor: .center)
            }
            .onChange(of: activeLineIndex) { newIndex in
                guard let newIndex = newIndex, newIndex < lyrics.lines.count else { return }
                // Approximates ScrollIntoCenterView's piecewise curve (slow
                // start, speed up, slight overshoot past 1.0 around 65-85%,
                // settle back) with a single cubic timing curve — SwiftUI's
                // withAnimation only takes one Bezier, not the original's
                // 4-segment piecewise function, but control points beyond
                // 1.0 still produce a similar overshoot-and-settle feel.
                withAnimation(.timingCurve(0.3, 1.4, 0.7, 1.0, duration: 0.8)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }
}
