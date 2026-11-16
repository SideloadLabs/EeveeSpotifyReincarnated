# Speed & pitch

Changes how fast and how high Spotify's music plays, on Spotify's own audio, so it works on every song,
local files included. Player settings → Speed & pitch turns it on (restart needed); the sliders on the
same page apply at once. Neither value is stored: every launch plays at normal speed.

Based on the speed & pitch feature of [Vitrine](https://github.com/My-Name-Is-Jeff/vitrine) (GPL-3.0, as is
this project) as of commit `f6f519b` (2026-11-15), which took it from spoti.pw by Vojtěch Škopek. Thanks to
both. It is maintained here on its own from that point. Vitrine's extras that plug into the same engine
(its karaoke look-ahead, lossless source selection, sleep timer fade, audio effects and Music Haptics) were
not brought over.

## Files

| File | What it does |
|---|---|
| `../include/EeveeSpeedPitch.h` | The C API the Swift side calls |
| `EeveeSpeedPitch.m` | That API: install, availability, clamping, the log |
| `SpeedPitchEngine.m` | Spotify's audio output: rebinding, the render callbacks, which output carries the music |
| `SpeedPitchClock.x` | Hooks on Spotify's player that keep the progress bar in step. **All of Spotify's class and method names are here** |
| `TimePitch.h/.m` | Apple's time-pitch unit and Varispeed, wrapped for the render thread |
| `Rebind.h/.m` | Rebinding Spotify's imports of C functions, with a jailbreak fallback |
| `SpeedPitchPrivate.h` | What the files above share |

Swift side, in `Sources/EeveeSpotify/Player/`: `SpeedPitch.swift` (the options, installing at launch) and
`SpeedPitchSettingsView.swift` (the settings page). Its strings are the `speed_pitch*` keys in
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
the song the engine has handed over since. A seek, skip, stop, new track or stall hands the clock back to
Spotify's, and the next report starts ours again.

### Threading

`feed()` and the render notify run on Core Audio's render threads: they only touch atomics, their own
`Output` and the units, and never allocate, lock, log or wait. Spotify connects, starts, stops and disposes
on its audio thread; `Output` records change under `sg_outputsLock` there and on `sg_outputsQueue`, and a
change waits for any render in progress to end. The API is main thread only.

## When Spotify updates

Everything Spotify-specific is checked at launch; a missing piece is logged and only that piece is skipped.

- `SPTPlayerState`: `playbackSpeed`, `position`, `timestamp`, `track`, `isPaused`, `isPlaying`.
  Without them speed stays off (pitch still works).
- `SPTEsperantoPlayer`: `addPlayerObserver:` (stall detection), `seekTo:relative:options:creatorTimestampPositionMs:`,
  `skipToNextTrackWithOptions:track:loggingParams:`, `skipToPreviousTrackWithOptions:track:loggingParams:`, `stop`.
  Without these the clock falls back to spotting jumps of more than 3 s in Spotify's reports.
- Spotify's binary importing `AudioUnitSetProperty` (without it only pitch works, in place), and
  `AudioOutputUnitStart`, `AudioOutputUnitStop` and `AudioComponentInstanceDispose`, which track outputs
  starting, stopping and going away.

The Objective-C names were confirmed on Spotify 9.1.78, 9.1.88 and 9.1.90 (in Vitrine). When the log says
`-[SPTEsperantoPlayer …] is missing` after an update, find the new name (a class dump of the new build) and
change it in `SpeedPitchClock.x`: both the hooked method and its `hasMethods` list.

## Testing

Turn on debug logging, enable Speed & pitch, restart, play a song, then export the debug log and look for
`[SpeedPitch]` lines:

- `audio: Spotify connects mixer … fed through the engine's callback`: speed is possible
- `… its own connection kept: …`: speed is off for that output, and the line says why
- `-[SPTEsperantoPlayer …] is missing` / `SPTPlayerState is missing`: a hook was skipped on this version

Then check, at 1.5× and 0.75×, with *Pitch follows speed* both on and off:

- the progress bar and lyrics stay in step through a whole song, a seek, a skip and a pause
- pitch alone at 1× (±12) sounds right and comes back clean at 0
- a local file at another sample rate, AirPods/Bluetooth, and a call or Siri interruption
