# 验证记录 · 1.1 (3)

更新日期：2026-10-17。

## 开源副本

- 从 AudioTrace 3（1.1，Build 3）提取；Swift 源码、测试与脚本保持一致。
- 个人 Team 改为可配置变量，Bundle ID 改为示例值；使用者必须自行配置签名。
- 默认 AudioTrace Scheme 仍为 SharedDebug，包含广播与 App Groups entitlement。
- 在 Xcode 26.2 / iOS 26.2 SDK 下，对 generic/platform=iOS 目标执行无签名构建：**BUILD SUCCEEDED**。
- 不连接手机、不安装到手机；原始构建日志、本机账户信息、私人媒体与设备报告不公开。

## 同版源码已有本地测试

- 合成 CoreMedia 样本：独立 WAV、H.264、时间戳、格式和方向变化、文件锁、异常恢复、流式 ZIP，通过。
- 独立 Python 校验：ZIP CRC、PCM16 WAV、JSONL 与精确采样偏移，通过。
- 非公开旧格式 Session 副本：单视频加两路独立 PCM MOV、时间原点、视频 edit 映射、重复导出、原媒体 SHA256 保持不变，通过。该私人样本不随仓库发布。
- 请求握手、录制范围、后台确认必须有新视频帧，以及缺少全屏能力时不回退到 App 内录制的合成测试，通过。

## 尚未验收

- 真机普通前后台切换、长时间连续录制及扩展实际资源占用。
- 豆包等第三方 App 的系统音频、并发麦克风和实时视觉通话。
- 锁屏、来电、强制结束或系统回收后的行为。
- 条件隔离的 iOS 27 ScreenCaptureKit 备用实现，没有 SDK 27 编译或真机通过结论。

合成测试不代表真实跨 App 捕获已通过。更多步骤见 TEST_PLAN.md。
