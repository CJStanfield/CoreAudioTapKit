// AudioBufferListUtilities.swift — zero-fill helpers for AudioBufferList.

import AudioToolbox
import Foundation

nonisolated func zeroFillAudioBuffers(_ ioData: UnsafeMutablePointer<AudioBufferList>) {
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    for buffer in buffers {
        guard let data = buffer.mData else { continue }
        memset(data, 0, Int(buffer.mDataByteSize))
    }
}
