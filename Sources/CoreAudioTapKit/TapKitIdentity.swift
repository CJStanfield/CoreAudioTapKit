import Foundation

/// Logger subsystem for the whole package.
let tapKitLogSubsystem = "com.coreaudiotapkit"

/// Names CoreAudioTapKit uses when creating its process tap and aggregate device.
/// Consumers who ship two tap-based apps side by side can fork these.
enum TapKitIdentity {
    static let tapName = "CoreAudioTapKit-CATap"
    static let aggregateDeviceName = "CoreAudioTapKit Aggregate"
    static let aggregateDeviceUIDPrefix = "com.coreaudiotapkit.CATap"
}
