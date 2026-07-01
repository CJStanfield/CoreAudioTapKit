import Testing
import CoreAudio
@testable import CoreAudioTapKit

struct AudioDevicesTests {
    @Test func outputsDoesNotThrowAndFieldsAreSane() throws {
        let outs = try AudioDevices.outputs()
        for d in outs {
            #expect(!d.uid.isEmpty)
            #expect(d.sampleRate > 0)
            #expect(d.id != AudioObjectID(kAudioObjectUnknown))
        }
    }

    @Test func defaultOutputIsAmongOutputsWhenPresent() throws {
        guard let def = try AudioDevices.defaultOutput() else { return }  // headless CI: skip
        let outs = try AudioDevices.outputs()
        #expect(outs.contains(where: { $0.uid == def.uid }))
    }
}
