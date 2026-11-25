#!/usr/bin/env bash
# ============================================================
#  run.sh —— 固定入口，你永远只需要跑这一条命令：
#
#      bash /home/w-l-delta/WinD/llama.cpp/scripts/linux/run.sh
#
#  AI 每次只改下面「当前步骤」这一行，你不用重新复制命令。
#  输出会写到共享盘的 step-report.txt，AI 回到 Windows 直接读。
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SHARE="$(cd "$HERE/../../.." && pwd)"      # <挂载点>/llama.cpp/scripts/linux -> <挂载点>
OUT="$SHARE/step-report.txt"

echo "工作目录: $HERE"
echo "共享盘  : $SHARE"
echo "报告文件: $OUT"
echo

# ---------------- 当前步骤（AI 会改这一行） ----------------
STEP="08-install-ui.sh"
# ----------------------------------------------------------

echo ">>> 执行: $STEP"
bash "$HERE/$STEP" 2>&1 | tee "$OUT"

echo
echo "报告已写入: $OUT   （Windows 里就是 D:\\step-report.txt）"
