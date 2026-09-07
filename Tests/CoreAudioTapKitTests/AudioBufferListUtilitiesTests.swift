import AudioToolbox
import Testing
@testable import CoreAudioTapKit

/// The render path's pure helpers, exercised with hand-built AudioBufferLists so the
/// duplex-interface and split-vs-interleaved cases are pinned without a device.
struct AudioBufferListUtilitiesTests {
    @Test func tapBuffersAreTheTrailingOnes() {
        // Output-only device: tap stream count unknown → buffer 0.
        #expect(tapBufferStartIndex(bufferCount: 2, tapStreamCount: 0) == 0)
        // MOTU-style duplex device: 2 hardware inputs ahead of 2 tap streams.
        #expect(tapBufferStartIndex(bufferCount: 4, tapStreamCount: 2) == 2)
        // Never negative.
        #expect(tapBufferStartIndex(bufferCount: 1, tapStreamCount: 3) == 0)
    }

    @Test func splitMonoPairInterleavesToStereo() {
        var left: [Float] = [1, 2, 3]
        var right: [Float] = [-1, -2, -3]
        var scratch = [Float](repeating: 0, count: 6)

        let frames = left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                withTwoBufferABL(l, r) { abl in
                    scratch.withUnsafeMutableBufferPointer { s in
                        normalizeToInterleavedStereo(abl, into: s.baseAddress!, maxFrames: 3)
                    }
                }
            }
        }
        #expect(frames == 3)
        #expect(scratch == [1, -1, 2, -2, 3, -3])
    }

    @Test func interleavedWideInputTakesFirstTwoChannels() {
        // 2 frames of 4-channel interleaved: only ch0/ch1 survive.
        var source: [Float] = [1, 2, 9, 9, 3, 4, 9, 9]
        var scratch = [Float](repeating: 0, count: 4)
        let frames = source.withUnsafeMutableBufferPointer { p in
            withOneBufferABL(p, channels: 4) { abl in
                scratch.withUnsafeMutableBufferPointer { s in
                    normalizeToInterleavedStereo(abl, into: s.baseAddress!, maxFrames: 8)
                }
            }
        }
        #expect(frames == 2)
        #expect(scratch == [1, 2, 3, 4])
    }

    @Test func duplexDeviceSkipsHardwareInputBuffers() {
        // Buffers 0 and 1 are the interface's preamps (noise); 2 and 3 are the tap.
        var noiseL: [Float] = [7, 7]
        var noiseR: [Float] = [7, 7]
        var tapL: [Float] = [1, 2]
        var tapR: [Float] = [-1, -2]
        var scratch = [Float](repeating: 0, count: 4)
        let frames = noiseL.withUnsafeMutableBufferPointer { a in
            noiseR.withUnsafeMutableBufferPointer { b in
                tapL.withUnsafeMutableBufferPointer { c in
                    tapR.withUnsafeMutableBufferPointer { d in
                        withFourBufferABL(a, b, c, d) { abl in
                            scratch.withUnsafeMutableBufferPointer { s in
                                normalizeToInterleavedStereo(
                                    abl, into: s.baseAddress!, maxFrames: 2,
                                    startingAtBuffer: tapBufferStartIndex(bufferCount: 4, tapStreamCount: 2)
                                )
                            }
                        }
                    }
                }
            }
        }
        #expect(frames == 2)
        #expect(scratch == [1, -1, 2, -2])
    }

    @Test func writeStereoIntoSplitAndInterleavedOutputs() {
        let stereo: [Float] = [1, -1, 2, -2]

        var l = [Float](repeating: 0, count: 2)
        var r = [Float](repeating: 0, count: 2)
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                withTwoBufferABL(lp, rp) { abl in
                    stereo.withUnsafeBufferPointer { s in
                        writeInterleavedStereo(
                            s.baseAddress!, frameCount: 2,
                            to: UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
                        )
                    }
                }
            }
        }
        #expect(l == [1, 2])
        #expect(r == [-1, -2])

        var wide = [Float](repeating: 0, count: 8)  // 2 frames × 4 channels
        wide.withUnsafeMutableBufferPointer { wp in
            withOneBufferABL(wp, channels: 4) { abl in
                stereo.withUnsafeBufferPointer { s in
                    writeInterleavedStereo(
                        s.baseAddress!, frameCount: 2,
                        to: UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
                    )
                }
            }
        }
        #expect(wide == [1, -1, 0, 0, 2, -2, 0, 0])
    }

    @Test func writableCapacityIsTheSmallestBuffer() {
        var a = [Float](repeating: 0, count: 8)
        var b = [Float](repeating: 0, count: 4)
        let capacity = a.withUnsafeMutableBufferPointer { ap in
            b.withUnsafeMutableBufferPointer { bp in
                withTwoBufferABL(ap, bp) { abl in
                    writableFrameCapacity(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl)))
                }
            }
        }
        #expect(capacity == 4)
    }
}

// MARK: - ABL builders

private func withOneBufferABL<R>(
    _ p: UnsafeMutableBufferPointer<Float>, channels: UInt32,
    _ body: (UnsafePointer<AudioBufferList>) -> R
) -> R {
    var abl = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
            mNumberChannels: channels,
            mDataByteSize: UInt32(p.count * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(p.baseAddress)
        )
    )
    return withUnsafePointer(to: &abl) { body($0) }
}

private func withTwoBufferABL<R>(
    _ a: UnsafeMutableBufferPointer<Float>, _ b: UnsafeMutableBufferPointer<Float>,
    _ body: (UnsafePointer<AudioBufferList>) -> R
) -> R {
    let list = AudioBufferList.allocate(maximumBuffers: 2)
    defer { free(list.unsafeMutablePointer) }
    list.count = 2
    list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(a.count * 4), mData: UnsafeMutableRawPointer(a.baseAddress))
    list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(b.count * 4), mData: UnsafeMutableRawPointer(b.baseAddress))
    return body(UnsafePointer(list.unsafePointer))
}

private func withFourBufferABL<R>(
    _ a: UnsafeMutableBufferPointer<Float>, _ b: UnsafeMutableBufferPointer<Float>,
    _ c: UnsafeMutableBufferPointer<Float>, _ d: UnsafeMutableBufferPointer<Float>,
    _ body: (UnsafePointer<AudioBufferList>) -> R
) -> R {
    let list = AudioBufferList.allocate(maximumBuffers: 4)
    defer { free(list.unsafeMutablePointer) }
    list.count = 4
    for (i, p) in [a, b, c, d].enumerated() {
        list[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(p.count * 4), mData: UnsafeMutableRawPointer(p.baseAddress))
    }
    return body(UnsafePointer(list.unsafePointer))
}
