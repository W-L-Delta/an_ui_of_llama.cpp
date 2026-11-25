#!/usr/bin/env bash
# ============================================================
#  run.sh —— 固定入口，你永远只需要跑这一条命令：
#
#      bash /home/w-l-delta/WinD/llama.cpp/scripts/linux/run.sh
#
#  AI 只改下面「当前步骤」那一行，你不用重新复制命令。
#  输出写到共享盘 step-report.txt，AI 回到 Windows 直接读。
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SHARE="$(cd "$HERE/../../.." && pwd)"
OUT="$SHARE/step-report.txt"

# ---- 自愈：这些脚本在 Windows 上生成，可能带 CRLF，bash 会直接报语法错 ----
fix_crlf() {
  local f="$1"
  [ -f "$f" ] || return 0
  if grep -q $'\r' "$f" 2>/dev/null; then
    local tmp="$f.crlf.$$"
    if sed 's/\r$//' "$f" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f"; then
      echo "  （已修正 CRLF 换行：$(basename "$f")）"
    else
      rm -f "$tmp"
      echo "  （警告：$(basename "$f") 含 CRLF 但修正失败）"
    fi
  fi
}
for f in "$HERE"/*.sh; do fix_crlf "$f"; done

echo "工作目录: $HERE"
echo "共享盘  : $SHARE"
echo "报告文件: $OUT"
echo

# ---------------- 当前步骤（AI 会改这一行） ----------------
STEP="18-ui-fixes.sh"
# ----------------------------------------------------------

echo ">>> 执行: $STEP"
bash "$HERE/$STEP" 2>&1 | tee "$OUT"

echo
echo "报告已写入: $OUT   （Windows 里就是 D:\\step-report.txt）"
