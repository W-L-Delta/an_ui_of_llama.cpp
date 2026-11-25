#!/usr/bin/env bash
# ============================================================
#  09-systemd.sh —— 做成开机自启（systemd 系统服务）
#
#  背景：你是靠重启切换系统的，重启后什么都没有了。
#  装好这两个服务后，开机就会自动拉起：
#      llama-server   （8080，挂了 5 秒后自动重启）
#      llama-panel    （8090，控制台 + 聊天界面）
#
#  用系统级服务（User=你），不依赖是否登录图形界面。
# ============================================================
set -u
DEST="$HOME/llama-ui"
LLAMA_BIN="$HOME/llama.cpp/llama-b12681"
USER_NAME="$(id -un)"
say() { printf "\n\033[36m== %s ==\033[0m\n" "$*"; }

say "1. 检查前置条件"
[ -f "$DEST/scripts/start-llama.sh" ] || { echo "  还没装 UI，先跑 08"; exit 1; }
[ -x "$DEST/bin/cuda/llama-server" ] || { echo "  缺少 bin/cuda/llama-server，先跑 08"; exit 1; }
[ -f "$DEST/panel/app.py" ] || { echo "  缺少 panel/app.py，先跑 08"; exit 1; }
command -v systemctl >/dev/null || { echo "  没有 systemctl（非 systemd 系统）"; exit 1; }
echo "  用户: $USER_NAME   目录: $DEST"

say "2. 停掉手动起的进程（交给 systemd 管理）"
if [ -f "$HOME/llama-server.pid" ]; then kill "$(cat "$HOME/llama-server.pid")" 2>/dev/null; fi
pkill -f 'llama-b12681/llama-server' 2>/dev/null
pkill -f 'llama-ui/panel/app.py' 2>/dev/null
sleep 2
pgrep -af 'llama-server|llama-ui/panel' || echo "  已清空"

say "3. 写 llama-server.service"
sudo tee /etc/systemd/system/llama-server.service >/dev/null <<EOT
[Unit]
Description=llama.cpp server (llama-local-chat)
After=network-online.target nvidia-persistenced.service
Wants=network-online.target

[Service]
Type=simple
User=$USER_NAME
WorkingDirectory=$DEST
Environment=HOME=$HOME
Environment=LD_LIBRARY_PATH=$LLAMA_BIN
ExecStart=/usr/bin/env bash $DEST/scripts/start-llama.sh --foreground
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOT

say "4. 写 llama-panel.service"
sudo tee /etc/systemd/system/llama-panel.service >/dev/null <<EOT
[Unit]
Description=llama.cpp console panel (llama-local-chat)
After=network-online.target llama-server.service
Wants=llama-server.service

[Service]
Type=simple
User=$USER_NAME
WorkingDirectory=$DEST
Environment=HOME=$HOME
ExecStart=/usr/bin/python3 $DEST/panel/app.py --port 8090
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOT

say "5. 启用并立即启动"
sudo systemctl daemon-reload
sudo systemctl enable llama-server llama-panel 2>&1 | tail -3
sudo systemctl restart llama-server
echo "  等待模型加载…"
python3 - <<'PY'
import time, urllib.request
for i in range(180):
    try:
        with urllib.request.urlopen("http://127.0.0.1:8080/health", timeout=2) as r:
            if r.status == 200:
                print(f"  llama-server 就绪（{i} 秒）")
                break
    except Exception:
        pass
    time.sleep(1)
else:
    print("  180 秒未就绪，检查: journalctl -u llama-server -n 50")
PY
sudo systemctl restart llama-panel
sleep 4

say "6. 状态"
for unit in llama-server llama-panel; do
  printf "  %-14s %s\n" "$unit" "$(systemctl is-active $unit 2>/dev/null) / $(systemctl is-enabled $unit 2>/dev/null)"
done
python3 - <<'PY'
import json, urllib.request
try:
    with urllib.request.urlopen("http://127.0.0.1:8090/api/state", timeout=5) as r:
        d = json.loads(r.read().decode())
    print(f"  面板 API: OK   服务运行={d.get('running')}   已加载={(d.get('loaded') or {}).get('id')}")
except Exception as e:
    print("  面板 API 访问失败:", e)
PY
nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null | sed 's/^/  显存: /'

say "完成"
cat <<EOT
  控制台:  http://127.0.0.1:8090
  聊天:    http://127.0.0.1:8090/chat

  常用命令：
    systemctl status llama-server llama-panel    查看状态
    sudo systemctl restart llama-server          重启服务
    sudo systemctl stop llama-server             停止
    journalctl -u llama-server -f                看实时日志
    sudo systemctl disable llama-server llama-panel   取消开机自启

  说明：开机后不需要登录图形界面，这两个服务就会自己起来。
EOT
