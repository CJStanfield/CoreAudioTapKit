# Apple Reference Index

Every Apple documentation page CoreAudioTapKit relies on, grouped by pipeline
stage. All links were verified live. For how these fit together, see
[How It Works](how-it-works.md); for what the terms mean, see
[Core Audio Concepts](core-audio-concepts.md).

## Frameworks

- [Core Audio](https://developer.apple.com/documentation/coreaudio) — HAL,
  taps, aggregate devices, property system
- [Audio Toolbox](https://developer.apple.com/documentation/audiotoolbox) —
  the clock and drift-compensation keys

## Background reading

- [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
  — Apple's overview article for the tap API (macOS 14.2+).

> Note: there is **no** WWDC session dedicated to Core Audio taps, and no
> Apple-hosted downloadable sample project. The API shipped in macOS 14.2
> documented only by the article above.

## Stage 1 — Process tap

- [`CATapDescription`](https://developer.apple.com/documentation/coreaudio/catapdescription)
- [`init(excludingProcesses:deviceUID:stream:)`](https://developer.apple.com/documentation/coreaudio/catapdescription/init(excludingprocesses:deviceuid:stream:))
- [`muteBehavior`](https://developer.apple.com/documentation/coreaudio/catapdescription/mutebehavior)
- [`CATapMuteBehavior`](https://developer.apple.com/documentation/coreaudio/catapmutebehavior)
- [`AudioHardwareCreateProcessTap`](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:))
- [`AudioHardwareDestroyProcessTap`](https://developer.apple.com/documentation/coreaudio/audiohardwaredestroyprocesstap(_:))

## Stage 2 — Aggregate device

- [`AudioHardwareCreateAggregateDevice`](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateaggregatedevice(_:_:))
- [`AudioHardwareDestroyAggregateDevice`](https://developer.apple.com/documentation/coreaudio/audiohardwaredestroyaggregatedevice(_:))
- [`kAudioAggregateDeviceUIDKey`](https://developer.apple.com/documentation/coreaudio/kaudioaggregatedeviceuidkey)
- [`kAudioAggregateDeviceTapListKey`](https://developer.apple.com/documentation/coreaudio/kaudioaggregatedevicetaplistkey)
- [`kAudioSubTapUIDKey`](https://developer.apple.com/documentation/coreaudio/kaudiosubtapuidkey)
- [`kAudioAggregateDeviceTapAutoStartKey`](https://developer.apple.com/documentation/coreaudio/kaudioaggregatedevicetapautostartkey)
- [`kAudioAggregateDeviceMainSubDeviceKey`](https://developer.apple.com/documentation/coreaudio/kaudioaggregatedevicemainsubdevicekey) (clock master)
- [`kAudioSubTapDriftCompensationKey`](https://developer.apple.com/documentation/coreaudio/kaudiosubtapdriftcompensationkey)
- [`kAudioSubTapDriftCompensationQualityKey`](https://developer.apple.com/documentation/coreaudio/kaudiosubtapdriftcompensationqualitykey)
- [`kAudioAggregateDriftCompensationMaxQuality`](https://developer.apple.com/documentation/coreaudio/kaudioaggregatedriftcompensationmaxquality)

## Stage 3 — The one IOProc (capture, process, render)

- [`AudioDeviceCreateIOProcIDWithBlock`](https://developer.apple.com/documentation/coreaudio/audiodevicecreateioprocidwithblock(_:_:_:_:))
- [`AudioDeviceStart`](https://developer.apple.com/documentation/coreaudio/audiodevicestart(_:_:))
- [`AudioDeviceStop`](https://developer.apple.com/documentation/coreaudio/audiodevicestop(_:_:))
- [`AudioDeviceIOBlock`](https://developer.apple.com/documentation/coreaudio/audiodeviceioblock)
- [`kAudioDevicePropertyStreams`](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertystreams)
- [`kAudioDevicePropertyIOProcStreamUsage`](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertyioprocstreamusage)

## Cross-cutting — Property system

- [`AudioObjectGetPropertyData`](https://developer.apple.com/documentation/coreaudio/audioobjectgetpropertydata(_:_:_:_:_:_:))
- [`AudioObjectPropertyAddress`](https://developer.apple.com/documentation/coreaudio/audioobjectpropertyaddress)
