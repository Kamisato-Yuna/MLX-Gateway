# 本机 Gateway 与 Whisper 常驻服务

配置日期：2026-10-17。此配置服务于本机 FChat 的 Whisper 转写。

## 退出调查

macOS 统一日志显示，Gateway 的旧进程 PID 37428 在 **2026-10-17 14:40:05 +08:00** 收到正常退出请求，并完成 AppKit 退出流程。关键记录为：

- `applicationShouldTerminate: NSTerminateNow`
- `App termination approved`
- `Termination complete. Exiting without sudden termination.`

未发现对应崩溃报告，也未发现当天相关的 Jetsam 内存终止报告。现有日志不能确定退出请求来自菜单、快捷键还是外部终止信号。因此，不能将此事认定为崩溃或内存不足。此前没有启动或保活任务，正常退出后也不会恢复，导致端口 44110 持续不可用。

原始日志保存在本地 `build/service-investigation/previous-exit.json`。关键摘录另存于运行目录的 `audio-service/acceptance/launchd-20261017/exit-summary.json`。原始日志未加入 Git。

## 当前部署

| 项目 | 配置 |
| --- | --- |
| Gateway 应用 | `/Users/yuna/Applications/MLXGateway.app` |
| Gateway 任务 | `dev.kamisato-yuna.MLXGateway.service` |
| Whisper 任务 | `dev.kamisato-yuna.MLXGateway.whisper` |
| LaunchAgent 目录 | `/Users/yuna/Library/LaunchAgents/` |
| 守护程序 | `/Users/yuna/Library/Application Support/MLXGateway/service/whisper_supervisor.py` |
| 日志目录 | `/Users/yuna/Library/Logs/MLXGateway/services/` |
| Gateway 监听 | `127.0.0.1:44110` |
| Whisper 监听 | `127.0.0.1:44120` |
| 对外模型 ID | `whisper-1` |
| 实际模型 | 原有 `mlx-community/whisper-large-v3-turbo` |

应用从已通过开发签名校验的本地构建复制到稳定目录。本次设置界面更新已重新构建并签名；原有模型、端口、FChat 配置和监听范围不变。后续清理构建目录不会删除常驻应用。

两个任务使用 `RunAtLoad=true`、`KeepAlive=true` 和 5 秒启动节流。登录图形会话后自动启动；正常退出和异常退出都会被重新拉起。Gateway 与 Whisper 分别恢复，一个进程退出不会主动停止另一个。

Whisper 守护程序每次启动后加载配置中的模型。它每 30 秒检查模型状态。模型丢失时重新加载；连续 3 次健康检查失败时结束自己管理的后端，由 launchd 重启。API 请求本身仍不启动服务、不加载模型。守护进程异常退出时，launchd 会清理同一进程组，避免旧后端残留并占用端口。

此方案是**用户登录后自启**。未配置系统级登录前服务，未改变 FileVault、电源或休眠设置。尚未重启整机验证首次登录，当前会话的任务加载及异常恢复已验证。

## 查看、停止与恢复

优先使用应用内的 **设置 → 常驻服务**：

- **登录后自动启动 Gateway 和 Whisper**：设置两个已有任务的登录启动策略。
- **退出后自动恢复**：设置 launchd 保活。该功能要求开启登录自启；正常退出应用也会恢复。
- **保存常驻配置**：写入配置。运行中的服务会短暂重启；停止中的服务保持停止。
- **实际运行状态**：分别显示任务安装状态、进程 PID、启动次数、最近退出结果和配置。HTTP 可用与 Whisper 模型就绪另行检测，不把进程存在当成转写可用。
- **停止服务**：停止 Gateway 和 Whisper，保留自启配置。应用重开控制窗口，该窗口不监听端口。
- **启动服务 / 重启服务**：由独立的一次性助手交接任务，完成后重开常驻设置页。登录自启关闭时，也可手动启动。
- **刷新 / 打开日志**：立即刷新状态，或在 Finder 打开服务日志目录。页面打开时每 2 秒自动刷新。

