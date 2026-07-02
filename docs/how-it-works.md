# How It Works

CoreAudioTapKit moves audio through six stages. This page walks each one in the
order it happens at runtime, points at the exact Core Audio call that does the
work, and links to Apple's documentation for it. Code references are to the
files in `Sources/CoreAudioTapKit/`.

```
 ┌─────────────┐   ┌──────────────────┐   ┌──────────────┐   ┌─────────────┐   ┌──────────────┐
 │ 1. Process  │──▶│ 2. Aggregate     │──▶│ 3. Capture   │──▶│ 4. Ring     │──▶│ 5. Your      │──▶ 6. AUHAL
 │    tap      │   │    device (alive)│   │    IOProc    │   │    buffer   │   │  AudioProcessor│    output
 └─────────────┘   └──────────────────┘   └──────────────┘   └─────────────┘   └──────────────┘
```

---

## Stage 1 — Create the process tap

**File:** `SystemTapCapture.start(outputDeviceID:sampleRate:)`

A *process tap* is a macOS 14.2 object that receives a copy of audio flowing
through the system. We build a tap that captures the **global** mix but
**excludes our own process** (otherwise we would capture the very audio we are
about to play, and feed back on ourselves), and we mute the original tapped
stream so it plays only through our output, not twice.

```swift
let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcesses)
tapDescription.muteBehavior = .muted
var tapID = AudioObjectID(kAudioObjectUnknown)
AudioHardwareCreateProcessTap(tapDescription, &tapID)
```

