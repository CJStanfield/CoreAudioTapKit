# Using CoreAudioTapKit

How to build your own system-audio app on top of the kit. If you want to
understand the machinery first, read [How It Works](how-it-works.md).

## 1. Add the package

```swift
// Package.swift
.package(url: "https://github.com/<you>/CoreAudioTapKit.git", from: "0.1.0")
```

Add the `CoreAudioTapKit` product to your target's dependencies. The package
requires **macOS 14.2+** (the process-tap API floor).

## 2. Meet the two requirements

- **Your app must not be sandboxed.** Process taps are unavailable to sandboxed
  apps. In an Xcode app target, remove the App Sandbox capability.
- **On macOS 14.4+ the user is prompted once** for "System Audio Recording
  Only" the first time you start capture. This is expected; capture proceeds
  once granted.

If you try to start on macOS older than 14.2, the engine throws
`CoreAudioTapError.unsupportedOS` rather than crashing.

## 3. Pick an output device

```swift
import CoreAudioTapKit

let outputs = try AudioDevices.outputs()            // [AudioOutputDevice] for a picker
let current = try AudioDevices.defaultOutput()      // AudioOutputDevice?
```

Each `AudioOutputDevice` (a CoreAudioTapKit value type)
carries `id`, `name`, `uid`, and `sampleRate`. You start the engine with the
`uid` (stable across launches; the numeric `id` is not).

## 4. Write an AudioProcessor

`AudioProcessor` is the whole "modify" surface. Two methods:

```swift
public protocol AudioProcessor: AnyObject {
    func prepare(sampleRate: Double)                                              // off the realtime thread
    func process(_ samples: UnsafeMutablePointer<Float>, frameCount: Int, channelCount: Int)  // ON it
}
```

- **`prepare(sampleRate:)`** is called at `start`, before any audio flows, on a
  normal thread. Do sample-rate-dependent setup here — allocate filter
  coefficients, size lookahead buffers, etc. It has a default no-op
  implementation, so skip it if you don't need it.
- **`process(...)`** is called for every output block, on the realtime audio
  thread. The buffer is interleaved `L R L R …` of length
  `frameCount * channelCount` (`channelCount == 2`). Mutate it in place; whatever
  you leave is what plays.

### Example: a stateful one-pole low-pass

```swift
import CoreAudioTapKit

final class LowPass: AudioProcessor {
    private var alpha: Float = 0
    private var zL: Float = 0, zR: Float = 0

    func prepare(sampleRate: Double) {
        let cutoff = 2_000.0
        let rc = 1.0 / (2 * .pi * cutoff)
        let dt = 1.0 / sampleRate
        alpha = Float(dt / (rc + dt))          // computed off the realtime thread
    }

    func process(_ s: UnsafeMutablePointer<Float>, frameCount: Int, channelCount: Int) {
        for i in 0..<frameCount {
            zL += alpha * (s[i*2]   - zL); s[i*2]   = zL
            zR += alpha * (s[i*2+1] - zR); s[i*2+1] = zR
        }
    }
}
```

For a trivial processor, skip the class entirely and use the closure initializer:

```swift
let engine = SystemAudioTapEngine { samples, frames, channels in
    for i in 0..<(frames * channels) { samples[i] *= 0.5 }   // −6 dB pad
}
```

## 5. Drive the engine

```swift
let engine = SystemAudioTapEngine(processor: LowPass())
try engine.start(outputUID: current!.uid)
// … audio now flows through LowPass …
engine.stop()
```

`start` resolves the device, reads its sample rate, calls your `prepare`, brings
up capture, pre-fills ~50 ms, then starts output — see
[How It Works](how-it-works.md) for the full sequence. `stop` tears the whole
chain down and is safe to call repeatedly. `deinit` calls `stop` for you, but
call it explicitly when you're done to release the tap promptly.

## The realtime rules

`process(...)` runs under a hard deadline on the audio thread. Break these and
you get glitches, drops, or priority inversions:

- **No allocation** — no `Array` growth, no `String`, no Swift runtime calls that
  might allocate. Pre-allocate in `prepare`.
- **No blocking** — no file/network I/O, no `DispatchQueue.sync`, no unbounded
  locks.
- **Hand values in cheaply.** To change a parameter from your UI, use the
  lightest synchronization possible. `Sources/TapKitDemo/GainProcessor.swift`
  shows the pattern: an `os_unfair_lock` guarding a single scalar, held for only
  the copy.

```swift
func setGain(_ v: Float) { os_unfair_lock_lock(lock); gain = v; os_unfair_lock_unlock(lock) }
func process(_ s: UnsafeMutablePointer<Float>, frameCount n: Int, channelCount c: Int) {
    os_unfair_lock_lock(lock); let g = gain; os_unfair_lock_unlock(lock)   // grab, release, then work
    for i in 0..<(n*c) { s[i] *= g }
}
```

## Errors

`start` throws `CoreAudioTapError` (defined in `Sources/CoreAudioTapKit/CoreAudioTapError.swift`):

| Case | Meaning |
| --- | --- |
| `.unsupportedOS` | Running on macOS < 14.2 — process taps don't exist. |
| `.missingDeviceUID` | Empty/invalid output UID passed to `start`. |
| `.audioComponentNotFound` | The AUHAL output component wasn't found (should not happen on a healthy system). |
| `.osStatus(status, operation)` | A specific Core Audio call failed; `operation` names which, `status` is the `OSStatus`. |

## Try the demo

```bash
swift run TapKitDemo
```

Device picker + gain slider, ~120 lines across three files in
`Sources/TapKitDemo/` — the smallest complete example of everything above.

---

See also: [Core Audio Concepts](core-audio-concepts.md) ·
[Apple Reference Index](apple-references.md)
