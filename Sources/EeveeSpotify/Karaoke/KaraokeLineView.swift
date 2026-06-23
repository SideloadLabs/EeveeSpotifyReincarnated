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
/// since lines need to wrap naturally at the screen edge like Spicetify's).
struct KaraokeLineView: View {
    let line: KaraokeLineDto
    let currentMs: Int
    let isActiveLine: Bool

    /// Groups syllables into words (consecutive IsPartOfWord runs joined),
    /// since highlight progress is most naturally computed and the text
    /// laid out per syllable but wrapping should happen between words, not
    /// mid-word.
    private var words: [[KaraokeSyllableDto]] {
        var result: [[KaraokeSyllableDto]] = []
        var current: [KaraokeSyllableDto] = []
        for syllable in line.syllables {
            if !syllable.isPartOfWord || current.isEmpty {
                if !current.isEmpty { result.append(current) }
                current = [syllable]
            } else {
                current.append(syllable)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    var body: some View {
        KaraokeFlowLayout(spacing: 8) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                KaraokeWordView(syllables: word, currentMs: currentMs, isActiveLine: isActiveLine)
            }
        }
        .opacity(isActiveLine ? 1.0 : 0.4)
        .blur(radius: isActiveLine ? 0 : 1.5)
        .scaleEffect(isActiveLine ? 1.0 : 0.97, anchor: .leading)
        .animation(.easeOut(duration: 0.35), value: isActiveLine)
    }
}

/// One word: its syllables rendered with zero inter-syllable spacing,
/// each syllable independently colored based on highlight progress.
private struct KaraokeWordView: View {
    let syllables: [KaraokeSyllableDto]
    let currentMs: Int
    let isActiveLine: Bool

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
    }
}

/// Renders a single syllable's text, colored by how far currentMs has
/// progressed through its startMs...endMs window:
///   - before startMs:  dim (not yet sung)
///   - during window:   progressively brightened left-to-right via a
///                       gradient mask, for the classic karaoke "fill" look
///   - after endMs:     fully bright (already sung)
private struct KaraokeSyllableTextView: View {
    let syllable: KaraokeSyllableDto
    let currentMs: Int
    let isActiveLine: Bool

    private var progress: Double {
        guard isActiveLine, syllable.endMs > syllable.startMs else {
            return currentMs >= syllable.endMs ? 1 : 0
        }
        let raw = Double(currentMs - syllable.startMs) / Double(syllable.endMs - syllable.startMs)
        return min(1, max(0, raw))
    }

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
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .animation(.linear(duration: 0.08), value: progress)
    }
}
