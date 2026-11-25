#!/usr/bin/env bash
# ============================================================
#  06-check-server.sh —— 服务状态诊断 + 补测
#
#  上一轮日志显示：model loaded / listening on 127.0.0.1:8080
#  说明 llama-server 本身起来了，是「健康检查那一步」没通过。
#  这个脚本查：进程还在不在、端口有没有在听、curl 有没有、有没有代理变量。
# ============================================================
set -u
PORT=8080
LOG="$HOME/llama-server.log"
say() { printf "\n\033[36m== %s ==\033[0m\n" "$*"; }

say "1. 进程"
if pgrep -af 'llama-server' >/dev/null 2>&1; then
  pgrep -af 'llama-server'
else
  echo "  没有 llama-server 进程（说明启动后又退出了）"
fi

say "2. 端口监听"
if command -v ss >/dev/null 2>&1; then
  ss -ltn 2>/dev/null | grep -E ":$PORT\b" || echo "  $PORT 没有在监听"
else
  echo "  没有 ss 命令"
fi

say "3. 工具与代理"
printf "  curl: "; command -v curl || echo "缺失！"
printf "  wget: "; command -v wget || echo "缺失"
echo "  代理相关环境变量："
env | grep -i -E 'proxy|PROXY' || echo "    无"

say "4. 健康检查（绕过代理）"
code="000"
if command -v curl >/dev/null 2>&1; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 8 "http://127.0.0.1:$PORT/health")
  echo "  /health -> HTTP $code"
else
  echo "  没有 curl，用 bash 自带 /dev/tcp 试："
  (exec 3<>/dev/tcp/127.0.0.1/$PORT && printf 'GET /health HTTP/1.0\r\n\r\n' >&3 && head -1 <&3) 2>/dev/null || echo "  连接失败"
fi

say "5. 如果健康检查通过，做一次对话"
if [ "$code" = "200" ]; then
  echo "  服务正常。下面的回答说明整条链路都通了："
  curl -s --noproxy '*' -X POST "http://127.0.0.1:$PORT/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"messages":[{"role":"user","content":"用一句话介绍你自己"}],"max_tokens":60,"stream":false}' \
    | head -c 700
  echo
  echo
  echo "  显存："
  nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null
  exit 0
fi

say "6. 没通过，看日志尾部"
tail -25 "$LOG" 2>/dev/null || echo "  没有日志文件"

say "7. 处理建议"
cat <<EOT
  - 若「进程」显示还在、端口也在听，但 health 不是 200：
      可能是请求被代理拦了。试试： curl --noproxy '*' http://127.0.0.1:$PORT/health
  - 若没有进程：
      说明启动后退出，把日志尾部（第 6 节）发给我
  - 若没有 curl：
      sudo apt install -y curl
EOT
