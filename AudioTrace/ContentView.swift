import SwiftUI
import ReplayKit
import AVKit

struct ContentView: View {
    @EnvironmentObject private var model: CaptureModel
    var body: some View {
        TabView {
            NavigationStack { capture }.tabItem { Label("录制", systemImage: "record.circle") }
            NavigationStack { history }.tabItem { Label("素材库", systemImage: "photo.on.rectangle.angled") }
            NavigationStack { TestView() }.tabItem { Label("诊断与测试", systemImage: "waveform.path.ecg") }
        }
        .alert("AudioTrace", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var capture: some View {
        List {
            Section {
                Label("Multimodal Capture Research", systemImage: "waveform.and.mic")
                    .font(.subheadline).foregroundStyle(.secondary)
                LabeledContent("设备", value: HardwareInfo.machine)
                LabeledContent("iOS", value: UIDevice.current.systemVersion)
            }
            if let active = model.active {
                Section("正在录制") {
                    LabeledContent("录制范围", value: active.metadata.requestedScope?.title ?? (active.metadata.mode == "broadcast" ? "系统屏幕广播" : "App 内录制"))
                    SessionStatus(metadata: active.metadata)
                    if active.metadata.mode == "broadcast" || active.metadata.mode == "screen_capture_kit" {
                        if model.fullDisplayConfirmed {
                            Label("已收到真实全屏视频，可以切换 App", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                            Text("切到豆包或主屏幕继续录制，完成后返回停止。录屏不保证在强制结束进程、锁屏或系统中断后继续。")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else { ProgressView("系统已启动，正在等待真实视频帧…") }
                    } else { Text("当前选择仅 App 内录制，切出会结束。").font(.footnote) }
                    Button(role: .destructive) { model.stop() } label: { Label("停止并保存到素材库", systemImage: "stop.circle.fill") }
                        .disabled(model.working || active.metadata.state == "finalizing")
                    if active.metadata.state == "finalizing" { ProgressView("正在完成文件…") }
                }
            } else {
                Section("1 · 选择录制范围") {
                    ForEach(RecordingScope.allCases) { scope in
                        Button { model.selectedScope = scope } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: model.selectedScope == scope ? "largecircle.fill.circle" : "circle")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(scope.title).font(.headline)
                                    Text(scope.explanation).font(.footnote).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                        }.buttonStyle(.plain).disabled(model.working || model.preparedBroadcast)
                    }
                }
                Section("2 · 录制条件") {
                    if let report = model.preflight {
                        Label(report.ready ? "当前模式具备启动条件" : "当前模式尚未具备启动条件", systemImage: report.ready ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(report.ready ? .green : .orange)
                        Text(report.message).font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("重新检查") { model.checkConditions() }.disabled(model.working)
                    if model.selectedScope == .appOnly { Toggle("包含麦克风", isOn: $model.microphoneEnabled) }
                }
                Section("3 · 启动录制") {
                    Button { model.startSelectedRecording() } label: {
                        Label(model.selectedScope == .appOnly ? "开始 App 内录制" : (model.nativeFullDisplayAvailable ? "打开系统全屏捕获" : "准备系统屏幕广播"), systemImage: "record.circle")
                    }.disabled(model.preflight?.ready != true || model.working || model.preparedBroadcast)
                    if model.preparedBroadcast {
                        HStack {
                            BroadcastPicker().frame(width: 54, height: 54).accessibilityLabel("系统屏幕广播授权")
                            Text("点击系统录屏按钮，选择 AudioTrace 并开始广播").font(.subheadline)
                        }
                        Button("取消本次准备") { model.cancelBroadcastPreparation() }
                    }
                    if let status = model.launchStatus { Text(status).font(.footnote).foregroundStyle(.secondary) }
                    if model.working { ProgressView("等待系统授权或文件完成…") }
                    if model.selectedScope.needsFullDisplay { Text("系统授权后，请等本页显示已收到真实全屏视频，再切换 App。不会自动改为 App 内录制。").font(.footnote) }
                }
            }
            Section {
                Text("录制结果会进入素材库。系统音频和麦克风从采集时就分开保存，素材可在本机播放和分别导出。诊断与测试在独立页面。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("录制")
            .onAppear { model.checkConditions() }
            .onChange(of: model.selectedScope) { _, _ in model.scopeChanged() }
    }

    private var history: some View {
        List {
            if model.sessions.isEmpty { ContentUnavailableView("还没有录制", systemImage: "tray", description: Text("录制结束后，Session 会显示在这里。")) }
            ForEach(model.sessions) { item in
                NavigationLink { SessionDetail(folder: item.folder, showDiagnostics: false) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.metadata.recordingStartTime.formatted(date: .numeric, time: .standard)).font(.headline)
                        Text("\(Int(item.metadata.durationSeconds)) 秒 · \(formatBytes(item.metadata.totalFileBytes)) · \(item.metadata.state)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("视频 \(formatBytes(item.videoBytes)) · 错误 \(item.metadata.errorCount) / 警告 \(item.metadata.warningCount)").font(.caption2)
                        Text("系统音频：\(item.metadata.systemAudio.state)\n麦克风：\(item.metadata.microphoneAudio.state)").font(.caption2)
                    }
                }
            }
            if model.hasMoreHistory { Button("加载更早的录制") { model.loadMoreHistory() } }
        }.navigationTitle("素材库").refreshable { await model.refresh() }
    }
}

struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 54, height: 54))
        picker.preferredExtension = CaptureConfiguration.extensionID
        picker.showsMicrophoneButton = true
        return picker
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

struct SessionStatus: View {
    let metadata: SessionMetadata
    var body: some View {
        LabeledContent("状态", value: metadata.state)
        LabeledContent("录制时长", value: "\(Int(metadata.durationSeconds)) 秒")
        LabeledContent("数据大小", value: formatBytes(metadata.totalFileBytes))
        LabeledContent("视频", value: "\(metadata.video.writtenFrames) 帧 / 丢弃 \(metadata.video.droppedFrames)")
        LabeledContent("系统音频", value: metadata.systemAudio.state)
        LabeledContent("麦克风", value: metadata.microphoneAudio.state)
    }
}

struct SessionDetail: View {
    let folder: URL
    var showDiagnostics = false
    @EnvironmentObject private var model: CaptureModel
    @State private var metadata: SessionMetadata?
    @State private var files: [URL] = []
    @State private var share: ShareItem?
    @State private var busy = false
    @State private var result: String?
    @State private var diagnostics = ""
    @State private var writerAlive = true
    var body: some View {
        List {
            if let metadata {
                Section("录制信息") {
                    LabeledContent("日期", value: metadata.recordingStartTime.formatted(date: .numeric, time: .omitted))
                    LabeledContent("时间", value: metadata.recordingStartTime.formatted(date: .omitted, time: .standard))
                    LabeledContent("录制范围", value: metadata.requestedScope?.title ?? metadata.mode)
                    Text(metadata.sessionId).font(.caption).textSelection(.enabled)
                    SessionStatus(metadata: metadata)
                    if showDiagnostics {
                        LabeledContent("测试场景", value: metadata.testScenario)
                        LabeledContent("事件数", value: "\(metadata.totalEventCount)")
                        LabeledContent("错误 / 警告", value: "\(metadata.errorCount) / \(metadata.warningCount)")
                        if let reason = metadata.stopReason { Text(reason).font(.caption).textSelection(.enabled) }
                    }
                }
                if showDiagnostics { Section("音频质量 · 最近一秒") {
                    AudioQuality(label: "系统音频", audio: metadata.systemAudio)
                    AudioQuality(label: "麦克风", audio: metadata.microphoneAudio)
                } }
                Section("检查与导出") {
                    Text("诊断包含事件的系统运行时间和剩余存储数值，用于定位中断与资源问题。分享会导出这些数据；可先查看下方 diagnostics.json 与完整日志。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("生成同步音视频 · 保留独立音轨") { createSynchronized() }.disabled(busy || writerAlive || model.active != nil)
                    Button("检查文件完整性与 SHA256") { verify() }.disabled(busy || writerAlive)
                    Button("导出整个 Session · ZIP") { export() }.disabled(busy || writerAlive)
                    if busy { ProgressView("正在处理，请保持 App 在前台…") }
                    if let result { Text(result).font(.footnote).textSelection(.enabled) }
                    if writerAlive { Text("录制停止并完成写入后可校验、播放和导出。").font(.footnote) }
                }
                Section("视频与音轨 · 点文件播放") {
                    ForEach(files.filter { ["wav", "mp4", "mov"].contains($0.pathExtension) }, id: \.path) { file in
                        HStack {
                            if ["wav", "mp4", "mov"].contains(file.pathExtension), !writerAlive {
                                NavigationLink { MediaPreview(url: file) } label: { VStack(alignment: .leading, spacing: 3) { Text(mediaTitle(file)).font(.subheadline); Text(file.lastPathComponent).font(.caption2).foregroundStyle(.secondary) } }
                            } else { Text(file.lastPathComponent).font(.caption) }
                            Spacer()
                            Text(formatBytes(Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)))
                                .font(.caption2).foregroundStyle(.secondary)
                            ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }.disabled(writerAlive)
                        }
                    }
                }
                if showDiagnostics { Section("诊断摘要 · 完整事件在 events.jsonl") {
                    NavigationLink("查看 diagnostics.json") { ScrollView { Text(diagnostics).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding() }.navigationTitle("诊断报告") }
                    ForEach(Array(metadata.errors.suffix(30).enumerated()), id: \.offset) { _, event in
                        VStack(alignment: .leading) { Text(event.code).font(.caption.bold()); Text(event.detail).font(.caption2).foregroundStyle(.secondary) }
                    }
                } }
                if showDiagnostics { Section("报告文件") { ForEach(files.filter { !["wav", "mp4", "mov"].contains($0.pathExtension) }, id: \.path) { file in ShareLink(file.lastPathComponent, item: file).disabled(writerAlive) } } }
            } else { Text("正在读取 Session…") }
        }
        .navigationTitle(showDiagnostics ? "会话诊断" : "录制素材")
        .sheet(item: $share) { ActivitySheet(items: [$0.url]) }
        .task {
            while !Task.isCancelled {
                await reload()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
    }
    private func reload() async {
        let loaded = await Task.detached(priority: .utility) {
            var latest = try? SessionStorage.read(SessionMetadata.self, from: folder.appendingPathComponent("metadata.json"))
            latest?.totalFileBytes = SessionStorage.bytes(in: folder)
            return (latest,
             SessionStorage.files(in: folder),
             (try? String(contentsOf: folder.appendingPathComponent("diagnostics.json"), encoding: .utf8)) ?? "无法读取诊断报告",
             SessionStorage.isWriterAlive(root: folder.deletingLastPathComponent()))
        }.value
        metadata = loaded.0; files = loaded.1; diagnostics = loaded.2; writerAlive = loaded.3
    }
    private func createSynchronized() {
        busy = true
        Task {
            do {
                _ = try await Task.detached(priority: .utility) { try await MultiTrackExporter.create(folder: folder) }.value
                result = "已生成同步 MOV。系统与麦克风保持独立音轨，轨道顺序记录在同步报告中。"
            } catch {
                result = "同步生成未完成：\(error.localizedDescription)；原始素材仍保留。"
                let failure = MediaOperationReport(operation: "synchronized_multitrack_export", at: Date(), domain: (error as NSError).domain, code: (error as NSError).code, message: error.localizedDescription)
                try? SessionStorage.write(failure, to: folder.appendingPathComponent("derivation_error.json"))
            }
            busy = false; await reload()
        }
    }
    private func verify() {
        busy = true
        Task {
            do {
                let checked = try await Task.detached(priority: .utility) { try await IntegrityChecker.check(folder: folder) }.value
                result = checked.passed ? "完整性检查通过。实际缺失音轨仍以 metadata 和诊断为准。" : checked.issues.joined(separator: "\n")
            } catch { result = error.localizedDescription }
            busy = false; await reload()
        }
    }
    private func export() {
        busy = true
        Task {
            do {
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Exports").appendingPathComponent("\(folder.lastPathComponent)_\(UUID().uuidString.prefix(6)).zip")
                let url = try await Task.detached(priority: .utility) { try SessionExporter.zip(folder: folder, destination: destination) }.value
                share = ShareItem(url: url)
            } catch { result = error.localizedDescription }
            busy = false
        }
    }
}

struct AudioQuality: View {
    let label: String
    let audio: AudioReport
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.headline)
            Text("回调 \(audio.callbacks) · 有效 PCM \(audio.validBuffers) · 非静音 \(audio.nonSilentBuffers)")
            Text(String(format: "RMS %.5f · Peak %.5f · 连续静音 %.1fs", audio.rms, audio.peak, audio.consecutiveSilenceSeconds))
            Text("接收 \(audio.receivedFrames) 帧 · 写入 \(audio.writtenFrames) 帧 · 丢弃 \(audio.droppedBuffers) 缓冲")
            Text(String(format: "文件时长 %.2fs · PTS 缺口 %.2fs", audio.durationSeconds, audio.detectedGapSeconds))
        }.font(.caption).textSelection(.enabled)
    }
}

struct TestView: View {
    @EnvironmentObject private var model: CaptureModel
    static let tests = ["1 · AudioTrace 屏幕与麦克风", "2 · 普通视频 App", "3 · 豆包普通语音", "4 · 豆包实时视觉语音", "5 · 五至十分钟持续对话"]
    private let instructions = [
        "在采集页启动 App 内录制，允许麦克风。回到自检页说话并播放测试音。停止后检查屏幕、两条 WAV、每秒 RMS 和 Peak。测试音是明确标记的刺激，不代表豆包音频。",
        "在录制页选跨 App 模式，通过条件检查后启动系统捕获并开启麦克风，切到普通、无 DRM 的视频 App 播放，再返回停止。检查 audioApp 是否有非静音数据。",
        "在录制页选跨 App 模式并启动系统捕获，切到豆包普通语音，交替说话与听回答。停止后检查系统/麦克风回调、静音和中断时间。",
        "启动广播后打开豆包实时视觉，对准物品并连续对话。检查摄像头预览是否被系统隐藏、三路数据是否持续以及权限冲突。不能预设兼容。",
        "连续对话至少五分钟，目标十分钟；期间旋转设备、切换前后台。另开短 Session 测试锁屏、来电、麦克风关闭和系统停止。停止后检查分段、时间映射、完整性与 ZIP。"
    ]
    var body: some View {
        List {
            Section("测试报告标签 · 不改变录制能力") {
                Picker("场景", selection: $model.scenario) { ForEach(Self.tests, id: \.self) { Text($0).tag($0) } }
                    .pickerStyle(.navigationLink).onChange(of: model.scenario) { _, _ in model.saveScenario() }
                Text("这里的场景只用于诊断测试标记，不会开启后台权限。正式录制请在录制页选择范围。").font(.footnote)
            }
            Section("独立 App 内自检") {
                Toggle("测试麦克风", isOn: $model.microphoneEnabled).disabled(model.active != nil)
                Button("开始 App 内自检") { model.startLocal(test: true) }.disabled(model.active != nil || model.working)
                if model.localRecording { Button("停止测试") { model.stop() }.disabled(model.working) }
                Text("仅用于验证本 App 的采集管线，切出会结束；不代表后台或豆包测试通过。").font(.footnote)
            }
            Section("启动条件诊断") {
                Button("检查当前录制模式") { model.checkConditions() }
                if let report = model.preflight { Text(report.code).font(.caption.monospaced()); Text(report.message).font(.footnote) }
                if let url = model.preflightURL { ShareLink("导出启动诊断 JSON", item: url) }
            }
            Section("每次会话的诊断与日志") {
                ForEach(model.sessions) { item in
                    NavigationLink { SessionDetail(folder: item.folder, showDiagnostics: true) } label: {
                        VStack(alignment: .leading) { Text(item.metadata.recordingStartTime.formatted(date: .numeric, time: .standard)); Text("\(item.metadata.state) · \(item.metadata.captureFramework)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Section("App 内声音刺激") {
                Button("播放 2 秒测试音 · 440 Hz") { model.playTestTone() }.disabled(!model.localRecording)
                Text("仅用于 App 内自检。请关闭静音并使用适当音量；扬声器的声音也可能被真实麦克风拾取。").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(Array(Self.tests.enumerated()), id: \.offset) { index, title in
                Section(title) { Text(instructions[index]).font(.subheadline) }
            }
            Section("如何反馈") {
                Text("导出 Session ZIP，附 iPhone 型号、iOS、Xcode/签名模式、豆包版本、操作顺序及异常大约发生时间。日志含实际采集信息，分享前检查屏幕和对话隐私。")
            }
        }.navigationTitle("诊断与测试")
    }
}

private struct ShareItem: Identifiable { let id = UUID(); let url: URL }
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
struct MediaPreview: View {
    let url: URL
    @EnvironmentObject private var model: CaptureModel
    @State private var audioActivated = false
    @State private var player: AVPlayer?
    @State private var audioTracks: [AVAssetTrack] = []
    @State private var selectedAudio = "both"
    var body: some View {
        Group {
            if url.pathExtension == "wav" { AudioFilePreview(url: url) }
            else {
                VStack {
                    VideoPlayer(player: player)
                    if audioTracks.count == 2 {
                        Picker("播放音轨", selection: $selectedAudio) {
                            Text("系统音轨").tag("system")
                            Text("麦克风音轨").tag("microphone")
                            Text("两条音轨").tag("both")
                        }.pickerStyle(.segmented).padding()
                    }
                }
                .onAppear { player = AVPlayer(url: url) }.onDisappear { player?.pause(); player = nil }
                .task {
                    if url.pathExtension == "mov", let asset = player?.currentItem?.asset {
                        audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
                        applyAudioSelection()
                    }
                }
                .onChange(of: selectedAudio) { _, _ in applyAudioSelection() }
            }
        }.navigationTitle(mediaTitle(url))
            .onAppear {
                if model.active == nil {
                    do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: .mixWithOthers); try AVAudioSession.sharedInstance().setActive(true); audioActivated = true }
                    catch { model.error = error.localizedDescription }
                }
            }
            .onDisappear { if audioActivated && model.active == nil { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) } }
    }
    private func applyAudioSelection() {
        guard audioTracks.count == 2 else { return }
        let mix = AVMutableAudioMix()
        mix.inputParameters = audioTracks.enumerated().map { index, track in
            let parameter = AVMutableAudioMixInputParameters(track: track)
            let audible = selectedAudio == "both" || (selectedAudio == "system" && index == 0) || (selectedAudio == "microphone" && index == 1)
            parameter.setVolume(audible ? 1 : 0, at: .zero)
            return parameter
        }
        player?.currentItem?.audioMix = mix // Playback only; captured tracks remain independent.
    }
}
func formatBytes(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

func mediaTitle(_ url: URL) -> String {
    if url.lastPathComponent == "synchronized_tracks.mov" { return "同步音视频 · 独立音轨" }
    if url.lastPathComponent.hasPrefix("system_audio") { return "系统音轨" }
    if url.lastPathComponent.hasPrefix("microphone_audio") { return "麦克风音轨" }
    return "屏幕视频"
}

struct AudioFilePreview: View {
    let url: URL
    @State private var player: AVAudioPlayer?
    @State private var position: Double = 0
    @State private var duration: Double = 0
    @State private var playing = false
    @State private var seeking = false
    @State private var error: String?
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform").font(.system(size: 64)).foregroundStyle(.tint)
            Text(mediaTitle(url)).font(.title2.bold())
            Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
            Slider(value: $position, in: 0...max(duration, 0.01), onEditingChanged: { editing in seeking = editing; if !editing { player?.currentTime = position } })
            Text("\(timeString(position)) / \(timeString(duration))").monospacedDigit()
            Button {
                guard let player else { return }
                if player.isPlaying { player.pause(); playing = false }
                else { if player.currentTime >= player.duration - 0.01 { player.currentTime = 0 }; playing = player.play() }
            } label: { Label(playing ? "暂停" : "播放", systemImage: playing ? "pause.circle.fill" : "play.circle.fill").font(.title) }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }.padding()
            .onAppear {
                do { player = try AVAudioPlayer(contentsOf: url); player?.prepareToPlay(); duration = player?.duration ?? 0 }
                catch { self.error = error.localizedDescription }
            }
            .onDisappear { player?.stop(); player = nil }
            .task {
                while !Task.isCancelled {
                    if let player { if !seeking { position = player.currentTime }; playing = player.isPlaying }
                    do { try await Task.sleep(for: .milliseconds(300)) } catch { break }
                }
            }
    }
    private func timeString(_ value: Double) -> String { String(format: "%02d:%02d", Int(value) / 60, Int(value) % 60) }
}

private struct MediaOperationReport: Codable {
    var operation: String
    var at: Date
    var domain: String
    var code: Int
    var message: String
}