启停和保存运行中的配置会中断请求。Gateway 自己启动的其他模型进程也会随应用退出，模型配置和文件不会修改。自动恢复开启时，直接退出应用不能持续停服；请使用设置中的“停止服务”。再次登录仍会按保存的自启配置启动。需要下次登录也保持停止，先关闭登录自启并保存，再停止服务。

服务助手随签名应用打包，不依赖仓库源码路径。维护任务 `dev.kamisato-yuna.MLXGateway.maintenance` 使用 `RunAtLoad=true`、`KeepAlive=false`，配置文件在应用支持目录，不放入登录 LaunchAgents 目录。操作结果保存在同目录的 `last-operation.json`；失败可从控制窗口检查并重试。

查看任务状态：

```bash
/Users/yuna/LLM-Local/mlx-local-runtime/.venv/bin/python \
  /Users/yuna/LLM-Local/MLX-Gateway/script/service_manager.py status
```

需要维护时，先停用两个任务。此操作也禁止下一次登录时自动启动，直到执行 `start`：

```bash
/Users/yuna/LLM-Local/mlx-local-runtime/.venv/bin/python \
  /Users/yuna/LLM-Local/MLX-Gateway/script/service_manager.py stop
```

按保存的 `RunAtLoad` / `KeepAlive` 配置恢复运行；默认安装配置会重新启用登录自启。如果此前在界面关闭了自启，此命令只手动启动：

```bash
/Users/yuna/LLM-Local/mlx-local-runtime/.venv/bin/python \
  /Users/yuna/LLM-Local/MLX-Gateway/script/service_manager.py start
```

常驻模式下，仅在音频界面卸载 Whisper 模型，也会在下一轮健康检查后重新加载。需要停服时，使用常驻设置页或上述 `stop` 命令。

## 更新常驻应用

构建目录与常驻应用相互独立。构建本身不更新常驻副本。维护时先执行 `stop`，再使用仓库的构建脚本，最后安装新副本：

```bash
cd /Users/yuna/LLM-Local/MLX-Gateway
./script/build_and_run.sh --build
/Users/yuna/LLM-Local/mlx-local-runtime/.venv/bin/python \
  script/service_manager.py install
```

安装程序先复制并验证签名，再接管旧进程。已有常驻副本和任务配置会备份到 `~/Library/Application Support/MLXGateway/service/backups/`。不要在常驻任务运行时执行会结束应用的开发命令；先进入维护状态，以免与自动恢复互相干扰。

## 实际验证

2026-10-17 完成以下演练。恢复时间是从发送退出信号到 Gateway 健康检查通过、Whisper 报告原模型已加载的实测值，不是服务时限承诺。

| 强制退出目标 | 恢复时间 | 恢复后 FChat 容器转写 |
| --- | --- | --- |
| Gateway | 0.394 秒 | HTTP 200，WebVTT |
| Whisper 后端 | 4.164 秒 | HTTP 200，WebVTT |
| Whisper 守护程序 | 3.361 秒 | HTTP 200，WebVTT |
| Gateway 正常退出（SIGTERM） | 0.226 秒 | HTTP 200，WebVTT |

每次均从 `fchat-local-mattermost-1` 上传原有中文合成 WAV。字幕时间轴保持 `00:00:00.000 --> 00:00:05.660`，文本为“你好,这是一条语音转写测试,请把这段话转换成文字。”。本地证据位于运行目录的 `audio-service/acceptance/launchd-20261017/recovery-results.json` 和同目录 VTT 文件。正常退出演练另验证了与原故障相同的退出方式也会自动恢复。

5 项隔离测试另外验证了预加载、丢失模型恢复、子进程崩溃、正常停用及无响应后端回收。真实演练证明进程恢复与容器转写链路可用，不代替 FChat 消息和界面验收。

## 常驻设置界面验收

2026-10-17 已在 `/Users/yuna/Applications/MLXGateway.app` 的实际原生窗口操作，未用模拟页面代替：

