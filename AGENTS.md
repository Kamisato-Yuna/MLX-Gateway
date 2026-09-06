# AGENTS.md

## 协作与授权

- 主要使用中文沟通和提交，简洁说明修改、验证结果与未完成项。
- 在用户已授权的范围内完成工作，常规可逆选择自行判断，不重复请求批准；授权不自动扩展到推送、合并、正式发布、部署或破坏性清理。保留用户已有改动及认证、数据安全措施。
- 用户明确指令优先于技能指南；仅按需读取相关技能与 references。若文件规则导致暂停，指出文件位置、原文和适用原因，不把建议推断为额外审批要求。

## 项目边界

- 本仓库是 MLX Gateway，一个本机 `mlx_lm` / `mlx_vlm` 出口管理器，不是任何单一客户端的专用工具。
- 默认 gateway 为 `127.0.0.1:44110`，默认 downstream model 为 `127.0.0.1:44100`，两者必须保持可配置。
- 同一时刻只运行一个下游模型服务。由用户在界面选择并启动模型，切换时先停止旧 backend，再启动目标模型；API 请求不得自动启动或切换模型。
- 模型文件只从用户在设置中指定的目录只读扫描或读取；禁止修改模型目录。模型列表以 config.json 扫描结果为准，不内置维护者本机模型。
- 不要把本机绝对模型路径写入公共协议响应。路径只允许存在于本地配置或进程启动实现中。

## 开发规则

- 如果仓库根目录存在 `.codegraph/`，理解或定位代码时先用 CodeGraph，再用 `rg` 等工具补充。
- 使用 Xcode 27 beta 6 构建，仅支持 arm64，使用 Swift 6 语言模式。界面采用原生 Liquid Glass，优先使用系统侧栏、工具栏和 glass 控件，避免重型仪表盘和不必要的 opaque 背景。
- 对外推理使用 OpenAI Responses，支持已实现的渐进 SSE、函数调用及结果回传、进程内存会话与后台任务；VLM 可接受图片及内联 PDF，文本文件通过内联数据提供。Chat Completions 仅作为内部 MLX 传输，Anthropic 与公开 Chat 路由均返回 404。所有能力以实际后端实现为准；音频、云托管工具、任意本机文件路径和未实现参数必须明确报错，不能静默丢弃或伪造支持。模型能力列表与文档须反映实际开放能力。

## 验证

- 测试只覆盖本轮改动；纯文档修改检查差异、链接与示例，不启动模型或运行构建。相关检查通过后，仅在新增改动、失败或未解决疑点需要时扩大或重复验证。
- 修改协议层后验证 Responses 输入/输出、受影响的成功与错误分支，以及已移除路由返回 404。修改生命周期后验证手动启停、模型切换、异常退出、日志和推理中停止；`./script/test.sh` 使用隔离 HTTP fixture，不证明真实 MLX 推理。真实模型验收单独记录。
- `./script/build_and_run.sh --verify` 会正常退出并重启应用，检查 Debug 构建、arm64、签名 Authority、进程和默认地址的 `/health`。只有界面启动操作会启动或切换下游模型。运行前确认影响属于已授权范围；健康检查或 fixture 不能代替真实推理与客户端验收，未完成项如实报告。

## 构建、签名与提交

- 本机维护者 Debug 构建使用 `Apple Development: Yuna Kamisato (RHMMQ36XSM)` / Team `852H844JG2`（证书 OU；括号中的 RHMMQ36XSM 是个人标识）。外部贡献者可通过 `MLX_GATEWAY_TEAM` / `MLX_GATEWAY_SIGN_IDENTITY` 指定自己的开发身份；必须由 Xcode 在最终资源处理后签名，并通过严格校验。
- 构建运行入口为 `./script/build_and_run.sh`，参数与示例见 [README](README.md#build-and-run)。
- 每次提交必须 GPG 签名，仓库本地配置必须保留：
  - `commit.gpgsign=true`
  - `user.signingkey=AB9C8A18647A9F8D`
  - `user.email=35021748+Kamisato-Yuna@users.noreply.github.com`
  - `user.name=潮汐予梦@Kamisato-Yuna`
- 禁止提交 `build/`、`DerivedData/`、`logs/`、`*.pid`、`*.dSYM`、secret 或本地运行产物。
