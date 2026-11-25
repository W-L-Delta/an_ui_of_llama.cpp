#!/usr/bin/env bash
# ============================================================
#  15-fix-shell-console.sh —— 修「控制台打不开」，并顺带修工作区路径
#
#  控制台打不开的真实原因：
#      聊天页里的「设置 / 控制台」是用 window.open(...) 打开的。
#      GTK 版 WebKit 默认**不会**为 window.open 创建新窗口，
#      所以在独立窗口里点它 = 毫无反应。
#      修法：连接 WebKitWebView 的 create 信号，把请求的 URL 在当前窗口里打开。
#
#  另外顺带跑 14，把 [tools] workspace = D:\llama工作区 改成 Linux 路径。
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/llama-ui"
SHELL_DIR="$DEST/shell"
APP_ID="llama-chat.desktop"
say() { printf "\n\033[36m== %s ==\033[0m\n" "$*"; }

say "0. 先修工作区路径（跑 14）"
bash "$HERE/14-fix-console.sh" || echo "  14 有报错，继续后面的步骤"

say "1. 重写外壳程序（支持 window.open）"
mkdir -p "$SHELL_DIR"
cat > "$SHELL_DIR/llama_chat.py" <<'PYEOF'
#!/usr/bin/env python3
# ============================================================
#  llama_chat.py —— 独立窗口外壳（GTK3 + WebKit2）
#  要点：
#    · 处理 WebKit 的 create 信号：页面里 window.open(...) 不再无反应，
#      直接在当前窗口里跳转（这就是"点控制台打不开"的原因）
#    · 顶部按钮：刷新 / 控制台 / 聊天
#    · 任何异常写 shell.log
#  自检： python3 llama_chat.py --check
# ============================================================
import os
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.join(HERE, "shell.log")
CHAT_URL = "http://127.0.0.1:8090/chat"
CONSOLE_URL = "http://127.0.0.1:8090/"
TITLE = "llama.cpp 本地对话"

os.environ.setdefault("WEBKIT_DISABLE_COMPOSITING_MODE", "1")
os.environ.setdefault("WEBKIT_DISABLE_DMABUF_RENDERER", "1")


def log(msg):
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(msg.rstrip() + "\n")
    except OSError:
        pass


def check():
    print("DISPLAY         =", os.environ.get("DISPLAY"))
    print("WAYLAND_DISPLAY =", os.environ.get("WAYLAND_DISPLAY"))
    print("XDG_SESSION_TYPE=", os.environ.get("XDG_SESSION_TYPE"))
    try:
        import gi
        gi.require_version("Gtk", "3.0")
        from gi.repository import Gtk
        print("GTK             =", Gtk.get_major_version(), Gtk.get_minor_version(), Gtk.get_micro_version())
    except Exception as e:
        print("GTK             = 失败:", e)
        return 2
    for ver in ("4.1", "4.0"):
        try:
            gi.require_version("WebKit2", ver)
            from gi.repository import WebKit2  # noqa: F401
            print("WebKit2         =", ver)
            return 0
        except Exception:
            continue
    print("WebKit2         = 不可用")
    return 2


def main():
    try:
        import gi
        gi.require_version("Gtk", "3.0")
        from gi.repository import Gtk

        WebKit = None
        for ver in ("4.1", "4.0"):
            try:
                gi.require_version("WebKit2", ver)
                from gi.repository import WebKit2 as WebKit  # noqa: F401
                break
            except Exception:
                continue
        if WebKit is None:
            log("错误：找不到 WebKit2")
            return 2

        log("启动 DISPLAY=%s WAYLAND_DISPLAY=%s" % (os.environ.get("DISPLAY"), os.environ.get("WAYLAND_DISPLAY")))

        view = WebKit.WebView()
        view.load_uri(CHAT_URL)

        def on_create(_view, action):
            """页面里 window.open() / target=_blank：在当前窗口打开，不弹无效新窗"""
            try:
                req = action.get_request()
                uri = req.get_uri() if req else ""
            except Exception:
                uri = ""
            if uri:
                log("窗口内跳转: " + uri)
                view.load_uri(uri)
            return None  # 不创建新 WebView

        try:
            view.connect("create", on_create)
        except Exception as e:
            log("挂载 create 信号失败: %r" % (e,))

        def on_load_failed(_view, _event, uri, error):
            log("加载失败 %s: %s" % (uri, error.message if hasattr(error, "message") else error))

        try:
            view.connect("load-failed", on_load_failed)
        except Exception:
            pass

        win = Gtk.Window(title=TITLE)
        win.set_default_size(1280, 860)
        icon = os.path.join(HERE, "icon.png")
        if os.path.isfile(icon):
            try:
                win.set_icon_from_file(icon)
            except Exception as e:
                log("设置图标失败（忽略）: %r" % (e,))

        header = Gtk.HeaderBar()
        header.set_show_close_button(True)
        header.props.title = TITLE

        def add_btn(label, uri, pack_end=False):
            b = Gtk.Button(label=label)
            b.connect("clicked", lambda *_: view.load_uri(uri))
            (header.pack_end if pack_end else header.pack_start)(b)
            return b

        add_btn("刷新", CHAT_URL)
        add_btn("聊天", CHAT_URL, pack_end=True)
        add_btn("控制台", CONSOLE_URL, pack_end=True)

        win.set_titlebar(header)
        win.add(view)
        win.connect("destroy", Gtk.main_quit)
        win.show_all()
        log("窗口已显示")
        Gtk.main()
        log("窗口关闭")
        return 0
    except Exception:
        log("崩溃:\n" + traceback.format_exc())
        return 1


