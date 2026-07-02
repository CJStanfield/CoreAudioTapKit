# CoreAudioTapKit

Correctly capture, modify, and play back **all** macOS system audio on modern
macOS (14.2+). The kit owns the painful CoreAudio lifecycle — process tap,
aggregate device, ring buffer, and AUHAL output — and hands you raw stereo
frames through one realtime hook:

```
system audio ──▶ CATap ──▶ ring buffer ──▶ your AudioProcessor ──▶ output device
```

**No DSP is included.** You bring the audio math (EQ, effects, metering,
recording); CoreAudioTapKit gets the signal to you and back out cleanly.

## Requirements

- **macOS 14.2 or newer** — `AudioHardwareCreateProcessTap` doesn't exist before
  then. Attempting to start on an older OS throws `CoreAudioTapError.unsupportedOS`.
- **The host app must not be sandboxed.** Process taps are unavailable to
  sandboxed apps.
- On **macOS 14.4+** the user is prompted once for "System Audio Recording Only"
  the first time you start capture.

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/<you>/CoreAudioTapKit.git", from: "0.1.0")
```

Then add the `CoreAudioTapKit` product to your target's dependencies.

## Quickstart

The closure form — a −6 dB pad in three lines:

```swift
import CoreAudioTapKit

let engine = SystemAudioTapEngine { samples, frames, channels in
    for i in 0..<(frames * channels) { samples[i] *= 0.5 }   // −6 dB
}

let output = try AudioDevices.defaultOutput()!
try engine.start(outputUID: output.uid)
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

These are the mistakes that cost days. CoreAudioTapKit handles all of them —
this list is why the library exists.

1. **Process taps need macOS 14.2+.** Guarded internally; surfaced as
   `CoreAudioTapError.unsupportedOS`.
2. **Exclude your own process from the tap** (and mute it), or you capture and
   re-emit your own output and feed back on yourself. The kit builds the tap
   with the current process excluded and `muteBehavior = .muted`.
3. **Wait for the aggregate device to report *alive* before capturing.** If you
   start the IOProc before the private aggregate device is ready, you get a
   stream of silent/zero buffers with no error — the single most common failure.
   `SystemTapCapture` polls for the alive state before starting.
4. **Sample rate is whatever the device reports** (Continuity mic ≈ 48 kHz,
   built-in ≈ 44.1 kHz) — never assume 48 kHz. The engine reads the device's
   nominal rate and passes it to `prepare(sampleRate:)`; configure your DSP there.
5. **The app must not be sandboxed** (see Requirements).

## The processing contract

`process(_:frameCount:channelCount:)` runs on the **realtime audio thread** under
a hard deadline. Do not allocate, lock heavily, or block inside it. If you need
to hand a value in from your UI (a gain, a coefficient set), use the lightest
possible synchronization — see `Sources/TapKitDemo/GainProcessor.swift` for a
safe `os_unfair_lock` scalar handoff. `prepare(sampleRate:)` runs off the
realtime thread, so heavier setup belongs there.

`channelCount` is `2` in this version (stereo).

## Non-goals

- No EQ / filters / DSP of any kind — that's your `AudioProcessor`.
- No room correction, mic capture, or measurement.
- No HAL virtual-device (driver) path — CATap is the only capture path.
- Stereo only, for now.

## Demo

```bash
swift run TapKitDemo
```

Pick an output device, hit **Start**, and drag the **Gain** slider — system
audio volume changes in real time. `swift run` launches an unbundled binary,
which is fine for local testing (it will trigger the TCC prompt). For a
distributable app, wrap the same code in a real, **non-sandboxed** `.app` bundle.

## License

MIT — see [LICENSE](LICENSE).