- The description object: [`CATapDescription`](https://developer.apple.com/documentation/coreaudio/catapdescription)
- The "global, but exclude these PIDs" initializer: [`init(stereoGlobalTapButExcludeProcesses:)`](https://developer.apple.com/documentation/coreaudio/catapdescription/init(stereoglobaltapbutexcludeprocesses:))
- Muting the tapped source so it isn't heard twice: [`muteBehavior`](https://developer.apple.com/documentation/coreaudio/catapdescription/mutebehavior) / [`CATapMuteBehavior`](https://developer.apple.com/documentation/coreaudio/catapmutebehavior)
- Creating the tap: [`AudioHardwareCreateProcessTap`](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:))

**Excluding our own process** requires our process's Core Audio object ID, which
we get by translating our PID through the property system (see
[Stage 4's property mechanism](#the-property-system-underneath-everything)):

```swift
address.mSelector = kAudioHardwarePropertyTranslatePIDToProcessObject
AudioObjectGetPropertyData(/* system object */, &address, …, &pid, …, &processObjectID)
```

> **Why this matters:** a global tap with no exclusion captures your own
> playback. The kit does the PID→object translation and exclusion for you.

---

## Stage 2 — Attach the tap to a private aggregate device (and wait for it)

**File:** `SystemTapCapture.start` → `waitForAggregateDeviceToBecomeAlive`

A tap by itself produces nothing you can read. You make its audio available by
composing an **aggregate device** whose sub-device is your chosen output and
whose *tap list* contains the tap. We build it **private** (not visible in Sound
preferences) and set it to auto-start the tap.

```swift
let aggregateDescription: [String: Any] = [
    kAudioAggregateDeviceNameKey: TapKitIdentity.aggregateDeviceName,
    kAudioAggregateDeviceUIDKey: aggregateUID,
    kAudioAggregateDeviceMainSubDeviceKey: outputUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
    kAudioAggregateDeviceTapListKey: [[
        kAudioSubTapDriftCompensationKey: true,
        kAudioSubTapUIDKey: tapUUID.uuidString,
    ]],
]
AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID)
```

- Creating the aggregate: [`AudioHardwareCreateAggregateDevice`](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateaggregatedevice(_:_:))
- The composition keys: [`kAudioAggregateDeviceUIDKey`](https://developer.apple.com/documentation/coreaudio/kaudioaggregatedeviceuidkey), [`kAudioAggregateDeviceTapListKey`](https://developer.apple.com/documentation/coreaudio/kaudioaggregatedevicetaplistkey), [`kAudioSubTapUIDKey`](https://developer.apple.com/documentation/coreaudio/kaudiosubtapuidkey), [`kAudioAggregateDeviceTapAutoStartKey`](https://developer.apple.com/documentation/coreaudio/kaudioaggregatedevicetapautostartkey)

### The single most important gotcha: wait for `alive`

Creating the aggregate device returns **before it is ready**. If you start
pulling audio immediately you get a stream of silent/zero buffers with no error.
The kit polls the device's `IsAlive` property until it is true (up to ~3 s)
before doing anything else:

```swift
address.mSelector = kAudioDevicePropertyDeviceIsAlive
for _ in 0..<30 {
    AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &isAlive)
    if isAlive != 0 { return }
    Thread.sleep(forTimeInterval: 0.1)
}
```

> If you have ever tapped system audio and gotten only silence, this is almost
> always why. It is the reason this library exists.

---

## Stage 3 — Run the capture IOProc

**File:** `SystemTapCapture` → `handleTapIOProc`

An **IOProc** is a block Core Audio calls repeatedly on a realtime thread, each
time handing you a slice of captured audio. We register one on the aggregate
device and start it.

```swift
AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, nil) { _, inputData, _, _, _ in
    self.handleTapIOProc(inputData: inputData, outputData: outputData)   // copy into ring buffer
}
AudioDeviceStart(aggregateDeviceID, procID)
```

- Registering the block: [`AudioDeviceCreateIOProcIDWithBlock`](https://developer.apple.com/documentation/coreaudio/audiodevicecreateioprocidwithblock(_:_:_:_:))
- Starting/stopping capture: [`AudioDeviceStart`](https://developer.apple.com/documentation/coreaudio/audiodevicestart(_:_:)) / [`AudioDeviceStop`](https://developer.apple.com/documentation/coreaudio/audiodevicestop(_:_:))

Inside the IOProc we read the tap's buffers (the tap may deliver two mono
channels or one interleaved buffer — the kit handles both) and write the frames
into the ring buffer. That's the hand-off from the capture thread to the output
thread.

---

## Stage 4 — Buffer between two realtime threads

**File:** `StereoRingBuffer`

Capture (Stage 3) and output (Stage 6) run on **different realtime threads** at
different, unsynchronized rates. A ring buffer decouples them: the IOProc writes,
the render callback reads. A single `os_unfair_lock` guards both channels so a
read can never see left/right desynchronized. When the reader outpaces the
writer, reads zero-fill rather than block.

The engine pre-fills ~50 ms of audio into this buffer **before** starting output,
which gives a stable latency floor and prevents the initial silence you'd
otherwise hear while the buffer warms up.

### The property system underneath everything

Stages 1–3 all talk to Core Audio through one uniform mechanism: you describe
*what* you want with an [`AudioObjectPropertyAddress`](https://developer.apple.com/documentation/coreaudio/audioobjectpropertyaddress)
(a selector + scope + element) and read or write it with
[`AudioObjectGetPropertyData`](https://developer.apple.com/documentation/coreaudio/audioobjectgetpropertydata(_:_:_:_:_:_:)).
Device lists, device UIDs, sample rates, the `IsAlive` flag, the PID→object
translation — every one is a property read. See
[Core Audio Concepts](core-audio-concepts.md#the-property-system) for a fuller
explanation.

---

## Stage 5 — Your AudioProcessor

**File:** `SystemAudioTapEngine.handleOutputRender` calls
`processor.process(_:frameCount:channelCount:)`

This is your hook. For every block the output unit renders, the engine drains
that many frames from the ring buffer into a scratch buffer and hands it to your
[`AudioProcessor`](using-coreaudiotapkit.md) to mutate in place — interleaved
`L R L R …`, `channelCount == 2`. Whatever you write is what gets played. This is
the entire "modify" surface of the library; the kit ships no DSP of its own.

Your `prepare(sampleRate:)` was called earlier, off the realtime thread, with
the output device's actual sample rate — that's where sample-rate-dependent
setup belongs. See [Using CoreAudioTapKit](using-coreaudiotapkit.md#the-realtime-rules)
for the realtime rules `process` must obey.

---

## Stage 6 — Render to the output device (AUHAL)

**File:** `HALOutputEngine`

The final stage is an **AUHAL output unit** — the standard audio unit for
sending audio to a hardware output device. We find the component, point it at the
chosen device, set its input stream format to match the source sample rate,
install a render callback, and start it.

```swift
var desc = AudioComponentDescription(
    componentType: kAudioUnitType_Output,
    componentSubType: kAudioUnitSubType_HALOutput,      // the AUHAL
    componentManufacturer: kAudioUnitManufacturer_Apple, …)
let component = AudioComponentFindNext(nil, &desc)
// … AudioComponentInstanceNew, set CurrentDevice, set StreamFormat …
AudioUnitSetProperty(audioUnit, kAudioUnitProperty_SetRenderCallback, …, &cb, …)
AudioOutputUnitStart(audioUnit)
```

- Finding the unit: [`AudioComponentFindNext`](https://developer.apple.com/documentation/audiotoolbox/audiocomponentfindnext(_:_:)) with [`AudioComponentDescription`](https://developer.apple.com/documentation/audiotoolbox/audiocomponentdescription)
- The AUHAL subtype: [`kAudioUnitSubType_HALOutput`](https://developer.apple.com/documentation/audiotoolbox/kaudiounitsubtype_haloutput)
- Installing the callback: [`AudioUnitSetProperty`](https://developer.apple.com/documentation/audiotoolbox/audiounitsetproperty(_:_:_:_:_:_:)) + [`kAudioUnitProperty_SetRenderCallback`](https://developer.apple.com/documentation/audiotoolbox/kaudiounitproperty_setrendercallback)
- The callback type: [`AURenderCallback`](https://developer.apple.com/documentation/audiotoolbox/aurendercallback)
- Start/stop: [`AudioOutputUnitStart`](https://developer.apple.com/documentation/audiotoolbox/audiooutputunitstart(_:)) / [`AudioOutputUnitStop`](https://developer.apple.com/documentation/audiotoolbox/audiooutputunitstop(_:))

The render callback is a C function pointer, so the engine passes itself across
the boundary as an opaque pointer (`Unmanaged.passUnretained`) and unwraps it
inside the callback to reach `handleOutputRender` — Stage 5.

---

## Teardown

`stop()` reverses everything in order: stop and dispose the output unit, stop the
capture IOProc, destroy the aggregate device
([`AudioHardwareDestroyAggregateDevice`](https://developer.apple.com/documentation/coreaudio/audiohardwaredestroyaggregatedevice(_:))),
and destroy the tap
([`AudioHardwareDestroyProcessTap`](https://developer.apple.com/documentation/coreaudio/audiohardwaredestroyprocesstap(_:))).
Leaving a private aggregate device or tap alive across restarts leaks system
audio objects, so teardown always runs — including from `deinit` and at the top
of `start()`.

---

Next: [Core Audio Concepts](core-audio-concepts.md) for the vocabulary, or
[Using CoreAudioTapKit](using-coreaudiotapkit.md) to build with it.
