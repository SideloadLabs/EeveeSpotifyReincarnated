# Speed & pitch

Changes how fast and how high Spotify's music plays, on Spotify's own audio, so it works on every song,
local files included. The sliders are in the full-screen player's ⋯ menu and apply at once. Tapping a value
resets it; holding it opens a box to type one, finer than the sliders' steps or past their ends (0.25× to 4×,
±24 semitones). Neither value is stored: every launch plays at normal speed.

There is no switch: it is installed at every launch, because it has to be in place before Spotify sets up its
audio, and at normal speed and pitch the sound passes through untouched.

Based on the speed & pitch feature of [Vitrine](https://github.com/My-Name-Is-Jeff/vitrine) (GPL-3.0, as is
this project) as of commit `f6f519b` (2026-11-15), which took it from spoti.pw by Vojtěch Škopek. Thanks to
both. It is maintained here on its own from that point. Vitrine's extras that plug into the same engine
(its karaoke look-ahead, lossless source selection, sleep timer fade, audio effects and Music Haptics) were
not brought over. The equalizer was redone in `../Equalizer` and runs in this engine's render notify.

## Files

| File | What it does |
|---|---|
| `../include/EeveeSpeedPitch.h` | The C API the Swift side calls |
| `EeveeSpeedPitch.m` | That API: install, availability, clamping, the log |
| `SpeedPitchEngine.m` | Spotify's audio output: rebinding, the render callbacks, which output carries the music |
| `SpeedPitchClock.x` | Hooks on Spotify's player that keep the progress bar in step. **All the player names the engine needs are here** |
| `MixerLimit.m` | Lifts Spotify's core mixer limit with the speed, so there are no pauses above 1.2× |
| `TimePitch.h/.m` | Apple's time-pitch unit and Varispeed, wrapped for the render thread |
| `Rebind.h/.m` | Rebinding Spotify's imports of C functions, with a jailbreak fallback |
| `SpeedPitchPrivate.h` | What the files above share |
| `../Shared/LogSink.h/.m` | Where the log lines go, shared with the equalizer |

Swift side, in `Sources/EeveeSpotify/Player/`:

| File | What it does |
|---|---|
| `SpeedPitch.swift` | The options, installing at launch, and the Swift face of the C API |
| `SpeedPitchMenu.x.swift` | Hooks that put the row into the player's ⋯ menu (Spotify's context menu sheet and the player header) |
| `SpeedPitchMenuView.swift` | That row, which opens in place onto the sliders and the *Pitch follows speed* switch, and the box for typing a value |

The strings are the `speed_pitch*` keys in
`layout/Library/Application Support/EeveeSpotify.bundle/en.lproj/Localizable.strings`; other languages fall
back to English until translated. The options are stored in UserDefaults under `eeveeSpeedPitchOptions`.

## How it works

### The sound

Spotify's player only takes a speed for podcasts, so speed, like pitch, is done to the sound itself.

Spotify's audio (`AudioUnitDriver2` in its binary) is a chain of audio units it wires with
`kAudioUnitProperty_MakeConnection`: a converter fed by its decoder, an EQ, a mixer, and a RemoteIO unit
(the speaker). Spotify's import of `AudioUnitSetProperty` is rebound, and when Spotify connects a mixer to a
RemoteIO unit, `feed()` is set as that unit's render callback instead and pulls the mixer itself.

- At normal speed and pitch, `feed()` passes the mixer's sound straight through.
- Otherwise it renders the time-pitch unit, which pulls the mixer for rate × the frames it hands back, so
  Spotify's decoder is drained that much faster or slower. With *Pitch follows speed* on, Varispeed
  resamples instead, so pitch rises with speed like a record.
- Putting the unit in or taking it out skips or repeats its 93 ms delay, so it stays in for 1.5 s after
  speed and pitch both return to normal.

