import Testing
@testable import CoreAudioTapKit

struct AudioProcessorTests {
    @Test func closureAdapterForwardsBufferAndCounts() {
        var seenFrames = 0
        var seenChannels = 0
        let proc = ClosureAudioProcessor { samples, frames, channels in
            seenFrames = frames
            seenChannels = channels
            for i in 0..<(frames * channels) { samples[i] *= 0.5 }
        }
        var buf: [Float] = [1, 1, 2, 2]  // 2 stereo frames
        buf.withUnsafeMutableBufferPointer {
            proc.process($0.baseAddress!, frameCount: 2, channelCount: 2)
        }
        #expect(seenFrames == 2)
        #expect(seenChannels == 2)
        #expect(buf == [0.5, 0.5, 1.0, 1.0])
    }

    @Test func defaultPrepareIsNoOp() {
        final class Bare: AudioProcessor {
            func process(_ s: UnsafeMutablePointer<Float>, frameCount: Int, channelCount: Int) {}
        }
        Bare().prepare(sampleRate: 48_000)  // compiles + does nothing
    }
}
