# Core Audio Concepts

A short glossary of the Apple building blocks CoreAudioTapKit stands on. If a
term in the code or in [How It Works](how-it-works.md) is unfamiliar, it's here.
Everything lives in two frameworks:

- [Core Audio](https://developer.apple.com/documentation/coreaudio) — the HAL
  (Hardware Abstraction Layer): devices, taps, aggregate devices, the property
  system.
- [Audio Toolbox](https://developer.apple.com/documentation/audiotoolbox) —
  aggregate devices, IOProcs, and the clock relationship between them.

---

## Process tap

A **process tap** (macOS 14.2+) is a system object that receives a copy of audio
as it flows through Core Audio. It can tap a single process or the whole system
mix, and can optionally mute the tapped source. You describe the tap you want
with a [`CATapDescription`](https://developer.apple.com/documentation/coreaudio/catapdescription)
and create it with [`AudioHardwareCreateProcessTap`](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:)).

Two facts about taps trip people up:

1. **A tap alone gives you no readable audio.** You must attach it to an
   aggregate device (below) to actually pull samples.
2. **A tap captures *you* too** unless you exclude your own process, which is
   why the kit uses the `excludingProcesses:deviceUID:stream:` initializer and
   scopes the tap to the output device rather than the global mix.

Apple's overview article: [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).

> **Naming note:** `CATapDescription` and `CATapMuteBehavior` use the `CA`
> prefix for **Core Audio**, not Core Animation. They live under
> `/documentation/coreaudio/`.

---

## Aggregate device

An **aggregate device** is a virtual device that combines one or more real
sub-devices — and, since macOS 14.2, one or more taps — into a single device you
can run. CoreAudioTapKit builds a **private** aggregate (invisible in Sound
settings) that pairs your chosen output device with the process tap, so reading
from the aggregate yields the tapped system audio.

- Create: [`AudioHardwareCreateAggregateDevice`](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateaggregatedevice(_:_:))
- Destroy: [`AudioHardwareDestroyAggregateDevice`](https://developer.apple.com/documentation/coreaudio/audiohardwaredestroyaggregatedevice(_:))
- Composed from a dictionary of keys: [`kAudioAggregateDeviceUIDKey`](https://developer.apple.com/documentation/coreaudio/kaudioaggregatedeviceuidkey),
  [`kAudioAggregateDeviceTapListKey`](https://developer.apple.com/documentation/coreaudio/kaudioaggregatedevicetaplistkey),
  [`kAudioSubTapUIDKey`](https://developer.apple.com/documentation/coreaudio/kaudiosubtapuidkey),
  [`kAudioAggregateDeviceTapAutoStartKey`](https://developer.apple.com/documentation/coreaudio/kaudioaggregatedevicetapautostartkey)

**It is not ready when creation returns.** Poll the `kAudioDevicePropertyDeviceIsAlive`
property until it's true before using it. This is the aggregate-alive gotcha
described in [How It Works, Stage 2](how-it-works.md#stage-2--attach-the-tap-to-a-private-aggregate-device-and-wait-for-it).

---

## IOProc

An **IOProc** is a callback Core Audio invokes on a dedicated realtime thread,
repeatedly, to hand your app a block of input audio and/or ask it for output
audio. The kit registers one on the aggregate device to receive captured frames.

- Register a block-based IOProc: [`AudioDeviceCreateIOProcIDWithBlock`](https://developer.apple.com/documentation/coreaudio/audiodevicecreateioprocidwithblock(_:_:_:_:))
- Run / halt it: [`AudioDeviceStart`](https://developer.apple.com/documentation/coreaudio/audiodevicestart(_:_:)) / [`AudioDeviceStop`](https://developer.apple.com/documentation/coreaudio/audiodevicestop(_:_:))

Because it runs on a realtime thread, an IOProc must never allocate, lock
heavily, or block — the same discipline your `AudioProcessor` follows.

---

## The property system

Nearly everything in Core Audio's HAL is read or written through **one uniform
API**. You point at a value with an
[`AudioObjectPropertyAddress`](https://developer.apple.com/documentation/coreaudio/audioobjectpropertyaddress)
— a `(selector, scope, element)` triple — and call
[`AudioObjectGetPropertyData`](https://developer.apple.com/documentation/coreaudio/audioobjectgetpropertydata(_:_:_:_:_:_:))
(or its `Set`/`DataSize` siblings) on a target object.

The kit uses this one mechanism for all of:

| What we want | Selector |
| --- | --- |
| List all devices | `kAudioHardwarePropertyDevices` |
| A device's UID / name | `kAudioDevicePropertyDeviceUID`, `kAudioObjectPropertyName` |
| A device's sample rate | `kAudioDevicePropertyNominalSampleRate` |
| Is the aggregate ready? | `kAudioDevicePropertyDeviceIsAlive` |
| Our own process object (to exclude) | `kAudioHardwarePropertyTranslatePIDToProcessObject` |
| The tap's audio format | `kAudioTapPropertyFormat` |

Once you internalize "it's all property reads," the CoreAudio surface in this
library stops looking exotic — it's the same three lines with a different
selector each time.

---

## Clock master and drift compensation

An aggregate device has exactly one **clock master**, the sub-device whose clock
drives the aggregate's IO cycle. You choose it with
[`kAudioAggregateDeviceMainSubDeviceKey`](https://developer.apple.com/documentation/coreaudio/kaudioaggregatedevicemainsubdevicekey).
Every other member is resampled to that clock by Core Audio when
[`kAudioSubTapDriftCompensationKey`](https://developer.apple.com/documentation/coreaudio/kaudiosubtapdriftcompensationkey)
(for taps) or the sub-device equivalent is set, at a quality chosen by
[`kAudioSubTapDriftCompensationQualityKey`](https://developer.apple.com/documentation/coreaudio/kaudiosubtapdriftcompensationqualitykey).
In CoreAudioTapKit the physical output is the clock master and the tap is
drift-compensated at maximum quality, which is what lets capture and render
share one clock.

---

## IOProc on an aggregate with input and output

An **IOProc** ([`AudioDeviceIOBlock`](https://developer.apple.com/documentation/coreaudio/audiodeviceioblock))
is the block Core Audio calls on a device's realtime thread once per IO cycle.
When the device is an aggregate that has both input members (our tap) and output
members (the physical device), a single call delivers the input buffers and the
output buffers together, for the same cycle, on the same clock. CoreAudioTapKit
registers one IOProc on its aggregate and does everything inside it: normalize
the tap's input, run your `AudioProcessor`, write the output. There is no
separate output unit and no ring buffer between threads, because there is only
one thread.

---


## Sample rate

There is no single system sample rate. Each device reports its own **nominal
sample rate** (`kAudioDevicePropertyNominalSampleRate`) — commonly 48 kHz, but
44.1 kHz and others are normal. The engine reads the output device's rate at
`start` and passes it to your `prepare(sampleRate:)`. Never hard-code 48 kHz in a
processor; configure from the value you're given.

---

Next: [Using CoreAudioTapKit](using-coreaudiotapkit.md) to put these together, or
the [Apple Reference Index](apple-references.md) for every link in one place.
