// SystemAudioTapEngine.swift — capture → user processor → output, the app-facing façade.

import AudioToolbox
import CoreAudio
import Foundation
import os.log

private let logger = Logger(subsystem: tapKitLogSubsystem, category: "TapEngine")

/// Captures all system audio, runs it through a user `AudioProcessor`, and
/// plays the result out on a chosen device.
///
/// The CoreAudio lifecycles live in `SystemTapCapture` and `HALOutputEngine`.
/// This type is the public façade and the AUHAL render-callback target.
public final class SystemAudioTapEngine {
    private static let scratchBufferFrameCapacity = 16_384

    private let processor: AudioProcessor
    private let ringBuffer: StereoRingBuffer
    private let tapCapture: SystemTapCapture
    private let outputEngine: HALOutputEngine

    nonisolated(unsafe) public private(set) var isRunning = false
    nonisolated(unsafe) private var outputSampleRate: Double = 48_000

    // Pre-allocated scratch buffer for the realtime render callback.
    nonisolated(unsafe) private let scratchBuffer = UnsafeMutablePointer<Float>.allocate(
        capacity: SystemAudioTapEngine.scratchBufferFrameCapacity * 2
    )

    public init(processor: AudioProcessor) {
        self.processor = processor
        let ring = StereoRingBuffer(capacityFrames: 9600)
        ringBuffer = ring
        tapCapture = SystemTapCapture(ringBuffer: ring, logger: logger)
        outputEngine = HALOutputEngine(logger: logger)
    }

    public convenience init(_ process: @escaping (UnsafeMutablePointer<Float>, Int, Int) -> Void) {
        self.init(processor: ClosureAudioProcessor(process))
    }

    deinit {
        stop()
        scratchBuffer.deallocate()
    }

    public func start(outputUID: String) throws {
        guard !outputUID.isEmpty else { throw CoreAudioTapError.missingDeviceUID }

        stop()
        ringBuffer.reset()

        do {
            let outputID = try SystemAudioDeviceLookup.resolveDeviceID(uid: outputUID)
            let reportedSR = SystemAudioDeviceLookup.sampleRate(for: outputID)
            let sampleRate = reportedSR > 0 ? reportedSR : 48_000
            outputSampleRate = sampleRate

            processor.prepare(sampleRate: sampleRate)
            logger.info("Output device \(outputID) sample rate: \(sampleRate)")

            isRunning = true

            // Stage 1: CATap captures the system mix into the ring buffer.
            try tapCapture.start(outputDeviceID: outputID, sampleRate: sampleRate)

            // Pre-fill: let the tap fill the ring before starting output.
            // Provides stable ~50 ms latency and prevents initial silence.
            Thread.sleep(forTimeInterval: 0.05)

            // Stage 2: AUHAL output on the physical device drains the ring and
            // runs the user processor in the render callback.
            try outputEngine.start(deviceID: outputID, sourceSampleRate: sampleRate, renderTarget: self)
        } catch {
            logger.error("Start failed: \(error.localizedDescription)")
            stop()
            throw error
        }
    }

    public func stop() {
        outputEngine.stop()
        tapCapture.stop()
        isRunning = false
        ringBuffer.reset()
    }

    /// AUHAL render callback target. Drains the ring, runs the processor in
    /// place, writes to the output buffers.
    nonisolated func handleOutputRender(
        inNumberFrames: UInt32,
        ioData: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let frameCount = Int(inNumberFrames)
        guard frameCount <= Self.scratchBufferFrameCapacity else {
            logger.error("Render requested \(frameCount) frames, exceeding scratch capacity")
            zeroFillAudioBuffers(ioData)
            return noErr
        }

        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        let temp = scratchBuffer

        ringBuffer.readInterleaved(temp, frameCount: frameCount)
        processor.process(temp, frameCount: frameCount, channelCount: 2)
        writeRenderOutput(from: temp, frameCount: frameCount, to: buffers)
        return noErr
    }

    private func writeRenderOutput(
        from samples: UnsafePointer<Float>,
        frameCount: Int,
        to buffers: UnsafeMutableAudioBufferListPointer
    ) {
        if buffers.count == 1 && buffers[0].mNumberChannels >= 2 {
            guard let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            memcpy(data, samples, frameCount * 2 * MemoryLayout<Float>.size)
        } else if buffers.count >= 2 {
            if let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                for i in 0..<frameCount { left[i] = samples[i * 2] }
            }
            if let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
                for i in 0..<frameCount { right[i] = samples[i * 2 + 1] }
            }
        }
    }
}
