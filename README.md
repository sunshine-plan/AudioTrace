# AudioTrace

An experimental, local-only iOS recorder built with SwiftUI and ReplayKit. Screen video, app audio, and microphone audio are saved separately, with timestamp-based export to a movie containing independent audio tracks.

**当前版本：1.1（3）。这是可自行编译的实验项目，后台连续性及第三方 App 音频兼容性仍需真机验证。**

## 能做什么

| 页面 | 用途 |
|---|---|
| 录制 | 选择仅 App 内、切出 App 后继续录屏、跨 App 采集，然后执行系统授权流程。 |
| 素材库 | 按日期、时间查看录制，分别播放视频、系统声音和麦克风声音，导出单个文件或整个 Session。 |
| 诊断与测试 | 检查启动条件、运行 App 内自检、导出启动报告和会话日志。正常录制不需要先运行自检。 |

应用没有服务器、登录账户、广告或自动上传。素材保存在设备上；分享由使用者主动操作。

## 分轨原理

ReplayKit 分别回调屏幕视频、`audioApp` 和 `audioMic`。AudioTrace 从采集开始就把两路音频分开写入 WAV，并记录原始 PTS 时间戳。按需生成的 MOV 保留视频与实际取得的独立 PCM 音轨。

这不是 AI 声源分离：不能把一条混音中的不同说话人拆开，也不能恢复系统未提供的音频。麦克风仍可能录到扬声器串音。

## 编译安装

本版本工程部署目标为 **iOS 26.0**，已在 **Xcode 26.2 / iOS 26.2 SDK** 下本地构建。没有第三方依赖，无需安装包管理器。

1. 下载或克隆源码，打开 `AudioTrace.xcodeproj`。
2. 编辑 `Configuration/Identifiers.xcconfig`：把 `AUDIOTRACE_BUNDLE_ID` 改成自己的唯一标识符，并填写 `AUDIOTRACE_TEAM`。App Group 会从 Bundle ID 派生。
3. 主 App 和 `AudioTraceBroadcast` 扩展使用同一 Team、自动签名，并为两者配置同一个已授权 App Group。需要在 Apple 开发配置中注册对应标识符。
4. 选择默认 **AudioTrace** Scheme，自行安装到 iPhone。三种录制范围均在 App 内选择。

```xcconfig
AUDIOTRACE_BUNDLE_ID = com.yourname.AudioTrace
AUDIOTRACE_APP_GROUP = group.$(AUDIOTRACE_BUNDLE_ID)
AUDIOTRACE_TEAM = YOUR_TEAM_ID
```

扩展 Bundle ID 自动追加 `.Broadcast`。不要只修改主 Target 的 Bundle ID，否则可能出现父子标识符不匹配。

默认 `AudioTrace` 与 `AudioTrace-SharedCapture` 都使用 SharedDebug/SharedRelease，包含广播配置；`AudioTrace-AppOnly` 使用不带 App Groups 的受限配置，只适合 App 内录制。

当前可构建的后台路径是 **ReplayKit Broadcast Upload Extension + App Groups**，不需要先升级到 iOS 27 SDK。源码另含条件编译隔离的 iOS 27 ScreenCaptureKit 备用实现，**尚未用 SDK 27 编译或真机验证**；不要将其视为已验证功能。

## 怎么录制

1. 进入“录制”，选择录制范围。“仅 App 内”在切到后台时会结束。
2. 如需切出 App，选“切出 App 后继续录屏”或“跨 App 采集”，通过启动条件检查。
3. 点击“准备系统屏幕广播”，再点击系统录屏按钮。在系统面板中选择 AudioTrace，按需开启麦克风，开始广播。
4. **等页面确认已收到真实视频帧后，再切换到主屏幕或其他 App。**
5. 返回 AudioTrace 或使用系统录屏指示器停止，等文件保存后进入“素材库”。

“切出后继续”和“跨 App”共用系统广播后端，代表不同使用意图。它们不会静默退回 App 内录制，也不会获得不同的系统权限。

