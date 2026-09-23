import SwiftUI

/// Renders one lyrics line the way the real Spicy Lyrics extension does
/// (see KaraokeAnimator.swift for the ported model):
///   - each syllable fills with a soft 20%-wide gradient edge sweeping
///     across it, while spring-driven scale, lift and glow follow the
///     extension's curves;
///   - syllables sung for a second or longer animate letter by letter,
///     the active letter popping with a proximity falloff to its
///     neighbours;
///   - background vocals render smaller and dimmer under the lead;
///   - interlude lines are three dots that swell in turn.
///
/// Layout: syllables that are IsPartOfWord glue together into one word
/// with no spacing; words wrap at the screen edge via KaraokeFlowLayout.
@available(iOS 15.0, *)
struct KaraokeLineView: View {
    let line: KaraokeLineDto
    let lineIndex: Int
    let currentMs: Int
    let lineState: KaraokeElementState
    /// Lines away from the active one; drives the distance blur.
    let distanceFromActive: Int
    let animator: KaraokeAnimator
    /// Concrete pixel width this line's FlowLayout should wrap/center
    /// within — passed down explicitly from KaraokeLyricsView's
    /// GeometryReader rather than relying on `.frame(maxWidth: .infinity)`
    /// to implicitly hand a usable width to the layout. See
    /// KaraokeLyricsView.swift's doc comment for why that implicit
    /// approach doesn't actually work for a custom Layout type.
    var availableWidth: CGFloat? = nil
    /// Resolved per line by KaraokeScrollingLines — duet lines
    /// (OppositeAligned) sit on the opposite side from the lead.
    var alignment: KaraokeTextAlignment = UserDefaults.karaokeOptions.textAlignment

    static let leadFontSize: CGFloat = 30
    static let backgroundFontSize: CGFloat = 20

    private var isActiveLine: Bool { lineState == .active }