| 操作 | 实际结果 |
| --- | --- |
| 打开设置并选择“常驻服务” | 显示原有 Gateway 与 Whisper 任务、PID、两项开关、HTTP 状态和 `whisper-1` 就绪状态 |
| 关闭自动恢复并保存 | 窗口重开，两任务恢复运行，`KeepAlive=false` |
| 关闭登录自启并保存 | 两任务仍可运行，`RunAtLoad=false`，launchd 禁用状态已读回 |
| 在自启关闭时停止，再启动 | 停止后没有两个端口的监听者；控制窗口可重新启动，仍保持自启关闭 |
| 恢复两个开关并保存 | 两任务配置恢复开启，服务与原模型就绪 |
| 自动恢复开启时重启、停止、再启动 | 操作完成；主动停止不会被保活重新拉起；启动后恢复服务 |
| 停止中修改并保存恢复开关 | 配置保存，服务保持停止；随后恢复原配置 |
| 点击“打开日志” | Finder 打开正确的 `Library/Logs/MLXGateway/services` 目录，显示六个服务日志文件 |
| 强制结束 Whisper 守护进程 | launchd 自动恢复；界面显示新 PID、启动次数 2、最近退出 `Killed: 9`，随后模型恢复就绪 |
| 转写进行中点击停止 | FChat 容器请求结束，curl 报空响应；停止不等待客户端超时 |
| 最终恢复后从 FChat 主容器转写 | `POST /v1/audio/transcriptions` 返回 HTTP 200、`text/vtt` 和原有中文测试字幕 |

界面测试修复了两项交接问题：等待旧 launchd 任务完全卸载后再启动；使用明确的单次维护任务，避免维护助手重复运行。设置弹窗也会在退出交接前关闭。

以下是修复前的记录：强制结束守护进程后，新进程短暂读到了旧后端的模型列表；旧后端退出后，一次即时请求返回 502。30 秒健康检查随后重新加载模型，约在新后端启动后 34.7 秒恢复就绪。此问题已在后续修复，见下一节。异常退出期间仍不能保证所有请求成功。

7 项服务管理测试覆盖配置保留、开关依赖、状态解析、关闭自启时手动启动、任务停止顺序、进程归属检查及单次维护任务。签名构建和实际界面操作另外验证。界面测试数据位于运行目录 `audio-service/acceptance/settings-ui-20261017/`，不加入 Git。整机重启和首次登录仍未实测。

## 异常恢复时序修复与复验

2026-10-17 后续版本修复了旧监听者尚未退出时误报就绪的问题。新守护先等待原端口释放，不停止占用该端口的其他进程。启动后，它用系统监听信息确认该端口由当前子进程持有，再读取模型列表。读取后再次确认进程归属，避免读取过程中发生更换。启动预加载不再依赖下一轮 30 秒巡检。

常驻设置页也会在模型探测前后检查监听进程的父进程是否为当前 launchd Whisper 守护。旧孤儿进程、尚未监听的新进程和未完成模型加载的服务都不能使该页显示就绪。后台自动巡检间隔仍为 30 秒。

`mlx-audio` 加载模型时会暂时阻塞 HTTP 处理。该阶段先将转写请求的只读 `/models` 单次探测上限从 3 秒改为 8 秒，后续已改为下面的有界等待。界面探测仍保持较短超时。请求不执行启动或加载操作，也不自动重发转写 POST；POST 已提交后发生的连接中断仍明确返回错误。

最终签名版本完成三轮真实异常演练。计时起点为发送 SIGKILL；模型就绪要求**新的守护与后端 PID**、监听归属和模型列表同时成立。FChat 主容器每轮连续上传原有中文测试 WAV，返回内容均校验为真实 WebVTT。

| 故障目标 | 新模型就绪 | 恢复后首个 FChat HTTP 200 完成 | 故障期间 502 / 503 | 随后成功转写 |
| --- | --- | --- | --- | --- |
| 守护进程，第 1 轮 | 4.549 秒 | 4.976 秒 | 1 / 0 | 连续 3 次 |
| 守护进程，第 2 轮 | 4.688 秒 | 5.246 秒 | 1 / 1 | 连续 3 次 |
| Whisper 后端 | 3.976 秒 | 4.578 秒 | 1 / 1 | 连续 3 次 |

