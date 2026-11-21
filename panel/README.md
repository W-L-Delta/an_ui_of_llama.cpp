# llama.cpp 控制台

一个本地小面板，用来切换 项目根目录 上加载的模型、调 `-ngl` 等参数，并立刻验证效果。
纯 Python 标准库 + 单页 HTML，不装任何依赖，只监听 `127.0.0.1:8090`。

## 启动

双击本目录的 `start.cmd`（或由对话程序自动拉起）。

快捷方式直接调用 `pythonw.exe` 的绝对路径，不经过 PATH、批处理和 curl：

- 面板没在跑 → 后台拉起，就绪后自动打开浏览器
- 面板已经在跑 → 只新开一个标签页，不会起第二个实例

也可以手动：

```bat
python app.py --open          :: 启动并打开浏览器
python app.py                 :: 只启动，http://127.0.0.1:8090
python app.py --port 8095     :: 换端口
```

启动失败（端口被占、配置缺失等）会弹窗提示，同时写入 `panel.log`。
关闭：点页面右下角「关闭面板」。

## 能做什么

| 区域 | 作用 |
|---|---|
| 加载的模型 | 只列出 `models\` 里**真实存在**的 gguf：配置里留着但文件没下的槽位不会显示成空卡片；点选后「应用并重启」即切换，卡片上的 ID 就是 DSH 里要选的模型 ID，可一键复制 |
| 模型参数 | `-ngl`、`-c`、线程 `-t`、并发 `-np`、KV cache 类型、flash-attn、mmproj，以及**采样参数**（temp / top_p / top_k / min_p / presence / frequency / repeat / repeat_last_n / dry）——按模型存在各自的段里 |
| 保活开关 | 标题栏「保活」开关，直接启用/禁用计划任务 `llama-keepalive`；状态卡显示保活状态与下次检查时间 |
| 服务状态 | 运行状态、PID、已加载上下文、量化/参数量、显存条 + 内存条（含 llama-server 工作集）、上次生成速度、操作日志 |
| 对话测速 | 发一条短对话，返回 tok/s、token 数、耗时，用来对比调参前后 |
| 运行日志 | 实时查看 `llama-server.err.log` / `.log` / `guard.log` |

## 参数写到哪

面板改的是 `项目根目录\scripts\llama.conf.ini`（该文件是现有 `start-llama.ps1` 的唯一配置源）：

- Qwen3.5-9B → `[gpu]` 段
- 线程/并发 → `[server]`
- 视觉投影 → `[vision]`

> 早先的 DeepSeek 槽位和 `[deepseek]` / `[deepseek_q4]` 段已随模型一起删除
> （文件不在盘上）。若要加回，按 `llama.conf.ini` 顶部注释补 `[model]` / `[server]`，
> 需要独立参数时再给它建段，面板会自动把参数写进该段。

每次写入前自动备份到 `llama-panel/backups/llama.conf.<时间戳>.ini`（保留最近 20 份）。
改完调用现有的 `scripts\start-llama.ps1` 重启，并把所选模型写进 `[models] active`，所以**保活任务下次拉起的也是这个模型**。

## 调参思路

- **显存不够先压 KV**：`q8_0 → q4_0` 大约省一半 KV，质量损失小于降 ngl
- **ngl 别乱降**：少一层就少一分并行度，速度掉得比省下的显存划算
- **长上下文很贵**：上下文翻倍，KV 也跟着翻倍
- **MoE 用 `--cpu-moe`**：专家留内存、注意力在显卡，小显存也能跑大模型
- 改完点「应用并重启」，再用对话测速对比前后差异

切换模型后

面板把模型换掉后，DSH 里要选对应 ID，否则会报 `UNKNOWN_MODEL`：

| 面板里的模型 | DSH 模型 ID |
|---|---|
| Qwen3.5 9B ✅ | `qwen3.5-9b` |
| Qwen3.6 35B-A3B | `qwen3.6-35b-a3b` |

## 注意事项

- **同一时刻只能跑一个模型**（每个约 5.3–5.5 GB，卡只有 8 GB）。切换会中断当前服务 10–30 秒。
- 保活任务 `llama-keepalive` 每 3 分钟检查一次，点「停止」后它会在几分钟内把服务重新拉起。想让它保持停止，先把标题栏的「保活」开关关掉（改的就是这个计划任务，不需要管理员权限）。
- 跑 ComfyUI（尤其 MiniMax H3）前先停掉 llama-server，否则抢显存。
- llama-server 没有设置 API Key（仅绑 127.0.0.1），面板同样只监听本机，不要改成 `0.0.0.0`。

## 目录

```
llama-panel/
  app.py           后端：ini 读写、进程控制、状态/测速 API
  ui.html          单页界面
  启动面板.cmd     备用启动入口（等价于 python app.py --open）
  panel.log        每次启动的记录，排障先看这里
  screen.png       界面截图
  backups/         配置自动备份
```

## 排查

- **双击没反应**：先看 `panel.log` 最后几行；正常会写「服务: …」「已请求浏览器打开: …」。
- **端口被占用**：面板会弹窗提示，用 `python app.py --port 8095`。
- **启动就失败**：页面下方「操作日志」里有 `start-llama.ps1` 的完整输出；也可直接跑
  `项目根目录\scripts\start-llama.ps1 -Foreground` 看前台日志。
- **改完没生效**：确认页面提示的写入段（现在只有 `[gpu]`），参数确实写进了 `llama.conf.ini`。

## 给对话前端用的接口

面板顺带提供三个只读/存储接口，`web\chat.html` 依赖它们：

| 接口 | 作用 |
|---|---|
| `GET /api/sessions` | 读 `panel\data\chat-sessions.json`（不存在时 `exists:false`） |
| `POST /api/sessions` | 整体覆盖写入会话 JSON（原子替换，>1MB 拒绝） |
| `GET /api/fs?path=...` | 只读列目录，用于工作区选文件夹和目录清单；`path` 为空时返回磁盘列表 |
| `POST /api/open-app` | 启动（或复用）桌面对话程序 `chat-app\llama-chat.exe` |

只绑定 127.0.0.1，没有鉴权；会话文件是明文。