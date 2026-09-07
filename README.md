# CoreAudioTapKit

Capture, modify, and play back **all** macOS system audio on one clock. The kit
owns the Core Audio lifecycle that is easy to get subtly wrong (process tap,
private aggregate device, IOProc, teardown) and hands you interleaved stereo
frames through one realtime hook:

```
system audio ──▶ device-scoped CATap ─┐
                                      ├─ ONE aggregate, ONE IOProc ──▶ your AudioProcessor ──▶ output device
physical output (clock master) ───────┘
```

**No DSP is included.** You bring the audio math (EQ, effects, metering);
CoreAudioTapKit gets the signal to you and back out without a second clock in
the way.

📖 **[Full documentation →](docs/README.md)**: each stage tied to Apple's Core
Audio docs, the reasoning behind the single-clock design, and an integration guide.

## Why this exists

The obvious way to build a system-wide audio processor on macOS 14.2+ is a
process tap that captures into a ring buffer, and a separate output unit that
drains the ring and plays the result. It works on built-in speakers. On
Bluetooth it audibly warbles in pitch, worst for 44.1 kHz sources on a 48 kHz
device, because the tap and the output are running on two independent clocks
and the device-side clock estimate on Bluetooth wobbles by a percent or more.
Every mechanism that reconciles the two domains (Core Audio's own sample rate
conversion, ring fill rails, a varispeed servo) prints that wobble into the
audio. Buffering more does not fix it. A minimal repro with no application code
reproduced it, and nothing fixed it while two clocks existed.

The fix is topology, not tuning. Put the tap and the physical output into
**one** private aggregate device with the physical output as clock master and
maximum-quality drift compensation on the tap, register **one** IOProc on that
aggregate, and write the processed audio into the aggregate's output buffers
inside the same callback. Core Audio then owns a single clock end to end and
does its drift compensation against the very clock the audio plays on. This
package is that design, extracted from a shipping app. The first public version
of this kit (July 2026) was the two-clock version; it was replaced, not tuned.

## Requirements

- **macOS 14.2 or newer.** `AudioHardwareCreateProcessTap` does not exist before
  then. Starting on an older OS throws `CoreAudioTapError.unsupportedOS`.
- **The host app must not be sandboxed.** Process taps are unavailable to
  sandboxed apps, which is also why apps built on this cannot ship on the Mac App
  Store.
- On **macOS 14.4+** the user is prompted once for "System Audio Recording Only"
  the first time you start capture.

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/CJStanfield/CoreAudioTapKit.git", from: "0.1.0")
```

Then add the `CoreAudioTapKit` product to your target's dependencies.

## Quickstart

A −6 dB pad in three lines:

```swift
import CoreAudioTapKit

let engine = SystemAudioTapEngine { samples, frames, channels in
    for i in 0..<(frames * channels) { samples[i] *= 0.5 }   // −6 dB
}

let output = try AudioDevices.defaultOutput()!
try engine.start(outputUID: output.uid)   // blocking for up to a few seconds; call off the main thread
// … later
engine.stop()
```

For stateful DSP, implement `AudioProcessor` and do sample-rate-dependent setup
in `prepare(sampleRate:)`:

```swift
final class MyEQ: AudioProcessor {
    func prepare(sampleRate: Double) {
        // build biquad coefficients for this rate (off the realtime thread)
    }
    func process(_ samples: UnsafeMutablePointer<Float>, frameCount: Int, channelCount: Int) {
        // mutate interleaved L R L R … in place, on the realtime thread
    }
}

let engine = SystemAudioTapEngine(processor: MyEQ())
```

Enumerate devices for a picker:

```swift
let outputs = try AudioDevices.outputs()          // [AudioOutputDevice]
let current = try AudioDevices.defaultOutput()    // AudioOutputDevice?
```

## The gotchas that make this hard

These are the mistakes that cost days. The kit handles all of them, and this
list is why it exists.

1. **Two clocks warble on Bluetooth.** A capture aggregate feeding a ring buffer
   drained by a separate output unit is the intuitive design and it is wrong for
   wireless outputs. See "Why this exists" above. The kit never creates a second
   output client.
2. **Process taps need macOS 14.2+.** Guarded internally; surfaced as
   `CoreAudioTapError.unsupportedOS`.
3. **Exclude your own process from the tap** and mute the tap, or you capture and
   re-emit your own output and feed back on yourself.
4. **Scope the tap to the output device's stream**, not the global mix, so the
   tap's format matches the output and there is no mixdown format mismatch.
5. **Wait for the aggregate device to report *alive* before starting the
   IOProc.** Otherwise you get a stream of silent buffers with no error, which is
   the single most common failure. The kit polls for it.
6. **A duplex interface puts its own inputs ahead of the tap's in the ABL.** On a
   USB interface with mic or line inputs, the first input buffers are the hardware
   preamps, not the system audio. The tap's streams are the trailing ones; the kit
   counts from the end and disables the unused hardware streams in its IOProc.
7. **Sample rate is whatever the device reports.** Never assume 48 kHz. The engine
   reads the device's nominal rate and passes it to `prepare(sampleRate:)`.
8. **Start and stop block.** Creating the tap and the aggregate, waiting for it to
   come alive, and `AudioDeviceStop` are all blocking round trips to
   `coreaudiod`, seconds in the worst case. Call them off the main thread.
9. **The app must not be sandboxed** (see Requirements).

## The processing contract

`process(_:frameCount:channelCount:)` runs on the **realtime audio thread** inside
the aggregate's IOProc, under a hard deadline. Do not allocate, lock heavily,
log, or block inside it. To hand a value in from your UI (a gain, a coefficient
set), use the lightest possible synchronization; `Sources/TapKitDemo/GainProcessor.swift`
shows a safe `os_unfair_lock` scalar handoff. `prepare(sampleRate:)` runs off the
realtime thread, so heavier setup belongs there.

`channelCount` is `2` in this version (stereo).

## Non-goals

- No EQ, filters, or DSP of any kind. That is your `AudioProcessor`.
- No room correction, mic capture, or measurement.
- No HAL virtual-device (driver) path. The process tap is the only capture path.
- No per-app processing. The tap is device-scoped by design; that is what makes
  the single clock possible.
- Stereo only, for now.

## Demo

```bash
swift run TapKitDemo
```

Pick an output device, hit **Start**, and drag the **Gain** slider: system audio
volume changes in real time. `swift run` launches an unbundled binary, which is
fine for local testing (it will trigger the TCC prompt). For a distributable
app, wrap the same code in a real, **non-sandboxed** `.app` bundle.

## Provenance

This is the system-audio layer of [Spectra](https://www.spectraaudio.tech), a
room-correction EQ for macOS, extracted and maintained by its developer, Cole
Stanfield. The DSP and the measurement stay in the app; the plumbing is here.

## License

MIT, see [LICENSE](LICENSE).
