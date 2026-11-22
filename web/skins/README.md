# skins/

皮肤清单在 `skins.json`，默认**按模型家族**切换（也可以在对话程序的「设置 → 皮肤」里手动指定）：

| 家族 | 主题色 | 背景图 | 图标 |
|---|---|---|---|
| `none`（没模型 / 其他模型） | 纯黑 | 无 | `icons/default.png` |
| `deepseek` | 深蓝 | `deepseek/bg.jpg` | `icons/deepseek.png` |
| `qwen` | 天蓝 | `qwen/bg.jpg` | `icons/qwen.png` |

## 背景图来源与版权

| 文件 | 来源 |
|---|---|
| `qwen/bg.jpg` | 本项目作者用 AI 生成 |
| `deepseek/bg.jpg`、`deepseek/bg.webp` | 收集自网络，仅作界面演示 |

> **如有侵权，请联系作者，会立即删除。**

如果你不想用这两张图，删掉对应文件即可：皮肤引擎在图片缺失时会自动回落到纯色主题，不会报错。

## 自己换图

替换同名文件就行，建议 1920×1080 以上。想加新家族，在 `skins.json` 的 `families` 里加一项，字段照抄现有条目。

## 预览

`http://127.0.0.1:8090/chat?family=qwen` 可以强制预览某个家族。
