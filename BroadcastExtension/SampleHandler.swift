import ReplayKit
import UIKit

final class SampleHandler: RPBroadcastSampleHandler {
    private var engine: CaptureEngine?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        do {
            let root = try CaptureConfiguration.recordingRoot(broadcast: true)
            let request = try? SessionStorage.read(BroadcastLaunchRequest.self, from: root.appendingPathComponent("launch_request.json"))
            let scenario = request?.scenario ?? (try? String(contentsOf: root.appendingPathComponent("test_scenario.txt"), encoding: .utf8)) ?? "unclassified"
            let created = try CaptureEngine(root: root, mode: "broadcast", scenario: scenario,
                device: HardwareInfo.machine, os: ProcessInfo.processInfo.operatingSystemVersionString,
                requestedScope: request?.scope, requestId: request?.requestId)
            engine = created
            created.event("BROADCAST_EXTENSION_STARTED", "Independent broadcast process created the session; waiting for genuine sample callbacks")
            created.onStopRequired = { [weak self] reason in
                self?.finishBroadcastWithError(NSError(domain: "AudioTrace.ControlledStop", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: reason == "user" ? "AudioTrace 已保存录制；由 App 请求停止。" : "AudioTrace 安全停止：\(reason)"]))
            }
            created.startMonitoring()
        } catch {
            finishBroadcastWithError(error)
        }
    }
    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        engine?.consume(sampleBuffer, type: sampleBufferType)
    }
    override func broadcastPaused() { engine?.setPaused(true) }
    override func broadcastResumed() { engine?.setPaused(false) }
    override func broadcastFinished() {
        // ReplayKit may tear down the process after this callback returns. Allow a bounded
        // finalization window; no sample buffers are held while waiting.
        guard let engine else { return }
        let done = DispatchSemaphore(value: 0)
        engine.finish(reason: "broadcast_finished") { done.signal() }
        if done.wait(timeout: .now() + 9) == .timedOut { engine.event("EXTENSION_FINALIZATION_DEADLINE", "OS may terminate before final checkpoint") }
    }
    override func broadcastAnnotated(withApplicationInfo applicationInfo: [AnyHashable: Any]) {
        engine?.event("BROADCAST_APPLICATION_ANNOTATION", String(describing: applicationInfo))
    }
}
