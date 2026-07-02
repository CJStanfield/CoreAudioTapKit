import SwiftUI
import CoreAudioTapKit

@MainActor
final class DemoModel: ObservableObject {
    @Published var devices: [AudioOutputDevice] = []
    @Published var selectedUID: String = ""
    @Published var isRunning = false
    @Published var gain: Double = 1.0 { didSet { processor.setGain(Float(gain)) } }
    @Published var errorText: String?

    private let processor = GainProcessor()
    private lazy var engine = SystemAudioTapEngine(processor: processor)

    func refresh() {
        do {
            devices = try AudioDevices.outputs()
            if selectedUID.isEmpty {
                selectedUID = (try? AudioDevices.defaultOutput())??.uid ?? devices.first?.uid ?? ""
            }
        } catch { errorText = error.localizedDescription }
    }

    func toggle() {
        errorText = nil
        if isRunning {
            engine.stop(); isRunning = false
        } else {
            do { try engine.start(outputUID: selectedUID); isRunning = true }
            catch { errorText = error.localizedDescription }
        }
    }
}

struct ContentView: View {
    @StateObject private var model = DemoModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Output", selection: $model.selectedUID) {
                ForEach(model.devices) { Text($0.name).tag($0.uid) }
            }
            .disabled(model.isRunning)

            HStack {
                Text("Gain")
                Slider(value: $model.gain, in: 0...2)
                Text(String(format: "%.2f×", model.gain)).monospacedDigit()
            }

            Button(model.isRunning ? "Stop" : "Start") { model.toggle() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedUID.isEmpty)

            if let err = model.errorText {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(20)
        .onAppear { model.refresh() }
    }
}