相比此前约 35 秒，本轮模型恢复缩短到约 4–5 秒。正在等待模型加载的请求可在恢复后完成；每轮强退瞬间仍出现一次 502，不能视为零中断或恢复时限承诺。表中的计数只对应本轮串行探测请求，不代表所有客户端流量。

实际设置窗口已验证：恢复中显示未就绪，恢复后显示新 PID、启动次数增加、最近退出原因和 `whisper-1 · 已就绪`。页面刷新及手动重启也已实测。启动时请求显示设置的动作移到主窗口挂载后；最终手动重启已自动重开常驻设置页。状态助手禁止在签名应用资源目录写入 Python 字节码缓存；多次刷新后严格签名校验仍通过。

重启验收期间曾因工具在应用交接未完成时读取窗口而启动额外实例。该实例已清理。最终按“点击重启 → 等待新 launchd 任务与端口归属一致 → 连接原生窗口”的顺序复验；已确认仅有一个 Gateway 进程，且它就是端口 44110 的受管监听者。最终手动重启后的 FChat 容器转写也返回 HTTP 200 和正确 WebVTT。

9 项守护测试使用真实子进程监听，包括旧后端仍返回已加载时的交接、端口被其他进程重新占用、探测中途更换监听者和等待中停止。10 项服务管理测试另覆盖设置页拒绝旧进程数据。音频协议及相关回归通过 211 项检查，音频控制器与图像服务隔离测试也通过。原有模型、监听地址、任务启动参数及连接偏好均逐项比对不变。

本地证据位于运行目录 `audio-service/acceptance/recovery-fix-20261017/`。最终演练为 `supervisor-2.json`、`supervisor-3.json`、`backend-1.json` 及对应 VTT。最终界面重启和配置比对为 `ui-restart.json`、`final.json`、`configuration-check.json`、`fchat-final.vtt`。`supervisor-1.json` 是只修复守护时序、尚未延长请求探测超时的中间版本，保留用于说明第二个 502 的来源。

## 有界就绪等待与单次提交复验

2026-10-17 后续版本将等待限定在转写 POST **之前**。每个请求最多等 12 秒，且不超过原配置超时；其间仅重复只读 `GET /models`，每次探测最多 2 秒，间隔最多 200 毫秒。探测还使用独立的时间限制，缓慢返回少量字节不能无限延长等待。等待消耗的时间从后续转写请求的超时预算中扣除。

模型在期限内就绪时，网关只提交一次转写 POST。未就绪时返回 `503 audio_backend_not_ready` 和 `Retry-After: 1`，并明确说明未提交转写。等待不会启动服务、加载或切换模型。等待期间配置改变会结束该请求；客户端断开或网关停止会取消等待，不会在稍后恢复时补交音频。

转写 POST 发送后不进入重试循环。下游重定向不会被自动跟随。若 POST 已处理但响应连接中断，仍返回 502 并说明结果可能未知，不自动重发。此方案不能替客户端去重，也不能保证已提交的请求在任意故障下都成功。

最终签名版本完成三轮强退演练。每轮在故障后立即由 FChat 主容器提交原有中文 WAV；curl 明确关闭重试。每轮随后共发送 3 个客户端请求，核对实际后端访问日志中的转写 POST 数量。

| 故障目标 | 新模型就绪 | 故障瞬间发起的转写完成 | 客户端结果 | 后端实际 POST |
| --- | --- | --- | --- | --- |
| 守护进程，第 1 轮 | 4.202 秒 | 4.782 秒 | 3 次 HTTP 200 | 3 次 |
| Whisper 后端 | 5.150 秒 | 5.456 秒 | 3 次 HTTP 200 | 3 次 |
| 守护进程，第 2 轮 | 4.592 秒 | 5.137 秒 | 3 次 HTTP 200 | 3 次 |

本轮 9 次真实转写均返回正确 WebVTT，未出现 502、503 或额外 POST。该结果覆盖上述演练，不是零故障承诺。

