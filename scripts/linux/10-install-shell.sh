#!/usr/bin/env bash
# ============================================================
#  10-install-shell.sh —— 给 Linux 做一个「独立窗口」外壳
#
#  不用浏览器：用 GTK3 + WebKit2 开一个自己的窗口，
#  效果和 Windows 的 llama-chat.exe 一样（有自己的窗口和图标）。
#
#  用到的都是 Ubuntu 官方源里的包，不需要编译、不需要 npm。
# ============================================================
set -u
DEST="$HOME/llama-ui"
SHELL_DIR="$DEST/shell"
USER_NAME="$(id -un)"
say() { printf "\n\033[36m== %s ==\033[0m\n" "$*"; }

say "1. 检查 GTK/WebKit 依赖"
need_install=""
python3 -c "import gi" 2>/dev/null || need_install="$need_install python3-gi"
python3 -c "import gi; gi.require_version('Gtk','3.0'); from gi.repository import Gtk" 2>/dev/null || need_install="$need_install gir1.2-gtk-3.0"
python3 - <<'PY' 2>/dev/null || need_install="$need_install gir1.2-webkit2-4.1"
import gi
gi.require_version("WebKit2", "4.1")
from gi.repository import WebKit2
PY
if [ -n "$need_install" ]; then
  echo "  需要安装:$need_install"
  sudo apt-get update -qq
  sudo apt-get install -y $need_install || { echo "  安装失败，详见上面输出"; exit 1; }
else
  echo "  依赖齐全"
fi
python3 - <<'PY'
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk
ver = None
for v in ("4.1", "4.0"):
    try:
        gi.require_version("WebKit2", v)
        from gi.repository import WebKit2
        ver = v
        break
    except Exception:
        continue
print("  GTK:", ".".join(map(str, (Gtk.get_major_version(), Gtk.get_minor_version(), Gtk.get_micro_version()))),
      " WebKit2:", ver or "缺失")
PY

say "2. 写入外壳程序"
mkdir -p "$SHELL_DIR"
cp -f "$DEST/web/skins/icons/default.png" "$SHELL_DIR/icon.png" 2>/dev/null || true

cat > "$SHELL_DIR/llama_chat.py" <<'PYEOF'
#!/usr/bin/env python3
# ============================================================
#  llama_chat.py —— 独立窗口外壳（GTK3 + WebKit2）
#  效果等同 Windows 上的 llama-chat.exe：
#    · 自己的窗口、自己的任务栏图标，不依赖浏览器
#    · 关掉窗口进程就结束
#  用法： python3 llama_chat.py [url]
# ============================================================
import os
import sys

URL = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8090/chat"
TITLE = "llama.cpp 本地对话"

# NVIDIA 混合显卡笔记本上 WebKit 偶尔会白屏，关掉合成模式最稳
os.environ.setdefault("WEBKIT_DISABLE_COMPOSITING_MODE", "1")

try:
    import gi
except ImportError:
    sys.stderr.write("缺少 python3-gi，先装：sudo apt install -y python3-gi gir1.2-gtk-3.0 gir1.2-webkit2-4.1\n")
    raise SystemExit(2)

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib  # noqa: E402

WebKit = None
for ver in ("4.1", "4.0"):
    try:
        gi.require_version("WebKit2", ver)
        from gi.repository import WebKit2 as WebKit  # noqa: F401
        WEBKIT_VER = ver
        break
    except (ValueError, ImportError):
        continue

if WebKit is None:
    sys.stderr.write("缺少 WebKit2 GTK，先装：sudo apt install -y gir1.2-webkit2-4.1\n")
    raise SystemExit(2)


class App:
    def __init__(self):
        self.win = Gtk.Window(title=TITLE)
        self.win.set_default_size(1280, 860)
        self.win.set_icon_from_file(os.path.join(os.path.dirname(os.path.abspath(__file__)), "icon.png"))
        self.web = WebKit.WebView()
        self.web.load_uri(URL)

        header = Gtk.HeaderBar()
        header.set_show_close_button(True)
        header.props.title = TITLE

        btn_reload = Gtk.Button(label="刷新")
        btn_reload.connect("clicked", lambda *_: self.web.reload())
        header.pack_start(btn_reload)

        btn_console = Gtk.Button(label="控制台")
        btn_console.connect("clicked", self.open_console)
        header.pack_end(btn_console)

        self.win.set_titlebar(header)
        self.win.add(self.web)
        self.win.connect("destroy", Gtk.main_quit)
        self.win.show_all()

    def open_console(self, *_):
        base = URL.rsplit("/", 1)[0]
        self.web.load_uri(base + "/")

    def run(self):
        Gtk.main()


if __name__ == "__main__":
    App().run()

PYEOF
chmod +x "$SHELL_DIR/llama_chat.py"
echo "  $SHELL_DIR/llama_chat.py"

say "3. 安装应用图标（应用列表里能看到）"
mkdir -p "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/256x256/apps"
cp -f "$SHELL_DIR/icon.png" "$HOME/.local/share/icons/hicolor/256x256/apps/llama-chat.png" 2>/dev/null || true
cat > "$HOME/.local/share/applications/llama-chat.desktop" <<EOT
[Desktop Entry]
Type=Application
Name=llama.cpp 本地对话
Name[zh_CN]=llama.cpp 本地对话
Comment=本地离线对话（独立窗口）
Exec=/usr/bin/python3 $SHELL_DIR/llama_chat.py
Icon=$HOME/.local/share/icons/hicolor/256x256/apps/llama-chat.png
Terminal=false
Categories=Utility;Network;Chat;
Keywords=llama,chat,AI,本地
StartupWMClass=llama_chat.py
EOT
chmod +x "$HOME/.local/share/applications/llama-chat.desktop"

say "4. 桌面快捷方式（双击启动）"
if [ -d "$HOME/Desktop" ]; then
  cp -f "$HOME/.local/share/applications/llama-chat.desktop" "$HOME/Desktop/llama-chat.desktop"
  chmod +x "$HOME/Desktop/llama-chat.desktop"
  # GNOME 需要标记为可信，否则双击会提示"不受信任"
  (command -v gio >/dev/null && gio set "$HOME/Desktop/llama-chat.desktop" metadata::trusted true 2>/dev/null) || true
  echo "  已放到 ~/Desktop（若提示不受信任：右键 → 允许运行）"
else
  echo "  ~/Desktop 不存在，跳过（仍可从应用列表启动）"
fi

say "5. 自检（不打开窗口，只检查能否导入）"
python3 - <<'PY'
import gi, os
os.environ.setdefault("WEBKIT_DISABLE_COMPOSITING_MODE", "1")
gi.require_version("Gtk", "3.0")
for v in ("4.1", "4.0"):
    try:
        gi.require_version("WebKit2", v)
        from gi.repository import WebKit2
        print("  WebKit2", v, "可用 —— 外壳可以正常打开")
        break
    except Exception:
        continue
else:
    print("  WebKit2 不可用，外壳打不开（可以用浏览器代替）")
PY

say "完成"
cat <<EOT
  启动方式（三种任选）：
    1. 应用列表里搜「llama.cpp 本地对话」
    2. 双击桌面上的 llama-chat（若提示不受信任，右键→允许运行）
    3. 终端： python3 $SHELL_DIR/llama_chat.py

  注意：外壳只是窗口，对话要靠后台服务，所以先确认
        systemctl status llama-server llama-panel
        两个都是 active 才有内容显示。
EOT
