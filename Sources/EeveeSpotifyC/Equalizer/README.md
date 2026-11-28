# Equalizer

15 bands from 25 Hz to 16 kHz, ±12 dB each, on Spotify's own sound after speed and pitch, with a headphone
correction from [AutoEq](https://github.com/jaakkopasanen/AutoEq) under them. Its page is in eevee's settings,
Listening › Equalizer. It applies as it changes. Off, or with every band at 0 and no correction, the sound passes
through untouched.

- **The curve** shows what the bands do, with a dot per band. A dot drags up and down, and a double tap puts it
  back to 0. The correction, when there is one, is the dashed line.
- **Bands** have a slider each. Tapping a band's value resets it; holding it opens a box to type one.
- **Presets**: twelve built in, and your own, saved under a name from the current curve and deleted with a swipe.
- **Prevent clipping**, on by default, runs a limiter after the bands, so the boosts keep their volume and only
  the peaks they'd push over are caught (see *Clip prevention*); the page says how far the boosts go.
- **Headphones**: pick yours from AutoEq's list and its correction is kept for the output playing now, so
  AirPods and wired headphones each get their own. It plays under the bands while the equalizer is on. The
  whole list shows, or what matches a search, 100 rows at a time as it scrolls; the page stays open after a
  pick, to try another. AutoEq's list (about 850 KB) is fetched from GitHub when the page is opened and kept
  for a month; a correction (under 1 KB) when it's first picked after launch. Nothing else goes over the
  network.

The bands and presets are those of spoti.pw's equalizer by Vojtěch Škopek, as found in
[Vitrine](https://github.com/My-Name-Is-Jeff/vitrine) (GPL-3.0, as is this project), and the draggable curve is
spoti.pw's idea too. Saved presets and corrections kept per output are Vitrine's. The filter design, the render
side and the parametric corrections are new; why is below.

## Files

| File | What it does |
|---|---|
| `../include/EeveeEqualizer.h` | The C API the Swift side calls |
| `EeveeEqualizer.m` | That API: keeps the sliders and the correction, designs them for the output's rate, logs |
| `Equalizer.h/.m` | The core, plain C: the design, the hand-over and the render side |
| `../SpeedPitch/SpeedPitchEngine.m` | Runs it, in `processInPlace()`, from the render notify on the music's output |
| `../Shared/LogSink.h/.m` | Where the log lines go, shared with speed & pitch |

Swift side, in `Sources/EeveeSpotify/Player/`:

| File | What it does |
|---|---|
| `Equalizer.swift` | Settings, presets, the output and its correction, the calls |
| `AutoEq.swift` | AutoEq's index (parsed, searched, cached) and its parametric files |
| `EqualizerSettingsView.swift` | The page and its curve |
| `EqualizerHeadphonesView.swift` | The headphone search |
| `ValuePrompt.swift` | The boxes to type a value or a name, and the rounding to hundredths, shared with speed & pitch |

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

## Clip prevention

A boost can push loud parts past full scale. Turning the whole sound down by the curve's highest point (what
this did before, and what most equalizers do) prevents that for steady tones, but costs the boost's volume all
the time, even in quiet songs, and still lets through peaks that line up in phase. So with **Prevent clipping**
on, a limiter runs after the sections instead (`limit()` in `Equalizer.m`):

- It looks 3 ms ahead (the sound is delayed that much) and turns down only what would pass -0.3 dBFS, letting
  go over 100 ms. The look-ahead holds the lowest gain any of the next 3 ms needs, averaged over 3 ms, so the
  gain is down to a peak's need by the time the peak plays and no sample ends over the ceiling.
- A slow trim turns the whole sound down when the limiter works hard: its reduction averaged over a second, past
  1 dB, lowers the trim 3 dB a second; under 0.3 dB it comes back 1 dB a second. It never goes lower than the
  curve's highest point, so the worst case is the old turn-down. It carries over gaps between songs.
- Turning it on or off crossfades the delayed sound with the plain sound over one buffer, so neither the 3 ms
  jump nor a gap is heard.

Measured in a Python port of this file on six songs (90 s each, 44.1 kHz) with the Bass, Loudness and Treble
presets, against the old turn-down:

- With Spotify's volume normalization on (its default, which turns loud masters down to about -14 LUFS before
  the equalizer sees them), the presets play 5 to 6 dB louder and the limiter acts in under 1% of the sound, by at
  most 1 dB. A +12 dB bass curve plays 10.5 to 12 dB louder, limited about a third to half the time by under
  1 dB on average.
- With it off, loud masters keep 0.4 to 4.4 dB of the boost; the trim settles at 2 to 4 dB and the limiter takes
  under 1 dB on average. Quiet masters keep all of it.

With **Prevent clipping** off nothing limits the boosts: they play at full height and a loud song can clip, as in
most equalizers. Turning it off asks first, every time. A float output clips in the hardware, a 16 or 32-bit
integer one where the samples are written back.

