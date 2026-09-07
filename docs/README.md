# CoreAudioTapKit Documentation

CoreAudioTapKit routes **all macOS system audio** through your code: it captures
the audio bound for an output device with a Core Audio process tap, lets you
modify the samples, and writes the result to that device, all inside one IOProc
on one clock.

```
system audio ─▶ device-scoped process tap ─┐
                                            ├─ ONE aggregate, ONE IOProc ─▶ your AudioProcessor ─▶ output device
physical output (clock master) ─────────────┘
```

These docs explain both **how it works** (so you can trust it and debug it) and
**how to use it** (so you can build your own audio app on top). Every Apple API
the kit touches links straight to Apple's documentation.

## Start here

| Doc | What it covers |
| --- | --- |
| [How It Works](how-it-works.md) | The full capture → process → output pipeline, one stage at a time, each tied to the exact Core Audio call and Apple's docs. Read this to understand the signal path. |
| [Core Audio Concepts](core-audio-concepts.md) | A glossary of the Apple building blocks — process taps, aggregate devices, clock masters and drift compensation, the property system, IOProcs — with links. Read this if a term in the code is unfamiliar. |
| [Using CoreAudioTapKit](using-coreaudiotapkit.md) | Integration guide: add the package, write an `AudioProcessor`, drive the engine, and the realtime rules you must follow. Read this to build something. |
| [Apple Reference Index](apple-references.md) | Every Apple documentation link the kit relies on, grouped by stage. A quick jump-off point into Apple's docs. |

## The one-paragraph version

macOS 14.2 added a public API, [`AudioHardwareCreateProcessTap`](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:)),
that lets a non-sandboxed app tap the system audio stream. On its own a tap
produces no audio you can read — you have to attach it to a private
[aggregate device](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateaggregatedevice(_:_:)),
wait for that device to come alive, and read samples in its
[IOProc](https://developer.apple.com/documentation/coreaudio/audiodevicecreateioprocidwithblock(_:_:_:_:)).
If the physical output is in that same aggregate as its clock master, the very
same IOProc call also hands you the output buffers, so you can process and
render on one clock. CoreAudioTapKit does all of that. The
[How It Works](how-it-works.md) doc walks the whole path and explains why the
single clock is not optional on Bluetooth.

## Source map

The library is small — each file owns one stage:

| File | Responsibility |
| --- | --- |
| `SystemTapCapture.swift` | Creates the device-scoped process tap and the single aggregate (output as clock master, tap drift-compensated), registers the one IOProc, works out which input buffers are the tap's, tears down in order. |
| `SystemAudioTapEngine.swift` | Public façade and the IOProc render target: normalizes tap input to stereo scratch, calls your processor, writes the aggregate's output buffers in the same call. |
| `AudioBufferListUtilities.swift` | Realtime-safe ABL helpers: zero fill, capacity, tap-buffer indexing for duplex interfaces, stereo normalize and write. |
| `AudioProcessor.swift` | The protocol you implement to modify audio, plus a closure adapter. |
| `AudioDevices.swift` / `AudioOutputDevice.swift` | Enumerate output devices for a picker. |
| `CoreAudioTapError.swift` | Typed errors, including the macOS-14.2 availability failure. |
