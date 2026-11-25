#!/usr/bin/env bash
# ============================================================
#  05-smoke-server.sh —— 用 Qwen3.5-9B 起一次服务并自测
#
#  模型直接从 Windows 盘读： ~/WinD/llama.cpp/models/
#  启动参数保守（上下文 32768），先保证能跑起来
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/llama.cpp/llama-b12681"
MODEL="$HOME/WinD/llama.cpp/models/Qwen3.5-9B-Q4_K_M.gguf"
LOG="$HOME/llama-server.log"
PIDF="$HOME/llama-server.pid"
PORT=8080
say() { printf "\n\033[36m== %s ==\033[0m\n" "$*"; }

say "检查"
[ -x "$BIN/llama-server" ] || { echo "找不到 $BIN/llama-server，先跑 04"; exit 1; }
if [ -f "$MODEL" ]; then
  printf "  模型: %s (%.1f GB)\n" "$MODEL" "$(awk -v b="$(stat -c %s "$MODEL")" 'BEGIN{printf "%.2f", b/1073741824}')"
else
  echo "  找不到模型: $MODEL"
  echo "  检查: ls ~/WinD/llama.cpp/models/"
  exit 1
fi

say "清理旧进程"
if [ -f "$PIDF" ]; then kill "$(cat "$PIDF")" 2>/dev/null && echo "  已停止旧进程"; fi
pkill -f 'llama-b12681/llama-server' 2>/dev/null
sleep 1

say "启动 llama-server（约 10-20 秒加载）"
cd "$BIN" || exit 1
nohup env LD_LIBRARY_PATH="$BIN" "$BIN/llama-server" \
  -m "$MODEL" \
  --host 127.0.0.1 --port "$PORT" \
  -ngl 35 -c 32768 -ctk q4_0 -ctv q4_0 -fa on -t 8 \
  > "$LOG" 2>&1 &
echo $! > "$PIDF"
echo "  PID: $(cat "$PIDF")   日志: $LOG"

say "等待 /health 就绪（最多 120 秒）"
ready=""
for i in $(seq 1 120); do
  if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then ready=1; break; fi
  if ! kill -0 "$(cat "$PIDF")" 2>/dev/null; then break; fi
  sleep 1
done

if [ -z "$ready" ]; then
  echo "  启动失败或超时。日志最后 30 行："
  tail -30 "$LOG"
  exit 1
fi
echo "  就绪（用了约 ${i} 秒）"

say "显示的模型"
curl -s "http://127.0.0.1:$PORT/v1/models" | head -c 400
echo

say "实际对话测试"
curl -s -X POST "http://127.0.0.1:$PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"用一句话介绍你自己"}],"max_tokens":60,"stream":false}' \
  | head -c 600
echo

say "显存占用"
nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null

say "完成"
cat <<EOT
  服务地址: http://127.0.0.1:$PORT
  停止服务: kill \$(cat ~/llama-server.pid)
  看日志  : tail -f ~/llama-server.log
EOT
