// SystemAudioDeviceLookup.swift — resolve CoreAudio devices by UID.

import CoreAudio
import Foundation

nonisolated enum SystemAudioDeviceLookup {
    static func resolveDeviceID(uid: String) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        try checkCoreAudioStatus(
            AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize),
            operation: "GetDeviceListSize"
        )

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = Array(repeating: AudioObjectID(), count: count)
        try checkCoreAudioStatus(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids),
            operation: "GetDeviceList"
        )

        for id in ids {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfUID: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
                AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, pointer)
            }
            if status == noErr, (cfUID as String) == uid {
                return id
            }
        }

        throw CoreAudioTapError.missingDeviceUID
    }

    static func sampleRate(for deviceID: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &sampleRate) == noErr ? sampleRate : 0
    }

    static func uid(for deviceID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }
        try checkCoreAudioStatus(status, operation: "GetDeviceUID")
        return uid as String
    }
}
