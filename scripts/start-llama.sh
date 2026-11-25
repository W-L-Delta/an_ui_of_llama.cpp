#!/usr/bin/env bash
# ============================================================
#  llama-local-chat · Linux 启动脚本
#
#  用法：
#     ./scripts/start-llama.sh                 启动（已在跑则不动）
#     ./scripts/start-llama.sh --stop          停止
#     ./scripts/start-llama.sh --status        查看状态
#     ./scripts/start-llama.sh --ensure        只在没跑时拉起（给 systemd/timer 用）
#     ./scripts/start-llama.sh --foreground    前台运行（给 systemd Type=simple 用）
#     ./scripts/start-llama.sh --base          切到 base 槽位并重启
#     ./scripts/start-llama.sh --qwen36        切到 qwen36 槽位
#     ./scripts/start-llama.sh --deepseek      切到 deepseek 槽位
#
#  兼容 Windows 侧的调用风格（-Stop / -EnsureRunning / -Status / -Base …），
#  面板在不同平台下不用改参数名。
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${LLAMA_CPP_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CONF="${LLAMA_PANEL_CONF:-$ROOT/scripts/llama.conf.ini}"
LOGS="$ROOT/logs"
PID_FILE="$LOGS/llama-server.pid"
OUT_LOG="$LOGS/llama-server.log"
ERR_LOG="$LOGS/llama-server.err.log"
GUARD_LOG="$LOGS/guard.log"
LOCK_FILE="$LOGS/.start.lock"

mkdir -p "$LOGS"

say()  { printf '%s\n' "$*"; }
ok()   { printf '  OK  %s\n' "$*"; }
warn() { printf '  !!  %s\n' "$*"; }
die()  { printf '  XX  %s\n' "$*" >&2; exit 1; }
guard(){ printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$GUARD_LOG"; }

# ------------------------------------------------------------ 配置读取
# gv <section> <key> <default>
gv() {
  local section="$1" key="$2" def="${3:-}"
  [ -f "$CONF" ] || { printf '%s' "$def"; return; }
  local v
  v="$(awk -v sect="$section" -v k="$key" '
    /^[[:space:]]*[#;]/ { next }
    /^[[:space:]]*\[/ {
      gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", $0)
      cur = tolower($0); next
    }
    {
      line = $0
      sub(/[[:space:]]*[#;].*$/, "", line)          # 去掉行内注释
      if (line ~ /^[[:space:]]*$/) next
      split(line, kv, "=")
      key = kv[1]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      if (tolower(cur) == tolower(sect) && tolower(key) == tolower(k)) {
        val = substr(line, index(line, "=") + 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
        print val; exit
      }
    }' "$CONF")"
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$def"; fi
}

# 先看角色自己的段，没有再回落到全局段
gvr() {  # gvr <role-section> <fallback-section> <key> <default>
  local role="$1" fb="$2" key="$3" def="${4:-}"
  local v=""
  [ "$role" != "$fb" ] && v="$(gv "$role" "$key" "")"
  [ -n "$v" ] && { printf '%s' "$v"; return; }
  gv "$fb" "$key" "$def"
}

# ------------------------------------------------------------ 运行态判断
health_ok() {
  local port; port="$(gv server port 8080)"
  curl -fsS --max-time 3 "http://127.0.0.1:$port/health" >/dev/null 2>&1
}

running_pid() {
  [ -f "$PID_FILE" ] || return 1
  local pid; pid="$(cat "$PID_FILE" 2>/dev/null)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s' "$pid"
}

find_server() {
  local c
  for c in "$ROOT/bin/cuda/llama-server" "$ROOT/bin/vulkan/llama-server" \
           "$ROOT/bin/llama-server" "$ROOT/bin/build/bin/llama-server"; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  command -v llama-server 2>/dev/null && return 0
  return 1
}

# ------------------------------------------------------------ 模型路径容错
# 配置里可能留着 Windows 相对路径（models\xxx.gguf）或过期绝对路径。
# 依次尝试：原样 / 反斜杠转正斜杠 / ROOT 相对 / Windows 盘挂载点 / 按文件名找
resolve_model() {
  local m="$1" n c
  n="${m//\\//}"
  for c in "$m" "$n" "$ROOT/$n" "$HOME/WinD/llama.cpp/$n" \
           "$HOME/WinD/llama.cpp/models/$(basename "$n")" "$ROOT/models/$(basename "$n")"; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# ------------------------------------------------------------ 参数拼装
build_args() {
  local role section model alias
  role="$(gv models active base)"
  case "$role" in
    base)     section="gpu";      model="$(gv model model '')";    alias="$(gv server alias '')" ;;
    qwen36)   section="qwen36";   model="$(gv model qwen36 '')";   alias="$(gv server alias_qwen36 '')" ;;
    deepseek) section="deepseek"; model="$(gv model deepseek '')"; alias="$(gv server alias_deepseek '')" ;;
    *)        section="gpu";      model="$(gv model model '')";    alias="$(gv server alias '')" ;;
  esac

  [ -n "$model" ] || die "配置里 [model] 没写模型文件（当前角色 $role）"
  local raw_model="$model"
  model="$(resolve_model "$raw_model")" || {
    warn "找不到模型文件：$raw_model"
    warn "试过：$ROOT/${raw_model//\\//}、$HOME/WinD/llama.cpp/${raw_model//\\//}"
    die "模型文件不存在（当前角色 $role）"
  }

  local host port threads parallel ngl ctx ctk ctv fa reason mmproj
  host="$(gv server host 127.0.0.1)"
  port="$(gv server port 8080)"
  threads="$(gv server threads 0)"
  parallel="$(gv server parallel 1)"
  ngl="$(gvr "$section" gpu n_gpu_layers 99)"
  ctx="$(gvr "$section" gpu ctx_size 32768)"
  ctk="$(gvr "$section" gpu cache_type_k '')"
  ctv="$(gvr "$section" gpu cache_type_v '')"
  fa="$(gvr "$section" gpu flash_attn on)"
  reason="$(gvr "$section" gpu reasoning_format '')"

  ARGS=(--model "$model" --host "$host" --port "$port"
        --ctx-size "$ctx" --n-gpu-layers "$ngl" --parallel "$parallel")
  [ -n "$alias" ] && ARGS+=(--alias "$alias")
  [ "$threads" != "0" ] && ARGS+=(--threads "$threads")
  [ -n "$ctk" ] && ARGS+=(--cache-type-k "$ctk")
  [ -n "$ctv" ] && ARGS+=(--cache-type-v "$ctv")
  case "$fa" in on|off|auto) ARGS+=(-fa "$fa") ;; esac
  [ -n "$reason" ] && ARGS+=(--reasoning-format "$reason")

  # KV 量化必须配 flash-attn
  if [ -n "$ctk$ctv" ] && [ "$fa" = "off" ]; then
    warn "KV cache 用了 $ctk/$ctv，必须开 flash-attn，已自动改为 on"
    ARGS+=(-fa on)
  fi

  # 视觉投影
  if [ "$(gv vision enabled false)" = "true" ]; then
    mmproj="$(gvr "$section" model mmproj '')"
    if [ -n "$mmproj" ]; then
      case "$mmproj" in /*) : ;; *) mmproj="$ROOT/$mmproj" ;; esac
      [ -f "$mmproj" ] && ARGS+=(--mmproj "$mmproj") || warn "视觉投影文件不存在：$mmproj"
    fi
  fi

  # 采样参数（角色段优先，其次 [sampling]）
  local k flag v
  while read -r k flag; do
    v="$(gvr "$section" sampling "$k" '')"
    [ -n "$v" ] && ARGS+=("$flag" "$v")
  done <<'EOF'
temp --temp
top_p --top-p
top_k --top-k
min_p --min-p
presence_penalty --presence-penalty
frequency_penalty --frequency-penalty
repeat_penalty --repeat-penalty
repeat_last_n --repeat-last-n
dry_multiplier --dry-multiplier
EOF

  # 角色段自己的 extra_args（比如 --cpu-moe），再拼 [extra] args
  local role_extra extra
  role_extra="$(gvr "$section" gpu extra_args '')"
  extra="$(gv extra args '')"
  if [ -n "$role_extra" ]; then read -r -a _tmp <<< "$role_extra"; ARGS+=("${_tmp[@]}"); fi
  if [ -n "$extra" ];      then read -r -a _tmp <<< "$extra";      ARGS+=("${_tmp[@]}"); fi
  # shellcheck disable=SC2034
  ROLE_NAME="$role"
  MODEL_PATH="$model"
  PORT="$port"
}

# ------------------------------------------------------------ 动作
wait_ready() {
  local port; port="$(gv server port 8080)"
  local i
  for i in $(seq 1 120); do
    if curl -fsS --max-time 2 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

do_start() {
  if running_pid >/dev/null; then
    ok "已在运行（PID $(running_pid)）"
    return 0
  fi
  if health_ok; then
    ok "端口已在服务（外部启动的 llama-server）"
    return 0
  fi

  local server; server="$(find_server)" || die "找不到 llama-server，请先运行 scripts/setup-linux.sh"
  build_args
  say "启动：$ROLE_NAME → $(basename "$MODEL_PATH")  (ctx=$CTX, 端口 $PORT)"

  # shellcheck disable=SC2086
  nohup "$server" "${ARGS[@]}" >"$OUT_LOG" 2>"$ERR_LOG" &
  local pid=$!
  printf '%s\n' "$pid" > "$PID_FILE"
  guard "start pid=$pid role=$ROLE_NAME"

  if wait_ready; then
    ok "就绪：http://127.0.0.1:$PORT （PID $pid）"
  else
    warn "等了 240 秒仍没就绪，看日志：$ERR_LOG"
    tail -n 15 "$ERR_LOG" 2>/dev/null | sed 's/^/      /'
    return 1
  fi
}

do_foreground() {
  local server; server="$(find_server)" || die "找不到 llama-server，请先运行 scripts/setup-linux.sh"
  build_args
  say "前台运行：$ROLE_NAME → $(basename "$MODEL_PATH")  (端口 $PORT)"
  exec "$server" "${ARGS[@]}"
}

do_stop() {
  local pid
  if pid="$(running_pid)"; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
    guard "stop pid=$pid"
    ok "已停止"
    return 0
  fi
  # 不是本脚本起的，按端口找
  local port; port="$(gv server port 8080)"
  if command -v fuser >/dev/null 2>&1; then
    fuser -k "${port}/tcp" 2>/dev/null && { ok "已停止占用 $port 的进程"; return 0; }
  fi
  ok "本来就没在跑"
}

do_status() {
  local port; port="$(gv server port 8080)"
  if pid="$(running_pid)"; then
    say "运行中（PID $pid，端口 $port）"
  elif health_ok; then
    say "运行中（外部进程，端口 $port）"
  else
    say "未运行"
    return 1
  fi
  curl -fsS --max-time 3 "http://127.0.0.1:$port/v1/models" 2>/dev/null | head -c 300
  echo
}

do_switch() {
  local role="$1"
  [ -f "$CONF" ] || die "配置不存在：$CONF"
  # 改 [models] active
  python3 - "$CONF" "$role" <<'PY'
import re, sys, pathlib
conf, role = sys.argv[1], sys.argv[2]
p = pathlib.Path(conf)
s = p.read_text(encoding="utf-8")
if re.search(r'(?m)^\s*\[models\]', s):
    s = re.sub(r'(?m)^(active\s*=).*$', r'\1 ' + role, s, count=1)
    if not re.search(r'(?m)^active\s*=', s):
        s = re.sub(r'(?m)^(\[models\]\s*)$', r'\1\nactive = ' + role, s, count=1)
else:
    s = "[models]\nactive = " + role + "\n\n" + s
p.write_text(s, encoding="utf-8")
PY
  ok "已切换到 $role"
  do_stop >/dev/null 2>&1 || true
  do_start
}

# ------------------------------------------------------------ 入口
ACTION="start"
for a in "$@"; do
  case "$a" in
    --stop|-Stop|stop)             ACTION="stop" ;;
    --status|-Status|status)       ACTION="status" ;;
    --ensure|-EnsureRunning|ensure)ACTION="ensure" ;;
    --foreground|-Foreground)      ACTION="foreground" ;;
    --base|-Base)                  ACTION="switch"; ROLE_ARG="base" ;;
    --qwen36|-Qwen36)              ACTION="switch"; ROLE_ARG="qwen36" ;;
    --deepseek|-DeepSeek)          ACTION="switch"; ROLE_ARG="deepseek" ;;
    -h|--help|help)                sed -n '2,20p' "$0"; exit 0 ;;
    *) warn "忽略未知参数：$a" ;;
  esac
done

if [ -f "$CONF" ] || [ "$ACTION" = "status" ]; then :; else
  die "找不到配置 $CONF（先复制 scripts/llama.conf.example.ini）"
fi

case "$ACTION" in
  stop)       do_stop ;;
  status)     do_status ;;
  foreground) do_foreground ;;
  switch)     do_switch "$ROLE_ARG" ;;
  ensure)
    if health_ok; then ok "服务正常"; else do_start; fi ;;
  start)      do_start ;;
esac
