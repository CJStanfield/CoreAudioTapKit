# How It Works

CoreAudioTapKit moves audio through four stages, and the last one is the whole
point: capture and output happen in one callback on one clock. This page walks
each stage in the order it happens at runtime, points at the exact Core Audio
call that does the work, and links to Apple's documentation for it. Code
references are to the files in `Sources/CoreAudioTapKit/`.

```
 ┌──────────────────────┐   ┌────────────────────────────────────┐   ┌───────────────────────────────┐
 │ 1. Device-scoped     │──▶│ 2. ONE private aggregate:          │──▶│ 3. ONE IOProc: tap input in,  │
 │    process tap       │   │    tap + physical output,          │   │    your AudioProcessor,       │
 │    (muted, excludes  │   │    output is clock master,         │   │    written to the aggregate's │
 │    our process)      │   │    tap drift-compensated (alive?)  │   │    output buffers, same call  │
 └──────────────────────┘   └────────────────────────────────────┘   └───────────────────────────────┘
```

---

## Stage 1 — Create the process tap

**File:** `SystemTapCapture.start(outputDeviceID:sampleRate:)`

A *process tap* is a macOS 14.2 object that receives a copy of audio flowing
through the system. We build a tap **scoped to the chosen output device's
stream**, so the tap's format matches that stream exactly and there is no
global-mixdown format mismatch to reconcile later. It **excludes our own
process** (otherwise we would capture the very audio we are about to play, and
feed back on ourselves), and it is **muted**, so the tapped audio plays only
through our output, not twice.

```swift
let tapDescription = CATapDescription(excludingProcesses: excludedProcesses, deviceUID: outputUID, stream: 0)
tapDescription.muteBehavior = .muted
var tapID = AudioObjectID(kAudioObjectUnknown)
AudioHardwareCreateProcessTap(tapDescription, &tapID)
```