if __name__ == "__main__":
    if "--check" in sys.argv:
        raise SystemExit(check())
    raise SystemExit(main())

PYEOF
chmod +x "$SHELL_DIR/llama_chat.py"
python3 "$SHELL_DIR/llama_chat.py" --check | sed 's/^/  /'

say "2. 写 launch.sh 与桌面条目"
cat > "$SHELL_DIR/launch.sh" <<'EOT'
#!/usr/bin/env bash
LOG="$HOME/llama-ui/shell/shell.log"
{
  echo "---- $(date '+%F %T') 启动 ----"
  exec /usr/bin/python3 "$HOME/llama-ui/shell/llama_chat.py"
} >> "$LOG" 2>&1
EOT
chmod +x "$SHELL_DIR/launch.sh"

DESKTOP_DIR=""
command -v xdg-user-dir >/dev/null 2>&1 && DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null)"
[ -z "${DESKTOP_DIR:-}" ] && [ -d "$HOME/桌面" ] && DESKTOP_DIR="$HOME/桌面"

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
EOT
}
mkdir -p "$HOME/.local/share/applications"
make_desktop > "$HOME/.local/share/applications/$APP_ID"
chmod +x "$HOME/.local/share/applications/$APP_ID"
if [ -n "${DESKTOP_DIR:-}" ] && [ -d "${DESKTOP_DIR}" ]; then
  make_desktop > "$DESKTOP_DIR/$APP_ID"
  chmod +x "$DESKTOP_DIR/$APP_ID"
  command -v gio >/dev/null 2>&1 && gio set "$DESKTOP_DIR/$APP_ID" metadata::trusted true 2>/dev/null || true
  echo "  桌面条目: $DESKTOP_DIR/$APP_ID"
fi

say "3. 实测外壳（6 秒）"
rm -f "$SHELL_DIR/shell.log"
timeout 6 "$SHELL_DIR/launch.sh"; rc=$?
echo "  退出码: $rc  （124=窗口正常）"
tail -8 "$SHELL_DIR/shell.log" 2>/dev/null | sed 's/^/    /'

say "4. 控制台可达性"
python3 - <<'PY'
import urllib.request, json
for name, url in (("控制台 /", "http://127.0.0.1:8090/"),
                  ("/chat", "http://127.0.0.1:8090/chat"),
                  ("/api/state", "http://127.0.0.1:8090/api/state")):
    try:
        with urllib.request.urlopen(url, timeout=6) as r:
            b = r.read()
        extra = ""
        if name == "/api/state":
            d = json.loads(b.decode())
            extra = f"  workspace={d.get('workspace')}"
        print(f"  {name:14s} OK  {len(b)} 字节{extra}")
    except Exception as e:
        print(f"  {name:14s} 失败: {e}")
PY

say "完成"
cat <<EOT
  现在：
    · 窗口顶栏有「聊天」「控制台」按钮，点哪个换哪个
    · 聊天页里的「设置」入口也会在当前窗口打开（不再无响应）
    · 工作区默认改成 ~/llama-work，可在控制台里改

  若还有问题： cat ~/llama-ui/shell/shell.log
EOT
