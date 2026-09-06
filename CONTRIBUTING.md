# 参与贡献

欢迎提交界面、模型兼容性、错误处理和文档改进。讨论想法请使用 [Discussions](https://github.com/Kamisato-Yuna/MLX-Gateway/discussions)，可复现问题请提交 Issue。

1. Fork 仓库，从 `main` 创建范围明确的分支。
2. 使用 Swift 6、macOS 26+、Apple Silicon 和 Xcode 27 构建。开发环境见 [README](README.md#build-and-run)。
3. 一次改动解决一个问题，保留已有安全措施；模型文件只读。主界面使用原生 SwiftUI 与系统材质。
4. 运行与改动相关的验证。服务或模型扫描改动运行 `./script/test.sh`；界面改动另记录真实点击步骤、预期和实际结果。fixture 不证明真实 MLX 推理。
5. 提交 Pull Request，说明动机、最终行为和验证结果。沟通与提交优先中文，也欢迎英文。不要附带模型权重、日志、凭据或个人配置。

本仓库采用 MIT；提交代码表示你有权按本项目许可证贡献该代码。第三方模型权重及 Python 依赖仍适用各自许可证。

维护者提交使用 GPG 签名。PR 默认采用 squash 合并，合并后删除远端分支；没有自动发布。正式分发应用前需另行完成 Developer ID 签名、公证与真实模型验证。

## 并发与测试

界面控制器隔离到 MainActor。后台网关与进程管理器沿用专用串行队列，跨线程值使用 Sendable；两个 `@unchecked Sendable` 类型的可变状态必须继续由现有队列/锁保护。不得用关闭 Swift 6 检查掩盖新增数据竞争。

测试不依赖维护者本机的模型。目录扫描测试在临时目录生成 config.json，生命周期测试启动独立 HTTP fixture。真实 MLX 验证是明确选择的 `--live` 模式，会顺序加载配置目录中的全部模型，请先确认内存和运行时间。

## 图标

`MLXGateway/Resources/Branding/AppIcon.icon` 是 Icon Composer 源文档，其 `Assets/` 中的 SVG 是可编辑图层。用 Icon Composer 检查默认、深色和单色外观，保存后通过 Xcode 编译。图标表达“本地芯片、统一网关、响应输出”，界面符号应保持这个语义。
