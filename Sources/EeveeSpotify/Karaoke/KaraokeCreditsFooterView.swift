import SwiftUI

/// "Written by: ..." footer shown beneath the last lyrics line, matching the
/// real extension's Credits/ApplyLyricsCredits.ts. Provider and sync credits
/// live in KaraokeAttributionView instead, which stays on screen.
struct KaraokeCreditsFooterView: View {
    let lyrics: KaraokeLyricsDto

    var body: some View {
        if !lyrics.songWriters.isEmpty {
            Text("Written by: \(lyrics.songWriters.joined(separator: ", "))")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 8)
        }
    }
}

/// Provider + sync credits, pinned to the bottom of the karaoke view.
/// The Spicy Lyrics developer API's attribution rules require it to be on
/// screen wherever the lyrics are ("It can be small and quiet. It cannot be
/// absent."): always the provider, and for community syncs the uploader
/// and maker, linked — all read from the response, never hardcoded.
struct KaraokeAttributionView: View {
    let lyrics: KaraokeLyricsDto

    private var providerLabel: String? {
        KaraokeCreditDto.providerLabel(code: lyrics.providerCode, displayName: lyrics.providerDisplayName)
    }

    var body: some View {
        if let providerLabel = providerLabel {
            VStack(spacing: 2) {
                Text("karaoke_lyrics_provided_by".localizeWithFormat(providerLabel))
                if lyrics.maker != nil || lyrics.uploader != nil {
                    HStack(spacing: 4) {
                        if let maker = lyrics.maker {
                            Text("karaoke_synced_by".localized)
                            creditLink(maker)
                        }
                        if let uploader = lyrics.uploader, uploader.name != lyrics.maker?.name {
                            Text(lyrics.maker == nil ? "karaoke_uploaded_by".localized : "karaoke_uploaded_by_continued".localized)
                            creditLink(uploader)
                        }
                    }
                }
            }
            .font(.system(size: 11, weight: .regular))
            .foregroundColor(.white.opacity(0.5))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.35)))
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder private func creditLink(_ credit: KaraokeCreditDto) -> some View {
        if let url = credit.url {
            Link(credit.name, destination: url)
                .foregroundColor(.white.opacity(0.8))
        } else {
            Text(credit.name)
        }
    }
}
