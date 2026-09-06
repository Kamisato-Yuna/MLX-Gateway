# 0.2.0 验证记录

验证日期：2026-09-06。环境为 Apple Silicon、macOS 27 预览版、Xcode 27 beta 6（27A5252f），Swift 6；最低部署版本 macOS 26。仅覆盖本轮日志、Responses、测试面板、性能统计和更新改动。

真实模型环境：MLX 0.32.2、mlx-lm 0.31.3、mlx-vlm 0.6.17、llguidance 1.8.0，OpenAI Python SDK 3.8.0。

## 客户端与真实模型

本地 Debug 构建通过，`script/build_and_run.sh --verify` 通过 arm64、Apple Development 严格签名、进程和 `/health` 检查。GUI 实际操作验证了日志级别颜色、搜索命中高亮、清理确认与取消、面板切换保留草稿、真实 SSE 请求、资源曲线和两轮性能测试。日志截断后继续追加且不产生空洞，由独立后端测试验证；界面验收没有清空用户已有日志。

手动启动 `Qwen3.6-35B-A3B-4bit`（MLX VLM）后，真实请求通过：

| 项目 | 结果 |
| --- | --- |
| 非流式与流式文本 | 返回有效 Responses 输出 |
| 渐进 SSE | 首段文本约 0.11 秒、终止约 1.79 秒，共 121 个事件；内容在终止前持续到达 |
| 会话续接 | `previous_response_id` 使用前轮历史成功 |
| 函数工具 | 指定 `get_weather` 返回调用，客户端提交测试结果后完成续接 |
| JSON Schema | 使用 VLM 后端约束解码，返回符合简单 schema 的对象 |
| 内联文本文件 | 正确读取 UTF-8 文件中的词语 |
| 图像 | 标准 64×64 RGB PNG 被正确识别为四个色块 |
| 内联 PDF | 文字和渲染页面共同提交，返回页面中的 `Hello` |
| 不支持的音频 | 返回明确 HTTP 400，未静默忽略 |

图像验收发现最初预置 PNG 可以读取尺寸但像素解码失败。预置已替换，测试现在通过 Core Graphics 实际绘制并核对像素，也用运行环境 Pillow `Image.load()` 验证完整解码；旧损坏样例作为负例保留。

停止 VLM 后，隔离测试主机手动切换至 `Qwen3-Coder-30B-A3B-Instruct-4bit`（MLX LM）。严格 SDK 的文本、会话续接、渐进流式、具名函数调用及结果回传、内联文本文件全部通过；LM 的 JSON 约束和图片请求明确返回 HTTP 400。测试结束后正常停止并释放模型。

性能面板显示真实 MLX 主进程 CPU、驻留内存和物理占用。短响应预置实际完成一轮预热和两轮测量；两轮平均约 0.30 秒。以上数值仅是该次设备、模型、缓存与提示词条件下的观测，不构成跨设备性能承诺。TTFT 只记录真实流式内容；非流式不伪造该指标。

## 自动化验证与协议范围

独立测试主机在 44319 / 44320 端口手动加载同一 VLM，OpenAI SDK 使用 `_strict_response_validation=True` 完成 31 项真实检查：非流式、续接、查询、分页、删除 8 项；文本流 4 项；函数调用、结果回传和工具流 10 项；后台任务、取消及 `starting_after` 续流 9 项，全部通过。另用 SDK 严格验证 5 类输入项和 17 个事件，修复发现的 usage 与输入项 schema 默认值缺失。

缓存和推理等 usage 明细优先保留下游实值，后端缺失时使用 SDK 所需的兼容默认值 0；这类默认值不是实测计数，`/status` 也明确说明该限制。

`script/test.sh` 通过 151 项检查，使用隔离后端验证 Responses 输入转换、LM/VLM 能力差异、渐进 SSE 与顺序、工具参数增量、推理文本、存储与分页、后台任务与取消、手动模型生命周期、日志截断和请求统计。临时 fixture 不证明真实模型推理质量。

`script/test-responses-playground.sh` 验证 JSON 原样传输、SSE 边界、请求与工具续接、预置、项目存储、脱敏和图像解码。`script/test_performance.sh` 验证单调时间、重复结束回调、并发记录与容量、分位数、PID 重用，以及对测试进程实际读取系统资源。

公开能力以 [README 能力表](../README.md#接口) 为准。网关不执行任意函数或云托管工具；函数 `strict=true`、音频、任意文件路径与 `file_id`/`file_url` 等未实现能力明确报错。会话驻留进程内存，重启清空。断开 HTTP 会取消网关请求；底层 GPU 计算能否立即停止取决于 MLX 后端。

## 发布与自动更新

Release 构建通过。产物为 `MLXGateway-0.2.0-macos-arm64.zip`，包内版本 0.2.0、build 2；使用 Developer ID Application / Team `852H844JG2` 签名，启用 Hardened Runtime 和安全时间戳，arm64 与严格嵌套签名检查通过。

更新测试通过真实 DEFLATE 大小篡改、下载与实际展开限额、路径穿越／链接／特殊文件、取消竞态、AppleDouble 属性恢复，以及替换／启动／恢复失败路径。

在独立临时目录构造同团队签名的 0.1.0 应用副本，实际运行签名客户端的更新 helper。收到 `READY` 后让旧进程正常退出，helper 返回 0，包内版本变为 0.2.0；新版进程确实重启、严格签名通过，`/status` 正常且模型保持停止。演练没有替换用户安装的应用。测试脚本最初未归一化 `/var` 与 `/private/var`，误报未启动；依据实际进程路径修正后通过。

Apple 公证与 Gatekeeper 分发验收尚未完成；当前安装包仅已完成 Developer ID 签名。正式分发状态以对应 Release 说明为准。桌面锁屏期间只完成命令行安装与进程验证，没有把它记为更新按钮的 GUI 点击验收。
