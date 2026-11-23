#!/usr/bin/env bash
# 打开对话界面：确保控制台面板在跑，然后交给浏览器
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${LLAMA_CPP_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PORT="${LLAMA_PANEL_PORT:-8090}"
URL="http://127.0.0.1:$PORT/chat"

up() { curl -fsS --max-time 2 "http://127.0.0.1:$PORT/api/state" >/dev/null 2>&1; }

if ! up; then
  mkdir -p "$ROOT/logs"
  nohup python3 "$ROOT/panel/app.py" --port "$PORT" \
    >>"$ROOT/logs/panel.log" 2>&1 &
  echo "$!" > "$ROOT/logs/panel.pid"
  for _ in $(seq 1 30); do up && break; sleep 0.4; done
fi

# 顺便确保推理服务在跑（面板起来后再拉起，避免抢锁）
bash "$ROOT/scripts/start-llama.sh" --ensure >/dev/null 2>&1 || true

opener=""
for c in xdg-open gio sensible-browser x-www-browser; do
  command -v "$c" >/dev/null 2>&1 && { opener="$c"; break; }
done

if [ -n "$opener" ]; then
  case "$opener" in
    xdg-open) xdg-open "$URL" >/dev/null 2>&1 & ;;
    gio)      gio open "$URL" >/dev/null 2>&1 & ;;
    *)        "$opener" "$URL" >/dev/null 2>&1 & ;;
  esac
else
  echo "控制台已启动：$URL （没找到浏览器，请手动打开）"
fi
