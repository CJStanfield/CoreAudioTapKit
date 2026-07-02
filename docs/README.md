# CoreAudioTapKit Documentation

CoreAudioTapKit routes **all macOS system audio** through your code: it captures
the system mix with a Core Audio process tap, buffers it, lets you modify the
samples, and plays the result back out on a device you choose.

```
system audio ─▶ process tap ─▶ aggregate device ─▶ ring buffer ─▶ your AudioProcessor ─▶ AUHAL output
```

These docs explain both **how it works** (so you can trust it and debug it) and
**how to use it** (so you can build your own audio app on top). Every Apple API
the kit touches links straight to Apple's documentation.

## Start here

| Doc | What it covers |
| --- | --- |
| [How It Works](how-it-works.md) | The full capture → process → output pipeline, one stage at a time, each tied to the exact Core Audio call and Apple's docs. Read this to understand the signal path. |
| [Core Audio Concepts](core-audio-concepts.md) | A glossary of the Apple building blocks — process taps, aggregate devices, the property system, AUHAL, IOProcs, render callbacks — with links. Read this if a term in the code is unfamiliar. |
| [Using CoreAudioTapKit](using-coreaudiotapkit.md) | Integration guide: add the package, write an `AudioProcessor`, drive the engine, and the realtime rules you must follow. Read this to build something. |
| [Apple Reference Index](apple-references.md) | Every Apple documentation link the kit relies on, grouped by stage. A quick jump-off point into Apple's docs. |

## The one-paragraph version

macOS 14.2 added a public API, [`AudioHardwareCreateProcessTap`](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:)),
that lets a non-sandboxed app tap the system audio stream. On its own a tap
produces no audio you can read — you have to attach it to a private
[aggregate device](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateaggregatedevice(_:_:)),
wait for that device to come alive, and pull samples from its
[IOProc](https://developer.apple.com/documentation/coreaudio/audiodevicecreateioprocidwithblock(_:_:_:_:)).
CoreAudioTapKit does all of that, hands you the samples, and renders whatever you
hand back through an [AUHAL output unit](https://developer.apple.com/documentation/audiotoolbox/kaudiounitsubtype_haloutput).
The [How It Works](how-it-works.md) doc walks the whole path.

## Source map

The library is small — each file owns one stage:

| File | Responsibility |
| --- | --- |
| `SystemTapCapture.swift` | Creates the process tap + aggregate device, runs the capture IOProc, writes into the ring buffer. |
| `StereoRingBuffer.swift` | Lock-protected interleaved stereo ring buffer bridging the capture and output threads. |
| `HALOutputEngine.swift` | Configures and runs the AUHAL output unit and its render callback. |
| `SystemAudioTapEngine.swift` | Public façade; wires capture → ring → your processor → output; owns the render callback body. |
| `AudioProcessor.swift` | The protocol you implement to modify audio, plus a closure adapter. |
| `AudioDevices.swift` / `AudioOutputDevice.swift` | Enumerate output devices for a picker. |
| `CoreAudioTapError.swift` | Typed errors, including the macOS-14.2 availability failure. |