    /// A word is a run of syllables glued by IsPartOfWord. The flag is
    /// forward-looking (see KaraokeSyllableDto): a syllable joins the
    /// current word when the *previous* syllable's flag was true. Indices
    /// are kept so each syllable keeps a stable animator key.
    private func words(_ syllables: [KaraokeSyllableDto]) -> [[(index: Int, syllable: KaraokeSyllableDto)]] {
        var result: [[(index: Int, syllable: KaraokeSyllableDto)]] = []
        var current: [(index: Int, syllable: KaraokeSyllableDto)] = []
        for (index, syllable) in syllables.enumerated() {
            let previousContinues = current.last?.syllable.isPartOfWord ?? false
            if current.isEmpty || previousContinues {
                current.append((index, syllable))
            } else {
                result.append(current)
                current = [(index, syllable)]
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private var horizontalAlignment: SwiftUI.HorizontalAlignment {
        SwiftUI.HorizontalAlignment(karaokeTextAlignment: alignment)
    }

    private func wordRow(_ syllables: [KaraokeSyllableDto], group: String, fontSize: CGFloat, isBackground: Bool) -> some View {
        KaraokeFlowLayout(spacing: fontSize * 0.28, alignment: horizontalAlignment) {
            ForEach(Array(words(syllables).enumerated()), id: \.offset) { _, word in
                HStack(spacing: 0) {
                    ForEach(word, id: \.index) { entry in
                        KaraokeSyllableView(
                            syllable: entry.syllable,
                            key: "\(lineIndex).\(group).\(entry.index)",
                            currentMs: currentMs,
                            lineState: lineState,
                            animator: animator,
                            fontSize: fontSize,
                            isBackground: isBackground
                        )
                    }
                }
            }
        }
        .frame(width: availableWidth)
    }

    var body: some View {
        if line.isInterlude {
            interludeBody
        } else {
            lyricsBody
        }
    }

    // MARK: Interlude

    /// Musical "• • •" line — only takes up space while it's the active
    /// line, and fades out preHiddenDotLineMs (500ms) before the next
    /// vocal line, like the real extension's pre-hidden dot line.
    private var interludeBody: some View {
        let visible = isActiveLine && currentMs < line.endMs - 500
        return HStack(spacing: Self.leadFontSize * 0.35) {
            ForEach(Array(line.syllables.enumerated()), id: \.offset) { index, dot in
                let style = isActiveLine
                    ? animator.dot(
                        "\(lineIndex).d.\(index)",
                        state: KaraokeElementState(ms: currentMs, start: dot.startMs, end: dot.endMs),
                        progress: karaokeProgress(ms: currentMs, start: dot.startMs, end: dot.endMs)
                    )
                    : KaraokeElementStyle(scale: KaraokeCurves.dotScale.at(0), yOffset: 0, glow: 0, gradientPosition: 0, opacity: KaraokeCurves.dotOpacity.at(0))
                Circle()
                    .fill(Color.white)
                    .frame(width: Self.leadFontSize * 0.36, height: Self.leadFontSize * 0.36)
                    .opacity(style.opacity)
                    .scaleEffect(style.scale)
                    .offset(y: CGFloat(style.yOffset) * Self.leadFontSize)
                    // text-shadow: 4 + 6·glow px at glow·90% opacity
                    .shadow(color: .white.opacity(min(style.glow * 0.9, 1)), radius: CGFloat(4 + 6 * style.glow) / 2)
            }
        }
        .frame(width: availableWidth, alignment: Alignment(horizontal: horizontalAlignment, vertical: .center))
        // Collapsed while inactive, but never clipped: clipping cut the
        // active dot's glow and bounce off at the frame edge.
        .frame(height: isActiveLine ? Self.leadFontSize * 1.4 : 0, alignment: .center)
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.35), value: visible)
        .animation(.easeOut(duration: 0.35), value: isActiveLine)
    }

    // MARK: Lyrics

    private var lineOpacity: Double {
        switch lineState {
        case .active: return 1
        case .notSung: return KaraokeCurves.notSungLineOpacity
        case .sung: return KaraokeCurves.sungLineOpacity
        }
    }

    /// applyBlur: BlurMultiplier per line of distance, capped. CSS applies
    /// it as a text-shadow blur radius; SwiftUI's blur radius is roughly
    /// half of that for the same look.
    private var blurRadius: CGFloat {
        guard !isActiveLine, distanceFromActive > 0 else { return 0 }
        let amount = min(KaraokeCurves.blurMultiplier * Double(distanceFromActive), KaraokeCurves.maxBlur)
        return CGFloat(amount / 2)
    }

    /// Line mode: the whole line wraps as one text and fills as one, the
    /// gradient spanning its full width (rows fill together), like the
    /// extension's `.line` element.
    private var lineSyncedText: some View {
        let style: KaraokeElementStyle = {
            switch lineState {
            case .notSung: return KaraokeElementStyle(scale: 1, yOffset: 0, glow: 0, gradientPosition: -20)
            case .sung: return .sung
            case .active:
                return animator.line(
                    "\(lineIndex).line",
                    state: .active,
                    progress: karaokeProgress(ms: currentMs, start: line.startMs, end: line.endMs)
                )
            }
        }()
        return KaraokeFillText(
            text: line.plainText,
            fontSize: Self.leadFontSize,
            gradientPosition: style.gradientPosition,
            isBackground: false,
            // text-shadow: 4 + 8·glow px at glow·50% opacity
            glowRadius: CGFloat(4 + 8 * style.glow) / 2,
            glowOpacity: min(style.glow * 0.5, 1),
            wraps: true,
            textAlignment: textAlignment
        )
        .frame(width: availableWidth, alignment: Alignment(horizontal: horizontalAlignment, vertical: .center))
    }

    private var textAlignment: TextAlignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private var lyricsBody: some View {
        VStack(alignment: horizontalAlignment, spacing: 6) {
            if line.isLineSynced {
                lineSyncedText
            } else if !line.syllables.isEmpty {
                wordRow(line.syllables, group: "l", fontSize: Self.leadFontSize, isBackground: false)
            }
            if !line.background.isEmpty {
                wordRow(line.background, group: "b", fontSize: Self.backgroundFontSize, isBackground: true)
            }
        }
        // A FIXED width (not maxWidth) — this is what actually guarantees
        // KaraokeFlowLayoutImpl's sizeThatFits/placeSubviews both receive
        // this exact, concrete value as their proposal/bounds width, with
        // no nil/unspecified fallback possible (each wordRow repeats it).
        .frame(width: availableWidth)
        .opacity(lineOpacity)
        .blur(radius: blurRadius)
        .animation(.timingCurve(0.61, 1, 0.88, 1, duration: 0.2), value: lineState)
        // Setting layoutDirection explicitly per-line (rather than relying
        // on the app's own environment, which follows the app's UI
        // language, not each individual song's) is what makes the syllable
        // fill gradient sweep the correct way for RTL lyrics like Arabic or
        // Hebrew. UnitPoint.leading/.trailing (used for the fill gradient's
        // start/end in KaraokeSyllableView) are layout-direction-relative,
        // not literally left/right — they only flip for RTL when the
        // environment says so.
        //
        // This alone is also what fixes KaraokeFlowLayout's word order for
        // RTL: a custom Layout conformance mirrors automatically in a
        // right-to-left environment unless it opts out, and
        // KaraokeFlowLayoutImpl doesn't opt out. `words` must NOT also
        // reverse the array for this reason: that would flip the order
        // twice, undoing this.
        .environment(\.layoutDirection, line.isRTL ? .rightToLeft : .leftToRight)
    }
}

@available(iOS 15.0, *)
extension KaraokeLineView: Equatable {
    /// Everything that can change how a line looks. Playback position only
    /// matters to the active line (and to a line whose own syllables are
    /// still in progress because they overlap the next line — rare, and
    /// they snap to their final state instead).
    static func == (lhs: KaraokeLineView, rhs: KaraokeLineView) -> Bool {
        lhs.lineIndex == rhs.lineIndex
            && lhs.lineState == rhs.lineState
            && lhs.distanceFromActive == rhs.distanceFromActive
            && lhs.availableWidth == rhs.availableWidth
            && lhs.alignment == rhs.alignment
            && lhs.animator === rhs.animator
            && (lhs.lineState != .active || lhs.currentMs == rhs.currentMs)
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

// MARK: - Syllable

/// One syllable — the unit the extension animates ("word" in its code).
@available(iOS 15.0, *)
private struct KaraokeSyllableView: View {
    let syllable: KaraokeSyllableDto
    let key: String
    let currentMs: Int
    let lineState: KaraokeElementState
    let animator: KaraokeAnimator
    let fontSize: CGFloat
    let isBackground: Bool

    private var duration: Int { syllable.endMs - syllable.startMs }

    /// IsLetterCapable: sung for at least a second, and more than one
    /// letter to animate.
    private var isLetterGroup: Bool {
        duration >= KaraokeCurves.letterGroupMinDurationMs && syllable.text.count > 1
    }

    private var state: KaraokeElementState {
        KaraokeElementState(ms: currentMs, start: syllable.startMs, end: syllable.endMs)
    }

    private var style: KaraokeElementStyle {
        switch lineState {
        case .notSung: return .notSung
        case .sung: return .sung
        case .active:
            return animator.syllable(
                key,
                state: state,
                progress: karaokeProgress(ms: currentMs, start: syllable.startMs, end: syllable.endMs)
            )
        }
    }

    var body: some View {
        let style = self.style
        Group {
            if isLetterGroup {
                letters
            } else {
                KaraokeFillText(
                    text: syllable.text,
                    fontSize: fontSize,
                    gradientPosition: style.gradientPosition,
                    isBackground: isBackground,
                    // text-shadow: 4 + 2·glow px at glow·35% opacity
                    glowRadius: CGFloat(4 + 2 * style.glow) / 2,
                    glowOpacity: min(style.glow * 0.35, 1)
                )
            }
        }
        .scaleEffect(style.scale)
        .offset(y: CGFloat(style.yOffset) * fontSize)
    }

    /// Emphasize.ts: letters split the syllable's time evenly, ending
    /// 250ms before the syllable does.
    private var letterWindows: [(start: Int, end: Int)] {
        let characters = Array(syllable.text)
        let end = syllable.endMs - KaraokeCurves.letterGroupEndTrimMs
        let each = Double(end - syllable.startMs) / Double(characters.count)
        return characters.indices.map { index in
            let start = syllable.startMs + Int(each * Double(index))
            return (start, syllable.startMs + Int(each * Double(index + 1)))
        }
    }

    private var letters: some View {
        let characters = Array(syllable.text)
        let windows = letterWindows
        let wordActive = lineState == .active && state == .active
        let activeIndex = wordActive
            ? windows.firstIndex { currentMs >= $0.start && currentMs < $0.end }
            : nil
        let activeProgress = activeIndex.map {
            karaokeProgress(ms: currentMs, start: windows[$0].start, end: windows[$0].end)
        } ?? 0

        return HStack(spacing: 0) {
            ForEach(characters.indices, id: \.self) { index in
                let letterState = KaraokeElementState(ms: currentMs, start: windows[index].start, end: windows[index].end)
                let letterStyle: KaraokeElementStyle = {
                    switch lineState {
                    case .notSung:
                        return KaraokeElementStyle(scale: KaraokeCurves.letterScale.at(0), yOffset: KaraokeCurves.letterYOffset.at(0), glow: 0, gradientPosition: -20)
                    case .sung:
                        return .sung
                    case .active:
                        return animator.letter(
                            "\(key).\(index)",
                            index: index,
                            state: letterState,
                            wordActive: wordActive,
                            activeIndex: activeIndex,
                            activeProgress: activeProgress
                        )
                    }
                }()
                KaraokeFillText(
                    text: String(characters[index]),
                    fontSize: fontSize,
                    gradientPosition: letterStyle.gradientPosition,
                    isBackground: isBackground,
                    // text-shadow: 4 + 12·glow px at glow·185% opacity
                    glowRadius: CGFloat(4 + 12 * letterStyle.glow) / 2,
                    glowOpacity: min(letterStyle.glow * KaraokeCurves.letterGlowOpacityMultiplier, 1)
                )
                .scaleEffect(letterStyle.scale)
                // Letters lift twice as far as whole syllables.
                .offset(y: CGFloat(letterStyle.yOffset * 2) * fontSize)
            }
        }
    }
}

// MARK: - Fill text

/// Text filled like Mixed.css's `.word`: white at --gradient-alpha up to
/// the sweep position, easing to --gradient-alpha-end over the next 20%
/// of the element's width, plus the white text-shadow glow.
@available(iOS 15.0, *)
private struct KaraokeFillText: View {
    let text: String
    let fontSize: CGFloat
    /// Percent of the element's width; -20 = unsung, 100 = fully sung.
    let gradientPosition: Double
    let isBackground: Bool
    let glowRadius: CGFloat
    let glowOpacity: Double
    /// Syllables never wrap; a whole line-synced line does.
    var wraps: Bool = false
    var textAlignment: TextAlignment = .center

    var body: some View {
        let alpha = isBackground ? KaraokeCurves.backgroundGradientAlpha : KaraokeCurves.gradientAlpha
        let alphaEnd = isBackground ? KaraokeCurves.backgroundGradientAlphaEnd : KaraokeCurves.gradientAlphaEnd
        let start = gradientPosition / 100
        let end = start + 0.2
        let stops: [Gradient.Stop] = [
            .init(color: .white.opacity(alpha), location: min(max(start, 0), 1)),
            .init(color: .white.opacity(alphaEnd), location: min(max(end, 0), 1)),
        ]
        // Before the edge reaches the element everything is alphaEnd; once
        // it has passed, everything is alpha — the clamped stops above
        // collapse to exactly that at the extremes.
        let fill: Color? = end <= 0 ? .white.opacity(alphaEnd) : (start >= 1 ? .white.opacity(alpha) : nil)

        Text(text)
            .font(.system(size: fontSize, weight: .bold))
            .multilineTextAlignment(textAlignment)
            .fixedSize(horizontal: !wraps, vertical: true)
            .foregroundStyle(
                fill.map { AnyShapeStyle($0) }
                    ?? AnyShapeStyle(LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing))
            )
            .shadow(color: .white.opacity(glowOpacity), radius: glowRadius)
    }
}
