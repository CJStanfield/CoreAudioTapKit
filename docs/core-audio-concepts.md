# Core Audio Concepts

A short glossary of the Apple building blocks CoreAudioTapKit stands on. If a
term in the code or in [How It Works](how-it-works.md) is unfamiliar, it's here.
Everything lives in two frameworks:

- [Core Audio](https://developer.apple.com/documentation/coreaudio) — the HAL
  (Hardware Abstraction Layer): devices, taps, aggregate devices, the property
  system.
- [Audio Toolbox](https://developer.apple.com/documentation/audiotoolbox) —
  audio units, including the AUHAL output unit and its render callback.

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
2. **A global tap captures *you* too** unless you exclude your own process — the
   reason the kit uses the `stereoGlobalTapButExcludeProcesses` initializer.

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

## AUHAL output unit

The **AUHAL** (AudioUnit Hardware Abstraction Layer) output unit is Apple's
standard audio unit for playing audio to a specific hardware device. You locate
it by its subtype [`kAudioUnitSubType_HALOutput`](https://developer.apple.com/documentation/audiotoolbox/kaudiounitsubtype_haloutput)
via [`AudioComponentFindNext`](https://developer.apple.com/documentation/audiotoolbox/audiocomponentfindnext(_:_:))
(matched with an [`AudioComponentDescription`](https://developer.apple.com/documentation/audiotoolbox/audiocomponentdescription)),
configure it with [`AudioUnitSetProperty`](https://developer.apple.com/documentation/audiotoolbox/audiounitsetproperty(_:_:_:_:_:_:)),
and run it with [`AudioOutputUnitStart`](https://developer.apple.com/documentation/audiotoolbox/audiooutputunitstart(_:)).

---

## Render callback

A **render callback** ([`AURenderCallback`](https://developer.apple.com/documentation/audiotoolbox/aurendercallback))
is the function the output unit calls, on its realtime thread, whenever it needs
another block of audio to play. You install it with
[`kAudioUnitProperty_SetRenderCallback`](https://developer.apple.com/documentation/audiotoolbox/kaudiounitproperty_setrendercallback).
In CoreAudioTapKit the callback drains the ring buffer, runs your
`AudioProcessor`, and copies the result into the unit's output buffers.

Because `AURenderCallback` is a plain C function pointer, the engine passes
itself across the boundary as an opaque `Unmanaged` pointer and unwraps it inside
the callback — a standard Core Audio Swift idiom.

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
