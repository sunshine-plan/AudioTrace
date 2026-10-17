import SwiftUI

@main
struct AudioTraceApp: App {
    @StateObject private var model = CaptureModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model)
                .onChange(of: phase) { _, value in
                    if value == .background { model.enteredBackground() }
                    if value == .active { model.enteredForeground() }
                }
                .task(id: phase) {
                    guard phase == .active else { return }
                    model.saveScenario()
                    while !Task.isCancelled {
                        await model.refresh()
                        do { try await Task.sleep(for: .seconds(2)) } catch { break }
                    }
                }
        }
    }
}
