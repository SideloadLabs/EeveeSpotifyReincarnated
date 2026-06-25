import SwiftUI

/// Karaoke lyrics view. Uses a SwiftUI TimelineView (the supported,
/// declarative equivalent of a manual CADisplayLink/Timer loop inside
/// SwiftUI) to re-evaluate playback position ~30 times per second,
/// determines which line is "active" right now, and renders all lines
/// with KaraokeLineView — auto-scrolling so the active line stays
/// vertically centered, matching Spicetify's lyrics panel behavior.
///
/// Supports two presentation modes, controlled by `isCompact` (driven by
/// LyricsOptions.karaokeShrinkOverlay, set by KaraokeOverlayPresenter):
///   - Full (isCompact == false): edge-to-edge takeover, opaque
///     background, matching the original behavior.
///   - Compact (isCompact == true): a smaller, rounded-corner card with
///     margins on all sides, floating over a dimmed scrim — the caller
///     (KaraokeOverlayPresenter) is responsible for presenting with a
///     transparent hosting background and .overFullScreen so whatever was
///     underneath (Spotify's own native Lyrics screen) stays visible
///     through the scrim and around the card's margins, rather than this
///     view replacing it outright.
@available(iOS 15.0, *)
struct KaraokeLyricsView: View {
    let lyrics: KaraokeLyricsDto
    var isCompact: Bool = false
    /// Called when the user dismisses the view (e.g. tapping the close
    /// button, or tapping the scrim in compact mode).
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            if isCompact {
                compactBody
            } else {
                fullScreenBody
            }
        }
        .preferredColorScheme(.dark)
    }

    private var fullScreenBody: some View {
        ZStack(alignment: .topTrailing) {
            KaraokeBackgroundView()
            content
            closeButton
        }
    }

    private var compactBody: some View {
        ZStack {
            // The hosting UIWindow's own background is already transparent
            // (set by KaraokeOverlayPresenter), so this scrim is the only
            // thing dimming the native Lyrics screen behind it. Tapping
            // outside the card dismisses, mirroring how tapping outside a
            // sheet/popover normally behaves.
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            ZStack(alignment: .topTrailing) {
                KaraokeBackgroundView()
                content
                closeButton
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
            .padding(.horizontal, 14)
            .padding(.top, 64)
            .padding(.bottom, 100)
        }
    }

    @available(iOS 15.0, *)
    private var content: some View {
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
                isCompact: isCompact
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
                .padding(isCompact ? 10 : 14)
                .background(Circle().fill(Color.white.opacity(0.12)))
        }
        .padding(.top, isCompact ? 16 : 50)
        .padding(.trailing, isCompact ? 14 : 20)
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
    var isCompact: Bool = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: isCompact ? 18 : 28) {
                    Spacer().frame(height: isCompact ? 24 : 80)

                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        KaraokeLineView(
                            line: line,
                            currentMs: currentMs,
                            isActiveLine: index == activeLineIndex,
                            isCompact: isCompact
                        )
                        .id(index)
                        .padding(.horizontal, isCompact ? 16 : 24)
                    }

                    KaraokeCreditsFooterView(lyrics: lyrics)

                    Spacer().frame(height: isCompact ? 60 : 200)
                }
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