Spotify keeps one chain per sample rate (a local file at another rate gets a second one), and both can run
at once. So every RemoteIO unit gets its own `Output` record, and the unit sits on one of them, the music's:
the one Spotify started or connected last, unless it has been silent for a second while another has sound.
`AudioOutputUnitStart`, `AudioOutputUnitStop` and `AudioComponentInstanceDispose` are rebound to keep track.

`feed()` only stands in when the formats allow it: float, non-interleaved, 32-bit, 1 or 2 channels, with the
mixer's output matching. Otherwise Spotify's own connection stays and only pitch works, through a render
notify that pitch-shifts each finished buffer in place.

On a jailbreak where Spotify's import page can't be written, the functions are hooked with ElleKit's
(Substrate's) `MSHookFunction` instead, and only calls coming from Spotify's binary are handled.

### The progress bar

Between its player's reports, Spotify extrapolates the position: `-[SPTPlayerState position]` is the last
reported position plus the time since, times `-playbackSpeed`. So `playbackSpeed` is scaled by our speed,
and once the speed leaves 1x, `position` answers from our own clock: Spotify's position at that moment plus
the song the engine has handed over since, times Spotify's own speed (1 for music; a podcast's, see below).
A seek, skip, stop, new track or stall hands the clock back to Spotify's, and the next report starts ours
again. After a return to 1x ours keeps counting, since Spotify's is still behind, until one of those.

Neither applies while the music isn't going through the engine: over Spotify Connect on another device, or
through Spotify's own connection when the engine lost it (a rebuilt chain, a refused format). That's told by
Spotify's player saying it plays while nothing has come through the engine for 3 s. Spotify's clock is the
right one then, and ours starts again from it when the music is back. A speed set before stays set, and the
menu shows it, so a tap can put it back to 1x while speed is unavailable.

### Threading

`feed()` and the render notify run on Core Audio's render threads: they only touch atomics, their own
`Output` and the units, and never allocate, lock, log or wait. Spotify connects, starts, stops and disposes
on its audio thread; `Output` records change under `sg_outputsLock` there and on `sg_outputsQueue`, and a
change waits for any render in progress to end. The API is main thread only.

### Spotify's mixer limit

