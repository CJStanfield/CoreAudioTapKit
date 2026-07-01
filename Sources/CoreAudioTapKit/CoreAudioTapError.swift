// CoreAudioTapError.swift — typed errors for the CoreAudio tap/output lifecycle.

import CoreAudio
import Foundation

public enum CoreAudioTapError: LocalizedError {
    case osStatus(OSStatus, String)
    case missingDeviceUID
    case audioComponentNotFound
    case unsupportedOS

    public var errorDescription: String? {
        switch self {
        case let .osStatus(status, operation):
            return "\(operation) failed with OSStatus \(status)."
        case .missingDeviceUID:
            return "A valid output device is required."
        case .audioComponentNotFound:
            return "Could not find the HAL output audio component."
        case .unsupportedOS:
            return "Core Audio process taps require macOS 14.2 or newer."
        }
    }
}

func checkCoreAudioStatus(_ status: OSStatus, operation: String) throws {
    guard status == noErr else {
        throw CoreAudioTapError.osStatus(status, operation)
    }
}
