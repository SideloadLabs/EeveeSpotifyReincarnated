import SwiftUI

/// Renders one lyrics line with per-syllable progressive fill — each
/// syllable transitions from dim to bright as currentMs crosses its
/// startMs...endMs range, matching the real SpicyLyrics extension's
/// word-highlight effect (Syllable.ts's word-group/syllable span fill).
///
/// Layout uses a wrapping HStack-of-words approach: syllables that are
/// IsPartOfWord glue together with zero spacing into one "word" Text
/// concatenation; separate words get normal space-separated layout via
/// SwiftUI's flexible wrapping (a custom flow layout, not a plain HStack,
/// since lines need to wrap naturally at the screen edge like Spicetify's,
/// and each wrapped row is centered horizontally — see
/// KaraokeFlowLayout.swift).
@available(iOS 15.0, *)
struct KaraokeLineView: View {
    let line: KaraokeLineDto
    let currentMs: Int
    let isActiveLine: Bool
    /// Concrete pixel width this line's FlowLayout should wrap/center
    /// within — passed down explicitly from KaraokeLyricsView's
    /// GeometryReader rather than relying on `.frame(maxWidth: .infinity)`
    /// to implicitly hand a usable width to the layout. See
    /// KaraokeLyricsView.swift's doc comment for why that implicit
    /// approach doesn't actually work for a custom Layout type.
    var availableWidth: CGFloat? = nil

    /// Groups syllables into words (consecutive IsPartOfWord runs joined),
    /// since highlight progress is most naturally computed and the text
    /// laid out per syllable but wrapping should happen between words, not
    /// mid-word.
    ///
    /// isPartOfWord is forward-looking (see KaraokeSyllableDto's doc
    /// comment) — a syllable glues onto the *next* one when *its own* flag
    /// is true, which is equivalent to: a syllable joins the *current*
    /// group when the *previous* syllable's flag was true. Checking the
    /// current syllable's own flag here (as an earlier version did) is the
    /// backwards reading that caused broken word boundaries like "Lo"/"la"
    /// splitting apart while "was"/"Lo" wrongly glued together.
    ///
    /// Kept in the syllables' own left-to-right storage order regardless
    /// of isRTL — see the note on `.environment(\.layoutDirection:)` below
    /// for why. An earlier version reversed this array for RTL lines,
    /// which was the actual bug: it and the environment's automatic
    /// mirroring each flip the word order once, and two flips put RTL
    /// lines right back in left-to-right order — indistinguishable from
    /// RTL handling not running at all.
    private var words: [[KaraokeSyllableDto]] {
        var result: [[KaraokeSyllableDto]] = []
        var current: [KaraokeSyllableDto] = []
        for syllable in line.syllables {
            let previousContinues = current.last?.isPartOfWord ?? false
            if current.isEmpty || previousContinues {
                current.append(syllable)
            } else {
                result.append(current)
                current = [syllable]
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    var body: some View {
        KaraokeFlowLayout(spacing: 8, alignment: SwiftUI.HorizontalAlignment(karaokeTextAlignment: UserDefaults.karaokeOptions.textAlignment)) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                KaraokeWordView(syllables: word, currentMs: currentMs, isActiveLine: isActiveLine)
            }
        }
        // A FIXED width (not maxWidth) — this is what actually guarantees
        // KaraokeFlowLayoutImpl's sizeThatFits/placeSubviews both receive
        // this exact, concrete value as their proposal/bounds width, with
        // no nil/unspecified fallback possible.
        .frame(width: availableWidth)
        .opacity(isActiveLine ? 1.0 : 0.4)
        .blur(radius: isActiveLine ? 0 : 1.5)
        .scaleEffect(isActiveLine ? 1.0 : 0.97, anchor: .center)
        .animation(.easeOut(duration: 0.35), value: isActiveLine)
        // Setting layoutDirection explicitly per-line (rather than relying
        // on the app's own environment, which follows the app's UI
        // language, not each individual song's) is what makes
        // KaraokeFlowLayout's word order correct for RTL lyrics like
        // Arabic or Hebrew: a custom Layout conformance mirrors
        // automatically in a right-to-left environment unless it opts out
        // (Layout's default layoutDirectionBehavior is .mirrors), and
        // KaraokeFlowLayoutImpl doesn't opt out. So placeSubviews below can
        // keep placing words/rows left-to-right as if the line were always
        // LTR — the environment flip here mirrors that whole result for
        // RTL lines, words included. words (above) must NOT also reverse
        // the array for this reason: that would flip the order twice,
        // undoing this.
        //
        // It does NOT, on its own, flip the per-syllable fill gradient in
        // KaraokeSyllableTextView below — LinearGradient's startPoint/
        // endPoint UnitPoints aren't layoutDirection-aware the way a
        // Layout's own placement is, so that view reads this same
        // environment value itself and swaps its own points by hand.
        .environment(\.layoutDirection, line.isRTL ? .rightToLeft : .leftToRight)
    }
}

private extension SwiftUI.HorizontalAlignment {
    init(karaokeTextAlignment: KaraokeTextAlignment) {
        switch karaokeTextAlignment {
        case .leading: self = .leading
        case .center: self = .center
        case .trailing: self = .trailing
        }
    }
}

/// One word: its syllables rendered with zero inter-syllable spacing,
/// each syllable independently colored based on highlight progress. The
/// whole word also scales/glows/bobs together as it's being actively
/// sung, matching LyricsAnimator.ts's word-level ScaleRange/GlowRange/
/// YOffsetRange curves — the original applies these per letter for an
/// even finer effect (LetterScaleRange), but per-word is a reasonable
/// first-pass fidelity level without needing per-character layout.
@available(iOS 15.0, *)
private struct KaraokeWordView: View {
    let syllables: [KaraokeSyllableDto]
    let currentMs: Int
    let isActiveLine: Bool

