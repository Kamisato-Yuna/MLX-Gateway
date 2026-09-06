# 应用更新

默认从 GitHub Release 检查稳定版本：
`https://api.github.com/repos/Kamisato-Yuna/MLX-Gateway/releases/latest`。
可切换到 Pages，默认地址为
`https://kamisato-yuna.github.io/MLX-Gateway/update.json`，也可保存自定义 HTTPS 地址。
源设置保存后才生效；下载、校验和安装期间不允许在界面切源。

```json
{
  "version": "v0.2.0",
  "title": "MLX Gateway 0.2.0",
  "notes": "更新说明",
  "download_url": "https://github.com/Kamisato-Yuna/MLX-Gateway/releases/download/v0.2.0/MLXGateway-0.2.0-macos-arm64.zip",
  "asset_name": "MLXGateway-0.2.0-macos-arm64.zip"
}
```

下载与 manifest 请求均检查 HTTP 状态，并拒绝任何 HTTPS 到 HTTP 的重定向。
ZIP 下载累计字节不超过 1 GiB；manifest 不超过 2 MiB，即使没有 Content-Length 也会限制。
每次请求拥有独立 URLSession，成功、错误、取消都会结束会话并清理失败的临时文件。
用户可取消下载和校验，之前操作的回调不会覆盖新操作状态。

ZIP 由 macOS 自带 libarchive 逐块读取，累计实际产出最多 2 GiB；不信任 ZIP 声明大小。
中央目录检查原始路径及文件类型，解码时再次检查路径、链接和类型。
拒绝路径穿越、绝对路径、反斜杠、控制字符、符号链接、硬链接、特殊文件、重复普通文件
及点路径别名。当前支持 UTF-8 文件名、单卷 ZIP，中央目录最多 65,534 项；不支持 ZIP64
中央目录。安装包应只包含一个 `.app`。AppleDouble 文件也计入解压预算后才恢复 xattr，
以保留 ditto 打包的 macOS 元数据。客户端不需要用户安装 Python、Swift 或第三方工具。

下载完成后先在临时目录解压并验证 bundle identifier、语义版本、arm64 主程序、严格嵌套
代码签名、Apple 信任链以及与当前应用相同的 TeamIdentifier。
`v0.2.0` 与 `0.2.0` 等价；预发布版本及 build metadata 比较使用同一份 Swift 实现。

点击“安装并重启”会启动签名客户端自身的 helper 模式。helper 在目标应用的父目录
建立独立暂存目录，重新受限解压并完成全部验证后输出 `READY`；GUI 收到后才正常退出。
准备失败会直接留在当前界面显示错误。helper 最多等待旧进程 60 秒，然后在同一卷上
把旧应用重命名到暂存目录的 `previous.app`，再把新应用重命名到原位置。
替换或启动命令失败时恢复旧应用；恢复失败时保留旧包并记录其路径，绝不嵌套移动到
半成品目录。成功后也保留 `previous.app` 供人工恢复。

退出之后发生的失败写入
`~/Library/Application Support/MLXGateway/update-failure.log`，并尝试重启恢复后的应用。
下次启动会显示该结果；自动检查不会覆盖它，用户主动检查或重试后才清除。
`open -n` 成功只证明系统接受启动请求，不能检测启动后的崩溃，也不替代真实客户端验收。

## 维护者验证入口

工程在创建 SwiftUI App 或任何控制器之前分派 `--mlx-gateway-update-helper`。
新 Swift 源须加入应用 target。libarchive 从固定系统路径动态载入，无额外链接参数。
`script/package_update.sh` 仅保留维护者兼容入口，不再复制到 Bundle。

仅受限解压并验签，保留结果供 `codesign`、`stapler`、`spctl` 检查；输出目录必须不存在：

```sh
HELPER_APP/Contents/MacOS/MLXGateway --mlx-gateway-update-helper \
  --verify-archive ARCHIVE CURRENT_SIGNED_APP BUNDLE_ID VERSION NEW_OUTPUT_DIRECTORY
```

成功返回 0，并输出 `VERIFIED:实际应用路径`；失败返回非零并清理本次创建的输出目录。
此模式不启动或停止应用。

安装调用（只对明确授权的目标使用）：

```sh
HELPER_APP/Contents/MacOS/MLXGateway --mlx-gateway-update-helper \
  --install ARCHIVE TARGET_APP BUNDLE_ID CURRENT_VERSION VERSION TEAM_ID PID FAILURE_LOG
```

将 stdout 重定向到单独日志，观察完整的一行 `READY` 后，才允许指定 PID 正常退出。
此前若输出 `ERROR:...` 或 helper 退出，目标应用尚未替换。
`TARGET_APP` 必须是版本为 `CURRENT_VERSION` 的真实 Apple 签名应用；隔离演练可使用
同团队签名的旧版本 fixture 与独立占位进程 PID，勿填写正在使用的 GUI PID。
helper 退出码 0 表示替换成功且系统接受启动请求，非零表示失败。

## 本轮验证

`./script/test_updates.sh` 使用隔离临时文件和 URLProtocol fixture，覆盖：

- 版本前缀、预发布数字顺序、build metadata；
- ZIP 路径穿越、符号链接、FIFO、重复条目、AppleDouble 路径和 xattr 恢复；
- 缺 Unix 类型位的普通文件、伪造大小的真实 DEFLATE 流、跨文件累计产出上限；
- HTTP 403/404、已知和未知长度超限、HTTP 降级重定向拒绝；
- 开始前取消、下载中取消、后续下载、控制器迟到回调与失败显示；
- 替换失败、启动失败、恢复失败时旧包保留，以及 helper 准备错误。

这些测试不启动 GUI 或模型，不证明正式发布、公证票据或实际升级验收。
真实签名包还需由发行任务验证解压后签名、公证票据、Gatekeeper、隔离安装及重启。
