import CoreAudioTapKit
import os.lock

/// Example processor: a single linear-gain multiplier. Thread-safe scalar set
/// from the UI, read on the audio thread.
final class GainProcessor: AudioProcessor {
    nonisolated(unsafe) private var gain: Float = 1.0
    private let lock = os_unfair_lock_t.allocate(capacity: 1)

    init() { lock.initialize(to: os_unfair_lock()) }
    deinit { lock.deallocate() }

    func setGain(_ value: Float) {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        gain = value
    }

    func process(_ samples: UnsafeMutablePointer<Float>, frameCount: Int, channelCount: Int) {
        os_unfair_lock_lock(lock); let g = gain; os_unfair_lock_unlock(lock)
        guard g != 1.0 else { return }
        for i in 0..<(frameCount * channelCount) { samples[i] *= g }
    }
}