- The description object: [`CATapDescription`](https://developer.apple.com/documentation/coreaudio/catapdescription)
- The device-scoped "exclude these PIDs" initializer: [`init(excludingProcesses:deviceUID:stream:)`](https://developer.apple.com/documentation/coreaudio/catapdescription/init(excludingprocesses:deviceuid:stream:))
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
whose *tap list* contains the tap. This is also where the single clock is
decided: the physical output is the aggregate's **main sub-device**, which makes
it the clock master, and the tap is **drift-compensated at maximum quality**
against that clock. We build the aggregate **private** (not visible in Sound
settings) and set it to auto-start the tap.

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

## Stage 3 — One IOProc: capture, process, and render in the same call

**File:** `SystemTapCapture.start` registers the block; `SystemAudioTapEngine.handleUnifiedRender` is the body

An **IOProc** is a block Core Audio calls repeatedly on a realtime thread. On an
aggregate that contains both an input (our tap) and an output (the physical
device), one IOProc invocation delivers the tap's input buffers **and** the
device's output buffers together. We register one IOProc on the aggregate, and
in every call we normalize the tap's input to interleaved stereo scratch, hand
that to your `AudioProcessor`, and write the result into the output buffers
before returning.

```swift
AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, nil) { _, inputData, _, outputData, _ in
    renderTarget.handleUnifiedRender(inputData: inputData, outputData: outputData, tapStreamCount: tapStreams)
}
AudioDeviceStart(aggregateDeviceID, procID)
```

- Registering the block: [`AudioDeviceCreateIOProcIDWithBlock`](https://developer.apple.com/documentation/coreaudio/audiodevicecreateioprocidwithblock(_:_:_:_:))
- Starting/stopping: [`AudioDeviceStart`](https://developer.apple.com/documentation/coreaudio/audiodevicestart(_:_:)) / [`AudioDeviceStop`](https://developer.apple.com/documentation/coreaudio/audiodevicestop(_:_:))
- The block signature (input and output ABLs in one call): [`AudioDeviceIOBlock`](https://developer.apple.com/documentation/coreaudio/audiodeviceioblock)

There is no ring buffer, no second thread, and no second output client. The tap's
frames go to your processor and out to the device in the same callback, on the
device's clock.

### Which input buffers are the tap's

A plain output device contributes no input streams, so the tap's buffers start at
index 0. A **duplex** interface (a USB interface with mic or line inputs) donates
its own input streams to the aggregate **ahead of** the tap's, so on a MOTU M4
the first input buffers are the hardware preamps, not the system audio. The kit
counts the tap's streams as the difference between the aggregate's input streams
and the device's own, treats the tap's buffers as the **trailing** ones, and
turns the device's unused hardware streams off in its IOProc so they are not
pulled every cycle.

- Stream counts: [`kAudioDevicePropertyStreams`](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertystreams)
- Per-IOProc stream enablement: [`kAudioDevicePropertyIOProcStreamUsage`](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertyioprocstreamusage) / [`AudioHardwareIOProcStreamUsage`](https://developer.apple.com/documentation/coreaudio/audiohardwareioprocstreamusage)

### The property system underneath everything

Stages 1 to 3 all talk to Core Audio through one uniform mechanism: you describe
*what* you want with an [`AudioObjectPropertyAddress`](https://developer.apple.com/documentation/coreaudio/audioobjectpropertyaddress)
(a selector + scope + element) and read or write it with
[`AudioObjectGetPropertyData`](https://developer.apple.com/documentation/coreaudio/audioobjectgetpropertydata(_:_:_:_:_:_:)).
Device lists, device UIDs, sample rates, the `IsAlive` flag, the PID to object
translation, stream counts: every one is a property read. See
[Core Audio Concepts](core-audio-concepts.md#the-property-system) for a fuller
explanation.

---

## Stage 4 — Your AudioProcessor

**File:** `SystemAudioTapEngine.handleUnifiedRender` calls
`processor.process(_:frameCount:channelCount:)`

This is your hook. For every IOProc call, the engine hands you the tap's frames
for that cycle as interleaved `L R L R …` with `channelCount == 2`, to mutate in
place. Whatever you write is what gets played, in that same cycle. This is the
entire "modify" surface of the library; the kit ships no DSP of its own.

Your `prepare(sampleRate:)` was called earlier, off the realtime thread, with
the output device's actual sample rate; that is where sample-rate-dependent
setup belongs. See [Using CoreAudioTapKit](using-coreaudiotapkit.md#the-realtime-rules)
for the realtime rules `process` must obey.

---

## Why one clock

The first public version of this kit did what most examples do: a tap-only
aggregate captured into a ring buffer, and a separate AUHAL output unit drained
the ring and played it. On built-in speakers that is fine. On Bluetooth it
warbles in pitch, about ±0.5 to 1% on a two-second period, worst for 44.1 kHz
sources on a 48 kHz-presented device, plus a several-percent glide at every
playback start while the earbuds' playout servo re-centers.

The cause is that the two ends were on **independent clocks**. A Bluetooth
device's clock estimate wobbles short-term by a percent or more, and every
mechanism that reconciles the two domains (Core Audio's own sample rate
conversion on the tap, ring fill rails, a PI-controlled varispeed servo)
prints that wobble into the audio. Bigger buffers, more lookahead, lighter
callbacks, tuned servos, keep-alive dither, and pinning the device rate were all
tried and all falsified by experiment. A minimal repro with zero application
code reproduced the warble whenever two clocks existed.

With the tap and the physical output in one aggregate clocked by the output,
Core Audio does its drift compensation inside its own machinery against the
clock the audio actually plays on, and there is nothing left to reconcile. That
is the whole design, and it is why this kit will not grow a ring buffer again.

---

## Teardown

`stop()` reverses everything in order: clear the capturing flag, stop and
destroy the IOProc, destroy the aggregate device
([`AudioHardwareDestroyAggregateDevice`](https://developer.apple.com/documentation/coreaudio/audiohardwaredestroyaggregatedevice(_:))),
and destroy the tap
([`AudioHardwareDestroyProcessTap`](https://developer.apple.com/documentation/coreaudio/audiohardwaredestroyprocesstap(_:))).
Leaving a private aggregate device or tap alive across restarts leaks system
audio objects, so teardown always runs, including from `deinit` and at the top
of `start()`. `AudioDeviceStop` blocks until the device's IO thread has left the
running state, so call `stop()` off the main thread too.

---

Next: [Core Audio Concepts](core-audio-concepts.md) for the vocabulary, or
[Using CoreAudioTapKit](using-coreaudiotapkit.md) to build with it.