    private var wordStartMs: Int { syllables.first?.startMs ?? 0 }
    private var wordEndMs: Int { syllables.last?.endMs ?? wordStartMs }

    /// 0 before the word starts, 1 once it's fully sung — drives all
    /// three animation curves the same way the syllable fill gradient's
    /// `progress` drives the color sweep.
    private var wordProgress: Double {
        guard isActiveLine, wordEndMs > wordStartMs else {
            return currentMs >= wordEndMs ? 1 : 0
        }
        let raw = Double(currentMs - wordStartMs) / Double(wordEndMs - wordStartMs)
        return min(1, max(0, raw))
    }

    /// Only animate scale/glow/bob while currentMs is actually inside the
    /// word's window — once fully sung (progress reaches 1 and stays
    /// there as playback moves on), the curve's own Time=1 keyframe
    /// already settles back to neutral (scale 1.0, glow 0, offset 0), so
    /// this doesn't need a separate "is currently being sung" gate beyond
    /// what the curves already encode.
    private var scale: Double { KaraokeAnimationCurve.wordScale.value(at: wordProgress) }
    private var glow: Double { KaraokeAnimationCurve.glow.value(at: wordProgress) }
    private var yOffsetFraction: Double { KaraokeAnimationCurve.yOffset.value(at: wordProgress) }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(syllables.enumerated()), id: \.offset) { _, syllable in
                KaraokeSyllableTextView(
                    syllable: syllable,
                    currentMs: currentMs,
                    isActiveLine: isActiveLine
                )
            }
        }
        .scaleEffect(scale)
        // yOffsetFraction is expressed as a fraction of font size in the
        // original (1/100, -1/60 etc applied to em-based units) — 28pt
        // matches the syllable text's font size below, so multiplying by
        // it converts the fraction into actual points.
        .offset(y: CGFloat(yOffsetFraction) * 28)
        .shadow(color: .white.opacity(glow * 0.8), radius: CGFloat(glow * 8))
        .animation(.linear(duration: 1.0 / 30.0), value: wordProgress)
    }
}

/// Renders a single syllable's text, colored by how far currentMs has
/// progressed through its startMs...endMs window:
///   - before startMs:  dim (not yet sung)
///   - during window:   progressively brightened left-to-right via a
///                       gradient mask, for the classic karaoke "fill" look
///   - after endMs:     fully bright (already sung)
@available(iOS 15.0, *)
private struct KaraokeSyllableTextView: View {
    let syllable: KaraokeSyllableDto
    let currentMs: Int
    let isActiveLine: Bool

    // Environment values do cascade down from KaraokeLineView's
    // .environment(\.layoutDirection:) — that part works the same for any
    // view, including this one — but reading it is on us: it's only
    // *layout* (HStack, and a custom Layout by default) that resolves
    // .leading/.trailing against this automatically. UnitPoint.leading and
    // .trailing, used below for the fill gradient, are plain fixed points
    // (x: 0 and x: 1) — LinearGradient has no idea layoutDirection exists,
    // so it never flips them. That's the whole reason the RTL fix in
    // KaraokeLineView made the line's word order correct while this
    // gradient kept sweeping left-to-right regardless: one relied on
    // automatic layoutDirection-aware resolution, the other needed it done
    // by hand. Swapping the two points explicitly here is that by-hand
    // equivalent.
    @Environment(\.layoutDirection) private var layoutDirection

    private var progress: Double {
        guard isActiveLine, syllable.endMs > syllable.startMs else {
            return currentMs >= syllable.endMs ? 1 : 0
        }
        let raw = Double(currentMs - syllable.startMs) / Double(syllable.endMs - syllable.startMs)
        return min(1, max(0, raw))
    }

    private var fillStart: UnitPoint { layoutDirection == .rightToLeft ? .trailing : .leading }
    private var fillEnd: UnitPoint { layoutDirection == .rightToLeft ? .leading : .trailing }

    var body: some View {
        Text(syllable.text)
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: progress),
                        .init(color: .white.opacity(0.35), location: progress),
                        .init(color: .white.opacity(0.35), location: 1),
                    ],
                    startPoint: fillStart,
                    endPoint: fillEnd
                )
            )
            .animation(.linear(duration: 0.08), value: progress)
    }
}
