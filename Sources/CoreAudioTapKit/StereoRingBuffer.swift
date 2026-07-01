// StereoRingBuffer.swift — lock-protected interleaved stereo ring buffer.

import Foundation
import os.lock

// Single lock protects both channels atomically, preventing L/R desync if a
// render read fires between writes.
nonisolated final class StereoRingBuffer {
    private let capacity: Int  // in stereo frames
    nonisolated(unsafe) private var storage: [Float]  // interleaved L R L R ...
    nonisolated(unsafe) private var writePos = 0
    nonisolated(unsafe) private var readPos = 0
    nonisolated(unsafe) private var count = 0
    private let lock = os_unfair_lock_t.allocate(capacity: 1)

    init(capacityFrames: Int) {
        capacity = capacityFrames
        storage = Array(repeating: 0, count: capacityFrames * 2)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deallocate()
    }

    nonisolated var availableFrames: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return count
    }

    nonisolated func reset() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        writePos = 0
        readPos = 0
        count = 0
    }

    /// Write the first two channels from an interleaved input buffer.
    nonisolated func writeInterleaved(
        _ src: UnsafePointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) {
        guard channelCount >= 2 else { return }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        for i in 0..<frameCount {
            let sourceIndex = i * channelCount
            storage[writePos * 2] = src[sourceIndex]
            storage[writePos * 2 + 1] = src[sourceIndex + 1]
            advanceWritePosition()
        }
    }

    /// Write from separate non-interleaved channel buffers.
    nonisolated func writeNonInterleaved(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frameCount: Int
    ) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        for i in 0..<frameCount {
            storage[writePos * 2] = left[i]
            storage[writePos * 2 + 1] = right[i]
            advanceWritePosition()
        }
    }

    /// Read interleaved stereo frames into dst. Zero-fills if not enough data.
    nonisolated func readInterleaved(_ dst: UnsafeMutablePointer<Float>, frameCount: Int) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        let toRead = min(frameCount, count)
        for i in 0..<toRead {
            dst[i * 2] = storage[readPos * 2]
            dst[i * 2 + 1] = storage[readPos * 2 + 1]
            readPos = (readPos + 1) % capacity
        }
        count -= toRead

        for i in toRead..<frameCount {
            dst[i * 2] = 0
            dst[i * 2 + 1] = 0
        }
    }

    nonisolated private func advanceWritePosition() {
        writePos = (writePos + 1) % capacity
        if count == capacity {
            readPos = (readPos + 1) % capacity
        } else {
            count += 1
        }
    }
}
