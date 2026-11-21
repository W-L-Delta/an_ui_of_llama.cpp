# llama.cpp 本地对话 + 控制台

Windows 上的本地大模型**一体化客户端**：原生窗口（WinForms + WebView2）里跑对话界面，
内置一个控制台面板管理模型和参数。不是浏览器标签页，不依赖任何云服务。

> 面向小显存单卡做过调优：模型怎么摆、上下文开多大、参数怎么调，都在控制台里能改、能测、能存。

## 功能

**对话**
- 原生窗口，左侧工作区 / 会话管理（新建、改名、删除、右键改名）
- Markdown 渲染：粗体、斜体、删除线、标题、列表、引用、代码块（代码块显示空格点、等宽对齐）
- 图片输入（需 mmproj 视觉投影）、文本/代码附件（自动按扩展名加语言标记）
- 上下文占用环（按会话独立记账）、令牌用量与 tok/s
- 旧历史自动摘要：上下文超过阈值时把早期对话压成要点（可手动触发）

**工具调用**（照 DSH 沙箱思路做的分级）
- 只读 / 工作区可写 / 完全访问 三级，按会话独立设置
- 写文件、执行命令每次弹审批框，可勾选「本会话内同类操作不再询问」
- 路径限制在工作区内；`shell` 仅完全访问档可用

**联网**
- `web_search`：Bing RSS 主引擎 + 360 兜底，多页抓取 → 逐条相关性打分 → 只把有用的交给模型
- `web_fetch`：容器打分提取正文（不是把整页标签扒掉），过滤导航与页脚
- SSRF 防护：只允许 http/https，解析后逐个 IP 拦内网 / 回环 / 链路本地地址，重定向逐跳校验

**控制台**（`panel/`，127.0.0.1:8090）
- 模型卡片、GPU 层数 / 上下文 / 线程 / KV 缓存 / flash-attn / 视觉投影 / 联网开关
- 每个模型独立的采样参数、`max_tokens`、模型提示词
- 服务状态、显存与内存条、操作日志、对话测速、保活开关
- 改参数前自动备份 `llama.conf.ini`，并可一键重启服务

**工程细节**
- 保活用计划任务 + GUI 子系统启动器，**全程没有控制台窗口闪现**
- 面板进程看门狗：面板挂了自动拉起
- 会话文件原子写入 + 每次保存前留快照（保留 30 份）

## 目录结构

```
llama-local/
├── chat-app/            原生外壳（C# WinForms + WebView2）
│   ├── src/Program.cs
│   ├── app.manifest
│   ├── assets/app.ico
│   └── build.ps1        编译脚本
├── panel/               控制台（Python 标准库，无第三方依赖）
│   ├── app.py           HTTP 服务 + 配置读写 + 工具执行器
│   ├── tools.py         文件/联网工具与安全护栏
│   ├── ui.html          控制台界面
│   └── start.cmd        双击启动
├── web/                 对话前端（静态页）
│   ├── chat.html
│   └── skins/           皮肤清单 + 图标（背景图需自备）
├── scripts/
│   ├── start-llama.ps1        启动 / 切换 / 停止 / 保活检查
│   ├── register-keepalive.ps1 注册计划任务
│   ├── windowless-runner.cs   无窗口启动器源码
│   ├── llama.conf.example.ini 配置示例
│   └── models.ini             llama-server 的 router 预设（可选）
├── docs/                架构与配置说明
├── bin/                 llama.cpp 二进制（自行下载，见 bin/README.md）
└── models/              GGUF 模型（自行放置，见 models/README.md）
```

## 快速开始

1. **llama.cpp 二进制**：按 `bin/README.md` 下载 CUDA 版解压到 `bin/cuda/`
2. **模型**：GGUF 放进 `models/`
3. **配置**：`copy scripts\llama.conf.example.ini scripts\llama.conf.ini`，改模型路径与 `[tools] workspace`
4. **编译外壳**：
   ```powershell
   powershell -ExecutionPolicy Bypass -File chat-app\build.ps1
   ```
   （用系统自带的 `csc.exe`，不需要装 .NET SDK；需要 WebView2 运行时，Win11 自带）
5. **启动**：
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\start-llama.ps1
   .\chat-app\llama-chat.exe
   ```
   程序启动时会自动拉起面板（8090）并确保 llama-server 在跑。

### 常驻保活（可选）

```powershell
powershell -ExecutionPolicy Bypass -File scripts\register-keepalive.ps1
```

注册一个每 3 分钟检查一次的计划任务，服务挂了自动拉起，且**不会闪控制台窗口**。

## 快捷键

| 按键 | 行为 |
|---|---|
| `Enter` | 换行 |
| `Ctrl+Enter` | 发送 |
| `Ctrl+Shift+C` | 把选中文字包成代码块 |
| `Tab` | 插入 4 个空格 |
| `Esc` | 关闭弹窗 / 图片灯箱 |

输入框里输入 `{` `[` `(` 会自动补配对，在两括号中间按 `Enter` 展开并缩进（类似 VS Code）。

## 设计要点

- **一个 llama-server，多个客户端**：控制台和对话页都通过 HTTP 访问 8080，模型只加载一份
- **配置即真相**：`llama.conf.ini` 是唯一配置源，控制台写它，启动脚本读它
- **参数按模型独立**：每个模型有自己的段（`[gpu]` / `[qwen36]` / `[deepseek]`），采样、上下文、KV 类型互不影响
- **安全默认**：面板与 llama-server 只监听 `127.0.0.1`；工具按会话授权；联网工具可整体关闭

更多细节见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) 与 [`docs/CONFIG.md`](docs/CONFIG.md)。

## 关于本仓库的内容

仓库里**只有源代码与文档**：不含模型权重、llama.cpp 二进制、聊天记录、截图，也不含任何本机路径或个人信息。
配置用的是 `scripts\llama.conf.example.ini` 模板，路径与模型名都是占位值，按你的环境改。

## 已知限制

- 仅 Windows（WinForms + WebView2 + 计划任务）
- 参数面板是针对单卡 8 GB 调的，多卡 / 大显存机器也能用，但默认值需要自己重调
- 表格 Markdown 暂不渲染（模型画的表经常列数不齐）
- 联网搜索依赖 Bing / 360 的公开页面，会间歇性返回无关结果——已做相关性校验与换词重试

## License

[MIT](LICENSE)