The list player's mixer (the `List Player Media Mixer Renderer Thread`) hands audio to the driver through a
token bucket: 10 s of frames up front, refilled at sample rate × 1.2 / 1000 frames per millisecond of
`std::chrono::steady_clock` (52 at 44.1 kHz). Both numbers are fixed in the binary, not remote settings. At
1.5× the engine drains the bucket in about 30 s; after that the core delivers 1.2× and the sound pauses
every few seconds to catch up. This is the stall Vitrine reports in
[vitrine#103](https://github.com/My-Name-Is-Jeff/vitrine/issues/103). No driver, buffer or look-ahead setting
changes it.

The bucket reads time through a `std::function` holding the address of Spotify's import of
`steady_clock::now()`, which the core copies when it starts. `MixerLimit.m` rebinds that import at launch,
before the core starts, so the copy holds ours. Our `now()` gives the real time to every caller except the
bucket's two reads, told by the code they return to: a load from `[bucket + 0x30]` followed by a divide by
1,000,000, and a store to `[bucket + 0x38]` right after `add x0, bucket, #0x10`. Once both have been seen,
those two get a timeline that runs max(1, speed) times as fast, so the bucket refills at 1.2× the chosen speed.
With only one recognised (a Spotify build that changed the other), neither is warped, so the bucket never
subtracts times from two timelines. The timeline never jumps
or runs behind the real clock, and the bucket keeps it after a return to 1×, so its stored time stays
consistent. A new bucket after a seek starts full.

Measured on Spotify 9.2.0 (XR), 60 s of continuous play: 1.5× played at 1.499× and 2× at 1.988×, against
1.31–1.34× before. 1× and 0.75× right after 2× played at 0.996× and 0.747×.

Spotify also has its own song speed, codenamed zephyr. The core allows it only for tracks whose server-sent
content type is talk, so it isn't used here. It still matters for podcasts: the core applies it before the
mixer, so each second through the engine holds that many seconds of the episode, and the clock counts with it.

## When Spotify updates

Everything Spotify-specific is checked at launch; a missing piece is logged and only that piece is skipped.

- `SPTPlayerState`: `playbackSpeed`, `position`, `timestamp`, `track`, `isPaused`, `isPlaying`.
  Without them speed stays off (pitch still works).
- `SPTEsperantoPlayer`: `addPlayerObserver:` (stall detection), `seekTo:relative:options:creatorTimestampPositionMs:`,
  `skipToNextTrackWithOptions:track:loggingParams:`, `skipToPreviousTrackWithOptions:track:loggingParams:`, `stop`.
  The last four go in together. Without them the clock falls back to spotting jumps of more than 3 s in
  Spotify's reports.
- The ⋯ menu: `NowPlaying_ModesImpl.HeaderElementsUnit` (the player header, whose ⋯ is the view labelled
  `Context menu`) and `ContextMenu_InternalImpl.ContextMenuViewController` (the sheet). Without them the
  row is left out (`menu skipped` in the log).
- Spotify's binary importing `AudioUnitSetProperty` (without it only pitch works, in place), and
  `AudioOutputUnitStart`, `AudioOutputUnitStop` and `AudioComponentInstanceDispose`, which track outputs
  starting, stopping and going away. Start is only rebound along with Stop; short of either, the
  jailbreak's hooks take all three where there are any.
- Spotify's binary importing `std::__1::chrono::steady_clock::now()`, and its mixer's token bucket keeping the
  shape `bucketRead()` in `MixerLimit.m` looks for. If the log says `Spotify's mixer not seen yet`, or `only
  its … seen`, after playing above 1×, the bucket's code changed: find the function that divides by 1,000,000
  between two clock reads (it is also used for download limits) and update the patterns. Speed still works;
  it only pauses above 1.2× again.

The Objective-C names were confirmed on Spotify 9.1.78, 9.1.88 and 9.1.90 (in Vitrine). When the log says
`-[SPTEsperantoPlayer …] is missing` after an update, find the new name (a class dump of the new build) and
change it in `SpeedPitchClock.x`: both the hooked method and its `hasMethods` list.

## Testing

Turn on debug logging, restart, play a song, then export the debug log and look for
`[SpeedPitch]` lines:

- `audio: Spotify connects mixer … fed through the engine's callback`: speed is possible
- `… its own connection kept: …`: speed is off for that output, and the line says why
- `a unit in the chain for … Hz, … channels, without Varispeed: …`: *Pitch follows speed* can't work on that output
- `mixer limit: follows 1.50x (Spotify's mixer seen)`: the core's limit follows the speed. Set the speed
  after a few seconds of playing, or the first change can say `not seen yet` before the mixer has run
- `-[SPTEsperantoPlayer …] is missing` / `SPTPlayerState is missing`: a hook was skipped on this version
- `menu table …, header …, footer …`: the first player ⋯ menu, and where the row went

Then check, at 1.5× and 0.75×, with *Pitch follows speed* both on and off:

- the progress bar and lyrics stay in step through a whole song, a seek, a skip and a pause
- typed values past the sliders (4× and 0.25×) and between their steps (1.13×, -0.32 st)
- pitch alone at 1× (±12) sounds right and comes back clean at 0
- a local file at another sample rate, AirPods/Bluetooth, and a call or Siri interruption
- a podcast at Spotify's own 1.5× with ours at 1.2×: the bar and SponsorBlock follow the episode (1.8×)
- moving playback to another device over Connect and back: the bar follows that device at its speed, and
  `Spotify plays, but nothing has come through the engine` is logged once
- back at 1× after another speed, a stall or a seek hands the clock back without the bar jumping ahead
