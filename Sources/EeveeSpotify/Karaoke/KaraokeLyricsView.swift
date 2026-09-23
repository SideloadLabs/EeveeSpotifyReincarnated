import SwiftUI

/// Karaoke lyrics view. Uses a SwiftUI TimelineView (the supported,
/// declarative equivalent of a manual CADisplayLink/Timer loop inside
/// SwiftUI) to re-evaluate playback position ~30 times per second,
/// determines which line is "active" right now, and renders all lines
/// with KaraokeLineView — auto-scrolling so the active line stays
/// vertically centered, matching Spicetify's lyrics panel behavior.
///
/// Lyrics text alignment (left/center/right, UserDefaults.karaokeOptions.
/// textAlignment) drives both the VStack's own alignment below and the
/// matching per-row alignment inside KaraokeFlowLayout — centered by
/// default, matching Spotify's own lyrics view and Spicetify's, rather
/// than ragged left-aligned text, but configurable via Settings. The
/// screen width is read explicitly via GeometryReader and threaded all
/// the way down to KaraokeLineView as a concrete `availableWidth`, rather
/// than relying on `.frame(maxWidth: .infinity)` to implicitly pass a
/// usable width to the custom Layout-conforming KaraokeFlowLayoutImpl.
/// That implicit approach is what an earlier version of this file used,
/// and it doesn't actually work for a custom Layout: `.frame(maxWidth:
/// .infinity)` expands the *outer* container to fill available space, but
/// during the sizing query it can still propose a nil/unspecified width
/// to the *child* — and KaraokeFlowLayoutImpl's sizeThatFits falls back
/// to `proposal.width ?? .infinity` when that happens, meaning no
/// wrapping decision gets made at all: the whole line renders as one long
/// unwrapped row at its natural width, which then gets positioned (not
/// centered the way a plain Text would be) within the expanded frame —
/// reading as left-aligned/overflowing rather than centered. Giving
/// KaraokeLineView a concrete, non-nil width to apply via `.frame(width:)`
/// (a fixed constraint, not a flexible one) removes that ambiguity
/// entirely.
@available(iOS 15.0, *)
struct KaraokeLyricsView: View {
    let lyrics: KaraokeLyricsDto
    /// Called when the user dismisses the view (e.g. tapping the close
    /// button).
    var onDismiss: () -> Void

    /// Spring state for every syllable, letter and dot — lives as long as
    /// this view does. A class, so stepping it doesn't invalidate the view.
    @State private var animator = KaraokeAnimator()

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                KaraokeBackgroundView()
                content(screenWidth: geo.size.width)
                closeButton
                KaraokeAttributionView(lyrics: lyrics)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .preferredColorScheme(.dark)
    }

    @available(iOS 15.0, *)
    private func content(screenWidth: CGFloat) -> some View {
        // .animation = every display frame (60/120Hz), which the springs
        // need: they're stepped with the real frame delta, like the
        // extension's requestAnimationFrame loop.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            // Reading the tracker here, inside the TimelineView's per-tick
            // closure, is what actually drives the animation — TimelineView
            // re-invokes this closure on its schedule, and since this read
            // is a plain computed value (not @State), there's no separate
            // "fire a side effect to update state" step needed; the new
            // value flows straight into the child views' bodies each tick.
            let currentMs = KaraokePlaybackTracker.shared.currentPositionMs()
            let activeIndex = activeLineIndex(at: currentMs)
            let _ = animator.beginFrame(at: timeline.date.timeIntervalSinceReferenceDate)

            KaraokeScrollingLines(
                lyrics: lyrics,
                currentMs: currentMs,
                activeLineIndex: activeIndex,
                screenWidth: screenWidth,
                animator: animator
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
    let animator: KaraokeAnimator

    private let horizontalPadding: CGFloat = 24
    private var options: KaraokeOptions { UserDefaults.karaokeOptions }

    private var vstackAlignment: HorizontalAlignment {
        switch options.textAlignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    /// Duet songs (any OppositeAligned line) switch to Spicy Lyrics' duet
    /// layout: lead vocalist on one side, the other vocalist on the
    /// opposite side. Centered text has no "opposite" side, so centered
    /// duets fall back to left/right like the real extension's
    /// HasDuetLines styling.
    private func alignment(for line: KaraokeLineDto) -> KaraokeTextAlignment {
        guard lyrics.lines.contains(where: \.oppositeAligned) else { return options.textAlignment }
        let leadAlignment: KaraokeTextAlignment = options.textAlignment == .trailing ? .trailing : .leading
        guard line.oppositeAligned else { return leadAlignment }
        return leadAlignment == .leading ? .trailing : .leading
    }

    private func state(of index: Int) -> KaraokeElementState {
        guard let active = activeLineIndex else { return .notSung }
        if index == active { return .active }
        return index < active ? .sung : .notSung
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: vstackAlignment, spacing: 28) {
                    Spacer().frame(height: 80)

                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        KaraokeLineView(
                            line: line,
                            lineIndex: index,
                            currentMs: currentMs,
                            lineState: state(of: index),
                            distanceFromActive: activeLineIndex.map { abs(index - $0) } ?? 0,
                            animator: animator,
                            availableWidth: max(0, screenWidth - horizontalPadding * 2),
                            alignment: alignment(for: line)
                        )
                        // Only the active line changes frame to frame; the
                        // rest compare equal and skip re-rendering. Redrawing
                        // every blurred line each frame was what starved the
                        // main thread (choppy line transitions, and Spotify's
                        // own UI lagging behind while the overlay was up).
                        .equatable()
                        .id(index)
                        // Tap a line to jump to it, like the extension:
                        // seeks to the line's first sung syllable.
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !line.isInterlude else { return }
                            let target = (line.syllables.first ?? line.background.first)?.startMs ?? line.startMs
                            KaraokePlaybackTracker.shared.seek(toMs: target)
                        }
                        .padding(.horizontal, horizontalPadding)
                        // Counter-flip each row — see the note on the outer
                        // ScrollView's own flip below for why this needs to
                        // happen twice.
                        .scaleEffect(x: 1, y: options.reversedDirection ? -1 : 1)
                    }

                    KaraokeCreditsFooterView(lyrics: lyrics)
                        .scaleEffect(x: 1, y: options.reversedDirection ? -1 : 1)

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
            // Standard "inverted list" technique (the same one chat apps
            // use to keep newest content pinned near the bottom, growing
            // upward): flip the WHOLE scroll content vertically here, then
            // counter-flip each individual row above so ITS OWN text still
            // reads right-side-up. The net effect is that line order reads
            // bottom-to-top instead of top-to-bottom — what would normally
            // render at the top now renders at the bottom and vice versa —
            // while each line's own text stays upright. Using scaleEffect
            // (y-axis only), not a 180° rotation, specifically so this
            // doesn't ALSO mirror left/right — that would fight the
            // leading/trailing alignment setting above, flipping which
            // side "leading"/"trailing" ends up on.
            .scaleEffect(x: 1, y: options.reversedDirection ? -1 : 1)
        }
    }
}
