# Linux 侧操作说明（双系统专用）

## 为什么不用复制粘贴命令

Windows 的磁盘在 Linux 里是**自动挂载**的，可以直接读写。
所以流程是：**在 Windows 上写脚本 → 在 Linux 里直接运行那个文件**，不用来回拷命令。

## 怎么用

1. 在 Linux 终端里先跑一次「找盘」：

```bash
for d in /run/media/*/* /home/*/WinD /mnt/* /media/*/*; do
  [ -d "$d/llama.cpp/scripts/linux" ] && { echo "Windows 盘在: $d"; break; }
done
```

2. 假设输出的路径是 `/home/w-l-delta/WinD`，那么直接运行：

```bash
bash /home/w-l-delta/WinD/llama.cpp/scripts/linux/01-gpu-check.sh
```

3. 想把结果带回 Windows（给 AI 看），加一个 `tee`：

```bash
bash /home/w-l-delta/WinD/llama.cpp/scripts/linux/01-gpu-check.sh | tee /home/w-l-delta/WinD/gpu-report.txt
```

这样报告会写到 Windows 的 D 盘根目录，重启回 Windows 后直接能打开，也能让 AI 读取。

## 脚本清单

| 脚本 | 作用 |
|---|---|
| `01-gpu-check.sh` | 显卡驱动诊断（只读） |
| `../linux-doctor.sh` | 整体环境体检（只读） |

## 注意

- NTFS 分区是 `rw` 挂载的，Linux 可以写回去，权限上一般不会拦
- 脚本只读不写，除了你用 `tee` 指定的那个报告文件
- 如果提示 `bash: ...: Permission denied`，用 `bash 文件路径` 运行（不需要 chmod）
