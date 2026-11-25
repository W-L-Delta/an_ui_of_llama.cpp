#!/usr/bin/env bash
# ============================================================
#  12-fix-all.sh —— 把两个问题一起修掉
#
#  结论（来自上一份报告）：
#    · 外壳程序本身是好的：窗口能显示（退出码 124 = 被 timeout 正常杀掉）
#    · 图标点不开的真正原因：.desktop 的 Exec 里写了引号、> 和 &，
#      这是 desktop 规范的保留字符，GNOME 直接拒绝执行（所以毫无反应）
#    · 后端两个 systemd 服务是 inactive（09 那步没跑成），所以窗口就算开了也是空页
#
#  做法：
#    1. 用 ~/llama-ui/shell/launch.sh 做唯一入口（重定向写在脚本里，Exec 只写路径）
#    2. 重写 .desktop、桌面副本（中文桌面 ~/桌面）、Dock 收藏
#    3. 跑 09 把 systemd 服务装好并启动（幂等）
#    4. 验证：服务/面板 active + 面板 API + 外壳能开 5 秒
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/llama-ui"
SHELL_DIR="$DEST/shell"
APP_ID="llama-chat.desktop"
say() { printf "\n\033[36m== %s ==\033[0m\n" "$*"; }

say "1. 桌面目录"
DESKTOP_DIR=""
command -v xdg-user-dir >/dev/null 2>&1 && DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null)"
[ -z "${DESKTOP_DIR:-}" ] && [ -d "$HOME/桌面" ] && DESKTOP_DIR="$HOME/桌面"
[ -z "${DESKTOP_DIR:-}" ] && [ -d "$HOME/Desktop" ] && DESKTOP_DIR="$HOME/Desktop"
echo "  ${DESKTOP_DIR:-未找到}"

say "2. 写唯一入口 launch.sh"
mkdir -p "$SHELL_DIR"
cat > "$SHELL_DIR/launch.sh" <<EOT
#!/usr/bin/env bash
LOG="\$HOME/llama-ui/shell/shell.log"
{
  echo "---- \$(date '+%F %T') 启动 ----"
  exec /usr/bin/python3 "\$HOME/llama-ui/shell/llama_chat.py"
} >> "\$LOG" 2>&1
EOT
chmod +x "$SHELL_DIR/launch.sh"
echo "  $SHELL_DIR/launch.sh"

say "3. 写桌面条目（Exec 只有路径，不含保留字符）"
mkdir -p "$HOME/.local/share/applications"
desktop_body() {
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
EOT
}
desktop_body > "$HOME/.local/share/applications/$APP_ID"
chmod +x "$HOME/.local/share/applications/$APP_ID"
if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$HOME/.local/share/applications/$APP_ID" \
    && echo "  校验通过" || echo "  校验仍有问题（见上）"
fi
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

say "4. 放到桌面"
if [ -n "${DESKTOP_DIR:-}" ] && [ -d "${DESKTOP_DIR}" ]; then
  desktop_body > "$DESKTOP_DIR/$APP_ID"
  chmod +x "$DESKTOP_DIR/$APP_ID"
  command -v gio >/dev/null 2>&1 && gio set "$DESKTOP_DIR/$APP_ID" metadata::trusted true 2>/dev/null || true
  echo "  $DESKTOP_DIR/$APP_ID"
fi

say "5. Dock 收藏"
if command -v gsettings >/dev/null 2>&1; then
  cur="$(gsettings get org.gnome.shell favorite-apps 2>/dev/null || echo "[]")"
  case "$cur" in
    *"$APP_ID"*) echo "  已在 Dock" ;;
    *) gsettings set org.gnome.shell favorite-apps "$(printf '%s' "$cur" | sed "s/\]$/, '$APP_ID']/")" 2>/dev/null && echo "  已加入 Dock" ;;
  esac
fi

say "6. 安装并启动 systemd 服务（跑 09）"
if [ -f "$HERE/09-systemd.sh" ]; then
  bash "$HERE/09-systemd.sh"
else
  echo "  找不到 09-systemd.sh"
fi

say "7. 验证"
for u in llama-server llama-panel; do
  printf "  %-13s %s\n" "$u" "$(systemctl is-active $u 2>/dev/null)"
done
python3 - <<'PY'
import json, urllib.request
for name, url in (("llama-server", "http://127.0.0.1:8080/health"),
                  ("llama-panel", "http://127.0.0.1:8090/api/state")):
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            body = r.read().decode()
        if name == "llama-panel":
            d = json.loads(body)
            print(f"  {name:12s} OK  running={d.get('running')} loaded={(d.get('loaded') or {}).get('id')}")
        else:
            print(f"  {name:12s} OK  {body[:60]}")
    except Exception as e:
        print(f"  {name:12s} 失败: {e}")
PY

say "8. 实测外壳（5 秒）"
rm -f "$SHELL_DIR/shell.log"
timeout 5 "$SHELL_DIR/launch.sh" ; rc=$?
echo "  退出码: $rc   （124 = 窗口正常显示后被关闭；其它 = 失败）"
tail -5 "$SHELL_DIR/shell.log" 2>/dev/null | sed 's/^/    /'

say "完成"
cat <<EOT
  现在可以：
    · 桌面双击「llama.cpp 本地对话」
    · 或 Dock 上点图标
    · 或应用列表搜索
    · 或终端： ~/llama-ui/shell/launch.sh

  出问题看日志：
    cat ~/llama-ui/shell/shell.log
EOT