## Headphone corrections

AutoEq publishes, for each of about 8,850 measured headphones, a parametric correction: ten RBJ filters
(low shelf, peaks, high shelf, each with a frequency, gain and Q) and a preamp. They run here exactly as Equalizer
APO and AutoEq itself define them, as up to 16 more sections after the bands, with no convolver and no delay.
spoti.pw and Vitrine use AutoEq's GraphicEQ files instead, turned into a long FIR filter and convolved, which
needs an FFT convolver and adds latency.

The file's preamp isn't used: the limiter covers the bands and the correction together, and its trim never goes
lower than their highest point together. For the Sennheiser HD 650 (oratory1990) that comes to 6.07 dB, against
the file's 6.1.

A correction is kept under the output's port UID (`AVAudioSessionPortDescription.uid`), which stays the same
for a Bluetooth device across connections, and is put in when the route changes. The bands stay the same
everywhere: the correction belongs to the headphones, the bands to taste.

## The render thread

- It runs in place in the music's render notify, after the pitch, in the hardware's format. The filters add no
  delay; the limiter adds its 3 ms look-ahead while it's on. Float split buffers are processed as they are; other
  formats are read into float lanes and written back.
- Designs are made on the main thread and handed over through a triple buffer, so neither side waits and no
  buffer is skipped. A new design fades in over 30 ms, the coefficients stepping every 32 frames. Dragging a
  slider doesn't click.
- A design is made for the output's sample rate. When the rate changes (another route), the sound passes as it
  is until the new design arrives, a moment later.
- Once it's off and faded, nothing runs.
- It costs about 4 ms per second of 44.1 kHz stereo on a desktop CPU, the limiter included.

## The log

With debug logging on, everything it does is under `[Equalizer]`:

- `on` / `off`, `clip prevention on` / `off` (at launch only when off), and `the music's output plays at
  48000 Hz` when the output starts or its rate changes.
- `output AirPods Pro, correction Apple AirPods Pro 2`: the output and its correction, at launch and on every
  route change. The output's UID is left out, since for Bluetooth it's the device's address.
- A report three seconds after anything changes, once per burst of slider moves:

  ```
  on at 48000 Hz, bands +6 +6 +5 +4 +2 +1 +0 +0 +0 +0 +0 +0 +0 +0 +0, correction 10 filters, limiter on, peaks at
  +6.15 dB, trim -0.00 dB; since the last report 1873 buffers run, 4 limited, 0 for another rate, 0 refused,
  0 passed over, 0 cleared after a fault
  ```

  With clip prevention off, `limiter on, …` reads `clip prevention off, peaks at +6.15 dB`. The render
  thread can't log, so it counts instead. **Buffers run** should climb while music plays and it's
  on. **Limited** is buffers the limiter turned down by more than 0.1 dB, and the **trim** its slow turn-down
  when the report was made: near 0 with normalization on, a few dB on a loud master with it off. **For another rate** climbing means the design didn't follow the output to its new rate (see
  `applyToFormat()` in `SpeedPitchEngine.m`). **Refused** means the hardware's format isn't one the in-place path
  reads: more than two channels, or not 16 or 32-bit; the `[SpeedPitch]` lines have the format. **Passed over**
  is a buffer that came while another output's render thread had it, which happens for a moment when the music
  moves between outputs. **Cleared after a fault** is filters that went non-finite and were emptied; it should
  stay at 0.
- `AutoEq list: 8850 headphones from the cache, 3.2 days old` (or `from GitHub`, or `GitHub failed (…, HTTP 403)`),
  and `AutoEq Sennheiser HD 650 (oratory1990): 10 filters` (`…, downloaded before` when it's picked again) or
  `… failed: HTTP 404, no file`. A failed download with HTTP 200 is a file it couldn't read: a new filter kind,
  or another layout.

## Testing

Turn on debug logging, restart, play a song, and check the `[Equalizer]` lines above. Then:

- turning it on with a preset, and dragging a band, change the sound at once, without clicks;
- turning it off goes back to the plain sound;
- the curve on the page matches what you hear (Bass lifts the lows, Podcast thins them);
- it still applies after unplugging headphones or changing to a Bluetooth route;
- it works along with speed and pitch;
- a dot on the curve drags, and a double tap resets it, without scrolling the page;
- a preset saved under a name shows in the preset menu and the list, and a swipe deletes it;
- with Prevent clipping on, Bass on a loud song plays about as loud as the plain song and doesn't distort or
  pump, and turning the switch on or off mid-song doesn't click;
- with Prevent clipping off, a boosted curve can distort a loud song, and the page says by how much it can go over;
- the headphones page lists everything without a search, scrolls to the end without stalling, and stays open
  after a pick;
- a headphone picked for one output plays only on that output, and comes back when it reconnects.
