# Equalizer

15 bands from 25 Hz to 16 kHz, ±12 dB each, on Spotify's own sound after speed and pitch. Its page is
Settings › Player › Equalizer, with presets and a curve of what it does. It applies as it changes. Tapping a
band's value resets it; holding it opens a box to type one. Off, or with every band at 0, the sound passes
through untouched.

The bands and presets are those of spoti.pw's equalizer by Vojtěch Škopek, as found in
[Vitrine](https://github.com/My-Name-Is-Jeff/vitrine) (GPL-3.0, as is this project). The filter design and the
render side are new; why is below.

## Files

| File | What it does |
|---|---|
| `../include/EeveeEqualizer.h` | The C API the Swift side calls |
| `EeveeEqualizer.m` | That API: keeps the sliders, designs them for the output's rate, logs |
| `Equalizer.h/.m` | The core, plain C: the design, the hand-over and the render side |
| `../SpeedPitch/SpeedPitchEngine.m` | Runs it, in `processInPlace()`, from the render notify on the music's output |

Swift side, in `Sources/EeveeSpotify/Player/`: `Equalizer.swift` (settings, presets, the calls),
`EqualizerSettingsView.swift` (the page) and `ValuePrompt.swift` (the typing box, shared with speed & pitch).

## The design

Each band is RBJ's peaking filter, 0.9 octave wide at half its gain. That's wider than the 2/3 octave between
bands, so neighbours add up to a flat line instead of rippling between them. The bandwidth is prewarped, so the
16 kHz band is as wide as the others; with a plain Q it shrinks to about a quarter octave near the top of the
range.

The sliders ask for a curve: each slider's gain at its band, and halfway between two bands the mean of
theirs. The bands' own gains are solved to meet that curve at all 29 points by weighted least squares, the
halfway points counting half, after Välimäki and Liski's accurate cascade graphic equalizer (2017). The solve
takes each band's effect as linear in its gain, and is then corrected three times against the real filters.

How far the response strays from the straight line through the sliders, 25 Hz to 16 kHz, at 48 kHz:

| Sliders | Here | spoti.pw's |
|---|---|---|
| All +6 dB | 0.31 dB | 3.1 dB |
| All +12 dB | 0.67 dB | 6.0 dB |
| One band +12 dB (16 kHz) | 0.65 dB | 3.9 dB |
| Presets (Bass, Loudness, Podcast) | 0.15–0.21 dB | 1.0–2.1 dB |

spoti.pw's bands meet the sliders exactly at their centres but sag between them: with all at +6 dB, 13 kHz
gets +2.9. Here a centre can be off by about 0.3 dB, in return for the whole curve following the sliders.

The sound is turned down by the curve's highest point, so the boosts can't clip and no limiter is needed. The
page says by how much.

## The render thread

- It runs in place in the music's render notify, after the pitch, in the hardware's format, so it adds no
  delay. Float split buffers are processed as they are; other formats are read into float lanes and written
  back.
- Designs are made on the main thread and handed over through a triple buffer, so neither side waits and no
  buffer is skipped. A new design fades in over 30 ms: the coefficients step every 32 frames, the gain moves
  every frame. Dragging a slider doesn't click.
- A design is made for the output's sample rate. When the rate changes (another route), the sound passes as it
  is until the new design arrives, a moment later.
- Once it's off and faded, nothing runs.
- It costs about 3 ms per second of 48 kHz stereo on a desktop CPU.

## Testing

Turn on debug logging, restart, play a song, and look for `[SpeedPitch]` lines: `equalizer on` and
`equalizer: the music's output plays at 48000 Hz` (or the route's rate). Then:

- turning it on with a preset, and dragging a band, change the sound at once, without clicks;
- turning it off goes back to the plain sound;
- the curve on the page matches what you hear (Bass lifts the lows, Podcast thins them);
- it still applies after unplugging headphones or changing to a Bluetooth route;
- it works along with speed and pitch.
