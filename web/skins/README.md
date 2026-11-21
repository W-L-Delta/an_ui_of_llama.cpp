# skins/

皮肤清单在 `skins.json`，按**模型家族**切换：

| 家族 | 主题色 | 背景图 | 图标 |
|---|---|---|---|
| `none`（没模型 / 其他模型） | 全黑 | 无 | `icons/default.png` |
| `deepseek` | 深蓝 | `deepseek/bg.jpg` | `icons/deepseek.png` |
| `qwen` | 天蓝 | `qwen/bg.jpg` | `icons/qwen.png` |

## 关于背景图

`*/bg.jpg` **不在仓库里**（版权与体积原因）。放自己喜欢的图，命名对上即可：

```
skins/qwen/bg.jpg       建议 1920x1080
skins/deepseek/bg.jpg
```

文件缺失时不会报错，只是没有背景图，主题色依然生效。

## 预览

`http://127.0.0.1:8090/chat?family=deepseek` 可以强制预览某个家族。
