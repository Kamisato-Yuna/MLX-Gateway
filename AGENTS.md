# AGENTS.md

## 项目边界

- 本仓库是 MLX Gateway，一个本机 `mlx_lm` / `mlx_vlm` 出口管理器，不是任何单一客户端的专用工具。
- 默认 gateway 为 `127.0.0.1:44110`，默认 downstream model 为 `127.0.0.1:44100`，两者必须保持可配置。
- 第一版采用 single active backend：同一时刻只运行一个下游模型服务，切换模型时先停止旧 backend，再启动目标模型。
- 模型文件只从 `/Users/yuna/LLM-Local/qwen36-mlx-vlm/models` 只读核对或读取；不要修改该目录。
- 不要把本机绝对模型路径写入公共协议响应。路径只允许存在于本地配置或进程启动实现中。

## 开发规则

- 如果仓库根目录存在 `.codegraph/`，理解或定位代码时先用 CodeGraph，再用 `rg` 等工具补充。
- 修改 SwiftUI UI 时遵守 macOS 26 原生风格：系统控件和 material 优先，避免重型仪表盘和不必要的 opaque 背景。
- 修改协议层后分别验证 OpenAI Chat、OpenAI Responses、Anthropic Messages。
- `stream`、`tools` / `tool_choice`、未实现的 vision 输入必须返回明确 unsupported JSON error。
- Anthropic `/v1/messages` 普通文本请求转为 OpenAI Chat；Anthropic tool use 第一版不支持。

## 构建、签名与提交

- Debug 构建使用 `Apple Development: Yuna Kamisato (RHMMQ36XSM)` / Team `RHMMQ36XSM`。
- 推荐入口是 `./script/build_and_run.sh`，验收入口是 `./script/build_and_run.sh --verify`。
- 每次提交必须 GPG 签名，仓库本地配置必须保留：
  - `commit.gpgsign=true`
  - `user.signingkey=AB9C8A18647A9F8D`
  - `user.email=35021748+Kamisato-Yuna@users.noreply.github.com`
  - `user.name=潮汐予梦@Kamisato-Yuna`
- 禁止提交 `build/`、`DerivedData/`、`logs/`、`*.pid`、`*.dSYM`、secret 或本地运行产物。
