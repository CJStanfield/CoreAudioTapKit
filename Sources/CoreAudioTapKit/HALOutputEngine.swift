// HALOutputEngine.swift — AUHAL output unit rendering the ring buffer to a device.

import AudioToolbox
import CoreAudio
import Foundation
import os.log

nonisolated final class HALOutputEngine {
    private let logger: Logger
    nonisolated(unsafe) private var audioUnit: AudioUnit?

    init(logger: Logger) {
        self.logger = logger
    }

    nonisolated func start(
        deviceID: AudioObjectID,
        sourceSampleRate: Double,
        renderTarget: SystemAudioTapEngine
    ) throws {
        stop()

        let audioUnit = try configureAudioUnit(
            deviceID: deviceID,
            sourceSampleRate: sourceSampleRate,
            renderTarget: renderTarget
        )
        self.audioUnit = audioUnit

        try checkCoreAudioStatus(AudioOutputUnitStart(audioUnit), operation: "AudioOutputUnitStart")
        logger.info("Output AudioUnit started on device \(deviceID)")
    }

    nonisolated func stop() {
        if let audioUnit {
            AudioOutputUnitStop(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
            self.audioUnit = nil
        }
    }

    nonisolated private func configureAudioUnit(
        deviceID: AudioObjectID,
        sourceSampleRate: Double,
        renderTarget: SystemAudioTapEngine
    ) throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw CoreAudioTapError.audioComponentNotFound
        }

        var au: AudioUnit?
        try checkCoreAudioStatus(AudioComponentInstanceNew(component, &au), operation: "AudioComponentInstanceNew")
        guard let audioUnit = au else {
            throw CoreAudioTapError.audioComponentNotFound
        }

        var devID = deviceID
        try checkCoreAudioStatus(
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioObjectID>.size)
            ),
            operation: "Set output device"
        )

        var renderQuality: UInt32 = 127
        AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_RenderQuality,
            kAudioUnitScope_Global,
            0,
            &renderQuality,
            UInt32(MemoryLayout<UInt32>.size)
        )

        var inputFormat = AudioStreamBasicDescription(
            mSampleRate: sourceSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        try checkCoreAudioStatus(
            AudioUnitSetProperty(
                audioUnit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input,
                0,
                &inputFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ),
            operation: "Set input format"
        )

        var cb = AURenderCallbackStruct(
            inputProc: outputRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(renderTarget).toOpaque()
        )
        try checkCoreAudioStatus(
            AudioUnitSetProperty(
                audioUnit,
                kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input,
                0,
                &cb,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ),
            operation: "Set render callback"
        )

        try checkCoreAudioStatus(AudioUnitInitialize(audioUnit), operation: "AudioUnitInitialize")
        return audioUnit
    }
}

nonisolated(unsafe) private let outputRenderCallback: AURenderCallback = { inRefCon, _, _, _, inNumberFrames, ioData in
    guard let ioData else { return noErr }
    let bridge = Unmanaged<SystemAudioTapEngine>.fromOpaque(inRefCon).takeUnretainedValue()
    return bridge.handleOutputRender(inNumberFrames: inNumberFrames, ioData: ioData)
}
