// SystemTapCapture.swift — CATap → aggregate device → ring buffer capture.

import AudioToolbox
import CoreAudio
import Foundation
import os.log

private struct TapFormatDescription {
    let channelCount: UInt32
    let sampleRate: Double
    let isInterleaved: Bool
    let isFloat: Bool
}

nonisolated final class SystemTapCapture {
    private let ringBuffer: StereoRingBuffer
    private let logger: Logger

    nonisolated(unsafe) private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    nonisolated(unsafe) private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    nonisolated(unsafe) private var aggregateIOProcID: AudioDeviceIOProcID?
    nonisolated(unsafe) private var aggregateIOBlock: AudioDeviceIOBlock?
    nonisolated(unsafe) private var tapChannelCount: Int = 2
    nonisolated(unsafe) private var inputCallCount: UInt64 = 0
    nonisolated(unsafe) private var isCapturing = false

    init(ringBuffer: StereoRingBuffer, logger: Logger) {
        self.ringBuffer = ringBuffer
        self.logger = logger
    }

    nonisolated func start(outputDeviceID: AudioObjectID, sampleRate: Double) throws {
        guard #available(macOS 14.2, *) else {
            throw CoreAudioTapError.unsupportedOS
        }

        stop()
        inputCallCount = 0

        let outputUID = try SystemAudioDeviceLookup.uid(for: outputDeviceID)
        let excludedProcesses = translateCurrentProcessForTapExclusion()

        let tapUUID = UUID()
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcesses)
        tapDescription.uuid = tapUUID
        tapDescription.muteBehavior = .muted
        tapDescription.name = TapKitIdentity.tapName

        tapID = AudioObjectID(kAudioObjectUnknown)
        try checkCoreAudioStatus(
            AudioHardwareCreateProcessTap(tapDescription, &tapID),
            operation: "AudioHardwareCreateProcessTap"
        )

        let tapFormat = queryTapFormat(tapID)
        tapChannelCount = max(1, Int(tapFormat?.channelCount ?? 2))

        let aggregateUID = "\(TapKitIdentity.aggregateDeviceUIDPrefix).\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: TapKitIdentity.aggregateDeviceName,
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                ]
            ],
        ]

        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        try checkCoreAudioStatus(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID),
            operation: "AudioHardwareCreateAggregateDevice"
        )

        waitForAggregateDeviceToBecomeAlive(aggregateDeviceID)

        var procID: AudioDeviceIOProcID?
        let ioBlock: AudioDeviceIOBlock = { [weak self] _, inputData, _, outputData, _ in
            guard let self else { return }
            self.handleTapIOProc(inputData: inputData, outputData: outputData)
        }
        aggregateIOBlock = ioBlock

        try checkCoreAudioStatus(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, nil, ioBlock),
            operation: "AudioDeviceCreateIOProcIDWithBlock"
        )
        aggregateIOProcID = procID

        isCapturing = true
        try checkCoreAudioStatus(
            AudioDeviceStart(aggregateDeviceID, procID),
            operation: "AudioDeviceStart(CATap aggregate)"
        )

        logStart(outputUID: outputUID, tapUUID: tapUUID, tapFormat: tapFormat, fallbackSampleRate: sampleRate)
    }

    nonisolated func stop() {
        isCapturing = false

        if let procID = aggregateIOProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            aggregateIOProcID = nil
        }
        aggregateIOBlock = nil

        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        tapChannelCount = 2
    }

    nonisolated private func handleTapIOProc(
        inputData: UnsafePointer<AudioBufferList>,
        outputData: UnsafeMutablePointer<AudioBufferList>
    ) {
        inputCallCount += 1
        guard isCapturing else { return }

        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard inputBuffers.count > 0 else {
            zeroFillAudioBuffers(outputData)
            return
        }

        if inputBuffers.count >= 2,
           inputBuffers[0].mNumberChannels == 1,
           inputBuffers[1].mNumberChannels == 1,
           let left = inputBuffers[0].mData?.assumingMemoryBound(to: Float.self),
           let right = inputBuffers[1].mData?.assumingMemoryBound(to: Float.self) {
            let frameCount = min(
                Int(inputBuffers[0].mDataByteSize),
                Int(inputBuffers[1].mDataByteSize)
            ) / MemoryLayout<Float>.size
            logInputPeakIfNeeded(left: left, right: right, frameCount: frameCount)
            ringBuffer.writeNonInterleaved(left: left, right: right, frameCount: frameCount)
        } else if let data = inputBuffers[0].mData?.assumingMemoryBound(to: Float.self) {
            let channelCount = max(1, Int(inputBuffers[0].mNumberChannels))
            let frameCount = Int(inputBuffers[0].mDataByteSize) / (MemoryLayout<Float>.size * channelCount)
            logInputPeakIfNeeded(data: data, sampleCount: frameCount * channelCount)

            if channelCount >= 2 {
                ringBuffer.writeInterleaved(data, frameCount: frameCount, channelCount: channelCount)
            } else {
                ringBuffer.writeNonInterleaved(left: data, right: data, frameCount: frameCount)
            }
        }

        zeroFillAudioBuffers(outputData)
    }

    nonisolated private func logInputPeakIfNeeded(data: UnsafePointer<Float>, sampleCount: Int) {
        guard inputCallCount <= 10 || inputCallCount % 2000 == 0 else { return }
        var peak: Float = 0
        for i in 0..<sampleCount {
            peak = max(peak, abs(data[i]))
        }
        logger.info("CATap input #\(self.inputCallCount): samples=\(sampleCount) peak=\(peak) fill=\(self.ringBuffer.availableFrames)")
    }

    nonisolated private func logInputPeakIfNeeded(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frameCount: Int
    ) {
        guard inputCallCount <= 10 || inputCallCount % 2000 == 0 else { return }
        var peak: Float = 0
        for i in 0..<frameCount {
            peak = max(peak, abs(left[i]), abs(right[i]))
        }
        logger.info("CATap input #\(self.inputCallCount): frames=\(frameCount) peak=\(peak) fill=\(self.ringBuffer.availableFrames)")
    }

    nonisolated private func translateCurrentProcessForTapExclusion() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = ProcessInfo.processInfo.processIdentifier
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &dataSize,
            &processObjectID
        )

        guard status == noErr, processObjectID != AudioObjectID(kAudioObjectUnknown) else {
            return []
        }

        return [processObjectID]
    }

    nonisolated private func queryTapFormat(_ tapID: AudioObjectID) -> TapFormatDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &format)
        guard status == noErr else { return nil }
        return TapFormatDescription(
            channelCount: format.mChannelsPerFrame,
            sampleRate: format.mSampleRate,
            isInterleaved: (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0,
            isFloat: (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        )
    }

    nonisolated private func waitForAggregateDeviceToBecomeAlive(_ deviceID: AudioObjectID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        for _ in 0..<30 {
            var isAlive: UInt32 = 0
            var dataSize = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &isAlive)
            if status == noErr, isAlive != 0 {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    nonisolated private func logStart(
        outputUID: String,
        tapUUID: UUID,
        tapFormat: TapFormatDescription?,
        fallbackSampleRate: Double
    ) {
        if let tapFormat {
            logger.info(
                "Started CATap global stereo muted | outputUID=\(outputUID, privacy: .public) tapUUID=\(tapUUID.uuidString, privacy: .public) tapID=\(self.tapID) aggregateID=\(self.aggregateDeviceID) fmt=\(tapFormat.sampleRate)Hz/\(tapFormat.channelCount)ch interleaved=\(tapFormat.isInterleaved) float=\(tapFormat.isFloat)"
            )
        } else {
            logger.info(
                "Started CATap global stereo muted | outputUID=\(outputUID, privacy: .public) tapUUID=\(tapUUID.uuidString, privacy: .public) tapID=\(self.tapID) aggregateID=\(self.aggregateDeviceID) fallbackSR=\(fallbackSampleRate)"
            )
        }
    }
}