素材库可分别播放、导出 MP4 和两路 WAV；“生成同步音视频”输出保留独立音轨的 MOV 和时间映射报告。派生成品不会覆盖原始媒体。WAV 紧凑保存实际样本，跨缺口同步要使用时间映射，不能假设所有文件从零同时播放就已同步。

## 常见问题

| 现象 | 检查方法与限制 |
|---|---|
| 当前模式尚未具备启动条件 | 确认用了默认 AudioTrace Scheme；检查主 App 与扩展的 Team、App Group 和 entitlement，导出启动诊断报告。 |
| Embedded binary 的 Bundle ID 前缀不匹配 | 在 xcconfig 统一修改 Bundle ID；扩展必须以主 App 标识符加点号开头，避免 Target 中残留单独覆盖。 |
| 切出 App 就停止 | 检查是否选择了“仅 App 内”；跨 App 要真正启动系统广播并收到视频，点击准备按钮本身不会开始录制。 |
| 授权后一直没有开始 | 约 45 秒未收到扩展 Session 会提示；检查系统面板是否选中 AudioTrace，以及扩展签名和共享容器。 |
| 系统声音或麦克风静音、缺失 | 取决于 iOS 实际提供的数据、系统麦克风开关和第三方 App 行为；通话、并发麦克风、DRM 等场景可能受限。未验证豆包兼容性。 |
| 锁屏、来电或强制结束后中断 | 不保证这些情况下继续录制；普通切到后台与强制结束进程是不同操作。 |
| 同步 MOV 无法生成 | 视频方向、音频格式或时钟 epoch 变化可能无法无损合并；保留并分别导出原始片段。 |
| 文件大或设备发热 | 录制和编码有资源开销。长边上限 1280、帧率上限 30 FPS；低存储、临界热或内存压力会请求停止。接近 4 GB 的 ZIP 请改为分文件导出。 |

更多限制见 [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md)，真机验收步骤见 [TEST_PLAN.md](TEST_PLAN.md)。

## 诊断与反馈

“诊断与测试”可以导出启动报告 `latest_preflight.json`；有会话时，可导出对应 Session 的诊断和媒体。日志区分无回调、真实静音、回调中断、写入失败和异常结束，并记录时间戳、计数与资源状态。

提 Issue 时请描述 iPhone/iOS、Xcode、录制范围、第三方 App 版本、系统麦克风开关、操作顺序和失败时间。**不要在公开 Issue 上传私人录屏、音频、完整设备标识或签名材料。**先检查报告内容，再附最小必要的日志。

## 本地验证

```sh
xcodebuild -project AudioTrace.xcodeproj -scheme AudioTrace \
  -destination 'generic/platform=iOS' \
  -derivedDataPath work/DerivedData CODE_SIGNING_ALLOWED=NO build

zsh Scripts/test_core.sh
```

已有测试覆盖独立 WAV 转换、H.264 写入、时间戳、方向和格式变化、锁、异常恢复、完整性及 ZIP CRC。另有针对旧格式 Session 的回归工具：

```sh
zsh Scripts/test_capture_flow.sh '/path/to/compatible-session.zip'
```

该工具针对 `in_app_self_test` 且以 `IN_APP_BACKGROUND_STOP` 结束、含视频及两路音频的旧格式会话，不适用于任意 ZIP。它只在 `work/` 复制输入后测试。私人录制样本和原始设备诊断不随开源仓库发布。

本地合成媒体与导出测试通过，不等于真实 iPhone 后台采集、第三方音频或长时间性能已通过验收。

## 代码结构

- `AudioTrace/`：录制控制、三页 UI、播放和导出。
- `BroadcastExtension/`：系统广播扩展入口。
- `Shared/`：音视频管线、存储、时间戳与诊断。
- `Configuration/`：Info、entitlement、隐私声明与标识符配置。
- `Tests/`、`Scripts/`：本地验证与项目生成工具。

## 许可证

[MIT](LICENSE)。欢迎反馈问题和提交改进。
