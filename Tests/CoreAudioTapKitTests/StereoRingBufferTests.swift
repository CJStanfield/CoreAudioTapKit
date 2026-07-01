import Testing
@testable import CoreAudioTapKit

struct StereoRingBufferTests {
    @Test func writeThenReadRoundTrips() {
        let ring = StereoRingBuffer(capacityFrames: 8)
        let input: [Float] = [1, -1, 2, -2, 3, -3]  // 3 stereo frames
        input.withUnsafeBufferPointer { ring.writeInterleaved($0.baseAddress!, frameCount: 3, channelCount: 2) }
        #expect(ring.availableFrames == 3)

        var out = [Float](repeating: 99, count: 6)
        out.withUnsafeMutableBufferPointer { ring.readInterleaved($0.baseAddress!, frameCount: 3) }
        #expect(out == input)
        #expect(ring.availableFrames == 0)
    }

    @Test func readBeyondAvailableZeroFills() {
        let ring = StereoRingBuffer(capacityFrames: 8)
        var out = [Float](repeating: 42, count: 4)
        out.withUnsafeMutableBufferPointer { ring.readInterleaved($0.baseAddress!, frameCount: 2) }
        #expect(out == [0, 0, 0, 0])
    }

    @Test func wrapAroundPreservesOrder() {
        let ring = StereoRingBuffer(capacityFrames: 4)
        let a: [Float] = [1, 1, 2, 2, 3, 3]  // 3 frames into a 4-frame ring
        a.withUnsafeBufferPointer { ring.writeInterleaved($0.baseAddress!, frameCount: 3, channelCount: 2) }
        var drain = [Float](repeating: 0, count: 4)
        drain.withUnsafeMutableBufferPointer { ring.readInterleaved($0.baseAddress!, frameCount: 2) }
        let b: [Float] = [4, 4, 5, 5]  // 2 more frames, forces wrap
        b.withUnsafeBufferPointer { ring.writeInterleaved($0.baseAddress!, frameCount: 2, channelCount: 2) }
        var out = [Float](repeating: 0, count: 6)
        out.withUnsafeMutableBufferPointer { ring.readInterleaved($0.baseAddress!, frameCount: 3) }
        #expect(out == [3, 3, 4, 4, 5, 5])
    }

    @Test func resetClears() {
        let ring = StereoRingBuffer(capacityFrames: 4)
        let a: [Float] = [1, 1]
        a.withUnsafeBufferPointer { ring.writeInterleaved($0.baseAddress!, frameCount: 1, channelCount: 2) }
        ring.reset()
        #expect(ring.availableFrames == 0)
    }
}
