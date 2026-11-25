#!/usr/bin/env bash
# ============================================================
#  07-start-server.sh —— 重新启动服务（不再依赖 curl）
#
#  上一轮查出来的问题：
#    1. 系统里没有 curl        -> 我的健康检查全都没生效，所以误报"超时"
#    2. 服务确实退出过（日志有 cleaning up before exit，说明收到 SIGTERM）
#       -> 终端关闭 / 会话结束 把它带走了
#
#  这个脚本：装 curl（方便以后）、用 setsid --fork 完全脱离终端启动、
#            用 python3 做健康检查与对话测试（不依赖 curl）
# ============================================================
set -u
PORT=8080
BIN="$HOME/llama.cpp/llama-b12681"
MODEL="$HOME/WinD/llama.cpp/models/Qwen3.5-9B-Q4_K_M.gguf"
LOG="$HOME/llama-server.log"
PIDF="$HOME/llama-server.pid"
say() { printf "\n\033[36m== %s ==\033[0m\n" "$*"; }

say "1. 检查工具"
if command -v curl >/dev/null 2>&1; then
  echo "  curl: 已有"
else
  echo "  curl: 缺失，尝试安装（会问 sudo 密码）"
  sudo apt-get install -y curl || echo "  安装失败，不影响后面（后面用 python3）"
fi
command -v python3 >/dev/null 2>&1 && echo "  python3: $(python3 -V 2>&1)" || { echo "  python3 缺失，无法继续"; exit 1; }

say "2. 停止旧进程"
if [ -f "$PIDF" ]; then
  kill "$(cat "$PIDF")" 2>/dev/null && echo "  已停止 $(cat "$PIDF")"
fi
pkill -f 'llama-b12681/llama-server' 2>/dev/null
sleep 2
pgrep -af 'llama-server' || echo "  当前没有 llama-server 在跑"

say "3. 完全脱离终端启动"
cd "$BIN" || exit 1
: > "$LOG"
setsid --fork env LD_LIBRARY_PATH="$BIN" "$BIN/llama-server" \
  -m "$MODEL" --host 127.0.0.1 --port "$PORT" \
  -ngl 35 -c 32768 -ctk q4_0 -ctv q4_0 -fa on -t 8 \
  >> "$LOG" 2>&1
sleep 3
PID="$(pgrep -f 'llama-b12681/llama-server' | head -1)"
if [ -n "${PID:-}" ]; then
  echo "$PID" > "$PIDF"
  echo "  PID: $PID（已脱离终端，关掉终端也不会停）"
else
  echo "  启动失败！日志："
  tail -20 "$LOG"
  exit 1
fi

say "4. 等待就绪（python3 探测 /health）"
python3 - <<'PY'
import time, urllib.request
ok = False
for i in range(180):
    try:
        with urllib.request.urlopen("http://127.0.0.1:8080/health", timeout=2) as r:
            if r.status == 200:
                ok = True
                print(f"  就绪，用了约 {i} 秒")
                break
    except Exception:
        pass
    time.sleep(1)
print("  健康检查通过" if ok else "  180 秒仍未就绪")
raise SystemExit(0 if ok else 1)
PY
rc=$?
[ $rc -ne 0 ] && { echo; echo "日志尾部:"; tail -25 "$LOG"; exit 1; }

say "5. 对话测试（真实推理一次）"
python3 - <<'PY'
import json, urllib.request, time
payload = json.dumps({
    "messages": [{"role": "user", "content": "用一句话介绍你自己"}],
    "max_tokens": 80, "stream": False,
}).encode()
req = urllib.request.Request("http://127.0.0.1:8080/v1/chat/completions",
                             data=payload, headers={"Content-Type": "application/json"})
t0 = time.time()
try:
    with urllib.request.urlopen(req, timeout=300) as r:
        j = json.loads(r.read().decode())
    msg = (j.get("choices") or [{}])[0].get("message", {})
    content = (msg.get("content") or "").strip().replace("\n", " ")
    print(f"  用时 {time.time()-t0:.1f}s")
    print(f"  回答: {content[:200] if content else '(空，可能全是思考内容)'}")
except Exception as e:
    print("  请求失败:", e)
    raise SystemExit(1)
PY

say "6. 状态"
nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null
printf "  进程: "; pgrep -af 'llama-b12681/llama-server' | head -1

say "完成"
cat <<EOT
  服务: http://127.0.0.1:$PORT     （已脱离终端，可关掉这个窗口）
  停止: kill \$(cat ~/llama-server.pid)
  日志: tail -f ~/llama-server.log
EOT