另将当前受管后端暂停，验证无法在期限内恢复的分支。FChat 请求在 12.149 秒结束，返回 503、`Retry-After: 1`，后端实际 POST 为 0。随后恢复同一后端进程，再次请求返回 200，后端实际 POST 增加 1 次。暂停操作使用 `finally` 恢复，未修改模型、地址或自启配置。

231 项协议及相关检查通过，音频控制器、图像服务隔离回归也通过。新增检查验证：恢复后只提交一次、等待到期零提交、缓慢探测不能延长期限、客户端断开后不补交，以及 POST 响应中断和重定向均不造成重复提交。

实际原生设置页的状态、刷新、新 PID 和恢复后就绪显示已验收。追加的“从界面选择音频并转写”测试在点击音频侧栏时遇到 `Sky Computer Use native pipe closed before response`。恢复原侧栏选择并重启受管应用、重置工具通道后，可再次读取并刷新设置页；当时的音频文件选择测试未完成，不记为通过；后续修复和实际操作结果见下文。应用和转写服务持续正常运行，最终配置与原值一致。FChat 真实转写和原生设置页验收分别保留，不能互相替代。

本轮证据位于运行目录 `audio-service/acceptance/readiness-wait-20261017/`：三轮 JSON、对应 VTT、`deadline.json`、`after-deadline.vtt`。最终配置比对和签名结果另存于同目录。


## 音频文件选择与转写界面验收

2026-10-17 继续检查自动化断开。macOS 崩溃报告确认，退出的是 `SkyComputerUseService`，不是 Gateway。16:18:12 与 16:27:03 的报告均为 `EXC_BREAKPOINT / SIGTRAP`，故障线程包含 `_assertionFailure`、`Array.remove(at:)` 和递归 `compactMap`。同时，受管 Gateway 与 Whisper 的进程和 HTTP 服务保持正常。

音频页是应用中唯一使用 `GroupBox` 的页面。给其内容增加辅助功能分组后，16:27:03 再次发生同样崩溃。将三个 `GroupBox` 改为普通 `VStack` 标题分区，并给标题添加 heading 辅助功能标记后，页面读取、截图和原生文件选择器均正常。此次修改绕开了当前桌面自动化读取器的崩溃触发结构；未修改该读取器，也未认定这是 Gateway 进程崩溃。

在已安装的签名应用中完成实际操作：

1. 打开 Whisper 音频页，点击“选择音频并转写…”。
2. 在原生文件选择器中定位并选中既有 `zh-test.wav`，点击“转写”。
3. 窗口显示文件名，以及“你好,这是一条语音转写测试,请把这段话转换成文字。”。
4. 后端访问日志只有一次转写 POST，结果为 HTTP 200。
5. 再次打开选择器并取消，结果保留，未增加转写 POST。
6. 切换到图像页，再返回音频页，文字保留，自动化通道未断开。

本轮界面修改未涉及模型、API、监听地址或 launchd 设置。现有 `whisper-1` 和实际 Whisper 模型继续使用，登录自启与异常恢复均保持开启。证据保存在运行目录的 `audio-service/acceptance/audio-ui-20261017/`，包括真实窗口截图 `transcript.png`、辅助功能树 `transcript-ax.txt`、后端 POST 记录及配置比对。

最终整理后的签名构建也已安装，并再次通过原生选择器完成一次中文音频转写。随后从 FChat 主容器提交同一 WAV，返回 HTTP 200 和正确 WebVTT；该轮后端日志共 2 次转写 POST，分别对应界面请求和容器请求。两者均未启用自动重试。签名严格校验通过。

最终常驻设置页显示 Gateway PID 27046、Whisper 守护进程 PID 27042，均运行中，`whisper-1` 已就绪。原侧栏选择已恢复。配置比对确认两个 LaunchAgent 的全部字段、音频服务 JSON，以及运行目录、模型目录、Python、主机和端口均与本轮操作前一致。最终结果见 `acceptance.json`、`configuration-check.json`、`final-status.json`、`final-transcript-ax.txt`、`fchat-final.vtt`。这些是本次验收记录，不是持续可用性承诺。
