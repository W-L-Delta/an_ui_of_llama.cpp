#!/usr/bin/env bash
# ============================================================
#  run.sh —— 固定入口，你永远只需要跑这一条命令：
#
#      bash /home/w-l-delta/WinD/llama.cpp/scripts/linux/run.sh
#
#  AI 每次只会改这个文件里「当前步骤」那一段，
#  所以你不用重新复制命令，直接重跑这一条即可。
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# <挂载点>/llama.cpp/scripts/linux -> <挂载点>
SHARE="$(cd "$HERE/../../.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"

echo "工作目录: $HERE"
echo "共享盘  : $SHARE"
echo

# ---------------- 当前步骤 ----------------
STEP="01-gpu-check.sh"
echo ">>> 正在执行: $STEP"
bash "$HERE/$STEP" 2>&1 | tee "$SHARE/gpu-report.txt"
# ------------------------------------------

echo
echo "报告已写入: $SHARE/gpu-report.txt"
echo "回到 Windows 后，这个文件就在 D:\\gpu-report.txt"
