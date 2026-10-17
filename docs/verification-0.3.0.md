# 0.3.0 验证记录

日期：2026-10-17。应用版本 `0.3.0`，build `3`。环境为 Apple Silicon、Xcode 27.1、Swift 6，最低 macOS 26。

## 代码与构建

当前工作区原本位于 `main`，没有独立业务分支或附加工作树。将已验收的音频、图像、媒体配置、Responses 兼容及常驻设置改动整合到 `main`。Dependabot PR 不在本次范围。

Release 由 Xcode 构建和签名，架构为 arm64，使用 Developer ID Application / Team `852H844JG2`。Hardened Runtime 已启用，不包含 `get-task-allow`。首次公证报告缺少安全时间戳；Release 配置已显式加入 `--timestamp`，重新构建后检查到安全时间戳。

## 隔离验证

- 231 项 Responses、媒体和 multipart 音频协议检查通过。
- 音频控制器的连接、加载、卸载、配置与错误处理检查通过。
- 图像服务的配置、启停、参数、PNG、路由及路径脱敏检查通过。
- 性能采样、Responses Playground 和更新器测试通过。
- 19 项 Python 服务管理与恢复测试通过；这些测试已加入 CI。

隔离测试不加载真实模型，不代替客户端验收。

## 实际服务与界面

音频页已使用原生文件选择器选中测试 WAV，转写文字正确显示。取消选择及页面往返均未新增提交，自动化通道保持正常。FChat 容器的同一测试音频返回 HTTP 200 和正确 WebVTT。恢复演练、请求次数及界面证据见 [常驻服务维护](local-service-operations.md)。

图像服务已完成代码与隔离验证；此前实际模型因可用内存不足而拒绝加载，尚无真实 PNG。该限制见 [图像接入记录](verification-images-2026-10-17.md)，不将图像模拟输出记为真实出图。

常驻配置是本机部署选项，不会为新用户自动安装或开启。该模式的维护更新按 [更新常驻应用](local-service-operations.md#更新常驻应用) 操作，避免与 launchd 保活同时替换应用。发布不包含模型权重、Python 环境、个人配置或凭据。

## 签名、公证和压缩包

修正后的 Apple 提交 `3e891604-ff39-4676-8db5-61b642dea3c6` 返回 `Accepted`。应用已附加公证票据，`stapler validate` 和严格嵌套签名检查通过。Gatekeeper 结果为 `accepted`，来源为 `Notarized Developer ID`。

最终 ZIP 在附加票据后生成。使用应用自身的 `--verify-archive` 模式，验证压缩包布局、应用身份、版本、arm64 和 Apple 同团队签名，结果为 `VERIFIED`。产物名为 `MLXGateway-0.3.0-macos-arm64.zip`。

已将同一公证 Release 安装到现有常驻应用位置。安装后 Gateway 和 Whisper 均就绪，FChat 主容器再次上传中文 WAV，得到 HTTP 200 和正确 WebVTT。逐项比对确认两个 LaunchAgent 的全部字段、音频配置、运行与模型目录、Python、监听主机和端口均不变。

## CI 与实际 Release 验收

恢复测试统一使用 `/usr/bin/python3`，与协议测试的系统解释器一致。托管环境的默认解释器曾出现 fixture 子进程存活但未监听的现象；改用系统解释器后，19 项测试约 6 秒通过。保留实际监听 PID 和 fixture 启动诊断，未放宽正式服务检查。

完整 [GitHub CI](https://github.com/Kamisato-Yuna/MLX-Gateway/actions/runs/39019728237) 已通过：恢复、协议、客户端/更新测试及 Release 编译全部成功。CI 仅编译，不发布或公证应用。

已安装的公证 Release 另完成原生文件选择与中文转写，结果正确。FChat 容器转写也返回 HTTP 200，配置与发布前逐项一致。

[0.3.0 Release](https://github.com/Kamisato-Yuna/MLX-Gateway/releases/tag/v0.3.0) 已公开。最终下载 ZIP 与本地发布包逐字节一致，下载副本的更新校验、公证票据和 Gatekeeper 检查另行记录。版本标签在草稿阶段对齐 CI 通过的提交，应用与运行脚本未在该阶段改变。
