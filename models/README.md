# models/

放 GGUF 模型文件。默认配置引用了三个示例模型（换成你自己的也行）：

| 槽位 | 文件 | 说明 |
|---|---|---|
| base | `model-base.gguf` | 主模型（示例槽位） |
| qwen36 | `model-moe.gguf` | MoE 大模型，专家放内存（`--cpu-moe`） |
| deepseek | `model-reasoning.gguf` | 带思维链的推理模型 |

可选：视觉投影文件（`--mmproj`），文件名写进 `llama.conf.ini` 的 `[model] mmproj`
或各模型段自己的 `mmproj`。

模型文件很大，`.gitignore` 已经排除，不会误提交。
