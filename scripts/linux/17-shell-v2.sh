#!/usr/bin/env bash
# ============================================================
#  17-shell-v2.sh —— 外壳 v2 + 扫描修复 + 现场诊断
#
#  解决四个问题：
#    1. 点图标开第二个窗口、Dock 图标不统一  -> 单实例锁 + WM class=llama-chat
#    2. 打开控制台把聊天顶掉、关掉就全关      -> 改成两个标签页（聊天 / 控制台）
#    3. 扫描模型结果为 0                      -> scan 现在会扫「已配置模型所在目录」
#    4. 打开显示无法连接                      -> 本脚本会打印两个 unit 的状态与日志
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SHARE="$(cd "$HERE/../../.." && pwd)"
PKG="$SHARE/llama.cpp/dist/ui"
DEST="$HOME/llama-ui"
SHELL_DIR="$DEST/shell"
APP_ID="llama-chat.desktop"
say() { printf "\n\033[36m== %s ==\033[0m\n" "$*"; }

say "1. 关掉所有旧外壳实例"
pkill -f 'llama-ui/shell/llama_chat.py' 2>/dev/null && echo "  已关闭旧窗口" || echo "  没有在跑的旧窗口"
sleep 1

say "2. 更新文件"
for f in "shell/llama_chat.py" "panel/app.py" "panel/ui.html" "web/chat.html"; do
  if [ -f "$PKG/$f" ]; then
    mkdir -p "$(dirname "$DEST/$f")"
    cp -f "$PKG/$f" "$DEST/$f"
    echo "  $f"
  else
    echo "  [缺失] $f"
  fi
done
chmod +x "$SHELL_DIR/llama_chat.py"
rm -f "$SHELL_DIR/shell.lock"

if [ -f "$DEST/web/skins/icons/default.png" ]; then
  cp -f "$DEST/web/skins/icons/default.png" "$SHELL_DIR/icon.png"
fi

say "3. 写 launch.sh 与桌面条目（统一 WM class）"
cat > "$SHELL_DIR/launch.sh" <<'EOT'
#!/usr/bin/env bash
LOG="$HOME/llama-ui/shell/shell.log"
{
  echo "---- $(date '+%F %T') 启动 ----"
  exec /usr/bin/python3 "$HOME/llama-ui/shell/llama_chat.py"
} >> "$LOG" 2>&1
EOT
chmod +x "$SHELL_DIR/launch.sh"

make_desktop() {
  cat <<EOT
[Desktop Entry]
Type=Application
Name=llama.cpp 本地对话
Comment=本地离线对话（独立窗口）
Exec=$SHELL_DIR/launch.sh
Icon=$SHELL_DIR/icon.png
Terminal=false
Categories=Utility;
Keywords=llama;chat;AI;
StartupNotify=true
StartupWMClass=llama-chat
EOT
}
DESKTOP_DIR=""
command -v xdg-user-dir >/dev/null 2>&1 && DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null)"
[ -z "${DESKTOP_DIR:-}" ] && [ -d "$HOME/桌面" ] && DESKTOP_DIR="$HOME/桌面"
mkdir -p "$HOME/.local/share/applications"
make_desktop > "$HOME/.local/share/applications/$APP_ID"
chmod +x "$HOME/.local/share/applications/$APP_ID"
if [ -n "${DESKTOP_DIR:-}" ] && [ -d "${DESKTOP_DIR}" ]; then
  make_desktop > "$DESKTOP_DIR/$APP_ID"
  chmod +x "$DESKTOP_DIR/$APP_ID"
  command -v gio >/dev/null 2>&1 && gio set "$DESKTOP_DIR/$APP_ID" metadata::trusted true 2>/dev/null || true
fi
echo "  已更新桌面条目"

say "4. 重启面板"
sudo systemctl restart llama-panel
sleep 4

say "5. 现场诊断"
for u in llama-server llama-panel; do
  printf "  %-13s %s / %s\n" "$u" "$(systemctl is-active $u 2>/dev/null)" "$(systemctl is-enabled $u 2>/dev/null)"
done
echo "  端口："
ss -ltn 2>/dev/null | grep -E ':(8080|8090)\b' | sed 's/^/    /' || echo "    8080/8090 都没有监听！"
echo "  llama-server 日志（最后 12 行）："
journalctl -u llama-server -n 12 --no-pager 2>/dev/null | sed 's/^/    /'
echo "  llama-panel 日志（最后 12 行）："
journalctl -u llama-panel -n 12 --no-pager 2>/dev/null | sed 's/^/    /'

say "6. 接口探测"
python3 - <<'PY'
import json, urllib.request
tests = [("llama /health", "http://127.0.0.1:8080/health"),
         ("llama /v1/models", "http://127.0.0.1:8080/v1/models"),
         ("panel /", "http://127.0.0.1:8090/"),
         ("panel /api/state", "http://127.0.0.1:8090/api/state"),
         ("panel /api/models/scan", "http://127.0.0.1:8090/api/models/scan")]
for name, url in tests:
    try:
        with urllib.request.urlopen(url, timeout=8) as r:
            b = r.read()
        extra = ""
        d = None
        try:
            d = json.loads(b.decode())
        except Exception:
            pass
        if "/v1/models" in name and d:
            extra = "  模型数=" + str(len(d.get("data") or []))
        if name.endswith("/api/models/scan") and d:
            extra = "  扫描到=" + str(len(d.get("files") or [])) + " 个 gguf"
        if name.endswith("/api/state") and d:
            extra = f"  running={d.get('running')} loaded={(d.get('loaded') or {}).get('id')} workspace={d.get('workspace')}"
        print(f"  {name:22s} OK  {len(b)} 字节{extra}")
    except Exception as e:
        print(f"  {name:22s} 失败: {e}")
PY

say "7. 实测外壳（8 秒）"
rm -f "$SHELL_DIR/shell.log"
timeout 8 "$SHELL_DIR/launch.sh"; rc=$?
echo "  退出码: $rc （124 = 窗口正常）"
tail -6 "$SHELL_DIR/shell.log" 2>/dev/null | sed 's/^/    /'

say "8. 单实例验证"
( "$SHELL_DIR/launch.sh" & sleep 4; echo "  第二个实例的退出码（应为 0，且不开新窗）：$?"; sleep 1; pkill -f 'llama-ui/shell/llama_chat.py' ) 2>/dev/null
tail -3 "$SHELL_DIR/shell.log" 2>/dev/null | sed 's/^/    /'

say "完成"
cat <<EOT
  现在窗口里有两个标签页：聊天 / 控制台，互不影响。
  图标统一为 llama-chat，重复点击不会开新窗口。

  如果还显示「无法连接」，看第 5 节的日志：
      journalctl -u llama-server -n 50 --no-pager
      journalctl -u llama-panel -n 50 --no-pager
EOT
