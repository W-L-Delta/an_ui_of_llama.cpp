# 配置说明

配置文件：`scripts/llama.conf.ini`（从 `llama.conf.example.ini` 复制而来）。
控制台的改动会写回这里，写之前自动备份到 `panel/backups/`。

## 段一览

| 段 | 作用 |
|---|---|
| `[models]` | `active` 指定当前加载哪个槽位，保活也认它 |
| `[model]` | 各槽位的 gguf 路径；`mmproj` 是视觉投影的默认值 |
| `[server]` | host / port / alias / threads / parallel |
| `[gpu]` | base 模型的参数（ngl、ctx、KV 类型、flash-attn、采样、max_tokens） |
| `[qwen36]` `[deepseek]` | 覆盖段：只写和 `[gpu]` 不同的键 |
| `[vision]` | `enabled` 是否加载 mmproj |
| `[router]` | llama-server 的 router 模式（多模型热切换，实验性） |
| `[extra]` | 追加到命令行的通用参数（如 `--reasoning-budget 512`） |
| `[sampling]` | 采样参数兜底值（模型段没写时用） |
| `[tools]` | 工具权限：`level` 默认级别、`ceiling` 上限、`workspace` 沙箱根、`max_rounds` |
| `[web]` | 联网：`enabled`、`engine`、`fallback`、`max_results`、`scan_pages`、`fetch_pages`、`block_private` |
| `[chat]` | 对话程序：`summarize`、`sum_threshold`、`sum_keep` |

## 常用键

```ini
[server]
port        = 8080
alias       = qwen3.5-9b
threads     = 8
parallel    = 1        ; 并发槽位，1 = 满上下文给单会话

[gpu]
n_gpu_layers = 35      ; 全上卡；装不下就调小
ctx_size     = 163840
cache_type_k = q4_0    ; KV 量化，q8_0 更准、q4_0 更省
flash_attn   = on

[qwen36]
ctx_size     = 65536
n_gpu_layers = 99
extra_args   = --cpu-moe   ; MoE 专家放内存，8G 卡也能跑 35B

[extra]
args = --reasoning-budget 512 --cache-reuse 256 --keep 256
```

## 三级回退

同一个键可以出现在三个地方，优先级：

```
模型自己的段  >  [gpu] / [sampling]  >  脚本内置默认
```

所以新增模型时，只写和默认不同的部分即可。

## 环境变量

| 变量 | 作用 |
|---|---|
| `LLAMA_CPP_ROOT` | 项目根目录（默认取 `panel/` 的上一级） |
| `LLAMA_PANEL_CONF` | 指定别的配置文件 |
| `LLAMA_PANEL_DATA` | 会话数据目录（**测试隔离用**，指向临时目录即可跑一份独立实例） |

例：起一个不碰真实数据的测试面板

```powershell
$env:LLAMA_PANEL_DATA = "$env:TEMP\llama-test"
python panel\app.py --port 8091
```

## 调参经验

**显存不够时，先压 KV 再降 ngl。**

- KV 量化 `q8_0 → q4_0` 大约省一半 KV 显存，精度损失通常比降 ngl 小
- ngl 每降一层，并行度就少一层，生成速度掉得比省下的显存划算得多
- 上下文翻倍，KV 缓存也跟着翻倍——长上下文的成本常常被低估

**MoE 模型看内存带宽，不是显存。**

把专家留在内存（`--cpu-moe`）往往比硬塞进显存更快：塞不下会溢出，反而更慢。
这类模型真正需要关注的是内存容量与带宽。

**给小显存卡的建议顺序：**

1. 先定 ngl（能全上卡就全上）
2. 再定上下文（够用就行）
3. 最后调 KV 量化（吃紧了才降）

具体数值取决于模型大小、量化、显卡和内存，没有通用答案——用控制台的「对话测速」在你自己的机器上量。
