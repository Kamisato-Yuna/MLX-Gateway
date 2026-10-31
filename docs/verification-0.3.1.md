# 0.3.1 验证记录

日期：2026-10-31。应用版本 `0.3.1`，build `4`。环境为 Apple Silicon、Xcode 27.2、Swift 6，最低 macOS 26。

## 代码

提交 `efc38f77afb10a7923c0bb901213130bcb77dcc0` 已推送到 `main`，并带有 GPG 签名。标签 `v0.3.1` 指向该提交，同样已签名。本版本包含分开的输入/输出限制，以及启动本地进程时移除外部 `PYTHONPATH` 和 `PYTHONHOME`。模型固有窗口上限不在本版本。

隔离测试 `./script/test.sh` 通过，共 261 项协议与服务检查。这些测试不加载真实模型。

## 签名、公证和压缩包

Release 由 Xcode 构建，架构为 arm64，使用 Developer ID Application / Team `852H844JG2`。Hardened Runtime 已启用，签名包含安全时间戳，不包含 `get-task-allow`。

Apple 公证提交 `21452998-f618-4eef-b543-90076792177d` 返回 `Accepted`。应用已附加公证票据。`stapler validate`、严格嵌套签名和 Gatekeeper 检查通过，来源为 `Notarized Developer ID`。

最终 ZIP 在附加票据后用 `ditto --sequesterRsrc` 生成。应用自身的 `--verify-archive` 返回 `VERIFIED`。解压副本再次通过 `stapler validate` 和 Gatekeeper。产物名为 `MLXGateway-0.3.1-macos-arm64.zip`，SHA-256 为 `31a49208fa197462aa2306fbb619369e2657f6b19425bf5e2d0658287c3cf2ab`。

## 发布

[0.3.1 Release](https://github.com/Kamisato-Yuna/MLX-Gateway/releases/tag/v0.3.1) 已公开，不是草稿，也不是预发布。下载副本与本地发布包逐字节一致。本轮没有把公证包安装到正在使用的应用位置，也没有重复 0.3.0 的真实音频转写验收。
